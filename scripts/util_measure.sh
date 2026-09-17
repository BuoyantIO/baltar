#!/usr/bin/env bash
# Shared helpers for the CPU sampler.
#
# Sourced by dev_5_measure_start.sh and dev_6_measure_stop.sh. Not
# executable and never run directly: util_measure.sh defines things
# and does nothing.
#
# What belongs here: only what BOTH scripts genuinely need, which is
# the state-dir layout and the paths inside it, locating the probe
# pod, the in-pod reaper, the cgroup and container-id contract the two
# ends agree on, resolving a workload to its pods and their mesh
# state, and the CSV schema.
#
# What does not: anything only one side uses. The in-pod collector
# loop and the reconnect loop are start's alone; the CSV build, its
# gap threshold and the awk that joins samples to the inventory are
# stop's alone. Putting either here would make this file the script
# and the scripts a wrapper.

PROBE_NS="${PROBE_NS:-kube-system}"
PROBE_SELECTOR="${PROBE_SELECTOR:-app=cpu-probe}"
DIR="${CPU_SAMPLER_DIR:-$HOME/.cache/kube-cpu-sampler}"
# One state file, holding "<pid> <run> <ns> <workload>".
#
# `stop` needs all of it: the run names the files and the workload
# names the CSV columns.
STATE="$DIR/collector.state"

mkdir -p "$DIR"

# Three files per run, all keyed by the run name.
#
# Keying by the run name is what stops runs colliding. .raw is the
# append-only sample stream, .inv the container-id inventory it is
# joined against, .csv the deliverable.
raw_path() { echo "$DIR/$1.raw"; }
inv_path() { echo "$DIR/$1.inv"; }
csv_path() { echo "$DIR/$1.csv"; }

# Collector detection is internal, not a `status` subcommand.
#
# The only reason anyone needed to ask was to find out whether `start`
# was safe, and `start` can answer that itself.
collector_pid() {
  [ -f "$STATE" ] || return 1
  local pid; pid=$(awk -F'\t' '{print $1}' "$STATE" 2>/dev/null)
  [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null || return 1
  echo "$pid"
}
state_field() { awk -F'\t' -v n="$1" '{print $n}' "$STATE" 2>/dev/null; }

# The CSV schema, in one place.
#
# `stop` writes this header and the columns are the contract every
# run's file is read against.
CSV_HEADER="ts_epoch,t_s,run,namespace,pod,container,role,mesh,container_id,usage_usec,delta_usec,interval_s,cpu_pct_core,event"

# ---------------------------------------------------------------- probe

probe_pod() {
  # Fail loudly rather than creating anything.
  #
  # The DaemonSet is owned by init_8, and a sampler that installs
  # cluster resources is a sampler that can break the thing it is
  # measuring.
  local pod
  pod=$(kubectl get pod -n "$PROBE_NS" -l "$PROBE_SELECTOR" \
          --field-selector=status.phase=Running \
          -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -z "$pod" ]; then
    echo "no Running pod matching $PROBE_SELECTOR in $PROBE_NS." >&2
    echo "run scripts/init_8_install_cpu_probe.sh first." >&2
    return 1
  fi
  echo "$pod"
}

# The two constants the pod end of the contract is built from.
#
# They are shared because the reaper below greps for the same mark the
# collector loop in dev_5_measure_start.sh sets, and a mark that
# drifted between the two files would silently stop reaping.
#
# The container id is derived from the cgroup directory name:
# $PROBE_CGROOT/.../cri-containerd-<id>.scope, stripped of prefix and
# suffix. It has to come out equal to the inventory's containerID with
# "containerd://" stripped (see dump_inventory), or the join in `stop`
# matches nothing.
PROBE_MARK="cpusampler_collector"
PROBE_CGROOT="/hostcgroup/kubelet.slice/kubelet-kubepods.slice"

# Killing the local `kubectl exec` does NOT kill the loop inside the
# pod.
#
# Measured 2026-09-17, four stale loops were left behind by four
# dropped streams, each still reading every cgroup once a second. The
# write to a closed stream never raises EPIPE in the pod, so the loop
# cannot notice on its own. It has to be reaped by name, which is what
# MARK is for. Left unreaped they accumulate and double the sample
# rate.
#
# This assumes one collector per cluster. A second laptop streaming
# from the same probe pod would be reaped by this one.
read -r -d '' INPOD_REAP_BODY <<'EOS' || true
# usage_usec catches the awk the loop is blocked inside. It is blocked
# because the exec pipe is closed at the laptop end but still open and
# unread at the pod end, so the write never fails: the loop is parked in
# write(2), not spinning. Killing the shell alone leaves that awk.
# Newest pid first, so awk dies before the shell that must reap it.
# Anything that still outlives its parent is reparented to the pod's
# PID 1, which is a shell loop that reaps it (init_8_cpu_probe.yaml);
# when PID 1 was `sleep infinity` those stayed zombies until the pod
# restarted.
for p in $(ps -o pid,args 2>/dev/null | grep -e "$MARK" -e usage_usec | grep -v grep | awk '{print $1}' | sort -rn); do
  [ "$p" = "$$" ] && continue
  kill "$p" 2>/dev/null
done
exit 0
EOS
# The mark is prepended rather than written into the heredoc.
#
# Prepending keeps it one constant. The heredoc itself is quoted so
# that $MARK, $$ and the ps substitution reach the pod's shell
# unexpanded.
INPOD_REAP="MARK=$PROBE_MARK
$INPOD_REAP_BODY"

# Called before every connect and at shutdown, by both scripts.
#
# `start` calls it because a previous collector's loop may still be
# ticking, `stop` because a SIGKILLed collector never ran its own
# handler.
reap_inpod_loops() {
  local pod
  pod=$(probe_pod 2>/dev/null) || return 0
  kubectl exec -n "$PROBE_NS" "$pod" -- sh -c "$INPOD_REAP" >/dev/null 2>&1 || true
  return 0
}

# ------------------------------------------------------- workload lookup

# The selector is read once.
#
# A Deployment's .spec.selector is immutable, so it survives every
# roll the run has to cope with, while pod names and container ids do
# not.
workload_selector() {
  local ns="$1" workload="$2" sel
  sel=$(kubectl get "$workload" -n "$ns" \
          -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null | sed 's/,$//')
  [ -n "$sel" ] || { echo "cannot resolve $workload in namespace $ns" >&2; return 1; }
  echo "$sel"
}

# Mesh state comes from the UNION of initContainers and containers.
#
# .spec.containers alone is wrong because the proxy is usually a
# native sidecar (an init container), so a meshed pod would read as
# unmeshed. And initContainers alone is also wrong: linkerd-identity's
# own proxy is a regular container, verified on this cluster
# 2026-09-17.
#
# Only this workload's pods are dumped. Every container of those pods
# is, app and proxy alike, because attributing the mesh's cost is the
# point.
dump_inventory() {
  local ns="$1" sel="$2" ts
  ts=$(date +%s)
  kubectl get pods -n "$ns" -l "$sel" -o json | jq -r --arg ts "$ts" '
    .items[] | . as $p
    | ((($p.spec.initContainers // []) + ($p.spec.containers // []))
       | map(.name) | index("linkerd-proxy")) as $px
    | (if $px == null then "unmeshed" else "meshed" end) as $mesh
    | ((($p.status.containerStatuses // []) | map(. + {kind: "app"}))
       + (($p.status.initContainerStatuses // []) | map(. + {kind: "init"})))[]
    | select(.containerID != null)
    | [ $ts,
        (.containerID | sub("^containerd://"; "")),
        $p.metadata.namespace, $p.metadata.name, .name,
        (if .name == "linkerd-proxy" then "proxy" else .kind end),
        $mesh ] | @tsv'
}
