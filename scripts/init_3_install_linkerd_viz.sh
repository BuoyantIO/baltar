#!/usr/bin/env bash
# Usage: ./init_3_install_linkerd_viz.sh
#
# Setup step 3. Installs the linkerd-viz extension, which carries the
# Prometheus that init_4's Grafana reads from.
#
# It runs after init_2, since viz installs into a cluster that already
# has a control plane.
set -euo pipefail

linkerd viz install | kubectl apply -f -

# linkerd check
