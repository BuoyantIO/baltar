#!/usr/bin/env bash
# Loads BUILD_OUT_DIR.
# shellcheck source=scripts/util_build.sh
. scripts/util_build.sh

# Run from the launchy-dev repo root.
# Usage: ./scripts/app/repro_2_e2e.sh
#        ./scripts/app/repro_2_e2e.sh TestAllowed
#        ./scripts/app/repro_2_e2e.sh TestAllowed TestDenied
#        PGPPI_DIR=~/src/pg-ppi GO_IMAGE=golang:1.26 ./scripts/app/repro_2_e2e.sh
#
# Env vars and defaults:
#   PGPPI_DIR      pg-ppi checkout next to launchy-dev
#   GO_IMAGE       golang:1.26
#   KUBECTL        kubectl on PATH
#   BUILD_OUT_DIR  out/ in the launchy-dev checkout (from util_build.sh)
#
# Repro step 2: runs pg-ppi's e2e suite against kind-kind, one go test per -run pattern argument.
# Runs in a container for pg-ppi's Go 1.26 toolchain, with host networking for kind's 127.0.0.1 API server.
set -euo pipefail

# Inputs with defaults; the context is fixed to the cluster from init_1_create_cluster.sh.
PGPPI_DIR=${PGPPI_DIR:-$(cd .. && pwd)/pg-ppi}
GO_IMAGE=${GO_IMAGE:-golang:1.26}
KUBECTL=${KUBECTL:-$(command -v kubectl || true)}
KUBE_CONTEXT=kind-kind

# Fails fast when the checkout or kubectl is missing.
if [ ! -f "$PGPPI_DIR/test/e2e/e2e_test.go" ]; then
  echo "pg-ppi checkout not found: $PGPPI_DIR" >&2
  echo "run: git clone https://github.com/daniel-garcia/pg-ppi.git $PGPPI_DIR" >&2
  exit 1
fi
[ -n "$KUBECTL" ] && [ -x "$KUBECTL" ] || { echo "kubectl not found: set KUBECTL" >&2; exit 1; }

# Writes a flattened kubeconfig holding only kind-kind, so one file mount suffices.
KUBECONFIG_FILE=$(mktemp)
trap 'rm -f "$KUBECONFIG_FILE"' EXIT
"$KUBECTL" config view --minify --flatten --context "$KUBE_CONTEXT" > "$KUBECONFIG_FILE"

# Persists the Go home under BUILD_OUT_DIR so reruns skip the module download.
# The container runs as the host user, so HOME must be writable outside the image.
GO_HOME="$BUILD_OUT_DIR/pgppi-e2e-gohome"
mkdir -p "$GO_HOME"

# Mounts the checkout read-only and the host's static kubectl onto the image's PATH.
GO_TEST=(docker run --rm --network host \
  --user "$(id -u):$(id -g)" \
  -v "$PGPPI_DIR:/src:ro" \
  -v "$KUBECONFIG_FILE:/kube/config:ro" \
  -v "$KUBECTL:/usr/local/bin/kubectl:ro" \
  -v "$GO_HOME:/gohome" \
  -e HOME=/gohome \
  -e GOCACHE=/gohome/cache \
  -e GOMODCACHE=/gohome/mod \
  -e GOFLAGS=-modcacherw \
  -e KUBECONFIG=/kube/config \
  -e KUBE_CONTEXT="$KUBE_CONTEXT" \
  -w /src \
  "$GO_IMAGE" \
  go test -tags e2e -count=1 -v)

# Runs the whole suite when no pattern is given.
if [ "$#" -eq 0 ]; then
  "${GO_TEST[@]}" ./test/e2e/
  exit
fi

# Runs one go test per pattern and fails if any failed.
# go test splits -run on '/' per level, so joining patterns with '|' selects the wrong subtests.
status=0
for pattern in "$@"; do
  "${GO_TEST[@]}" -run "$pattern" ./test/e2e/ || status=1
done
exit "$status"
