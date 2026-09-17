#!/usr/bin/env bash
# Usage: ./dev_4_inspect_cores.sh [NAMESPACE] [WORKLOAD]
#   e.g. ./dev_4_inspect_cores.sh
#        ./dev_4_inspect_cores.sh grafana deploy/grafana
# Defaults to emojivoto deploy/web, matching
# dev_3_modify_linkerd_cores.sh.
#
# Shows what the proxy's core settings are and what the proxy actually
# did with them. Pairs with dev_3_modify_linkerd_cores.sh: run this
# before and after to see the change.
#
# The inspect_<n>_ prefix marks a read-only script. It changes nothing.
set -euo pipefail

NS="${1:-emojivoto}"
WORKLOAD="${2:-deploy/web}"

echo "=== 1. Configured: proxy-additional-env annotation on the pod template ==="
# Only the pod template annotation has any effect; the Deployment's own does nothing.
kubectl get "$WORKLOAD" -n "$NS" \
  -o jsonpath='{.spec.template.metadata.annotations.config\.linkerd\.io/proxy-additional-env}' \
  || true
echo

echo "=== 2. Configured: CORES env actually set on the running proxy container ==="
SELECTOR=$(kubectl get "$WORKLOAD" -n "$NS" \
  -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' | sed 's/,$//')
# Newest pod, not .items[0]. During a rollout the old pod is still
# Running and sorts first, which makes this script report the setting
# you just replaced.
POD=$(kubectl get pods -n "$NS" -l "$SELECTOR" \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
COUNT=$(kubectl get pods -n "$NS" -l "$SELECTOR" --no-headers | wc -l | tr -d ' ')
[ "$COUNT" -gt 1 ] && echo "(note: $COUNT pods match; a rollout may be in progress. Reporting the newest.)"
echo "pod: $POD"
kubectl get pod "$POD" -n "$NS" -o go-template='{{range .spec.initContainers}}{{if eq .name "linkerd-proxy"}}{{range .env}}{{if or (eq .name "LINKERD2_PROXY_CORES_MAX") (eq .name "LINKERD2_PROXY_CORES") (eq .name "LINKERD2_PROXY_CORES_MIN")}}{{.name}}={{.value}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}'
kubectl get pod "$POD" -n "$NS" -o jsonpath='{range .spec.initContainers[?(@.name=="linkerd-proxy")]}cpu limit={.resources.limits.cpu} request={.resources.requests.cpu}{"\n"}{end}'

echo "=== 3. Decided: what the proxy chose at startup ==="
# The proxy announces its own decision, from linkerd2_proxy::rt. This is
# intent, not observed OS threads.
kubectl logs -n "$NS" "$POD" -c linkerd-proxy 2>/dev/null | grep -i 'proxy runtime' || echo "(no 'proxy runtime' line found)"

echo "=== 4. Observed: tokio_rt_workers, the real worker count ==="
# Do not count threads named "proxy"; tokio_rt_workers is the number.
# Scoped to the one pod above, not the workload: proxy-metrics answers
# for every pod behind a workload, so a rollout prints two numbers.
linkerd diagnostics proxy-metrics -n "$NS" "po/$POD" 2>/dev/null \
  | awk '/^tokio_rt_workers /{print "tokio_rt_workers =", $2}' \
  || echo "(proxy-metrics unavailable; is the workload meshed?)"
