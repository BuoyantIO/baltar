#!/usr/bin/env bash
# Usage: ./inspector_1_build_image.sh
#        INSPECTOR_IMAGE=localhost/l4-proto-inspector:test ./inspector_1_build_image.sh
#
# Env vars and defaults:
#   INSPECTOR_IMAGE  localhost/l4-proto-inspector:dev
#
# Inspector step 1 (on the Mac or the VM, after init_1_create_cluster.sh): tests l4_proto_inspector, builds its image, loads it into kind.
# The Dockerfile compiles in a Rust build stage, so a Mac host binary (Mach-O) never reaches the image.
set -euo pipefail

# Locates the crate relative to this script, not the cwd.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CRATE_DIR="$SCRIPT_DIR/../l4_proto_inspector"
INSPECTOR_IMAGE=${INSPECTOR_IMAGE:-localhost/l4-proto-inspector:dev}

# Targets the cluster from init_1_create_cluster.sh.
KIND_CLUSTER=kind

# Fails fast on missing tools or crate.
for tool in docker kind; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool (on the VM, run via bash -lc)" >&2; exit 1; }
done
[ -f "$CRATE_DIR/Cargo.toml" ] || { echo "crate not found: $CRATE_DIR/Cargo.toml" >&2; exit 1; }

# Runs the tests on the host when cargo is present; the image build does not run them.
if command -v cargo >/dev/null; then
  (cd "$CRATE_DIR" && cargo test)
else
  echo "cargo not found: skipping cargo test" >&2
fi

# Builds the image from the crate dir; .dockerignore limits the context to Cargo.toml, Cargo.lock and src/.
docker build -t "$INSPECTOR_IMAGE" "$CRATE_DIR"

# Loads the localhost/ image into kind so pods never pull it.
kind load docker-image --name "$KIND_CLUSTER" "$INSPECTOR_IMAGE"
