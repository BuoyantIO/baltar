#!/usr/bin/env bash
# Usage: ./build_2_linkerd2.sh
#        LINKERD2_REF=<branch|sha|pull/<n>/head> ./build_2_linkerd2.sh
#        LINKERD2_DIR=/path/to/linkerd2 BUILD_OUT_DIR=/path/to/out ./build_2_linkerd2.sh
#
# Env vars and defaults:
#   LINKERD2_DIR     ../linkerd2 beside this launchy-dev checkout
#   LINKERD2_REF     pull/15676/head
#   DOCKER_REGISTRY  localhost/linkerd
#   BUILD_OUT_DIR    out/ in the launchy-dev checkout (from util_build.sh)
#
# Build step 2. Needs $BUILD_OUT_DIR/proxy.env from build_1_proxy.sh.
# Checks out the linkerd2 ref, builds the controller image, the proxy
# image and the CLI in the repo's devcontainer, overlays the custom proxy
# binary onto the proxy image, and writes $BUILD_OUT_DIR/images.env for
# verify_2_linkerd2.sh and the install step.
#
# The ref defaults to pull/15676/head, not the PR branch name: the branch
# lives in a fork and is absent from linkerd/linkerd2.
#
# DOCKER_REGISTRY is fixed because the justfile default is a random name
# per run, which would make the image names unreproducible.
#
# Overlay: `just linkerd-build` fetches a released proxy binary
# (bin/docker-build-proxy), so the PR-built binary is copied in on top.
# Only /usr/lib/linkerd/linkerd2-proxy is copied: the proxy repo's
# /out holds only that file, and copying anything else from the proxy
# image would replace linkerd2's own helpers (identity, validator).
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=util_build.sh
. "$SCRIPT_DIR/util_build.sh"

LINKERD2_DIR=${LINKERD2_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)/linkerd2}
LINKERD2_REF=${LINKERD2_REF:-pull/15676/head}
DOCKER_REGISTRY=${DOCKER_REGISTRY:-localhost/linkerd}

require_tools
require_repo "$LINKERD2_DIR" linkerd2

# Fail before the checkout and a long build if step 1 has not run.
LINKERD2_PROXY_SHA=$(read_env proxy.env LINKERD2_PROXY_SHA)
PROXY_BUILD_IMAGE=$(read_env proxy.env PROXY_BUILD_IMAGE)
docker image inspect "$PROXY_BUILD_IMAGE" >/dev/null

read -r LINKERD2_SHA LINKERD2_SHORT_SHA < <(checkout_ref "$LINKERD2_DIR" "$LINKERD2_REF")
echo "building linkerd2 $LINKERD2_SHA ($LINKERD2_REF)" >&2

# The tag comes from the same script the justfile uses, run on the host
# so it is known here; the host git sees the same detached HEAD.
LINKERD_TAG=$(cd "$LINKERD2_DIR" && bin/root-tag)

devcontainer_up "$LINKERD2_DIR"

# `env` carries DOCKER_REGISTRY into the container: the justfile and
# bin/docker-build-proxy read it, and the devcontainer does not inherit
# ours. The justfile derives its tag from bin/root-tag.
devcontainer_exec "$LINKERD2_DIR" \
  env "DOCKER_REGISTRY=$DOCKER_REGISTRY" \
  just linkerd-build

# bin/build-cli-bin builds for the container's os-arch (bin/_os.sh gives
# e.g. linux-amd64 or linux-arm64) and prints the repo-relative path as
# its last line, so the path is taken from it instead of being guessed.
CLI_REL=$(devcontainer_exec "$LINKERD2_DIR" bin/build-cli-bin | tail -n 1)

CONTROLLER_IMAGE=$DOCKER_REGISTRY/controller:$LINKERD_TAG
PROXY_INIT_IMAGE=$DOCKER_REGISTRY/proxy:$LINKERD_TAG
LINKERD_CLI=$LINKERD2_DIR/$CLI_REL
docker image inspect "$CONTROLLER_IMAGE" >/dev/null
docker image inspect "$PROXY_INIT_IMAGE" >/dev/null
[ -x "$LINKERD_CLI" ] || { echo "missing CLI binary: $LINKERD_CLI" >&2; exit 1; }

# Both short SHAs in the tag tie the image to the two source trees.
PROXY_IMAGE=$DOCKER_REGISTRY/proxy:custom-$LINKERD2_SHORT_SHA-proxy-${LINKERD2_PROXY_SHA:0:7}

# The Dockerfile goes in on stdin so no build context is needed and no
# file is written into either repo. printf runs in the container shell
# because the devcontainer wrapper cannot forward our stdin.
OVERLAY_DOCKERFILE="FROM $PROXY_INIT_IMAGE
COPY --from=$PROXY_BUILD_IMAGE /usr/lib/linkerd/linkerd2-proxy /usr/lib/linkerd/linkerd2-proxy
"
# SC2016: the snippet must expand in the container shell, not here.
# shellcheck disable=SC2016
devcontainer_exec "$LINKERD2_DIR" sh -c '
  printf "%s" "$1" | docker buildx build --platform=linux/amd64 --load --tag "$2" -
' sh "$OVERLAY_DOCKERFILE" "$PROXY_IMAGE"
docker image inspect "$PROXY_IMAGE" >/dev/null

write_env images.env \
  "LINKERD2_SHA=$LINKERD2_SHA" \
  "LINKERD2_PROXY_SHA=$LINKERD2_PROXY_SHA" \
  "LINKERD_TAG=$LINKERD_TAG" \
  "CONTROLLER_IMAGE=$CONTROLLER_IMAGE" \
  "PROXY_IMAGE=$PROXY_IMAGE" \
  "PROXY_INIT_IMAGE=$PROXY_INIT_IMAGE" \
  "LINKERD_CLI=$LINKERD_CLI"
echo "wrote $BUILD_OUT_DIR/images.env" >&2
