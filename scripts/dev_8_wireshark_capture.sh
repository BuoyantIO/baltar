#!/usr/bin/env bash
# Usage: ./dev_8_wireshark_capture.sh [NAMESPACE] [WORKLOAD]
#   e.g. ./dev_8_wireshark_capture.sh
#        ./dev_8_wireshark_capture.sh | wireshark -k -i -
#        FILTER='tcp port 4143' OUT=/tmp/inspector-4143.pcap ./dev_8_wireshark_capture.sh
#        OUT=/tmp/web.pcap ./dev_8_wireshark_capture.sh emojivoto deploy/web
#        OUT=/tmp/pod.pcap ./dev_8_wireshark_capture.sh emojivoto pod/web-5d8f7c9b6-abcde
#   Live view on the Mac, run there:
#        ssh -o ClearAllForwardings=yes dev 'bash -lc "cd ~/projects/launchy-dev && scripts/dev_8_wireshark_capture.sh"' | /Applications/Wireshark.app/Contents/MacOS/Wireshark -k -i -
# Defaults to inspect deploy/inspector.
#
# Captures one running pod's traffic with tcpdump in an ephemeral debug
# container, as pcap to OUT or stdout. All human-readable output goes to stderr.
#
# In a meshed pod, traffic between pods on 4143 is mTLS, so payloads are
# encrypted; the proxy-to-app hop inside the pod is cleartext.
#
#  Mac: Wireshark -k -i -  <-- ssh stdout <--  VM: kubectl exec -c sniff
#                                                        |
#  target pod (one network namespace, shared by all)     v
#  +--------------------------------------------------------------------+
#  | sniff (ephemeral): tcpdump -i any -U -w -, sees every hop below    |
#  |                                                                    |
#  | other pods --mTLS--> linkerd-proxy :4143 --clear--> app :<port>    |
#  |  (encrypted)          e.g. PROXY v2 header to inspector :15432     |
#  |                                                                    |
#  | other pods <--mTLS-- linkerd-proxy :4140 <--clear-- app outbound   |
#  |  (encrypted)                    (iptables-redirected to :4140)     |
#  |                                                                    |
#  | lo: in-pod loopback hops, e.g. inspector -> echo 127.0.0.1:9000    |
#  +--------------------------------------------------------------------+
#
# Env vars and defaults:
#   OUT=<unset>                pcap file; unset streams to a piped stdout, else writes /tmp/inspector.pcap
#   FILTER=<empty>             tcpdump filter expression; empty captures all traffic
#   TARGET=<first app container> container whose process namespace to join; default skips linkerd-proxy
#   IMAGE=nicolaka/netshoot    debug container image
#   SNIFF=sniff                debug container name
#   KUBE_CONTEXT=<current>     kube context; unset uses the current one
set -euo pipefail

# Inputs with defaults.
NS="${1:-inspect}"
WORKLOAD="${2:-deploy/inspector}"
OUT=${OUT:-}
FILTER=${FILTER:-}
TARGET=${TARGET:-}
IMAGE=${IMAGE:-nicolaka/netshoot}
SNIFF=${SNIFF:-sniff}
KUBE_CONTEXT=${KUBE_CONTEXT:-}

# Helpers: kubectl on KUBE_CONTEXT if set, a bold step banner, and exit with a message, all on stderr.
k() {
  if [ -n "$KUBE_CONTEXT" ]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi
}
step() { printf '\n\033[1m==> %s\033[0m\n' "$*" >&2; }
die() { echo "$*" >&2; exit 1; }

# Writes to a default file rather than pcap bytes to a terminal; a piped stdout keeps streaming.
if [ -z "$OUT" ] && [ -t 1 ]; then
  OUT=/tmp/inspector.pcap
fi

# Fails fast, naming the missing prerequisite.
step "prerequisites"
command -v kubectl >/dev/null || die "kubectl not found: install it"
k cluster-info >/dev/null 2>&1 || die "kube context ${KUBE_CONTEXT:-<current>} unreachable: check kubectl config current-context"
k get namespace "$NS" >/dev/null 2>&1 || die "namespace $NS missing: deploy the workload first"

# Resolves WORKLOAD to one running pod, the newest so a rollout picks the replacement.
step "pod for $NS/$WORKLOAD"
case "$WORKLOAD" in
  pod/*|pods/*|po/*)
    pod=${WORKLOAD#*/}
    phase=$(k -n "$NS" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null) \
      || die "pod $NS/$pod not found"
    [ "$phase" = Running ] || die "pod $NS/$pod is $phase, not Running"
    ;;
  *)
    # shellcheck disable=SC2016 # go-template vars, not shell expansions
    selector=$(k -n "$NS" get "$WORKLOAD" \
      -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null) \
      || die "$NS/$WORKLOAD not found: check the namespace and workload"
    selector=${selector%,}
    [ -n "$selector" ] || die "$NS/$WORKLOAD has no matchLabels selector: pass pod/<name> instead"
    pod=$(k -n "$NS" get pod -l "$selector" --field-selector=status.phase=Running \
      --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
    [ -n "$pod" ] || die "no running pod for $NS/$WORKLOAD (selector $selector)"
    ;;
esac
echo "pod: $pod" >&2

# Defaults TARGET to the first container that is not the proxy.
if [ -z "$TARGET" ]; then
  for c in $(k -n "$NS" get pod "$pod" -o jsonpath='{.spec.containers[*].name}'); do
    if [ "$c" != linkerd-proxy ]; then TARGET=$c; break; fi
  done
  [ -n "$TARGET" ] || die "pod $pod has no container other than linkerd-proxy: set TARGET"
fi
echo "target: $TARGET" >&2

# Reads the sniff container's running and terminated state; empty strings when absent.
sniff_state() {
  k -n "$NS" get pod "$pod" -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name==\"$SNIFF\")].state.$1}"
}

# Creates the sniff container if absent; a terminated one cannot be restarted or its name reused.
step "ephemeral container $SNIFF"
exists=$(k -n "$NS" get pod "$pod" -o jsonpath="{.spec.ephemeralContainers[?(@.name==\"$SNIFF\")].name}")
if [ -z "$exists" ]; then
  k -n "$NS" debug "$pod" --image="$IMAGE" --target="$TARGET" --container="$SNIFF" \
    -- sleep infinity </dev/null >&2
elif [ -z "$(sniff_state running)" ] && [ -n "$(sniff_state terminated)" ]; then
  die "$SNIFF in $pod terminated and its name cannot be reused: restart the pod or set a different SNIFF"
fi

# Waits for it to run; the first image pull is slow.
for _ in $(seq 1 60); do
  [ -n "$(sniff_state running)" ] && break
  [ -n "$(sniff_state terminated)" ] && die "$SNIFF in $pod terminated: restart the pod or set a different SNIFF"
  sleep 1
done
[ -n "$(sniff_state running)" ] || die "$SNIFF in $pod not running after 60s: check kubectl -n $NS describe pod $pod"
echo "$SNIFF running" >&2

# Captures; -U flushes each packet so a live Wireshark sees it immediately.
tcpdump_cmd=(k -n "$NS" exec "$pod" -c "$SNIFF" -- tcpdump -i any -U -w -)
[ -n "$FILTER" ] && tcpdump_cmd+=("$FILTER")
label=${FILTER:-all traffic}
if [ -n "$OUT" ]; then
  step "capture '$label' to $OUT (Ctrl-C to stop)"
  "${tcpdump_cmd[@]}" </dev/null >"$OUT"
else
  step "capture '$label' to stdout (Ctrl-C to stop)"
  "${tcpdump_cmd[@]}" </dev/null
fi
