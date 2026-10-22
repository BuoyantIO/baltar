#!/usr/bin/env bash
# Shows the proxy's core settings and what the proxy did with them.
# Run from the baltar repo root. Pairs with dev_3: run before and after.
#
# Usage:
#   ./scripts/dev_4_inspect_cores.sh
#   ./scripts/dev_4_inspect_cores.sh grafana deploy/grafana
#
# Args and defaults:
#   $1 NAMESPACE: emojivoto
#   $2 WORKLOAD: deploy/web
set -euo pipefail

NS="${1:-emojivoto}"
WORKLOAD="${2:-deploy/web}"

echo "=== 1. Configured: proxy-additional-env annotation on the pod template ==="
# Only the pod template annotation has any effect; the Deployment's own does nothing.
kubectl get "$WORKLOAD" -n "$NS" \
  -o jsonpath='{.spec.template.metadata.annotations.config\.linkerd\.io/proxy-additional-env}'
echo

echo "=== 2. Configured: CORES env actually set on the running proxy container ==="
# shellcheck disable=SC2016 # $k and $v are go-template vars, not shell.
LABELS=$(kubectl get "$WORKLOAD" -n "$NS" \
  -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}')
SELECTOR=$(echo "$LABELS" | sed 's/,$//')
# Take the newest pod, not .items[0].
# During a rollout the old pod is still Running and sorts first, reporting the setting just replaced.
POD=$(kubectl get pods -n "$NS" -l "$SELECTOR" \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
echo "pod: $POD"
PROXY_ENV=$(kubectl get pod "$POD" -n "$NS" \
  -o jsonpath='{range .spec.initContainers[?(@.name=="linkerd-proxy")].env[*]}{.name}={.value}{"\n"}{end}')
echo "$PROXY_ENV" | sed -n '/CORES/p'
CPU=$(kubectl get pod "$POD" -n "$NS" \
  -o jsonpath='{range .spec.initContainers[?(@.name=="linkerd-proxy")]}limit={.resources.limits.cpu} request={.resources.requests.cpu}{end}')
echo "cpu $CPU"

echo "=== 3. Decided: what the proxy chose at startup ==="
# The proxy logs its decision from linkerd2_proxy::rt: intent, not observed OS threads.
LOGS=$(kubectl logs -n "$NS" "$POD" -c linkerd-proxy)
echo "$LOGS" | sed -n '/[Pp]roxy runtime/p'

echo "=== 4. Observed: tokio_rt_workers, the real worker count ==="
# Scoped to one pod: proxy-metrics on a workload answers for every pod behind it.
METRICS=$(linkerd diagnostics proxy-metrics -n "$NS" "po/$POD")
echo "$METRICS" | sed -n '/^tokio_rt_workers /p'
