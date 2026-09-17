#!/usr/bin/env bash
# Usage: ./init_2_install_linkerd.sh
#
# Setup step 2. Installs the Linkerd control plane with whatever
# `linkerd` CLI is on PATH.
#
# The version is not pinned here, so the CLI decides it.
set -euo pipefail

# Catches an unfit cluster before anything is applied.
#
# A failure here leaves nothing half-installed.
linkerd check --pre

# CRDs go first.
#
# The control plane manifests reference types they define.
linkerd install --crds | kubectl apply -f -

linkerd install | kubectl apply -f -

# Blocks until the control plane is actually healthy.
#
# The next setup step then starts from a working mesh rather than a
# scheduled one.
linkerd check
