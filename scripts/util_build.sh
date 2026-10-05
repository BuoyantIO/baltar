#!/usr/bin/env bash
# Shared helpers for the custom Linkerd image build.
#
# Sourced by build_1_proxy.sh, verify_1_proxy.sh, build_2_linkerd2.sh
# and verify_2_linkerd2.sh. Not executable and never run directly:
# util_build.sh defines things and does nothing. The sourcing script
# owns `set -euo pipefail`.
#
# What belongs here: only what every build and verify script needs,
# which is the prerequisite check, the repo check, the ref checkout,
# the devcontainer up and exec wrappers, and the env-file hand-off.
#
# What does not: build commands and verification assertions. Those are
# each script's own.
#
# Nothing here clones, installs or commits. A missing repo or tool is
# reported with the command for the user to run.

BUILD_OUT_DIR="${BUILD_OUT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/out}"

# Fails fast when a required tool is missing.
#
# Checked up front so a build does not run for minutes before hitting
# an absent `devcontainer`. The CLI is never installed here: a global
# npm install is the user's call.
require_tools() {
  local missing=0
  command -v git >/dev/null 2>&1 || { echo "missing: git" >&2; missing=1; }
  command -v docker >/dev/null 2>&1 || { echo "missing: docker" >&2; missing=1; }
  if command -v docker >/dev/null 2>&1 && ! docker buildx version >/dev/null 2>&1; then
    echo "missing: docker buildx" >&2; missing=1
  fi
  if ! command -v devcontainer >/dev/null 2>&1; then
    echo "missing: devcontainer; install with: npm install -g @devcontainers/cli" >&2
    missing=1
  fi
  [ "$missing" -eq 0 ] || exit 1
}

# Exits non-zero unless $1 is a git checkout, naming the clone command.
#
# $2 is the repo name on github.com/linkerd. Cloning is the user's
# step so a script never writes outside its own checkout.
require_repo() {
  local dir=$1 repo=$2
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "not a git checkout: $dir" >&2
    echo "run: git clone https://github.com/linkerd/$repo.git $dir" >&2
    exit 1
  fi
}

# Detaches $1 at ref $2 and prints "<full-sha> <short-sha>".
#
# Refuses a tree with tracked changes so a checkout never discards or
# mixes in local work. Untracked files are ignored (-uno): the VM
# checkouts hold untracked files that do not affect a detached
# checkout, and refusing on them would block every run. A checkout
# that would overwrite an untracked file still fails inside git.
# `git fetch origin <ref>` takes a branch, a commit SHA, or the
# `pull/<n>/head` form, which GitHub serves as refs/pull/<n>/head.
# Progress goes to stderr so stdout is only the SHA pair.
checkout_ref() {
  local dir=$1 ref=$2
  if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
    echo "refusing: tracked changes in $dir" >&2
    git -C "$dir" status --short --untracked-files=no >&2
    exit 1
  fi
  git -C "$dir" fetch origin "$ref" >&2
  git -C "$dir" checkout --detach FETCH_HEAD >&2
  local full short
  full=$(git -C "$dir" rev-parse HEAD)
  short=$(git -C "$dir" rev-parse --short HEAD)
  echo "$full $short"
}

# Starts the repo's devcontainer. Idempotent: `up` reuses a running one.
devcontainer_up() {
  devcontainer up --workspace-folder "$1" >&2
}

# Runs a command in the repo's devcontainer with an empty docker config:
# devcontainer_exec <dir> <cmd...>.
#
# The devcontainer's ~/.docker/config.json sets `credsStore` to a VS Code
# helper that does not exist outside VS Code, so every image pull fails
# with "error getting credentials". A fresh empty DOCKER_CONFIG, made
# inside the container and removed on exit, drops that setting for this
# command only. `docker buildx` is still found: the plugin lives in the
# system path /usr/libexec/docker/cli-plugins, not in ~/.docker. The
# command runs as a child, not via exec, so the EXIT trap cleans up.
devcontainer_exec() {
  local dir=$1; shift
  # SC2016: the snippet must expand in the container shell, not here.
  # shellcheck disable=SC2016
  devcontainer exec --workspace-folder "$dir" sh -c '
    d=$(mktemp -d) || exit 1
    trap "rm -rf \"$d\"" EXIT
    DOCKER_CONFIG=$d "$@"
  ' sh "$@"
}

# Writes KEY=value lines to $BUILD_OUT_DIR/<name>: write_env <name> KEY=value...
#
# Overwrites the file so a rerun never leaves stale keys from an older
# build. Values must not contain newlines.
write_env() {
  local name=$1; shift
  mkdir -p "$BUILD_OUT_DIR"
  printf '%s\n' "$@" > "$BUILD_OUT_DIR/$name"
}

# Prints the value of KEY in $BUILD_OUT_DIR/<name>: read_env <name> <KEY>.
#
# Reads literally rather than sourcing so a value is never executed.
# Fails when the file or key is missing, so a verify or later build
# that needs an earlier hand-off stops instead of using an empty value.
read_env() {
  local name=$1 key=$2 line file
  file="$BUILD_OUT_DIR/$name"
  [ -f "$file" ] || { echo "missing env file: $file" >&2; return 1; }
  line=$(grep -m1 "^${key}=" "$file") || { echo "missing key $key in $file" >&2; return 1; }
  echo "${line#*=}"
}
