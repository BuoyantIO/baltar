#!/usr/bin/env bash
# Usage: ./init_0_prerequisites.sh
#
# Checks that this machine can run the init_ modules before any of them
# starts.
#
# A rebuild that dies halfway leaves a cluster that is neither the old
# one nor the new one, so the task 4 entrypoint gates on this: it exits
# non-zero when anything REQUIRED is missing and zero otherwise.
#
# The inspect_<n>_ prefix marks a read-only script. It changes nothing:
# every command here reads a version, the docker daemon or the kind
# cluster list, and nothing is created, patched or deleted.
#
# Required means the init_ modules shell out to it. Optional means only
# the load_, inspect_ or pf_ scripts do, so a rebuild succeeds without
# it. The pf_ scripts prefer pbcopy and open but fall back to xclip/xsel
# and xdg-open on Linux, so they are reported as optional, not required;
# this repo targets a Linux VM later, so those are reported n/a rather
# than missing when the host is not Darwin.
set -euo pipefail

OS="$(uname -s)"
MISSING_REQUIRED=0
MISSING_OPTIONAL=0
YQ_MISSING=0

# Each tool carries its own version command rather than assuming that
# --version works.
#
# Version flags differ per tool and some print to stderr.
version_of() {
  local BIN="$1"
  case "$BIN" in
    kind)       kind --version ;;
    kubectl)    kubectl version --client 2>/dev/null | head -1 ;;
    helm)       helm version --short ;;
    linkerd)    linkerd version --client --short ;;
    curl)       curl --version | head -1 ;;
    yq)         yq --version ;;
    docker)     docker --version ;;
    jq)         jq --version ;;
    python3)    python3 --version ;;
    bombardier) bombardier --version 2>&1 | head -1 ;;
    step)       step version | head -1 ;;
    *)          echo "" ;;  # base64, pbcopy, open report no useful version
  esac
}

# $1 = binary, $2 = REQUIRED|OPTIONAL|MACOS, $3 = which scripts need it.
check_bin() {
  local BIN="$1" TIER="$2" WHY="$3" VERSION=""

  # A macOS-only tool on Linux is reported as n/a, not as a finding.
  #
  # The pf_ scripts that use it do not run there at all.
  if [ "$TIER" = "MACOS" ] && [ "$OS" != "Darwin" ]; then
    printf '  %-12s n/a       %s (macOS-only, host is %s)\n' "$BIN" "$WHY" "$OS"
    return
  fi

  if command -v "$BIN" >/dev/null 2>&1; then
    VERSION="$(version_of "$BIN" 2>/dev/null | head -1 || true)"
    printf '  %-12s OK        %s\n' "$BIN" "${VERSION:-$WHY}"
    return
  fi

  if [ "$TIER" = "REQUIRED" ]; then
    printf '  %-12s MISSING   %s\n' "$BIN" "$WHY"
    MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
    # The yq flag is set with an `if`, not an `&&`.
    #
    # An `&&` here would return non-zero for every other binary and,
    # under set -e, abort the script on the first tool that is not yq.
    if [ "$BIN" = "yq" ]; then YQ_MISSING=1; fi
  else
    printf '  %-12s absent    %s\n' "$BIN" "$WHY"
    MISSING_OPTIONAL=$((MISSING_OPTIONAL + 1))
  fi
}

echo "=== 1. Required: binaries the init_ modules shell out to ==="
check_bin docker  REQUIRED "init_1 (kind needs a container runtime)"
check_bin kind    REQUIRED "init_1, cleanup_1"
check_bin kubectl REQUIRED "init_1 through init_7"
check_bin helm    REQUIRED "init_4, init_5, init_7"
check_bin linkerd REQUIRED "init_2, init_3"
check_bin curl    REQUIRED "init_4 (linkerd values.yaml), init_6 (emojivoto)"
check_bin yq      REQUIRED "init_4 only - see the yq note below"

echo
echo "=== 2. Optional: binaries only the load_, inspect_ and pf_ scripts need ==="
check_bin bombardier OPTIONAL "test_load_1 only; load_2 runs it as a container instead"
check_bin jq         OPTIONAL "wip_1 (parses Prometheus query results)"
check_bin python3    OPTIONAL "wip_4 (samples proxy metrics, summarises the run)"
check_bin step       OPTIONAL "init_2_install_bel (generates the BEL trust anchor and issuer)"
check_bin base64     OPTIONAL "pf_2 (decodes the grafana admin password)"
check_bin pbcopy     MACOS    "pf_2, pf_3"
check_bin open       MACOS    "pf_2, pf_3"

echo
echo "=== 3. The yq trap ==="
# yq gets a section of its own.
#
# It is the one failure this whole script exists to prevent: yq ships
# with neither macOS nor most Linux images, and init_4 is the only
# module that uses it. Without this check a rebuild gets as far as
# pulling the grafana chart and recreating the grafana namespace before
# dying on a missing binary.
if [ "$YQ_MISSING" = "1" ]; then
  echo "  yq is MISSING. init_4 pulls the grafana chart and DELETES the"
  echo "  grafana namespace before it reaches the yq lines, so the rebuild"
  echo "  fails with the namespace already gone. Install it first:"
  echo "    brew install yq   # or: https://github.com/mikefarah/yq"
elif command -v yq >/dev/null 2>&1; then
  # We check which of the two yq implementations this is.
  #
  # Two unrelated tools are called yq. init_4 uses `yq -i '.[...]...'`,
  # which is mikefarah's Go implementation; the python wrapper of the
  # same name takes different arguments and would fail there.
  if yq --version 2>&1 | grep -q 'mikefarah'; then
    echo "  OK: mikefarah yq, which is the flavour init_4's -i syntax needs."
  else
    echo "  WARNING: this yq is not mikefarah's Go build. init_4 uses"
    echo "  \`yq -i '.[\"grafana.ini\"]...'\`, which the python yq does not accept."
  fi
fi

echo
echo "=== 4. Docker daemon ==="
# We check that the daemon answers, not only that docker is installed.
#
# Installed is not the same as running: kind create cluster fails on a
# stopped Docker Desktop with an error that does not say so plainly.
if ! command -v docker >/dev/null 2>&1; then
  echo "  skipped: docker is not installed"
elif docker info >/dev/null 2>&1; then
  echo "  OK: daemon responding, server $(docker info --format '{{.ServerVersion}}' 2>/dev/null)"
else
  echo "  NOT RUNNING: docker is installed but the daemon is not answering."
  echo "  init_1 cannot create a kind cluster until it is started."
  MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
fi

echo
echo "=== 5. Linkerd CLI extensions ==="
# We check that `linkerd viz` resolves.
#
# init_3 calls `linkerd viz install`. viz is a subcommand of the main
# CLI in current releases, but the CLI also resolves extensions from
# PATH, so an older or partial install can have `linkerd` without
# `linkerd viz`.
if ! command -v linkerd >/dev/null 2>&1; then
  echo "  skipped: linkerd is not installed"
elif linkerd viz --help >/dev/null 2>&1; then
  echo "  OK: \`linkerd viz\` resolves, which is what init_3 installs with"
else
  echo "  MISSING: \`linkerd viz\` does not resolve. init_3 will fail."
  MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
fi

echo
echo "=== 6. Existing kind cluster ==="
# An existing cluster is reported, not acted on.
#
# init_1 runs a bare `kind create cluster` and fails if one already
# exists, by design: this script says so up front instead of letting the
# rebuild discover it.
if ! command -v kind >/dev/null 2>&1; then
  echo "  skipped: kind is not installed"
else
  CLUSTERS="$(kind get clusters 2>/dev/null || true)"
  if [ -z "$CLUSTERS" ]; then
    echo "  none. init_1 will create 'kind' from scratch."
  else
    echo "  present: $(echo "$CLUSTERS" | tr '\n' ' ')"
    echo "  init_1's \`kind create cluster\` will FAIL against an existing"
    echo "  cluster named 'kind'. Run cleanup_1_cluster.sh first if a"
    echo "  from-scratch rebuild is what you want. Not an error here."
  fi
fi

echo
echo "=== 7. Summary ==="
if [ "$MISSING_REQUIRED" -gt 0 ]; then
  echo "  FAIL: $MISSING_REQUIRED required prerequisite(s) missing. Do not start a rebuild."
  exit 1
fi
echo "  PASS: every prerequisite the init_ modules need is present."
[ "$MISSING_OPTIONAL" -gt 0 ] && echo "  ($MISSING_OPTIONAL optional tool(s) absent: the rebuild works, some load_/inspect_/pf_ scripts do not.)"
exit 0
