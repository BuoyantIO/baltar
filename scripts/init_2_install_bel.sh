#!/usr/bin/env bash
# Usage: ./init_2_install_bel.sh
#        BEL_VERSION=2.19.12 ./init_2_install_bel.sh
#        BEL_PROXY_ADDITIONAL_ENV='[{"name":"RUST_LOG","value":"debug"}]' ./init_2_install_bel.sh
#
# Env vars and defaults:
#   BEL_VERSION               2.20.3
#   BEL_ENV_FILE              .no_commit_bel in the launchy-dev checkout (KEY=value lines; BUOYANT_LICENSE required, API_CLIENT_ID/API_CLIENT_SECRET ignored)
#   BEL_PROXY_ADDITIONAL_ENV  unset (JSON array for proxy.additionalEnv)
#   BEL_CERT_DIR              out/bel_certs in the launchy-dev checkout
#
# Setup step 2, alternative to init_2_install_linkerd.sh: installs a chosen Buoyant Enterprise for Linkerd
# version with Helm into the kind cluster (after init_1_create_cluster.sh).
# Rerunning with another version or env upgrades in place; meshed pods need a restart to get new proxy env.
set -euo pipefail

# Resolves inputs relative to the checkout.
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
BEL_VERSION=${BEL_VERSION:-2.20.3}
BEL_ENV_FILE=${BEL_ENV_FILE:-$REPO_DIR/.no_commit_bel}
BEL_PROXY_ADDITIONAL_ENV=${BEL_PROXY_ADDITIONAL_ENV:-}
BEL_CERT_DIR=${BEL_CERT_DIR:-$REPO_DIR/out/bel_certs}
NAMESPACE=linkerd
CP_RELEASE=linkerd-control-plane

# Fails fast on missing tools before touching the cluster.
for bin in kubectl helm step; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing: $bin (brew install $bin)" >&2; exit 1; }
done

# Loads the license from the git-ignored file only; an inherited BUOYANT_LICENSE would mask an empty file.
if [ ! -f "$BEL_ENV_FILE" ]; then
  echo "license file not found: $BEL_ENV_FILE" >&2
  echo "create it with KEY=value lines; required: BUOYANT_LICENSE=<license from https://enterprise.buoyant.io>" >&2
  exit 1
fi
unset BUOYANT_LICENSE
# Exports the file's plain KEY=value lines; API_CLIENT_ID and API_CLIENT_SECRET are loaded but unused.
set -a
# shellcheck source=/dev/null
. "$BEL_ENV_FILE"
set +a
if [ -z "${BUOYANT_LICENSE:-}" ]; then
  echo "BUOYANT_LICENSE is empty after sourcing $BEL_ENV_FILE: add a line BUOYANT_LICENSE=<license>" >&2
  exit 1
fi

# Refuses any context but kind, so a real cluster is never upgraded by accident.
KUBE_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
case "$KUBE_CONTEXT" in
  kind-*) ;;
  *) echo "refusing: kubectl context '$KUBE_CONTEXT' does not start with kind-" >&2; exit 1 ;;
esac
KUBECTL=(kubectl --context "$KUBE_CONTEXT")
HELM=(helm --kube-context "$KUBE_CONTEXT")

# Stops on a control plane Helm does not own (init_2's `linkerd install`) instead of fighting over its objects.
EXISTING=$("${KUBECTL[@]}" -n "$NAMESPACE" get deploy -o name 2>/dev/null || true)
if [ -n "$EXISTING" ] && ! "${HELM[@]}" -n "$NAMESPACE" status "$CP_RELEASE" >/dev/null 2>&1; then
  echo "refusing: deployments exist in namespace $NAMESPACE without Helm release $CP_RELEASE (OSS install?)" >&2
  echo "run scripts/cleanup_1_cluster.sh and scripts/init_1_create_cluster.sh first" >&2
  exit 1
fi

# Writes the license to a private temp file so it stays out of the process list and the echoed command.
LICENSE_FILE=""
cleanup() { [ -z "${LICENSE_FILE:-}" ] || rm -f "$LICENSE_FILE"; }
trap cleanup EXIT
LICENSE_FILE=$(mktemp)
chmod 600 "$LICENSE_FILE"
printf '%s' "$BUOYANT_LICENSE" >"$LICENSE_FILE"

# Generates the trust anchor and issuer once; reruns reuse them so upgrades keep existing proxy identities valid.
mkdir -p "$BEL_CERT_DIR"
if [ ! -f "$BEL_CERT_DIR/ca.crt" ] || [ ! -f "$BEL_CERT_DIR/issuer.key" ]; then
  step certificate create root.linkerd.cluster.local "$BEL_CERT_DIR/ca.crt" "$BEL_CERT_DIR/ca.key" \
    --profile root-ca --no-password --insecure -f
  step certificate create identity.linkerd.cluster.local "$BEL_CERT_DIR/issuer.crt" "$BEL_CERT_DIR/issuer.key" \
    --profile intermediate-ca --not-after 8760h --no-password --insecure \
    --ca "$BEL_CERT_DIR/ca.crt" --ca-key "$BEL_CERT_DIR/ca.key" -f
fi

# Adds the BEL chart repo; the URL is the one enterprise-linkerd's helm-test workflow uses.
helm repo add linkerd-buoyant https://helm.buoyant.cloud >/dev/null
helm repo update linkerd-buoyant >/dev/null

# Echoes then runs a command; the license only appears as the temp file path.
run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  "$@"
}

# Installs the CRDs first: the control plane chart references their types.
run "${HELM[@]}" upgrade --install linkerd-crds linkerd-buoyant/linkerd-enterprise-crds \
  --namespace "$NAMESPACE" --create-namespace --version "$BEL_VERSION"

# Installs the control plane; values are reset each run, so dropping BEL_PROXY_ADDITIONAL_ENV removes the env.
CP_ARGS=(upgrade --install "$CP_RELEASE" linkerd-buoyant/linkerd-enterprise-control-plane
  --namespace "$NAMESPACE" --version "$BEL_VERSION"
  --set-file "license=$LICENSE_FILE"
  --set-file "identityTrustAnchorsPEM=$BEL_CERT_DIR/ca.crt"
  --set-file "identity.issuer.tls.crtPEM=$BEL_CERT_DIR/issuer.crt"
  --set-file "identity.issuer.tls.keyPEM=$BEL_CERT_DIR/issuer.key")
if [ -n "$BEL_PROXY_ADDITIONAL_ENV" ]; then
  CP_ARGS+=(--set-json "proxy.additionalEnv=$BEL_PROXY_ADDITIONAL_ENV")
fi
run "${HELM[@]}" "${CP_ARGS[@]}"

# Waits for every control plane deployment to finish rolling out.
"${KUBECTL[@]}" -n "$NAMESPACE" get deploy -o name | while read -r deploy; do
  "${KUBECTL[@]}" -n "$NAMESPACE" rollout status "$deploy" --timeout=5m
done
