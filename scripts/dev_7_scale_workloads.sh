#!/usr/bin/env bash
# Usage: ./dev_7_scale_workloads.sh [EMOJIVOTO_REPLICAS] [HAPROXY_REPLICAS]
#   e.g. ./dev_7_scale_workloads.sh          # 5 emojivoto, 1 haproxy
#        ./dev_7_scale_workloads.sh 1 2      # back to the install defaults
#
# Sets the replica count of the emojivoto deployments and of the HAProxy
# ingress controller, then waits for every rollout and prints what is
# actually running.
#
# 1 haproxy and 5 emojivoto is the interesting shape.
#
# With 2 ingress replicas behind one NodePort the load splits unevenly
# (measured 2026-09-17: one pod took ~1.6x the other), so neither proxy
# gets near its core budget. One replica concentrates the whole ingress
# load into one proxy. Scaling emojivoto up moves the bottleneck off
# the backend, which is what capped throughput at ~14.7k rps.
#
# The dev_<n>_ prefix marks a script that changes something already
# installed, as against init_ (build it), pf_ (expose it), test_load_
# (drive it) and cleanup_ (remove it).
#
# NOTE ON vote-bot. It is scaled with everything else by default, but
# it is the one workload whose replica count changes the measurement
# rather than the capacity.
#
# It generates its own continuous traffic against web-svc, so N
# replicas of it means N times the uncontrolled background load sitting
# underneath whatever the load driver is measuring. It is scaled by
# default because "all emojivoto workloads" is what was asked for.
# To take it out of the picture:
#   VOTE_BOT_REPLICAS=0 ./dev_7_scale_workloads.sh
#
# Scales and nothing else.
#
# It does not mesh, unmesh, measure or generate load.
set -euo pipefail

EMOJIVOTO_REPLICAS="${1:-5}"
HAPROXY_REPLICAS="${2:-1}"
# Defaults to the emojivoto count, so the plain invocation does what
# the usage line says.
#
# Set it explicitly to hold vote-bot down.
VOTE_BOT_REPLICAS="${VOTE_BOT_REPLICAS:-$EMOJIVOTO_REPLICAS}"

EMOJIVOTO_NS=emojivoto
HAPROXY_NS=haproxy-controller
HAPROXY_DEPLOY=haproxy-ingress-kubernetes-ingress

for n in "$EMOJIVOTO_REPLICAS" "$HAPROXY_REPLICAS" "$VOTE_BOT_REPLICAS"; do
  case "$n" in ''|*[!0-9]*) echo "replica counts must be whole numbers" >&2; exit 1 ;; esac
done

echo "=== 1. Scaling emojivoto ==="
# web, emoji and voting carry the request path.
#
# vote-bot is scaled separately because it is a load generator, not
# capacity.
for d in web emoji voting; do
  kubectl scale deploy/"$d" -n "$EMOJIVOTO_NS" --replicas="$EMOJIVOTO_REPLICAS"
done
kubectl scale deploy/vote-bot -n "$EMOJIVOTO_NS" --replicas="$VOTE_BOT_REPLICAS"

echo "=== 2. Scaling the HAProxy ingress controller ==="
kubectl scale deploy/"$HAPROXY_DEPLOY" -n "$HAPROXY_NS" --replicas="$HAPROXY_REPLICAS"

echo "=== 3. Waiting for rollouts ==="
# Wait for the pods, not only for the Deployment.
#
# A scale-up is not complete when the Deployment says so: the new pods
# have to be Ready, and a meshed pod is not Ready until its proxy is.
for d in web emoji voting vote-bot; do
  kubectl rollout status deploy/"$d" -n "$EMOJIVOTO_NS" --timeout=180s
done
kubectl rollout status deploy/"$HAPROXY_DEPLOY" -n "$HAPROXY_NS" --timeout=180s

echo "=== 4. Running now ==="
# READY is the count that matters, not the replica field that was just
# set.
kubectl get deploy -n "$EMOJIVOTO_NS" \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas'
kubectl get deploy -n "$HAPROXY_NS" "$HAPROXY_DEPLOY" \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas'

if [ "$VOTE_BOT_REPLICAS" -gt 1 ]; then
  echo
  echo "note: vote-bot is at $VOTE_BOT_REPLICAS replicas, so there are" >&2
  echo "$VOTE_BOT_REPLICAS generators putting untracked load on web-svc" >&2
  echo "underneath anything you measure. VOTE_BOT_REPLICAS=0 removes it." >&2
fi
