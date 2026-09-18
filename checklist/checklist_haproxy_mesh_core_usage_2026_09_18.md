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

- [ ] 1. Confirm the cluster is in the pre-toggle state
- [ ] 2. Mesh-toggle test at CORES_MAX=3, one load generator
- [ ] 3. Mesh-toggle test at CORES_MAX=2, two load generators
- [ ] 4. Record the net state change

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
- Mesh+cores toggle: one `helm upgrade --reset-values -f <values file>`
  sets the inject annotation and the `CORES_MAX` pin in a single
  rollout, the same pattern task 17 used (`haproxy_mesh_2cores.yaml`).
  Doing it in one upgrade, not `dev_2` then `dev_3` separately, avoids
  two rollouts and keeps one clean step in the CSV.
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

Expected: haproxy 1/1 replica; the `initContainers` line is **empty**
(no `linkerd-proxy`), i.e. unmeshed. emojivoto web/emoji/voting 5/5,
`vote-bot` 0/0 (its Deployment still exists at 0 replicas), web proxy
`LINKERD2_PROXY_CORES_MAX=3`.

If haproxy is currently meshed (e.g. left over from a previous run of
task 2 or 3), unmesh it:

    ./dev_2_mesh_haproxy.sh unmesh

If its replica count is wrong:

    ./dev_7_scale_workloads.sh 5 1
    VOTE_BOT_REPLICAS=0 ./dev_7_scale_workloads.sh 5 1

Do not touch emojivoto's core pin (must stay `CORES_MAX=3`) and do not
run more than one fix-up command at once, since each triggers its own
rollout.

Done when the `initContainers` check above prints nothing and
`dev_4_inspect_cores.sh emojivoto deploy/web` shows the expected
emojivoto state.

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

Write the values file that meshes haproxy at `CORES_MAX=3` in one
upgrade:

    cd scripts
    cat > mesh_3cores.yaml <<'EOF'
    controller:
      podAnnotations:
        linkerd.io/inject: enabled
        config.linkerd.io/proxy-additional-env: '[{"name":"LINKERD2_PROXY_CORES_MAX","value":"3"}]'
      service:
        nodePorts:
          http: 31080
      replicaCount: 1
    EOF

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
    ./test_load_2_docker_nodeport.sh 1000 100s "$URL"

    # terminal C — wait 30s after B started, then fire the toggle
    sleep 30
    cd scripts
    helm upgrade haproxy-ingress haproxytech/kubernetes-ingress -n haproxy-controller \
      --reset-values -f mesh_3cores.yaml
    kubectl rollout status deploy/haproxy-ingress-kubernetes-ingress -n haproxy-controller --timeout=180s

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

_(fill in after running: unmeshed baseline CPU, mean/peak meshed proxy
CPU, whether 200% was exceeded, and throughput in each window)_

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

Write the values file that meshes haproxy at `CORES_MAX=2`:

    cat > mesh_2cores.yaml <<'EOF'
    controller:
      podAnnotations:
        linkerd.io/inject: enabled
        config.linkerd.io/proxy-additional-env: '[{"name":"LINKERD2_PROXY_CORES_MAX","value":"2"}]'
      service:
        nodePorts:
          http: 31080
      replicaCount: 1
    EOF

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
    ./test_load_2_docker_nodeport.sh 1000 100s "$URL"

    # terminal C — second load generator, started alongside B, also 100s
    cd scripts
    ./test_load_2_docker_nodeport.sh 1000 100s "$URL"

    # terminal D — wait 30s after B/C started, then fire the toggle
    sleep 30
    cd scripts
    helm upgrade haproxy-ingress haproxytech/kubernetes-ingress -n haproxy-controller \
      --reset-values -f mesh_2cores.yaml
    kubectl rollout status deploy/haproxy-ingress-kubernetes-ingress -n haproxy-controller --timeout=180s

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

_(fill in after running: unmeshed baseline CPU, mean/peak meshed proxy
CPU, whether 200% was exceeded, combined throughput per window, and how
the meshed CPU compares to task 20's 161.0%/169.0% and to task 2's
result above)_

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

_(fill in: final mesh state, final CORES_MAX, final replica counts, and
which of them differ from task 20's state recorded in Context)_
