#!/usr/bin/env bash
# Usage: ./init_9_deploy_echo.sh
#        CONTEXT=kind-launchy ./init_9_deploy_echo.sh
#
# Setup step 9: deploys init_9_echo.yaml: ns demo (meshed) and a meshed echo server on opaque port 5678,
# the target of test_load_3_fortio.sh.
# Deletes the Deployment first so the pod restarts with the currently installed proxy; safe to rerun.
#
#  pod echo
#  +--------------------------+
#  | linkerd-proxy :4143      |  <-- mTLS, opaque :5678
#  |   |                      |
#  |   v                      |
#  | http-echo :5678 "hello"  |
#  +--------------------------+
#
# Env vars and defaults:
#   CONTEXT=kind-kind   kubectl context; must start with kind- so load never hits a real cluster
set -euo pipefail

# Inputs with defaults; the manifest sits next to this script.
CONTEXT=${CONTEXT:-kind-kind}
MANIFEST="$(cd "$(dirname "$0")" && pwd)/init_9_echo.yaml"

# Helpers: kubectl on CONTEXT, and a bold step banner.
k() { kubectl --context "$CONTEXT" "$@"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# Fails fast on a non-kind context, missing kubectl, manifest or context.
case "$CONTEXT" in
  kind-*) ;;
  *) echo "context $CONTEXT does not start with kind-: refusing to deploy on it" >&2; exit 1 ;;
esac
command -v kubectl >/dev/null || { echo "kubectl not found: install it" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }
k config get-contexts "$CONTEXT" >/dev/null 2>&1 || {
  echo "context $CONTEXT not found: run init_1_create_cluster.sh" >&2
  exit 1
}

# Deletes the workload so the re-applied pod gets the currently installed proxy.
step "delete deploy/echo in ns demo"
k -n demo delete deploy echo --ignore-not-found --wait

# Applies ns demo, deploy/echo and svc/echo.
step "apply ns demo, echo"
k apply -f "$MANIFEST"

# Waits for the meshed Deployment to roll out.
step "rollout"
k -n demo rollout status deploy/echo --timeout=180s

# Lists the pods; READY 2/2 shows linkerd-proxy was injected.
step "ready"
k -n demo get pods -o wide
