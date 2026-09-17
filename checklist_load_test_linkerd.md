# Load test Linkerd: emojivoto via HAProxy ingress

Goal: load test Linkerd, driving emojivoto/web through the HAProxy ingress
controller, with proxy max cores configurable. Load generated from outside
the cluster. Cluster is on this laptop today, moving to an SSH-reachable VM
later, possibly exposed to the public internet.

## Tasks

- [x] 1. Establish how max proxy cores is configured
- [x] 2. Establish how the proxy interprets the cores values
- [x] 3. Determine whether cores config can be applied live or needs a reinstall
- [x] 4. Verify the proxy actually respects CORES_MAX at runtime
- [x] 5. Script: inject core restrictions
- [x] 6. Script: mesh the HAProxy ingress controller
- [x] 7. Load generator outside the cluster
- [x] 8. Determine what actually caps throughput today
- [ ] 9. Run the cores experiment
- [ ] 10. Move the cluster to an SSH-reachable VM
- [ ] 11. Expose the VM to the public internet
- [x] 12. Session setup: checklist workflow rules
- [ ] 13. Verify the cores cap actually bounds CPU

## Learnings

What we know that bears on the goal. Everything here is measured, not assumed.

- **Meshing HAProxy costs 55% of throughput.** 53.4k -> 23.7k RPS at
  c125/30s, p50 1.75ms -> 5.01ms, 100% 2xx both ways. Unmesh recovered
  the baseline, so it is the sidecar, not drift.
- **Every proxy defaults to ONE worker thread**, including the meshed
  HAProxy ingress proxy that carried all that traffic. The default is 1,
  not the node's CPU count. This is the most likely cause of most of that
  55%, and it is the single most promising thing to change.
- **`kubectl port-forward` halves your numbers.** 23.1k vs 53.4k at
  identical settings. Never benchmark through it. Use
  `scripts/load_test_docker.sh`, a Docker container on the `kind` network
  hitting the NodePort directly.
- **Four levers set proxy cores; the best is
  `config.linkerd.io/proxy-additional-env`** setting
  `LINKERD2_PROXY_CORES_MAX` directly. Absolute count, no k8s CPU limit or
  request, no CFS throttling. `proxy-cpu-limit` also gives an absolute
  count but adds a real cgroup quota; `proxy-cpu-ratio-limit` avoids that
  but only takes a ratio.
- **Cores are a THREAD cap, not a CPU cap.** Nothing measured so far shows
  a CPU bound: the proxy also runs a main thread, an admin thread and a
  blocking pool. Only `proxy-cpu-limit` hard-bounds CPU, via throttling.
  Task 13 is the unfinished work here.
- **Changes are live, per workload, ~9s per rollout.** Annotate
  `spec.template.metadata.annotations` and Kubernetes rolls the pods
  itself. Annotating the Deployment's own metadata silently does nothing.
- **Namespace-level `proxy-cpu-ratio-limit` is silently dropped upstream.**
  Per-workload only. Confirmed in source and by two independent tests.
- **Verify with `tokio_rt_workers`**, in the linkerd-viz Prometheus and via
  `linkerd diagnostics proxy-metrics`. Do not count threads: a
  single-threaded proxy has zero threads named `proxy`.
- **The current ~53.5k ceiling is unattributed.** No component is pegged
  and 25% of the node stayed idle. The load generator shares the same
  15-CPU VM as the cluster, so settling this needs task 10.

## 1. Establish how max proxy cores is configured

Find the supported levers on *this* cluster, not on whatever version the
docs describe, and record what each one produces.

- [x] Confirm the feature exists at the installed version
      Injector and proxy both support it at edge-26.9.2 (proxy v2.368.0).
      Landed in edge-25.3.3 via linkerd2#13767 and linkerd2-proxy#3731.
- [x] Identify the annotations and what env vars they produce
      Verified empirically by injecting throwaway pods into a `corestest`
      namespace and reading the proxy env back. Namespace since deleted.
      - `config.linkerd.io/proxy-cpu-ratio-limit: "0.5"`
        -> `LINKERD2_PROXY_CORES_MAX_RATIO=0.5`, no k8s resource limits
      - `config.linkerd.io/proxy-cpu-limit: "6"`
        -> `LINKERD2_PROXY_CORES_MAX=6`, plus a real k8s CPU limit of 6
      - `config.linkerd.io/proxy-cpu-request: "2"`
        -> `LINKERD2_PROXY_CORES=2` and `LINKERD2_PROXY_CORES_MIN=2`
- [x] Decide which lever to use for load testing
      Prefer `proxy-cpu-ratio-limit`. `proxy-cpu-limit` also imposes CFS
      throttling, which makes a bad result ambiguous between thread
      starvation and kernel throttling.
- [x] Check whether the cited issue is relevant
      linkerd2#14813 is "increases the access timeout linkerd+haproxy
      ingress", closed `wontfix` by the stale bot, no linked PRs. Not the
      cores feature. Coincidentally the same haproxy+linkerd topology.
- [ ] Record the Helm equivalents for later cluster-wide use
      `proxy.runtime.workers.minimum`, `.maximum`, `.maximumCPURatio`.
      Not yet verified against the installed chart, only the local BEL
      2.20.2 copy.

## 2. Establish how the proxy interprets the cores values

- [x] Read the precedence rules from proxy source
      From `linkerd/workers/src/lib.rs`:
      - `CORES_MAX` is an absolute thread count, and beats `CORES_MAX_RATIO`
      - `CORES_MIN` clamps upward, so min wins when min > max
      - result is clamped down by `num_cpus::get()`, so >15 is a no-op on
        the current single 15-CPU node
      - if the result is 1 the proxy builds a current-thread runtime,
        otherwise a multi-thread runtime

## 3. Determine whether cores config can be applied live or needs a reinstall

Answer: YES, live, no reinstall. Per-workload changes take effect by
patching the pod template. A cluster-wide default also needs no reinstall
but does need every meshed pod restarted.

- [x] Annotating an existing Deployment and rolling it works
      `emojivoto/web` patched with `proxy-cpu-ratio-limit: "0.4"` went
      from `tokio_rt_workers` 1 to 6 on all three replicas. 0.4 x 15 = 6,
      exact. Proxy env showed `CORES_MAX_RATIO=0.4` and `resources: {}`,
      i.e. no k8s CPU request or limit, as expected for the ratio lever.
- [x] Namespace-level `proxy-cpu-ratio-limit` is SILENTLY IGNORED
      See findings. This is an upstream omission, not a local misconfig.
- [x] A restart is required
      Changing the annotation with no rollout left pods untouched after
      30s: same names, same creation timestamps, workers still 6,
      `generation == observedGeneration`. The count is an env var written
      at admission and read once at proxy startup, so only pod recreation
      moves it.
- [x] Measure rollout turnaround for the sweep
      9 seconds for all 3 replicas, consistent across 3 timed rollouts.
      Budget ~30s per sweep data point, since pods need a few seconds
      past Ready before `proxy-metrics` scrapes cleanly.
- [x] Assess the cost of a cluster-wide default
      No reinstall needed. Control plane was installed by the CLI
      (`linkerd.io/created-by: linkerd/cli edge-26.9.2`, no Helm release
      secret in the `linkerd` namespace). Current values have
      `runtime.workers.minimum: 1` with `maximum` and `maximumCPURatio`
      both unset, which is why every proxy defaults to 1.
      Options, cheapest first:
      1. `linkerd upgrade --set proxy.runtime.workers.maximumCPURatio=X
         | kubectl apply -f -`. Supported path, re-renders rather than
         reinstalls. Restarts control-plane pods. Needs the issuer
         key/cert material or `--from-manifests`.
      2. Edit the `values` key of the `linkerd-config` ConfigMap directly.
         Lowest blast radius and needs NO injector restart: the injector
         re-reads the mounted values file per admission request
         (`controller/proxy-injector/webhook.go:43`), and kubelet refreshes
         the projected volume within ~a minute. Diverges from
         `last-applied-configuration`, and a later `linkerd upgrade`
         silently overwrites it.
      3. Adopt into Helm, then `helm upgrade`. Highest cost, no benefit.
      ALL THREE still require restarting every meshed pod. The value is
      consumed at admission only, so existing pods keep what they were
      injected with.

### Findings from task 3

- **Annotating the Deployment's own `metadata.annotations` silently does
  nothing.** Only `spec.template.metadata.annotations` reaches the
  injector, because the injector sees the Pod admission request, not the
  Deployment. Tested: `kubectl annotate deploy web ...` plus a rollout
  restart produced new pods still at 1 worker with no `CORES_MAX_RATIO`
  env, and no warning, event or error. This is the most likely way to
  think a cores setting is applied when it is not.
- **Patching the pod template is itself a rollout.** Changing a template
  annotation bumps the pod-template hash and the Deployment controller
  rolls a new ReplicaSet on its own. `kubectl rollout restart` is
  redundant there and only adds a `restartedAt` annotation to clean up.
  It is needed only when the annotation lives outside the template.
- **UPSTREAM BUG: namespace-level `config.linkerd.io/proxy-cpu-ratio-limit`
  is dropped silently.** Verified in the local linkerd2 checkout at commit
  `4607bffec`:
    - `AppendNamespaceAnnotations` (`pkg/inject/inject.go:177`) copies only
      `ProxyAnnotations` + `ProxyAlphaConfigAnnotations` + the inject
      annotation onto the pod.
    - The `ProxyAnnotations` list (`inject.go:43-80`) contains
      `ProxyCPULimitAnnotation` and `ProxyCPURequestAnnotation` but NOT
      `ProxyCPURatioLimitAnnotation`.
    - `grep -rn ProxyCPURatioLimitAnnotation pkg/` returns only its
      definition at `pkg/k8s/labels.go:198` and the per-pod override
      handler at `inject.go:479`. It is in neither propagation list.
  Control test ruled out a local cause: namespace-level
  `proxy-log-level: warn` DID propagate on the same namespace.
  Consequence for us: cores must be set per workload, not per namespace,
  unless we use `proxy-cpu-request`/`proxy-cpu-limit`, which do appear in
  the list. That half is source-based inference and was NOT empirically
  confirmed, because the node is at 94% CPU requests (14170m/15000m) and
  a namespace-level request of 2 across 3 replicas risked Pending pods.
- **Default-injected proxies carry explicit `CORES=1` and `CORES_MIN=1`.**
  The single-threaded default is set deliberately by the injector, not a
  fallback inside the proxy.

## 4. Verify the proxy actually respects CORES_MAX at runtime

Scratch pods live in namespace `corestest`, manifest at `corestest.yaml`.

- [x] Find a way to observe the proxy's computed core count
      The proxy announces it at startup. No debug container needed:
        kubectl logs -n <ns> <pod> -c linkerd-proxy | grep 'proxy runtime'
      Emits either `Using single-threaded proxy runtime` or
      `Using multi-threaded proxy runtime cores=N`, from `linkerd2_proxy::rt`.
      This is the proxy's own decision, i.e. intent, not observed OS threads.
- [x] Confirm the count tracks the cores settings across several values
      Verified directly, not taken from the agent's report:
        c-baseline  (no annotations)        -> single-threaded
        c-max2      (ratio 0.14)            -> cores=2
        c-max8      (ratio 0.54)            -> cores=8
        c-min4max2  (request 4 + ratio 0.14)-> cores=4
        c-limit4    (cpu-limit 4)           -> cores=4
      Ratio arithmetic on the 15-CPU node: 15*0.14=2.1 -> 2, 15*0.54=8.1 -> 8.
      Both chosen mid-interval so the result does not depend on round vs floor.
- [x] Confirm the MIN-beats-MAX clamp behaves as the source says
      c-min4max2 has min 4 against a ratio-derived max of 2 and reports
      cores=4. Min wins, as `.max(min_cores)` in the source requires.
- [x] Confirm the real runtime thread count, not just the announced one
      The proxy exports a Prometheus gauge `tokio_rt_workers`, "The number
      of worker threads used by the runtime", backed by tokio's
      `RuntimeMetrics::num_workers()`. Registered on the proxy runtime,
      not the admin runtime (`linkerd2-proxy/src/rt.rs:108-111`).
        linkerd diagnostics proxy-metrics -n <ns> po/<pod> \
          | awk '/^tokio_rt_workers /{print $2}'
      Cross-checked directly against all five corestest pods. Gauge matched
      the startup log in every case: 1, 2, 8, 4, 4.
      This is the metric to use, not total thread count. See findings.

### Findings from task 4

- **The default with no cores annotation is 1, not the node's CPU count.**
  `Workers::cores()` falls back to 1 when neither max nor ratio is set. So
  every unannotated proxy in this cluster, including all of emojivoto, is
  running a single-threaded runtime today. This is the baseline the load
  test starts from.
- **`CORES_MIN > CORES_MAX` is structurally unreachable via annotations.**
  `proxy-cpu-request` sets a real k8s CPU request and `proxy-cpu-limit` a
  real k8s limit, and k8s rejects request > limit. Verified with a
  server-side dry run:
    spec.initContainers[0].resources.requests: Invalid value: "4":
    must be less than or equal to cpu limit of 2
  Both `linkerd-init` and `linkerd-proxy` are flagged. To exercise
  min > max you must express the max as `proxy-cpu-ratio-limit`, which
  sets no k8s resources. Task 5's script should refuse the impossible
  combination up front with a clear message rather than letting the API
  server produce this.
- **`num_cpus::get()` is cgroup-aware.** Under `proxy-cpu-limit: 4` the
  proxy sees `available` as 4, not 15. Harmless for c-limit4 since
  min(4,4)=4, but it means `proxy-cpu-limit` changes both the max AND the
  clamp ceiling, another reason to prefer the ratio lever for the sweep.
- **Use `tokio_rt_workers`, not a thread count.** Total threads has a
  non-constant offset: a multi-thread runtime shows `workers + 2` (main
  plus admin), while a current-thread runtime shows 2 threads but 1
  worker, because the single worker is the main thread. Counting threads
  named `proxy` gives the exact worker count in multi-thread mode but
  returns 0 for a single-threaded proxy. The gauge is right in both.
- **The gauge reflects the built runtime, not the env.** A test pod with
  `CORES=1`, `CORES_MIN=1`, `CORES_MAX=4` reported `tokio_rt_workers 4`.
  Reading env vars alone would have given the wrong answer.
- Proxy admin on :4191 serves `/metrics`, `/proxy-log-level`, `/live`,
  `/ready`, and `/shutdown` (POST only, not exercised). No task-dump
  endpoint in this build. Companion gauges worth watching during the
  sweep: `tokio_rt_busy_seconds_total`, `tokio_rt_steal_total`,
  `tokio_rt_injection_queue_depth`, `tokio_rt_polls_total`.
- A local checkout exists at `/Users/apoorv/projects/linkerd2-proxy/`,
  useful for future source questions.
- Side effect to clean up: two ephemeral debug containers, `tcdebug` and
  `tcdebug2`, were added to `emojivoto/web-d56d5d959-77jgz`. Both exited 0.
  Ephemeral containers cannot be removed without deleting the pod, so the
  rollout restart in task 3 clears them.

## 5. Script: inject core restrictions

Done. `scripts/set_cores.sh`, 32 lines. Tested for real against
`emojivoto/web`: 4 -> 4 workers on all 3 replicas, 2 -> 2, reset -> 1
with the annotation removed and `resources` `{}` throughout.
One defect found on test and FIXED: with no args it died with
`$1: unbound variable` instead of printing usage. Takes an ABSOLUTE core count and sets
`LINKERD2_PROXY_CORES_MAX` directly via the `proxy-additional-env`
annotation, which is better than all three cpu annotations for this:

    ./scripts/set_cores.sh <namespace> <workload> <cores|reset>
    ./scripts/set_cores.sh emojivoto deploy/web 6

**Fourth lever, found late and now preferred:
`config.linkerd.io/proxy-additional-env`** (`pkg/k8s/labels.go:338`).
Value is a JSON array of corev1.EnvVar. It renders AFTER the cores vars
in `charts/partials/templates/_proxy.tpl:243`, and
`MergeAdditionalEnv`/`mergeEnvByName` (`pkg/inject/inject.go:212-265`)
merge by name with workload annotations overriding namespace ones.
Verified end to end with pod `corestest/c-env6`:
    '[{"name":"LINKERD2_PROXY_CORES_MAX","value":"6"}]'
    -> tokio_rt_workers 6, startup log cores=6, resources {}
Absolute count, no k8s CPU limit, no CPU request, so no CFS throttling
and nothing consumed from node capacity. `proxy-cpu-limit` gives an
absolute count but throttles; `proxy-cpu-ratio-limit` avoids throttling
but only takes a ratio. This lever has neither drawback.
Patch JSON re-verified with a server-side dry run against
`emojivoto/web`; emojivoto unmodified.

A 524-line `set_proxy_cores.sh` was written first and DELETED. The
operation is one `kubectl patch`; the size came from an over-specified
agent prompt (six flags, dry-run, namespace-wide, timeouts, assertions),
not from the task. The findings below were the real deliverable.
A Makefile-target version was also tried and reverted; scripts preferred.

Tested on a throwaway Deployment in `corestest`: 0.4 -> 6 workers,
0.6 -> 9, reset -> 1. I separately re-checked the ratio guard myself:
`2`, `0`, `1.0` and `abc` are all rejected, and the metric path returns 8
for `po/c-max8`.

Known artifact, not a bug: during a rollout the metric line prints one
number per live pod, so the terminating pod's count shows alongside the
new one for ~30s before settling.

Original over-built interface, for the record:

    set_proxy_cores.sh -n <ns> (<workload> | --namespace-wide) <levers>
      --min N    proxy-cpu-request      --ratio F   proxy-cpu-ratio-limit
      --max N    proxy-cpu-limit        --reset     remove all three
      --dry-run  --timeout <d>

- [x] Decide the interface
      Levers are DECLARATIVE, not additive: the levers named on an
      invocation are the complete desired state, so an unnamed lever is
      removed. `--max 2` after `--ratio 0.5` leaves only the limit.
      Without this the readback assertion is meaningless, since a stale
      ratio would survive and the script would still claim success.
- [x] Apply the annotation and roll the affected pods
      Merge patch on `.spec.template.metadata.annotations`, which is the
      only location that reaches the injector (see task 3 findings).
- [x] Read back and print the resulting env, and fail on mismatch
      Also asserts the k8s resources block, not just env: `--max N` must
      produce a proxy cpu limit of N, every other lever must produce none.
      Proven to fire for real: `--namespace-wide --ratio 0.25` applied
      cleanly, read back `<unset>`, and the script exited non-zero.
- [x] Refuse min > max up front
- [x] Validate `--ratio` is strictly between 0 and 1
      `1.0`, `2` and `0` all refused before anything is applied.
- [x] Support reverting to the unset state
- [x] Handle native sidecars
      Proven by negative control: a copy of the script with the
      `.spec.initContainers` branch renamed to a non-existent field failed
      loudly rather than silently reporting nothing was set. The working
      script names its own source on every pod.
- [x] Print the predicted effective worker count
      BUG FOUND AND FIXED during review, see below.

### Findings from task 5

- **Bug in the script's `predict_workers`, found on review and fixed.**
  The no-lever branch predicted `avail` (15) when the proxy actually
  defaults to 1. `--reset` therefore reported "predicted 15 of 15" when
  the true answer is 1. Contradicted directly by `corestest/c-baseline`,
  which has no cores annotations and reports `tokio_rt_workers` 1 on a
  15-CPU node. Fixed to `w = 1`, re-checked against every known-good data
  point: no annotations -> 1, ratio 0.54 -> 8, min 4 + ratio 0.14 -> 4.
  All match measured reality.
- **Independent corroboration of the task 3 upstream finding.** This agent
  hit the namespace-level ratio-limit drop without being told about it,
  and isolated it further: with BOTH `proxy-cpu-limit=1` and
  `proxy-cpu-ratio-limit=0.25` on the same namespace, the pod came back
  carrying only the limit. Two independent agents, two methods, same
  conclusion.
- **A large `--min`/`--max` will not schedule on a busy node.** Default
  RollingUpdate requires the new pod to fit alongside the old one. The
  script times out on `rollout status` and exits non-zero rather than
  hanging. Relevant to the sweep: high core counts need either `Recreate`
  or headroom.
- Script prediction still assumes `avail` is the node's CPU count. Task 4
  established `num_cpus::get()` is cgroup-aware, so under `--max N` the
  proxy sees N. Harmless today because min(N,N)=N, but it means the
  printed "of N available" is the node figure, not the proxy's view.

## 6. Script: mesh the HAProxy ingress controller

Rewritten as `scripts/mesh_haproxy.sh`, 25 lines:
`./scripts/mesh_haproxy.sh <mesh|unmesh>`. Tested for real, both ways.
The first version was 437 lines and was deleted for the same reason as
task 5: the operation is one `helm upgrade`. Its two DECISIONS below were
the real deliverable and are preserved. Passes `bash -n`. The mesh itself
is still UNRUN, because task 8 needs the unmeshed baseline first.

- [x] Decide inject mode: `enabled`, not `ingress`
      The docs do recommend ingress mode for HAProxy
      (linkerd.io/2-edge/tasks/using-ingress/#haproxy), but that advice is
      conditional on configuration this cluster does not have:
      - it requires each Ingress to carry
        `haproxy.org/request-set-header: l5d-dst-override <svc>...`.
        `emojivoto-ingress` has only `haproxy.org/ingress.class`.
      - without that header, ingress mode falls back to Host/`:authority`,
        which through the port-forward is `localhost:8080` and resolves to
        nothing in-cluster.
      - ingress mode requires the controller to strip client-supplied
        `l5d-dst-override` or it is an open relay. Nothing here does.
      - linkerd2#14813 is this exact stack reporting higher CPU and access
        timeouts after switching to ingress mode, with no maintainer fix.
      `--mesh ingress` remains available and warns before acting.
- [x] Decide annotate-Deployment vs Helm values: Helm values
      Key is `controller.podAnnotations`, verified against the real chart
      (`helm show values haproxytech/kubernetes-ingress --version 1.54.1`,
      line 236 under `controller:`). There is a second `podAnnotations`
      under `defaultBackend:` at ~line 706 which is the wrong one.
      Confirmed it renders into `spec.template.metadata.annotations` both
      via `helm template` and a client-side `helm upgrade --dry-run`.
      Chosen over `kubectl annotate` because `--unmesh` then becomes
      `helm upgrade --reset-values`, an exact return to chart default, and
      `helm get values` becomes an authoritative status source.
      Namespace-level annotation was rejected deliberately: the chart ships
      a `crdjob` hook Job in the same namespace that would also get injected.
- [x] Support unmeshing, so the baseline is reproducible
- [x] Static verification
      `bash -n` and `shellcheck -S style` clean. `--status`, all four
      `--dry-run` variants, and the argument error paths run against the
      live cluster. Native-sidecar readiness logic diffed against real
      meshed pods in linkerd-viz and matched exactly.
      I re-ran `bash -n` and `--status` myself: state UNMESHED, 0/2
      sidecars, 2/2 ready, 200. Helm release still revision 1.
- [x] Annotate the haproxy deployment and roll it
      Run for real. Helm revision 1 -> 2 on mesh, 3 on unmesh. Both pods
      came back 2/2 with `linkerd-init` + `linkerd-proxy`.
- [x] Verify pods come up 2/2 and traffic still flows meshed
      100% 2xx, no errors. See the cost below.
- [x] Decide whether this lives in `install_ingress_haproxy.sh` or separately
      Separate. The installer stays value-free as the baseline, so the
      meshed and unmeshed states remain independently reproducible.

### RESULT: meshing HAProxy costs 55% of throughput

Measured through the Docker/NodePort path at c125/30s, both 100% 2xx:

    unmeshed  53.4k RPS   p50 1.75ms   p99  8.48ms
    meshed    23.7k RPS   p50 5.01ms   p99 10.83ms
    delta     -55% RPS    p50 2.9x     p99 +28%

Unmesh recovered the baseline at 52.1k / 1.76ms / 9.01ms, so the drop is
attributable to the sidecar and not to drift.

**The meshed HAProxy proxies came up at `tokio_rt_workers` 1.** A single
worker thread was carrying all ingress traffic. That is the default, not
a misconfiguration, and it is very likely the cause of most of this drop.
Re-running this with the ingress proxy given more cores is the obvious
next experiment, and is the most direct version of the original question.
It is also the same shape as linkerd2#14813, the issue originally cited:
a user seeing high CPU and access timeouts on meshed HAProxy ingress.

### Risks recorded from task 6

- **`kubectl port-forward` binds to one pod at connect time and does not
  follow a rollout.** Meshing replaces both haproxy pods, so the existing
  port-forward on :8080 will die mid-run and any health check through it
  will report a false failure. Restart the port-forward as a deliberate
  step after meshing, before concluding anything. This also affects
  tasks 7 and 8.
- Every mesh/unmesh runs the chart's `pre-upgrade` hook Job with
  `backoffLimit: 0`. If it fails, the whole upgrade fails.
- Re-running `scripts/install_ingress_haproxy.sh` does
  `helm upgrade --install` with no values and will silently UNMESH the
  controller. Left as-is on purpose; noted in the script's `--help`.
- `--unmesh` uses `--reset-values`, which discards any values set on the
  release later, by design.

## 7. Load generator outside the cluster

Done. `scripts/load_test_docker.sh`, 12 lines.

    ./scripts/load_test_docker.sh [CONNECTIONS] [DURATION] [URL]
    defaults: 125 30s http://172.18.0.2:31605/

- [x] Choose the path
      A plain Docker container on the `kind` network hitting the NodePort:
      `docker run --rm --network kind alpine/bombardier ... http://172.18.0.2:31605/`
      Outside Kubernetes, and bypasses `kubectl port-forward` entirely.
- [x] Confirm the generator is not itself the limit
      It burns ~1.6 of the VM's 15 cores. Going c125 -> c250 held
      throughput flat while doubling p50 and p99, which is downstream
      queueing, not generator starvation.
- [x] Note on the earlier failed pod
      `alpine/bombardier` is fine as a Docker container: it is native
      linux/arm64 and its entrypoint is already `bombardier`. The earlier
      RunContainerError came from the `sleep infinity` override, not the
      image.

## 8. Determine what actually caps throughput today

Done, unmeshed HAProxy, emojivoto at 1 proxy worker. All runs 30s,
100% 2xx, zero errors.

- [x] Attribute the ceiling. **`kubectl port-forward` was a real
      bottleneck: 23.1k -> 53.4k RPS, 2.3x, at identical settings.**
        docker/NodePort c50  : 40.9k RPS, p50 0.99ms, p99  4.27ms
        docker/NodePort c125 : 53.4k RPS, p50 1.75ms, p99  8.48ms
                               (repeat: 48.9k, p50 1.87ms, p99 9.48ms)
        docker/NodePort c250 : 53.7k RPS, p50 3.27ms, p99 17.39ms
        host/port-forward c125: 23.1k RPS, p50 4.75ms, p99 16.10ms
      The agent's 23.1k reproduces the earlier suspect 23.7k, so that
      measurement was sound; it was just measuring kubectl.
      The knee is between c50 and c125.
- [x] Record the unmeshed-haproxy baseline. The c125 figures above ARE it.
- [x] CPU during the c125 run
        node container    ~955-990% of 1500%  (~65%)
        web-svc app       151-154% each x3    (~460%)
        haproxy           126-132% each x2    (~258%)
        linkerd-proxy      ~72% each x3       (~216%)
        load generator     157%
        node-wide: 46% us, 16.5% sy, 11.9% softirq, 25% idle, load avg 14.4
- [ ] OPEN: no single component is pegged, so the ~53.5k ceiling is not
      attributed. Reads as aggregate scheduling contention on the one
      15-CPU Docker Desktop VM shared by generator and cluster, but 25%
      idle remained while throughput was flat, which contention alone does
      not explain. Settling it needs the generator on a separate machine,
      i.e. task 10.
      NOTE: the proxies' single worker threads are the highest-utilised
      individual threads in the system at 58-67% of a core each. 1 worker
      is not yet the cap but is the nearest thing to one.

## 9. Run the cores experiment

Blocked on Q1 and Q4.

- [ ] Choose and apply the annotation scope
- [ ] Sweep cores and record RPS and latency at each value
- [ ] Record where the proxy stops scaling

## 10. Move the cluster to an SSH-reachable VM

Not started. Current cluster is kind on this laptop.

- [ ] Decide the target: cloud VM, which provider, what size
- [ ] Decide whether to keep kind or use a real distro on the VM
      15 CPUs and 8GB on one node is the current shape. Matching or
      exceeding that matters for result comparability.
- [ ] Decide how the load generator reaches it: SSH tunnel, private
      network, or public endpoint
- [ ] Make the install scripts work unchanged on the VM

## 11. Expose the VM to the public internet

Not started. Flagging up front: emojivoto has no authentication, and a
public ingress will be scanned within minutes of going up.

- [ ] Decide what actually needs to be public and why
      If the load generator is the only external client, an IP allowlist or
      SSH tunnel gives the same result without a public endpoint.
- [ ] If public: restrict by source IP at the cloud firewall
- [ ] If public: decide TLS, and whether HAProxy terminates it
- [ ] Make sure the k8s API server is not exposed alongside the ingress
- [ ] Plan teardown, so it does not outlive the test

## 12. Session setup: checklist workflow rules

- [x] Add checklist-driven workflow rules to `~/.claude/CLAUDE.md`
      Added as `## Checklist-driven sessions` under the existing
      `# Workflow` section. Backup of the original is in the session
      scratchpad as `CLAUDE.md.bak`.
- [x] Create this checklist
- [x] Restructure to `## Tasks` at top with a section per task, and
      update the format rules in `~/.claude/CLAUDE.md` to match

## 13. Verify the cores cap actually bounds CPU

NOT STARTED. This is the gap behind "how do we know CPU is not exceeded".
Everything proven so far is THREAD COUNT (`tokio_rt_workers`), measured on
idle pods carrying no traffic. Nothing yet shows a CPU bound.

**`LINKERD2_PROXY_CORES_MAX` caps worker threads, not CPU.** With no
cgroup limit nothing enforces a CPU ceiling: N workers bound worker time
at N cores, but the proxy also runs a main thread, an admin thread, and a
blocking pool sized `max_blocking_threads(cores)`. Total process CPU can
therefore exceed N. Only `config.linkerd.io/proxy-cpu-limit` sets a real
cgroup quota and hard-caps CPU. That reverses the earlier preference: if
the goal is "Linkerd must not exceed N cores", CFS throttling is the
enforcement mechanism, not a drawback.

### Where to see the metrics

All of these are already scraped by the linkerd-viz Prometheus, confirmed
by query (22 series each, one per meshed proxy). Grafana is already wired
to that Prometheus.

    kubectl port-forward -n linkerd-viz svc/prometheus 19090:9090

- `tokio_rt_workers` — worker thread count. Labels include `namespace`,
  `pod`, `deployment`, so per-pod filtering works. All six `corestest`
  pods are visible with correct values.
- `tokio_rt_busy_seconds_total` — cumulative worker busy time. Its rate
  is worker CPU in cores. Same labels.
- `process_cpu_seconds_total` — total proxy process CPU, `job="linkerd-proxy"`.
  CAVEAT: this series carries only `__name__`, `instance`, `job`. No pod
  label, so per-pod attribution needs mapping `instance` (pod IP:4191)
  back to a pod.

Per-pod without Prometheus:

    linkerd diagnostics proxy-metrics -n <ns> <workload> \
      | grep -E '^(tokio_rt_workers|tokio_rt_busy_seconds_total|process_cpu_seconds_total)'

`kubectl top` is NOT available: metrics-server is not installed
("Metrics API not available").

### Methodology

- [ ] 1. Set `emojivoto/web` to `CORES_MAX=N` via `set_cores.sh`, N small
      enough to be reachable under load (2 or 4). Confirm `tokio_rt_workers`
      reads N on all 3 replicas before generating any load.
- [ ] 2. Drive load with `scripts/load_test_docker.sh` at the c125 shape,
      so results are comparable to the task 8 baseline.
- [ ] 3. Measure WORKER CPU, in cores:
        rate(tokio_rt_busy_seconds_total{namespace="emojivoto",pod=~"web-.*"}[1m])
      Expect it to plateau at <= N as offered load increases. If it exceeds
      N, the thread cap is not doing what we think.
- [ ] 4. Measure TOTAL proxy process CPU:
        rate(process_cpu_seconds_total{job="linkerd-proxy"}[1m])
      joined back to the web pods by instance IP. The GAP between this and
      step 3 is the non-worker overhead that `CORES_MAX` does not bound.
      Quantifying that gap is the actual deliverable of this task.
- [ ] 5. Sweep offered load upward until worker CPU stops rising, to show
      the plateau is a cap and not just an artifact of insufficient load.
- [ ] 6. Repeat steps 1-4 with `config.linkerd.io/proxy-cpu-limit: N`
      instead. Confirm total CPU is hard-capped at N, and read
      `cpu.stat` from the node for the direct evidence of enforcement:
        docker exec kind-control-plane \
          cat /sys/fs/cgroup/kubepods.slice/.../cpu.stat
      Non-zero `nr_throttled` / `throttled_usec` is the proof that the
      cgroup quota, not the thread count, is what bounds CPU.
- [ ] 7. State plainly which lever gives a soft bound and which gives a
      hard one, with the measured numbers behind each.

### Controls

- Compare against `corestest/c-baseline` (1 worker) and `c-env6`
  (6 workers) as idle references, to separate load-driven CPU from
  baseline process CPU.
- Re-run the task 8 c125 baseline unchanged at the end, to confirm the
  cluster has not drifted between measurements.

## Context: environment as found

- Cluster: `kind-kind`, single node `kind-control-plane`, 15 CPUs, 8GB RAM,
  k8s v1.37.0, arm64.
- Linkerd: client `enterprise-2.20.2`, server `edge-26.9.2`,
  proxy `cr.l5d.io/linkerd/proxy:edge-26.9.2` (proxy `v2.368.0`).
- Control plane is **not** under Helm. `helm list -A` shows only grafana,
  haproxy-ingress and my-headlamp.
- Proxies run as **native sidecars**: init containers with
  `restartPolicy: Always`, not regular containers.
- emojivoto: `web` x3, plus emoji, voting, vote-bot. All meshed (2/2).
  Current proxy env is `CORES=1`, `CORES_MIN=1`, no max, no limits.
- HAProxy ingress: 2 replicas in `haproxy-controller`, unmeshed (1/1),
  NodePort 31605 -> 80.
- Scripts, all under `scripts/`: `install_ingress_haproxy.sh`,
  `load_test.sh`, `load_test_docker.sh`, `mesh_haproxy.sh`,
  `set_cores.sh`. `apply-grafana.sh` and `Makefile` remain at the root.
- Local chart copy `linkerd-enterprise-control-plane/` is BEL 2.20.2 and
  does support `proxy.runtime.workers.*`. It is not what is installed.

## Open questions

- **Q1 Goal.** Verify the setting works, build a cores-vs-throughput curve,
  find the cluster's ceiling, or reproduce a specific symptom? Blocks task 9.
- **Q2 Load generator.** ANSWERED: outside the cluster.
- **Q3 HAProxy order.** Mesh it now, or take an unmeshed baseline first?
  Baseline first gives an attributable cost for the ingress proxy.
  Blocks the ordering of tasks 6 and 8.
- **Q4 Cores scope.** emojivoto `web` only, haproxy once meshed, or
  cluster-wide? Namespace-wide is now RULED OUT for the ratio lever: task
  3 proved namespace-level `proxy-cpu-ratio-limit` is silently dropped
  upstream. Blocks tasks 5 and 9.
- **Q5 New.** Report the namespace-propagation omission upstream to
  linkerd/linkerd2? It is a one-line fix (add
  `ProxyCPURatioLimitAnnotation` to the `ProxyAnnotations` list) and
  reproduces at HEAD. Out of scope for this checklist unless you want it.
