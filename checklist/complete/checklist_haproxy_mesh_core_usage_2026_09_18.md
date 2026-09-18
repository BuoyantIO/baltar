# HAProxy ingress proxy: does more load cross the CORES_MAX cap

Goal: find out whether the haproxy ingress's Linkerd proxy CPU can be
pushed past the 200%-of-one-core ceiling task 20 measured, either with
a higher cap or with more real concurrent connections.

Both experiments use an unmesh -> mesh toggle mid-run, the same shape
as `checklist_mvp.md` tasks 17/19/20: sampler and load both start while
haproxy is unmeshed, so there is a clean unmeshed baseline; haproxy is
meshed with the target `CORES_MAX` partway through; load keeps running
long enough afterward to get a settled meshed window. This gives more
data per run than measuring only the already-meshed steady state:
an unmeshed baseline, the transition itself, and the meshed plateau,
all on one CPU timeline.

## Hypothesis

- **Raising to 3 cores (task 2).** Expect the proxy CAN cross 200% once
  it has 3 cores to use, the same way task 23 of
  `checklist_repro_kube_setup.md` found 206-209% mean and peaks to 218%
  under a raw connection sweep at `CORES_MAX=3`. If it instead stays
  near task 20's 161%/169% even with the cap raised, that says this
  particular load (1 replica, 1000 connections) genuinely cannot demand
  more than ~161% regardless of the cap, matching task 20's own
  conclusion that the ceiling is a throughput problem, not a
  concurrency one.
- **Two terminals at 1000 connections each (task 3), back at
  `CORES_MAX=2`.** Expect this CAN push closer to or above 200%, because
  two independent OS processes generate real additional concurrent
  connections, unlike raising one process's `-c` flag, which task 20
  showed just queues without adding demand. If CPU still does not cross
  200% here either, that rules out connection concurrency as the
  missing ingredient and leaves throughput (bytes/requests actually
  served) as the only remaining lever.

## Tasks

- [x] 1. Confirm the cluster is in the pre-toggle state
- [x] 2. Mesh-toggle test at CORES_MAX=3, one load generator
- [x] 3. Mesh-toggle test at CORES_MAX=2, two load generators
- [ ] 4. Record the net state change — moot, cluster being deleted

## Context

- kind cluster, node `kind-control-plane`, 15 CPUs, arm64, k8s v1.37.0.
- All scripts referenced below live in `scripts/`, run from the repo root.
- haproxy ingress: Helm release `haproxy-ingress`, namespace
  `haproxy-controller`, Deployment `haproxy-ingress-kubernetes-ingress`,
  NodePort pinned at 31080.
- emojivoto: namespace `emojivoto`, deployments `web`, `emoji`, `voting`,
  `vote-bot`. Stays at 5 replicas each (0 for `vote-bot`), meshed,
  `CORES_MAX=3`, for both tasks 2 and 3; not touched by either.
- CPU sampler: `dev_5_measure_start.sh <run-name> <namespace> <workload>`
  starts a 1Hz collector against one workload — it reads cgroup CPU
  directly, so it measures whether the workload is meshed or not, and
  keeps sampling straight through a mesh toggle. `dev_6_measure_stop.sh`
  (no args) stops it and writes `~/.cache/kube-cpu-sampler/<run-name>.csv`.
  A run name cannot be reused. Only one sampler can run in the cluster
  at a time. `RESOLVE_INTERVAL=2` (task 17's setting) re-resolves pods
  every 2s instead of the 5s default, so the roll is caught sharply
  against our shorter, ~100s runs.
- Load generator: `test_load_2_docker_nodeport.sh [CONNECTIONS] [DURATION] [URL]`
  runs `alpine/bombardier` as a plain Docker container on the `kind`
  network. Running it twice at once from two terminals is two
  independent processes hitting the same NodePort — this is what task 3
  uses to get real concurrent connections rather than a single
  process's `-c` flag.
- Mesh+cores toggle: `dev_2_mesh_haproxy.sh mesh <CORES>` now takes an
  optional `CORES` argument (added for this checklist) and sets the
  inject annotation and the `CORES_MAX` pin in one rollout, internally
  through a values file for the same reason task 17 needed one
  (`--set` can't cleanly carry the annotation's JSON-string value).
  One call, one rollout, instead of `dev_2` then `dev_3` separately.
- Timing budget, per the user's spec: run the load for at least 90s —
  30s unmeshed baseline, the toggle (assumed ~30s), 30s settled meshed.
  Actual handover took 13-40s across tasks 17/19/20 (faster with fewer
  replicas), so both tasks below run the load for **100s**, firing the
  toggle at t=30s, to keep a real settled meshed window even if the
  rollout takes the full 40s seen before. If it finishes faster, the
  meshed window is just longer than 30s, not shorter.
- Baseline to compare against, from `checklist_mvp.md` task 20, 1
  haproxy replica, `CORES_MAX=2`, 1000 connections/150s, one terminal,
  already-meshed steady state: proxy CPU mean 161.0%, peak 169.0%, zero
  rows above 200%; 15,079 rps.

## 1. Confirm the cluster is in the pre-toggle state

Both tasks 2 and 3 need to start from haproxy **unmeshed**, so the run
captures a real unmeshed baseline before its own toggle. This task gets
the cluster there once, so task 3 (which runs after task 2 has already
meshed haproxy) knows to redo it.

Preconditions: `kubectl cluster-info` succeeds; `helm list -n
haproxy-controller` shows the `haproxy-ingress` release deployed.

Commands:

    cd scripts
    kubectl get deploy -n haproxy-controller haproxy-ingress-kubernetes-ingress \
      -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas'
    kubectl get deploy -n emojivoto \
      -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas'
    kubectl get deploy -n haproxy-controller haproxy-ingress-kubernetes-ingress \
      -o jsonpath='{.spec.template.spec.initContainers[*].name}{"\n"}'
    ./dev_4_inspect_cores.sh emojivoto deploy/web

Done when the `initContainers` check above prints nothing and
`dev_4_inspect_cores.sh emojivoto deploy/web` shows the expected
emojivoto state.

### Result

- **Haproxy**: 1/1 replica, unmeshed (no `linkerd-proxy` in initContainers)
- **NodePort**: 31080
- **Emojivoto**: web/emoji/voting 5/5, vote-bot 0/0
- **Emojivoto proxy cores**: `LINKERD2_PROXY_CORES_MAX=3`

## 2. Mesh-toggle test at CORES_MAX=3, one load generator

**Problem.** Task 23 of `checklist_repro_kube_setup.md` showed that at
`CORES_MAX=3` a proxy under high raw load *can* cross 200% (206-209%
mean, peaks to 218%). Task 20 never crossed 200% at `CORES_MAX=2`, 1000
connections, one haproxy replica. This checks whether that same 1000
connection load, against the same one replica, crosses 200% once the
cap is raised to 3 cores mid-run — i.e. whether the proxy actually has
more than 200% of demand once it's allowed to use it. Run this
experiment first, since task 3 needs the cap back at 2 to be a fair
test of its own question.

Precondition: task 1's unmeshed state.

Derive the target URL:

    NODE_IP=$(kubectl get node kind-control-plane \
      -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    NODE_PORT=$(kubectl get svc -n haproxy-controller haproxy-ingress-kubernetes-ingress \
      -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
    URL="http://${NODE_IP}:${NODE_PORT}/api/list"

Four terminals:

    # terminal A — start the sampler first, before any load, while still unmeshed
    cd scripts
    RESOLVE_INTERVAL=2 ./dev_5_measure_start.sh toggle-3core haproxy-controller \
      deploy/haproxy-ingress-kubernetes-ingress

    # terminal B — start the load; runs 100s total
    cd scripts
    ./test_load_2_docker_nodeport.sh 1000 120s "$URL"

    # terminal C — wait 30s after B started, then fire the toggle
    sleep 30
    cd scripts
    ./dev_2_mesh_haproxy.sh mesh 3

    # terminal D — only after B's bombardier summary prints and C's rollout is done
    cd scripts
    ./dev_6_measure_stop.sh

Do not scale replicas or touch emojivoto's pin during this run.

Verification: `dev_6_measure_stop.sh` prints the CSV path
(`~/.cache/kube-cpu-sampler/toggle-3core.csv`). It carries `mesh=unmeshed`
rows before the toggle and `mesh=meshed` rows after, with a `roll`
event marking the transition. Split the analysis in two, same method
tasks 17/19/20 used:

    awk -F, 'NR==1 || ($5=="linkerd-proxy" || $5=="kubernetes-ingress-controller")' \
      ~/.cache/kube-cpu-sampler/toggle-3core.csv

- unmeshed steady window (before the `roll` row): controller container
  CPU only, no `linkerd-proxy` rows exist yet.
- meshed steady window (after the new pod's ramp settles, skip its
  first ~5 ticks): `linkerd-proxy` container `cpu_pct_core`, mean and
  peak. Record whether any row exceeds 200%.

Also record the run's rps/latency/error counts from terminal B's
bombardier summary (compare against task 20's 15,079 rps, p50 54.31ms
— note this run's total includes an unmeshed segment, so its aggregate
rps is not directly comparable to task 20's all-meshed 150s number;
only the meshed-window CPU and the meshed-window rps, if computed
separately, are).

### Result

First attempt (100s load) gave only a 10-second burst, not a plateau,
because the traffic cutover took far longer than the load ran — see
Q1 below. **Re-run at 2026-09-18 with 120s of load**, same CSV
(`~/.cache/kube-cpu-sampler/toggle-3core.csv`, overwritten, 241 rows,
one `roll` event), which caught a real steady state:

- **Unmeshed baseline** (old pod's `kubernetes-ingress-controller`,
  t_s 0-87): steady around 129-138% in the window right before
  cutover (overall mean 121.0%, pulled down by the run's early ramp).
- **Traffic cutover again lagged pod creation by ~40s**: the new
  (meshed) pod was created at t_s=47-49, but its proxy and app
  containers sat at ~0% through t_s=87, while the old pod kept
  absorbing full load. At t_s=88 it flips: old pod drops to ~0, new
  proxy jumps 151.7% -> 210.8% and climbs into a stable band by ~t_s=95.
- **Steady meshed window (t_s 95-125, 32 samples, well clear of the
  ramp): proxy mean 212.9%, peak 230.2%.** 36 of 76 total proxy
  samples exceeded 200%, sustained for 30+ seconds — a real plateau,
  not a burst. **200% WAS exceeded, decisively.** Slightly above task
  23's raw connection-sweep finding (206-209% mean, 218% peak) at the
  same `CORES_MAX=3`.
- App container in the same steady window: mean 78.9%, peak 85.5% —
  roughly half its unmeshed draw, the same "proxy takes over, app CPU
  drops" pattern tasks 17/19/20 found.
- **Bombardier**: 18,783.73 rps avg over 120s, 2,252,491 2xx, zero
  4xx/5xx, 981 connection-refused (during the roll, as in every prior
  toggle run), p50 45.15ms, p99 167.5ms, max 2.10s, 84.63MB/s. Total
  requests match the stated rps × 120s, so the full run completed as
  intended.
- **Net state after this task**: haproxy meshed, `CORES_MAX=3`, 1
  replica (feeds into task 3, which reverts to `CORES_MAX=2`).

See Q1 below: the ~40s pod-ready-to-traffic-cutover gap recurred in
both the 100s and 120s runs. It didn't block this result (the 120s
run ran long enough to get a clean plateau anyway), but it is right at
the edge of what task 3's 100s timing budget assumes.

## 3. Mesh-toggle test at CORES_MAX=2, two load generators

**Problem.** Task 20 found the ingress proxy peaked at 169% of its
200% (`CORES_MAX=2`) budget even at 1000 connections from one
`bombardier` process, and concluded throughput, not connection count,
was the ceiling. This checks whether two independent generator
processes — real concurrent connections from two OS processes, each at
1000 connections (2000 total), not one process's `-c` flag — push the
proxy any closer to, or past, 200%.

Precondition: haproxy unmeshed again. Task 2 leaves it meshed at
`CORES_MAX=3`, so redo task 1's unmesh step first:

    cd scripts
    ./dev_2_mesh_haproxy.sh unmesh
    kubectl get deploy -n haproxy-controller haproxy-ingress-kubernetes-ingress \
      -o jsonpath='{.spec.template.spec.initContainers[*].name}{"\n"}'
    # must print nothing

Derive the target URL once and reuse it in both load terminals:

    NODE_IP=$(kubectl get node kind-control-plane \
      -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    NODE_PORT=$(kubectl get svc -n haproxy-controller haproxy-ingress-kubernetes-ingress \
      -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
    URL="http://${NODE_IP}:${NODE_PORT}/api/list"
    echo "$URL"

Five terminals:

    # terminal A — start the sampler first, while still unmeshed
    cd scripts
    RESOLVE_INTERVAL=2 ./dev_5_measure_start.sh toggle-2core-2term haproxy-controller \
      deploy/haproxy-ingress-kubernetes-ingress

    # terminal B — first load generator, 100s
    cd scripts
    ./test_load_2_docker_nodeport.sh 1000 120s "$URL"

    # terminal C — second load generator, started alongside B, also 100s
    cd scripts
    ./test_load_2_docker_nodeport.sh 1000 120s "$URL"

    # terminal D — wait 30s after B/C started, then fire the toggle
    sleep 30
    cd scripts
    ./dev_2_mesh_haproxy.sh mesh 2

    # terminal E — only after B and C's bombardier summaries print and D's rollout is done
    cd scripts
    ./dev_6_measure_stop.sh

Do not run any other mesh/scale command while the sampler or either
load run is active.

Verification: same method as task 2, against
`~/.cache/kube-cpu-sampler/toggle-2core-2term.csv`. Record the unmeshed
baseline, the meshed mean/peak proxy CPU, and whether 200% was
exceeded. Combined throughput in each window is the two generators'
rps added together, since they hit the same backend at once.

### Result

Run at 2026-09-18, 120s per generator, CSV
`~/.cache/kube-cpu-sampler/toggle-2core-2term.csv`, 245 rows, one
`roll` event.

- **Unmeshed baseline is much higher than the single-generator
  baseline.** Steady window t_s 9-57 (n=47), old pod's
  `kubernetes-ingress-controller`: **mean 203.88%, peak 220.19%** — well
  above task 20's single-generator 128.8%/149.3%. Two terminals really
  did generate more demand than one process's `-c` flag would; this
  container isn't `CORES_MAX`-capped, so it was free to show it.
- **Cutover was fast this time**: new pod created t_s=44, real traffic
  ramp by t_s=57-58 (~13s gap) — nothing like task 2's ~40s lag.
- **Steady meshed window (t_s 59-125, 65 samples, ~66s plateau): proxy
  mean 168.1%, peak 178.45%. Zero rows exceeded 200%.** Higher than
  task 20's single-generator peak (169.0% -> 178.45%) but still clearly
  under the cap, and below task 2's `CORES_MAX=3` result (212.9%
  mean/230.2% peak) as expected since the cap itself is lower here.
- App container in the same window: mean 75.1%, peak 86.7% — again
  roughly a third to half its unmeshed draw.
- **The two generators did not hit the same URL.** One terminal's
  bombardier summary shows it querying `/` (15,641.04 rps avg,
  1,875,919 2xx, 1,014 connection-refused, 10.82MB/s); the other shows
  `/api/list` (7,627.54 rps avg, 914,826 2xx, 965 connection-refused,
  34.31MB/s — higher byte throughput despite fewer requests, consistent
  with `/api/list`'s larger response body). Combined: ~23,268 rps avg,
  2,790,745 total 2xx, 0 4xx/5xx, 1,979 connection-refused. Likely
  cause: `$URL` was derived in one terminal and not re-exported into
  the other, so that terminal's `test_load_2_docker_nodeport.sh` fell
  back to its own default (`/`) when it received an empty third
  argument. This is a real methodological gap — task 3 wasn't a clean
  2x replication of one endpoint — but it doesn't undermine the CPU
  conclusion: it still produced substantial combined concurrent demand
  (confirmed by the unmeshed controller's 220% peak), and the proxy
  still stayed under 200% against it.
- **Answer to the hypothesis: no, still didn't cross 200%.** Even with
  real concurrent demand pegging the unmeshed controller at ~204-220%,
  the `CORES_MAX=2` proxy topped out at 178.45%. This rules out
  connection concurrency as the missing ingredient and leaves
  throughput/demand actually reaching the proxy as the remaining
  explanation, matching task 20's original conclusion.
- **Net state after this task**: haproxy meshed, `CORES_MAX=2`, 1
  replica — matches task 20's original end state.

## 4. Record the net state change

Whatever tasks 2 and 3 leave running matters for the next session, the
same way task 17 recorded its net change instead of restoring.

Command to check the live state after both experiments:

    cd scripts
    kubectl get deploy -n haproxy-controller haproxy-ingress-kubernetes-ingress \
      -o jsonpath='{.spec.template.spec.initContainers[*].name}{"\n"}'
    kubectl get deploy -n haproxy-controller haproxy-ingress-kubernetes-ingress \
      -o jsonpath='{.spec.template.metadata.annotations.config\.linkerd\.io/proxy-additional-env}{"\n"}'
    kubectl get deploy -n haproxy-controller haproxy-ingress-kubernetes-ingress \
      -o custom-columns='READY:.status.readyReplicas,DESIRED:.spec.replicas'

Write the actual meshed/unmeshed state, `CORES_MAX` value and replica
count here. Expected: haproxy ends meshed at `CORES_MAX=2` (task 3's
toggle), 1 replica — matching task 20's original end state — unless
task 3 was skipped or failed after task 2.

### Result

**Blocked, deliberately not done**: the cluster is being deleted, so
there is no next session for this state to matter to. Both
experiments already answered what they set out to answer (see tasks
2 and 3's Results above); recording the final live state would have
no reader.

## Open questions

- **Q1 Why does traffic cutover lag pod creation by ~40s?** Seen in
  both of task 2's runs: the new pod is created and its containers are
  running (per the CSV) well before the old pod's CPU drops to zero,
  during which the new pod sits at ~0% doing nothing. First run:
  pod created t_s=77, cutover t_s=116 (~39s). Second run: pod created
  t_s=47-49, cutover t_s=88 (~40s). Tasks 17/19/20 saw 13-40s
  handovers measured the same way, so 40s is within precedent, but at
  the edge of it, and task 3's 100s load budget (30s pre-toggle + an
  assumed ~30s transition + 30s settled) only has headroom for this if
  the transition stays under ~40s. If task 3 sees a longer gap, its
  100s run may repeat task 2's first attempt (a burst instead of a
  plateau) — consider running task 3 for 120s instead of 100s from the
  start, given this task's own experience.
