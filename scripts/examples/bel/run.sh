#!/usr/bin/env bash
# Run from the baltar repo root.
# Usage: ./scripts/examples/bel/run.sh
#        BEL_VERSION=2.19.12 ./scripts/examples/bel/run.sh
#        CONNECTIONS=500 QPS=100 ./scripts/examples/bel/run.sh
#
# Example: kind cluster with Buoyant Enterprise for Linkerd, the meshed echo server in ns demo
# and a meshed fortio client holding long-lived connections to it under steady load.
# Creates the cluster, so it fails if a kind cluster already exists; tear down with scripts/cleanup_1_cluster.sh.
#
# Env vars and defaults (passed through to the scripts; see their headers):
#   BEL_VERSION   2.20.3 (init_2_install_bel.sh; also BEL_ENV_FILE, BEL_PROXY_ADDITIONAL_ENV, BEL_CERT_DIR)
#   CONTEXT       kind-kind (init_9_deploy_echo.sh, test_load_3_fortio.sh)
#   CONNECTIONS   2000 (test_load_3_fortio.sh)
#   QPS           500 (test_load_3_fortio.sh)
set -euo pipefail

# Creates the cluster: init_2_install_bel.sh runs after init_1_create_cluster.sh.
scripts/init_1_create_cluster.sh

# Installs BEL, deploys echo, then starts the fortio load.
scripts/init_2_install_bel.sh
scripts/init_9_deploy_echo.sh
scripts/test_load_3_fortio.sh

# Names the teardown.
echo "cleanup: scripts/cleanup_1_cluster.sh"
