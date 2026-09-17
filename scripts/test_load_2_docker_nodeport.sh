#!/usr/bin/env bash
# Load test straight at the NodePort, no tunnel in the path: a plain
# Docker container on the `kind` network, bypassing kubectl port-forward.
# Named for what it hits, not where the generator runs, because the
# `kind` network goes away if the cluster moves to a VM.
# Usage: test_load_2_docker_nodeport.sh [CONNECTIONS] [DURATION] [URL]
#
# Docker is not incidental. Docker Desktop does not route to container
# IPs from macOS, so the node's NodePort is unreachable from the host:
# only a container on the `kind` network can hit it.
set -euo pipefail

CONNS="${1:-125}"
DURATION="${2:-30s}"

# Derived, not hardcoded: the NodePort is reassigned on every install of
# the haproxy chart, and the node IP changes with the cluster. The old
# hardcoded 172.18.0.2:31605 silently hit nothing after a rebuild.
if [ -z "${3:-}" ]; then
  NODE_IP=$(kubectl get node kind-control-plane \
    -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  NODE_PORT=$(kubectl get svc -n haproxy-controller haproxy-ingress-kubernetes-ingress \
    -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
  [ -n "$NODE_IP" ] && [ -n "$NODE_PORT" ] || {
    echo "could not derive node IP or NodePort; is the cluster up and haproxy installed?" >&2
    exit 1
  }
  URL="http://${NODE_IP}:${NODE_PORT}/"
else
  URL="$3"
fi

echo "load testing $URL" >&2

exec docker run --rm --network kind alpine/bombardier \
  -c "$CONNS" -d "$DURATION" -l --print r "$URL"
