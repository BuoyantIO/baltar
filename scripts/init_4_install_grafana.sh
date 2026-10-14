#!/usr/bin/env bash
# Run from the launchy-dev repo root.
# Usage: ./scripts/init_4_install_grafana.sh
#
# Setup step 4. Installs Grafana wired to the linkerd-viz Prometheus.
#
# It pulls the grafana chart locally, patches its values.yaml, installs
# from that local copy, then deletes the local copy.
#
# Requires: helm, yq, curl, and a linkerd-viz install already in the
# cluster, since the datasource and the authz policy both target it.
# Destructive: deletes and recreates the `grafana` namespace.
set -euo pipefail

# Work dir under the repo root; deleted at the end.
WORKDIR=grafana-install

# Fetches the chart into $WORKDIR/grafana.
rm -rf "$WORKDIR"
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo update grafana
helm pull grafana/grafana --untar --untardir "$WORKDIR"

# Uses linkerd's own values.yaml as the source of truth for the
# datasource and dashboards.
#
# It is layered on top of the chart's defaults, not replacing them.
curl -sSL https://raw.githubusercontent.com/linkerd/linkerd2/main/grafana/values.yaml \
  -o "$WORKDIR/linkerd-values.yaml"

# Fixes so grafana works when reverse-proxied under /grafana/.
yq -i '.["grafana.ini"].server.root_url = "%(protocol)s://%(domain)s:%(http_port)s/grafana/"' "$WORKDIR/linkerd-values.yaml"
yq -i '.["grafana.ini"].server.serve_from_sub_path = true' "$WORKDIR/linkerd-values.yaml"

kubectl delete namespace grafana --ignore-not-found
kubectl create namespace grafana
helm install grafana "$WORKDIR/grafana" -n grafana -f "$WORKDIR/linkerd-values.yaml"

# Allows grafana's ServiceAccount to query the linkerd-viz prometheus.
#
# Its admin/query port is deny-by-default: only metrics-api is allowed
# otherwise.
kubectl apply -f https://raw.githubusercontent.com/linkerd/linkerd2/main/grafana/authzpolicy-grafana.yaml

# Cleans up the work dir.
rm -rf "$WORKDIR"
