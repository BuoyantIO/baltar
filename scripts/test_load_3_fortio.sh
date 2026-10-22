#!/usr/bin/env bash
# Loads k (kubectl on CONTEXT).
# shellcheck source=scripts/util_kube.sh
. scripts/util_kube.sh

# Run from the baltar repo root.
# Usage: TARGET_URL=http://svc.ns:8080/ NAMESPACE=ns ./scripts/test_load_3_fortio.sh
#        CONNECTIONS=500 QPS=100 TARGET_URL=http://svc.ns:8080/ NAMESPACE=ns ./scripts/test_load_3_fortio.sh
#
# Load test inside the mesh: deploys test_load_3_fortio.yaml, a meshed fortio client (deploy/load in NAMESPACE)
# holding many long-lived connections to TARGET_URL under steady load until it is deleted.
# Deletes the Deployment first so the pod restarts with the currently installed proxy; safe to rerun.
#
#  pod load                            target
#  +---------------------+  mTLS      +------------+
#  | fortio --> linkerd- |----------->| TARGET_URL |
#  | -c CONNECTIONS proxy|            +------------+
#  | -qps QPS            |
#  +---------------------+
#
# Env vars and defaults:
#   CONTEXT=kind-kind                     kubectl context
#   NAMESPACE                             required: namespace of deploy/load; must exist
#   TARGET_URL                            required: fortio target URL
#   CONNECTIONS=2000                      fortio -c, concurrent long-lived connections
#   QPS=500                               fortio -qps, total requests per second across all connections
set -euo pipefail

# Inputs: NAMESPACE and TARGET_URL are required, the rest default; the manifest sits next to this script.
NAMESPACE=${NAMESPACE:?set NAMESPACE, e.g. TARGET_URL=http://svc.ns:8080/ NAMESPACE=ns $0}
TARGET_URL=${TARGET_URL:?set TARGET_URL, e.g. TARGET_URL=http://svc.ns:8080/ NAMESPACE=ns $0}
CONTEXT=${CONTEXT:-kind-kind}
CONNECTIONS=${CONNECTIONS:-2000}
QPS=${QPS:-500}
MANIFEST=scripts/test_load_3_fortio.yaml

# Deletes the workload so the re-applied pod gets the currently installed proxy.
echo "[-] delete deploy/load in ns $NAMESPACE"
k -n "$NAMESPACE" delete deploy load --ignore-not-found --wait

# Fills the manifest placeholders and applies it.
# Quoted replacements keep & literal under bash 5.2 patsub_replacement; bash 3.2 never expands it.
echo "[-] apply deploy/load, -c $CONNECTIONS -qps $QPS $TARGET_URL"
manifest=$(<"$MANIFEST")
manifest=${manifest//"<CONNECTIONS_PLACEHOLDER>"/"$CONNECTIONS"}
manifest=${manifest//"<QPS_PLACEHOLDER>"/"$QPS"}
manifest=${manifest//"<TARGET_URL_PLACEHOLDER>"/"$TARGET_URL"}
printf '%s\n' "$manifest" | k -n "$NAMESPACE" apply -f -

# Waits for the meshed Deployment to roll out.
echo "[-] rollout"
k -n "$NAMESPACE" rollout status deploy/load --timeout=180s

# Lists the pods; READY 2/2 shows linkerd-proxy was injected.
echo "[-] ready"
k -n "$NAMESPACE" get pods -o wide
