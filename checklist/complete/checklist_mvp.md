# MVP: composable CPU measurement, then the cluster on the Azure VM

Goal: a minimum viable setup where proxy and application CPU are measured
by a script that runs on its own, in its own terminal, while load runs in
another, and where the cluster under test can be either this laptop's or
the one on the Azure VM.

Done means: one command samples CPU for a named target until stopped, a
separate command drives load, and we have a CPU number for the same
workload meshed and unmeshed, taken the same way on both machines.

Three things stay separate processes, and that separation is the point:

- the **sampler**, which measures and nothing else
- the **load driver**, which generates traffic and nothing else
- the **mesh toggle**, which changes the thing being measured

Each is runnable alone, in its own terminal, against a target given as an
argument. No script starts the load for you. This is a change from the
four `wip_` scripts, which each run their own load internally.

**The measurement work comes first and is done on the laptop.** The VM
adds a WAN, a shared 8 vCPU and a second set of tool versions, none of
which help while the sampler's design is still unsettled. The VM tasks
start once the sampler is validated locally.

The `wip_` scripts are **reference only**. The new scripts sit alongside
them; nothing is deleted or rewritten under this checklist.

Design lifted from task 26 of `checklist_repro_kube_setup.md`, whose
LOCAL items are already done: the kind config with `extraPortMappings`,
the prerequisites check, and the macOS guards on the `pf_` scripts.

## Tasks

- [x] 1. Record the VM's facts and confirm non-interactive SSH
- [x] 2. Settle the unmeshed CPU source
- [x] 3. Write the standalone CPU sampler
- [x] 4. Validate the sampler locally, meshed and unmeshed
- [x] 5. Make the sampler survive a mesh toggle mid-run
- [x] 6. Make the load driver a separate, composable process
- [ ] 7. Install the missing prerequisites on the VM
- [ ] 8. Get the repo onto the VM
- [ ] 9. Bring the cluster up on the VM
- [ ] 10. Reach the ingress from the laptop over the public IP
- [ ] 11. Measure CPU unmeshed on the VM
- [ ] 12. Measure CPU meshed on the VM
- [ ] 13. Record the comparison
- [x] 14. `dev_1_mesh_emojivoto.sh mesh` exits non-zero
- [x] 15. The probe pod accumulates zombies
- [x] 16. Publish measurements to Grafana (dropped)
- [x] 17. Measure haproxy across an unmesh -> mesh transition under load
- [x] 18. `dev_2_mesh_haproxy.sh unmesh` unpins the NodePort
- [x] 19. Measure at 2 ingress replicas and 5 emojivoto replicas
- [x] 20. Measure at 1 ingress replica and 1000 connections
- [ ] 21. Reformat every script comment for human readers

## 1. Record the VM's facts and confirm non-interactive SSH

Everything downstream assumes the VM answers without a prompt and that we
know what we are running on. The size and vCPU count bound every CPU
number we take later, so they are not optional trivia.

- [x] Confirm `ssh dev` works non-interactively, no passphrase prompt
      - `ssh -o BatchMode=yes -o ConnectTimeout=8 dev` returns
        immediately, login user `apoorv`
- [x] Record OS, kernel, architecture
      - Ubuntu 24.04.4 LTS, kernel 6.17.0-1022-azure, x86_64. Matches the
        x86/amd64 expectation from task 26.
- [x] Record vCPUs and RAM
      - 8 vCPU, 31 GiB RAM. `nproc` = 8, verified directly.
      - so the ceiling is 800% of one core, and 172G of 247G disk free
- [x] Confirm the public IP 20.245.114.144 matches the alias `dev`
      - ping 4/4, 0% loss, RTT avg 30.5ms (min 26.5, max 36.3)
      - that 30.5ms is the floor under every laptop-driven latency number
- [x] Record the tool inventory
      - present: docker 29.8.0, kind 0.33.0, kubectl v1.37.0,
        helm v3.21.4, curl 8.5.0, jq 1.7, python3 3.12.3
      - absent: linkerd, yq, bombardier. Task 7 fixes this.
- [x] Record what else is running on the VM
      - `k3d-deep-server-0` (rancher/k3s v1.36.3) and `recursing_fermi`,
        a `vsc-linkerd2-proxy-*` devcontainer
      - both stay. The VM persists between sessions; only our kind
        cluster is created and torn down per run.
      - no port conflict: k3d publishes only `0.0.0.0:36971->6443/tcp`,
        and nothing listens on 80, 443, 6443, 8080 or 31080
- [ ] Record the resource group and subscription
      - load the `buoyant-azure` skill before any `az` command that writes
      - not blocking anything: no `az` command is needed yet

## 2. Settle the unmeshed CPU source

**Settled: cgroup v2 `cpu.stat` `usage_usec`, read through a probe pod
that mounts the node's `/sys/fs/cgroup`.** It has 1-second granularity,
agrees with the proxy's own counter to within that counter's resolution,
and reads meshed and unmeshed containers identically.

All four `wip_` scripts read the proxy's admin port `:4191` or
`job="linkerd-proxy"` series. An unmeshed workload has neither, and
`wip_4` exits on "port-forward never came up". Measuring both states means
reading the *application* container from a source that exists either way.

- [x] Rule out `docker exec` as the route to the cgroup
      - refused by the permission system, so the cgroup was briefly
        dropped as unreachable. It is not: a pod with a hostPath mount of
        `/sys/fs/cgroup` reaches the same tree through `kubectl exec`,
        which is permitted.
- [x] Reject the kubelet-side sources on granularity
      - cAdvisor's housekeeping interval is the floor, and scraping it
        more often only resamples an unchanged value. 10s cannot measure
        a 30s run to better than ~33%.
      - the timestamp-division idea would have made the lag survivable
        for a *long* run, but it does nothing for granularity, which is
        the binding constraint
- [x] Establish the cgroup layout on the kind node
      - cgroup v2. There is no `kubepods.slice` at the root; the path is
        `/sys/fs/cgroup/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-<qos>.slice/kubelet-kubepods-<qos>-pod<UID>.slice/cri-containerd-<containerID>.scope/cpu.stat`
      - `<qos>` is `besteffort`, `burstable` or absent for guaranteed;
        `<UID>` is `.metadata.uid` with `-` replaced by `_`; the
        container id is `.status.containerStatuses[].containerID` or
        `.status.initContainerStatuses[].containerID` minus the
        `containerd://` prefix
- [x] Measure the update granularity
      - six reads 1s apart on an idle `emojivoto/web`: 254893, 257450,
        260974, 263727, 267557, 270636 usec
      - advances every second, deltas 2.5-3.8ms, no lumps. 1s is a real
        sampling interval here, not an aspiration.
- [x] Validate against `process_cpu_seconds_total` on a container that
      has a proxy
      - 60.117s window on `linkerd-viz/prometheus`'s `linkerd-proxy`
      - proxy counter: 0.210000s, 0.349% of one core
      - cgroup: 0.213160s, 0.355% of one core
      - **disagreement 1.50%, absolute gap 3.16ms**
      - that gap is *inside the proxy counter's own resolution*: it
        reports 2 decimals, so 10ms quantization on a 0.21s delta is
        ±4.8%. The cgroup read is microsecond-resolution and is the more
        precise of the two, not the less.
      - caveat: this was an idle proxy. Re-check under load in task 4,
        where absolute CPU is 100x higher and quantization stops mattering.
- [x] Confirm it reads a container with no proxy
      - demonstrated on `web-5f7c799d5b-p645g`, the unmeshed replacement
        pod: same path shape, same 1s granularity. No proxy involved
        anywhere in the read.
- [x] Measure the per-read cost
      - single `kubectl exec`: 113, 86, 84, 85, 79 ms
      - one exec reading **all 29 container cgroups**: 105ms
      - so cost is per-sample, not per-target. A single long-lived exec
        looping inside the pod removes even that, and is what task 3
        should do rather than one exec per sample.
- [x] Decide how the probe pod is created and owned
      - now `scripts/init_8_install_cpu_probe.sh` and
        `scripts/init_8_cpu_probe.yaml`
      - a **DaemonSet in `kube-system`**, not a single pod pinned by
        `nodeName`, so it works on a multi-node cluster unchanged
      - the init script verifies the mount rather than trusting Ready: a
        Ready pod with a wrong cgroup tree looks identical otherwise
      - verified 2026-09-17: `cpu-probe-ldnl6 sees 30 container cgroups`
      - the scratch pod in `default` has been deleted

### Mesh state: a trap for the sampler

The proxy is a **native sidecar**, so it is an init container. Anything
enumerating `.spec.containers[].name` sees only the app container and
concludes the workload is unmeshed. This is why a meshed cluster looks
unmeshed at a glance.

- [x] Record the correct mesh check
      - **the union of `.spec.initContainers[]` and `.spec.containers[]`
        is mandatory.** Neither list alone is correct on this cluster.
      - verified 2026-09-17: `linkerd-destination` and
        `linkerd-proxy-injector` carry `linkerd-proxy` in
        `.spec.initContainers`, but `linkerd-identity` carries it in
        `.spec.containers`. An initContainers-only check reports
        linkerd-identity unmeshed.
- [x] Unmesh emojivoto, 2026-09-17
      - `dev_1_mesh_emojivoto.sh unmesh`, all four deployments rolled
      - verified: new pods read `1/1` with empty `spec.initContainers`
      - **haproxy-controller is still meshed** and was left alone, since
        `dev_2`'s unmesh uses `--reset-values` and would reset every
        user-set helm value, not just the inject annotation

## 3. Write the standalone CPU sampler

**Decided: two subcommands, `start <name>` and `stop`.** The name is the
run's defining title. `stop` ends the run and prints the report under
that name; it takes no argument, since only one run is active at a time.
There is no separate `report` subcommand.

Revised 2026-09-17, replacing an always-on collector with explicit
markers. Always-on bought the ability to answer a question about a run
after the fact without having planned for it, at the cost of a stream
that had to survive indefinitely, rotate, and reconnect. Starting and
stopping around a run is simpler and keeps the property that matters:
the sampler still generates no load, so load runs in another terminal
and the two do not know about each other.

Shape, decided 2026-09-17:

- the **probe pod** is a DaemonSet, already installed by
  `init_8_install_cpu_probe.sh`. It does no measuring.
- the **in-pod loop** reads every container cgroup under
  `kubelet.slice` on each tick and prints one line per container
- the **collector** is one long-lived `kubectl exec`, started by
  `start` and ended by `stop`
- the **inventory** maps container id to namespace, pod, container and
  mesh state, refreshed on a slow loop. Internal, not a subcommand.
- **aggregation** happens in `stop`, which prints the report

Why streaming rather than one exec per sample: an exec costs ~85ms and
one exec reads all 30 cgroups in 105ms. Per-sample execs would mean
~86,000 process spawns and as many API calls per day. A single held
connection costs one busybox loop reading 30 small files per tick.

Built as `scripts/dev_5_measure_cpu.sh`. State in
`$CPU_SAMPLER_DIR`, default `~/.cache/kube-cpu-sampler`.

- [x] In-pod collector loop
      - walk `/hostcgroup/kubelet.slice/kubelet-kubepods.slice`, emit
        one line per container: clock, cgroup path, `usage_usec`
      - clock comes from `/proc/uptime`, which is monotonic and has
        centisecond resolution. Busybox `date` has no `%N` and prints
        the literal string, so it cannot timestamp sub-second.
      - emit `date +%s` alongside it once per tick so the monotonic
        clock can be tied back to wall time
- [x] Stream reader
      - one `kubectl exec`, output appended to a file
      - reconnect when the stream drops: apiserver restart, network
        blip, pod eviction
      - **mark every gap explicitly.** A reconnect leaves a hole, and
        nothing may average across it.
      - rotation is no longer load-bearing now that the collector runs
        only for the length of a run, but it is kept: nothing stops
        someone leaving `start` running overnight.
- [x] Inventory loop
      - `kubectl get pods -A -o json` every ~30s, mapping container id
        to namespace, pod, container name and mesh state
      - mesh state comes from `.spec.initContainers[]`, never
        `.spec.containers[]` alone: the proxy is a native sidecar
      - the counter stream stays pure numbers keyed by container id. The
        join happens at aggregation time.
      - this is why task 5 is nearly empty: pod churn is an inventory
        change, not an event the collector has to survive
- [x] Target a single workload, sample at 1Hz, write per-second CSV
      - **revised 2026-09-17**, replacing "collect everything, filter
        later". The output is now a time series for one workload, not a
        whole-node snapshot aggregated after the fact.
      - the point is the shape over time: a CSV with one row per
        container per second can be graphed, and a mean hides the ramp,
        the plateau and any spike
      - `start <name> <ns> <workload>`, matching the argument order
        `dev_4_inspect_cores.sh` already uses
      - app and proxy containers are separate rows, so mesh cost stays
        attributable
      - what this gives up: a question about a container that was not
        targeted cannot be answered after the run. Accepted.
      - built and verified 2026-09-17. CSV at
        `~/.cache/kube-cpu-sampler/<run>.csv`, columns
        `ts_epoch,t_s,run,namespace,pod,container,role,mesh,container_id,usage_usec,delta_usec,interval_s,cpu_pct_core,event`
      - `role` is app|proxy|init, so proxy cost stays attributable
      - `event` is sample|first|gap|reconnect|roll, and every non-sample
        row carries empty delta/interval/percent, so a hole is never
        drawn as a zero
      - collection inside the probe pod stays untargeted, reading every
        cgroup on the node; the workload filter is applied on the way
        into the CSV. One read costs 105ms for all of them, so filtering
        at the source would cost more than it saves.
      - name reuse is refused at `start`, before any sampling happens
      - **the shape is the point, and it showed**: 39 rows over 37.9s,
        intervals 1.02-1.04s, zero duplicate (id, second) keys.
        ~0.3% idle, then 322 -> 346 -> plateau ~330% of one core, 222%
        on the last load second, back to 0.2%. A mean of 177% would have
        hidden all of it.
      - spot-checked independently: 39 rows, top samples 346.66, 344.04,
        343.09, 336.48, 335.22, events `1 first` + `37 sample`
- [x] Explicit start/stop, named
      - `start <name>` bounds the run and records wall time. `stop` ends
        it and prints the report under that name.
      - aggregation is over the marked window, so there is no edge
        quantization: the sampler owns the boundaries
- [x] `stop` writes the report to a file as well as stdout
      - under `$CPU_SAMPLER_DIR`, named after the run, carrying the
        title, window, measured elapsed, gap count and the table, so it
        stands alone without the terminal scrollback
      - a reused run name must not silently overwrite an earlier report
      - raw sample data is kept, not deleted on stop, so a report can be
        regenerated if the aggregation logic changes
- [x] Aggregate in `stop`
      - CPU seconds, percent of one core, mean and peak over the window
      - per container, app and proxy separately
      - CPU per request when a request count is supplied
- [x] Clean shutdown, no orphaned `kubectl exec` or port-forwards
      - after SIGTERM: no `kubectl exec`, no sampler process, and no
        collector process left in the probe pod

### Three things the design got wrong, found while building

These were specified in this section and did not survive contact.

- [x] `.spec.initContainers` alone misclassifies mesh state
      - corrected in task 2. The union of both lists is required.
- [x] Killing the local `kubectl exec` does not kill the in-pod loop
      - the loop parks in `write(2)` because the exec pipe stays open
        and unread on the pod side, so it never sees EPIPE
      - four stale loops accumulated, each still reading every cgroup at
        1Hz, and the sample rate doubled
      - fixed by marking the loop and reaping it by name over
        `kubectl exec` before every connect and at shutdown, newest pid
        first so `awk` dies before the shell reaping it
- [x] `trap cleanup EXIT INT TERM` does not stop the collector
      - bash resumes the reconnect loop after the handler returns and
        immediately opens a new exec. Handlers now `exit 0`.
Moved out of this task, since neither is about writing the sampler:
probe-pod zombies to task 15, Grafana and Prometheus publishing to
task 16.

### Smoke test, 2026-09-17

Load driven separately by `test_load_2_docker_nodeport.sh 50 20s`:
29760 RPS, 595151 2xx. Window 21.43s measured across 22 ticks, 0 gaps.

      emojivoto/web-svc (unmeshed)      66.577 CPU-s  310.67% mean  343.89% peak
      haproxy ingress-controller        13.759 CPU-s   64.21% mean   69.87% peak
      haproxy linkerd-proxy             39.155 CPU-s  182.71% mean  202.46% peak
      linkerd-viz/prometheus proxy       0.023 CPU-s    0.11% mean    0.31% peak

Per request: web-svc 109.25 uCPU/req, haproxy proxy 64.35 uCPU/req.

Both an unmeshed container (emojivoto) and meshed ones (haproxy-controller,
linkerd-viz) produced numbers, which was the point.

Gap handling verified by killing the exec mid-run: `G <epoch> reconnect
rc=143` written, and the report over that window read 10.89s across 10
ticks with 1 gap, while per-container measured elapsed was 8.28s over 8
deltas. The ~2.6s hole is excluded, not averaged in.

Known rough edge: reporting the instant after `mark stop` can be one tick
short because of stream buffering. `report` prints a note when data ends
before the stop marker.

Out of scope: latency, which `wip_2` covers. Also out of scope: deleting
or rewriting any `wip_` script.

## 4. Validate the sampler locally, meshed and unmeshed

Prove the sampler on the laptop's cluster before the VM adds variables.

Validated 2026-09-17 with 5s load runs throughout. Also the first
exercise of the split scripts, `dev_5_measure_start.sh`,
`dev_6_measure_stop.sh` and `util_measure.sh`.

- [x] Confirm a local cluster is available, or rebuild one
      - `kind-kind` up, node Ready, k8s v1.37.0, probe DaemonSet running.
        No rebuild needed.
- [x] Re-validate the cgroup source against the proxy counter UNDER LOAD
      - 18.568s window on meshed `emojivoto/web`'s `linkerd-proxy`
      - proxy `process_cpu_seconds_total`: 0.16 -> 7.44 = 7.28 CPU-s
      - cgroup `usage_usec`: 170550 -> 7455236 = 7.284686 CPU-s
      - **disagreement +0.064%, absolute gap 4.7ms.** Taking the other
        adjacent 1s tick gives +0.095%, so 0.06-0.09% either way.
      - the proxy counter's own 10ms quantization on 7.28s is ±0.069%,
        so the disagreement is at or inside its resolution
      - **this supersedes the idle 1.50% figure**: at 35x the absolute
        CPU, quantization no longer dominates and the two still agree.
        The cgroup source is settled.
      - moved here from task 2, which validated it idle only
      - idle result: 1.50% disagreement over 60.117s, but absolute CPU
        was 0.210s and the proxy counter quantizes at 10ms, so ±4.8%
      - under load absolute CPU is ~100x higher and quantization stops
        mattering, so this is the check that actually binds
- [x] Sample an unmeshed workload and get a plausible non-zero number
      - `val4-unmeshed.csv`, 22 rows, 1 container, 0 gaps, intervals
        1.01-1.04s. Idle 0.20-0.48%, then 259.07 -> 344.59 -> 337.32 ->
        339.79 -> 339.68, decay, back to 0.26-0.52%. 30315 RPS.
- [x] Sample the same workload meshed, app and proxy separately
      - `val4-meshed.csv`: 30 app rows and 30 proxy rows, distinct
        container ids, `mesh` reads meshed on all 60
      - app peak 272.92%, proxy peak 147.59%. 24298 RPS.
      - spot-checked independently: `30 app meshed`, `30 proxy meshed`,
        proxy top samples 147.59, 147.18, 146.51
- [x] Confirm restarting the sampler between the two states is enough
      - stop, mesh, start: the new run resolved the rolled pods, picked
        up both new container ids and labelled them meshed
      - the selector survives a roll because it is read from the
        immutable `.spec.selector`
- [x] Confirm sampling perturbs throughput negligibly
      - with sampler 30315.63 and 29492.85 RPS; without 30377.76 and
        28973.93. Sampler runs came out 0.8% *higher*.
      - **this does not confirm the prior <0.4% claim.** Within-group
        spread is 2.8% and 4.8%, so 5s runs only bound the effect to
        roughly ±5%. Re-run at 30s to say more.
      - corroborating: CPU per request is 112.24, 111.40 and 111.34
        uCPU/req across the three runs, so the app does identical work
        per request either way
- [x] Confirm two terminals work as intended: sampler in one, load in
      the other, neither aware of the other
      - neither takes the other as an argument or reads its state

### Limits of this validation, carried elsewhere

Every run here is ~5-6 sampled seconds, so a plateau rests on 4-5
samples. Enough to show ramp, plateau and decay, and enough for the
cgroup-vs-proxy check, which uses cumulative counters where sample count
does not enter. Not enough for a mesh overhead figure with a confidence
interval, so that re-run moved to task 13. Two defects found here moved
to task 3 and task 14.

## 5. Make the sampler survive a mesh toggle mid-run

**Mostly dissolved by task 3's design.** The always-on collector is keyed
by container id and never resolves a target, so a mesh toggle is just new
container ids appearing in the inventory. There is nothing to survive.

What is left is the part the design does not handle for free.

- [x] Confirm the claim rather than assuming it: toggle under a running
      sampler and check the output tells the story correctly
      - done three times, on haproxy rather than emojivoto: tasks 17, 19
        and 20. The claim held every time: a toggle is just new
        container ids appearing in the inventory.
- [x] Make the roll visible in the aggregate
      - `roll` rows mark it, and each new container's first sighting is
        a `first` row with empty delta, interval and percent
      - **verified, not assumed**: max `interval_s` across all 607
        sample rows in task 17 was 1.04s, so no delta spans the
        transition. Re-checked in tasks 19 and 20.
      - the old counter stops and the new starts from zero, and the two
        never join because the join key is the container id
- [x] Decide what a container disappearing means
      - a gap, never a zero. A zero silently drags an average down.
      - exercised in task 20: the newly meshed proxy read a real 0.14%
        while idle under load, while the absence of a proxy before the
        mesh produced no rows at all. The CSV distinguishes the two,
        which is the whole point of the `event` column.
- [x] Confirm the inventory refresh interval is fast enough
      - **it is 5s, not ~30s.** `RESOLVE_INTERVAL="${RESOLVE_INTERVAL:-5}"`
        in `dev_5_measure_start.sh:54`, and it is overridable by env.
        The ~30s figure written when task 3 was designed did not survive
        into the built script.
      - a container that lives and dies between refreshes is still never
        named. Its counters are collected, keyed by id, so the data
        survives even when the label does not.

## 6. Make the load driver a separate, composable process

`test_load_2_docker_nodeport.sh` already runs `alpine/bombardier` in a
container and takes connections and duration, but it derives the node IP
and NodePort with kubectl, so it only works where the cluster is.

**Closed 2026-09-17: `test_load_2_docker_nodeport.sh` already satisfied
every item and needed no change.** Exercised this way throughout tasks
17, 19 and 20.

- [x] Take the target as an argument so it can point at the VM's public
      IP as easily as at a local NodePort
      - the third positional argument IS the URL, and when given, the
        kubectl derivation is skipped entirely
      - so pointing it at the VM needs no code change, only a different
        URL. This is what unblocks task 11 and task 12.
- [x] Keep connections and duration as arguments
      - first and second positional, defaults 125 and 30s
- [x] Print requests/sec and the HTTP code breakdown, as today
      - **known limit, hit in every toggle run**: one aggregate over the
        whole run, so a run spanning two mesh states cannot have its two
        request rates separated. That needs two runs, not one.
- [x] Do not start, stop, or know about the sampler
- [x] Decide whether this is a change to `test_load_2` or a new script
      - **neither. No change was required.** The URL argument already
        existed; the earlier reading of this task missed it.

## 7. Install the missing prerequisites on the VM

Confirmed absent under task 1: linkerd, yq, bombardier.

- [ ] Install the linkerd CLI
      - required by init_2, init_3 and `dev_1_mesh_emojivoto.sh`
- [ ] Install yq, after checking which scripts actually need it
- [ ] Decide whether bombardier is needed on the host at all
      - the load driver runs it in a container, so probably not
- [ ] Run `scripts/init_0_prerequisites.sh` and record the output
      - it is already Linux-aware: macOS-only tools report `n/a`
      - this is the real check; task 1's inventory was ad-hoc
- [ ] Record the version of everything installed, since nothing is pinned

## 8. Get the repo onto the VM

Task 26 settled this: the scripts run on the VM, not driven remotely from
the laptop, because kind writes `127.0.0.1:<port>` into the kubeconfig and
tunnelling the API server buys nothing. The load driver is the exception
and stays on the laptop.

- [ ] Choose clone or rsync, and record which
      - no `kube` checkout exists on the VM. `~/projects` holds `dev`,
        `enterprise-linkerd`, `j5j`, `linkerd2`, `linkerd2-proxy`.
      - this repo has no remote configured, so rsync to `~/projects/kube`
        is the path of least resistance unless we push it somewhere
- [ ] Confirm `dev_5_measure_cpu.sh` runs unchanged on Ubuntu x86_64
      - moved here from task 3, which could only exercise Darwin arm64
      - the collector runs inside a busybox pod either way, so the risk
        is in the laptop-side script, not the in-pod loop
- [ ] Get the repo there and confirm the `scripts/` tree arrived
- [ ] Decide how later script changes reach the VM
      - this happens repeatedly while tasks 11 and 12 run

## 9. Bring the cluster up on the VM

Run the existing modules unchanged. The only VM-specific input is
`KIND_LISTEN_ADDRESS=0.0.0.0`, because the committed config binds
loopback only. The cluster is created and torn down per run, so this
task's output is a repeatable procedure, not a one-time setup.

- [ ] Run init_1 through init_7 with `KIND_LISTEN_ADDRESS=0.0.0.0`
- [ ] Capture wall-clock time, against the laptop's 5m7s
- [ ] Confirm all pods Ready
- [ ] Confirm the ingress answers 200 from the VM itself
      - on Linux the Docker bridge routes from the host, so
        `curl 172.18.0.2:31080` works directly, unlike on macOS
- [ ] Confirm `cleanup_1_cluster.sh` tears down cleanly and leaves the
      k3d cluster and the devcontainer untouched
      - this matters more than usual: teardown runs between every run
- [ ] Note any script needing a change to run on Linux
      - feed anything found back to `checklist_repro_kube_setup.md`

## 10. Reach the ingress from the laptop over the public IP

Path 3 of task 26: kind publishes the NodePort on the VM's host via
`extraPortMappings`, and the NSG rule the user has added, scoped to the
laptop, lets us in. No userspace relay in the data path, which matters
because the local socat analogue halved throughput and raised p50
six-fold.

- [ ] Confirm the NodePort is published on the VM's host interface
- [ ] `curl` the ingress from the laptop and get a 200
- [ ] Record the RTT again under the port actually used
      - ICMP already passes at 30.5ms avg; TCP to the NodePort is the
        path that matters
- [ ] Keep the SSH tunnel as a recorded fallback, unused if this works

## 11. Measure CPU unmeshed on the VM

Separate from the meshed run deliberately: different measurement source,
different failure modes.

- [ ] Confirm both emojivoto and HAProxy are unmeshed
      - `dev_1_mesh_emojivoto.sh unmesh`, `dev_2_mesh_haproxy.sh unmesh`
      - note: `dev_2` unmesh uses `--reset-values`, which resets *all*
        user-set helm values, not just the inject annotation
- [ ] Start the sampler in its own terminal
- [ ] Run the load from the laptop in another
- [ ] Stop the sampler, record CPU and the load result together
- [ ] Record what the number covers: app container only, no proxy exists
- [ ] Record whether the k3d cluster or the devcontainer were busy
      - they share the 8 vCPU and will skew the result if they are

## 12. Measure CPU meshed on the VM

- [ ] Mesh both, and confirm with `dev_4_inspect_cores.sh`
- [ ] Set CORES_MAX and record the value used
      - `dev_3_modify_linkerd_cores.sh` has no reset path, so record what
        was set and how to undo it
- [ ] Start the sampler in its own terminal
- [ ] Run the same load from the laptop, same connections and duration
- [ ] Stop the sampler, record app CPU and proxy CPU separately
- [ ] Confirm `tokio_rt_workers` matches the CORES_MAX that was set
- [ ] Record VM load conditions again, as in task 11

## 13. Record the comparison

- [ ] Re-run the mesh overhead comparison at 30s before quoting it
      - moved here from task 4, whose 5s runs only had 4-5 plateau
        samples. The cgroup-vs-proxy validation does not need this, but
        an overhead figure with a stated confidence does.
      - thin numbers from task 4, not to be quoted as-is: app 111.34 vs
        112.24 uCPU/req, proxy +59.63 uCPU/req
- [ ] Meshed vs unmeshed CPU for the same load, same VM
- [ ] CPU per request for both, which needs no subtraction and is the
      stronger of the two comparisons
- [ ] Throughput and 2xx rate for both
- [ ] State plainly what the laptop-to-VM path adds
      - needs a VM-local load run as the no-network reference, otherwise
        the mesh cost and the WAN cost are not separable
- [ ] Promote anything durable to `knowledge.md`, leaving run state here

## 14. `dev_1_mesh_emojivoto.sh mesh` exits non-zero

Found during task 4. The mesh itself succeeds; the script's final
`linkerd check --proxy` is what fails, so the non-zero exit is
misleading rather than a real failure.

- [x] Confirm the symptom
      - `linkerd -n emojivoto check --proxy` exits **1** with exactly one
        failing line out of 65 passing checks:
        `x Running: ~/.linkerd2/bin/linkerd-trust check ... --namespace=emojivoto ...`
        `error: unexpected argument '--namespace' found`
      - `linkerd-data-plane`, `linkerd-identity-data-plane`, `linkerd-viz`
        and `linkerd-viz-data-plane` all pass, so the mesh is healthy
      - verified independently of the agent that fixed it
- [x] Root cause
      - `~/.linkerd2/bin/linkerd-trust` is `linkerd-trust-1.0.0-beta.1`,
        installed 2025-09-01, **outside this repo**, so no cluster
        rebuild clears it
      - it answers `_extension-metadata` with `"checks":"always"`, and
        `cli/cmd/check_extensions.go:findAlwaysChecks` runs any such
        binary on every `linkerd check`
      - its `check` subcommand has no `--namespace` flag, and the CLI
        appends one whenever `-n` is set. **Without `-n` the same binary
        returns `{}` and passes**, which is why a plain `linkerd check`
        exits 0 and never prints a linkerd-trust section.
- [x] Decide whether this is the same thing as task 22 of
      `checklist_repro_kube_setup.md`
      - **yes, a duplicate of task 22's first half**, down to the binary
        path and the `set -e` consequence
      - task 22 stays open: it also covers the linkerd-viz install race
        and the Grafana authz retest, neither of which is this
      - removing or fixing the broken binary remains task 22's item
- [x] Decide what the script should do
      - **the check was removed, 2026-09-17 on the user's call.** The
        script meshes and waits for the rollout; that is all.
      - an earlier fix here forgave the linkerd-trust failure and exited
        non-zero on anything else. It worked, but it was 22 lines to
        keep a check that was not the script's job.
      - `linkerd check --proxy` is still run by hand when wanted. The
        broken binary is task 22 of `checklist_repro_kube_setup.md`.

## 15. The probe pod accumulates zombies

Found in task 3, confirmed growing in task 4. Cosmetic today, but it is
an unbounded leak in a pod meant to run for the life of the cluster.

- [x] Confirm the count still grows
      - 4 zombies in `cpu-probe-ldnl6` before the fix: PIDs 770, 1153,
        1384 `[xargs]` and 5523 `[find]`, PID 1 `sleep infinity`
      - **it leaks per reconnect, not per run**: still 4 after the runs
        in tasks 17, 19 and 20, the same 4 task 4 recorded. Slow, but
        unbounded.
- [x] Fix the cause
      - PID 1 in `init_8_cpu_probe.yaml` is now
        `sh -c "trap 'exit 0' TERM INT; while :; do sleep 1; done"`
      - `sleep infinity` cannot reap because it never calls wait(2).
        busybox ash waits for its foreground `sleep` with `waitpid(-1)`,
        so it reaps whatever else was reparented to it.
      - verified empirically on two throwaway pods before touching the
        DaemonSet: two orphaned children left **2 zombies under
        `sleep infinity` and 0 under the shell loop**
      - rejected `shareProcessNamespace` (pod-level, changes nothing
        inside the container) and a tini image (more churn than the
        problem warrants)
      - **bonus: the `trap` also fixes deletion.** The kernel drops
        unhandled default-action signals to PID 1, so the old pod
        ignored SIGTERM and took the full grace period: `kubectl delete`
        measured **31.2s** before against **0.3s** after.
      - mount still good after the roll:
        `cpu-probe-r5hnl sees 39 container cgroups`
- [x] Confirm a start/stop cycle adds none after the fix
      - measured across **three** cycles, not one, because the earlier
        claim that a fixed reaper "added none" was wrong when measured
        once: baseline 0, then 0, 0, 0
      - the cycles were real, not no-ops: each CSV carried 24 sample
        rows over 2 containers
      - plus a direct orphan test against the live probe pod afterwards:
        two orphaned children, 0 zombies left
      - spot-checked independently: PID 1 is the trapping shell loop and
        `ps` shows zero processes in state Z

## 16. Publish measurements to Grafana

Decided in task 3 and deferred out of it. The CSV is the artifact and
carries the exact numbers; Grafana is for looking at the shape.

**DROPPED 2026-09-17 on the user's call. Kept, not deleted, so the
reasoning survives if it comes back.**

The CSV is the artifact and carries the exact numbers at 1s resolution.
Everything this task was for has been answered from it directly: the
ramp, the plateau, the roll, the per-pod split, and the fact that the
proxy steps rather than spikes. None of that needed a dashboard.

The annotation only ever earned its place if runs were being compared
against *other* cluster metrics on the same timeline, and no analysis
this session wanted that.

- [x] Post a region annotation to Grafana's `/api/annotations` bounding
      a run, so it shows as a shaded band over any chart
      - dropped. Was plain `curl` plus a service-account token.
- [x] Decide whether this is still wanted now that the sampler writes a
      per-second CSV
      - **no.** Decided by the user 2026-09-17.
- [x] Optional: expose `usage_usec` as a Prometheus counter
      - dropped with the rest. The reasoning below still stands and is
        why it was never compelling: a scrape interval becomes the
        resolution floor.
      - the scrape interval becomes the resolution floor, so linkerd-viz
        Prometheus at 10s puts us back where task 2 started. Needs a
        dedicated 1s scrape job to be worth anything.
      - still strictly better than cAdvisor at the same interval: this
        would read the live cgroup file at scrape time, so the value is
        fresh. cAdvisor's is already up to 10s stale however often it is
        scraped.
      - a cumulative counter loses no data to a slow scrape. It loses
        resolution, and run-scoped numbers taken from it carry up to
        ±10s of boundary error. That is why the numbers come from the
        CSV, not from `rate()`.

## 17. Measure haproxy across an unmesh -> mesh transition under load

The question is whether a linkerd proxy pinned to 2 cores crosses 200% of
one core under enough load. haproxy-controller is the subject because it
is the ingress: every request in the cluster passes through it, so it is
the proxy that saturates first.

Design, decided 2026-09-17 with the user:

- **one sampler on haproxy-controller**, not on emojivoto. The sampler
  takes a single workload and its in-pod reaper kills any second
  collector in the cluster, so two workloads cannot be sampled at once.
- **the toggle happens mid-run**, so one CSV carries unmeshed ingress
  CPU, the roll, and meshed app+proxy CPU on one timeline
- **only haproxy goes to 2 cores.** emojivoto web stays at CORES_MAX=3,
  so the backend is not the thing that runs out of headroom first.
- **load hits `/api/list`**, the JSON data endpoint. `/list` returns 200
  but serves the same static SPA shell as `/`, so it exercises less of
  the app.

This is also the first real exercise of task 5, a mesh toggle under a
running sampler, on haproxy rather than emojivoto.

### Starting state, measured 2026-09-17

- node `kind-control-plane`, **15 CPUs**, k8s v1.37.0, arm64
- emojivoto all four deployments meshed, proxy a native sidecar in
  `.spec.initContainers[]`
- emojivoto `web` proxy: `CORES=1`, `CORES_MIN=1`, **`CORES_MAX=3`**,
  `tokio_rt_workers 3`. No cpu requests or limits on any proxy, so
  CORES_MAX is the only thing bounding worker count.
- haproxy-controller **already meshed**, 2 replicas, also `CORES_MAX=3`
- ingress at `172.18.0.2:31080`, Ingress `emojivoto/emojivoto-ingress`,
  `/` prefix to `web-svc:80`, so `/api/list` routes through unchanged
- `/api/list` returns 200 and a JSON array; `/list` returns 200 HTML
- cpu-probe DaemonSet Running

### Tasks

- [x] Work around task 18 so the NodePort survives the unmesh
      - `helm upgrade haproxy-ingress haproxytech/kubernetes-ingress
        -n haproxy-controller --reset-values
        --set controller.service.nodePorts.http=31080`
      - one upgrade, one rollout. Re-pinning afterwards would have
        rolled the pods twice.
- [x] Unmesh haproxy and verify it, union of initContainers and containers
      - both pods from rs `...-5f79678c95`, Running 1/1,
        `initContainers=[]`, `containers=[kubernetes-ingress-controller]`
      - `linkerd-proxy` in neither list on either pod
      - `helm get values` no longer carries `podAnnotations`, so the
        inject annotation was reset away as intended
      - emojivoto untouched: all 4 pods still 2/2, ages predating the
        upgrade, so nothing rolled there
- [x] Confirm the ingress still answers 200 on `/api/list` at the
      NodePort from a container on the `kind` network
      - `/api/list` 200, 4513 bytes; `/` 200, 560 bytes
      - http 80 -> nodePort 31080 unchanged after the upgrade
- [x] Decide the load level that can actually saturate 2 cores
      - **500 connections.** Swept unmeshed at 10s each against
        `/api/list`: 125 conns 12,087 rps; **500 conns 14,676 rps**;
        1000 conns 12,864 rps; 2000 conns 12,671 rps. Zero non-2xx at
        every level, repeatable across reruns.
      - it peaks at 500 and *declines*, it does not merely flatten.
        Past 500, p50 latency scales linearly with connections
        (33.0 -> 72.5 -> 144.1 ms for 500 -> 1000 -> 2000) with no
        throughput gain: the extra connections only queue.
      - the generator is not the limit: `docker stats` during a 500-conn
        run read bombardier at 0.62 cores against kind-control-plane's
        9.35. A generator ceiling would also show as a flat ceiling
        rather than a decline.
      - node is not CPU-pinned either: 9.72 of 15 cores busy at 500
        conns, 9.26 at 2000, read from `/proc/stat` twice 5s apart
        through the cpu-probe pod. `kubectl top node` is unavailable,
        there is no metrics-server on this cluster.
- [x] **2 cores is not reachable here, and the reason is not the load
      level.** Predicted before the run, confirmed by it: peak for a
      single proxy was 119.2% of a core against a 2-core budget.
      - unmeshed, the haproxy *controller* container draws 0.52-0.54
        cores per replica, ~1.06 summed, and that is its ceiling: it is
        already at it by 500 conns. `requests: cpu 250m` and no limit,
        so it is not throttled; it simply needs no more.
      - haproxy is ~11% of cluster CPU. Of kubepods.slice's 9.30 cores,
        most is meshed emojivoto and its proxies, which is what caps
        throughput at 14.7k rps.
      - the smoke test's 182.71% proxy figure was taken at ~29.7k rps
        against `/` with emojivoto **unmeshed**, about twice today's
        request rate against a response 8x smaller (560 vs 4513 bytes)
      - so the backend saturates before the ingress proxy does. Getting
        the proxy to 2 cores needs a setup change, not more load: fewer
        haproxy replicas, or an unmeshed/cheaper backend.
- [x] Start the sampler on `haproxy-controller deploy/haproxy-ingress-kubernetes-ingress`
      - `RESOLVE_INTERVAL=2` so the roll is caught sharply
      - run `t17-haproxy-toggle-2core`, CSV at
        `~/.cache/kube-cpu-sampler/t17-haproxy-toggle-2core.csv`
- [x] Drive load at `http://172.18.0.2:31080/api/list` in its own terminal
      - 500 conns, 150s. 13,139 rps avg, 1,969,693 2xx, no 3xx/4xx/5xx.
      - latency avg 38.07ms, p50 36.91, p99 65.92, max 1.07s
      - 277 `connection refused`, all during the pod roll. Connection
        failures, not HTTP errors.
      - **bombardier reports one aggregate over all 150s**, which spans
        both states, so the unmeshed and meshed request rates cannot be
        separated from it. rps stdev 3448 against a 13,139 mean is
        consistent with the unmeshed phase being faster, but that is
        inference. Splitting it needs two load runs, not one.
- [x] Mesh haproxy mid-run with `CORES_MAX=2` set in the same upgrade
      - `helm upgrade haproxy-ingress haproxytech/kubernetes-ingress
        -n haproxy-controller --reset-values -f haproxy_mesh_2cores.yaml`,
        the values file carrying inject, CORES_MAX=2 and nodePort 31080
      - one rollout, as intended. NodePort 31080 survived.
- [x] Stop the sampler and confirm the CSV carries the roll
      - 615 rows: 607 `sample`, 6 `first`, 2 `roll`. No gaps, no
        reconnects. 4 pods, 6 container ids.
      - **no dead window**: old and new pods overlap. hhqdg+wlgds to
        t_s 98, +7rspj from 99, all four at 115, then hhqdg+7rspj+bs9gr
        to 130, only the new pair from 131.
      - **no row averages across the roll.** Every new container's first
        appearance is a `first` row with empty delta and percent, and
        max `interval_s` across all 607 sample rows is 1.04s, so no
        delta spans the transition. Verified independently.
      - 5 integer epoch seconds carry no sample. Tick rounding, not
        loss: ticks are ~1.02s apart on the pod's monotonic clock.
- [x] Confirm `tokio_rt_workers` reads 2 on the new meshed pods
      - `tokio_rt_workers 2` on both, and `LINKERD2_PROXY_CORES_MAX=2`
        in both proxies' env
      - the injector also sets `CORES=1` and `CORES_MIN=1`; the runtime
        honoured CORES_MAX, as it did at 3
      - the proxy sidecar's `resources` are `{}`, so **nothing but the
        tokio worker count enforces the pin**. There is no CPU limit
        behind it.
      - the union rule was load-bearing again: the proxy is in
        `.spec.initContainers` with `restartPolicy: Always`, not in
        `.spec.containers`
- [x] Report whether the proxy crossed 200% of one core, per pod and
      summed, and where it plateaued
      - **it did not. Zero rows above 200.0, highest single proxy sample
        119.24% on 7rspj at t_s 135.07.** Verified independently.
      - steady meshed window (rollout done -> load end, 52 ticks):
        proxy 7rspj mean 112.3 peak 119.2; bs9gr mean 70.7 peak 76.5
      - summed across both pods, proxy mean 183.0 peak 192.5. That is
        two proxies together against separate 2-core budgets, so it is
        not evidence of saturation.
      - controller, same window: 7rspj mean 56.1 peak 61.0; bs9gr mean
        36.9 peak 43.7, summed mean 93.0
      - unmeshed controller, steady pre-toggle window (60 ticks):
        hhqdg mean 49.4 peak 52.0; wlgds mean 52.2 peak 53.9, summed
        mean 101.6
      - **so meshing cost ~1.83 cores of proxy across two pods while
        app CPU stayed flat** (101.6 -> 93.0 summed mean)
      - load split unevenly, 7rspj carrying ~1.6x bs9gr on both
        containers. Two replicas behind one NodePort do not share
        evenly, which is itself why per-pod saturation is hard to reach.
      - the 79.2 peak on an unmeshed controller belongs to the **roll**
        window, not steady state: one surviving old pod briefly took
        the whole load. Do not quote it as an unmeshed figure.
- [x] Record what changed rather than restoring
      - **not restored, deliberately**: tasks 19 and 20 built on this
        state, so restoring between them would have destroyed the setup
        each one needed.
      - net change over the session: haproxy 2 replicas meshed at
        CORES_MAX=3 -> 1 replica meshed at CORES_MAX=2; emojivoto
        web/emoji/voting 1 -> 5 replicas, still meshed at CORES_MAX=3;
        vote-bot 1 -> 0.
      - `init_1` to `init_8` rebuild the install defaults, and
        `dev_7_scale_workloads.sh 1 2` restores the replica counts.

## 18. `dev_2_mesh_haproxy.sh unmesh` unpins the NodePort

Found 2026-09-17 while planning task 17, before running anything.

`unmesh` runs `helm upgrade --reset-values`, which drops **all**
user-supplied values. `init_7_install_haproxy.sh` pins the NodePort with
`--set controller.service.nodePorts.http=${HAPROXY_NODEPORT:-31080}`
precisely because an unpinned port moves on every reinstall and silently
broke the load-test URL once already. So unmesh undoes the fix init_7
exists to apply.

The checklist already warns that `--reset-values` "would reset every
user-set helm value, not just the inject annotation" in task 2, but
records it as a reason to leave haproxy alone rather than as a defect.

- [ ] Confirm the symptom: unmesh, then read the NodePort back
      - **not yet observed.** Inferred only, 2026-09-17: the chart
        default is `nodePorts: {}` with the comment "If empty, random
        ports will be used", so a bare `--reset-values` renders a
        Service with no http nodePort and helm's 3-way merge patches
        the pinned 31080 away.
      - the bare command was deliberately not run, because it would
        have broken the load URL task 17 needs. Confirming it properly
        means doing it when nothing is mid-measurement.
      - **dropped, not pending.** The fix is in and survived four
        upgrades across tasks 17, 19 and 20, reading 31080 every time.
        Reproducing the break would cost a cluster repair to prove what
        the chart's own default already states.
- [x] Decide the fix, and apply it
      - `dev_2_mesh_haproxy.sh` rewritten 2026-09-17. Both paths now
        write a values file and run one `helm upgrade --reset-values -f`,
        re-pinning the NodePort from `HAPROXY_NODEPORT` (default 31080,
        the same variable `init_7` uses).
      - `--reset-values` is kept, so the release state is whatever the
        script just said it is rather than a merge with what a previous
        run left behind. The narrower fix, unsetting only the inject
        annotation, would have given that up.
      - it also takes an optional CORES argument, so mesh and the core
        pin are one rollout. Meshing and then patching cores would roll
        the pods twice inside one measurement window, the second roll
        landing in the middle of the meshed plateau.
      - it now verifies its own result: mesh state from the union of
        initContainers and containers, and the NodePort read back.
- [x] Check whether anything else is lost the same way
      - **tested 2026-09-17 rather than asserted. Both directions
        measured, and the rule I had written down was wrong.**
      - **The discriminator is whether the chart RENDERS the field**,
        not whether the change was made outside helm.
      - `replicas` is rendered, so it is reconciled against the live
        object and patched back even when the rendered value did not
        change between releases. Scaled to 1 by hand, then a
        byte-identical `--reset-values` upgrade, and it returned to the
        chart's 2. `dev_2`'s live read-back is therefore needed.
      - the `config.linkerd.io/proxy-additional-env` annotation that
        `dev_3_modify_linkerd_cores.sh` writes is rendered by neither
        the old nor the new manifest, so helm leaves it alone. It
        survived three separate `--reset-values` upgrades, and in the
        decisive one **the pod was not even replaced**: same pod, age
        still counting, so no pod-template patch was sent at all.
      - **consequence, and it settled the script design**: pin cores
        once with `dev_3` and later mesh toggles keep them. One rollout,
        no yaml change, and `dev_2` stays purely about meshing.
      - the NodePort case is different again and still stands: that
        value WAS helm-managed, so `--reset-values` legitimately dropped
        it from the new manifest.
      - superseded claim, kept so the error is visible: 
      - the reasoning was that `kubectl scale` is invisible to helm and
        the chart default is 2, so a toggle would scale the ingress back
        to 2 mid-measurement. But helm 3's three-way merge only removes
        what was in the previous manifest and is absent from the new
        one, and a `kubectl scale` is in neither, so it may survive
        untouched.
      - `dev_2` was changed to read live `.spec.replicas` and write it
        back. That is harmless either way, but it may be solving nothing.
      - **blocks nothing, but it decides task 20's rollout count**: if an
        out-of-band change survives, `dev_3` can pin cores once and a
        later toggle keeps them, so a toggle costs one rollout, not two.
      - the test, three rollouts: drop cores from helm values; set them
        with `dev_3` via kubectl; run another `--reset-values` upgrade
        and read back both the annotation and the replica count.
        Deferred while sampler runs were in flight on that deployment.


## 19. Measure at 2 ingress replicas and 5 emojivoto replicas

Task 17 could not push a 2-core proxy past 119% of a core. Two reasons,
both about shape rather than load level: the meshed emojivoto backend
capped throughput at ~14.7k rps, and two ingress replicas behind one
NodePort split that load unevenly, 1.6 to 1. So neither proxy saw enough
traffic to need its second core.

The first plan was one ingress replica, so a single proxy would take the
whole load. **Revised to two on the user's call**, because one replica
means the mesh toggle drops all traffic rather than half, and a hole in
the throughput is worse than a proxy that does not saturate. The uneven
1.6-to-1 split across two replicas therefore stays, and crossing 200% on
a single pod is correspondingly harder.

What does change: **five replicas of each emojivoto workload**, so the
backend stops being the ceiling that capped throughput at ~14.7k rps,
and **vote-bot scaled to 0**, so nothing puts untracked traffic on
web-svc underneath the measurement. Load stays at 500 connections, which
is where throughput peaked in the sweep.

### Setup, run before the measurement

- [x] `VOTE_BOT_REPLICAS=0 ./dev_7_scale_workloads.sh 5 2`
      - done 2026-09-17. All five rollouts succeeded.
      - first run was `./dev_7_scale_workloads.sh 5 1`, superseded by
        the revision to two ingress replicas and vote-bot 0
      - `rollout status` on a 0-replica deployment returns immediately
        rather than hanging, which was the risk in scaling vote-bot to 0
      - cosmetic: the READY column prints `<none>` for vote-bot, because
        `.status.readyReplicas` is absent rather than 0 when a
        deployment is scaled to zero
- [x] `./dev_2_mesh_haproxy.sh unmesh`
      - helm revision 5. Replica count preserved at 1, which is the
        point of the task 18 fix: without it the chart default of 2
        would have come back.
- [x] Confirm 2 haproxy pods, unmeshed, NodePort still 31080, emojivoto
      5/5, vote-bot 0, ingress 200 on `/api/list`
      - verified: pods `...-5f79678c95-gl4db` and `-s4p2x` both Running,
        `linkerd-proxy` in neither container list on either; nodePort
        31080; 15 emojivoto pods, all meshed, none unmeshed; 0 vote-bot
        pods; `/api/list` 200
      - **node background load is 0.38 of 15 cores** with vote-bot at 0
      - it was 0.42-0.51 with vote-bot at 5, so the 5 generators cost
        only ~0.05-0.13 cores. Removing them changed the background
        less than expected; they were never the noise floor.
- [x] Fix `dev_2`'s verification listing terminating pods
      - found running the setup: `kubectl rollout status` returns while
        the old pod is still in the API listing carrying the OLD mesh
        state, so unmesh printed a stray `meshed` line for a pod that
        was draining
      - the check was right and the pod set was wrong. It now skips
        pods with a `deletionTimestamp`.

### The run, three terminals

The separation is the point: the sampler never generates load, the load
driver never touches mesh state, and neither takes the other as an
argument.

    term 1   cd scripts && RESOLVE_INTERVAL=2 \
               ./dev_5_measure_start.sh <run-name> haproxy-controller \
               deploy/haproxy-ingress-kubernetes-ingress

    term 2   cd scripts && ./test_load_2_docker_nodeport.sh 500 150s \
               http://172.18.0.2:31080/api/list

    term 3   # at roughly 55s into the load, to mesh mid-run at 2 cores
             cd scripts && ./dev_2_mesh_haproxy.sh mesh
             # cores are already pinned and survive the toggle; if they
             # are not, pin them once beforehand with
             #   ./dev_3_modify_linkerd_cores.sh haproxy-controller \
             #     deploy/haproxy-ingress-kubernetes-ingress 2
             # after the load finishes
             cd scripts && ./dev_6_measure_stop.sh

- [x] Run done 2026-09-17 as run `manual`, CSV at
      `~/.cache/kube-cpu-sampler/manual.csv`
      - 539 rows: 531 `sample`, 6 `first`, 2 `roll`. 4 pods, 6 container
        ids. Load 500 conns/150s: **17,095 rps avg** (up from 13,140
        with a 1-replica backend), 2,564,081 2xx, latency p50 23.54ms
        p99 112.20ms, 177 `connection refused` across the roll.
- [x] **The proxy did not cross 200%. Highest single proxy sample
      109.64% of a core**, on 5pdv2 at t_s 154.56. Zero rows above 200.
      - fully meshed and under load, t_s 152.47-164.98, 13 ticks:
        5pdv2 proxy mean 101.7 peak 109.6; vdhsq proxy mean 96.4 peak
        102.3; app containers 49.2 and 48.9 mean
      - summed proxy mean 198.1 peak 205.4. **Two proxies against two
        separate 2-core budgets, so this is not a ceiling reading.**
        Quoting it as one would repeat task 17's mistake.
      - unmeshed under load, t_s 12-70, 56 ticks: app 63.7 and 59.8
        mean, 123.5 summed
      - **so meshing took the ingress from ~123.5% of a core to ~296%**
        (98.1 app + 198.1 proxy), and app CPU *fell* as the proxy took
        over the connection work
- [x] **The uneven split is fixed, and it was not the reason.**
      - 101.7 vs 96.4, a 1.05-to-1 split, against 1.6-to-1 in task 17.
        Scaling the backend to 5 replicas evened it out.
      - so the proxy is not starved by imbalance. At 17k rps it runs at
        about 55% of its 2-core budget because that is all it needs.
      - extrapolation: at 2 replicas each proxy carries ~102%, so **1
        replica would carry roughly double and land right at 200%.**
        That is the change that would test the ceiling.
- [x] **Does the proxy spike when the mesh lands? No.** It is a step,
      and it is gated by the old pod dying, not by meshing.
      - **before the mesh the proxy does not exist.** No rows at all,
        which the CSV distinguishes from a zero sample. There is no
        "0 before" to plot; there is an absence.
      - **it then idles at ~0 for ~40s while Running and Ready.** 5pdv2's
        proxy was born t_s 71.93 and read 0.00-0.18% every tick to
        110.56. vdhsq's was born 112.74 and read ~0 to 150.38.
      - **it steps to plateau in ONE tick, at the exact tick the pod it
        replaced stops serving.** 5pdv2 proxy 0.18 -> 51.02 at t_s
        111.67 while gl4db fell 71.89 -> 12.29. vdhsq proxy 17.73 ->
        100.54 at 152.47 while s4p2x fell 85.64 -> 0.11.
      - **cause: connection pinning.** bombardier holds 500 long-lived
        keep-alive connections and conntrack keeps each on the pod it
        was established with. A freshly meshed pod is Ready and gets
        nothing until the old pod is terminated and the connections
        re-establish.
      - **no overshoot.** 5pdv2 settled ~60% while still sharing with an
        unmeshed pod, rising to ~101% only when that pod went. The run
        peak of 109.64 is an ordinary sample inside the final plateau,
        not a startup transient.
      - consequence for any future toggle run: the interesting moment is
        not the helm upgrade, it is the old pod's termination, and the
        two are ~40s apart here
- [x] **Defect in this run's design: the fully meshed window is 13 of
      165 ticks.** Everything else was a mixed state.
      - the rollout is staggered. First replica meshed at t_s 71.9, the
        second only at t_s 113.8, and the last unmeshed pod kept serving
        until t_s 152.5.
      - between t_s 148 and 151 the unmeshed pod was drawing ~90% app
        CPU while the meshed pod's proxy sat at ~62%, so traffic was not
        evenly split during the transition either
      - a 150s load run is barely long enough. Either fire the toggle
        earlier than 55s, or run the load longer, so the meshed plateau
        rests on more than 13 samples.
      - the sampler was stopped while load was still running, so the
        tail is all valid. Verified tick by tick rather than assumed.
- [x] Pick a run name that is not already used
      - `start` refuses a reused name before taking a sample, so a
        collision costs nothing but a retype. Taken so far: smoketest,
        task5-toggle, test, toggle-unmesh-to-mesh, unmeshed-web,
        val4-meshed, val4-unmeshed, val4-unmeshed-b,
        t17-haproxy-toggle-2core.
- [x] Let the sampler take ~10s of idle baseline before starting load
- [x] Record the wall-clock epoch of the mesh command, so the CSV can be
      read against it
- [x] Report peak and mean proxy `cpu_pct_core` per pod
      - **per pod, not summed.** Each proxy has its own 2-core budget,
        so only a single pod's number is comparable to 200%. Task 17's
        summed 192.5% peak looked close to the ceiling and meant
        nothing.
      - report the split between the two pods as well, since it bounds
        how close the busier one could ever get
- [x] Say whether it crossed 200%, and if not, what the new ceiling was
      - it did not: plateau 101.7% and 96.4% per pod, peak 109.6%

### What to watch out for

- **vote-bot is at 0**, so nothing but the load driver is putting traffic
  on web-svc. It cost less than expected: ~0.05-0.13 of a core.
- **Two ingress replicas cover for each other across the roll**, which is
  why they were kept. Task 17 logged 277 connection refusals this way,
  a dip rather than a hole.
- **The cost of that choice is the uneven split.** Task 17 measured
  1.6 to 1 between the two replicas, so the busier proxy sees well under
  half the total. If this run also fails to cross 200%, the split is the
  first thing to suspect, not the load level.
- The proxy's `resources` stay `{}`, so the 2-core pin is the tokio
  worker count and nothing else. No CPU limit enforces it.


## 20. Measure at 1 ingress replica and 1000 connections

Task 19 settled why 2 cores was out of reach, and it was not imbalance
or the backend: with the split evened out at 1.05 to 1 and the backend at
5 replicas, each ingress proxy still ran at ~102% of a core, about half
its budget. The extrapolation from that is direct: **one replica carries
roughly double, which lands at ~200%.** This run tests it.

Two changes from task 19, both on the user's call: **one ingress
replica**, accepting that the toggle drops all traffic rather than half,
and **1000 connections** instead of 500.

The 1000-connection figure needs checking rather than assuming. The
sweep in task 17 found 1000 conns *worse* than 500 (12,864 vs 14,676
rps, with p50 latency doubling and no throughput gain), but that was
against a 1-replica backend which was itself the bottleneck. With the
backend at 5 replicas that ceiling has moved, and task 19 already
measured 17,095 rps at 500 conns against the old 14,676. Whether 1000
now buys throughput or just queues is unmeasured.

### Setup, done 2026-09-17

- [x] `VOTE_BOT_REPLICAS=0 ./dev_7_scale_workloads.sh 5 1`
- [x] `./dev_2_mesh_haproxy.sh unmesh`
- [x] Verified: haproxy pod `...-5f79678c95-vzkrv` Running, unmeshed,
      `linkerd-proxy` in neither container list; nodePort 31080; 15
      emojivoto pods, all meshed; `/api/list` 200
- [x] `dev_2`'s verification no longer lists terminating pods
      - it printed exactly one pod with no stray `meshed` line, which is
        the fix from task 19 working

### The run, three terminals

    term 1   cd scripts && RESOLVE_INTERVAL=2 \
               ./dev_5_measure_start.sh <run-name> haproxy-controller \
               deploy/haproxy-ingress-kubernetes-ingress

    term 2   cd scripts && ./test_load_2_docker_nodeport.sh 1000 150s \
               http://172.18.0.2:31080/api/list

    term 3   # at roughly 40s into the load
             cd scripts && ./dev_2_mesh_haproxy.sh mesh
             # cores are already pinned and survive the toggle; if they
             # are not, pin them once beforehand with
             #   ./dev_3_modify_linkerd_cores.sh haproxy-controller \
             #     deploy/haproxy-ingress-kubernetes-ingress 2
             # after the load finishes
             cd scripts && ./dev_6_measure_stop.sh

- [x] Run done 2026-09-17 as `ingress_1_conn_1000`, CSV at
      `~/.cache/kube-cpu-sampler/ingress_1_conn_1000.csv`
      - 207 rows: 203 `sample`, 3 `first`, 1 `roll`. 2 pods, 3 containers.
- [x] **Still under 200%. Proxy mean 161.0%, peak 169.0%** over the
      48-tick meshed plateau (t_s 80-128.9). Zero rows above 200.
      27 of 64 proxy ticks were above 160%.
      - app container: unmeshed mean 128.8 peak 149.3 (68 ticks);
        meshed mean 69.8 peak 78.3
      - **so the ingress went from ~129% of a core to ~231%** (69.8 app
        + 161.0 proxy), and app CPU almost halved as the proxy took over
        the connection work. Same direction as task 19, larger in
        absolute terms because one pod carries everything.
- [x] **1000 connections did not buy throughput. It queued.**
      - 15,079 rps against task 19's **17,095 at 500 conns**, a 12%
        loss, with p50 latency 54.31ms against 23.54ms and max 2.43s
      - same signature the task 17 sweep found at 1000 conns, and it
        survived the backend going to 5 replicas: the extra connections
        only sit in a queue
      - 2,260,554 2xx, and **1012 connection refusals** against task
        19's 177, as expected with no second replica to cover the roll
- [x] **Why 161% and not the predicted ~200%.** The prediction assumed
      throughput would hold, and it did not.
      - scaling task 19's summed 198.1% by the throughput actually
        delivered gives 198.1 x (15079/17095) = 174.8%, against 161.0%
        measured. One proxy is slightly cheaper than two at equal
        request rate, not dearer.
      - per request the two runs agree closely: 115.9 uCPU/req at 2
        replicas/500 conns, 106.8 at 1 replica/1000 conns
      - **so the ceiling was never a concurrency problem. It is a
        throughput problem**, and 1000 conns moved throughput the wrong
        way. The untested point is 1 replica at 500 conns, which is
        where throughput peaked.
- [x] Toggle at ~40s, not 55s
      - handover took ~13s here against ~40s in task 19, as predicted:
        the new pod was born t_s 63.59 and the old one stopped serving
        at t_s 77.25
      - that gave a 48-tick meshed plateau against task 19's 13
      - task 19 fired at 55s and got only 13 fully-meshed ticks out of
        165, because the handover lagged the helm upgrade by ~40s
      - with one replica the handover should be faster: the rollout
        surges to 2 pods, then terminates the old one as soon as the new
        is Ready, rather than rolling one replica at a time
- [x] The handover confirmed task 19's no-spike finding again
      - proxy read 0.44 to 0.14 from birth at t_s 63.59 through 76.21,
        then 120.20 at 77.25, 146.11 at 78.28, 151.27 at 79.32, settling
        ~161%. A three-tick ramp to plateau, no overshoot.
      - the old pod fell 113.35 -> 34.54 -> 0.14 across the same ticks

### What to expect

- **All traffic drops across the roll**, not half. Task 19 logged 177
  connection refusals with a second replica covering; expect a hole in
  the throughput here rather than a dip, and expect bombardier's
  aggregate rps to be dragged down by it.
- **The proxy will read ~0 until the old pod is terminated**, then step
  to its plateau in one tick. Task 19 established this: a meshed pod is
  Ready and receiving nothing while conntrack holds the existing
  connections on the old pod. Do not read that zero as the proxy being
  idle under load.
- bombardier still reports one aggregate over both states, so the
  unmeshed and meshed request rates cannot be separated from it.


## 21. Reformat every script comment for human readers

One house style for every comment block: a short summary of what the
thing does, then the reasoning for why it is necessary. Summary first so
a reader skimming gets the what without the why.

The scripts carry a lot of hard-won reasoning and it is currently mixed
in with the description at the same level, so both are slower to read
than they need to be.

Scope: the 26 `.sh` and `.yaml` files in `scripts/`, excluding
`wip_1_proxy_runtime.sh` and `wip_2_hop_latency.sh`, which this
checklist has always treated as reference only.

- [ ] Agree the format
      - line 1: what it does, one sentence
      - blank comment line
      - then why, and what breaks without it
- [ ] Reformat `init_*` (9 files)
- [ ] Reformat `dev_*` (7 files)
- [ ] Reformat `pf_*`, `test_load_*`, `cleanup_*`, `util_measure.sh` (7)
- [ ] No code changes, no facts dropped
      - the comments record measurements and dates; rewording must not
        lose a number or a date


## Context

- **VM**: public IP 20.245.114.144, SSH alias `dev`, login user `apoorv`.
  Ubuntu 24.04.4 LTS, kernel 6.17.0-1022-azure, x86_64, 8 vCPU, 31 GiB
  RAM, 172G free disk. Resource group and subscription still unrecorded.
- **The VM persists between sessions.** The kind cluster does not: it is
  created and torn down per run, so setup and teardown are both hot paths.
- **8 vCPU is the CPU ceiling**: 800% of one core, shared with a k3d
  cluster and a `vsc-linkerd2-proxy` devcontainer that both stay running.
- **Laptop-to-VM RTT is 30.5ms** (min 26.5, max 36.3, 0% loss). Every
  latency number driven from the laptop sits on top of this.
- **NSG**: a rule is in place for this laptop. ICMP passes.
- **Architecture**: VM is x86/amd64, laptop is Darwin arm64. Nothing built
  locally transfers.
- **Scripts run on the VM**, except the load driver, which runs on the
  laptop. Settled in task 26 of `checklist_repro_kube_setup.md`.
- **The `wip_` scripts are reference only.** New scripts sit alongside.
  `wip_1` is a one-shot snapshot, `wip_2` and `wip_3` bracket and diff,
  `wip_4` is the only continuous sampler. All four start their own load.
- **Nothing is version-pinned**, so the VM and the laptop may differ.
- **The laptop's reference numbers**: 53.4k RPS unmeshed, 23.7k meshed at
  c125/30s, p50 1.75ms to 5.01ms, from `checklist_load_test_linkerd.md`.
  Measured from a container on the `kind` network, not over a WAN, so not
  directly comparable to anything driven from the laptop against the VM.
- **Measurement rules** live in `knowledge.md` and apply unchanged:
  bracket with two counter snapshots, divide by measured elapsed,
  `tokio_rt_busy_seconds_total` is not CPU, cAdvisor lags.

## Open questions

- What is the unmeshed CPU source? Blocks task 3, and therefore
  everything downstream. cgroup `cpu.stat` over `docker exec` is the
  candidate because it has no lag, but it is unvalidated. This is task 2.
- ~~Is there a usable cluster on the laptop right now?~~ Answered: yes.
  `kind-kind` is up with emojivoto, haproxy-controller, linkerd,
  linkerd-viz, grafana and headlamp all Running. Task 4 needs no rebuild.
- Does the sampler need to survive a mesh toggle, or is restarting it
  between states acceptable? Changes how much work task 3 is. Noted in
  task 4.
- Which subscription and resource group is the VM in? Blocks nothing
  until an `az` command is needed. Noted in task 1.
