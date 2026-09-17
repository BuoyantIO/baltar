#!/usr/bin/env bash
# Usage: ./pf_4_haproxy_forward.sh
# Forwards the HAProxy ingress to http://localhost:8080 for browser use.
# Emojivoto is what you reach through it, but it is the ingress that is
# being exposed here.
#
# The pf_<n>_ prefix marks a script that port-forwards or exposes a
# service. The number follows the init_ step that installs what it
# exposes: the haproxy ingress is init_7, so this is pf_4. It blocks until
# ctrl-C, so a rebuild chain must not run it.
#
# Do not benchmark through this. Per checklist_load_test_linkerd.md,
# kubectl port-forward measured 23.1k RPS against 53.4k for the same
# settings hit directly on the NodePort. Use scripts/test_load_2_docker_nodeport.sh.
set -euo pipefail

echo "Access Emojivoto in your browser at: http://localhost:8080"
echo "Press Ctrl+C to stop forwarding."

kubectl port-forward -n haproxy-controller svc/haproxy-ingress-kubernetes-ingress 8080:80
