#!/usr/bin/env bash
# Usage: ./pf_3_headlamp_dashboard.sh
# Opens the Headlamp dashboard: copies a fresh auth token to the
# clipboard, port-forwards the pod, and opens the browser at it.
#
# The token goes into Headlamp's sign-in box. The pf_<n>_ prefix marks
# a script that port-forwards or exposes a service. The number follows
# the init_ step that installs what it exposes: headlamp is init_5, so
# this is pf_3 of the group. It blocks until ctrl-C, so a rebuild
# chain must not run it. It prefers pbcopy and open, falling back to
# xclip/xsel and xdg-open on Linux.
set -euo pipefail

# Guards the macOS-only clipboard and browser tools.
#
# The guard is what keeps these scripts working on a headless Linux
# host (the VM of task 26). On Linux we fall back to xclip/xsel if
# present and otherwise print, which is the only sane behaviour with
# no clipboard and no browser.
copy_to_clipboard() {
  if command -v pbcopy >/dev/null 2>&1; then
    pbcopy
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --input
  else
    echo "no clipboard tool found; the value follows:" >&2
    cat >&2
  fi
}

open_url() {
  if command -v open >/dev/null 2>&1; then
    open "$1"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$1"
  else
    echo "no browser opener found; visit $1 yourself" >&2
  fi
}

PORT=8081

# COPY
kubectl create token my-headlamp --namespace kube-system | copy_to_clipboard

POD_NAME=$(kubectl get pods --namespace kube-system -l "app.kubernetes.io/name=headlamp,app.kubernetes.io/instance=my-headlamp" -o jsonpath="{.items[0].metadata.name}")
CONTAINER_PORT=$(kubectl get pod --namespace kube-system "$POD_NAME" -o jsonpath="{.spec.containers[0].ports[0].containerPort}")

echo "Visit http://127.0.0.1:${PORT} to use your application"

# Backgrounds the port-forward and traps its exit.
#
# The browser can only be opened once the tunnel answers: in the
# foreground the port-forward would block and `open` would never run.
# The trap stops the tunnel when this script exits, however it exits.
kubectl --namespace kube-system port-forward "$POD_NAME" "${PORT}:${CONTAINER_PORT}" &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

# Wait for the tunnel rather than guessing at a sleep duration.
for _ in $(seq 30); do
  if curl -sS -o /dev/null "http://127.0.0.1:${PORT}"; then break; fi
  sleep 0.5
done

# launch dashboard
open_url "http://127.0.0.1:${PORT}"

# Hold the tunnel open; ctrl-C to stop.
wait "$PF_PID"
