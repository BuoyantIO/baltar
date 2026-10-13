# launchy-dev

Scripts to stand up a Linkerd test cluster and measure it: CPU per
container, latency per hop, meshed vs. unmeshed, under load. The
cluster is a local `kind` cluster by default; the same scripts also
run against an Azure VM for load driven over a public IP.

## What gets installed

`init_*` scripts, run in order, build the cluster from nothing:

1. `init_1` creates the `kind` cluster and the Gateway API CRDs.
2. `init_2`/`init_3` install the Linkerd control plane and the
   `linkerd-viz` extension (Prometheus, Grafana source).
   `init_2_install_bel.sh` is the alternative to
   `init_2_install_linkerd.sh`: it installs a chosen Buoyant
   Enterprise for Linkerd version with Helm, optionally with extra
   proxy env, and refuses to overwrite an OSS install.
3. `init_4`/`init_5` install Grafana (wired to viz's Prometheus) and
   Headlamp, a cluster UI.
4. `init_6`/`init_7` deploy the `emojivoto` demo app and an HAProxy
   ingress in front of it, on a pinned NodePort.
5. `init_8` installs a `cpu-probe` DaemonSet: a hostPath mount of each
   node's `/sys/fs/cgroup`, read through `kubectl exec`, so CPU can be
   read the same way for meshed and unmeshed workloads.
6. `init_9` deploys ns `demo` and a meshed `echo` server on opaque
   port 5678, the target of `test_load_3_fortio.sh`.

Run `init_0_prerequisites.sh` first; it checks the host has what the
rest needs and fails fast rather than leaving a half-built cluster.

## Day to day

`dev_*` scripts work against a cluster that is already up:
mesh/unmesh emojivoto or the HAProxy ingress, set the proxy's core
count, inspect what a proxy is actually using, scale replicas, and
run the CPU sampler (`dev_5` starts it, `dev_6` stops it and writes a
CSV). `dev_9` prints each matching pod's proxy `Rss` and
`AnonHugePages` from `smaps_rollup` on its `kind` node, read-only.
`pf_*` scripts open the viz, Grafana and Headlamp dashboards, or
forward the ingress to `localhost:8080`. `test_load_1`/`test_load_2` drive
load with `bombardier`, either through whatever is publishing
`:8080` or straight at the NodePort from a container on the `kind`
network. `test_load_3_fortio.sh` deploys `load`, a meshed fortio
client in ns `demo` holding many long-lived connections to `echo`
under steady load (`CONNECTIONS`, `QPS`). `cleanup_1_cluster.sh` tears the whole thing down.

`Makefile`'s `health-check` is a one-line curl against emojivoto on
`:8080`.

## Working from checklists

Work is tracked in `checklist/`, one file per concern
(`checklist_<concern>.md`): a flat task list up top, then one section
per task with the exact commands, preconditions and done-criteria, so
a task can be handed to a sub-agent with no other context. Finished
checklists move to `checklist/complete/`. To pick up or start work,
name a checklist (or a concern, if none exists yet) and ask Claude
Code to work from it.
