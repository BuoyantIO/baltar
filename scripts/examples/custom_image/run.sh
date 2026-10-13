#!/usr/bin/env bash
# Usage: ./run.sh
#        LINKERD2_PROXY_REF=pull/4625/head LINKERD2_REF=pull/15676/head ./run.sh
#        BUILD_OUT_DIR=/path/to/out ./run.sh
#
# Env vars and defaults (passed through; defaults live in the called scripts):
#   LINKERD2_PROXY_REF  pull/4625/head (build_1_proxy.sh)
#   LINKERD2_REF        pull/15676/head (build_2_linkerd2.sh)
#   BUILD_OUT_DIR       out/ in the launchy-dev checkout (util_build.sh)
#
# Builds a custom proxy and Linkerd control plane, installs them on the kind cluster and verifies the images.
# build_5_verify_linkerd2.sh runs the linux/amd64 CLI, so its CLI checks fail on macOS.
# Cleanup: scripts/cleanup_1_cluster.sh
set -euo pipefail

# Resolves the scripts directory from this example's location.
SCRIPTS_DIR=$(cd "$(dirname "$0")/../.." && pwd)

# Creates the kind cluster build_3 targets, unless it exists: init_1 fails on an existing cluster.
command -v kind >/dev/null 2>&1 || { echo "missing: kind; run $SCRIPTS_DIR/init_0_prerequisites.sh" >&2; exit 1; }
if ! kind get clusters | grep -qx kind; then
  "$SCRIPTS_DIR/init_1_create_cluster.sh"
fi

# Builds, installs and verifies the custom images in step order.
"$SCRIPTS_DIR/build_1_proxy.sh"
"$SCRIPTS_DIR/build_2_linkerd2.sh"
"$SCRIPTS_DIR/build_3_install_custom_linkerd.sh"
"$SCRIPTS_DIR/build_4_verify_proxy.sh"
"$SCRIPTS_DIR/build_5_verify_linkerd2.sh"

echo "cleanup: $SCRIPTS_DIR/cleanup_1_cluster.sh" >&2
