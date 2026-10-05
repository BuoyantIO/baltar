#!/usr/bin/env bash
# Shared helpers for the build, verify and repro scripts; sourced, never run, so the caller owns `set -euo pipefail`.
# Nothing here clones, installs or commits: a missing repo or tool prints the command for the user to run.

# Holds the env files handed between steps.
BUILD_OUT_DIR="${BUILD_OUT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/out}"

# Fails fast when a required tool is missing, before a minutes-long build.
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

# Exits unless $1 is a git checkout, printing the clone command for github.com/linkerd/$2.
require_repo() {
  local dir=$1 repo=$2
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "not a git checkout: $dir" >&2
    echo "run: git clone https://github.com/linkerd/$repo.git $dir" >&2
    exit 1
  fi
}

# Detaches $1 at ref $2 (branch, SHA or pull/<n>/head) and prints only "<full-sha> <short-sha>" on stdout.
# Refuses tracked changes but not untracked files, which the VM checkouts hold and would block every run.
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

# Runs <cmd...> in <dir>'s devcontainer with an empty DOCKER_CONFIG: devcontainer_exec <dir> <cmd...>.
# The default config's credsStore is a VS Code helper absent outside VS Code, which fails every pull.
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

# Overwrites $BUILD_OUT_DIR/<name> with newline-free KEY=value args: write_env <name> KEY=value...
write_env() {
  local name=$1; shift
  mkdir -p "$BUILD_OUT_DIR"
  printf '%s\n' "$@" > "$BUILD_OUT_DIR/$name"
}

# Prints KEY from $BUILD_OUT_DIR/<name> without sourcing it: read_env <name> <KEY>.
# Fails on a missing file or key, so a later step stops instead of using an empty value.
read_env() {
  local name=$1 key=$2 line file
  file="$BUILD_OUT_DIR/$name"
  [ -f "$file" ] || { echo "missing env file: $file" >&2; return 1; }
  line=$(grep -m1 "^${key}=" "$file") || { echo "missing key $key in $file" >&2; return 1; }
  echo "${line#*=}"
}
