# Load test Linkerd: emojivoto via HAProxy ingress

Goal: load test Linkerd in the local kind cluster, driving emojivoto/web
through the HAProxy ingress controller, with proxy max cores configurable.

## Tasks

- [x] T1. Establish how max proxy cores is configured
- [x] T2. Establish how the proxy interprets the cores values
- [ ] T3. Determine what actually caps throughput today
- [ ] T4. Stand up the load generator
- [ ] T5. Mesh the HAProxy ingress controller
- [ ] T6. Run the cores experiment
- [x] T7. Session setup: checklist workflow rules

## T1. Establish how max proxy cores is configured

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

## T2. Establish how the proxy interprets the cores values

- [x] Read the precedence rules from proxy source
      From `linkerd/workers/src/lib.rs`:
      - `CORES_MAX` is an absolute thread count, and beats `CORES_MAX_RATIO`
      - `CORES_MIN` clamps upward, so min wins when min > max
      - result is clamped down by `num_cpus::get()`, so >15 is a no-op here
      - if the result is 1 the proxy builds a current-thread runtime,
        otherwise a multi-thread runtime
- [ ] Verify `CORES_MAX` changes the proxy's real thread count at runtime
      Only env var presence is proven so far. Actual thread count is not.
      Not blocked on any open question.

## T3. Determine what actually caps throughput today

- [ ] Attribute the current ceiling
      One unattributed data point: 23.7k RPS, 4.8ms p50, 13.6ms p99, all
      2xx, over 10s at 125 connections through `kubectl port-forward`.
      Could be the port-forward, the mesh, or emojivoto itself.
- [ ] Compare against a path that bypasses `kubectl port-forward`
      Depends on T4.

## T4. Stand up the load generator

Blocked on Q2.

- [ ] Choose the topology
- [ ] Deploy it
- [ ] Confirm it can saturate something before it saturates itself

## T5. Mesh the HAProxy ingress controller

Blocked on Q3. HAProxy is currently unmeshed (1/1), 2 replicas.

- [ ] Record the unmeshed baseline first, if that is the chosen order
- [ ] Inject haproxy
- [ ] Re-measure and record the delta attributable to the ingress proxy

## T6. Run the cores experiment

Blocked on Q1 and Q4.

- [ ] Choose and apply the annotation scope
- [ ] Sweep cores and record RPS and latency at each value
- [ ] Record where the proxy stops scaling

## T7. Session setup: checklist workflow rules

- [x] Add checklist-driven workflow rules to `~/.claude/CLAUDE.md`
      Added as `## Checklist-driven sessions` under the existing
      `# Workflow` section. Backup of the original is in the session
      scratchpad as `CLAUDE.md.bak`.
- [x] Create this checklist

## Context: environment as found

- Cluster: `kind-kind`, single node `kind-control-plane`, 15 CPUs, 8GB RAM,
  k8s v1.37.0, arm64.
- Linkerd: client `enterprise-2.20.2`, server `edge-26.9.2`,
  proxy `cr.l5d.io/linkerd/proxy:edge-26.9.2` (proxy `v2.368.0`).
- Control plane is **not** under Helm. `helm list -A` shows only grafana,
  haproxy-ingress and my-headlamp. Cluster-wide Helm values would require
  a reinstall.
- Proxies run as **native sidecars**: init containers with
  `restartPolicy: Always`, not regular containers.
- emojivoto: `web` x3, plus emoji, voting, vote-bot. All meshed (2/2).
  Current proxy env is `CORES=1`, `CORES_MIN=1`, no max, no limits.
- HAProxy ingress: 2 replicas in `haproxy-controller`, unmeshed (1/1),
  NodePort 31605 -> 80.
- Local chart copy `linkerd-enterprise-control-plane/` is BEL 2.20.2 and
  does support `proxy.runtime.workers.*`. It is not what is installed.

## Open questions

- **Q1 Goal.** Verify the setting works, build a cores-vs-throughput curve,
  find the cluster's ceiling, or reproduce a specific symptom? This decides
  whether Q2 through Q4 need answering at all. Blocks T6.
- **Q2 Load generator.** In-cluster pod, a container on the `kind` docker
  network hitting NodePort 31605, or keep the host `kubectl port-forward`?
  In-cluster removes the port-forward but competes for the same 15 cores.
  Blocks T4.
- **Q3 HAProxy.** Mesh it now, or take an unmeshed baseline first? Baseline
  first gives an attributable cost for the ingress proxy. Blocks T5.
- **Q4 Cores scope.** emojivoto `web` only, haproxy once meshed,
  namespace-wide, or cluster-wide? Cluster-wide means reinstalling the
  control plane, since it is not under Helm. Blocks T6.
