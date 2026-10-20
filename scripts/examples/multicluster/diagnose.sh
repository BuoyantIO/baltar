#!/usr/bin/env bash
# Run from the launchy-dev repo root.
# Usage: ./scripts/examples/multicluster/diagnose.sh
#        OUT_DIR=out/mc_run ./scripts/examples/multicluster/diagnose.sh
#
# Shows where east resolves the mirrored west services, then drives real
# traffic and reads back the server identity each request reached.
#
# Every stage is tee'd to a file under OUT_DIR so the evidence persists
# after the run, and also printed so the operator sees it live.
#
# Env vars and defaults:
#   OUT_DIR   out/mc_<timestamp>. Results dir; one file per stage.
#
# -e is omitted on purpose: the diagnostics probe names that may not
# resolve and curls that may time out, and we want every stage captured
# regardless of any single command's exit status.
set -uo pipefail

OUT_DIR=${OUT_DIR:-out/mc_$(date +%Y%m%d_%H%M%S)}
mkdir -p "$OUT_DIR"
echo "[-] writing results to $OUT_DIR"

# Resolves the three services from east's perspective.
#
# victim is east's own baseline; evil-west and gwhijack-west are the
# mirrored carriers, named <service>-<cluster>.
{
  echo "=== victim.tenant:80 [baseline local service] ==="
  linkerd --context kind-kind diagnostics endpoints victim.tenant.svc.cluster.local:80
  echo
  echo "=== evil-west.tenant:80 [local-discovery annotation carrier] ==="
  linkerd --context kind-kind diagnostics endpoints evil-west.tenant.svc.cluster.local:80
  echo
  echo "=== gwhijack-west.tenant:80 [remote-discovery/remote-service label carrier] ==="
  linkerd --context kind-kind diagnostics endpoints gwhijack-west.tenant.svc.cluster.local:80
} 2>&1 | tee "$OUT_DIR/endpoints.txt"

# Reads the destination TLS identity each service resolves to.
#
# The identity names the backend that would answer, so it shows whether a
# mirrored carrier lands on its own cluster or on an east-local pod.
{
  for SVC in victim.tenant evil-west.tenant gwhijack-west.tenant; do
    echo "=== $SVC identity (destination TlsIdentity) ==="
    linkerd --context kind-kind diagnostics endpoints "${SVC}.svc.cluster.local:80" -o json \
      | grep -iE "\"dnsName\"|\"podName\"|\"ip\"" | sort -u
    echo
  done
} 2>&1 | tee "$OUT_DIR/identity.txt"

# Drives real traffic from the meshed client and prints each body.
#
# The returned page (I-AM-VICTIM-EAST vs I-AM-WEST-OTHER) shows which
# backend actually served the request.
{
  C=$(kubectl --context kind-kind -n tenant get pod -l app=client -o jsonpath="{.items[0].metadata.name}")
  echo "client pod: $C"
  for SVC in victim evil-west gwhijack-west; do
    echo "--- curl http://$SVC.tenant.svc.cluster.local/ ---"
    kubectl --context kind-kind -n tenant exec "$C" -c curl -- \
      curl -s -m 8 "http://$SVC.tenant.svc.cluster.local/"
    echo "[exit $?]"
  done
} 2>&1 | tee "$OUT_DIR/traffic.txt"

# Reads the client proxy's outbound target identity per authority.
#
# A few requests first so the metrics populate, then the server_id the
# client proxy negotiated for each authority, which is the mTLS-level
# proof of the backend it reached.
{
  C=$(kubectl --context kind-kind -n tenant get pod -l app=client -o jsonpath="{.items[0].metadata.name}")
  for _ in 1 2 3; do
    kubectl --context kind-kind -n tenant exec "$C" -c curl -- \
      curl -s -m 8 -o /dev/null "http://victim.tenant.svc.cluster.local/"
    kubectl --context kind-kind -n tenant exec "$C" -c curl -- \
      curl -s -m 8 -o /dev/null "http://evil-west.tenant.svc.cluster.local/"
  done
  echo "=== outbound target identities (server_id) by authority ==="
  linkerd --context kind-kind diagnostics proxy-metrics -n tenant "pod/$C" \
    | grep -E "^outbound_.*(authority|server_id)" | grep -iE "victim|evil-west" \
    | grep -oE "authority=\"[^\"]*\"|target_addr=\"[^\"]*\"|server_id=\"[^\"]*\"|dst_server_id=\"[^\"]*\"" \
    | sort | uniq -c
  echo "=== raw sample lines ==="
  linkerd --context kind-kind diagnostics proxy-metrics -n tenant "pod/$C" \
    | grep -E "server_id=" | grep -iE "evil-west|victim" | head -6
} 2>&1 | tee "$OUT_DIR/proxy_metrics.txt"

echo "[-] results written under $OUT_DIR"
