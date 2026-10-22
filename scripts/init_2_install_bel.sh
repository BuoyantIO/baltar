#!/usr/bin/env bash
# Run from the baltar repo root.
# Usage: ./scripts/init_2_install_bel.sh
#        BEL_VERSION=2.19.12 ./scripts/init_2_install_bel.sh
#        BEL_PROXY_ADDITIONAL_ENV='[{"name":"RUST_LOG","value":"debug"}]' ./scripts/init_2_install_bel.sh
#
# Env vars and defaults:
#   BEL_VERSION               2.20.3
#   BEL_ENV_FILE              .no_commit_bel (KEY=value lines with BUOYANT_LICENSE)
#   BEL_PROXY_ADDITIONAL_ENV  [] (JSON array for proxy.additionalEnv)
#   BEL_CERT_DIR              out/bel_certs
#
# Installs or upgrades Buoyant Enterprise for Linkerd with Helm on the current kubectl context.
# Meshed pods need a restart to get new proxy env.
set -euo pipefail

BEL_VERSION=${BEL_VERSION:-2.20.3}
BEL_ENV_FILE=${BEL_ENV_FILE:-.no_commit_bel}
BEL_PROXY_ADDITIONAL_ENV=${BEL_PROXY_ADDITIONAL_ENV:-[]}
BEL_CERT_DIR=${BEL_CERT_DIR:-out/bel_certs}

# Loads BUOYANT_LICENSE from the git-ignored env file.
set -a
# shellcheck source=/dev/null
. "$BEL_ENV_FILE"
set +a

# Generates the trust anchor and issuer once, so upgrades keep existing proxy identities valid.
mkdir -p "$BEL_CERT_DIR"
if [ ! -f "$BEL_CERT_DIR/ca.crt" ] || [ ! -f "$BEL_CERT_DIR/issuer.key" ]; then
  step certificate create root.linkerd.cluster.local "$BEL_CERT_DIR/ca.crt" "$BEL_CERT_DIR/ca.key" \
    --profile root-ca --no-password --insecure -f
  step certificate create identity.linkerd.cluster.local "$BEL_CERT_DIR/issuer.crt" "$BEL_CERT_DIR/issuer.key" \
    --profile intermediate-ca --not-after 8760h --no-password --insecure \
    --ca "$BEL_CERT_DIR/ca.crt" --ca-key "$BEL_CERT_DIR/ca.key" -f
fi

# Adds the BEL chart repo.
helm repo add linkerd-buoyant https://helm.buoyant.cloud >/dev/null
helm repo update linkerd-buoyant >/dev/null

# Installs the CRDs first: the control plane chart references their types.
helm upgrade --install linkerd-crds linkerd-buoyant/linkerd-enterprise-crds \
  --namespace linkerd --create-namespace --version "$BEL_VERSION"

# Installs the control plane; the license goes through a process substitution to stay out of argv.
helm upgrade --install linkerd-control-plane linkerd-buoyant/linkerd-enterprise-control-plane \
  --namespace linkerd --version "$BEL_VERSION" \
  --set-file license=<(printf '%s' "$BUOYANT_LICENSE") \
  --set-file "identityTrustAnchorsPEM=$BEL_CERT_DIR/ca.crt" \
  --set-file "identity.issuer.tls.crtPEM=$BEL_CERT_DIR/issuer.crt" \
  --set-file "identity.issuer.tls.keyPEM=$BEL_CERT_DIR/issuer.key" \
  --set-json "proxy.additionalEnv=$BEL_PROXY_ADDITIONAL_ENV"

# Waits for every control plane deployment to become available.
kubectl -n linkerd wait --for=condition=available deploy --all --timeout=5m
