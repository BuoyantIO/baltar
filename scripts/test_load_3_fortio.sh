#!/usr/bin/env bash
# Usage: ./test_load_3_fortio.sh
#        CONNECTIONS=500 QPS=100 ./test_load_3_fortio.sh
#        CONTEXT=kind-launchy ./test_load_3_fortio.sh
#
# Load test inside the mesh: deploys test_load_3_fortio.yaml, a meshed fortio client (deploy/load in ns demo)
# holding many long-lived connections to echo under steady load until it is deleted.
# Needs init_9_deploy_echo.sh first. Deletes the Deployment first so the pod restarts with the currently
# installed proxy; safe to rerun.
#
#  pod load                            pod echo
#  +---------------------+  mTLS      +--------------------------+
#  | fortio --> linkerd- |----------->| linkerd-proxy :4143      |
#  | -c CONNECTIONS proxy|  opaque    |   |                      |
#  | -qps QPS            |  :5678     |   v                      |
#  +---------------------+            | http-echo :5678 "hello"  |
#                                     +--------------------------+
#
# Env vars and defaults:
#   CONTEXT=kind-kind   kubectl context; must start with kind- so load never hits a real cluster
#   CONNECTIONS=2000    fortio -c, concurrent long-lived connections to echo
#   QPS=500             fortio -qps, total requests per second across all connections
set -euo pipefail

# Inputs with defaults; the manifest sits next to this script.
CONTEXT=${CONTEXT:-kind-kind}
CONNECTIONS=${CONNECTIONS:-2000}
QPS=${QPS:-500}
MANIFEST="$(cd "$(dirname "$0")" && pwd)/test_load_3_fortio.yaml"

# Helpers: kubectl on CONTEXT, and a bold step banner.
k() { kubectl --context "$CONTEXT" "$@"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# Fails fast on a non-kind context, missing kubectl, manifest or context, or non-numeric inputs.
case "$CONTEXT" in
  kind-*) ;;
  *) echo "context $CONTEXT does not start with kind-: refusing to generate load on it" >&2; exit 1 ;;
esac
command -v kubectl >/dev/null || { echo "kubectl not found: install it" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }
k config get-contexts "$CONTEXT" >/dev/null 2>&1 || {
  echo "context $CONTEXT not found: run init_1_create_cluster.sh" >&2
  exit 1
}
case "$CONNECTIONS$QPS" in
  *[!0-9]*) echo "CONNECTIONS and QPS must be integers: got $CONNECTIONS, $QPS" >&2; exit 1 ;;
esac

# Fails fast if the load target is missing; the namespace and echo come from init_9_deploy_echo.sh.
k get ns demo >/dev/null 2>&1 || { echo "ns demo not found: run init_9_deploy_echo.sh" >&2; exit 1; }
k -n demo get deploy echo >/dev/null 2>&1 || {
  echo "deploy/echo not found in ns demo: run init_9_deploy_echo.sh" >&2
  exit 1
}

# Deletes the workload so the re-applied pod gets the currently installed proxy.
step "delete deploy/load in ns demo"
k -n demo delete deploy load --ignore-not-found --wait

# Applies the manifest with the value after -c and -qps replaced; awk avoids GNU-only sed -i.
step "apply deploy/load, -c $CONNECTIONS -qps $QPS"
awk -v c="$CONNECTIONS" -v q="$QPS" '
  prev ~ /- -c$/   { sub(/"[0-9]+"/, "\"" c "\"") }
  prev ~ /- -qps$/ { sub(/"[0-9]+"/, "\"" q "\"") }
  { print; prev = $0 }
' "$MANIFEST" | k apply -f -

# Waits for the meshed Deployment to roll out.
step "rollout"
k -n demo rollout status deploy/load --timeout=180s

# Lists the pods; READY 2/2 shows linkerd-proxy was injected.
step "ready"
k -n demo get pods -o wide
