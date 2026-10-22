#!/usr/bin/env bash
# Run from the baltar repo root.
# Usage: ./scripts/examples/grafana/run.sh
#        KIND_LISTEN_ADDRESS=0.0.0.0 ./scripts/examples/grafana/run.sh
#
# Env vars and defaults:
#   Inputs pass through to the called scripts (e.g. GATEWAY_API_VERSION for init_1).
#
# Sets up a kind cluster with Linkerd, viz and Grafana, then port-forwards to the Grafana dashboard.
# Runs, in order: scripts/init_0_prerequisites.sh, scripts/init_1_create_cluster.sh,
# scripts/init_2_install_linkerd.sh, scripts/init_3_install_linkerd_viz.sh,
# scripts/init_4_install_grafana.sh, scripts/pf_2_grafana_dashboard.sh.
# Cleanup: scripts/cleanup_1_cluster.sh.
set -euo pipefail

# Fails fast if any called script is missing, before the cluster is touched.
STEPS=(
  init_0_prerequisites.sh
  init_1_create_cluster.sh
  init_2_install_linkerd.sh
  init_3_install_linkerd_viz.sh
  init_4_install_grafana.sh
  pf_2_grafana_dashboard.sh
)
for s in "${STEPS[@]}"; do
  [ -x "scripts/$s" ] || { echo "missing or not executable: scripts/$s" >&2; exit 1; }
done

# Builds the cluster with Linkerd, viz and Grafana.
scripts/init_0_prerequisites.sh
scripts/init_1_create_cluster.sh
scripts/init_2_install_linkerd.sh
scripts/init_3_install_linkerd_viz.sh
scripts/init_4_install_grafana.sh

# Names the cleanup now: the port-forward below blocks until ctrl-C.
echo "cleanup: scripts/cleanup_1_cluster.sh"
scripts/pf_2_grafana_dashboard.sh
