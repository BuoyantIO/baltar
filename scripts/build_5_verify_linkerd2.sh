#!/usr/bin/env bash
# Loads read_env and BUILD_OUT_DIR.
# shellcheck source=scripts/util_build.sh
. scripts/util_build.sh

# Run from the launchy-dev repo root.
# Usage: ./scripts/build_5_verify_linkerd2.sh
#        BUILD_OUT_DIR=/path/to/out ./scripts/build_5_verify_linkerd2.sh
#
# Env vars and defaults:
#   BUILD_OUT_DIR  out/ in the launchy-dev checkout (from util_build.sh)
#
# Build step 5. Reads $BUILD_OUT_DIR/images.env from build_2_linkerd2.sh
# and proxy.env from build_1_proxy.sh. Checks that the linkerd2 images
# exist, the CLI reports the build tag, the CLI and the controller binary
# contain the PROXY protocol v2 annotation key, and the proxy image carries
# the custom proxy binary. A true render with `linkerd inject` needs cluster
# config, so it is deferred to checklist_repro_proxy_protocol. Prints
# one line per check and exits non-zero if any check fails.
#
# The CLI is a linux/amd64 binary built for the VM. On macOS the CLI
# checks cannot run and fail; run this script on the VM.
#
# Reads images only. Binaries are copied out with `docker create` and
# `docker cp` and hashed on the host: the proxy image is minimal, so
# `sha256sum` may be absent inside it.
set -euo pipefail

BIN_PATH=/usr/lib/linkerd/linkerd2-proxy
ANNOTATION=config.linkerd.io/proxy-protocol-v2-inbound-ports
CONTROLLER_BIN=/controller

command -v docker >/dev/null 2>&1 || { echo "missing: docker" >&2; exit 1; }

LINKERD_TAG=$(read_env images.env LINKERD_TAG)
CONTROLLER_IMAGE=$(read_env images.env CONTROLLER_IMAGE)
PROXY_IMAGE=$(read_env images.env PROXY_IMAGE)
PROXY_INIT_IMAGE=$(read_env images.env PROXY_INIT_IMAGE)
LINKERD_CLI=$(read_env images.env LINKERD_CLI)
PROXY_BUILD_IMAGE=$(read_env proxy.env PROXY_BUILD_IMAGE)

# Container ids live in a file, not an array: bin_sum runs in a command substitution
# subshell, so array appends there never reach the trap and the containers leak.
CID_FILE=$(mktemp)
# shellcheck disable=SC2329 # invoked via trap
cleanup() {
  local c
  while read -r c; do
    [ -z "$c" ] || docker rm -f "$c" >/dev/null 2>&1 || true
  done <"$CID_FILE"
  rm -f "$CID_FILE"
}
trap cleanup EXIT

FAILED=0
# Prints one check line and records a failure: report <PASS|FAIL|INFO> <name> <detail>.
report() {
  printf '%s %s: %s\n' "$1" "$2" "$3"
  [ "$1" != FAIL ] || FAILED=1
}

# Prints the sha256 of the proxy binary in image $1; fails if it cannot be read.
bin_sum() {
  local cid tmp sum
  cid=$(docker create "$1") || return 1
  echo "$cid" >>"$CID_FILE"
  tmp=$(mktemp)
  if ! docker cp "$cid:$BIN_PATH" "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  sum=$(shasum -a 256 "$tmp" | cut -d' ' -f1)
  rm -f "$tmp"
  echo "$sum"
}

# Images check: a missing image means the build did not finish or was pruned.
IMAGES_OK=1
for img in "$CONTROLLER_IMAGE" "$PROXY_IMAGE" "$PROXY_INIT_IMAGE" "$PROXY_BUILD_IMAGE"; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    report PASS images "$img exists"
  else
    report FAIL images "$img not found"
    IMAGES_OK=0
  fi
done

# CLI check: the tag ties the binary to the images; a stale CLI renders a stale proxy config.
if [ ! -x "$LINKERD_CLI" ]; then
  report FAIL cli "$LINKERD_CLI missing or not executable"
elif CLI_VERSION=$("$LINKERD_CLI" version --client --short 2>&1); then
  if [ "$CLI_VERSION" = "$LINKERD_TAG" ]; then
    report PASS cli "version $CLI_VERSION"
  else
    report FAIL cli "version '$CLI_VERSION' != $LINKERD_TAG"
  fi
else
  report FAIL cli "cannot run $LINKERD_CLI: $CLI_VERSION"
fi

# Annotation checks: offline proof that the PR is compiled in, as `inject` needs a cluster.
# Only binaries built from the PR contain the annotation key; stock builds do not.
# The controller image holds the proxy-injector webhook in /controller (Dockerfile.controller).
if [ -x "$LINKERD_CLI" ]; then
  if grep -c -a -F -q -- "$ANNOTATION" "$LINKERD_CLI"; then
    report PASS cli-annotation "$LINKERD_CLI contains $ANNOTATION"
  else
    report FAIL cli-annotation "$LINKERD_CLI lacks $ANNOTATION"
  fi
else
  report FAIL cli-annotation "$LINKERD_CLI missing or not executable"
fi
if [ "$IMAGES_OK" -eq 1 ]; then
  if CTRL_TMP=$(mktemp) && CTRL_CID=$(docker create "$CONTROLLER_IMAGE") \
    && { echo "$CTRL_CID" >>"$CID_FILE"; docker cp "$CTRL_CID:$CONTROLLER_BIN" "$CTRL_TMP" >/dev/null 2>&1; }; then
    if grep -c -a -F -q -- "$ANNOTATION" "$CTRL_TMP"; then
      report PASS controller-annotation "$CONTROLLER_IMAGE:$CONTROLLER_BIN contains $ANNOTATION"
    else
      report FAIL controller-annotation "$CONTROLLER_IMAGE:$CONTROLLER_BIN lacks $ANNOTATION"
    fi
  else
    report FAIL controller-annotation "cannot read $CONTROLLER_BIN from $CONTROLLER_IMAGE"
  fi
  rm -f "${CTRL_TMP:-}"
else
  report FAIL controller-annotation "skipped: an image is missing"
fi

# Overlay check: the proxy image must hold the PR-built binary, not the one linkerd2 fetched.
if [ "$IMAGES_OK" -eq 1 ]; then
  if OVERLAY_SUM=$(bin_sum "$PROXY_IMAGE") && BUILD_SUM=$(bin_sum "$PROXY_BUILD_IMAGE") \
    && INIT_SUM=$(bin_sum "$PROXY_INIT_IMAGE"); then
    if [ "$OVERLAY_SUM" = "$BUILD_SUM" ]; then
      report PASS overlay "proxy image binary equals build image binary $BUILD_SUM"
    else
      report FAIL overlay "proxy image binary $OVERLAY_SUM != build image $BUILD_SUM"
    fi
    if [ "$OVERLAY_SUM" != "$INIT_SUM" ]; then
      report PASS overlay "proxy image binary differs from init image $INIT_SUM"
    else
      report FAIL overlay "proxy image binary equals init image binary $INIT_SUM"
    fi
  else
    report FAIL overlay "cannot read $BIN_PATH from an image"
  fi
else
  report FAIL overlay "skipped: an image is missing"
fi

exit "$FAILED"
