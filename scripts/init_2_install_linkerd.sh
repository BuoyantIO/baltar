#!/usr/bin/env bash
# Usage: ./init_2_install_linkerd.sh
# Setup step 2. Installs the Linkerd control plane with whatever `linkerd`
# CLI is on PATH: the version is not pinned here, so the CLI decides it.
set -euo pipefail

# Catches an unfit cluster before anything is applied, so a failure here
# leaves nothing half-installed.
linkerd check --pre

# CRDs first: the control plane manifests reference types they define.
linkerd install --crds | kubectl apply -f -

linkerd install | kubectl apply -f -

# Blocks until the control plane is actually healthy, so the next setup
# step starts from a working mesh rather than a scheduled one.
linkerd check
