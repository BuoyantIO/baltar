#!/usr/bin/env bash
# Usage: ./init_2_install_linkerd.sh
#        CONTEXT=kind-east ./init_2_install_linkerd.sh
#        TRUST_ANCHOR_CRT=out/anchor/ca.crt ISSUER_CRT=out/anchor/issuer.crt \
#          ISSUER_KEY=out/anchor/issuer.key CONTEXT=kind-east ./init_2_install_linkerd.sh
#        LINKERD_VERSION=edge-26.6.3 ./init_2_install_linkerd.sh
#
# Setup step 2. Installs the Linkerd control plane with whatever
# `linkerd` CLI is on PATH, or with a pinned CLI when LINKERD_VERSION is set.
#
# The CLI decides the installed version, so pinning the CLI pins the mesh.
#
# Env vars and defaults:
#   CONTEXT            current kubeconfig context (so the single-cluster
#                      flow is unchanged). The multicluster flow sets it
#                      per cluster, e.g. kind-east then kind-west.
#   TRUST_ANCHOR_CRT   unset. When set (with ISSUER_CRT and ISSUER_KEY),
#   ISSUER_CRT         install uses this shared root and issuer instead of
#   ISSUER_KEY         the CLI-generated ones, so two clusters can share a
#                      trust anchor and trust each other's identities.
#   LINKERD_VERSION    unset (CLI on PATH). When set, e.g. edge-26.6.3,
#                      installs that edge CLI to out/cli/<version> unless
#                      already there, and uses it for every linkerd call.
set -euo pipefail

# Resolves CONTEXT to the current context when unset.
#
# Passing the current context explicitly is identical to passing no
# --context, so the default leaves single-cluster behavior unchanged
# while letting the multicluster flow target each cluster by name.
CONTEXT=${CONTEXT:-$(kubectl config current-context)}

# Picks the CLI: the one on PATH, or the pinned one, downloaded once.
#
# INSTALLROOT is absolute since the install script moves the binary there.
LINKERD=linkerd
if [ -n "${LINKERD_VERSION:-}" ]; then
  LINKERD="out/cli/$LINKERD_VERSION/bin/linkerd"
  if [ ! -x "$LINKERD" ]; then
    echo "[-] install linkerd CLI $LINKERD_VERSION"
    curl -sL https://run.linkerd.io/install-edge \
      | LINKERD2_VERSION="$LINKERD_VERSION" INSTALLROOT="$PWD/out/cli/$LINKERD_VERSION" sh
  fi
fi

# Catches an unfit cluster before anything is applied.
#
# A failure here leaves nothing half-installed.
"$LINKERD" --context "$CONTEXT" check --pre

# CRDs go first.
#
# The control plane manifests reference types they define.
"$LINKERD" --context "$CONTEXT" install --crds | kubectl --context "$CONTEXT" apply -f -

# Installs the control plane, with a shared trust anchor when one is given.
#
# Two meshes only trust each other when they issue identities from the
# same root, so the multicluster flow passes the shared anchor and issuer
# here; the single-cluster flow passes none and the CLI mints its own.
if [ -n "${TRUST_ANCHOR_CRT:-}" ]; then
  "$LINKERD" --context "$CONTEXT" install \
    --identity-trust-anchors-file "$TRUST_ANCHOR_CRT" \
    --identity-issuer-certificate-file "$ISSUER_CRT" \
    --identity-issuer-key-file "$ISSUER_KEY" | kubectl --context "$CONTEXT" apply -f -
else
  "$LINKERD" --context "$CONTEXT" install | kubectl --context "$CONTEXT" apply -f -
fi

# Blocks until the control plane is actually healthy.
#
# The next setup step then starts from a working mesh rather than a
# scheduled one.
"$LINKERD" --context "$CONTEXT" check

# Prints the pinned CLI so later steps can use the same one.
#
# `linkerd upgrade` (dev_10) must match the installed version.
if [ -n "${LINKERD_VERSION:-}" ]; then
  echo "[-] linkerd CLI: $PWD/$LINKERD"
  echo "    for later steps: export PATH=\"$PWD/out/cli/$LINKERD_VERSION/bin:\$PATH\""
fi
