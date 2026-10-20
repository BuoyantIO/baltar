#!/usr/bin/env bash
# Run from the launchy-dev repo root.
# Usage: ./scripts/examples/multicluster/run.sh
#        ANCHOR_DIR=out/anchor ./scripts/examples/multicluster/run.sh
#
# Reference run of the multicluster mirror setup and the
# discovery-annotation redirect demo. It builds two kind clusters (the
# default kind cluster and west), meshes both under one shared trust
# anchor, mirrors west into the local cluster, deploys the demo workloads,
# then shows where the local cluster resolves the mirrored services.
#
# Creates the clusters, so it fails if the default kind cluster or west
# already exist; tear down with scripts/cleanup_1_cluster.sh then
# CLUSTER_NAME=west scripts/cleanup_1_cluster.sh.
#
# Env vars and defaults (passed through to the scripts; see their headers):
#   ANCHOR_DIR   out/anchor (mc_0_trust_anchor.sh; init_2 reads it)
#   OUT_DIR      out/mc_<timestamp> (diagnose.sh results dir)
set -euo pipefail

HERE=scripts/examples/multicluster
ANCHOR_DIR=${ANCHOR_DIR:-out/anchor}

# Checks tools and mints the shared trust anchor both clusters will use.
echo "[-] step 0: prerequisites and shared trust anchor"
ANCHOR_DIR="$ANCHOR_DIR" scripts/mc_0_trust_anchor.sh

# Builds the two clusters from the same init script, with no host port so
# they do not collide on one machine.
echo "[-] step 1: create the default kind cluster and west"
KIND_CONFIG="$HERE/kind.yaml" scripts/init_1_create_cluster.sh
CLUSTER_NAME=west KIND_CONFIG="$HERE/kind.yaml" scripts/init_1_create_cluster.sh

# Meshes both clusters under the shared anchor so their identities trust
# each other.
echo "[-] step 2: install Linkerd on both under the shared anchor"
CONTEXT=kind-kind TRUST_ANCHOR_CRT="$ANCHOR_DIR/ca.crt" ISSUER_CRT="$ANCHOR_DIR/issuer.crt" \
  ISSUER_KEY="$ANCHOR_DIR/issuer.key" scripts/init_2_install_linkerd.sh
CONTEXT=kind-west TRUST_ANCHOR_CRT="$ANCHOR_DIR/ca.crt" ISSUER_CRT="$ANCHOR_DIR/issuer.crt" \
  ISSUER_KEY="$ANCHOR_DIR/issuer.key" scripts/init_2_install_linkerd.sh

# Installs the multicluster extension, the local gateway address and the
# west-into-local Link.
echo "[-] step 3: multicluster install, MetalLB and link"
scripts/mc_1_multicluster.sh

# Deploys the demo workloads and carriers on each side.
echo "[-] step 4: deploy demo workloads"
kubectl --context kind-kind apply -f "$HERE/east.yaml"
kubectl --context kind-west apply -f "$HERE/west.yaml"
kubectl --context kind-kind -n tenant rollout status deploy/victim --timeout=120s
kubectl --context kind-kind -n tenant rollout status deploy/client --timeout=120s
kubectl --context kind-west -n tenant rollout status deploy/other --timeout=120s

# Shows where the local cluster resolves the mirrored services and persists the output.
echo "[-] step 5: diagnose"
"$HERE/diagnose.sh"

# Names the teardown.
echo "cleanup: scripts/cleanup_1_cluster.sh then CLUSTER_NAME=west scripts/cleanup_1_cluster.sh"
