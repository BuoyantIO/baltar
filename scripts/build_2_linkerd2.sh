#!/usr/bin/env bash
# Loads the shared build helpers.
# shellcheck source=scripts/util_build.sh
. scripts/util_build.sh

# Run from the baltar repo root.
# Usage: ./scripts/build_2_linkerd2.sh
#        LINKERD2_REF=<branch|sha|pull/<n>/head> ./scripts/build_2_linkerd2.sh
#        LINKERD2_DIR=/path/to/linkerd2 BUILD_OUT_DIR=/path/to/out ./scripts/build_2_linkerd2.sh
#
# Env vars and defaults:
#   LINKERD2_DIR     ../linkerd2 beside this baltar checkout
#   LINKERD2_REF     pull/15676/head (the PR branch lives in a fork)
#   DOCKER_REGISTRY  localhost/linkerd (the justfile default is random per run)
#   BUILD_OUT_DIR    out/ in the baltar checkout (from util_build.sh)
#
# Build step 2 (after build_1_proxy.sh): builds linkerd2's images and CLI, overlays the PR proxy, writes images.env.
# The overlay is needed because `just linkerd-build` bakes in a released proxy binary.
set -euo pipefail

# Applies env defaults.
LINKERD2_DIR=${LINKERD2_DIR:-$(cd .. && pwd)/linkerd2}
LINKERD2_REF=${LINKERD2_REF:-pull/15676/head}
DOCKER_REGISTRY=${DOCKER_REGISTRY:-localhost/linkerd}

# Fails fast on a missing tool or repo checkout.
require_tools
require_repo "$LINKERD2_DIR" linkerd2

# Reads step 1's hand-off, failing before the checkout and long build if it is missing.
LINKERD2_PROXY_SHA=$(read_env proxy.env LINKERD2_PROXY_SHA)
PROXY_BUILD_IMAGE=$(read_env proxy.env PROXY_BUILD_IMAGE)
docker image inspect "$PROXY_BUILD_IMAGE" >/dev/null

# Detaches the linkerd2 repo at the requested ref.
read -r LINKERD2_SHA LINKERD2_SHORT_SHA < <(checkout_ref "$LINKERD2_DIR" "$LINKERD2_REF")
echo "building linkerd2 $LINKERD2_SHA ($LINKERD2_REF)" >&2

# Runs the justfile's bin/root-tag on the host, which sees the same detached HEAD.
LINKERD_TAG=$(cd "$LINKERD2_DIR" && bin/root-tag)

# Starts the linkerd2 repo's devcontainer.
devcontainer_up "$LINKERD2_DIR"

# Passes DOCKER_REGISTRY via `env`: the devcontainer does not inherit our environment.
devcontainer_exec "$LINKERD2_DIR" \
  env "DOCKER_REGISTRY=$DOCKER_REGISTRY" \
  just linkerd-build

# Takes the CLI path from bin/build-cli-bin's last line: its os-arch suffix depends on the container.
CLI_REL=$(devcontainer_exec "$LINKERD2_DIR" bin/build-cli-bin | tail -n 1)

# Confirms the controller image, proxy-init image and CLI exist.
CONTROLLER_IMAGE=$DOCKER_REGISTRY/controller:$LINKERD_TAG
PROXY_INIT_IMAGE=$DOCKER_REGISTRY/proxy:$LINKERD_TAG
LINKERD_CLI=$LINKERD2_DIR/$CLI_REL
docker image inspect "$CONTROLLER_IMAGE" >/dev/null
docker image inspect "$PROXY_INIT_IMAGE" >/dev/null
[ -x "$LINKERD_CLI" ] || { echo "missing CLI binary: $LINKERD_CLI" >&2; exit 1; }

# Tags the overlay image with both short SHAs, tying it to the two source trees.
PROXY_IMAGE=$DOCKER_REGISTRY/proxy:custom-$LINKERD2_SHORT_SHA-proxy-${LINKERD2_PROXY_SHA:0:7}

# Builds the overlay image from a stdin Dockerfile that copies in only the PR proxy binary.
# Copying more would replace linkerd2's identity and validator helpers.
OVERLAY_DOCKERFILE="FROM $PROXY_INIT_IMAGE
COPY --from=$PROXY_BUILD_IMAGE /usr/lib/linkerd/linkerd2-proxy /usr/lib/linkerd/linkerd2-proxy
"
# SC2016: printf expands in the container shell, as the devcontainer wrapper cannot forward our stdin.
# shellcheck disable=SC2016
devcontainer_exec "$LINKERD2_DIR" sh -c '
  printf "%s" "$1" | docker buildx build --platform=linux/amd64 --load --tag "$2" -
' sh "$OVERLAY_DOCKERFILE" "$PROXY_IMAGE"
docker image inspect "$PROXY_IMAGE" >/dev/null

# Hands the build off to build_5_verify_linkerd2.sh and the repro scripts.
write_env images.env \
  "LINKERD2_SHA=$LINKERD2_SHA" \
  "LINKERD2_PROXY_SHA=$LINKERD2_PROXY_SHA" \
  "LINKERD_TAG=$LINKERD_TAG" \
  "CONTROLLER_IMAGE=$CONTROLLER_IMAGE" \
  "PROXY_IMAGE=$PROXY_IMAGE" \
  "PROXY_INIT_IMAGE=$PROXY_INIT_IMAGE" \
  "LINKERD_CLI=$LINKERD_CLI"
echo "wrote $BUILD_OUT_DIR/images.env" >&2
