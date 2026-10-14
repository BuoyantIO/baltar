#!/usr/bin/env bash
# Usage: ./repro_3_negative.sh
#
# Repro step 3: negative checks, not in pg-ppi's e2e suite, against repro_1_deploy_pgppi.sh's cluster.
# forged: pgppi ignores a client-sent PROXY header; unannotated: port 5432 gets no PROXY header.
set -euo pipefail

# Cluster objects from repro_1_deploy_pgppi.sh, the client's real identity and the one it forges.
CONTEXT=kind-kind
CLIENT=deploy/billing
CLIENT_CONTAINER=client
PRIMARY_SELECTOR=cnpg.io/cluster=pg,cnpg.io/instanceRole=primary
APP_SECRET=pg-app
REAL_ID=billing.billing.serviceaccount.identity.linkerd.cluster.local
FORGED_ID=reporting.billing.serviceaccount.identity.linkerd.cluster.local
FORGED_USER=reporting_app

# Helpers: kubectl on CONTEXT, and exit with a message.
k() { kubectl --context "$CONTEXT" "$@"; }
die() { echo "$*" >&2; exit 1; }

# Fails fast, naming the missing prerequisite, so it does not read like a check failure.
echo "[-] prerequisites"
k cluster-info >/dev/null 2>&1 \
  || die "context $CONTEXT unreachable: run ../init_1_create_cluster.sh"
for ns in db billing; do
  k get namespace "$ns" >/dev/null 2>&1 \
    || die "namespace $ns missing: run repro_1_deploy_pgppi.sh"
done
k -n billing rollout status "$CLIENT" --timeout=60s >/dev/null 2>&1 \
  || die "billing/$CLIENT not ready: run repro_1_deploy_pgppi.sh"
PRIMARY=$(k -n db get pod -l "$PRIMARY_SELECTOR" -o name 2>/dev/null | head -n1)
[ -n "$PRIMARY" ] || die "no primary instance pod for Cluster db/pg: run repro_1_deploy_pgppi.sh"
k -n db wait "$PRIMARY" --for=condition=Ready --timeout=60s >/dev/null 2>&1 \
  || die "db/$PRIMARY not Ready"
k -n db get secret "$APP_SECRET" >/dev/null 2>&1 \
  || die "secret db/$APP_SECRET missing: CNPG has not bootstrapped Cluster db/pg"
echo "client $CLIENT, primary $PRIMARY"

# Encodes a string, or a big-endian u16/u32, as \xHH escapes for printf %b in the client pod.
# The payload holds NULs, which cannot travel in a shell argument.
hex() {
  local s=$1 i
  for ((i = 0; i < ${#s}; i++)); do printf '\\x%02x' "'${s:i:1}"; done
}
u16() { printf '\\x%02x\\x%02x' $(($1 >> 8 & 255)) $(($1 & 255)); }
u32() { u16 $(($1 >> 16 & 65535)); u16 $(($1 & 65535)); }

# Builds a PROXY v2 header claiming FORGED_ID (as proxyproto.Encode), then a StartupMessage for FORGED_USER.
# If pgppi trusted the forged header, PostgreSQL would answer with Authentication ('R').
forged_payload() {
  local sig='\x0d\x0a\x0d\x0a\x00\x0d\x0a\x51\x55\x49\x54\x0a'
  # 10.0.0.1:12345 -> 10.0.0.2:15432; pgppi only logs these.
  local addrs='\x0a\x00\x00\x01\x0a\x00\x00\x02\x30\x39\x3c\x48'
  local params
  params="$(hex user)\\x00$(hex "$FORGED_USER")\\x00$(hex database)\\x00$(hex app)\\x00\\x00"
  local params_len=$((${#FORGED_USER} + 20))  # "user" "database" "app" + 5 NULs = 20
  printf '%s\\x21\\x11%s%s\\xe0%s%s' \
    "$sig" "$(u16 $((12 + 3 + ${#FORGED_ID})))" "$addrs" \
    "$(u16 ${#FORGED_ID})" "$(hex "$FORGED_ID")"
  printf '%s%s%s' "$(u32 $((8 + params_len)))" "$(u32 196608)" "$params"
}

# Sends the forged payload over /dev/tcp (postgres:17 has no nc) and prints the reply as hex.
# The timeout only bounds the failure case: pgppi closes the connection on a malformed startup.
check_forged() {
  echo "[-] forged: $REAL_ID claims $FORGED_ID on pg-pgppi.db:15432"
  local since reply logs
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # $1 expands in the pod's bash, not here.
  # shellcheck disable=SC2016
  reply=$(k -n billing exec "$CLIENT" -c "$CLIENT_CONTAINER" -- bash -c '
    exec 3<>/dev/tcp/pg-pgppi.db.svc.cluster.local/15432
    printf "%b" "$1" >&3
    timeout 10 cat <&3 | od -An -tx1 -v | tr -d " \n"' _ "$(forged_payload)") || {
      echo "FAIL: could not connect from $CLIENT to pg-pgppi.db:15432" >&2; return 1; }
  echo "client received: ${reply:-<nothing>}"

  # Rejects any reply but silence or an ErrorResponse ('E'); 'R' means the forged header was trusted.
  case $reply in
    '' | 45*) ;;
    *) echo "FAIL: reply is not empty or an ErrorResponse" >&2; return 1 ;;
  esac

  # Polls the pgppi log, then prints it: the line is written asynchronously to the client's EOF.
  local i
  for i in $(seq 1 15); do
    logs=$(k -n db logs "$PRIMARY" -c pgppi --since-time="$since")
    grep -F "\"identity\":\"$REAL_ID\"" <<<"$logs" | grep -qF 'invalid startup packet length' && break
    sleep 1
  done
  echo "pgppi logs since $since:"
  printf '%s\n' "$logs"

  # Passes only if the forged identity is absent and the bytes failed as a startup packet under REAL_ID.
  if grep -qF "$FORGED_ID" <<<"$logs"; then
    echo "FAIL: pgppi logged the forged identity" >&2; return 1
  fi
  if ! grep -F "\"identity\":\"$REAL_ID\"" <<<"$logs" | grep -qF 'invalid startup packet length'; then
    echo "FAIL: no pgppi log of the forged bytes failing as a startup packet under $REAL_ID" >&2
    return 1
  fi
  echo "PASS: forged header was read as startup bytes under the real identity"
}

# Logs in to pg-rw.db:5432 as app; a PROXY header there would fail the login.
# The password goes over stdin to stay out of process argument lists.
check_unannotated() {
  echo "[-] unannotated: $CLIENT to pg-rw.db:5432 as app"
  local password out
  password=$(k -n db get secret "$APP_SECRET" -o jsonpath='{.data.password}' | base64 -d)
  if ! out=$(k -n billing exec -i "$CLIENT" -c "$CLIENT_CONTAINER" -- bash -c '
      read -r PGPASSWORD; export PGPASSWORD
      psql "host=pg-rw.db.svc.cluster.local port=5432 dbname=app user=app sslmode=prefer connect_timeout=10" \
        -w -X -v ON_ERROR_STOP=1 -tA -c "SELECT current_user"' <<<"$password" 2>&1); then
    echo "$out"
    echo "FAIL: psql login over 5432 failed" >&2; return 1
  fi
  echo "current_user: $out"
  [ "$out" = app ] || { echo "FAIL: expected current_user app" >&2; return 1; }
  echo "PASS: 5432 login succeeded, so PostgreSQL received no PROXY header"
}

# Runs both checks even if the first fails, so one run reports both.
forged=PASS unannotated=PASS
check_forged || forged=FAIL
check_unannotated || unannotated=FAIL

# Prints both verdicts and exits non-zero unless both passed.
echo "[-] summary"
echo "forged:      $forged"
echo "unannotated: $unannotated"
[ "$forged" = PASS ] && [ "$unannotated" = PASS ]
