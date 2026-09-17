#!/usr/bin/env bash
# Usage: ./dev_2_mesh_haproxy.sh <mesh|unmesh>
#
# The kubectl port-forward on :8080 dies with the old pods, so restart
# it after.
set -euo pipefail

# Helm release name, its namespace, and the chart it was installed from.
RELEASE=haproxy-ingress
NS=haproxy-controller
CHART=haproxytech/kubernetes-ingress

# Every upgrade of this chart has to carry two things, or it silently
# undoes them. Both measured 2026-09-17, not assumed.
#
# The first is the NodePort, because `--reset-values` drops it and the
# chart default is `nodePorts: {}`, documented as "If empty, random
# ports will be used". init_7 pins it precisely so a saved load-test
# URL keeps working. Same variable name as init_7, keep them in step.
HAPROXY_NODEPORT="${HAPROXY_NODEPORT:-31080}"
#
# The second is the replica count: read the live value and pass it
# back.
#
# `replicas` is a field the chart RENDERS, and a rendered field is
# reconciled against the live object and patched back even when its
# rendered value did not change between releases. So a `kubectl scale`
# (dev_7_scale_workloads.sh) is reverted by any upgrade here,
# mid-measurement.
#
# The proxy's core pin needs NO such treatment: dev_3 writes an
# annotation the chart renders in neither manifest, so helm leaves it
# alone. Pin once with dev_3 and it survives every toggle.
REPLICAS=$(kubectl get deploy "$RELEASE"-kubernetes-ingress -n "$NS" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || true)

case "${1:-}" in
  # Mesh: set the inject annotation via Helm values.
  #
  # Setting it as a Helm value is what lets unmesh revert it exactly.
  mesh)
    helm upgrade "$RELEASE" "$CHART" -n "$NS" --reuse-values \
      --set 'controller.podAnnotations.linkerd\.io/inject=enabled' \
      ${REPLICAS:+--set controller.replicaCount=$REPLICAS}
    ;;
  # Unmesh: drop all user-supplied values, returning to chart
  # defaults.
  #
  # The NodePort and replica count are the exception: they are
  # re-pinned above.
  unmesh)
    helm upgrade "$RELEASE" "$CHART" -n "$NS" --reset-values \
      --set controller.service.nodePorts.http="$HAPROXY_NODEPORT" \
      ${REPLICAS:+--set controller.replicaCount=$REPLICAS}
    ;;
  *) echo "usage: $0 <mesh|unmesh>" >&2; exit 1 ;;
esac

# Wait for the replacement pods.
#
# The replacement pods are where the sidecar appears or disappears.
kubectl rollout status deploy/"$RELEASE"-kubernetes-ingress -n "$NS" --timeout=180s
