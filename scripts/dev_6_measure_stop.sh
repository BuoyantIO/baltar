#!/usr/bin/env bash
# Loads the sampler state helpers.
# shellcheck source=scripts/util_measure.sh
. scripts/util_measure.sh

# Run from the baltar repo root.
# Usage: ./scripts/dev_6_measure_stop.sh
#
# Ends the run started by ./scripts/dev_5_measure_start.sh, finalises the CSV and
# prints its path on stdout. It takes no arguments: only one run is
# active at a time and `start` already recorded the name, namespace and
# workload, so asking again is only a way to typo the name and finalise
# nothing.
#
# The CSV is written to $CPU_SAMPLER_DIR (default
# ~/.cache/kube-cpu-sampler) as <run-name>.csv.
#
# One row per container per second, long format, so it graphs directly
# with no reshaping:
#
#   ts_epoch       wall clock second the sample was taken
#   t_s            seconds since the run's first tick; the x axis
#   run            <run-name>, so runs concatenate into one file
#   namespace,pod  which pod the container belongs to; pod changes on a roll
#   container      container name, e.g. web or linkerd-proxy
#   role           app | proxy | init: the mesh's cost is the proxy rows
#   mesh           meshed | unmeshed, from the pod's own spec
#   container_id   joins rows across the run; unique per container instance
#   usage_usec     cgroup v2 cumulative CPU microseconds, the raw counter
#   delta_usec     usage_usec consumed since this container's last sample
#   interval_s     MEASURED seconds that delta covers, not a nominal 1.00
#   cpu_pct_core   delta_usec over interval_s as a percent of ONE core
#   event          sample | first | gap | reconnect | roll (see below)
#
# An `event` other than `sample` has empty delta/interval/percent:
# `first` is a container's first sight, `gap` an interval that spans
# unobserved time, `reconnect` the stream dropping, `roll` the
# workload's pods being replaced.
#
# A hole is left as a hole rather than drawn as a zero.
#
# If <run-name>.csv appeared mid-run, this writes <run-name>.<epoch>.csv
# rather than overwrite anything.
#
# The deliverable is a CSV time series, one row per container per
# second, not a summary.
#
# A mean over a run hides the ramp, the plateau and the spike, which
# are the only interesting parts of a load test. Nothing is printed for
# the terminal to hold: the run prints the path of the file it wrote
# and the file is the result.
#
# Measures and nothing else.
#
# It generates no load, meshes and unmeshes nothing, and creates and
# deletes no Kubernetes resources. Its only writes to the cluster are
# the `kubectl exec` that reaps the in-pod collector loop.
set -euo pipefail

START_SCRIPT=./scripts/dev_5_measure_start.sh
# Longest interval still treated as one measured step.
#
# Beyond this the counter advanced over time nothing observed, so the
# step is a hole.
GAP_MAX_S="${GAP_MAX_S:-2.5}"

usage() { sed -n '6,13p' "$0" >&2; exit 1; }

# ------------------------------------------------------------- csv build

build_csv() {
  local run="$1" ns="$2" workload="$3"
  local raw inv csv
  raw=$(raw_path "$run"); inv=$(inv_path "$run"); csv=$(csv_path "$run")
  [ -s "$raw" ] || { echo "no samples were collected for run '$run' ($raw)" >&2; exit 1; }
  # Never clobber an existing file.
  #
  # If the name was taken between `start` and here, the samples still
  # get a file, under a name that says when.
  if [ -e "$csv" ]; then
    csv="$DIR/$run.$(date +%s).csv"
    echo "warning: $(csv_path "$run") appeared during the run; writing $csv instead" >&2
  fi

  # The join is by container id, which is unique per container
  # instance.
  #
  # A roll therefore cannot alias an old pod's rows onto a new pod's.
  #
  # Every percentage divides by the MEASURED interval between two
  # samples of that same container, taken from the monotonic clock,
  # never by the nominal one second. An interval that spans a
  # reconnect, a missing container or anything longer than GAP_MAX_S is
  # not measured time: the row is emitted with empty delta and empty
  # percent and event=gap, so the hole is visible in the graph instead
  # of being drawn as a zero or smeared across the samples either side
  # of it.
  awk -F'\t' -v invf="$inv" -v run="$run" -v gapmax="$GAP_MAX_S" '
    FILENAME == invf {
      id = $2; ns[id] = $3; pod[id] = $4; cn[id] = $5; role[id] = $6; mesh[id] = $7
      next
    }
    function row(ts, t, i, dus, dds, dts, ps, ev) {
      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
        ts, t, run, (i == "" ? "" : ns[i]), (i == "" ? "" : pod[i]),
        (i == "" ? "" : cn[i]), (i == "" ? "" : role[i]),
        (i == "" ? "" : mesh[i]), i, dus, dds, dts, ps, ev
    }
    { split($0, w, " ") }
    w[1] == "T" { up = w[2] + 0; ep = w[3] + 0; if (up0 == 0) up0 = up; next }
    # seq changes on a reconnect, which invalidates every open delta.
    w[1] == "G" { seq++; row(w[2] + 0, "", "", "", "", "", "", "reconnect"); next }
    w[1] == "R" { row(w[2] + 0, "", "", "", "", "", "", "roll"); next }
    w[1] == "S" {
      id = w[2]; u = w[3] + 0
      if (!(id in pod)) next          # not part of the target workload
      du = ""; dt = ""; pct = ""; ev = "sample"
      if (!(id in seen)) ev = "first"
      else if (lseq[id] != seq) ev = "gap"
      else {
        d = u - lu[id]; t = up - lup[id]
        if (d < 0 || t <= 0.005 || t > gapmax + 0) ev = "gap"
        else {
          du = sprintf("%d", d); dt = sprintf("%.2f", t)
          pct = sprintf("%.2f", d / 10000.0 / t)   # usec/sec of one core
          measured[id] += t; rows++
        }
      }
      row(ep, sprintf("%.2f", up - up0), id, u, du, dt, pct, ev)
      lu[id] = u; lup[id] = up; lseq[id] = seq; seen[id] = 1
      emitted++
      next
    }
    END {
      n = 0; for (i in seen) n++
      printf "containers=%d emitted=%d measured_rows=%d\n", n, emitted, rows > "/dev/stderr"
    }
  ' "$inv" "$raw" > "$DIR/.$run.body" || { echo "csv build failed" >&2; exit 1; }

  {
    echo "$CSV_HEADER"
    cat "$DIR/.$run.body"
  } > "$csv"
  rm -f "$DIR/.$run.body"

  echo "run '$run' ($ns/$workload) finalised" >&2
  echo "$csv"
  return 0
}

# ----------------------------------------------------------------- stop

[ $# -eq 0 ] || { echo "this takes no arguments" >&2; usage; }
[ -f "$STATE" ] || {
  echo "no run is active; start one with: $START_SCRIPT <run-name> <ns> <workload>" >&2
  exit 1
}

run=$(state_field 2); ns=$(state_field 3); workload=$(state_field 4)
[ -n "$run" ] || { echo "state file $STATE is unreadable; remove it and start again" >&2; exit 1; }
pid=$(collector_pid) || pid=""
if [ -n "$pid" ]; then
  kill -TERM "$pid" 2>/dev/null || true
  # Wait for the collector's own handler to run before building the
  # CSV.
  #
  # Otherwise the build races the writer still appending samples.
  for i in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "collector pid $pid ignored SIGTERM; killing" >&2
    kill -KILL "$pid" 2>/dev/null || true
    sleep 1
  fi
else
  echo "collector for run '$run' was already gone; finalising what it collected" >&2
fi
# Reaped unconditionally.
#
# A SIGKILLed collector never ran its handler, and the in-pod loop does
# not die with the exec that started it.
reap_inpod_loops
rm -f "$STATE"

build_csv "$run" "$ns" "$workload"
