#!/usr/bin/env bash
# Usage: ./init_5_install_headlamp.sh
#
# Setup step 5. Installs Headlamp, the cluster UI, into kube-system.
#
# Unpinned: helm resolves whatever chart version the repo currently has.
set -euo pipefail

helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm install my-headlamp headlamp/headlamp --namespace kube-system
