#!/usr/bin/env bash
# Usage: ./init_6_deploy_emojivoto.sh
#
# Setup step 6. Deploys the emojivoto demo app.
#
# It was split out of the old install_ingress_haproxy.sh so the app and
# the ingress that exposes it can be installed, torn down and re-run
# independently.
set -euo pipefail

echo "=== Deploying Emojivoto Application ==="
curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/emojivoto.yml | kubectl apply -f -
