#!/usr/bin/env bash
# Usage: ./dev_1_mesh_emojivoto.sh <mesh|unmesh>
# Meshes or unmeshes the emojivoto deployments by re-applying them
# through `linkerd inject` or `linkerd uninject`.
#
# The mesh_<n>_ prefix marks a script that meshes or unmeshes a
# workload: not setup, not a port-forward, and safe to run against a
# cluster that is already up.
set -euo pipefail

NS=emojivoto

case "${1:-}" in
  mesh)
    # `linkerd inject` SKIPS any workload carrying
    # linkerd.io/inject=disabled, reporting 'deployment "web" skipped'
    # and emitting the manifest unchanged. Clear the annotation first or
    # mesh is a silent no-op.
    for DEPLOY in $(kubectl get -n "$NS" deploy -o name); do
      kubectl -n "$NS" patch "$DEPLOY" \
        -p '{"spec":{"template":{"metadata":{"annotations":{"linkerd.io/inject":null}}}}}'
    done
    kubectl get -n "$NS" deploy -o yaml | linkerd inject - | kubectl apply -f -
    ;;
  unmesh)
    # uninject alone is enough: the emojivoto namespace carries no
    # inject annotation, so nothing re-injects the new pods. Do not
    # patch linkerd.io/inject=disabled here, which would block a later
    # mesh.
    kubectl get -n "$NS" deploy -o yaml | linkerd uninject - | kubectl apply -f -
    ;;
  *) echo "usage: $0 <mesh|unmesh>" >&2; exit 1 ;;
esac

# Wait for the replacement pods, which is where the sidecar appears or
# disappears.
for DEPLOY in $(kubectl get -n "$NS" deploy -o name); do
  kubectl rollout status "$DEPLOY" -n "$NS" --timeout=180s
done

# Only meaningful when there are proxies to check.
if [ "$1" = mesh ]; then
  linkerd -n "$NS" check --proxy
fi
