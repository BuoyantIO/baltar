#!/usr/bin/env bash
# Usage: ./inspector_5_cleanup.sh
#
# Inspector step 5: deletes ns inspect from kind-kind so inspector_2_deploy.sh starts clean.
# Leaves the cluster, ns linkerd and the image in kind alone; exits 0 when ns inspect is already gone.
#
# Env vars and defaults: none.
set -euo pipefail

# Targets the cluster from init_1_create_cluster.sh.
CONTEXT=kind-kind

# Helpers: kubectl on CONTEXT, and a bold step banner.
k() { kubectl --context "$CONTEXT" "$@"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# Fails fast on a missing kubectl or context.
command -v kubectl >/dev/null || { echo "kubectl not found: install it" >&2; exit 1; }
k config get-contexts "$CONTEXT" >/dev/null 2>&1 || {
  echo "context $CONTEXT not found: run init_1_create_cluster.sh" >&2
  exit 1
}

# Deletes everything inspector_2_deploy.sh created and waits until it is gone.
step "delete ns inspect"
k delete namespace inspect --ignore-not-found --wait
