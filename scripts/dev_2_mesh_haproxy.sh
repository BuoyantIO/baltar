#!/usr/bin/env bash
# Usage: ./dev_2_mesh_haproxy.sh <mesh|unmesh> [CORES]
#   e.g. ./dev_2_mesh_haproxy.sh mesh        # mesh, proxy's own core default
#        ./dev_2_mesh_haproxy.sh mesh 3      # mesh AND pin CORES_MAX=3
#        ./dev_2_mesh_haproxy.sh unmesh
#
# CORES only applies to `mesh`; it sets the same
# LINKERD2_PROXY_CORES_MAX annotation dev_3_modify_linkerd_cores.sh
# does, but in the same upgrade that adds the sidecar, so a mesh+cores
# toggle is one rollout instead of two. Without CORES, `mesh` leaves
# whatever core pin was already on the pod template (dev_3's annotation
# survives helm upgrades, per the note below) or the proxy's own
# default if none was ever set.
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

CORES="${2:-}"
if [ -n "$CORES" ]; then
  case "$CORES" in ''|*[!0-9]*) echo "cores must be a positive integer" >&2; exit 1 ;; esac
  [ "$CORES" -gt 0 ] || { echo "cores must be a positive integer" >&2; exit 1; }
fi

case "${1:-}" in
  # Mesh: set the inject annotation via Helm values.
  #
  # Setting it as a Helm value is what lets unmesh revert it exactly.
  #
  # With CORES given, the core pin annotation goes through a values
  # FILE, not --set: its value is itself a JSON string
  # (`[{"name":"LINKERD2_PROXY_CORES_MAX",...}]`), and quoting that
  # through --set's own comma/dot escaping is what task 17 hit and
  # worked around with a file instead. --reset-values here for the
  # same reason unmesh uses it: the file is now the complete,
  # deterministic set of values, not a delta on top of history.
  mesh)
    if [ -n "$CORES" ]; then
      VALUES_FILE=$(mktemp)
      trap 'rm -f "$VALUES_FILE"' EXIT
      cat > "$VALUES_FILE" <<EOF
controller:
  podAnnotations:
    linkerd.io/inject: enabled
    config.linkerd.io/proxy-additional-env: '[{"name":"LINKERD2_PROXY_CORES_MAX","value":"$CORES"}]'
  service:
    nodePorts:
      http: $HAPROXY_NODEPORT
  replicaCount: ${REPLICAS:-1}
EOF
      helm upgrade "$RELEASE" "$CHART" -n "$NS" --reset-values -f "$VALUES_FILE"
    else
      helm upgrade "$RELEASE" "$CHART" -n "$NS" --reuse-values \
        --set 'controller.podAnnotations.linkerd\.io/inject=enabled' \
        ${REPLICAS:+--set controller.replicaCount=$REPLICAS}
    fi
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
  *) echo "usage: $0 <mesh|unmesh> [CORES]" >&2; exit 1 ;;
esac

# Wait for the replacement pods.
#
# The replacement pods are where the sidecar appears or disappears.
kubectl rollout status deploy/"$RELEASE"-kubernetes-ingress -n "$NS" --timeout=180s
