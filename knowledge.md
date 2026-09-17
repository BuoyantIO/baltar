# Debugging Linkerd with this test setup

What stays true across sessions: how to measure, what the setup's quirks
would otherwise make you conclude wrongly, and the traps. Run state and
current numbers live in the `checklist_*.md` files, not here.

## Measure the right thing

**CPU: read the proxy's own `process_cpu_seconds_total`** from its admin
endpoint (:4191). Sample twice, divide the delta by the *measured*
elapsed time, ×100 for percent of one core. Nothing else is synchronous.

**cAdvisor lags ~10-20s.** Useless for runs under a couple of minutes: it
once reported half the CPU of a 30s run. The accounting is the same, only
the read is late. It remains the only source for containers that export
no metrics, and it is trimmed here: no `container_threads`, no
`container_cpu_cfs_throttled_seconds_total`.

**Threads: the proxy's `process_threads`.**

**Latency: use the mean from `_sum/_count`.** `response_latency_ms`
buckets are 1, 2, 3, 4, 5, 10, 20, 30, 40, 50, 100, 200ms, so everything
sub-millisecond lands in one bucket and any quantile there is
interpolation. Between 5 and 10ms the bucket is 5ms wide.

**Bracket a run with two counter snapshots and subtract.** A `rate()`
window does not align with the run and smears idle background traffic in.

**`tokio_rt_busy_seconds_total` is not CPU and is not comparable across
worker counts.** It counts unparked wall-clock, including work-stealing
and spin-before-park, so it overstates saturation more as workers are
added. Below ~1s sampling it is meaningless: it advances in lumps.

**Scraping is cheap over an established port-forward** (~2.4ms) and
expensive via `linkerd diagnostics proxy-metrics` (a process and a fresh
forward per call). Sampling at 1Hz perturbed throughput by <0.4%.

## Attribute before you tune

Two methods, and agreeing answers are worth far more than one:

- **Latency per hop**: diff each proxy's `response_latency_ms` inbound and
  outbound across the run, then subtract adjacent hops. Only the proxy
  rows are measured; everything else is subtraction and errors compound.
- **CPU per request**: CPU seconds over the window ÷ requests, per
  container. No subtraction, so it is the stronger check.

**Check saturation before touching a limit.** A cap only matters if
something reaches it. Raising the proxy's core cap bought ~7% precisely
because no proxy was near the old cap; the measurement that would have
predicted that took one query.

**A closed-loop load test is latency-bound.** With N connections each
doing one request at a time, throughput ≈ N ÷ latency. If adding
connections only raises latency and leaves throughput flat, you are not
capacity-limited and adding capacity will not help.

## Setup facts that change conclusions

**On macOS, Docker bridge IPs are unreachable from the host; on Linux they
are routable.** Every access decision follows from this. A container on
the `kind` network reaching the NodePort is roughly twice the throughput
of any host-side path, and most of that loss is the macOS-to-VM boundary
rather than whatever relay you chose. Benchmark from inside the network.

**`kubectl port-forward` binds one pod and dies with it**, so meshing or
unmeshing kills it mid-run. Anything targeting a Service's NodePort
survives pod replacement. Pin the NodePort, or it is reassigned on every
reinstall and a saved URL silently points at nothing.

**Know what your test path actually exercises.** emojivoto's `/` is a
560-byte static page that makes no backend calls, so it does not exercise
the mesh's RPC path at all. `/api/list` fans out 1:1 to emoji-svc and
returns 8x the body. `/api/vote` is the only path reaching voting-svc.
An experiment at the wrong path measures the wrong thing.

**Proxies run as native sidecars** (init containers with
`restartPolicy: Always`), so `.spec.containers` lookups find nothing.

**Proxies have no CPU limit or request by default**, so the tokio worker
count is the only bound. `LINKERD2_PROXY_CORES_MAX` caps worker threads,
not CPU time; `config.linkerd.io/proxy-cpu-limit` sets a real Kubernetes
limit and conflates the two. A 1-core proxy runs tokio's current-thread
runtime, so its main thread is the worker.

## Traps

- **`linkerd inject` silently skips** a workload annotated
  `linkerd.io/inject: disabled`: it prints `skipped`, emits the manifest
  unchanged, and `kubectl apply` reports success. Clear the annotation
  first.
- **`linkerd check --proxy` can exit non-zero for reasons unrelated to
  your workload** (here, a local extension rejecting a flag the CLI
  passes it). Under `set -e` that makes a healthy mesh look broken.
- **`proxy-metrics <workload>` answers for every pod behind it**,
  including one still terminating. Scope to `po/<pod>`.
- **During a rollout the old pod is still Running and sorts first**, so
  `.items[0]` gives you the setting you just replaced. Sort by
  `creationTimestamp`.
- **An unmeshed pod silently disables its own policy.** A Server or
  AuthorizationPolicy is enforced by the target's inbound proxy, so if the
  target came up 1/1 nothing enforces it and access tests pass for the
  wrong reason. linkerd-viz has come up half-injected here after a race
  with the injector; check readiness columns after every build.
- **bash 3.2 returns the EXIT trap's last status**, so a trap ending in
  `wait` on a killed port-forward makes every run exit 143.
- **`cargo check` will not run natively on macOS** for linkerd2-proxy:
  Linux-only socket2 accessors. Cross-compile to a Linux target.

## The proxy's tokio metrics

14 `tokio_rt_*` series, all worker-side, **no blocking-pool metrics**.
They come from `kubert-prometheus-tokio`, a pinned git dependency, wired
up in `linkerd2-proxy/src/rt.rs`: the proxy hands the library its own
runtime handle and registry and polls on a 1s tick, so the library is
linked in, not separate. `--cfg tokio_unstable` is unconditional, so the
blocking-pool accessors are available and simply unexported. Adding
metrics means either an upstream PR plus a tag bump, or registering
gauges directly in `rt.rs`. The series reach Prometheus with pod,
namespace and deployment attached as scrape-time labels, so exporters
should not add identity labels of their own.

**`tokio_rt_injection_queue_depth` is broken upstream**: it duplicates
`tokio_rt_local_queue_depth` because both are set from
`total_local_queue_depth` instead of `global_queue_depth`. Unfixed on
main, shipped since 2023. Do not use it.

## Scripts

Prefixes match the groups below, and numbers give run order within a
group. `init_` starts at `init_0`, which builds nothing but must run
first. `pf_` scripts block until ctrl-C, so a rebuild must never call
one. `wip_` marks a script that works but is not fit to hand over.

### Setup
- `init_0_prerequisites.sh` checks required tools; exits non-zero if one is missing
- `init_1_create_cluster.sh` kind cluster plus Gateway API CRDs; reads `init_1_create_cluster.yaml` to publish the NodePort to the host
- `init_2_install_linkerd.sh` control plane, ending on `linkerd check`
- `init_3_install_linkerd_viz.sh` viz, which carries the Prometheus everything reads
- `init_4_install_grafana.sh` grafana, pointed at that Prometheus
- `init_5_install_headlamp.sh` headlamp, the cluster UI
- `init_6_deploy_emojivoto.sh` the demo app, which arrives unmeshed
- `init_7_install_haproxy.sh` haproxy ingress and its Ingress, NodePort pinned
- `cleanup_1_cluster.sh` deletes the cluster; nothing survives it

### General
- `pf_1_viz_dashboard.sh` opens the linkerd-viz dashboard
- `pf_2_grafana_dashboard.sh` opens grafana, password to the clipboard
- `pf_3_headlamp_dashboard.sh` opens headlamp, token to the clipboard
- `pf_4_haproxy_forward.sh` forwards the ingress to localhost:8080 for a browser; do not benchmark through it

### Dev
- `dev_1_mesh_emojivoto.sh <mesh|unmesh>` meshes or unmeshes emojivoto
- `dev_2_mesh_haproxy.sh <mesh|unmesh>` meshes or unmeshes the ingress; unmesh currently resets the pinned NodePort, so re-run init_7 after it
- `dev_3_modify_linkerd_cores.sh [NS] [WORKLOAD] [CORES]` sets the proxy worker cap, defaulting to `emojivoto deploy/web`
- `dev_4_inspect_cores.sh [NS] [WORKLOAD]` confirms the cap took: annotation, container env, the proxy's startup decision and `tokio_rt_workers` together, because they can disagree

### Testing
- `test_load_1_local_tunnel.sh [PORT] [PATH]` drives load from the host, only when you deliberately want to measure a host-side path
- `test_load_2_docker_nodeport.sh [CONNS] [DURATION]` the default load generator: a container on the `kind` network straight at the NodePort

### In revision
`wip_`: these produced the CPU and per-hop-latency results but are not
fit to hand over: hardcoded proxy targets that break on an unmeshed workload, a
hardcoded 200% threshold, and no cAdvisor fallback for a container with
no proxy.

- `wip_1_proxy_runtime.sh` KEY=VALUE snapshot of one proxy's tokio counters, threads and CPU, meant to be diffed
- `wip_2_hop_latency.sh` brackets a run and diffs every proxy's latency histogram per hop
- `wip_3_measured.sh` wraps a run with before/after proxy snapshots, for totals
- `wip_4_sampled.sh` samples throughout a run, which is what finds peaks an average hides

## Tooling

`scripts/init_0_prerequisites.sh` checks every prerequisite and exits
non-zero if a required one is missing. The yq *flavour* matters: the Go
(mikefarah) syntax is what the scripts use, and the identically-named
python wrapper fails on it.
