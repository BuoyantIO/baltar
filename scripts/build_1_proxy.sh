#!/usr/bin/env bash
# Usage: ./build_1_proxy.sh
#        LINKERD2_PROXY_REF=<branch|sha|pull/<n>/head> ./build_1_proxy.sh
#        LINKERD2_PROXY_DIR=/path/to/linkerd2-proxy BUILD_OUT_DIR=/path/to/out ./build_1_proxy.sh
#
# Env vars and defaults:
#   LINKERD2_PROXY_DIR  ../linkerd2-proxy beside this launchy-dev checkout
#   LINKERD2_PROXY_REF  pull/4625/head (the PR branch lives in a fork)
#   LINKERD_TAG         edge-25.11.3, the proxy Dockerfile's base tag (set so the justfile skips the GitHub API)
#   BUILD_OUT_DIR       out/ in the launchy-dev checkout (from util_build.sh)
#
# Build step 1: builds localhost/linkerd/proxy:custom-<short-sha> in the devcontainer and writes proxy.env.
# The SHA tag replaces the justfile default, which embeds the branch name and so reads "HEAD" when detached.
set -euo pipefail

# Loads the shared build helpers.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=util_build.sh
. "$SCRIPT_DIR/util_build.sh"

# Applies env defaults.
LINKERD2_PROXY_DIR=${LINKERD2_PROXY_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)/linkerd2-proxy}
LINKERD2_PROXY_REF=${LINKERD2_PROXY_REF:-pull/4625/head}
LINKERD_TAG=${LINKERD_TAG:-edge-25.11.3}

# Fails fast on a missing tool or repo checkout.
require_tools
require_repo "$LINKERD2_PROXY_DIR" linkerd2-proxy

# Detaches the proxy repo at the requested ref.
read -r PROXY_FULL_SHA PROXY_SHORT_SHA < <(checkout_ref "$LINKERD2_PROXY_DIR" "$LINKERD2_PROXY_REF")
echo "building linkerd2-proxy $PROXY_FULL_SHA ($LINKERD2_PROXY_REF)" >&2

# Names the image after the proxy commit.
DOCKER_REPO=localhost/linkerd/proxy
DOCKER_TAG=custom-$PROXY_SHORT_SHA

# Starts the proxy repo's devcontainer.
devcontainer_up "$LINKERD2_PROXY_DIR"

# Passes LINKERD_TAG via `env`: the devcontainer does not inherit our environment.
devcontainer_exec "$LINKERD2_PROXY_DIR" \
  env "LINKERD_TAG=$LINKERD_TAG" \
  just "docker-repo=$DOCKER_REPO" "docker-tag=$DOCKER_TAG" docker

# Confirms the image exists locally.
PROXY_BUILD_IMAGE=$DOCKER_REPO:$DOCKER_TAG
docker image inspect "$PROXY_BUILD_IMAGE" >/dev/null

# Hands the build off to build_4_verify_proxy.sh and build_2_linkerd2.sh.
write_env proxy.env \
  "LINKERD2_PROXY_SHA=$PROXY_FULL_SHA" \
  "PROXY_BUILD_IMAGE=$PROXY_BUILD_IMAGE" \
  "PROXY_BASE_IMAGE=ghcr.io/linkerd/proxy:$LINKERD_TAG"
echo "wrote $BUILD_OUT_DIR/proxy.env" >&2
