#!/usr/bin/env bash
# Usage: ./cleanup_1_cluster.sh
# Tears the cluster down. Nothing the init_ modules install survives the
# cluster, so this is a complete teardown.
set -euo pipefail

kind delete cluster
