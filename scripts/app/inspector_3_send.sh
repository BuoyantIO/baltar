#!/usr/bin/env bash
# Usage: ./inspector_3_send.sh
#        MARKER=pp-test-1 ./inspector_3_send.sh
#
# Inspector step 3: sends a marker from deploy/client through inspector.inspect:15432 and checks
# the echo equals it, so the inspector stripped the PROXY v2 header. Last line: `marker: <marker>`.
#
# Env vars and defaults:
#   MARKER=pp-<epoch>-<random> payload to send; pass it to inspector_4_verify.sh
set -euo pipefail

# Inputs with defaults.
MARKER=${MARKER:-pp-$(date +%s)-$RANDOM}

# Cluster objects from inspector_2_deploy.sh.
CONTEXT=kind-kind
NS=inspect

# Helpers: kubectl on CONTEXT, a bold step banner, and exit with a message.
k() { kubectl --context "$CONTEXT" "$@"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "$*" >&2; exit 1; }

# Fails fast, naming the missing prerequisite, so it does not read like a check failure.
step "prerequisites"
command -v kubectl >/dev/null || die "kubectl not found: install it"
k cluster-info >/dev/null 2>&1 || die "context $CONTEXT unreachable: run ../init_1_create_cluster.sh"
k get namespace "$NS" >/dev/null 2>&1 || die "namespace $NS missing: run inspector_2_deploy.sh"
for d in inspector client; do
  k -n "$NS" rollout status "deploy/$d" --timeout=60s >/dev/null 2>&1 \
    || die "$NS/deploy/$d not ready: run inspector_2_deploy.sh"
done

# Sends the marker and checks the echo; any leftover header bytes would come back in the reply.
step "send $MARKER to inspector.$NS:15432"
reply=$(k -n "$NS" exec deploy/client -c client -- \
  sh -c "echo '$MARKER' | nc -w2 inspector.$NS 15432") \
  || die "FAIL: nc from deploy/client to inspector.$NS:15432 failed"
echo "client received: ${reply:-<nothing>}"
[ "$reply" = "$MARKER" ] || die "FAIL: reply is not exactly $MARKER"

# Prints the marker last so it can be copied into inspector_4_verify.sh.
echo "marker: $MARKER"
