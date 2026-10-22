#!/usr/bin/env bash
# Run from the baltar repo root.
# Usage: ./scripts/mc_0_trust_anchor.sh
#        ANCHOR_DIR=out/anchor ./scripts/mc_0_trust_anchor.sh
#
# Multicluster setup step 0. Checks the machine can run the mc_ steps and
# mints the trust anchor the two clusters share.
#
# The mc_ steps build two kind clusters (east and west, contexts
# kind-east and kind-west). Two meshes only trust each other's identities
# when both issue from the same root, so this runs before init_2 and
# writes the shared root and issuer that init_2 installs on both.
#
# step gets a hint of its own: it is the one tool the VM does not ship by
# default, and nothing else can mint the anchor.
#
# Env vars and defaults:
#   ANCHOR_DIR   out/anchor. Holds ca.crt/ca.key (root) and
#                issuer.crt/issuer.key (intermediate) for init_2 to read.
set -euo pipefail

ANCHOR_DIR=${ANCHOR_DIR:-out/anchor}

# Fails fast when a required tool is missing, before any cert is written.
#
# kind/kubectl/linkerd match the init_ prerequisites; step is extra here
# because only the shared trust anchor needs it.
MISSING=0
for BIN in kind kubectl linkerd step; do
  if command -v "$BIN" >/dev/null 2>&1; then
    printf '  %-10s OK\n' "$BIN"
  else
    printf '  %-10s MISSING\n' "$BIN"
    MISSING=$((MISSING + 1))
  fi
done

# step carries an install hint because it is the odd one out.
#
# kind, kubectl and linkerd are already on the VM, so a failure here is
# almost always step; naming the install path saves a lookup.
if ! command -v step >/dev/null 2>&1; then
  echo "  step mints the shared trust anchor and is not on the VM by default."
  echo "  Install it first: https://smallstep.com/docs/step-cli/installation"
  echo "    brew install step   # or see the link above for Linux packages"
fi

if [ "$MISSING" -gt 0 ]; then
  echo "[-] FAIL: $MISSING required tool(s) missing; do not start the mc_ steps."
  exit 1
fi

# Generates the anchor only when it is absent, so reruns are safe.
#
# Regenerating the root after init_2 installed it would break trust
# between the clusters, so an existing anchor is reused as is.
mkdir -p "$ANCHOR_DIR"
if [ -f "$ANCHOR_DIR/ca.crt" ]; then
  echo "[-] trust anchor already present in $ANCHOR_DIR; reusing it"
else
  echo "[-] minting shared root and issuer into $ANCHOR_DIR"
  step certificate create root.linkerd.cluster.local \
    "$ANCHOR_DIR/ca.crt" "$ANCHOR_DIR/ca.key" \
    --profile root-ca --no-password --insecure
  step certificate create identity.linkerd.cluster.local \
    "$ANCHOR_DIR/issuer.crt" "$ANCHOR_DIR/issuer.key" \
    --profile intermediate-ca --not-after 8760h --no-password --insecure \
    --ca "$ANCHOR_DIR/ca.crt" --ca-key "$ANCHOR_DIR/ca.key"
fi

echo "[-] PASS: tools present, shared anchor ready in $ANCHOR_DIR"
echo "    pass these to init_2 on each cluster:"
echo "    TRUST_ANCHOR_CRT=$ANCHOR_DIR/ca.crt ISSUER_CRT=$ANCHOR_DIR/issuer.crt ISSUER_KEY=$ANCHOR_DIR/issuer.key"
