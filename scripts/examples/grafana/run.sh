#!/usr/bin/env bash
# Usage: ./scripts/examples/grafana/run.sh
#        KIND_LISTEN_ADDRESS=0.0.0.0 ./scripts/examples/grafana/run.sh
#
# Env vars and defaults:
#   SCRIPTS_DIR  scripts/ in the launchy-dev checkout
#   Other inputs pass through to the called scripts (e.g. GATEWAY_API_VERSION for init_1).
#
# Sets up a kind cluster with Linkerd, viz and Grafana, then port-forwards to the Grafana dashboard.
# Runs, in order: scripts/init_0_prerequisites.sh, scripts/init_1_create_cluster.sh,
# scripts/init_2_install_linkerd.sh, scripts/init_3_install_linkerd_viz.sh,
# scripts/init_4_install_grafana.sh, scripts/pf_2_grafana_dashboard.sh.
# Cleanup: scripts/cleanup_1_cluster.sh.
set -euo pipefail

# Resolves the scripts dir two levels up from this example.
SCRIPTS_DIR=${SCRIPTS_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}

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
  [ -x "$SCRIPTS_DIR/$s" ] || { echo "missing or not executable: $SCRIPTS_DIR/$s (set SCRIPTS_DIR to the launchy-dev scripts dir)" >&2; exit 1; }
done

# Builds the cluster with Linkerd, viz and Grafana.
"$SCRIPTS_DIR/init_0_prerequisites.sh"
"$SCRIPTS_DIR/init_1_create_cluster.sh"
"$SCRIPTS_DIR/init_2_install_linkerd.sh"
"$SCRIPTS_DIR/init_3_install_linkerd_viz.sh"
"$SCRIPTS_DIR/init_4_install_grafana.sh"

# Names the cleanup now: the port-forward below blocks until ctrl-C.
echo "cleanup: $SCRIPTS_DIR/cleanup_1_cluster.sh"
"$SCRIPTS_DIR/pf_2_grafana_dashboard.sh"
