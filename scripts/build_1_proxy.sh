#!/usr/bin/env bash
# Usage: ./build_1_proxy.sh
#        LINKERD2_PROXY_REF=<branch|sha|pull/<n>/head> ./build_1_proxy.sh
#        LINKERD2_PROXY_DIR=/path/to/linkerd2-proxy BUILD_OUT_DIR=/path/to/out ./build_1_proxy.sh
#
# Env vars and defaults:
#   LINKERD2_PROXY_DIR  ../linkerd2-proxy beside this launchy-dev checkout
#   LINKERD2_PROXY_REF  pull/4625/head
#   LINKERD_TAG         edge-25.11.3
#   BUILD_OUT_DIR       out/ in the launchy-dev checkout (from util_build.sh)
#
# Build step 1. Checks out the proxy ref, builds the proxy image with
# `just docker` in the repo's devcontainer, and writes
# $BUILD_OUT_DIR/proxy.env for verify_1_proxy.sh and build_2_linkerd2.sh.
#
# The ref defaults to pull/4625/head, not the PR branch name: the branch
# lives in a fork and is absent from linkerd/linkerd2-proxy.
#
# LINKERD_TAG is set explicitly because the justfile otherwise resolves
# it from the GitHub releases API, which makes a build depend on the
# network and on rate limits. The default is the tag that the proxy
# Dockerfile uses for its own LINKERD2_IMAGE default, so the base image
# is the one the repo already builds against. The justfile fixes the base
# as ghcr.io/linkerd/proxy:$LINKERD_TAG.
#
# The image is named localhost/linkerd/proxy:custom-<short-sha>. The
# justfile default tag embeds the branch name, and a detached checkout
# makes that "HEAD"; a fixed name with the SHA is stable and traceable.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=util_build.sh
. "$SCRIPT_DIR/util_build.sh"

LINKERD2_PROXY_DIR=${LINKERD2_PROXY_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)/linkerd2-proxy}
LINKERD2_PROXY_REF=${LINKERD2_PROXY_REF:-pull/4625/head}
LINKERD_TAG=${LINKERD_TAG:-edge-25.11.3}

require_tools
require_repo "$LINKERD2_PROXY_DIR" linkerd2-proxy

read -r PROXY_FULL_SHA PROXY_SHORT_SHA < <(checkout_ref "$LINKERD2_PROXY_DIR" "$LINKERD2_PROXY_REF")
echo "building linkerd2-proxy $PROXY_FULL_SHA ($LINKERD2_PROXY_REF)" >&2

DOCKER_REPO=localhost/linkerd/proxy
DOCKER_TAG=custom-$PROXY_SHORT_SHA

devcontainer_up "$LINKERD2_PROXY_DIR"

# `env` carries LINKERD_TAG into the container: the justfile reads it
# with env_var_or_default, and the devcontainer does not inherit ours.
devcontainer_exec "$LINKERD2_PROXY_DIR" \
  env "LINKERD_TAG=$LINKERD_TAG" \
  just "docker-repo=$DOCKER_REPO" "docker-tag=$DOCKER_TAG" docker

PROXY_BUILD_IMAGE=$DOCKER_REPO:$DOCKER_TAG
docker image inspect "$PROXY_BUILD_IMAGE" >/dev/null

write_env proxy.env \
  "LINKERD2_PROXY_SHA=$PROXY_FULL_SHA" \
  "PROXY_BUILD_IMAGE=$PROXY_BUILD_IMAGE" \
  "PROXY_BASE_IMAGE=ghcr.io/linkerd/proxy:$LINKERD_TAG"
echo "wrote $BUILD_OUT_DIR/proxy.env" >&2
