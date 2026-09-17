#!/usr/bin/env bash
# Usage: ./init_7_install_haproxy.sh
#        HAPROXY_NODEPORT=31080 ./init_7_install_haproxy.sh
# Setup step 7. Installs the HAProxy ingress controller and the Ingress
# that routes to emojivoto's web-svc, so init_6 must have run first.
# The port-forward that used to end this script now lives in
# pf_4_haproxy_forward.sh, which blocks and so is not a setup step.
set -euo pipefail

echo "=== 1. Installing HAProxy Ingress Controller via Helm ==="
helm repo add haproxytech https://haproxytech.github.io/helm-charts
helm repo update

# The NodePort is pinned rather than randomly assigned. An unpinned
# port moves on every reinstall, which silently broke the load-test URL
# after the last rebuild, and it would break an SSH tunnel or a kind
# extraPortMapping the same way. The chart's values document this as
# "If empty, random ports will be used".
helm upgrade --install haproxy-ingress haproxytech/kubernetes-ingress \
  --create-namespace \
  --namespace haproxy-controller \
  --set controller.service.nodePorts.http=${HAPROXY_NODEPORT:-31080}

echo "=== 2. Waiting for HAProxy Controller Pod to be Ready ==="
kubectl wait --namespace haproxy-controller \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=kubernetes-ingress \
  --timeout=90s

echo "=== 3. Applying HAProxy Ingress Resource in 'emojivoto' Namespace ==="
cat <<'INGRESS' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: emojivoto-ingress
  namespace: emojivoto
  annotations:
    haproxy.org/ingress.class: "haproxy"
spec:
  ingressClassName: haproxy
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-svc
            port:
              number: 80
INGRESS

# ==============================================================================
# CLEANUP COMMANDS (Removes HAProxy & Ingress, keeps Emojivoto running)
# ==============================================================================
# kubectl delete ingress emojivoto-ingress -n emojivoto
# helm uninstall haproxy-ingress -n haproxy-controller
# kubectl delete namespace haproxy-controller
