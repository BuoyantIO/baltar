#!/usr/bin/env bash
# Usage: ./pf_2_grafana_dashboard.sh
# Opens the Grafana dashboard: copies the admin password to the
# clipboard, port-forwards the pod, and opens the browser at it.
#
# The login is `admin`, with the password pasted from the clipboard.
# The pf_<n>_ prefix marks a script that port-forwards or exposes a
# service. The number follows the init_ step that installs what it
# exposes: grafana is init_4, so this is pf_2 of the group. It blocks
# until ctrl-C, so a rebuild chain must not call it. It prefers
# pbcopy and open, falling back to xclip/xsel and xdg-open on Linux.
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

PORT=3000

kubectl get secret --namespace grafana grafana -o jsonpath="{.data.admin-password}" | base64 --decode | copy_to_clipboard

POD_NAME=$(kubectl get pods --namespace grafana -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=grafana" -o jsonpath="{.items[0].metadata.name}")

echo "Visit http://localhost:${PORT} and log in as admin; the password is on your clipboard."

# Backgrounds the port-forward and traps its exit.
#
# The browser can only be opened once the tunnel answers: in the
# foreground the port-forward would block and `open` would never run.
# The trap stops the tunnel when this script exits, however it exits.
kubectl --namespace grafana port-forward "$POD_NAME" "${PORT}:${PORT}" &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

for _ in $(seq 30); do
  if curl -sS -o /dev/null "http://localhost:${PORT}"; then break; fi
  sleep 0.5
done

open_url "http://localhost:${PORT}"

# Hold the tunnel open; ctrl-C to stop.
wait "$PF_PID"
