#!/usr/bin/env bash
# Loads k (kubectl on CONTEXT).
# shellcheck source=scripts/util_kube.sh
. scripts/util_kube.sh

# Run from the baltar repo root.
# Usage: ./scripts/tm_1_namespace_scope.sh
#        CONTEXT=kind-kind NS_A=a NS_B=b SETTLE=30 ./scripts/tm_1_namespace_scope.sh
#
# Checks linkerd-destination never puts an ExternalWorkload from NS_A into an EndpointSlice of a Service in NS_B.
# Applies tm_1_namespace_scope.yaml; prints `pass` and exits 0, or `fail: ...` lines and exits 1.
# Cleanup: kubectl delete ns tm-scope-a tm-scope-b
#
# Env vars and defaults:
#   CONTEXT=$(kubectl config current-context)   kubectl context
#   NS_A=tm-scope-a                             namespace of the ExternalWorkload and control Service
#   NS_B=tm-scope-b                             namespace of the same-selector Service that must stay empty of it
#   WORKLOAD_IP=10.99.0.1                       ExternalWorkload IP
#   SETTLE=20                                   seconds to wait after apply for the controller to reconcile
set -euo pipefail

# Inputs with defaults; the manifest sits next to this script.
CONTEXT=${CONTEXT:-$(kubectl config current-context)}
NS_A=${NS_A:-tm-scope-a}
NS_B=${NS_B:-tm-scope-b}
WORKLOAD_IP=${WORKLOAD_IP:-10.99.0.1}
SETTLE=${SETTLE:-20}
MANIFEST=scripts/tm_1_namespace_scope.yaml

# Fills the manifest placeholders and applies it.
echo "[-] apply ns $NS_A, $NS_B, ExternalWorkload $NS_A/tm-ew ($WORKLOAD_IP), svc tm-svc in both"
manifest=$(<"$MANIFEST")
manifest=${manifest//"<NS_A_PLACEHOLDER>"/"$NS_A"}
manifest=${manifest//"<NS_B_PLACEHOLDER>"/"$NS_B"}
manifest=${manifest//"<WORKLOAD_IP_PLACEHOLDER>"/"$WORKLOAD_IP"}
printf '%s\n' "$manifest" | k apply -f -

# Gives the controller time to write EndpointSlices; there is no condition to wait on for their absence.
echo "[-] settle ${SETTLE}s"
sleep "$SETTLE"

# Positive control: the A Service's slice must reference the ExternalWorkload, proving the controller ran.
echo "[-] control: EndpointSlice in $NS_A references ExternalWorkload tm-ew"
if ! k -n "$NS_A" get endpointslice -l kubernetes.io/service-name=tm-svc \
  -o jsonpath='{range .items[*].endpoints[*]}{.targetRef.kind}/{.targetRef.name}{"\n"}{end}' \
  | grep -qx 'ExternalWorkload/tm-ew'; then
  echo "fail: control: no EndpointSlice in $NS_A references ExternalWorkload $NS_A/tm-ew"
  exit 1
fi

# Emits one line per endpoint in NS_B and keeps those pointing at an ExternalWorkload, NS_A or WORKLOAD_IP.
# A `slice` line precedes each slice's endpoints since jsonpath cannot reach the parent name from inside.
echo "[-] invariant: no EndpointSlice in $NS_B references $NS_A or an ExternalWorkload"
offenders=$(k -n "$NS_B" get endpointslice -o jsonpath='{range .items[*]}{"slice\t"}{.metadata.name}{"\n"}{range .endpoints[*]}{"ep\t"}{.targetRef.kind}{"\t"}{.targetRef.namespace}{"\t"}{.targetRef.name}{"\t"}{.addresses[*]}{"\n"}{end}{end}' \
  | awk -F'\t' -v ns_a="$NS_A" -v ip="$WORKLOAD_IP" '
    $1 == "slice" { slice = $2; next }
    $2 == "ExternalWorkload" || $3 == ns_a || index(" " $5 " ", " " ip " ") { print slice "|" $2 "|" $3 "|" $4 "|" $5 }')

# Passes when nothing in NS_B matched.
if [ -z "$offenders" ]; then
  echo "pass"
  exit 0
fi

# Reports each offending endpoint and dumps its slice.
while IFS='|' read -r slice kind ns name addr; do
  echo "fail: endpointslice $NS_B/$slice references $kind $ns/$name $addr"
  k -n "$NS_B" get endpointslice "$slice" -o yaml
done <<< "$offenders"
exit 1
