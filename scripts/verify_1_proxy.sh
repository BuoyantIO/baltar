#!/usr/bin/env bash
# Usage: ./verify_1_proxy.sh
#        BUILD_OUT_DIR=/path/to/out ./verify_1_proxy.sh
#
# Env vars and defaults:
#   BUILD_OUT_DIR  out/ in the launchy-dev checkout (from util_build.sh)
#
# Verify step 1. Reads $BUILD_OUT_DIR/proxy.env from build_1_proxy.sh and
# checks the custom proxy image: it differs from the base image, carries
# the PROXY protocol v2 feature, and ties to LINKERD2_PROXY_SHA. Prints
# one line per check and exits non-zero if any check fails.
#
# Reads images only. The binary is copied out with `docker create` and
# `docker cp` and searched on the host: the proxy image is minimal, so
# `strings` or `grep` may be absent inside it.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=util_build.sh
. "$SCRIPT_DIR/util_build.sh"

BIN_PATH=/usr/lib/linkerd/linkerd2-proxy
FEATURE_STRING=LINKERD2_PROXY_INBOUND_PORTS_PROXY_PROTOCOL_V2

command -v docker >/dev/null 2>&1 || { echo "missing: docker" >&2; exit 1; }

PROXY_SHA=$(read_env proxy.env LINKERD2_PROXY_SHA)
BUILD_IMAGE=$(read_env proxy.env PROXY_BUILD_IMAGE)
BASE_IMAGE=$(read_env proxy.env PROXY_BASE_IMAGE)

WORK=$(mktemp -d)
CIDS=()
# shellcheck disable=SC2329 # invoked via trap
cleanup() {
  local c
  # The ${CIDS[@]+...} form avoids an unbound-variable error on an empty array in bash 3.2.
  for c in ${CIDS[@]+"${CIDS[@]}"}; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

FAILED=0
# Prints one check line and records a failure: report <PASS|FAIL|INFO> <name> <detail>.
report() {
  printf '%s %s: %s\n' "$1" "$2" "$3"
  [ "$1" != FAIL ] || FAILED=1
}

# Copies the proxy binary of image $1 to the host path $2.
extract_bin() {
  local cid
  cid=$(docker create "$1")
  CIDS+=("$cid")
  docker cp "$cid:$BIN_PATH" "$2" >/dev/null
}

# Image check: both binaries must exist and differ, else the build copied nothing new.
if ! docker image inspect "$BUILD_IMAGE" >/dev/null 2>&1; then
  report FAIL image "$BUILD_IMAGE not found"
  exit 1
fi
if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
  docker pull "$BASE_IMAGE" >/dev/null 2>&1 || true
fi
extract_bin "$BUILD_IMAGE" "$WORK/build.bin"
BUILD_SUM=$(shasum -a 256 "$WORK/build.bin" | cut -d' ' -f1)
if extract_bin "$BASE_IMAGE" "$WORK/base.bin" 2>/dev/null; then
  BASE_SUM=$(shasum -a 256 "$WORK/base.bin" | cut -d' ' -f1)
  if [ "$BUILD_SUM" != "$BASE_SUM" ]; then
    report PASS image "build $BUILD_SUM differs from base $BASE_SUM"
  else
    report FAIL image "build binary equals base binary $BASE_SUM"
  fi
else
  report FAIL image "cannot read $BIN_PATH from base image $BASE_IMAGE"
fi

# Feature check: the env var name is only in binaries built with the PR change.
if grep -a -c -F "$FEATURE_STRING" "$WORK/build.bin" >/dev/null; then
  report PASS feature "binary contains $FEATURE_STRING"
else
  report FAIL feature "binary lacks $FEATURE_STRING"
fi

# Provenance check: image label first, then the SHA embedded in the binary.
# Neither is guaranteed to exist; absence is reported, not failed, since
# nothing then contradicts the SHA.
LABEL_REV=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$BUILD_IMAGE" 2>/dev/null || true)
SHORT_SHA=${PROXY_SHA:0:7}
if [ -n "$LABEL_REV" ] && [ "$LABEL_REV" != "<no value>" ]; then
  if [ "$LABEL_REV" = "$PROXY_SHA" ]; then
    report PASS provenance "image label revision matches $PROXY_SHA"
  else
    report FAIL provenance "image label revision $LABEL_REV != $PROXY_SHA"
  fi
elif grep -a -c -F "$PROXY_SHA" "$WORK/build.bin" >/dev/null; then
  report PASS provenance "binary embeds full SHA $PROXY_SHA"
elif grep -a -c -F "$SHORT_SHA" "$WORK/build.bin" >/dev/null; then
  report PASS provenance "binary embeds short SHA $SHORT_SHA"
else
  report INFO provenance "SHA not exposed by image label or binary; $PROXY_SHA unverified (image tag ends in custom-$SHORT_SHA)"
fi

exit "$FAILED"
