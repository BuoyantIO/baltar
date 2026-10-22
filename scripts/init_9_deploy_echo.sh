#!/usr/bin/env bash
# Loads k (kubectl on CONTEXT).
# shellcheck source=scripts/util_kube.sh
. scripts/util_kube.sh

# Run from the baltar repo root.
# Usage: ./scripts/init_9_deploy_echo.sh
#        CONTEXT=kind-baltar ./scripts/init_9_deploy_echo.sh
#
# Setup step 9: deploys init_9_echo.yaml: ns demo (meshed) and a meshed echo server on opaque port 5678.
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
#   CONTEXT=kind-kind   kubectl context
set -euo pipefail

# Inputs with defaults.
CONTEXT=${CONTEXT:-kind-kind}

# Deletes the workload so the re-applied pod gets the currently installed proxy.
echo "[-] delete deploy/echo in ns demo"
k -n demo delete deploy echo --ignore-not-found --wait

# Applies ns demo, deploy/echo and svc/echo.
echo "[-] apply ns demo, echo"
k apply -f scripts/init_9_echo.yaml

# Waits for the meshed Deployment to roll out.
echo "[-] rollout"
k -n demo rollout status deploy/echo --timeout=180s

# Lists the pods; READY 2/2 shows linkerd-proxy was injected.
echo "[-] ready"
k -n demo get pods -o wide
