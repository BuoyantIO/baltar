#!/usr/bin/env bash
# Loads read_env and BUILD_OUT_DIR.
# shellcheck source=scripts/util_build.sh
. scripts/util_build.sh

# Run from the baltar repo root.
# Usage: ./scripts/build_3_install_custom_linkerd.sh
#        BUILD_OUT_DIR=/path/to/out ./scripts/build_3_install_custom_linkerd.sh
#        CLUSTER_NAME=east ./scripts/build_3_install_custom_linkerd.sh
#
# Env vars and defaults:
#   BUILD_OUT_DIR  out/ in the baltar checkout (from util_build.sh)
#   CLUSTER_NAME   kind
#
# Build step 3 (after init_1_create_cluster.sh, build_2_linkerd2.sh): installs Linkerd from the custom build.
# PROXY_INIT_IMAGE is unused: linkerd-init renders from proxy.image, which contains proxy-init.
set -euo pipefail

# Targets the cluster from init_1_create_cluster.sh, which names its context kind-<name>.
CLUSTER_NAME=${CLUSTER_NAME:-kind}
KUBE_CONTEXT=kind-$CLUSTER_NAME

# read_env fails on a missing file or key, so a skipped build stops here.
CONTROLLER_IMAGE=$(read_env images.env CONTROLLER_IMAGE)
PROXY_IMAGE=$(read_env images.env PROXY_IMAGE)
LINKERD_CLI=$(read_env images.env LINKERD_CLI)
[ -x "$LINKERD_CLI" ] || { echo "linkerd CLI not executable: $LINKERD_CLI" >&2; exit 1; }

# Loads the localhost/ images into kind; the chart's IfNotPresent policy then never pulls.
kind load docker-image --name "$CLUSTER_NAME" "$CONTROLLER_IMAGE" "$PROXY_IMAGE"

# Checks the cluster meets Linkerd's prerequisites.
"$LINKERD_CLI" --context "$KUBE_CONTEXT" check --pre

# Installs the Linkerd CRDs.
"$LINKERD_CLI" --context "$KUBE_CONTEXT" install --crds \
  | kubectl --context "$KUBE_CONTEXT" apply -f -

# Points every image at the custom build; controllerImage also covers the policy container.
# --set-string keeps a numeric-looking tag a string.
"$LINKERD_CLI" --context "$KUBE_CONTEXT" install \
  --set-string "controllerImage=${CONTROLLER_IMAGE%:*}" \
  --set-string "controllerImageVersion=${CONTROLLER_IMAGE##*:}" \
  --set-string "proxy.image.name=${PROXY_IMAGE%:*}" \
  --set-string "proxy.image.version=${PROXY_IMAGE##*:}" \
  | kubectl --context "$KUBE_CONTEXT" apply -f -

# Blocks until the control plane is healthy.
"$LINKERD_CLI" --context "$KUBE_CONTEXT" check
