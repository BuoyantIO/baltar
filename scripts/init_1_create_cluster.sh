#!/usr/bin/env bash
# Run from the baltar repo root.
# Usage: ./scripts/init_1_create_cluster.sh
#        GATEWAY_API_VERSION=v1.5.1 ./scripts/init_1_create_cluster.sh
#        KIND_LISTEN_ADDRESS=0.0.0.0 ./scripts/init_1_create_cluster.sh
#        CLUSTER_NAME=east ./scripts/init_1_create_cluster.sh
#
# Setup step 1. Creates the kind cluster and installs the Gateway API
# CRDs.
#
# The init_<n>_ prefix marks a cluster-setup script and the order it
# runs in, separating these from the load-test scripts alongside.
#
# The one shape kind's defaults cannot give is a published NodePort, so
# the config file exists for that alone. CLUSTER_NAME defaults to kind's
# own default, so the single-cluster flow is unchanged; the multicluster
# flow sets it to build east and west from the same script.
set -euo pipefail

# Names the cluster so the same script can build more than one.
#
# kind's own default is "kind"; keeping that default means every existing
# caller behaves exactly as before.
CLUSTER_NAME=${CLUSTER_NAME:-kind}

KIND_CONFIG=${KIND_CONFIG:-scripts/init_1_create_cluster.yaml}
[ -f "$KIND_CONFIG" ] || { echo "kind config not found: $KIND_CONFIG" >&2; exit 1; }

# Rewrites a copy of the config when the listen address is overridden.
#
# On a host that must be reachable from elsewhere, the published port
# has to bind beyond loopback. Rewriting a copy keeps the committed
# config as the safe default rather than making every machine edit it in
# place.
KIND_LISTEN_ADDRESS=${KIND_LISTEN_ADDRESS:-}
if [ -n "$KIND_LISTEN_ADDRESS" ]; then
  GENERATED=$(mktemp -t kind-config)
  trap 'rm -f "$GENERATED"' EXIT
  sed "s/listenAddress: \"127.0.0.1\"/listenAddress: \"$KIND_LISTEN_ADDRESS\"/" \
    "$KIND_CONFIG" > "$GENERATED"
  KIND_CONFIG=$GENERATED
  echo "publishing on $KIND_LISTEN_ADDRESS, not loopback" >&2
fi

# Fails loudly if a cluster of this name already exists.
#
# The alternative is pretending the rebuild succeeded against a cluster
# we did not just build.
kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"

# Proves the API server answers and the context is the one we expect.
#
# A caller running the modules in order then starts from a known
# cluster. kind prefixes the context with "kind-".
kubectl cluster-info --context "kind-$CLUSTER_NAME"

# Installs the Gateway API CRDs.
#
# Linkerd expects these to exist already, so they go in here rather than
# in init_2. The release tag is the only thing that varies, so it is the
# one override this script takes.
GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-v1.5.1}
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
