#!/usr/bin/env bash
# Shared helpers `k` and `pod_node_pid`; sourced, never run, so the caller owns `set -euo pipefail` and sets CONTEXT.

# Runs kubectl on the caller's CONTEXT, so no call can fall through to the current context.
k() { kubectl --context "$CONTEXT" "$@"; }

# Prints "<node> <pid>" for container $3 of pod $2 in namespace $1: its kind node and host pid.
# Native sidecars report under initContainerStatuses, so both status lists are read.
pod_node_pid() {
  local info node cid pid
  info=$(k -n "$1" get pod "$2" -o jsonpath="{.spec.nodeName} {.status.initContainerStatuses[?(@.name==\"$3\")].containerID}{.status.containerStatuses[?(@.name==\"$3\")].containerID}") || return
  read -r node cid <<<"$info"
  pid=$(docker exec "$node" crictl inspect -o go-template --template '{{.info.pid}}' "${cid#*://}") || return
  echo "$node $pid"
}
