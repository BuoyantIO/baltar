#!/usr/bin/env bash
# Usage: ./dev_3_modify_linkerd_cores.sh [NAMESPACE] [WORKLOAD] [CORES]
#   e.g. ./dev_3_modify_linkerd_cores.sh emojivoto deploy/web 6
#        ./dev_3_modify_linkerd_cores.sh emojivoto deploy/web
# Defaults to emojivoto deploy/web, the workload the load tests drive,
# and to 1 core, which is the proxy's own default.
#
# There is no reset. To clear the setting, drop the annotation by hand:
#   kubectl patch <workload> -n <ns> --type merge -p \
#     '{"spec":{"template":{"metadata":{"annotations":{"config.linkerd.io/proxy-additional-env":null}}}}}'
#
# The modify_<n>_ prefix marks a script that changes the configuration of
# something already installed, as against init_ (build it), pf_ (expose
# it) and mesh_ (mesh it).
set -euo pipefail

# Target workload, and the annotation that injects arbitrary proxy env
# vars.
#
# Preferred over config.linkerd.io/proxy-cpu-limit, which would also
# set a real k8s CPU limit and so throttle the proxy at the same
# number.
NS="${1:-emojivoto}"
WORKLOAD="${2:-deploy/web}"
CORES="${3:-1}"
ANNOTATION=config.linkerd.io/proxy-additional-env

# Cores must be a positive whole number.
#
# The proxy ignores anything else.
case "$CORES" in ''|*[!0-9]*) echo "cores must be a positive integer" >&2; exit 1 ;; esac
[ "$CORES" -gt 0 ] || { echo "cores must be a positive integer" >&2; exit 1; }
VALUE=$(printf '"[{\\"name\\":\\"LINKERD2_PROXY_CORES_MAX\\",\\"value\\":\\"%s\\"}]"' "$CORES")

# Patch the annotation onto spec.template.metadata.annotations.
#
# Only that path works; the Deployment's own annotations do nothing.
kubectl patch "$WORKLOAD" -n "$NS" --type merge \
  -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"$ANNOTATION\":$VALUE}}}}}"

# Wait for the rollout; no restart is needed.
#
# Patching the template IS the rollout.
kubectl rollout status "$WORKLOAD" -n "$NS" --timeout=120s

# tokio_rt_workers is the real worker count.
#
# Do not count threads named "proxy".
linkerd diagnostics proxy-metrics -n "$NS" "$WORKLOAD" | awk '/^tokio_rt_workers /{print $2}'
