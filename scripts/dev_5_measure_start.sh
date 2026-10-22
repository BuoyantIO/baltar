#!/usr/bin/env bash
# Loads the sampler state helpers.
# shellcheck source=scripts/util_measure.sh
. scripts/util_measure.sh

# Run from the baltar repo root.
# Usage: ./scripts/dev_5_measure_start.sh <run-name> <namespace> <workload>
#
#   <run-name>   titles the run and names its CSV, <run-name>.csv
#   <namespace>  the namespace the workload lives in
#   <workload>   the one workload to sample, as `deploy/web` (the same
#                argument style dev_4_inspect_cores.sh takes, so both
#                can be pointed at a thing by copy-paste)
#
# Samples every container of that workload's pods once a second and
# blocks until ./scripts/dev_6_measure_stop.sh ends the run and writes the CSV.
#
# Three terminals, because the sampler never generates load: driving the
# load is somebody else's terminal, and so is meshing or unmeshing.
#
#   term 1:  ./scripts/dev_5_measure_start.sh unmeshed-web emojivoto deploy/web
#   term 2:  ./scripts/test_load_2_docker_nodeport.sh 125 30s
#   term 3:  ./scripts/dev_6_measure_stop.sh
#
# A run name cannot be reused: if <run-name>.csv already exists this
# exits before taking a single sample.
#
# Finding out at `stop` that the name was taken would mean the load
# test is wasted.
#
# Measures and nothing else.
#
# It never generates load and never meshes or unmeshes anything,
# creates and deletes no Kubernetes resources, and never uses
# `docker exec`.
#
# The counter is cgroup v2 `usage_usec`, read through the cpu-probe
# DaemonSet (init_8_install_cpu_probe.sh).
#
# That counter exists for every container whether or not it has a
# proxy, which is the whole point: the proxy's own
# process_cpu_seconds_total cannot measure an unmeshed workload. Reads
# go through `kubectl exec`; `docker exec` is blocked and would not
# work on a remote cluster anyway.
#
# Collection stays untargeted inside the pod (every container cgroup on
# the node is read each tick) and is narrowed to the workload on the
# laptop.
#
# Narrowing inside the pod would save nothing measurable and would need
# a new in-pod loop every time the workload's pods rolled and the
# container ids changed.
set -euo pipefail

STOP_SCRIPT=./scripts/dev_6_measure_stop.sh
ERRLOG="$DIR/collector.err"
# How often the workload's pods are re-resolved.
#
# A roll (a mesh toggle, say) replaces every pod name and every
# container id, so the id->pod map has to be refreshed while the run is
# live or the new pod's samples land with nothing to join them to. 5s
# is a `kubectl get pods` on one label selector, which is noise next to
# the thing being measured.
RESOLVE_INTERVAL="${RESOLVE_INTERVAL:-5}"

usage() { sed -n '6,22p' "$0" >&2; exit 1; }

# Keep the run name to characters that cannot break a filename or a CSV
# column.
#
# The run name becomes both.
check_run_name() {
  case "${1:-}" in
    "") echo "missing <run-name>" >&2; usage ;;
    *[!A-Za-z0-9._-]*) echo "run name may only contain A-Z a-z 0-9 . _ -" >&2; exit 1 ;;
  esac
}

# ------------------------------------------------------ in-pod collector

# The loop that runs inside the probe pod.
#
# Kept in one variable so the reader can restart it verbatim after a
# reconnect.
#
# /proc/uptime, not date: busybox `date` has no %N and prints the
# literal string "%N", so it cannot timestamp below a second.
# /proc/uptime is monotonic with centisecond resolution, which is what
# the elapsed-time division needs. `date +%s` rides along once per tick
# purely so the monotonic clock can be tied back to wall-clock time in
# the CSV.
read -r -d '' INPOD_BODY <<'EOS' || true
while :; do
  UP=$(cut -d" " -f1 /proc/uptime)
  echo "T $UP $(date +%s)"
  LIST=$(find "$CGROOT" -name 'cri-containerd-*.scope' -type d 2>/dev/null)
  if [ -n "$LIST" ]; then
    # One awk over every cpu.stat: a shell read per file would cost more
    # than the reads themselves. awk exits each tick, which flushes it.
    echo "$LIST" | sed 's|$|/cpu.stat|' | xargs awk '
      /^usage_usec/ {
        p = FILENAME
        sub(/\/cpu\.stat$/, "", p)
        n = split(p, a, "/")
        id = a[n]
        sub(/^cri-containerd-/, "", id)
        sub(/\.scope$/, "", id)
        print "S " id " " $2
      }' 2>/dev/null
  fi
  sleep 1
done
EOS
# MARK is never read by the loop.
#
# It exists so the line shows in the pod's `ps -o args` and the reaper
# in util_measure.sh can find it. Both constants are prepended rather
# than written into the heredoc, which is quoted so $UP, $LIST and the
# awk fields reach the pod unexpanded.
INPOD_SCRIPT="MARK=$PROBE_MARK
CGROOT=$PROBE_CGROOT
$INPOD_BODY"

# ------------------------------------------------------- inventory loop

# Refreshing the map is also how a roll is noticed: if the set of pod
# names changed, the workload rolled under us.
#
# The roll is written into the sample stream so it lands in the CSV in
# time order, because a CPU curve with a step in it is unreadable
# without knowing the pods changed.
resolve_loop() {
  local ns="$1" sel="$2" inv="$3" raw="$4" prev="" sig
  while :; do
    dump_inventory "$ns" "$sel" >> "$inv" 2>>"$ERRLOG" || true
    sig=$(awk -F'\t' '{print $4}' "$inv" 2>/dev/null | sort -u | tr '\n' ',' || true)
    if [ -n "$prev" ] && [ "$sig" != "$prev" ]; then
      printf 'R %s pods=%s\n' "$(date +%s)" "$sig" >> "$raw"
    fi
    prev="$sig"
    sleep "$RESOLVE_INTERVAL"
  done
}

# --------------------------------------------------------- collector io

append_rows() {
  local line raw="$1"
  while IFS= read -r line; do
    printf '%s\n' "$line" >> "$raw"
  done
  return 0
}

COLLECT_KPID=""
COLLECT_RESPID=""
collect_cleanup() {
  [ -z "$COLLECT_KPID" ] || kill "$COLLECT_KPID" 2>/dev/null || true
  [ -z "$COLLECT_RESPID" ] || kill "$COLLECT_RESPID" 2>/dev/null || true
  reap_inpod_loops
  # The state file deliberately outlives the collector.
  #
  # It carries the run name, and `stop` is the only thing that may
  # retire a run.
  #
  # bash 3.2 returns the EXIT trap's last status, so end on a success.
  return 0
}

# ---------------------------------------------------------------- start

run="${1:-}"; ns="${2:-}"; workload="${3:-}"
check_run_name "$run"
[ -n "$ns" ] && [ -n "$workload" ] || { echo "needs <run-name> <namespace> <workload>" >&2; usage; }

if pid=$(collector_pid); then
  echo "already collecting run '$(state_field 2)' as pid $pid; stop it first" >&2
  exit 1
fi
[ -f "$STATE" ] && echo "discarding stale run '$(state_field 2)' (its collector is gone)" >&2

raw=$(raw_path "$run"); inv=$(inv_path "$run"); csv=$(csv_path "$run")
# Checked before a single sample is taken, not after the run.
#
# Finding out at `stop` that the name is taken means the load test is
# wasted.
if [ -e "$csv" ]; then
  echo "$csv already exists; an earlier run used the name '$run'." >&2
  echo "pick another name or move that file out of the way." >&2
  exit 1
fi

sel=$(workload_selector "$ns" "$workload") || exit 1
probe_pod >/dev/null      # fail before claiming the state file

printf '%s\t%s\t%s\t%s\n' "$$" "$run" "$ns" "$workload" > "$STATE"
# The signal handlers must exit, not only clean up.
#
# A handler that only cleans up is not a shutdown: bash resumes the
# reconnect loop as soon as it returns, and the collector comes back
# from the dead holding a new exec.
trap collect_cleanup EXIT
trap 'collect_cleanup; exit 0' INT TERM
: > "$ERRLOG"; : > "$raw"; : > "$inv"

dump_inventory "$ns" "$sel" >> "$inv"
resolve_loop "$ns" "$sel" "$inv" "$raw" & COLLECT_RESPID=$!

echo "run '$run' sampling $ns/$workload (selector $sel) at 1Hz" >&2
echo "csv will be written to $csv on: $STOP_SCRIPT" >&2

while :; do
  pod=$(probe_pod) || { sleep 5; continue; }
  reap_inpod_loops   # a previous collector's loop may still be ticking
  echo "streaming from $PROBE_NS/$pod" >&2
  # Process substitution rather than a pipeline, so the kubectl pid is
  # the one we hold.
  #
  # Killing a pipeline's last stage leaves the exec.
  kubectl exec -n "$PROBE_NS" "$pod" -- sh -c "$INPOD_SCRIPT" \
    > >(append_rows "$raw") 2>>"$ERRLOG" &
  COLLECT_KPID=$!
  rc=0; wait "$COLLECT_KPID" || rc=$?
  COLLECT_KPID=""
  # A reconnect leaves a hole; record it.
  #
  # Without the record, a counter delta could be averaged across time
  # nothing watched.
  printf 'G %s reconnect rc=%s\n' "$(date +%s)" "$rc" >> "$raw"
  echo "stream dropped (rc=$rc), reconnecting in 2s" >&2
  sleep 2
done
