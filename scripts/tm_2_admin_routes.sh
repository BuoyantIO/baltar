#!/usr/bin/env bash
# Loads k (kubectl on CONTEXT).
# shellcheck source=scripts/util_kube.sh
. scripts/util_kube.sh

# Run from the baltar repo root.
# Usage: ./scripts/tm_2_admin_routes.sh
#        ADMIN_ROUTES="GET /env.json POST /shutdown" CONTEXT=kind-kind ./scripts/tm_2_admin_routes.sh
#
# Checks a meshed proxy's admin server (:4191) answers 403 to a non-loopback client on each non-public route.
# Public routes /live, /ready and /metrics are not checked.
# Applies tm_2_admin_routes.yaml; prints `pass` and exits 0, or `fail: ...` lines and exits 1.
# Cleanup: kubectl delete ns tm-admin-target tm-admin-client
#
# Env vars and defaults:
#   CONTEXT=$(kubectl config current-context)   kubectl context
#   TARGET_NS=tm-admin-target                   meshed namespace of deploy/tm-target
#   CLIENT_NS=tm-admin-client                   unmeshed namespace of pod/tm-client
#   ADMIN_ROUTES="GET /proxy-log-level GET /env.json POST /shutdown GET /logs.json GET /debug/pprof/profile.pb.gz"
#                                               space-separated method/path pairs to check
set -euo pipefail

# Inputs with defaults; the manifest sits next to this script.
CONTEXT=${CONTEXT:-$(kubectl config current-context)}
TARGET_NS=${TARGET_NS:-tm-admin-target}
CLIENT_NS=${CLIENT_NS:-tm-admin-client}
ADMIN_ROUTES=${ADMIN_ROUTES:-GET /proxy-log-level GET /env.json POST /shutdown GET /logs.json GET /debug/pprof/profile.pb.gz}
MANIFEST=scripts/tm_2_admin_routes.yaml

# Fills the manifest placeholders and applies it.
echo "[-] apply ns $TARGET_NS (meshed) deploy/tm-target, ns $CLIENT_NS pod/tm-client"
manifest=$(<"$MANIFEST")
manifest=${manifest//"<TARGET_NS_PLACEHOLDER>"/"$TARGET_NS"}
manifest=${manifest//"<CLIENT_NS_PLACEHOLDER>"/"$CLIENT_NS"}
printf '%s\n' "$manifest" | k apply -f -

# Waits for the target rollout and the client pod.
echo "[-] wait"
k -n "$TARGET_NS" rollout status deploy/tm-target --timeout=180s
k -n "$CLIENT_NS" wait --for=condition=Ready pod/tm-client --timeout=180s

# Shows both endpoints so the output proves the client is not loopback.
target_pod=$(k -n "$TARGET_NS" get pod -l app=tm-target -o jsonpath='{.items[0].metadata.name}')
target_ip=$(k -n "$TARGET_NS" get pod "$target_pod" -o jsonpath='{.status.podIP}')
client_ip=$(k -n "$CLIENT_NS" get pod tm-client -o jsonpath='{.status.podIP}')
echo "[-] client $CLIENT_NS/tm-client $client_ip -> target $TARGET_NS/$target_pod $target_ip:4191"

# Requests each route from the client; anything but 403 is a failure.
# `|| true` keeps the loop going on a curl error, which -w still reports as 000.
read -r -a routes <<< "$ADMIN_ROUTES"
set -- "${routes[@]}"
failed=0
while [ "$#" -gt 0 ]; do
  method=$1
  path=$2
  shift 2
  code=$(k -n "$CLIENT_NS" exec tm-client -- curl -s -o /dev/null -w '%{http_code}' -X "$method" --max-time 5 \
    "http://$target_ip:4191$path" || true)
  if [ "$code" != "403" ]; then
    echo "fail: $method $path -> $code from $client_ip to $target_pod/$target_ip:4191"
    failed=1
  fi
done

# Passes when every route answered 403.
if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "pass"
