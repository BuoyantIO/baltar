#!/usr/bin/env bash
# Loads k (kubectl on CONTEXT).
# shellcheck source=scripts/util_kube.sh
. scripts/util_kube.sh

# Run from the baltar repo root.
# Usage: ./scripts/dev_10_linkerd_upgrade.sh proxyInit.closeWaitTimeoutSecs=3600
#        CONTEXT=kind-east ./scripts/dev_10_linkerd_upgrade.sh \
#          proxyInit.closeWaitTimeoutSecs=3600 proxy.image.version=fix15731
#
# Re-renders the installed control plane with `linkerd upgrade` (CLI on PATH),
# one `--set key=value` per positional arg, applies it and waits for the rollout.
# Keeps the manifest at out/upgrade_<CONTEXT>.yaml for inspection.
#
# Env vars and defaults:
#   CONTEXT=kind-kind   kubectl and linkerd context
#   TIMEOUT=300s        rollout status timeout
set -euo pipefail

# Inputs with defaults.
CONTEXT=${CONTEXT:-kind-kind}
TIMEOUT=${TIMEOUT:-300s}
MANIFEST="out/upgrade_${CONTEXT}.yaml"

# Turns each key=value arg into a --set flag.
SET_ARGS=()
for kv in "$@"; do
  SET_ARGS+=(--set "$kv")
done

# Renders the upgraded control plane to a kept file.
echo "[-] render $MANIFEST"
mkdir -p out
linkerd --context "$CONTEXT" upgrade ${SET_ARGS[@]+"${SET_ARGS[@]}"} >"$MANIFEST"

# Applies the rendered manifest.
echo "[-] apply $MANIFEST"
k apply -f "$MANIFEST"

# Waits for the control plane Deployments to roll out.
# Can time out by design when the new values break linkerd-init (control plane pods are injected too); old pods keep serving.
echo "[-] rollout"
k -n linkerd rollout status deploy --timeout="$TIMEOUT"
