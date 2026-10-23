#!/usr/bin/env bash
# Loads build_overlay.
# shellcheck source=scripts/util_build.sh
. scripts/util_build.sh

# Run from the baltar repo root.
# Usage: BASE_IMAGE=cr.l5d.io/linkerd/proxy:edge-26.6.3 OVERLAY_TAG=localhost/linkerd/proxy:fix15731 \
#          LOCAL_FILES=../linkerd2-proxy-init/linkerd2-proxy-init=/usr/lib/linkerd/linkerd2-proxy-init \
#          SETCAP_PATH=/usr/lib/linkerd/linkerd2-proxy-init CLUSTER_NAME=kind ./scripts/build_6_overlay_proxy.sh
#        BASE_IMAGE=cr.l5d.io/linkerd/proxy:edge-26.6.3 OVERLAY_TAG=localhost/linkerd/proxy:sysctl \
#          COPY_FROM_IMAGE=<image with procps> COPY_PATHS=/usr/bin/sysctl ./scripts/build_6_overlay_proxy.sh
#
# Env vars and defaults:
#   BASE_IMAGE       required: image to overlay
#   OVERLAY_TAG      required: tag of the built image, <name>:<version>
#   COPY_FROM_IMAGE  empty: image COPY_PATHS are taken from
#   COPY_PATHS       empty: space-separated paths, copied to the same path
#   LOCAL_FILES      empty: space-separated src=dest host files
#   SETCAP_PATH      empty: file given cap_net_raw,cap_net_admin+eip after the copies
#   CLUSTER_NAME     empty: kind cluster to load the image into; unset skips the load
#
# Builds a proxy overlay image and prints the --set args for dev_10_linkerd_upgrade.sh.
set -euo pipefail

# Applies env defaults.
BASE_IMAGE=${BASE_IMAGE:?usage: see header}
OVERLAY_TAG=${OVERLAY_TAG:?usage: see header}
COPY_FROM_IMAGE=${COPY_FROM_IMAGE:-}
COPY_PATHS=${COPY_PATHS:-}
LOCAL_FILES=${LOCAL_FILES:-}
SETCAP_PATH=${SETCAP_PATH:-}
CLUSTER_NAME=${CLUSTER_NAME:-}

# Builds the overlay on the host docker.
echo "[-] build $OVERLAY_TAG"
build_overlay "$BASE_IMAGE" "$OVERLAY_TAG" "$COPY_FROM_IMAGE" "$COPY_PATHS" "$LOCAL_FILES" "$SETCAP_PATH"

# Loads the image into kind; the IfNotPresent policy printed below then never pulls.
if [ -n "$CLUSTER_NAME" ]; then
  echo "[-] kind load $OVERLAY_TAG into $CLUSTER_NAME"
  kind load docker-image --name "$CLUSTER_NAME" "$OVERLAY_TAG"
fi

# Prints the args for dev_10_linkerd_upgrade.sh.
echo "proxy.image.name=${OVERLAY_TAG%:*} proxy.image.version=${OVERLAY_TAG##*:} proxy.image.pullPolicy=IfNotPresent"
