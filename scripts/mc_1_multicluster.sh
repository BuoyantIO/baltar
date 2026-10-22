#!/usr/bin/env bash
# Run from the baltar repo root.
# Usage: ./scripts/mc_1_multicluster.sh
#        GATEWAY_ADDRESS=172.18.255.200 ./scripts/mc_1_multicluster.sh
#
# Multicluster step 1. Turns two existing meshed clusters into a mirror
# pair: the local cluster mirrors west's exported services over west's
# gateway.
#
# Assumes the local and west clusters already exist with Linkerd installed
# under the shared trust anchor (mc_0 then init_2 on each). Here it installs
# the multicluster extension on both, gives west's gateway a stable
# address with MetalLB, and links west into the local cluster in gateway
# mode.
#
# Env vars and defaults:
#   EAST_CONTEXT      kind-kind. The local cluster that mirrors (holds the
#                     Link); its kind default name is kind.
#   WEST_CONTEXT      kind-west. The cluster whose services are exported.
#   GATEWAY_ADDRESS   172.18.255.200. West's gateway address the Link routes
#                     mirrored traffic to; must fall in the MetalLB pool below.
#   METALLB_VERSION   v0.14.9. The MetalLB release manifest to apply.
#   METALLB_POOL      scripts/mc_1_metallb_pool.yaml. The address pool.
set -euo pipefail

EAST_CONTEXT=${EAST_CONTEXT:-kind-kind}
WEST_CONTEXT=${WEST_CONTEXT:-kind-west}
GATEWAY_ADDRESS=${GATEWAY_ADDRESS:-172.18.255.200}
METALLB_VERSION=${METALLB_VERSION:-v0.14.9}
METALLB_POOL=${METALLB_POOL:-scripts/mc_1_metallb_pool.yaml}

# Installs the multicluster extension and waits for each gateway.
#
# The gateway must be Running before the link is generated, since the CLI
# reads its identity from the west cluster to build the Link.
for CTX in "$EAST_CONTEXT" "$WEST_CONTEXT"; do
  echo "[-] $CTX: installing multicluster extension"
  linkerd --context "$CTX" multicluster install | kubectl --context "$CTX" apply -f -
  kubectl --context "$CTX" -n linkerd-multicluster rollout status deploy/linkerd-gateway --timeout=180s
done

# Gives west's gateway a routable address with MetalLB.
#
# The Link targets west's exported services over west's gateway, so west's
# gateway is the LoadBalancer that must get the pinned address. kind
# gateways have no cloud behind them, so without MetalLB the address stays
# pending and the Link has nothing to target.
echo "[-] $WEST_CONTEXT: installing MetalLB and the address pool"
kubectl --context "$WEST_CONTEXT" apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
kubectl --context "$WEST_CONTEXT" -n metallb-system rollout status deploy/controller --timeout=180s
kubectl --context "$WEST_CONTEXT" -n metallb-system rollout status daemonset/speaker --timeout=180s
kubectl --context "$WEST_CONTEXT" apply -f "$METALLB_POOL"

# Links west into the local cluster in gateway mode.
#
# The Link is generated from the west context (where the credentials and
# gateway live) and applied to the local context (which runs the service
# mirror). The
# gateway address is pinned because the pool assigns it, and the
# remote-discovery selector matches the services exported for remote
# discovery rather than gateway mirroring.
# Resolves west's API server address on the Docker network: kind's kubeconfig
# points the Link at a host loopback port the east service-mirror pod cannot
# reach, so the Link must carry west's container-network API address.
WEST_CONTAINER="${WEST_CONTEXT#kind-}-control-plane"
WEST_API_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$WEST_CONTAINER")

echo "[-] linking $WEST_CONTEXT into $EAST_CONTEXT (gateway mode)"
linkerd --context "$WEST_CONTEXT" multicluster link \
  --cluster-name west \
  --api-server-address "https://${WEST_API_IP}:6443" \
  --gateway-addresses "$GATEWAY_ADDRESS" \
  --remote-discovery-selector 'mirror.linkerd.io/exported=remote-discovery' \
  | kubectl --context "$EAST_CONTEXT" apply -f -

# Confirms the Link landed on the local cluster.
#
# The service mirror only starts reconciling once this object exists.
echo "[-] verifying the Link on $EAST_CONTEXT"
kubectl --context "$EAST_CONTEXT" -n linkerd-multicluster get link west
