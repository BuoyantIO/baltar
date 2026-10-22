#!/usr/bin/env bash
# Run from the baltar repo root.
# Usage: ./scripts/examples/custom_image/run.sh
#        LINKERD2_PROXY_REF=pull/4625/head LINKERD2_REF=pull/15676/head ./scripts/examples/custom_image/run.sh
#        BUILD_OUT_DIR=/path/to/out ./scripts/examples/custom_image/run.sh
#
# Env vars and defaults (passed through; defaults live in the called scripts):
#   LINKERD2_PROXY_REF  pull/4625/head (build_1_proxy.sh)
#   LINKERD2_REF        pull/15676/head (build_2_linkerd2.sh)
#   BUILD_OUT_DIR       out/ in the baltar checkout (util_build.sh)
#
# Builds a custom proxy and Linkerd control plane, installs them on the kind cluster and verifies the images.
# build_5_verify_linkerd2.sh runs the linux/amd64 CLI, so its CLI checks fail on macOS.
# Cleanup: scripts/cleanup_1_cluster.sh
set -euo pipefail

# Creates the kind cluster build_3 targets, unless it exists: init_1 fails on an existing cluster.
command -v kind >/dev/null 2>&1 || { echo "missing: kind; run scripts/init_0_prerequisites.sh" >&2; exit 1; }
if ! kind get clusters | grep -qx kind; then
  scripts/init_1_create_cluster.sh
fi

# Builds, installs and verifies the custom images in step order.
scripts/build_1_proxy.sh
scripts/build_2_linkerd2.sh
scripts/build_3_install_custom_linkerd.sh
scripts/build_4_verify_proxy.sh
scripts/build_5_verify_linkerd2.sh

echo "cleanup: scripts/cleanup_1_cluster.sh" >&2
