#!/usr/bin/env bash
# Usage: ./pf_1_viz_dashboard.sh
# Opens the linkerd-viz dashboard. The CLI opens the browser itself and
# holds the tunnel until ctrl-C.
#
# The pf_<n>_ prefix marks a script that port-forwards or exposes a
# service. The number follows the init_ step that installs what it
# exposes: viz is init_3, so this is pf_1 of the group. Run in the
# foreground rather than backgrounded with &, because a backgrounded
# child dies with the script that spawned it.
set -euo pipefail

linkerd viz dashboard
