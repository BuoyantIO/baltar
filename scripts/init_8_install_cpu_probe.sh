#!/usr/bin/env bash
# Run from the baltar repo root.
# Usage: ./scripts/init_8_install_cpu_probe.sh
#
# Setup step 8. Installs the cpu-probe DaemonSet, which mounts each
# node's /sys/fs/cgroup read-only so `kubectl exec` can read container
# CPU counters.
#
# The proxy's own process_cpu_seconds_total only exists where there is a
# proxy, so it cannot measure an unmeshed workload. The cgroup v2
# counter exists for every container either way, but on a kind node it
# is otherwise only reachable via `docker exec`. A pod with a hostPath
# mount reaches the same tree through kubectl.
#
# The probe does no measuring. It is a mount point with a shell. The
# sampler reads through it.
set -euo pipefail

echo "=== Installing cpu-probe DaemonSet ==="
kubectl apply -f scripts/init_8_cpu_probe.yaml

kubectl rollout status daemonset/cpu-probe -n kube-system --timeout=120s

# Proves the mount works rather than trusting that the pod is Running.
#
# A Ready pod with an empty or wrong cgroup tree looks identical here.
POD=$(kubectl get pod -n kube-system -l app=cpu-probe \
        -o jsonpath='{.items[0].metadata.name}')

if ! kubectl exec -n kube-system "$POD" -- \
       test -f /hostcgroup/cgroup.controllers; then
  echo "cpu-probe: /hostcgroup is not a cgroup v2 root" >&2
  exit 1
fi

COUNT=$(kubectl exec -n kube-system "$POD" -- sh -c \
  'find /hostcgroup/kubelet.slice/kubelet-kubepods.slice -maxdepth 3 -name cpu.stat 2>/dev/null | wc -l')

echo "cpu-probe ready: $POD sees $COUNT container cgroups"
