#!/usr/bin/env bash
# Usage: ./repro_1_deploy_pgppi.sh
#        PGPPI_DIR=~/src/pg-ppi ./repro_1_deploy_pgppi.sh
#        PGPPI_IMAGE=ghcr.io/daniel-garcia/pg-ppi:dev ./repro_1_deploy_pgppi.sh
#        CERT_MANAGER_VERSION=v1.21.2 CNPG_VERSION=1.30.1 ./repro_1_deploy_pgppi.sh
#
# Repro step 1: deploys pgppi, cert-manager, CloudNativePG and Cluster db/pg onto kind-kind.
# Mirrors pg-ppi's hack/e2e-setup.sh minus its kind and Linkerd steps; safe to rerun.
#
# What this deploys on kind-kind; ns linkerd comes from build_3.
# Image ghcr.io/daniel-garcia/pg-ppi:dev runs both the plugin and the sidecar.
#
#   ns cert-manager: cert-manager
#     | Issuer pgppi-selfsigned issues pgppi-server-tls, pgppi-client-tls
#     v
#   ns cnpg-system
#   +-------------------------+  gRPC, mTLS   +---------------------------+
#   | cnpg-controller-manager |-------------->| deploy/pgppi              |
#   +-------------------------+  svc pgppi    | CNPG-I plugin             |
#     | reconciles               :9090        +---------------------------+
#     v                                         | lifecycle hook patches
#   ns db: Cluster pg --> pod pg-1 <------------+ instance pods only:
#                                     + container pgppi
#                                     + linkerd.io/inject: enabled
#                                     + config.linkerd.io/opaque-ports:
#                                         5432,15432
#                                     + config.linkerd.io/
#                                         proxy-protocol-v2-inbound-ports:
#                                         15432
#
#   ns linkerd (build_3): linkerd-identity, linkerd-destination,
#   linkerd-proxy-injector. The injector adds linkerd-proxy to pods with
#   linkerd.io/inject and turns the PROXY v2 annotation into env
#   LINKERD2_PROXY_INBOUND_PORTS_PROXY_PROTOCOL_V2=15432.
#
# Request path, billing client to Postgres:
#
#   ns billing                         ns db
#   +--------------------+             +-------------------------------+
#   | deploy/billing     |  mTLS to    | pod pg-1                      |
#   | (SA billing)       |  svc        |                               |
#   | client: psql       |  pg-pgppi   |                               |
#   | user=billing_app   |  :15432     |                               |
#   | linkerd-proxy -----+------------>| linkerd-proxy :4143           |
#   +--------------------+             |  ends mTLS, prepends PROXY v2 |
#                                      |  with TLV 0xE0 = id           |
#                                      |    | $(POD_IP):15432          |
#                                      |    v                          |
#                                      | pgppi                         |
#                                      |  strips header, opens TLS     |
#                                      |  with client cert CN = id     |
#                                      |    | 127.0.0.1:5432           |
#                                      |    v                          |
#                                      | postgres                      |
#                                      |  pg_hba: cert map=linkerd     |
#                                      |  pg_ident: id -> billing_app  |
#                                      +-------------------------------+
#   id = billing.billing.serviceaccount.identity.linkerd.cluster.local
#   Other clients in ns billing: reporting, intruder, cdc, unmeshed.
set -euo pipefail

# Inputs with defaults; PGPPI_DIR is a pg-ppi checkout next to launchy-dev.
PGPPI_DIR=${PGPPI_DIR:-$(cd "$(dirname "$0")/../.." && pwd)/pg-ppi}
PGPPI_IMAGE=${PGPPI_IMAGE:-ghcr.io/daniel-garcia/pg-ppi:dev}
CERT_MANAGER_VERSION=${CERT_MANAGER_VERSION:-v1.21.2}
CNPG_VERSION=${CNPG_VERSION:-1.30.1}

# Fails fast when the pg-ppi checkout is missing.
if [ ! -f "$PGPPI_DIR/hack/e2e-setup.sh" ]; then
  echo "pg-ppi checkout not found: $PGPPI_DIR" >&2
  echo "run: git clone https://github.com/daniel-garcia/pg-ppi.git $PGPPI_DIR" >&2
  exit 1
fi

# Targets the cluster from init_1_create_cluster.sh.
CONTEXT=kind-kind
KIND_CLUSTER=kind

# Helpers: kubectl on CONTEXT, and a bold step banner.
k() { kubectl --context "$CONTEXT" "$@"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# Builds the pgppi image into kind; the manifests use pg-ppi:dev with IfNotPresent.
# A PGPPI_IMAGE override is loaded but not referenced, as in pg-ppi's own script.
step "pgppi image $PGPPI_IMAGE"
docker build -t "$PGPPI_IMAGE" "$PGPPI_DIR"
kind load docker-image --name "$KIND_CLUSTER" "$PGPPI_IMAGE"

# Installs cert-manager, which issues the plugin's gRPC TLS certificates.
step "cert-manager $CERT_MANAGER_VERSION"
k apply -f "https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml"
k -n cert-manager rollout status deploy --timeout=180s

# Installs CloudNativePG; server-side because its CRDs exceed the client-side annotation limit.
step "CloudNativePG $CNPG_VERSION"
k apply --server-side -f \
  "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${CNPG_VERSION%.*}/releases/cnpg-$CNPG_VERSION.yaml"
k -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout=180s

# Deploys the pgppi plugin, restarted once its certificates are Ready.
# The first pod may start before cert-manager has created its secrets.
step "pgppi CNPG-I plugin"
k apply -k "$PGPPI_DIR/deploy/plugin"
k -n cnpg-system wait certificate --all --for=condition=Ready --timeout=120s
k -n cnpg-system rollout restart deploy/pgppi
k -n cnpg-system rollout status deploy/pgppi --timeout=120s

# Deploys Cluster db/pg and the billing clients.
# Cluster Ready proves the plugin injected the instance pod's sidecars.
step "example Cluster and clients"
k apply -f "$PGPPI_DIR/examples/cluster.yaml"
k apply -f "$PGPPI_DIR/examples/clients.yaml"
k -n db wait cluster/pg --for=condition=Ready --timeout=600s
k -n billing rollout status deploy --timeout=300s

# Lists the db pods to show where the instance runs.
step "ready"
k -n db get pods -o wide
