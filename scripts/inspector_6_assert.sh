#!/usr/bin/env bash
# Usage: ./inspector_6_assert.sh
#        EXPECTED_ID=wrong.inspect.serviceaccount.identity.linkerd.cluster.local ./inspector_6_assert.sh
#        INSPECTOR_IMAGE=localhost/l4-proto-inspector:dev CONTEXT=kind-kind ./inspector_6_assert.sh
#
# Inspector step 6: runs the pp_test assertion once in a fresh Pod inspector-assert and exits with
# the inspector container's exit code: 0 pass, 1 assertion failed, 2 setup error.
# Every other failure, kubectl included, exits 2, so only the inspector can yield 0 or 1.
# Needs the fixture from inspector_2_deploy.sh (ns inspect, SA inspector, deploy/client).
#
# Traffic path: deploy/client runs `nc inspector-assert.inspect 15432`; its linkerd-proxy sends
# mTLS to the Pod's linkerd-proxy, which prepends PROXY v2 (TLV 0xE0 = client identity) for the
# inspector. The inspector checks the header against --pp-identity and exits when the conn closes.
#
# Env vars and defaults:
#   EXPECTED_ID=client.inspect.serviceaccount.identity.linkerd.cluster.local identity pp_test expects
#   CONTEXT=kind-kind kubectl context
#   INSPECTOR_IMAGE=localhost/l4-proto-inspector:dev inspector image, substituted into the manifest
#   TIMEOUT=60 seconds to wait for the inspector container to terminate after the send
set -Eeuo pipefail

# Turns any unguarded command failure into exit 2; -E carries the trap into functions.
trap 'exit 2' ERR

# Inputs with defaults; the manifest sits next to this script.
DEFAULT_ID=client.inspect.serviceaccount.identity.linkerd.cluster.local
DEFAULT_IMAGE=localhost/l4-proto-inspector:dev
EXPECTED_ID=${EXPECTED_ID:-$DEFAULT_ID}
CONTEXT=${CONTEXT:-kind-kind}
INSPECTOR_IMAGE=${INSPECTOR_IMAGE:-$DEFAULT_IMAGE}
TIMEOUT=${TIMEOUT:-60}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || exit 2
MANIFEST="$SCRIPT_DIR/inspector_assert.yaml"

# Cluster objects from inspector_2_deploy.sh and the manifest.
NS=inspect
POD=inspector-assert

# Helpers: kubectl on CONTEXT, a bold step banner, and exit 2 so setup errors never read as a fail.
k() { kubectl --context "$CONTEXT" "$@"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "$*" >&2; exit 2; }

# Fails fast, naming the missing prerequisite.
step "prerequisites"
# Positive decimal only: bash arithmetic exits 1 on a bad operand and reads a leading 0 as octal.
case "$TIMEOUT" in
  '' | 0* | *[!0-9]*) die "TIMEOUT must be a positive integer of seconds, got: $TIMEOUT" ;;
esac
command -v kubectl >/dev/null || die "kubectl not found: install it"
[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
k cluster-info >/dev/null 2>&1 || die "context $CONTEXT unreachable: run init_1_create_cluster.sh"
k get namespace "$NS" >/dev/null 2>&1 || die "namespace $NS missing: run inspector_2_deploy.sh"
k -n "$NS" get serviceaccount inspector >/dev/null 2>&1 \
  || die "$NS/serviceaccount/inspector missing: run inspector_2_deploy.sh"
k -n "$NS" rollout status deploy/client --timeout=60s >/dev/null 2>&1 \
  || die "$NS/deploy/client not ready: run inspector_2_deploy.sh"

# Removes a Pod left by an earlier run; restartPolicy Never means it cannot be reused.
step "delete old pod $POD"
k -n "$NS" delete pod "$POD" --ignore-not-found --wait || die "delete of old pod $NS/$POD failed"

# Deletes the Pod on any exit; the Service stays, since apply keeps it idempotent.
trap 'k -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT

# Applies the manifest with image and identity swapped in; sed writes to stdout, so no GNU -i.
step "apply $POD, image $INSPECTOR_IMAGE, expect $EXPECTED_ID"
sed -e "s|image: $DEFAULT_IMAGE|image: $INSPECTOR_IMAGE|" \
  -e "s|- $DEFAULT_ID\$|- $EXPECTED_ID|" "$MANIFEST" | k apply -f - \
  || die "apply of $MANIFEST failed"

# Waits until linkerd-proxy, inspector and echo are all ready.
step "wait Ready"
k -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=180s \
  || die "pod $NS/$POD not Ready within 180s"

# Sends one marker; the reply is informational, since the inspector exit code is the verdict.
marker="assert-$(date +%s)-$RANDOM"
step "send $marker to $POD.$NS:15432"
reply=$(k -n "$NS" exec deploy/client -c client -- \
  sh -c "echo '$marker' | nc -w2 $POD.$NS 15432") \
  || die "nc from deploy/client to $POD.$NS:15432 failed"
echo "client received: ${reply:-<nothing>}"

# Polls the inspector container until it terminates; kubectl wait cannot match "any exit code".
# A failed get is retried: a persistent kubectl error ends in the timeout die, not exit 1.
step "wait for inspector to terminate (${TIMEOUT}s)"
path='{.status.containerStatuses[?(@.name=="inspector")].state.terminated.exitCode}'
code=""
deadline=$((SECONDS + TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
  code=$(k -n "$NS" get pod "$POD" -o jsonpath="$path") || code=""
  [ -n "$code" ] && break
  sleep 1
done
[ -n "$code" ] || die "inspector in $NS/$POD did not terminate within ${TIMEOUT}s"
case "$code" in
  *[!0-9]*) die "inspector exitCode is not a number: $code" ;;
esac
# Exit statuses wrap modulo 256, so an out-of-range code could read as 0 or 1.
{ [ "${#code}" -le 3 ] && [ "$code" -le 255 ]; } || die "inspector exitCode out of range: $code"

# Prints the exit code, and the inspector's findings from stderr when it did not pass.
step "summary"
echo "inspector exitCode: $code"
if [ "$code" -ne 0 ]; then
  k -n "$NS" logs "$POD" -c inspector >&2 || true
fi
exit "$code"
