#!/usr/bin/env bash
# Usage: ./inspector_pipeline.sh
#        KEEP=1 ./inspector_pipeline.sh
#        INSPECTOR_IMAGE=localhost/l4-proto-inspector:test ./inspector_pipeline.sh
#
# Inspector pipeline: runs every inspector check end to end and stops at the first broken stage.
# Stages: cargo test, build and load image, deploy fixture, positive assert (exit 0),
# negative assert with a wrong identity (exit 1), then cleanup on every exit path.
# Prints one summary line per stage and exits non-zero when any stage failed.
#
# Env vars and defaults:
#   CONTEXT=kind-kind kubectl context; inspector_2_deploy.sh and inspector_5_cleanup.sh only target kind-kind
#   INSPECTOR_IMAGE=localhost/l4-proto-inspector:dev image built, loaded and asserted against
#   KEEP= set to 1 to skip cleanup and leave ns inspect for debugging
set -euo pipefail

# Inputs with defaults; exported so the step scripts see them.
CONTEXT=${CONTEXT:-kind-kind}
INSPECTOR_IMAGE=${INSPECTOR_IMAGE:-localhost/l4-proto-inspector:dev}
KEEP=${KEEP:-}
export CONTEXT INSPECTOR_IMAGE

# Locates the step scripts and crate relative to this script, not the cwd.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CRATE_DIR="$SCRIPT_DIR/../l4_proto_inspector"

# Identity the negative stage expects, so pp_test must fail.
WRONG_ID=wrong.identity

# Stage names and results, parallel arrays since macOS bash 3.2 has no associative arrays.
STAGES=(cargo_test build_image deploy assert_pass assert_fail cleanup)
RESULTS=()

# Helpers: a bold stage banner, and a fatal prerequisite error.
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "$*" >&2; exit 1; }

# Fails fast on missing tools, crate, step scripts or a context the fixture scripts do not target.
for tool in cargo docker kind kubectl; do
  command -v "$tool" >/dev/null || die "missing tool: $tool (on the VM run via bash -lc)"
done
[ -f "$CRATE_DIR/Cargo.toml" ] || die "crate not found: $CRATE_DIR/Cargo.toml"
for s in inspector_1_build_image.sh inspector_2_deploy.sh inspector_5_cleanup.sh inspector_6_assert.sh; do
  [ -x "$SCRIPT_DIR/$s" ] || die "step script missing or not executable: $SCRIPT_DIR/$s"
done
[ "$CONTEXT" = kind-kind ] \
  || die "CONTEXT=$CONTEXT unsupported: inspector_2_deploy.sh and inspector_5_cleanup.sh only target kind-kind"

# Records a stage result by its index in STAGES.
set_result() {
  local i
  for i in "${!STAGES[@]}"; do
    [ "${STAGES[$i]}" = "$1" ] && RESULTS[i]=$2
  done
  return 0
}

# Runs one stage: banner, command, result; returns the command's status so set -e stops the pipeline.
run_stage() {
  local name=$1 rc=0
  shift
  step "stage $name"
  "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then set_result "$name" pass; else set_result "$name" "FAIL (exit $rc)"; fi
  return "$rc"
}

# Runs the crate's unit and localhost tests in a subshell so the cwd stays put.
cargo_test() { (cd "$CRATE_DIR" && cargo test); }

# Asserts with a wrong identity; only exit 1 counts, since 0 means no check and 2 a setup error.
assert_fail() {
  local rc=0
  EXPECTED_ID=$WRONG_ID "$SCRIPT_DIR/inspector_6_assert.sh" || rc=$?
  if [ "$rc" -ne 1 ]; then
    echo "negative assert exited $rc, want 1" >&2
    return 1
  fi
}

# Cleans up unless KEEP=1, then prints one line per stage and exits non-zero on any failure.
finish() {
  local rc=$? i failed=0
  trap - EXIT INT TERM
  if [ "${KEEP:-}" = 1 ]; then
    set_result cleanup "skipped (KEEP=1)"
  else
    run_stage cleanup "$SCRIPT_DIR/inspector_5_cleanup.sh" || failed=1
  fi
  step "summary"
  for i in "${!STAGES[@]}"; do
    printf '%-12s %s\n' "${STAGES[$i]}" "${RESULTS[$i]:-not run}"
    case "${RESULTS[$i]:-}" in FAIL*) failed=1 ;; esac
  done
  [ "$rc" -eq 0 ] && [ "$failed" -eq 1 ] && rc=1
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT TERM

# Runs the stages in order; the first failure exits through finish.
run_stage cargo_test cargo_test
run_stage build_image "$SCRIPT_DIR/inspector_1_build_image.sh"
run_stage deploy "$SCRIPT_DIR/inspector_2_deploy.sh"
run_stage assert_pass "$SCRIPT_DIR/inspector_6_assert.sh"
run_stage assert_fail assert_fail
