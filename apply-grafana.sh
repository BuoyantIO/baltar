#!/usr/bin/env bash
# Installs Grafana wired to the linkerd-viz Prometheus.
# Pulls the grafana chart locally, patches its values.yaml, installs
# from that local copy, then deletes the local copy.
set -e

# fetch chart -> ./grafana-install/grafana
rm -rf grafana-install
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo update grafana
helm pull grafana/grafana --untar --untardir grafana-install

# use linkerd's own values.yaml as source of truth (datasource + dashboards),
# layered on top of the chart's defaults - not replacing them
curl -sSL https://raw.githubusercontent.com/linkerd/linkerd2/main/grafana/values.yaml \
  -o grafana-install/linkerd-values.yaml

# fixes so grafana works when reverse-proxied under /grafana/
yq -i '.["grafana.ini"].server.root_url = "%(protocol)s://%(domain)s:%(http_port)s/grafana/"' grafana-install/linkerd-values.yaml
yq -i '.["grafana.ini"].server.serve_from_sub_path = true' grafana-install/linkerd-values.yaml

kubectl delete namespace grafana --ignore-not-found
kubectl create namespace grafana
helm install grafana grafana-install/grafana -n grafana -f grafana-install/linkerd-values.yaml

# allow grafana's ServiceAccount to query the linkerd-viz prometheus
# (its admin/query port is deny-by-default, only metrics-api is allowed otherwise)
kubectl apply -f grafana-authz.yaml

rm -rf grafana-install
