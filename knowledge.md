# Debugging Linkerd with this test setup

What stays true across sessions: how to measure, what the setup's quirks
would otherwise make you conclude wrongly, and the traps. Run state and
current numbers live in the `checklist_*.md` files, not here.

## Measure the right thing

**CPU: read cgroup v2 `cpu.stat` `usage_usec`** through a pod that
hostPath-mounts the node's `/sys/fs/cgroup`. Sample twice, divide the
delta by the *measured* elapsed time, ×100 for percent of one core.

This supersedes the proxy's own `process_cpu_seconds_total`, which is
still correct but only exists where there is a proxy. An unmeshed
workload has no :4191 and no `job="linkerd-proxy"` series, so any
meshed-vs-unmeshed comparison needs a source that reads both states
identically. The cgroup counter does; it is also microsecond-resolution
against the proxy counter's two decimal places.

The two agree. Under load, over an 18.568s window on a meshed
`emojivoto/web` proxy: proxy counter 7.28 CPU-s, cgroup 7.284686 CPU-s,
a **+0.064% disagreement**, which is inside the proxy counter's own 10ms
quantization (±0.069% on 7.28s). Idle they disagree by 1.50%, but that
is 3.16ms on a 0.21s delta, and the cgroup read is the more precise of
the two, not the less.

The path is
`/sys/fs/cgroup/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-<qos>.slice/kubelet-kubepods-<qos>-pod<UID>.slice/cri-containerd-<containerID>.scope/cpu.stat`.
`<qos>` is `besteffort`, `burstable`, or absent for guaranteed; `<UID>`
is `.metadata.uid` with `-` replaced by `_`. It advances every second
with no lumps, so 1Hz is a real sampling rate here.

**Stream it, do not exec per sample.** One `kubectl exec` costs ~85ms and
a single exec reads all ~30 container cgroups in 105ms, so cost is per
sample, not per target. A long-lived exec running a loop inside the pod
removes even that. Per-sample execs would mean ~86,000 process spawns a
day.

**Killing the local `kubectl exec` does not kill the in-pod loop.** The
loop parks in `write(2)` because the pipe stays open and unread on the
pod side, so it never sees EPIPE. Stale loops accumulate and double the
sample rate. Mark the loop and reap it by name before every connect.

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

**CPU per request is the figure that survives a config change.** Across
two runs with different replica counts, connection counts and
throughputs, the ingress proxy cost 115.9 and 106.8 uCPU/req: the same
number. Percent-of-a-core differed wildly between them (198% summed
across two proxies versus 161% on one) and is meaningless without the
request rate beside it. Quote percent only with throughput attached.

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

**`helm upgrade --reset-values` drops every user-supplied value, and a
value the chart defaults differently is then patched back to that
default.** Confirmed for the pinned NodePort: the chart default is
`nodePorts: {}`, documented as "If empty, random ports will be used", so
after `--reset-values` the rendered Service carries no nodePort and the
old pinned one is patched away.

**Whether an out-of-band change survives depends on one thing: does the
chart render that field?** Measured 2026-09-17, both directions.

- **A field the chart renders is patched back, even if its rendered value
  did not change between releases.** `kubectl scale` to 1, then a
  byte-identical `--reset-values` upgrade, and replicas returns to the
  chart's 2. So a mesh toggle silently rescales a deployment someone
  scaled by hand.
- **A field the chart renders in neither manifest is left alone.** A
  `kubectl patch` annotation that helm never set, such as the
  `config.linkerd.io/proxy-additional-env` that
  `dev_3_modify_linkerd_cores.sh` writes, survived three separate
  `--reset-values` upgrades. In the decisive one the pod was not even
  replaced, so helm sent no pod-template patch at all.

The practical consequence: **pin proxy cores once with `dev_3` and later
mesh toggles keep them.** One rollout, and mesh scripts do not need to
know about cores. Replica counts are the opposite and must be read from
the live object and passed back through the values on every upgrade.

The intuition "helm erases anything set outside helm" is wrong and was
recorded here as fact before it was tested.

## What a mesh toggle looks like under load

**The proxy does not spike when the mesh lands. It reads ~0, then
steps.** A newly meshed pod is Running and Ready while receiving no
traffic at all, because a closed-loop generator holds long-lived
keep-alive connections and conntrack pins each to the pod it was
established with. Nothing moves until the old pod is terminated.

Measured twice: the idle period was ~40s with 2 replicas (the deployment
rolls one at a time) and ~13s with 1 (it surges then terminates). The
handover then completes in one to three ticks, straight to the plateau,
with no overshoot. **The interesting moment is the old pod's
termination, not the helm upgrade**, and the two are tens of seconds
apart.

**Mark the roll and never average across it.** The old container's
counter stops and the new one starts from zero; they must not join. A
container disappearing is a gap, never a zero, because a zero drags an
average down silently.

**Never sum proxy CPU across replicas and compare it to a core budget.**
Each proxy has its own. Two proxies summing to 198% of a core look like
they are grazing a 2-core cap and are in fact at half of it each.

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
- `init_8_install_cpu_probe.sh` the cpu-probe DaemonSet that every CPU measurement reads through; verifies the cgroup mount rather than trusting Ready, since a Ready pod with the wrong tree looks identical
- `cleanup_1_cluster.sh` deletes the cluster; nothing survives it

### General
- `pf_1_viz_dashboard.sh` opens the linkerd-viz dashboard
- `pf_2_grafana_dashboard.sh` opens grafana, password to the clipboard
- `pf_3_headlamp_dashboard.sh` opens headlamp, token to the clipboard
- `pf_4_haproxy_forward.sh` forwards the ingress to localhost:8080 for a browser; do not benchmark through it

### Dev
- `dev_1_mesh_emojivoto.sh <mesh|unmesh>` meshes or unmeshes emojivoto
- `dev_2_mesh_haproxy.sh <mesh|unmesh>` meshes or unmeshes the ingress, and nothing else. It re-pins the NodePort on unmesh and passes the live replica count back through on both paths, because those are the two fields an upgrade would otherwise undo. Core pinning is `dev_3`'s job and survives a toggle on its own.
- `dev_3_modify_linkerd_cores.sh [NS] [WORKLOAD] [CORES]` sets the proxy worker cap, defaulting to `emojivoto deploy/web`
- `dev_4_inspect_cores.sh [NS] [WORKLOAD]` confirms the cap took: annotation, container env, the proxy's startup decision and `tokio_rt_workers` together, because they can disagree
- `dev_5_measure_start.sh <run> <ns> <workload>` starts the CPU sampler on one workload and blocks; `RESOLVE_INTERVAL` (default 5s) sets how fast a roll is noticed
- `dev_6_measure_stop.sh` ends the run and writes `<run>.csv`, one row per container per second
- `dev_7_scale_workloads.sh [EMOJIVOTO] [HAPROXY]` sets replica counts, defaulting to 5 and 1; `VOTE_BOT_REPLICAS=0` removes the built-in load generator, which is capacity for the app but noise for a measurement

### Testing
- `test_load_1_local_tunnel.sh [PORT] [PATH]` drives load from the host, only when you deliberately want to measure a host-side path
- `test_load_2_docker_nodeport.sh [CONNS] [DURATION] [URL]` the default load generator: a container on the `kind` network straight at the NodePort. Given a URL it skips the kubectl derivation entirely, which is how it points at a remote cluster with no code change. It prints ONE aggregate for the whole run, so a run spanning two mesh states cannot have its two request rates separated: that needs two runs.

`util_measure.sh` is sourced by `dev_5` and `dev_6` and run directly by
neither. It holds only what both need: the state-dir layout, locating the
probe pod, the in-pod reaper, the cgroup and container-id contract the
two ends agree on, workload-to-pod resolution with mesh state, and the
CSV schema.

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
