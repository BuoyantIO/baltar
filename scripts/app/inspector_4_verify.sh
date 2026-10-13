#!/usr/bin/env bash
# Usage: ./inspector_4_verify.sh
#        MARKER=pp-1759000000-12345 ./inspector_4_verify.sh
#        EXPECTED_ID=client.inspect.serviceaccount.identity.linkerd.cluster.local ./inspector_4_verify.sh
#
# Inspector step 4: checks the inspector log has a PROXY v2 header with TLV 0xE0 = EXPECTED_ID on
# the conn that carried MARKER (from inspector_3_send.sh), or on the latest header's conn if unset.
#
# Env vars and defaults:
#   MARKER=<unset> marker printed by inspector_3_send.sh; unset uses the latest PpHeader
#   EXPECTED_ID=client.inspect.serviceaccount.identity.linkerd.cluster.local client identity in TLV 0xE0
set -euo pipefail

# Inputs with defaults.
MARKER=${MARKER:-}
EXPECTED_ID=${EXPECTED_ID:-client.inspect.serviceaccount.identity.linkerd.cluster.local}

# Cluster objects from inspector_2_deploy.sh and the PROXY v2 signature.
CONTEXT=kind-kind
NS=inspect
SIGNATURE=0d0a0d0a000d0a515549540a

# Helpers: kubectl on CONTEXT, a bold step banner, and exit with a message.
k() { kubectl --context "$CONTEXT" "$@"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "$*" >&2; exit 1; }

# Fails fast, naming the missing prerequisite, so it does not read like a check failure.
step "prerequisites"
command -v kubectl >/dev/null || die "kubectl not found: install it"
command -v jq >/dev/null || die "jq not found: install it"
k cluster-info >/dev/null 2>&1 || die "context $CONTEXT unreachable: run ../init_1_create_cluster.sh"
k get namespace "$NS" >/dev/null 2>&1 || die "namespace $NS missing: run inspector_2_deploy.sh"
k -n "$NS" rollout status deploy/inspector --timeout=60s >/dev/null 2>&1 \
  || die "$NS/deploy/inspector not ready: run inspector_2_deploy.sh"

# Picks the conn: the marker's request Chunk if MARKER is set, else the latest PpHeader.
find_conn() {
  local hex chunk
  if [ -z "$MARKER" ]; then
    step "latest PpHeader conn"
    logs=$(k -n "$NS" logs deploy/inspector -c inspector)
    conn=$(jq -rR 'fromjson? | select(.event == "PpHeader") | .conn' <<<"$logs" | tail -n1)
    [ -n "$conn" ] || { echo "FAIL: no PpHeader in the inspector log" >&2; return 1; }
    return 0
  fi

  # Polls the inspector log for the marker's request Chunk; log lines may lag the echo.
  step "request Chunk for $MARKER"
  hex=$(printf '%s\n' "$MARKER" | od -An -tx1 -v | tr -d ' \n')
  for _ in $(seq 1 10); do
    logs=$(k -n "$NS" logs deploy/inspector -c inspector)
    chunk=$(jq -cR --arg h "$hex" \
      'fromjson? | select(.event == "Chunk" and .dir == "request" and .preview_hex == $h)' <<<"$logs")
    [ -n "$chunk" ] && break
    sleep 1
  done
  [ -n "$chunk" ] || { echo "FAIL: no request Chunk with preview_hex $hex" >&2; return 1; }
  echo "chunk:  $chunk"
  conn=$(jq -r '.conn' <<<"$chunk" | head -n1)
}

# Requires a PpHeader on conn with the signature and TLV 0xE0 = EXPECTED_ID.
check_pp() {
  local header
  find_conn || return 1
  header=$(jq -cR --argjson c "$conn" --arg sig "$SIGNATURE" --arg id "$EXPECTED_ID" \
    'fromjson? | select(.event == "PpHeader" and .conn == $c and (.raw_hex | startswith($sig))
      and any((.tlvs // [])[]; .type == "0xe0" and .text == $id))' <<<"$logs")
  [ -n "$header" ] || {
    echo "FAIL: no PpHeader on conn $conn with signature and 0xe0 = $EXPECTED_ID" >&2; return 1; }
  echo "header: $header"
}

# Prints the verdict and exits non-zero unless it passed.
logs=""
conn=""
pp=PASS
check_pp || pp=FAIL
step "summary"
echo "pp: $pp"
[ "$pp" = PASS ]
