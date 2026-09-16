# set the port
PORT="${1:-8080}"
# set the http path: `blocking`
QUERY="${2:-}"

bombardier -c 125 -n 10000000 http://localhost:$PORT/$QUERY

# Bombarding http://localhost:8080 with 10000000 requests using 125 connections
#  10000000 / 10000000 [============================================] 100.00% 37s Done!
# Statistics        Avg      Stdev        Max
#   Reqs/sec    264560.00   10733.06     268434
#   Latency      471.00us   522.34us    51.00ms
#   HTTP codes:
#     1xx - 0, 2xx - 10000000, 3xx - 0, 4xx - 0, 5xx - 0
#     others - 0
#   Throughput:   292.92MB/s
