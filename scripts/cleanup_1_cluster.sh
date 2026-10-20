#!/usr/bin/env bash
# Usage: ./cleanup_1_cluster.sh
#        CLUSTER_NAME=east ./scripts/cleanup_1_cluster.sh
# Tears the cluster down. Nothing the init_ modules install survives the
# cluster, so this is a complete teardown.
set -euo pipefail

# Names the cluster to delete so the same script can tear down more than one.
#
# Left unset we run kind's bare delete, which targets kind's own default
# cluster; keeping that exact form means every single-cluster caller, all of
# which target context kind-kind, behaves as before.
CLUSTER_NAME=${CLUSTER_NAME:-}
if [ -n "$CLUSTER_NAME" ]; then
  kind delete cluster --name "$CLUSTER_NAME"
else
  kind delete cluster
fi
