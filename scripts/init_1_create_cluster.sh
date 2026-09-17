#!/usr/bin/env bash
# Usage: ./init_1_create_cluster.sh
#        GATEWAY_API_VERSION=v1.5.1 ./init_1_create_cluster.sh
#        KIND_LISTEN_ADDRESS=0.0.0.0 ./init_1_create_cluster.sh
# Setup step 1. The init_<n>_ prefix marks a cluster-setup script and the
# order it runs in, separating these from the load-test scripts alongside.
#
# Creates the kind cluster and installs the Gateway API CRDs. Still
# unparameterised on the cluster shape: kind's defaults decide the name,
# node count and k8s version, so there is one shape and no flags living
# in shell history. The one thing the defaults cannot give is a published
# NodePort, so the config file exists for that alone.
set -euo pipefail

KIND_CONFIG=${KIND_CONFIG:-$(cd "$(dirname "$0")" && pwd)/init_1_create_cluster.yaml}
[ -f "$KIND_CONFIG" ] || { echo "kind config not found: $KIND_CONFIG" >&2; exit 1; }

# On a host that must be reachable from elsewhere, the published port has
# to bind beyond loopback. Rewriting a copy keeps the committed config as
# the safe default rather than making every machine edit it in place.
KIND_LISTEN_ADDRESS=${KIND_LISTEN_ADDRESS:-}
if [ -n "$KIND_LISTEN_ADDRESS" ]; then
  GENERATED=$(mktemp -t kind-config)
  trap 'rm -f "$GENERATED"' EXIT
  sed "s/listenAddress: \"127.0.0.1\"/listenAddress: \"$KIND_LISTEN_ADDRESS\"/" \
    "$KIND_CONFIG" > "$GENERATED"
  KIND_CONFIG=$GENERATED
  echo "publishing on $KIND_LISTEN_ADDRESS, not loopback" >&2
fi

# Fails loudly if a cluster of this name already exists, rather than
# pretending the rebuild succeeded against a cluster we did not just build.
kind create cluster --config "$KIND_CONFIG"

# Proves the API server answers and the context is the one we expect,
# so a caller running the modules in order starts from a known cluster.
kubectl cluster-info --context kind-kind

# Gateway API CRDs. Linkerd expects these to exist already, so they go in
# here rather than in init_2. The release tag is the only thing that
# varies, so it is the one override this script takes.
GATEWAY_API_VERSION=${GATEWAY_API_VERSION:-v1.5.1}
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
