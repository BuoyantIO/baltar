#!/usr/bin/env bash
# Loads k (kubectl on CONTEXT) and pod_node_pid.
# shellcheck source=scripts/util_kube.sh
. scripts/util_kube.sh

# Run from the baltar repo root.
# Usage: ./scripts/dev_11_pod_sysctl.sh
#        SYSCTL_KEY=net.ipv4.tcp_keepalive_time ./scripts/dev_11_pod_sysctl.sh
#        NAMESPACE=emojivoto SELECTOR=app=web-svc CONTEXT=kind-east ./scripts/dev_11_pod_sysctl.sh
#
# Prints, for every pod matching SELECTOR, its node, the SYSCTL_KEY value read inside the pod's netns
# (nsenter on CONTAINER's host pid from its kind node) and the node netns value.
# Pod netns start at the kernel default, while kube-proxy sets some keys (e.g. conntrack timeouts)
# only in the node netns, so the node value is a reference, not the pod's.
#
# Read-only: it changes nothing in the cluster or on the node.
#
# Env vars and defaults:
#   CONTEXT=kind-kind                                          kubectl context; nodes are read via docker exec
#   NAMESPACE=demo                                             namespace of the pods
#   SELECTOR=app=echo                                          label selector; every matching pod is printed
#   CONTAINER=linkerd-proxy                                    container whose pid gives the netns
#   SYSCTL_KEY=net.netfilter.nf_conntrack_tcp_timeout_close_wait   dotted key, read from /proc/sys/<key with / for .>
set -euo pipefail

# Inputs with defaults.
CONTEXT=${CONTEXT:-kind-kind}
NAMESPACE=${NAMESPACE:-demo}
SELECTOR=${SELECTOR:-app=echo}
CONTAINER=${CONTAINER:-linkerd-proxy}
SYSCTL_KEY=${SYSCTL_KEY:-net.netfilter.nf_conntrack_tcp_timeout_close_wait}
SYSCTL_PATH="/proc/sys/$(echo "$SYSCTL_KEY" | tr . /)"

# Lists the matching pods, one name per line.
PODS=$(k -n "$NAMESPACE" get pods -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

# One line per pod: the pod netns value, then the node netns value as a reference.
echo "[-] $SYSCTL_KEY in ns $NAMESPACE, -l $SELECTOR"
printf '%-45s %-25s %-10s %s\n' POD NODE POD_NETNS NODE_NETNS
while read -r pod; do
  [ -n "$pod" ] || continue
  np=$(pod_node_pid "$NAMESPACE" "$pod" "$CONTAINER")
  read -r node pid <<<"$np"
  pod_val=$(docker exec "$node" nsenter -t "$pid" -n cat "$SYSCTL_PATH")
  node_val=$(docker exec "$node" cat "$SYSCTL_PATH")
  printf '%-45s %-25s %-10s %s\n' "$pod" "$node" "$pod_val" "$node_val"
done <<EOF2
$PODS
EOF2
