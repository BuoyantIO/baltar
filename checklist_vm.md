# Running the cluster and the CPU measurement on the Azure VM

Goal: reproduce the laptop's measurement setup on the Azure VM and take
meshed and unmeshed CPU numbers there, with load driven from the laptop
over the public IP.

Moved out of `checklist_mvp.md` tasks 7 to 13, which are closed there
with a pointer here. The measurement design, the sampler and the load
driver are all settled and unchanged; nothing in this file revisits them.

## Tasks

- [ ] 1. Decide and record how the repo reaches the VM
- [ ] 2. Get the repo onto the VM
- [ ] 3. Install the linkerd CLI on the VM
- [ ] 4. Resolve yq on the VM
- [ ] 5. Decide whether bombardier is needed on the VM
- [ ] 6. Run init_0_prerequisites.sh on the VM and record versions
- [ ] 7. Create the kind cluster on the VM
- [ ] 8. Install linkerd and linkerd-viz on the VM
- [ ] 9. Deploy emojivoto and the haproxy ingress on the VM
- [ ] 10. Install the cpu-probe DaemonSet on the VM
- [ ] 11. Confirm the ingress answers from the VM itself
- [ ] 12. Reach the ingress from the laptop over the public IP
- [ ] 13. Confirm the sampler runs on Ubuntu x86_64
- [ ] 14. Scale the workloads to the measurement shape
- [ ] 15. Measure the unmeshed baseline on the VM
- [ ] 16. Measure meshed on the VM
- [ ] 17. Record the comparison
- [ ] 18. Confirm teardown is clean and leaves the VM's other work alone
- [ ] 19. Record the VM's Azure resource group and subscription

## 1. Decide and record how the repo reaches the VM

This repo has no git remote, so a clone is not available without pushing
it somewhere first. Confirm that with `git remote -v` in
`/Users/apoorv/projects/kube`; expect empty output.

Tasks 15 and 16 will iterate on scripts, so the method has to be
repeatable and cheap, not a one-off copy.

Use rsync over the existing `ssh dev` alias, include `.git` so the VM
copy is a real checkout, and record the exact command in this section so
later syncs are the same command. Do not set up a remote or a bare repo
unless rsync turns out not to work.

Done when the command is written down here and the choice justified in
one line.

## 2. Get the repo onto the VM

Preconditions: task 1 decided. `ssh -o BatchMode=yes -o ConnectTimeout=8 dev`
returns without a prompt.

Confirm there is no existing checkout first:

    ssh dev 'ls ~/projects/kube 2>/dev/null || echo "absent"'

`~/projects` on the VM holds `dev`, `enterprise-linkerd`, `j5j`,
`linkerd2`, `linkerd2-proxy`. None of those may be touched.

Then sync:

    rsync -az --delete /Users/apoorv/projects/kube/ dev:~/projects/kube/

Verify by comparing the script inventory on both sides, not by trusting
rsync's exit code:

    ls /Users/apoorv/projects/kube/scripts | sort > /tmp/local_scripts
    ssh dev 'ls ~/projects/kube/scripts | sort' > /tmp/vm_scripts
    diff /tmp/local_scripts /tmp/vm_scripts

Expect no output. Then confirm the `.sh` files are executable on the VM:

    ssh dev 'ls -l ~/projects/kube/scripts/*.sh | grep -cv "^-rwx"'

Expect `0`.

Done when the diff is empty and every `.sh` is executable.

## 3. Install the linkerd CLI on the VM

`init_2`, `init_3`, `dev_1_mesh_emojivoto.sh` and
`dev_4_inspect_cores.sh` all shell out to `linkerd`, so nothing after
task 8 works without it.

The binary already exists at `~/.linkerd2/bin/linkerd` on the VM
(`linkerd-edge-26.9.1`, observed 2026-09-17) but is NOT on PATH. That is
the actual problem to solve, so check before installing anything:

    ssh dev 'ls ~/.linkerd2/bin; command -v linkerd || echo "not on PATH"'

PATH has to be set for NON-INTERACTIVE ssh, not only login shells,
because every later task drives the VM as `ssh dev '<command>'`. A line
in `~/.bashrc` guarded by the usual non-interactive early return will
not take effect. Put it where non-interactive ssh reads it, or symlink
the binary into `/usr/local/bin`.

The single test that matters:

    ssh dev 'linkerd version --client'

Done when that prints a version with no PATH manipulation in the command.

## 4. Resolve yq on the VM

`/usr/bin/yq` exists on the VM (observed 2026-09-17), which contradicts
the earlier record that yq was absent. It is most likely the Debian
python wrapper, whose syntax is incompatible with the Go (mikefarah) yq
the scripts are written against.

First find out whether anything actually needs it:

    grep -rn '\byq\b' /Users/apoorv/projects/kube/scripts/

If nothing outside comments uses it, record that and skip the install.

If something does, identify the flavour:

    ssh dev 'yq --version'

The Go flavour prints something like `yq (https://github.com/mikefarah/yq/) version v4.x`.
The python wrapper prints a bare version and accepts different syntax.
If it is the wrapper, install the Go binary somewhere earlier on PATH
rather than removing `/usr/bin/yq`, which is a distribution package and
may be depended on by something else on this shared VM.

Done when either "nothing needs yq" is recorded, or `yq --version`
reports the Go flavour.

## 5. Decide whether bombardier is needed on the VM

`test_load_2_docker_nodeport.sh` runs `alpine/bombardier` in a Docker
container, so the host binary is not needed for it. The plan also drives
load from the LAPTOP against the VM's public IP, which means the
generator does not run on the VM at all in the main measurement.

The exception worth considering: task 17 wants a VM-local load run as a
no-network reference, so the WAN cost can be separated from the mesh
cost. That run still uses the Docker container, so it still does not need
a host binary.

Expected outcome: not needed, do not install. Record the reasoning.

## 6. Run init_0_prerequisites.sh on the VM and record versions

This is the real prerequisite check. The ad-hoc inventory taken earlier
was wrong about yq, which is exactly why this exists.

    ssh dev 'cd ~/projects/kube/scripts && ./init_0_prerequisites.sh; echo "exit=$?"'

The script is already Linux-aware and reports macOS-only tools as `n/a`.

Record its full verdict and exit code in this section, plus the version
of every tool it names. Nothing in this repo is version-pinned, so the
VM and the laptop can differ and that difference has to be visible when
a number looks wrong later.

Done when exit is 0 and the versions are written down here.

## 7. Create the kind cluster on the VM

Preconditions: tasks 2, 3 and 6 done.

    ssh dev 'cd ~/projects/kube/scripts && KIND_LISTEN_ADDRESS=0.0.0.0 ./init_1_create_cluster.sh'

`KIND_LISTEN_ADDRESS=0.0.0.0` is the only VM-specific input. The
committed `init_1_create_cluster.yaml` binds the published NodePort to
loopback, which would make task 12 impossible.

Do NOT touch the k3d cluster `k3d-deep-server-0` or the devcontainer
`recursing_fermi`. Both persist between sessions and belong to other
work. Confirm both are still running afterwards:

    ssh dev 'docker ps --format "{{.Names}}"'

There is no port conflict to fear: k3d publishes only
`0.0.0.0:36971->6443/tcp`, and nothing listens on 80, 443, 6443, 8080 or
31080.

Capture wall-clock time for the whole init sequence against the laptop's
5m7s, and record it in task 11.

Done when `kubectl get nodes` on the VM shows the node Ready.

## 8. Install linkerd and linkerd-viz on the VM

    ssh dev 'cd ~/projects/kube/scripts && ./init_2_install_linkerd.sh && ./init_3_install_linkerd_viz.sh'

Skip `init_4_install_grafana.sh` and `init_5_install_headlamp.sh`. They
install dashboards, nothing reads them in this measurement, and
checklist_mvp task 16 dropped Grafana publishing. Record that they were
skipped deliberately so a later reader does not think the setup is
incomplete.

`init_2` ends on `linkerd check`. If it fails on the `linkerd-trust`
extension the way it does on the laptop, that is a local-binary problem
and should not exist on the VM; if it appears there too, record it and
check whether the VM has its own `linkerd-trust` binary.

Watch for linkerd-viz coming up half-injected, which has happened on the
laptop after a race with the injector. Check the readiness columns:

    ssh dev 'kubectl get pods -n linkerd-viz'

Done when all linkerd and linkerd-viz pods are Ready.

## 9. Deploy emojivoto and the haproxy ingress on the VM

    ssh dev 'cd ~/projects/kube/scripts && ./init_6_deploy_emojivoto.sh && ./init_7_install_haproxy.sh'

`init_6` must run before `init_7`, because `init_7` creates an Ingress
pointing at `web-svc`.

emojivoto arrives unmeshed from `init_6`. That is the correct starting
state for task 15.

`init_7` pins the NodePort to 31080 via
`--set controller.service.nodePorts.http`. Confirm it took, because task
12's URL depends on it:

    ssh dev 'kubectl get svc -n haproxy-controller haproxy-ingress-kubernetes-ingress -o jsonpath="{.spec.ports[?(@.port==80)].nodePort}"'

Done when that prints 31080 and all emojivoto and haproxy pods are Ready.

## 10. Install the cpu-probe DaemonSet on the VM

    ssh dev 'cd ~/projects/kube/scripts && ./init_8_install_cpu_probe.sh'

Every CPU number in tasks 15 and 16 is read through this. The script
verifies the cgroup mount itself rather than trusting Ready, because a
Ready pod with the wrong cgroup tree looks identical.

Expect output of the form `cpu-probe-<id> sees N container cgroups`.

PID 1 in the pod is a trapping shell loop, not `sleep infinity`, so it
reaps orphaned children. If the VM's copy predates that fix, re-sync
(task 2) before running this.

Done when the script reports a non-zero cgroup count.

## 11. Confirm the ingress answers from the VM itself

On Linux the Docker bridge is routable from the host, unlike macOS, so
this works directly and needs no container:

    ssh dev 'curl -s -o /dev/null -w "%{http_code}\n" http://172.18.0.2:31080/api/list'

Confirm the node IP first rather than assuming 172.18.0.2:

    ssh dev 'kubectl get node kind-control-plane -o jsonpath="{.status.addresses[?(@.type==\"InternalIP\")].address}"'

Use `/api/list`, not `/`. `/` is a 560-byte static page that makes no
backend calls and does not exercise the mesh's RPC path. `/api/list`
fans out to emoji-svc and returns roughly 4.5KB.

Record the wall-clock time for tasks 7 to 10 here, against the laptop's
5m7s.

Done when the curl returns 200 from the VM.

## 12. Reach the ingress from the laptop over the public IP

kind publishes the NodePort on the VM's host interface via
`extraPortMappings`, and an NSG rule scoped to this laptop is already in
place. No userspace relay is in the data path, which matters: the local
socat analogue halved throughput and raised p50 six-fold.

Confirm the port is actually published on the host interface:

    ssh dev 'ss -ltn | grep 31080'

Then from the laptop:

    curl -s -o /dev/null -w "%{http_code} %{time_total}\n" http://20.245.114.144:31080/api/list

Record the TCP round trip under the port actually used. ICMP already
passes at 30.5ms average (min 26.5, max 36.3, 0% loss), and that 30.5ms
is the floor under every laptop-driven number.

If this fails, the recorded fallback is an SSH tunnel, but it changes
what is being measured and every number taken through it has to say so.
Try the direct path first and only fall back with a note.

Done when the laptop gets a 200 and the RTT is recorded here.

## 13. Confirm the sampler runs on Ubuntu x86_64

The sampler has only ever run on Darwin arm64. The in-pod collector runs
inside a busybox pod either way, so the risk is in the laptop-side
script, not the loop.

The scripts will run ON the VM, so the "laptop-side" half runs under
Ubuntu's bash and coreutils here. Specific things that differ from macOS
and are worth checking: `date` flags, `awk` flavour (gawk vs BWK), and
the bash version, since `util_measure.sh` carries a bash 3.2 workaround
that a newer bash does not need but must not break on.

Take a short run against an idle workload, with no load test:

    ssh dev 'cd ~/projects/kube/scripts && ./dev_5_measure_start.sh vmsmoke emojivoto deploy/web' &
    sleep 15
    ssh dev 'cd ~/projects/kube/scripts && ./dev_6_measure_stop.sh'

Verify the CSV has sample rows, the intervals are close to 1.0s, and
there are no gap or reconnect events:

    ssh dev 'awk -F, "NR>1{print \$14}" ~/.cache/kube-cpu-sampler/vmsmoke.csv | sort | uniq -c'

Clean up the `vmsmoke.*` files afterwards.

Done when a run produces a CSV with sample rows and no gaps, and any
script change needed to get there is recorded here and synced back to
the laptop copy.

## 14. Scale the workloads to the measurement shape

    ssh dev 'cd ~/projects/kube/scripts && VOTE_BOT_REPLICAS=0 ./dev_7_scale_workloads.sh 5 2'

vote-bot must be 0. It generates continuous traffic against web-svc
underneath whatever the load driver does, which is noise in a CPU
measurement.

The 8 vCPU ceiling is the reason this shape may need revisiting. The
laptop's cluster had 15 CPUs and the same shape drew about 9.3 of them
under load, so the VM has materially less headroom and is shared with
the k3d cluster and the devcontainer. If the node saturates, reduce the
emojivoto replica count rather than the connection count, and record
what was used.

Done when the deployments report their target replica counts Ready.

## 15. Measure the unmeshed baseline on the VM

Preconditions: tasks 12, 13 and 14 done.

Confirm both emojivoto and haproxy are unmeshed first, using the UNION
of `.spec.initContainers[]` and `.spec.containers[]`. The proxy is a
native sidecar, so a containers-only check reports a meshed pod as
unmeshed:

    ssh dev 'kubectl get pods -n emojivoto -o json | jq -r ".items[] | select(.metadata.deletionTimestamp==null) | [.metadata.name, ((((.spec.initContainers//[])+(.spec.containers//[]))|map(.name)|index(\"linkerd-proxy\"))|if .==null then \"unmeshed\" else \"meshed\" end)] | @tsv"'

If either is meshed, unmesh with `./dev_1_mesh_emojivoto.sh unmesh` and
`./dev_2_mesh_haproxy.sh unmesh`.

Three separate processes, in three terminals. The sampler generates no
load and the load driver knows nothing about the sampler:

    on the VM:      cd ~/projects/kube/scripts && RESOLVE_INTERVAL=2 \
                      ./dev_5_measure_start.sh vm-unmeshed haproxy-controller \
                      deploy/haproxy-ingress-kubernetes-ingress
    on the laptop:  cd scripts && ./test_load_2_docker_nodeport.sh 500 150s \
                      http://20.245.114.144:31080/api/list
    on the VM:      cd ~/projects/kube/scripts && ./dev_6_measure_stop.sh

Give the sampler about 10s of idle before starting the load.

Record together: the CSV path, mean and peak `cpu_pct_core` for the app
container, the bombardier result (rps, 2xx, latency distribution), and
what the number covers. Unmeshed there is no proxy, so the figure is the
app container alone.

Also record whether the k3d cluster or the devcontainer were busy during
the run, since they share the 8 vCPU and will skew the result:

    ssh dev 'docker stats --no-stream --format "{{.Name}} {{.CPUPerc}}"'

Done when the CSV, the load result and the VM load conditions are all
written into this section.

## 16. Measure meshed on the VM

Mesh both, then pin the proxy cores:

    ssh dev 'cd ~/projects/kube/scripts && ./dev_1_mesh_emojivoto.sh mesh && ./dev_2_mesh_haproxy.sh mesh'
    ssh dev 'cd ~/projects/kube/scripts && ./dev_3_modify_linkerd_cores.sh haproxy-controller deploy/haproxy-ingress-kubernetes-ingress 2'

Pin cores with `dev_3` and nothing else. The annotation it writes is
rendered by neither helm manifest, so it survives later mesh toggles;
this was measured on the laptop, not assumed.

Confirm the pin took, using all four views, because they can disagree:

    ssh dev 'cd ~/projects/kube/scripts && ./dev_4_inspect_cores.sh haproxy-controller deploy/haproxy-ingress-kubernetes-ingress'

`tokio_rt_workers` is the real worker count. Do not count threads named
"proxy".

Then run the identical load to task 15: same connections, same duration,
same URL, driven from the laptop. Use run name `vm-meshed`.

Record app CPU and proxy CPU separately. The `role` column is app or
proxy, which is what keeps the mesh's cost attributable. Record CORES_MAX
and how to undo it, since `dev_3` has no reset path: drop the annotation
with

    kubectl patch deploy/haproxy-ingress-kubernetes-ingress -n haproxy-controller --type merge \
      -p '{"spec":{"template":{"metadata":{"annotations":{"config.linkerd.io/proxy-additional-env":null}}}}}'

Record VM load conditions again as in task 15.

Done when both CPU figures, the load result and `tokio_rt_workers` are
written into this section.

## 17. Record the comparison

Run both states at 150s, not 30s. Five-second runs on the laptop left
plateaus resting on 4 to 5 samples, which is not enough for a figure with
a stated confidence.

Report, for meshed and unmeshed on the same VM under the same load:
throughput and 2xx rate, CPU per request, and mean and peak percent of a
core with the throughput stated alongside.

Lead with CPU per request. It needs no subtraction, so it is the stronger
comparison, and on the laptop it held steady at 115.9 and 106.8 uCPU/req
across two configurations whose percent-of-core figures differed wildly.

Report proxy CPU per pod, never summed across replicas. Each proxy has
its own core budget, and a summed 198% against a 2-core cap looks like
saturation while each proxy is at half.

Separating the mesh cost from the WAN cost needs a VM-local load run as
the no-network reference, driven from a container on the VM's `kind`
network. Without it the two are confounded and the write-up must say so.

For context, the laptop's numbers, which are NOT directly comparable
because they were driven from a container on the `kind` network rather
than over a WAN: 53.4k rps unmeshed and 23.7k meshed at c125/30s, p50
1.75ms to 5.01ms.

Promote anything durable to `knowledge.md` and leave run state here.

## 18. Confirm teardown is clean and leaves the VM's other work alone

The cluster is created and torn down per run, so teardown is a hot path,
not an afterthought.

    ssh dev 'cd ~/projects/kube/scripts && ./cleanup_1_cluster.sh'
    ssh dev 'docker ps --format "{{.Names}}"; kind get clusters'

`k3d-deep-server-0` and `recursing_fermi` must both still be running and
`kind get clusters` must not list ours. Anything else surviving is a
teardown bug and belongs in this section as a finding.

Feed any script that needed a change to run on Linux back into
`checklist_repro_kube_setup.md`.

## 19. Record the VM's Azure resource group and subscription

Carried over from checklist_mvp task 1, where it was the last open item
and blocked nothing.

Load the `buoyant-azure` skill before running any `az` command that
writes. This task only reads, but the skill also says which subscription
a bare `az` command lands in, which is the thing most likely to make a
read misleading.

Find the VM by its public IP 20.245.114.144 rather than by a guessed
name, then record the subscription name and id, the resource group, the
VM name and its size.

Done when all five are written here.

## Context

- **VM**: public IP 20.245.114.144, SSH alias `dev`, login user `apoorv`.
  Ubuntu 24.04.4 LTS, kernel 6.17.0-1022-azure, x86_64, 8 vCPU, 31 GiB
  RAM, 172G free disk.
- **8 vCPU is the ceiling**, 800% of one core, shared with a k3d cluster
  and a `vsc-linkerd2-proxy` devcontainer that both stay running. The
  laptop had 15 CPUs and drew about 9.3 of them under the same load, so
  headroom here is materially tighter.
- **The VM persists between sessions. The kind cluster does not**: it is
  created and torn down per run.
- **Laptop-to-VM RTT is 30.5ms** (min 26.5, max 36.3, 0% loss). Every
  latency number driven from the laptop sits on top of this.
- **NSG**: a rule is in place for this laptop. ICMP passes.
- **Architecture**: VM is x86/amd64, laptop is Darwin arm64. Nothing
  built locally transfers.
- **Scripts run on the VM. The load driver runs on the laptop.**
- **Tool state observed 2026-09-17**: docker 29.8.0, kind 0.33.0, kubectl
  v1.37.0, helm v3.21.4, curl 8.5.0, jq 1.7, python3 3.12.3 all present.
  `linkerd` is at `~/.linkerd2/bin` but not on PATH. `/usr/bin/yq` exists,
  flavour unconfirmed. No bombardier. No `~/projects/kube`.
- **Measurement rules** live in `knowledge.md` and apply unchanged.

## Open questions

- Is `/usr/bin/yq` on the VM the Go flavour or the python wrapper, and
  does anything in `scripts/` actually need it? Blocks task 4 only.
- Does the 8 vCPU ceiling force a smaller workload shape than the
  laptop's 5 emojivoto replicas? Blocks nothing until task 14, and task
  14 says what to do if it does.
- Can the mesh cost be separated from the WAN cost without a VM-local
  load run? Currently no. Noted in task 17.
