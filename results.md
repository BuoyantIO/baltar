# Load test results

Source: `checklist/complete/checklist_load_test_linkerd.md`, `checklist_repro_kube_setup.md`, `checklist_mvp.md`. Tool: `alpine/bombardier` via `scripts/test_load_1_local_tunnel.sh` / `test_load_2_docker_nodeport.sh`. All laptop-only; the VM checklist (`checklist_vm.md`) has never been run.

## Meshing HAProxy

**Problem**: whether adding the Linkerd sidecar to the HAProxy ingress costs throughput or latency.

**Result**: meshing cost 55% of throughput. Unmeshed 53.4k RPS (p50 1.75ms, p99 8.48ms) vs meshed 23.7k RPS (p50 5.01ms, p99 10.83ms). Unmesh recovered 52.1k RPS, so the drop is the sidecar, not drift.

**Detail**: Docker/NodePort path, c125/30s, both states 100% 2xx (`checklist_load_test_linkerd.md:417-434`). The meshed proxies came up with `tokio_rt_workers=1`, a single worker thread carrying all ingress traffic — flagged as the likely cause but not confirmed; re-running with more proxy cores was never done.

## Path cost: port-forward vs Docker/NodePort

**Problem**: whether the load-test path itself (not the mesh) was capping throughput.

**Result**: `kubectl port-forward` alone is a 2.3x bottleneck at identical settings, and explains most of the "meshing" drop above.

**Detail**: Unmeshed HAProxy, all 30s, 100% 2xx (`checklist_load_test_linkerd.md:478-486`): docker/NodePort c50 40.9k RPS, c125 53.4k RPS (repeat 48.9k), c250 53.7k RPS, vs host/port-forward c125 23.1k RPS. Independently confirmed on `checklist_repro_kube_setup.md:1053-1057`: container→NodePort 52.7k RPS vs socat bridge 26.0k RPS vs port-forward 20.8k RPS. CPU during the c125 unmeshed run (`checklist_load_test_linkerd.md:489-495`) showed no single component pegged — the ~53.5k ceiling itself was left unattributed.

## CORES_MAX cap

**Problem**: whether the per-proxy core cap actually bounds CPU, and whether raising it buys throughput.

**Result**: the cap holds — CPU never exceeded it at CORES_MAX=2. Raising it to 3 bought +7-9% real throughput, and eliminated the load generator and app replicas as alternate explanations.

**Detail**: `checklist_repro_kube_setup.md:622-675`. At CORES_MAX=2, a connection sweep (125/250/500/1000 conns) never exceeded 200% CPU (peak 173.2%); throughput stayed flat at 25-28k req/s while p50 rose 4.2ms→38.1ms. Raising to 3 cores (n=4 runs each): 125 conns 26,531→28,505 req/s (+7.4%, Welch t=3.7, p≈0.01); 500 conns 29,387→32,046 req/s (+9.0%), with CPU samples crossing 200% for the first time (29/30). Two bottleneck checks ruled out other causes: doubling load generators added +11% combined throughput (generator wasn't the limit), and scaling `web-svc` 1→2 replicas changed throughput by <1% despite halving each proxy's CPU.

## Per-hop latency

**Problem**: where the 4.61ms mean request latency is actually spent.

**Result**: proxies account for 54% of total CPU and 57% of latency (haproxy processing + ingress→web hop); apps account for the rest.

**Detail**: 125 conns (`checklist_repro_kube_setup.md:690-714`). Latency split: edge 1.06ms/23%, haproxy 1.00ms/22%, ingress→web proxy 1.60ms/35% (largest), web app 0.95ms/21%. CPU-per-request cross-check gave the same 54/46 proxy/app split at 318us/request total.

## Fan-out cost: `/` vs `/api/list`

**Problem**: whether the fan-out endpoint (`/api/list`, which calls out to emoji services) costs more than the flat `/` route.

**Result**: fan-out costs 62% of throughput and 2.7x p50, though it's confounded by response size.

**Detail**: two runs each (`checklist_repro_kube_setup.md:723-730`): `/` 28,460/28,043 RPS at p50 4.2ms vs `/api/list` 10,726/10,687 RPS at p50 11.1ms. `/api/list` responses are 4,513 bytes vs 560 bytes for `/`, so byte throughput actually rises (48.2 vs 19.5 MB/s) even as request throughput falls.

## Mesh toggle under sustained load

**Problem**: whether meshing the ingress while it's under sustained load causes CPU to exceed its cap, and how that scales with replica count and connection load.

**Result**: across all three configurations tested, ingress proxy CPU never crossed the 200%-per-pod cap.

**Detail** (`checklist_mvp.md`), CORES_MAX=2, `/api/list`, mesh toggled mid-run in each case:
- 1 replica, 500 conns/150s (task 17): 13,139 RPS avg, p50 36.91ms, p99 65.92ms, 0 errors, 277 connection-refused during rollout. Proxy CPU peaked at 119.2%/76.5% across the two pods; meshing cost ~1.83 cores of proxy while app CPU stayed flat.
- 2 replicas, 5 app replicas, 500 conns/150s (task 19): 17,095 RPS avg, p50 23.54ms, p99 112.20ms, 177 connection-refused. Highest single CPU sample 109.64%. Caveat: only 13 of 165 sampled ticks were in the fully-meshed steady state, so this reading rests on a thin window.
- 1 replica, 1000 conns/150s (task 20): 15,079 RPS (12% below task 19's 500-conn run), p50 54.31ms, max 2.43s, 1012 connection-refused. Proxy mean 161.0%/peak 169.0%. Per-request CPU cost was similar across configurations (106.8-115.9 uCPU/req), read as evidence the ceiling is a throughput problem, not a concurrency one.

## Not run / inconclusive

- **VM load test**: `checklist_vm.md` — every task unchecked, no run has happened on the Azure VM.
- **Cores-vs-throughput sweep on emojivoto** (`checklist_load_test_linkerd.md` task 9): blocked on open questions, never run.
- **Cores-cap verification methodology** (task 13 of the same file): written but not started; superseded by the CORES_MAX 2→3 experiment above.
- **extraPortMappings path**: script written, never exercised as part of the path-cost sweep.
- **53.5k RPS ceiling in the unmeshed-HAProxy baseline**: no single component was pegged, left explicitly unattributed.

Raw per-second CSVs behind the mesh-toggle numbers live at `~/.cache/kube-cpu-sampler/` (e.g. `manual.csv`, `ingress_1_conn_1000.csv`), not tracked in git.
