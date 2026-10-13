#!/usr/bin/env bash
# Usage: ./dev_9_proxy_memory.sh
#        MEM_NAMESPACE=emojivoto MEM_SELECTOR=app=web-svc ./dev_9_proxy_memory.sh
#        CONTEXT=kind-launchy ./dev_9_proxy_memory.sh
#
# Prints, for every pod matching MEM_SELECTOR, the MEM_CONTAINER process's Rss and AnonHugePages
# from /proc/<pid>/smaps_rollup on its kind node, with the node's transparent_hugepage setting and
# architecture, since both change what those numbers mean.
#
# Read-only: it changes nothing in the cluster or on the node.
#
#  kubectl: pod -> nodeName, containerID     docker exec <node> (kind node container)
#  (init or regular container status)  --->  crictl inspect <id> -> host pid
#                                            /proc/<pid>/smaps_rollup
#
# Env vars and defaults:
#   CONTEXT=<current>             kubectl context; must start with kind- because nodes are read via docker exec
#   MEM_NAMESPACE=demo            namespace of the pods
#   MEM_SELECTOR=app=echo         label selector; every matching pod is printed
#   MEM_CONTAINER=linkerd-proxy   container to read; looked up in init and regular containers
set -euo pipefail

# Inputs with defaults; CONTEXT falls back to the current kubectl context.
CONTEXT=${CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}
MEM_NAMESPACE=${MEM_NAMESPACE:-demo}
MEM_SELECTOR=${MEM_SELECTOR:-app=echo}
MEM_CONTAINER=${MEM_CONTAINER:-linkerd-proxy}

# Helpers: kubectl on CONTEXT, and exit with a message.
k() { kubectl --context "$CONTEXT" "$@"; }
die() { echo "$*" >&2; exit 1; }

# Fails fast on missing tools or a non-kind context.
command -v kubectl >/dev/null || die "kubectl not found: install it"
command -v docker >/dev/null || die "docker not found: kind nodes are read with docker exec"
case "$CONTEXT" in
  kind-*) ;;
  *) die "context '${CONTEXT:-<none>}' does not start with kind-: refusing, nodes are read via docker exec" ;;
esac

# One line per pod: name|node|containerID|image; native sidecars report under initContainerStatuses.
# '|' rather than tab, since read collapses adjacent tabs and an empty field would shift the rest.
JP='{range .items[*]}{.metadata.name}{"|"}{.spec.nodeName}{"|"}'
JP+="{.status.initContainerStatuses[?(@.name==\"$MEM_CONTAINER\")].containerID}"
JP+="{.status.containerStatuses[?(@.name==\"$MEM_CONTAINER\")].containerID}{\"|\"}"
JP+="{.status.initContainerStatuses[?(@.name==\"$MEM_CONTAINER\")].image}"
JP+="{.status.containerStatuses[?(@.name==\"$MEM_CONTAINER\")].image}{\"\\n\"}{end}"
PODS=$(k -n "$MEM_NAMESPACE" get pods -l "$MEM_SELECTOR" -o jsonpath="$JP") \
  || die "kubectl get pods failed in ns $MEM_NAMESPACE on context $CONTEXT"
[ -n "$PODS" ] || die "no pod matches -l $MEM_SELECTOR in ns $MEM_NAMESPACE"

# Runs inside the node: container id -> host pid -> smaps_rollup fields, THP setting, architecture.
# Passed as $1 to sh -c so the id is never spliced into the command string.
# shellcheck disable=SC2016 # expanded by the node's sh, not here
INNODE='
command -v crictl >/dev/null || exit 3
pid=$(crictl inspect -o go-template --template "{{.info.pid}}" "$1") || exit 4
[ -n "$pid" ] && [ -r "/proc/$pid/smaps_rollup" ] || { echo "no readable /proc/$pid/smaps_rollup" >&2; exit 4; }
grep -E "^(Rss|AnonHugePages):" "/proc/$pid/smaps_rollup"
echo "thp: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
echo "arch: $(uname -m)"
'

# One block per pod; any missing container, node or crictl stops the run.
while IFS='|' read -r pod node cid image; do
  [ -n "$cid" ] || die "pod $pod has no started container $MEM_CONTAINER (checked init and regular containers)"
  [ -n "$node" ] || die "pod $pod is not scheduled on a node"
  docker inspect --type container "$node" >/dev/null 2>&1 \
    || die "node container $node not found in docker: is $CONTEXT a local kind cluster?"
  rc=0
  out=$(docker exec "$node" sh -c "$INNODE" sh "${cid#*://}") || rc=$?
  case "$rc" in
    0) ;;
    3) die "crictl not found in node $node" ;;
    *) die "reading $MEM_CONTAINER of pod $pod on node $node failed (rc=$rc)" ;;
  esac
  printf 'pod:                          %s\n' "$pod"
  printf 'node:                         %s\n' "$node"
  printf 'image:                        %s\n' "$image"
  printf '%s\n' "$out" | awk '
    $1 == "Rss:"           { printf "Rss:                          %s kB\n", $2 }
    $1 == "AnonHugePages:" { printf "AnonHugePages:                %s kB\n", $2 }
    $1 == "thp:"           { sub(/^thp: /, ""); printf "transparent_hugepage/enabled: %s\n", $0 }
    $1 == "arch:"          { printf "arch:                         %s\n", $2 }'
  echo
done <<EOF
$PODS
EOF
