#!/usr/bin/env bash
# Usage: ./run.sh
#        CONNECTIONS=250 DURATION=60s ./run.sh
#        LOAD_SCRIPT=test_load_1_local_tunnel.sh RUN_NAME=tunnel-web ./run.sh
#
# Samples CPU of one workload around a load run: dev_5_measure_start.sh in the background,
# one test_load_* script, then dev_6_measure_stop.sh, which prints the CSV path.
# Precondition: a cluster with emojivoto, HAProxy and the cpu-probe (init_1, init_6, init_7, init_8).
#
# Env vars and defaults:
#   LOAD_SCRIPT=test_load_2_docker_nodeport.sh  load script under scripts/; test_load_1 ignores CONNECTIONS/DURATION
#   CONNECTIONS=125                             concurrent connections, passed to test_load_2
#   DURATION=30s                                load duration, passed to test_load_2
#   RUN_NAME=load-<epoch>                       names the CSV; dev_5 refuses a name already used
#   NAMESPACE=emojivoto                         namespace of the sampled workload
#   WORKLOAD=deploy/web                         sampled workload
#   START_TIMEOUT=30                            seconds to wait for the sampler to start
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")/../.." && pwd)"
LOAD_SCRIPT=${LOAD_SCRIPT:-test_load_2_docker_nodeport.sh}
CONNECTIONS=${CONNECTIONS:-125}
DURATION=${DURATION:-30s}
RUN_NAME=${RUN_NAME:-load-$(date +%s)}
NAMESPACE=${NAMESPACE:-emojivoto}
WORKLOAD=${WORKLOAD:-deploy/web}
START_TIMEOUT=${START_TIMEOUT:-30}

# Fail fast on missing scripts.
for f in dev_5_measure_start.sh dev_6_measure_stop.sh "$LOAD_SCRIPT" util_measure.sh; do
  [ -f "$SCRIPTS/$f" ] || { echo "missing $SCRIPTS/$f; set LOAD_SCRIPT to an existing test_load_* script" >&2; exit 1; }
done
case "$LOAD_SCRIPT" in
  test_load_1_*) load_args=() ;;
  *) load_args=("$CONNECTIONS" "$DURATION") ;;
esac

# Reuse the sampler's state helpers to detect when the collector is live.
# shellcheck source=../../util_measure.sh
. "$SCRIPTS/util_measure.sh"

# Stop the sampler on any exit, so a failed load still yields a CSV.
SAMPLER_PID=""
SAMPLER_STARTED=""
stop_sampler() {
  local rc=$?
  if [ -n "${SAMPLER_STARTED:-}" ]; then
    "$SCRIPTS/dev_6_measure_stop.sh" || rc=$?
  elif [ -n "${SAMPLER_PID:-}" ]; then
    kill "$SAMPLER_PID" 2>/dev/null || true
  fi
  echo "cleanup: $SCRIPTS/cleanup_1_cluster.sh" >&2
  exit "$rc"
}
trap stop_sampler EXIT

# Start the sampler and wait until it owns the state file.
"$SCRIPTS/dev_5_measure_start.sh" "$RUN_NAME" "$NAMESPACE" "$WORKLOAD" &
SAMPLER_PID=$!
waited=0
until [ "$(collector_pid 2>/dev/null || true)" = "$SAMPLER_PID" ]; do
  kill -0 "$SAMPLER_PID" 2>/dev/null || { echo "dev_5_measure_start.sh exited before sampling" >&2; SAMPLER_PID=""; exit 1; }
  [ "$waited" -lt "$START_TIMEOUT" ] || { echo "sampler not live after ${START_TIMEOUT}s" >&2; exit 1; }
  sleep 1
  waited=$((waited + 1))
done
SAMPLER_STARTED=1

# Drive the load; the EXIT trap stops the sampler and prints the CSV path.
"$SCRIPTS/$LOAD_SCRIPT" ${load_args[@]+"${load_args[@]}"}
