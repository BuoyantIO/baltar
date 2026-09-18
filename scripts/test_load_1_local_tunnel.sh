#!/usr/bin/env bash
# Usage: test_load_1_local_tunnel.sh [PORT] [PATH]
#
# Load test through whatever is publishing localhost:8080, tunnel
# included: kubectl port-forward, or a socat bridge to the NodePort.
#
# It measures that path as much as the cluster; for the cluster alone
# test_load_2_docker_nodeport.sh is the one to use. bombardier must be
# installed on the host.

# set the port
PORT="${1:-8080}"
# set the http path: `blocking`
QUERY="${2:-}"

bombardier -c 125 -d 30s http://localhost:$PORT/$QUERY

# Bombarding http://localhost:8080 with 10000000 requests using 125 connections
#  10000000 / 10000000 [============================================] 100.00% 37s Done!
# Statistics        Avg      Stdev        Max
#   Reqs/sec    264560.00   10733.06     268434
#   Latency      471.00us   522.34us    51.00ms
#   HTTP codes:
#     1xx - 0, 2xx - 10000000, 3xx - 0, 4xx - 0, 5xx - 0
#     others - 0
#   Throughput:   292.92MB/s
