# Reproducible kube setup: kind cluster from scratch

Goal: rebuild the kind cluster from scratch with one command, no manual
steps. Scope started as the cluster itself and has widened as steps
arrive: it now covers the kind cluster, the Gateway API CRDs and the
Linkerd control plane, linkerd-viz, Grafana, Headlamp, emojivoto and
the HAProxy ingress. Nothing is now out of scope: the whole setup is
covered. Target is this laptop (Darwin, arm64) only.
Versions are not pinned: the rebuild installs whatever is current.

The setup scripts are being provided by the user. We wire them into a
reproducible entrypoint and verify the rebuild, rather than authoring the
install logic ourselves.

Q:
- the focus going forward should be to get this testing VM ready. its less important that this work
  locally. consider this if it simplifies the setup. ideally we can also run it locally.
- if we are making a decision where it wont run locally then call it out before proceeding.
- how is cpu measured. can it be measured while a test is being run? there should be a separate
script to measure so its reusable.
    - same with latency but its less important for now. future item.
- can we only measure cpu while meshed? i want across mesh and unmeshed so how is that possible?

## Tasks

- [x] 1. Collect the scripts being provided
- [x] 2. Define the target cluster shape
- [x] 3. Write the kind cluster config (dropped, see section)
- [ ] 4. Write the rebuild entrypoint
- [x] 5. Verify a from-scratch rebuild
- [x] 6. Verify the rebuild repeats
- [x] 7. Write the cluster create module
- [x] 8. Write the Gateway API CRDs module (merged into task 7)
- [x] 9. Write the Linkerd control plane module
- [x] 10. Write the Grafana module
- [x] 11. Write the Headlamp module and its dashboard script
- [x] 12. Write the linkerd-viz module and its dashboard script
- [x] 13. Split the HAProxy script into setup modules
- [x] 14. Document and check the prerequisites
- [x] 15. Write the mesh scripts
- [ ] 16. Rename the cores script under the modify_ prefix
- [x] 17. Fix the mesh/unmesh round trip
- [x] 18. Derive the load-test target instead of hardcoding it
- [ ] 19. Pin the haproxy NodePort
- [ ] 20. Host access without Docker: kind extraPortMappings
- [ ] 21. Test the cores modify script, and an inspect script to match
- [ ] 22. `linkerd check` is broken and noisy, for two unrelated reasons
- [ ] 23. Measure proxy CPU and threads under load at CORES_MAX=2
- [ ] 24. Add blocking-pool metrics to the proxy and run a custom build
- [ ] 25. Upstream bug: `tokio_rt_injection_queue_depth` is a duplicate
- [ ] 26. Run the setup on an Azure VM, load-tested from the laptop
- [ ] 27. Revise the four measurement scripts, which are too complicated

## 1. Collect the scripts being provided

The user is supplying the setup scripts. Nothing downstream can start
until we have them and know what each one does.

- [x] Receive the scripts and record where they landed
      - all pasted into the session 2026-09-16 and written to `scripts/`
        as the seven `init_` modules and three `pf_` scripts listed in
        Context
- [x] Read each one and record, per script: what it creates, what it
      assumes already exists, and whether it is safe to re-run
      - recorded per module in tasks 7 and 9 to 13
      - re-run safety, summarised: init_1 fails on an existing cluster,
        init_5 and init_7's `helm install`/`helm upgrade --install`
        differ, init_4 deletes and recreates the `grafana` namespace
- [x] Note which parts fall outside this checklist's scope
      - nothing is, as of 2026-09-16: emojivoto and the ingress were the
        last exclusions and task 13 brought them in

## 2. Define the target cluster shape

What "reproduced" means, stated concretely enough to check against.
Without this, task 5 has no pass condition.

- [x] Cluster name: `kind`, context `kind-kind`, kind's default
- [x] Node count and roles: one node, `kind-control-plane`, kind's
      default single control-plane
- [x] Kubernetes version: v1.37.0, taken from kind's default node image,
      not pinned
- [x] CPU and memory available to the node: 15 CPUs, 8123872Ki, read
      from `.status.capacity`. Set by the Docker Desktop VM, not by
      kind, so it is a host prerequisite and not reproducible from this
      repo.
- [x] Port mappings the cluster must expose: none. The NodePort is
      reached from a container on the `kind` network, so no
      `extraPortMappings` are needed. Revisit only if a host-side path
      without Docker is wanted, which is the task 3 note.
- [x] Write the agreed shape into `## Context` below

## 3. Write the kind cluster config

A checked-in kind config file so cluster creation carries no flags that
live only in someone's shell history.

- [x] Config file committed at a fixed path (dropped)
- [x] Every element of the task 2 shape that kind controls is expressed
      in it (dropped)
- [x] Anything kind cannot control (Docker Desktop CPU/RAM) documented
      as a prerequisite (dropped, but recorded in Context anyway)

Dropped 2026-09-16, then revived the same day. The drop was right at the
time: kind's defaults were the config. Task 20 is the case that reverses
it, because `extraPortMappings` can only be set at create time and a
published NodePort is the one thing the defaults cannot give.
`init_1_create_cluster.yaml` now exists at the repo root and init_1 passes it with
`--config`. The three items above are therefore live again, and the
first two are now done.

## 4. Write the rebuild entrypoint

One command from no cluster to a ready cluster, calling the modules
rather than duplicating them.

- [ ] Single entrypoint exists (Makefile target or script)
- [ ] It runs the seven `init_` modules in numeric order and nothing
      else: the `pf_` scripts block and must stay out
      - amended: was "creates the cluster from the task 3 config", which
        died with task 3. init_1 creates the cluster.
- [x] A teardown path exists that removes the cluster completely
      - `cleanup_1_cluster.sh`: `kind delete cluster`. Nothing survives
        the cluster, so it is complete. Not yet wired into an entrypoint.
- [ ] It fails loudly on a missing prerequisite instead of half-building,
      which task 14 enumerates

## 5. Verify a from-scratch rebuild

Proof on a machine with no cluster. This is what makes "reproducible"
true or false.

- [x] Built from scratch, reported by the user 2026-09-16
      - this session did not observe that run, so the evidence below is
        corroboration after the fact, not a transcript
- [x] Corroborated against the live cluster
      - namespace creation timestamps in init order: linkerd 19:51:16,
        viz 19:52:05, grafana 19:52:19, emojivoto 19:56:18, haproxy
        19:56:27. About five minutes end to end.
      - node Ready, k8s v1.37.0, arm64; 8 `gateway.networking.k8s.io`
        CRDs present, so init_1's second half ran
      - helm showed grafana 10.5.15, headlamp 0.45.0,
        kubernetes-ingress 1.54.2 deployed, every pod Ready
- [x] Record the exact commands the run used
      - dropped: not captured at the time. Task 6 captured them on the
        second build instead.

## 6. Verify the rebuild repeats

A rebuild that works once is not reproducible. This catches state left
behind by a previous run.

- [x] Teardown verified
      - `cleanup_1_cluster.sh` left nothing: no cluster, no context, no
        `grafana-install` work directory, and stray port-forwards died
        with the cluster
      - the one leftover was `kindproxy`, a socat container from an
        experiment rather than any script. Removed.
- [x] Run teardown then the modules a second time, clean
      - 2026-09-16 14:25:57 to 14:31:14, 5m7s, from no cluster
      - ordered commands captured: init_1 through init_7, then
        `dev_1_mesh_emojivoto.sh mesh`, `dev_2_mesh_haproxy.sh mesh`, then
        `dev_3_modify_linkerd_cores.sh` on `emojivoto deploy/web`
        and on `haproxy-controller deploy/haproxy-ingress-kubernetes-ingress`
- [x] Second run produces the same cluster shape as the first
      - all 25 pods Ready across seven namespaces, nothing pending
      - ingress answers 200 on `http://172.18.0.2:31080/`
      - `linkerd check` in init_2 finished all-green this time
- [ ] Re-running the modules against an existing cluster either succeeds
      unchanged or fails clearly, decided deliberately
      - still untested; only the clean-start path has been exercised

## 7. Write the cluster create module

The first module. Everything else assumes a cluster, so this runs first
and proves the API server answers before handing over.

- [x] `scripts/init_1_create_cluster.sh` created, executable, `bash -n`
      clean
      - plain `kind create cluster`, then
        `kubectl cluster-info --context kind-kind` as the ready check
      - unparameterised on the cluster by decision
      - also applies the Gateway API CRDs, folded in here; tag defaults
        to v1.5.1, overridable with `GATEWAY_API_VERSION`
- [x] Run it against a machine with no cluster and confirm it works
      - confirmed twice via tasks 5 and 6
- [x] Decide what it should do when a cluster already exists
      - keep kind's own error and the non-zero exit. That is the loud
        failure task 4 wants, and `cleanup_1_cluster.sh` is the
        deliberate way to start over. Still untested.

## 8. Write the Gateway API CRDs module

Merged into task 7, 2026-09-16. The CRDs install inside
`init_1_create_cluster.sh` rather than as their own module, so
`scripts/init_2_install_gateway_api.sh` was deleted and Linkerd took the
init_2 slot.

## 9. Write the Linkerd control plane module

Setup step 2. Installs the control plane with whatever `linkerd` CLI is
on PATH and does not return until `linkerd check` passes.

- [x] `scripts/init_2_install_linkerd.sh` created, executable, `bash -n`
      clean
      - `linkerd check --pre`, CRDs, control plane, `linkerd check`
      - unpinned by decision: the CLI on PATH picks the version
- [x] Run it and confirm the control plane comes up
      - linkerd pods all Ready; on the second build `linkerd check`
        finished all-green
- [x] Record which versions the run installed
      - client and server edge-26.9.3, proxy
        `cr.l5d.io/linkerd/proxy:edge-26.9.3`
      - the previous cluster ran client enterprise-2.20.2 and server
        edge-26.9.2, so the unpinned install has already drifted

## 10. Write the Grafana module

Setup step 4. Grafana pointed at the linkerd-viz Prometheus, installed
from a patched local copy of the upstream chart.

- [x] `scripts/init_4_install_grafana.sh` created, executable, `bash -n`
      clean
      - pulls the chart, layers linkerd's own `values.yaml` over the
        defaults, patches `root_url` and `serve_from_sub_path` for
        `/grafana/`, installs, applies `authzpolicy-grafana.yaml`
      - work dir anchored to the repo root, not the caller's cwd
      - added `set -euo pipefail`, which the pasted version lacked
- [x] Confirm the linkerd-viz dependency is satisfied
      - `init_3_install_linkerd_viz.sh` installs it and runs first
- [x] Note that it deletes and recreates the `grafana` namespace:
      re-runnable but destructive of anything else living there
- [x] Run it and confirm Grafana comes up
      - helm release grafana-10.5.15 deployed, pod 2/2 Ready
- [x] Confirm the datasource reads the linkerd-viz Prometheus and the
      copied password logs in
      - verified over the HTTP API, no browser: basic auth as `admin`
        returned 200; one datasource, `prometheus`, isDefault, at
        `http://prometheus.linkerd-viz.svc.cluster.local:9090`
      - it returns data, which is the part that matters: `up` gave 22
        series across jobs linkerd-proxy, linkerd-controller, prometheus
        and kubernetes-nodes-cadvisor; `count(request_total)` gave 50
      - `/api/...` and `/grafana/api/...` both answer despite
        `serve_from_sub_path`
      - the `grafana` AuthorizationPolicy targets Server
        `prometheus-admin` requiring the `grafana` ServiceAccount.
        Amended: on the first cluster prometheus ran 1/1, so nothing
        enforced it. The queries prove the datasource, not the
        authorization. Tracked in task 22.

## 11. Write the Headlamp module and its dashboard script

Setup step 5 installs Headlamp. Opening the dashboard is a separate
script because it blocks.

- [x] `scripts/init_5_install_headlamp.sh` created, executable
      - `helm repo add` then `helm install my-headlamp` into kube-system
      - unpinned: helm takes whatever chart version the repo has
- [x] `scripts/pf_3_headlamp_dashboard.sh` created, executable
      - token to clipboard via pbcopy, port-forward, open the browser
      - port-forward is backgrounded and waited on before `open`: in the
        pasted order the foreground port-forward blocked and `open`
        would never have run
      - macOS only, for pbcopy and open
- [x] Confirm the dashboard loads and the token signs in
      - verified over HTTP, no browser. `kubectl create token
        my-headlamp` mints a well-formed JWT.
      - that token is cluster-admin: the chart creates ClusterRoleBinding
        `my-headlamp-admin` to `cluster-admin`, and `auth can-i --list`
        returns `*.*` with verbs `[*]`
      - `GET /` returns 200 `text/html` with `<title>Headlamp</title>`
        and a 5.5MB asset bundle that itself serves 200
      - the backend accepts the token: `/clusters/main/version` gave
        k8s v1.37.0, `/api/v1/nodes` 1 node, `/api/v1/pods` 25 pods
      - negative controls: no header gives 403 `system:anonymous`, a
        garbage bearer gives 401
- [ ] `pf_3_headlamp_dashboard.sh` hardcodes local port 8081 and fails
      silently if it is taken
      - a leftover forward already held 8081, so a second run cannot
        bind, its tunnel exits immediately, but the readiness curl still
        succeeds against the stale forward and `open` still shows a
        working dashboard. It breaks when the old forward dies.
      - `pf_2` on 3000 and `pf_4` on 8080 have the same shape
- [ ] Decide whether re-running the install against an existing release
      should fail or upgrade
      - `helm install` currently errors on a second run, where init_7
        uses `helm upgrade --install`

## 12. Write the linkerd-viz module and its dashboard script

Setup step 3. Viz carries the Prometheus that Grafana reads, so it sits
between the control plane and Grafana.

- [x] `scripts/init_3_install_linkerd_viz.sh` created, executable
      - `linkerd viz install | kubectl apply -f -`
      - the `linkerd check` after it is left commented, as pasted
- [x] `scripts/pf_1_viz_dashboard.sh` created, executable
      - runs in the foreground rather than backgrounded with `&`: a
        backgrounded child dies with the script that spawned it, and the
        CLI opens the browser and holds the tunnel itself
- [x] Renumber the modules downstream of it
      - grafana init_3 -> init_4, headlamp init_4 -> init_5
- [x] Run it and confirm viz comes up
      - linkerd-viz pods Ready; on the second build all five came up
        injected at 2/2
- [x] Confirm Grafana's datasource reads from its Prometheus
      - verified under task 10
- [ ] Decide whether the commented `linkerd check` should be live
      - without it init_4 can start against a viz that is not ready.
        Task 22 has the evidence: the problem appeared once and did not
        recur, so it is a race, not a certainty.

## 13. Split the HAProxy script into setup modules

The pre-existing `install_ingress_haproxy.sh` did four things: deployed
emojivoto, installed the controller, applied the Ingress, then blocked
on a port-forward. Only the first three are setup.

- [x] `scripts/init_6_deploy_emojivoto.sh` created
      - the emojivoto apply alone, so app and ingress can be re-run
        independently
- [x] `scripts/init_7_install_haproxy.sh` created
      - helm install, readiness wait, and the Ingress pointing at
        `web-svc`, which is why it runs after init_6
      - cleanup commands preserved as comments at the foot of the file
- [x] `scripts/pf_4_haproxy_forward.sh` created
      - named for haproxy, not emojivoto: it forwards
        `svc/haproxy-ingress-kubernetes-ingress` and emojivoto is only
        what you reach through it
      - carries the warning that benchmarking through port-forward
        measured 23.1k RPS against 53.4k direct
- [x] `scripts/install_ingress_haproxy.sh` removed with `git rm`
- [x] `set -e` upgraded to `set -euo pipefail` across the split
- [x] Run init_6 and init_7 and confirm emojivoto answers through the
      ingress
      - `http://172.18.0.2:31080/` returns 200 from the `kind` network,
        and a load run got 100% 2xx through the ingress to `web-svc`

## 14. Document and check the prerequisites

The modules assume tools a fresh machine may not have, and a rebuild
that dies halfway is worse than one that refuses to start.

- [x] List every binary the modules shell out to
      - REQUIRED for a rebuild: docker, kind, kubectl, helm, linkerd,
        curl, yq. That is exactly what the seven `init_` modules use.
      - optional: bombardier (`load_1` only), jq (`inspect_2`), python3
        (`load_4`), base64 (`pf_2`); macOS-only: pbcopy, open (`pf_2`,
        `pf_3`)
      - corrections to the earlier list: jq and python3 were missing
        from it; `bombardier` is only needed on the host by `load_1`,
        since `load_2` runs `alpine/bombardier` in a container; `base64`
        is `pf_`-only and works on both BSD and GNU; `linkerd viz` is a
        subcommand, not a separate binary
      - the yq flavour matters, not just its presence: `init_4` uses
        mikefarah's Go yq syntax, and the same-named python wrapper
        would fail
- [x] Decide where the check lives
      - its own read-only script, `scripts/init_0_prerequisites.sh`,
        which the task 4 entrypoint can gate on. Exits 1 with a count
        when anything required is missing.
      - macOS-only tools report `n/a` rather than missing when the host
        is Linux, verified with a `uname` shim, so it stays honest on
        the VM of task 26
      - also checks what is not a binary: that the docker daemon
        actually responds, that `linkerd viz` resolves, and whether a
        kind cluster already exists (reported, not acted on)
- [x] `yq` is not standard on macOS and only init_4 needs it
      - the script says so explicitly when yq is missing: `init_4` pulls
        the chart and deletes the `grafana` namespace before it reaches
        the yq lines, so a missing yq fails destructively, not early
- [x] Record the check in Context once it exists
      - verified on this machine: exit 0, all seven required present
        (docker 29.7.2, kind 0.33.0, kubectl v1.36.1, helm v3.21.4,
        linkerd edge-26.9.3, curl 8.7.1, yq v4.53.6 mikefarah)
      - failure path verified with a stripped PATH: 6 required missing,
        yq warning fires, exit 1

## 15. Write the mesh scripts

Meshing is neither setup nor a port-forward: it runs against a cluster
that is already up, and it is what the load tests toggle.

- [x] `scripts/dev_1_mesh_emojivoto.sh` created, takes `mesh|unmesh`
      - mesh: patch `linkerd.io/inject` to null on every deployment
        first, then inject. `linkerd inject` SKIPS any workload carrying
        `linkerd.io/inject: disabled`, so without that clear it is a
        silent no-op.
      - unmesh: uninject only, no disabled patch
      - waits on `kubectl rollout status` for every deployment
      - `linkerd check --proxy` on mesh only: after an unmesh there are
        no proxies to check
- [x] `scripts/dev_2_mesh_haproxy.sh` renamed from `mesh_haproxy.sh`
- [x] Decide whether emojivoto arrives meshed already
      - it does not. After a fresh init_6 the four deployments carry no
        pod-template annotation and run 1/1, and the namespace has only
        `last-applied-configuration`. So `mesh` is the step that meshes
        it, and unmesh needs no disabled patch.
- [x] Run it and confirm the `--proxy` check passes
      - every emojivoto-relevant check passes. The non-zero exit is task
        22's problem, not this script's.

## 16. Rename the cores script under the modify_ prefix

`set_cores.sh` reconfigures something already installed, which is none
of init_, pf_ or mesh_.

- [x] Renamed to `scripts/dev_3_modify_linkerd_cores.sh`
- [x] `corestest.yaml` reference updated: the only one outside the
      checklists
- [x] Decide whether the load-test scripts want a prefix too
      - they became `test_load_1_local_tunnel.sh` and
        `test_load_2_docker_nodeport.sh`, and cleanup took `cleanup_`
- [ ] `checklist_load_test_linkerd.md` still cites `set_cores.sh` and
      `mesh_haproxy.sh`
      - left alone deliberately: another concern's running record.
        Decide whether to update its paths.

## 17. Fix the mesh/unmesh round trip

Found by running it: unmesh worked, then mesh silently did nothing.

- [x] Reproduced the failure
      - `linkerd inject` refuses any workload carrying
        `linkerd.io/inject: disabled`, printing `deployment "web"
        skipped` and emitting the manifest unchanged, so `kubectl apply`
        applied an unmeshed deployment and reported success
      - the annotation came from this session's own unmesh path
- [x] Established the wrong assumption behind it
      - the `emojivoto` namespace carries no inject annotation at all,
        so uninject alone unmeshes and the patch was never needed
- [x] Fixed both paths and verified mesh
      - four pods 2/2, templates showing `linkerd.io/inject: enabled`
- [x] Verify unmesh, then mesh again, as a round trip
      - mesh: all four injected, 2/2. unmesh: all four uninjected, 1/1,
        pod-template annotations completely empty. mesh again: all four
        injected, none skipped, which proves the unmesh left nothing
        blocking.
- [x] Run `linkerd -n emojivoto check --proxy`
      - ran to completion; emojivoto passes. See task 22.

## 18. Derive the load-test target instead of hardcoding it

`test_load_2_docker_nodeport.sh` pointed at a URL from a deleted cluster.

- [x] Confirmed it was broken, not just stale
      - from a container on the `kind` network: 31605 gave `000`, the
        real port gave `200`. The node IP survived the rebuild; the
        NodePort did not.
- [x] Confirmed Docker is required, not incidental
      - `curl http://172.18.0.2:31769/` from the host returns `000`:
        Docker Desktop does not route to container IPs from macOS
- [x] Script derives both values with kubectl, URL still overridable as
      the third argument, and fails clearly if either comes back empty
- [x] Ran it end to end
      - 19.2k RPS, 100% 2xx, p50 482us at 10 connections
- [x] Decide whether to pin the NodePort
      - yes, done under task 19

## 19. Pin the haproxy NodePort

An assigned NodePort moves on every reinstall, which is what silently
broke the load-test URL. Pinning is also the precondition for any stable
path from the laptop: an SSH tunnel or a kind extraPortMapping.

- [x] `init_7_install_haproxy.sh` sets
      `controller.service.nodePorts.http`, default 31080, overridable
      with `HAPROXY_NODEPORT`
      - the chart documents the key as "If empty, random ports will be
        used"
- [x] Verified against the live cluster
      - the service reports `80:31080/TCP`, `http://172.18.0.2:31080/`
        returns 200 from the `kind` network, and
        `test_load_2_docker_nodeport.sh` derived the new port by itself
- [ ] Decide whether https, stat and admin want pinning too
      - only http is pinned; the other three are still random

## 20. Host access without Docker: kind extraPortMappings

Not started. It is the only host-side path that reaches the workload
without a userspace relay in front of it.

The case: Docker Desktop does not route to the node's IP from macOS
(`000` from the host, 200 from the `kind` network). Every host path
today pays a relay: `pf_4` dies on every pod roll, and the socat bridge
survives rolls but still costs half the throughput. An `extraPortMapping`
is published by the node container itself, so `localhost:8080` reaches
the NodePort with no tunnel and no extra container, and it survives mesh
and unmesh because nothing is bound to a pod.

The cost: `extraPortMappings` is only read at cluster-create time, so it
needs a kind config file, reversing task 3, and a cluster recreate. It
also needs the NodePort pinned, which task 19 did at 31080.

- [x] Write the kind config with the mapping
      - `scripts/init_1_create_cluster.yaml`, beside the script that reads it: `containerPort: 31080`,
        `hostPort: 8080`, `listenAddress: "127.0.0.1"`
      - the containerPort must match the NodePort init_7 pins, and the
        file says so, because nothing enforces it
- [x] Wire it into `init_1_create_cluster.sh` via
      `kind create cluster --config`
      - the module stays unparameterised on cluster shape; the config
        exists only for the one thing kind's defaults cannot give
      - `KIND_CONFIG` overrides the path, and `KIND_LISTEN_ADDRESS`
        rewrites a temp copy so the committed default stays loopback-only
        while a VM can publish beyond it. Override tested directly.
      - init_1 fails with a clear message if the config is missing
- [ ] Recreate the cluster and confirm `curl localhost:8080` returns 200
      with no port-forward and no bridge container
      - not done: a latency experiment is using the cluster
- [ ] Measure it against the other three paths at `-c 125 -d 3s`
      - numbers to beat: 52.7k container to NodePort, 26.0k socat
        bridge, 20.8k port-forward
- [ ] Confirm it survives a mesh and an unmesh without reconnecting
- [ ] Decide whether `pf_4_haproxy_forward.sh` can then be deleted
- [ ] Note that the recreate doubles as another task 6 repeat

## 21. Test the cores modify script, and an inspect script to match

`dev_3_modify_linkerd_cores.sh` had never been run. Testing it needs
a way to see the result, which is what the inspect script is for.

- [x] `scripts/dev_4_inspect_cores.sh` created, read-only, hence the
      `inspect_` prefix
      - shows four things: the `proxy-additional-env` pod-template
        annotation, the CORES env on the running proxy container plus its
        cpu limit, the proxy's own startup decision from
        `linkerd2_proxy::rt`, and `tokio_rt_workers` from
        `linkerd diagnostics proxy-metrics`
      - the startup log is intent, the metric is observed; they can
        disagree, so it shows both
- [x] Verified `modify_1` changes the runtime
      - before: no annotation, `CORES=1` `CORES_MIN=1`, single-threaded,
        tokio_rt_workers = 1
      - after `... 4`: annotation set, `CORES_MAX=4` on the container,
        `Using multi-threaded proxy runtime cores=4`, workers = 4
      - all four layers agree
- [x] Verified on emojivoto deploy/web, the workload the load tests drive
- [x] Both scripts default to `emojivoto deploy/web`
      - positional: `NS="${1:-emojivoto}"`, `WORKLOAD="${2:-deploy/web}"`,
        `CORES="${3:-1}"`, one signature rather than two
- [x] `reset` removed from modify_1
      - clearing the annotation is documented in the header as a
        `kubectl patch ... null` one-liner
- [x] Fixed inspect_1's pod selection
      - it took `.items[0]`, and during a rollout the old pod is still
        Running and sorts first, so it reported the setting just
        replaced. Caught live: two web pods at CORES_MAX 6 and 3, and it
        showed 6.
      - now sorts by creationTimestamp, takes the newest, scopes
        proxy-metrics to `po/<pod>`, and warns when more than one pod
        matches
- [x] Uppercased every variable across `scripts/`
      - the rename caught a live bug in `dev_1_mesh_emojivoto.sh`: the mesh
        path's loop header stayed `for d in` while its body became
        `$DEPLOY`, which under `set -u` would have failed the patch
      - confirmed meshing does not clobber the cores annotation
- [ ] `modify_1`'s trailing `tokio_rt_workers` print is unreliable
      - it printed two values on one run, because proxy-metrics answers
        for every pod behind the workload including the terminating one.
        Fix it the way dev_4_inspect_cores was fixed, or drop the line.

## 22. `linkerd check` is broken and noisy, for two unrelated reasons

Found while verifying the mesh round trip. Neither is caused by the mesh
scripts, and both were spot-checked directly.

**The `linkerd-trust` extension rejects the flag the CLI passes it.**
`~/.linkerd2/bin/linkerd-trust check --namespace=emojivoto` returns
`error: unexpected argument '--namespace' found`, with the tip
`a similar argument exists: '--as'`. That single hard failure makes
`linkerd check --proxy` exit non-zero, and because it is the last
command in `dev_1_mesh_emojivoto.sh` under `set -e`, a successful mesh exits
1. `~/.linkerd2/bin/` holds several CLI versions including
`linkerd-edge-26.8.4` and `linkerd-edge-26.9.3`.

**Half of linkerd-viz came up unmeshed, once.** On the first cluster
`metrics-api`, `prometheus` and `tap` ran 1/1 while `tap-injector` and
`web` ran 2/2, about 49 seconds after the control plane namespace was
created. On the rebuild all five came up injected at 2/2, so it is a
race at install time, not a property of init_3.

- [x] Decide what `dev_1_mesh_emojivoto.sh` should do about the exit code
      - `|| true` hides real failures; leaving it means every successful
        mesh looks like a failure
      - done in task 14 of `checklist_mvp.md`: the script now captures
        the check, prints it whole, and exits non-zero unless the only
        `×` line is the linkerd-trust one. Root cause recorded there:
        linkerd-trust announces `checks: always`, so it runs on every
        `linkerd check`, and its `check` has no `--namespace` flag.
- [ ] Fix or remove the `linkerd-trust` extension
      - a local binary in `~/.linkerd2/bin/`, outside this repo, so a
        rebuild will not fix it
- [ ] Re-test the Grafana authz path on the rebuilt cluster
      - now meaningful: prometheus is 2/2, so its inbound proxy exists
        and the AuthorizationPolicy is actually enforced

## 23. Measure proxy CPU and threads under load at CORES_MAX=2

Cap both proxies at 2 cores, drive load through the ingress, and answer
two questions: does either exceed two cores of CPU (>200% of one core),
and does either spawn blocking-pool threads (OS threads above the worker
count)? `CORES_MAX` caps tokio worker threads only; it says nothing
about CPU time or the `spawn_blocking` pool.

- [x] `scripts/wip_1_proxy_runtime.sh [NS] [WORKLOAD]` written
      - emits KEY=VALUE lines so two snapshots can be diffed
      - dumps every `tokio_` metric by pattern, not by name
- [x] `scripts/wip_3_measured.sh [CONNECTIONS] [DURATION]` written
- [x] Validate both against the live cluster
      - `container_threads` and `container_cpu_cfs_throttled_seconds_total`
        do not exist in this cluster's cAdvisor; the kubelet ships a
        trimmed one. Scripts now print `series_absent`.
      - thread count comes from the proxy's `process_threads`, CPU from
        `process_cpu_seconds_total`, read synchronously
      - an EXIT trap made every run exit 143: bash 3.2 returns the
        trap's last status and `wait` on a killed port-forward gives 143
      - the Prometheus value parser was greedy and returned the last
        matching series; replaced with jq
      - pod selection now filters `status.phase=Running` and sums across
        replicas
- [x] Run the experiment
      - **Neither proxy exceeds its 2-core cap.** haproxy replica 1:
        48.90 CPU seconds over 30s, 153-163%. Replica 2: 30.88s, ~103%.
        emojivoto web: 38.74s, 125-129%.
      - independent bound: `tokio_rt_busy_seconds_total` deltas of
        56.15s and 52.54s, 175% and 169%, under the 200% two workers
        impose. Busy exceeds CPU because it is wall-clock unparked time.
      - **No blocking-pool threads.** `process_threads` = 4 before and
        after, unmoved by 858k requests.
      - thread names read on the node, verified directly: `linkerd2-proxy`
        (main), `proxy`, `proxy`, `admin`. A 1-worker proxy shows only
        `linkerd2-proxy` + `admin`, because tokio uses the current-thread
        runtime there and the main thread is the worker.
      - load: 28,627 req/s, 858,685 requests, 100% 2xx, p50 4.19ms
- [x] `tokio_` series reach Prometheus
      - `count({__name__=~"tokio_.*"})` = 224 series across the same 14
        names, nothing dropped at scrape time
      - they already carry `namespace`, `pod`, `deployment`,
        `workload_ns`, `instance` and `job` as scrape-time target labels,
        so per-pod attribution needs no proxy change
- [x] Re-run at higher connection counts to look for peaks
      - `scripts/wip_4_sampled.sh [CONNS] [DURATION] [INTERVAL] [OUTDIR]`
        added: long-lived port-forwards to each admin port before the
        run, a Python sampling loop, rates from measured elapsed time
      - **200% is never exceeded.** Highest single sample anywhere:
        173.2%, haproxy at 250 connections, including a 0.25s-resolution
        run that would have caught sub-second bursts.
      - 125 conns: haproxy 160/162% mean, web 130%. 250: 153/156%, 121%.
        500: 146/146%, 104%. 1000: 152/153%, 94%. All 100% 2xx.
      - already saturated at 125 connections: throughput flat at 25-28k
        req/s to 1000 while p50 scales 4.2 -> 8.7 -> 17.6 -> 38.1ms
      - the constraint is the worker pool, not CPU: worker-busy sits at
        180-190% against the 200% ceiling while process CPU runs 20-40
        points below it, so workers spend real time blocked, not on-CPU
      - sampling overhead ruled out by A/B control: under 0.4%
        difference, inside the ~3% run-to-run spread
      - `tokio_rt_busy_seconds_total` is unusable below ~1s: it advances
        in lumps when a worker parks, giving 797% for a 2-worker runtime
        at 0.25s. Process CPU comes from /proc and does not.
- [x] Test the hypothesis at 3 cores
      - **partly right, mostly wrong.** The pool is a real ceiling: at
        2 workers the haproxy proxy never passed 200% in any sample; at
        3 it ran 206-209% mean with peaks of 218%, arithmetically
        impossible at 2. But lifting the pool 50% bought only 7-9%
        throughput.
      - 125 conns, n=4 each: 26,531 -> 28,505 req/s, +7.4%, Welch
        t=3.7, p~0.01, so real but small against the ~3% spread.
        p50 4.53 -> 4.21ms; p99 8.93 -> 9.44ms, slightly worse.
      - 500 conns: 29,387 -> 32,046 req/s, +9.0%. At 2 cores 0 of 30
        samples passed 200%; at 3 cores 29 of 30 did.
      - the prediction failed where it counts: worker-busy did not come
        off its ceiling. 90-93% of 200% at 2 cores, 91-94% of 300% at 3.
        The pool re-saturated at the new limit while throughput barely
        moved, which is not what a dominant bottleneck looks like.
      - verified directly afterwards: both workloads carry
        `CORES_MAX=3` and the web proxy reports `tokio_rt_workers = 3`
- [x] Eliminate the three named candidate constraints
      - load generator: two concurrent generators at 125 conns each gave
        30,225 req/s combined vs 27,263 for one (+11%) while p50 doubled,
        and each used only 45% of a core against 86% for a single one.
        They were waiting on the server. A small tax, not the ceiling.
      - emojivoto app containers: `web-svc` is the largest CPU consumer
        on the node at 276.9% of one core, yet scaling web to 2 replicas
        changed nothing (28,611 vs 28,505 req/s) even though the work
        genuinely split, each web proxy dropping 145% -> 78%
      - node aggregate: total container CPU during a 3-core run was 950%
        of one core out of 15, and a synthetic 15-thread spin test
        degraded only 12%, so ~5 cores sat unused
- [x] Break the latency down per hop
      - `scripts/wip_2_hop_latency.sh` added, read-only: brackets a
        load run with two Prometheus snapshots of every proxy's
        `response_latency_ms` histogram and diffs the counters, rather
        than using `histogram_quantile(rate(...))`, whose window does not
        align with the run and smears idle vote-bot traffic into it
      - of the 4.61ms mean at 125 conns: edge (generator to the ingress
        proxy's measurement point, containing NodePort DNAT, the
        iptables redirect and bombardier itself) 1.06ms / 23%; haproxy's
        own processing <=1.00ms / 22%, an upper bound that also contains
        two socket crossings; ingress proxy outbound to web proxy
        inbound 1.60ms / 35%, the largest single segment; web app 0.95ms
        / 21%
      - only the three proxy rows are measured; everything else is
        subtraction, so errors compound
      - independent cross-check by CPU per request over the same window,
        which needs no subtraction: ingress proxies 121.8us, web proxy
        50.7us, haproxy controllers 51.1us, web-svc 94.7us. Total 318us
        per request, 8.6 cores. **Proxies 54%, apps 46%.**
      - so the proxies are neither a small fraction nor dominant. They
        are roughly half the cost on both lines of evidence.
      - **no proxy was near its cap**: ingress replicas ran at 1.86 and
        1.44 cores, web proxy at 1.37, all against `CORES_MAX=3`. That
        is why raising 2 to 3 bought only 7%: the knob was never the
        constraint.
- [x] Correct the fan-out hypothesis, which was wrong
      - `/` does not call emoji-svc or voting-svc at all. It returns a
        560-byte static page, verified three ways, and ~850k requests to
        it produced 78-98 emoji calls, which is exactly the vote-bot
        background rate. Confirmed directly: `/` returns 200 with 560
        bytes.
      - so the earlier "31,400 vs 28,505" cannot have been a fan-out
        effect, and no run at `/` has ever exercised the fan-out
      - the inverse A/B, run twice each: `/` 28,460 and 28,043 rps at
        p50 4.2ms; `/api/list` 10,726 and 10,687 rps at p50 11.1ms, with
        emoji calls 1:1 to requests. Fan-out costs 62% of throughput and
        2.7x the p50.
      - confound: `/api/list` returns 4,513 bytes against 560, verified
        directly, so byte throughput actually rises (48.2 vs 19.5 MB/s)
        and some of that latency is body size, not the RPC. voting-svc
        is never called on either path; only `/api/vote` reaches it.
- [x] Note the precision limits
      - the histogram buckets are 1, 2, 3, 4, 5, 10, 20, 30, 40, 50,
        100, 200ms. Everything under 1ms lands in one bucket, so the web
        inbound p50 of 0.66ms is pure interpolation and only its mean is
        trustworthy. Between 5 and 10ms the bucket is 5ms wide, so p95
        and p99 should be read as "between 5 and 10ms".
      - the decomposition therefore uses means from `_sum/_count`
        throughout, which are not bucket-limited
      - balancer queue latency was 21.6us on web's outbound and had zero
        observations on haproxy's, which dials pod IPs directly. That
        rules out proxy load-balancer queueing but does not bound the
        proxies' other internal queueing.
- [x] Caution on the earlier evidence
      - worker-busy is not comparable across worker counts. Tokio counts
        work-stealing and spin-before-park as busy, and the busy-minus-CPU
        gap grew from 22pp at 2 cores to 66pp at 3. The original
        "180-190% against a 200% ceiling" reading was partly this
        artifact.
      - `wip_4_sampled.sh` hardcodes its `>200%` column and does not
        adjust for a 3-worker ceiling
- [ ] Scale `emojivoto/web` to 10 replicas and re-run
      - queued behind the 3-core run, to rule out the app as the
        bottleneck. Report how many reach Ready.
- [ ] Chart worker busy-time in Grafana
      - the data is there; no panel exists

## 24. Add blocking-pool metrics to the proxy and run a custom build

Rebuilding the proxy is acceptable, so the blocking pool can be measured
directly instead of inferred from OS thread counts.

- [x] Locate the registration site and confirm the build flag
      - the metrics are not the proxy's own code. They come from
        `kubert-prometheus-tokio` v0.2.1, a git dependency on
        `linkerd/linkerd-kubert` at rev cb414cc, wired up in
        `linkerd2-proxy/src/rt.rs:96-121`. The `tokio_rt_` prefix comes
        from `sub_registry_with_prefix` at `rt.rs:108`.
      - it is a library linked into the proxy, not a separate process:
        the proxy passes its own `Handle::current()` and registry, and
        spawns the 1s polling task itself (`rt.rs:104`, hard-coded)
      - values come from `tokio-metrics`' `RuntimeMonitor`, not
        `tokio::runtime::RuntimeMetrics` directly
      - `--cfg tokio_unstable` is unconditional, verified directly at
        `Dockerfile:38` plus every CI workflow and the devcontainer.
        Not optional: kubert has a `compile_error!` without it.
      - `buoyant-proxy` is byte-identical on every file involved
      - `rt.rs:82` sets `.max_blocking_threads(cores)`, so the pool is
        capped at the worker count, not tokio's 512 default
- [x] Add the three blocking-pool metrics
      - branch `tokio-blocking-metrics` in `linkerd2-proxy`, off
        c32edef0, `src/rt.rs` +44/-1, uncommitted
      - three `prom::Gauge<i64>` on the same `tokio_rt` sub-registry,
        driven by a second 1s task, because kubert's `updated()` is `->!`
        and never yields a point to hook into
      - renders as `tokio_rt_blocking_threads`,
        `tokio_rt_blocking_threads_idle`, `tokio_rt_blocking_queue_depth`
      - no identity labels by design: Prometheus attaches namespace, pod,
        deployment and workload_ns at scrape time
      - `cargo check` cannot run natively on macOS, on this change or on
        baseline: `linkerd-proxy-transport` uses Linux-only socket2
        accessors. Reproduced on the untouched tree. Cross-compiled to
        `aarch64-unknown-linux-gnu` instead: passes in 18.8s, clippy and
        fmt clean.
      - that needed `rustup target add aarch64-unknown-linux-gnu` and
        `brew install zig`, both installed on this laptop. zig supplies
        the cross C compiler for `aws-lc-sys`; not needed when building
        in Docker or on Linux.
- [ ] Build the image, for amd64
      - the target is the x86 Azure VM of task 26, not this laptop
      - preferred route is building ON the VM: native x86, no
        cross-compile, no registry. `docker buildx --platform
        linux/amd64` here runs a Rust release build under QEMU, and the
        repo's dev image `ghcr.io/linkerd/dev:v50` is amd64-only.
- [ ] Get the image into the cluster with `kind load docker-image`
- [ ] Point the injector at it
      - `config.linkerd.io/proxy-image` per workload is smaller than
        changing the control plane's proxy image for everything
- [ ] Re-run task 23's experiment against the custom proxy

Amended after task 23 ran: the empirical question this was meant to
answer is already answered. The proxy spawns no blocking threads at all
under 858k requests, verified by thread name on the node, so the three
metrics would report an empty pool. The rebuild is now about
instrumentation for its own sake, or for a workload that uses
`spawn_blocking`.

Open: how long a proxy build takes, and whether the repo's own tooling
(devcontainer, `just`, Makefile) is the supported path over bare `cargo`.

## 25. Upstream bug: `tokio_rt_injection_queue_depth` is a duplicate

Found while locating the metrics registration, verified directly in the
vendored source. `kubert-prometheus-tokio/src/lib.rs:170-173` sets two
different gauges from the same field:

    self.injection_queue_depth
        .set(probe.total_local_queue_depth as i64);
    self.local_queue_depth
        .set(probe.total_local_queue_depth as i64);

So `tokio_rt_injection_queue_depth` reports the local queue depth and
never the injection queue. The two series are identical by construction,
and anyone diagnosing scheduler pressure from the global injection queue
is reading the wrong number.

- [x] Confirm against a live proxy that the two series are always equal
      - they are, bit-identical: over 60 minutes across 31 proxy
        instances and 5812 samples,
        `max_over_time((abs(injection - on(instance) local))[60m:15s])`
        is 0 for every instance, and the inequality count is empty
      - not an idle-cluster artifact: local queue depth peaked at 325 on
        a haproxy pod and `stddev_over_time` reached 100.96, so the
        queues genuinely moved
      - negative control: the same comparison between
        `tokio_rt_workers` and `tokio_rt_local_queue_depth` flags all 32
        instances, so the query works and the 0 is the metric
      - so the gauge carries no independent information at all
- [x] Check whether it is already reported or fixed upstream
      - not reported, not fixed. Verified directly: v0.2.1 is the newest
        crate tag (the full set is v0.1.0, v0.2.0-alpha1, v0.2.0,
        v0.2.1), and `main` still has both gauges fed
        `probe.total_local_queue_depth`.
      - the repo has 27 items, all PRs, zero issues; nothing matches
        the queue-depth terms
      - the file has three commits ever, the newest a 2024 doc typo, so
        this has shipped since December 2023
- [ ] File it upstream as an issue plus the one-line PR
      - needs the user's go-ahead: it is an outward-facing action
- [x] Establish the fix
      - one word: `probe.global_queue_depth`, verified present on the
        same `RuntimeMetrics` struct kubert already holds
        (tokio-metrics 0.5.0 `runtime.rs:417`, populated at `:1292`,
        outside the `#[cfg(tokio_unstable)]` block so it needs no extra
        gate)
      - tokio renamed `injection_queue_depth` to `global_queue_depth`,
        which is likely how the copy-paste survived review
      - the Prometheus metric name can stay, so no dashboard breaks
- [ ] Decide on the proxy-side workaround
      - a kubert fix does nothing for us until someone cuts v0.2.2 and
        we bump `Cargo.toml:145-149`, so the practical fix is a fourth
        gauge in task 24's existing 1s loop in `rt.rs`, which already
        holds the runtime handle: three lines, exposed as
        `tokio_rt_global_queue_depth` to avoid colliding with kubert's
        registration
- [ ] Check whether any linkerd-viz dashboard or alert reads
      `tokio_rt_injection_queue_depth`

## 26. Run the setup on an Azure VM, load-tested from the laptop

Move the cluster onto an existing SSH-reachable x86 Azure VM and drive
load at it from the laptop. This is the repro-setup half of task 10 in
`checklist_load_test_linkerd.md`.

One networking fact drives the design: on Linux, Docker bridge IPs are
routable from the host, so on the VM `curl 172.18.0.2:31080` works
directly. On macOS it does not, which is why every host-side path here
needed a relay. The laptop still cannot reach that bridge, so it crosses
by SSH or by a published host port.

**Items marked LOCAL can be done and verified on this laptop first, with
no VM.** They are the portable work: the kind config, the prerequisites
check, and
the macOS-only guards. Everything else needs the VM.

### Do first, locally

- [x] LOCAL: build the kind config with `extraPortMappings`
      - written and wired into init_1 under task 20. Verification still
        needs a cluster recreate, which is blocked on the running
        experiment.
      - `KIND_LISTEN_ADDRESS=0.0.0.0` is the VM's path: the committed
        config binds loopback only
- [x] LOCAL: write the prerequisites check from task 14's list
      - `scripts/init_0_prerequisites.sh`, done under task 14. macOS-only
        tools report `n/a` on Linux rather than failing.
- [x] LOCAL: guard the macOS-only `pf_` scripts
      - `pf_2` and `pf_3` now use `copy_to_clipboard` and `open_url`
        helpers: pbcopy, else xclip, else xsel, else print to stderr;
        open, else xdg-open, else print the URL
      - the macOS branch is verified (a value reached the clipboard).
        The Linux branch cannot be exercised here, because `open` lives
        in /usr/bin so the fallback never fires: unverified.
      - `pf_1_viz_dashboard.sh` needs nothing: `linkerd viz dashboard`
        opens the browser itself and is not macOS-specific
- [x] LOCAL: decide where the scripts run
      - decided: on the VM. Clone or rsync the repo, run over SSH. The
        laptop route needs the kind kubeconfig rewritten and the API
        server tunnelled, because kind writes `127.0.0.1:<port>`, and
        buys nothing the SSH path does not.
      - the load generator is the exception and stays on the laptop,
        which is the whole point of the exercise
- [x] LOCAL: confirm `test_load_2_docker_nodeport.sh` needs no change
      - reviewed: it derives node IP and NodePort with kubectl and runs
        `alpine/bombardier` in a container on the `kind` network. No
        macOS-specific calls, no host bombardier needed.
      - on Linux it will also work from the VM host directly, since
        Docker bridge IPs route there, but the container path works
        unchanged so there is nothing to alter

### Needs the VM

- [ ] Record the VM's facts: resource group, size, vCPUs, RAM, OS image
      - architecture is settled: x86/amd64
- [ ] Confirm SSH works non-interactively; record the host alias
- [ ] Confirm whether SSH is direct on a public IP or via a bastion
      - decides whether a published port is reachable at all
- [ ] Install prerequisites: docker (user in the `docker` group), kind,
      kubectl, helm, linkerd CLI, yq, curl
- [ ] Run init_1 through init_7 on the VM, capturing wall-clock time
      - compare against the laptop's 5m7s
- [ ] Confirm all pods Ready and the ingress answers 200 from the VM
- [ ] Mesh both, set CORES_MAX, confirm with `inspect_1`
- [ ] Pick the laptop-to-cluster path, in increasing setup cost:
      1. `ssh -L 8080:172.18.0.2:31080 <vm>`: works today, no Azure
         change, but a userspace relay so it costs throughput
      2. a socat container on the VM publishing a host port: same cost,
         no cluster recreate
      3. the `extraPortMappings` config from the LOCAL work above, plus
         an NSG rule: no relay at all
      - all three target the Service's NodePort, not a pod, so they
        survive mesh and unmesh. `kubectl port-forward` does not.
- [ ] If publishing a port, scope the NSG rule to the laptop's IP rather
      than the internet
- [ ] Run the load from the VM first: the baseline with no network in
      the path. Then from the laptop, and record the difference.
      - expect a large drop. The local analogue, a socat relay, halved
        throughput and raised p50 six-fold; an SSH tunnel adds
        encryption and a WAN on top.
      - the laptop path measures the tunnel as much as the mesh

### Open

- Which subscription and resource group is the VM in? Load the
  `buoyant-azure` skill before any `az` command that writes.
- Public exposure (task 11 of the sibling checklist) is a separate
  decision, not in scope here unless asked.

## 27. Revise the four measurement scripts, which are too complicated

`wip_1_proxy_runtime.sh`, `wip_2_hop_latency.sh`,
`wip_3_measured.sh` and `wip_4_sampled.sh` all work and produced the
results in tasks 23 and the hop-latency work, but they are not something
to hand to someone else. They are deliberately left out of the script
list in `knowledge.md` until revised.

What is wrong with them, as far as is known:

- `wip_4_sampled.sh` hardcodes both proxies as sampling targets, so it
  breaks when a workload is unmeshed and has no proxy on :4191
- its `>200%` column is hardcoded to 200 and does not follow the actual
  worker cap
- none of them fall back to cAdvisor for a container that has no proxy,
  so an unmeshed haproxy has no CPU number at all
- `inspect_2` and `load_3` overlap: one emits snapshots, the other diffs
  them, and it is not obvious which to reach for
- `inspect_4` runs its own load internally, so it cannot be pointed at a
  run someone else is driving

- [ ] Decide which of the four survive, and whether the survivors merge
- [ ] Make the survivors work with unmeshed workloads
- [ ] Re-list them in `knowledge.md` once they are fit to hand over

## Context

### Current state

- A cluster is live, rebuilt from scratch 2026-09-16 14:25-14:31 in
  5m7s: node `kind-control-plane` at 172.18.0.2, k8s v1.37.0, arm64,
  15 CPUs, 8123872Ki. All 25 pods Ready.
- emojivoto and the haproxy ingress are both meshed. Both proxies were
  set to `CORES_MAX=2` for task 23 and a dispatched run is raising them
  to 3. Neither proxy container has a CPU limit or request, so
  `CORES_MAX` is the only bound.
- NodePort pinned at 31080. Ingress answers 200 from the `kind` network.
- An earlier cluster was torn down with `cleanup_1_cluster.sh`, which is
  what proved the teardown path.
- Host is Darwin 25.5.0, arm64, kind on Docker Desktop, so node CPU and
  RAM come from the Docker Desktop VM allocation, not from kind.
- Installed versions, unpinned and already drifting: linkerd client and
  server edge-26.9.3, proxy edge-26.9.3, against enterprise-2.20.2 /
  edge-26.9.2 on the cluster that predated this session.

### Conventions

- Every script under `scripts/` carries one of seven prefixes:
  `init_` builds it, `pf_` exposes it, `mesh_` meshes it, `modify_`
  reconfigures it, `load_` drives traffic at it, `inspect_` reads it,
  `cleanup_` destroys it.
- Numbers increment within each group. `init_` numbers give run order.
  `pf_` and `mesh_` numbers follow the `init_` step that installs what
  they act on, so inserting one renumbers those after it, as grafana did.
- Variables are UPPERCASE. Optional arguments default positionally,
  `NS="${1:-emojivoto}"`, not a `case $#` block.
- `pf_` scripts block until ctrl-C, so the rebuild must never call them.
- Cluster create is the one unparameterised module: it takes no
  arguments, so there is one cluster shape and no flags in shell history.

### The scripts

- Setup, in run order: `init_1_create_cluster.sh` (kind plus the Gateway
  API CRDs), `init_2_install_linkerd.sh`,
  `init_3_install_linkerd_viz.sh`, `init_4_install_grafana.sh`,
  `init_5_install_headlamp.sh`, `init_6_deploy_emojivoto.sh`,
  `init_7_install_haproxy.sh`. Run end to end twice.
- Expose: `pf_1_viz_dashboard.sh`, `pf_2_grafana_dashboard.sh`,
  `pf_3_headlamp_dashboard.sh`, `pf_4_haproxy_forward.sh`. The first
  three are macOS-only (`pbcopy`, `open`).
- Mesh: `dev_1_mesh_emojivoto.sh`, `dev_2_mesh_haproxy.sh`, both `<mesh|unmesh>`.
- Modify: `dev_3_modify_linkerd_cores.sh [NS] [WORKLOAD] [CORES]`.
- Inspect, read-only: `dev_4_inspect_cores.sh` (annotation, env,
  proxy startup decision, tokio_rt_workers) and
  `wip_1_proxy_runtime.sh` (KEY=VALUE snapshot for diffing).
- Load: `test_load_1_local_tunnel.sh` (through whatever publishes
  localhost:8080), `test_load_2_docker_nodeport.sh` (container on the `kind`
  network, straight at the NodePort, derives node IP and port),
  `wip_3_measured.sh` (before/after deltas),
  `wip_4_sampled.sh` (per-interval sampling, finds peaks).
- Teardown: `cleanup_1_cluster.sh`.
- `Makefile` and `corestest.yaml` remain at the root.

### Measurements that shape decisions

- Path cost, `-c 125 -d 3s`, same target: container to NodePort 52.7k
  RPS p50 713us; host through a socat bridge 26.0k p50 4.42ms; host
  through `kubectl port-forward` 20.8k p50 5.68ms. Most of the loss is
  the macOS-to-Docker-VM boundary, not kubectl: the bridge has no API
  server in its path and still halves throughput. This revises the
  "port-forward halves your numbers" learning in
  `checklist_load_test_linkerd.md`, which has not been updated.
- CPU is measured from each proxy's own `process_cpu_seconds_total`,
  read synchronously. cAdvisor is unusable for runs under ~2 minutes:
  its 10s scrape lag understated a 30s run by half (24.97s vs 48.90s),
  though the cumulative counters agree to three significant figures once
  settled.
- The kubelet ships a trimmed cAdvisor: `container_threads` and
  `container_cpu_cfs_throttled_seconds_total` do not exist in this
  cluster. Thread count comes from the proxy's `process_threads`.
- `capacity.pods = 110` on the node: the upstream kubelet default, not a
  kind or Kubernetes-wide constraint.

### Related

- Sibling concern `checklist_load_test_linkerd.md`. Its task 10 (move to
  an SSH-reachable VM) is task 26 here. It still cites the old script
  paths `set_cores.sh` and `mesh_haproxy.sh`, deliberately left alone as
  another concern's record.
- Proxy source: `/Users/apoorv/projects/linkerd2-proxy` (branch
  `tokio-blocking-metrics`, uncommitted) and
  `/Users/apoorv/projects/buoyant-proxy`, byte-identical on everything
  metrics-related.

## Open questions

- `make health-check` curls `localhost:8090`, but
  `pf_4_haproxy_forward.sh` forwards to `localhost:8080`. One is stale.
  Blocks nothing; the Makefile target reports a false failure until
  settled.
- Does the kind config need `extraPortMappings`? Now a live design
  question rather than a blocker: it is the only host-side path with no
  relay, and task 26 needs it on the VM. Task 20 holds the detail.
- Where should the scripts run for the VM: on the VM over SSH, or on the
  laptop against a tunnelled API server? Blocks task 26.
- Is SSH to the VM direct on a public IP or via a bastion? Decides
  whether a published port is reachable at all. Blocks task 26.

### Resolved

- Nothing installed linkerd-viz though Grafana needed it. Now
  `init_3_install_linkerd_viz.sh`, between the control plane and Grafana.
- Whether the scripts include cluster creation: yes, init_1 runs
  `kind create cluster`, so the chain starts from nothing.
- `test_load_2_docker_nodeport.sh` hardcoded `172.18.0.2:31605`. Confirmed
  broken after a rebuild (31605 gave `000`, the real port gave 200). It
  now derives both values, and task 19 pinned the port at 31080.
- Which of the old cluster's properties matter: settled in task 2. The
  15 CPUs and 8GB are Docker Desktop's allocation, a host prerequisite,
  not reproducible from this repo.
