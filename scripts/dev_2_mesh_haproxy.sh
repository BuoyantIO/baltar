#!/usr/bin/env bash
# Usage: ./dev_2_mesh_haproxy.sh <mesh|unmesh>
# The kubectl port-forward on :8080 dies with the old pods; restart it after.
set -euo pipefail

# Helm release name, its namespace, and the chart it was installed from.
RELEASE=haproxy-ingress
NS=haproxy-controller
CHART=haproxytech/kubernetes-ingress

case "${1:-}" in
  # Mesh: set the inject annotation via Helm values, so unmesh can revert exactly.
  mesh)
    helm upgrade "$RELEASE" "$CHART" -n "$NS" --reuse-values \
      --set 'controller.podAnnotations.linkerd\.io/inject=enabled'
    ;;
  # Unmesh: drop all user-supplied values, returning to chart defaults.
  unmesh)
    helm upgrade "$RELEASE" "$CHART" -n "$NS" --reset-values
    ;;
  *) echo "usage: $0 <mesh|unmesh>" >&2; exit 1 ;;
esac

# Wait for the replacement pods, which is where the sidecar appears or disappears.
kubectl rollout status deploy/"$RELEASE"-kubernetes-ingress -n "$NS" --timeout=180s
