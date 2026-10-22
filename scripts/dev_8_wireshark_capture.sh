#!/usr/bin/env bash
# Usage: ./scripts/dev_8_wireshark_capture.sh [NAMESPACE] [WORKLOAD]
#   e.g. ./scripts/dev_8_wireshark_capture.sh
#        ./scripts/dev_8_wireshark_capture.sh | wireshark -k -i -
#        FILTER='tcp port 4143' OUT=/tmp/inspector-4143.pcap ./scripts/dev_8_wireshark_capture.sh
#        OUT=/tmp/web.pcap ./scripts/dev_8_wireshark_capture.sh emojivoto deploy/web
#        OUT=/tmp/pod.pcap ./scripts/dev_8_wireshark_capture.sh emojivoto pod/web-5d8f7c9b6-abcde
#   Live view on the Mac, run there:
#        ssh -o ClearAllForwardings=yes dev 'bash -lc "cd ~/projects/baltar && scripts/dev_8_wireshark_capture.sh"' | /Applications/Wireshark.app/Contents/MacOS/Wireshark -k -i -
# Run from the baltar repo root. Defaults to inspect deploy/inspector.
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
set -euo pipefail

NS="${1:-inspect}"
WORKLOAD="${2:-deploy/inspector}"
OUT=${OUT:-}
FILTER=${FILTER:-}
TARGET=${TARGET:-}
IMAGE=${IMAGE:-nicolaka/netshoot}
SNIFF=${SNIFF:-sniff}

# Writes to a file rather than pcap bytes to a terminal; a piped stdout keeps streaming.
if [ -z "$OUT" ] && [ -t 1 ]; then
  OUT=/tmp/inspector.pcap
fi

# Resolves WORKLOAD to a pod: the newest running one, so a rollout picks the replacement.
echo "[-] pod for $NS/$WORKLOAD" >&2
case "$WORKLOAD" in
  pod/*|pods/*|po/*)
    pod=${WORKLOAD#*/}
    ;;
  *)
    # shellcheck disable=SC2016 # go-template vars, not shell expansions
    LABELS=$(kubectl -n "$NS" get "$WORKLOAD" \
      -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}')
    SELECTOR=$(echo "$LABELS" | sed 's/,$//')
    pod=$(kubectl -n "$NS" get pod -l "$SELECTOR" --field-selector=status.phase=Running \
      --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
    ;;
esac
echo "pod: $pod" >&2

# Defaults TARGET to the first container that is not the proxy.
names=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.spec.containers[?(@.name!="linkerd-proxy")].name}')
TARGET=${TARGET:-${names%% *}}
echo "target: $TARGET" >&2

# Creates the sniff container if absent, then waits for it to run; the first image pull is slow.
echo "[-] ephemeral container $SNIFF" >&2
SNIFF_NAME=$(kubectl -n "$NS" get pod "$pod" -o jsonpath="{.spec.ephemeralContainers[?(@.name==\"$SNIFF\")].name}")
if [ -z "$SNIFF_NAME" ]; then
  kubectl -n "$NS" debug "$pod" --image="$IMAGE" --target="$TARGET" --container="$SNIFF" \
    -- sleep infinity </dev/null >&2
fi
for _ in $(seq 60); do
  SNIFF_RUNNING=$(kubectl -n "$NS" get pod "$pod" -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name==\"$SNIFF\")].state.running}")
  [ -n "$SNIFF_RUNNING" ] && break
  sleep 1
done

# Captures; -U flushes each packet so a live Wireshark sees it immediately.
echo "[-] capture '${FILTER:-all traffic}' to ${OUT:-stdout} (Ctrl-C to stop)" >&2
# shellcheck disable=SC2086 # FILTER splits into the separate args tcpdump expects
kubectl -n "$NS" exec "$pod" -c "$SNIFF" -- tcpdump -i any -U -w - $FILTER </dev/null >"${OUT:-/dev/stdout}"
