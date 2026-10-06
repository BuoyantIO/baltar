#!/usr/bin/env bash
# Usage: ./inspector_2_deploy.sh
#        INSPECTOR_IMAGE=localhost/l4-proto-inspector:dev ./inspector_2_deploy.sh
#
# Inspector step 2: deploys inspector_2_deploy.yaml into ns inspect on kind-kind and waits for rollouts.
# Needs the image from inspector_1_build_image.sh loaded into kind; safe to rerun.
#
# Traffic path: inspector_3_send.sh runs `nc inspector.inspect 15432` in pod
# client via kubectl exec; 15432 is opaque and in
# proxy-protocol-v2-inbound-ports.
#
#  pod client                         pod inspector
#  +--------------------+  mTLS     +------------------------------------------+
#  | nc ---> linkerd-   |---------->| linkerd-proxy :4143 (terminates mTLS)    |
#  |  (exec)  proxy     |  :4143    |   + PROXY v2 (TLV 0xE0 = client id)      |
#  +--------------------+           |      |                                   |
#                                   |      v                                   |
#                                   | inspector :15432  (log header, strip it) |
#                                   |      |  --upstream 127.0.0.1:9000        |
#                                   |      v                                   |
#                                   | echo :9000 (socat cat, loopback only)    |
#                                   +------------------------------------------+
#  client has no listener (busybox, sleep infinity); replies retrace the path.
#
# Env vars and defaults:
#   INSPECTOR_IMAGE=localhost/l4-proto-inspector:dev inspector image, substituted into the manifest
set -euo pipefail

# Inputs with defaults; the manifest sits next to this script.
INSPECTOR_IMAGE=${INSPECTOR_IMAGE:-localhost/l4-proto-inspector:dev}
MANIFEST="$(cd "$(dirname "$0")" && pwd)/inspector_2_deploy.yaml"
DEFAULT_IMAGE=localhost/l4-proto-inspector:dev

# Targets the cluster from init_1_create_cluster.sh.
CONTEXT=kind-kind

# Helpers: kubectl on CONTEXT, and a bold step banner.
k() { kubectl --context "$CONTEXT" "$@"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# Fails fast on a missing kubectl, manifest or context.
command -v kubectl >/dev/null || { echo "kubectl not found: install it" >&2; exit 1; }
[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }
k config get-contexts "$CONTEXT" >/dev/null 2>&1 || {
  echo "context $CONTEXT not found: run init_1_create_cluster.sh" >&2
  exit 1
}

# Applies the manifest with INSPECTOR_IMAGE swapped in; sed writes to stdout, so no GNU -i.
step "apply ns inspect, image $INSPECTOR_IMAGE"
sed "s|image: $DEFAULT_IMAGE|image: $INSPECTOR_IMAGE|" "$MANIFEST" | k apply -f -

# Waits for both meshed Deployments to roll out.
step "rollout"
k -n inspect rollout status deploy/inspector --timeout=180s
k -n inspect rollout status deploy/client --timeout=180s

# Lists the pods; READY 3/3 and 2/2 show linkerd-proxy was injected.
step "ready"
k -n inspect get pods -o wide
