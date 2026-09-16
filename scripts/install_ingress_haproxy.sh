#!/usr/bin/env bash
set -e

echo "=== 1. Deploying Emojivoto Application ==="
curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/emojivoto.yml | kubectl apply -f -

echo "=== 2. Installing HAProxy Ingress Controller via Helm ==="
helm repo add haproxytech https://haproxytech.github.io/helm-charts
helm repo update

helm upgrade --install haproxy-ingress haproxytech/kubernetes-ingress \
  --create-namespace \
  --namespace haproxy-controller

echo "=== 3. Waiting for HAProxy Controller Pod to be Ready ==="
kubectl wait --namespace haproxy-controller \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/name=kubernetes-ingress \
  --timeout=90s

echo "=== 4. Applying HAProxy Ingress Resource in 'emojivoto' Namespace ==="
cat <<EOF | kubectl apply -f -
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
EOF

echo "=== 5. Forwarding HAProxy to http://localhost:8080 ==="
echo "Access Emojivoto in your browser at: http://localhost:8080"
echo "Press Ctrl+C to stop forwarding."

kubectl port-forward -n haproxy-controller svc/haproxy-ingress-kubernetes-ingress 8080:80

# ==============================================================================
# CLEANUP COMMANDS (Removes HAProxy & Ingress, keeps Emojivoto running)
# ==============================================================================
# kubectl delete ingress emojivoto-ingress -n emojivoto
# helm uninstall haproxy-ingress -n haproxy-controller
# kubectl delete namespace haproxy-controller
