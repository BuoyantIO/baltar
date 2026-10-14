#!/usr/bin/env bash
# Shared helper `k`; sourced, never run, so the caller owns `set -euo pipefail` and sets CONTEXT.

# Runs kubectl on the caller's CONTEXT, so no call can fall through to the current context.
k() { kubectl --context "$CONTEXT" "$@"; }
