# Scripts

We keep one step per script, named `<category>_<n>_<purpose>`. The header of each script holds its `# Usage:` line and env vars; we read it before running.

## Catalog

### init: cluster and component setup

- `init_0_prerequisites.sh`: checks the machine can run the init steps.
- `init_1_create_cluster.sh`: creates the kind cluster and installs the Gateway API CRDs.
  - `init_1_create_cluster.yaml`: kind config that publishes the NodePort to the host.
- `init_2_install_bel.sh`: installs BEL (Buoyant Enterprise for Linkerd).
- `init_2_install_linkerd.sh`: installs the Linkerd control plane with the `linkerd` CLI on PATH.
- `init_3_install_linkerd_viz.sh`: installs linkerd-viz, whose Prometheus Grafana reads.
- `init_4_install_grafana.sh`: installs Grafana wired to the viz Prometheus.
- `init_5_install_headlamp.sh`: installs the Headlamp cluster UI.
- `init_6_deploy_emojivoto.sh`: deploys the emojivoto demo app.
- `init_7_install_haproxy.sh`: installs the HAProxy ingress and the Ingress to emojivoto.
- `init_8_install_cpu_probe.sh`: installs the cpu-probe DaemonSet that exposes cgroup CPU counters.
  - `init_8_cpu_probe.yaml`: the DaemonSet manifest.
- `init_9_deploy_echo.sh`: deploys the meshed echo server in ns `demo`.
  - `init_9_echo.yaml`: the namespace and echo manifests.

### dev: mesh, tune, measure and inspect

- `dev_1_mesh_emojivoto.sh`: meshes or unmeshes emojivoto.
- `dev_2_mesh_haproxy.sh`: meshes or unmeshes HAProxy, optionally pinning proxy cores.
- `dev_3_modify_linkerd_cores.sh`: sets the proxy core count on a workload.
- `dev_4_inspect_cores.sh`: shows the proxy core setting of a workload.
- `dev_5_measure_start.sh`: starts a CPU sampling run for one workload.
- `dev_6_measure_stop.sh`: ends the run and prints the CSV path.
- `dev_7_scale_workloads.sh`: sets replica counts for emojivoto and HAProxy.
- `dev_8_wireshark_capture.sh`: captures a workload's traffic for Wireshark or a pcap file.
- `dev_9_proxy_memory.sh`: prints proxy Rss and AnonHugePages per pod from its kind node.

### test: load tests

- `test_load_1_local_tunnel.sh`: load test through whatever publishes `localhost:8080`.
- `test_load_2_docker_nodeport.sh`: load test at the NodePort from a Docker container, no tunnel.
- `test_load_3_fortio.sh`: meshed fortio client holding long-lived connections to `TARGET_URL`.
  - `test_load_3_fortio.yaml`: the fortio Deployment manifest.

### build: custom Linkerd builds

- `build_1_proxy.sh`: builds the linkerd2-proxy image from a ref.
- `build_2_linkerd2.sh`: builds the linkerd2 images from a ref.
- `build_3_install_custom_linkerd.sh`: installs the images built by steps 1 and 2.
- `build_4_verify_proxy.sh`: verifies the installed proxy is the custom build.
- `build_5_verify_linkerd2.sh`: verifies the installed control plane is the custom build.

### pf: port-forwards and dashboards

- `pf_1_viz_dashboard.sh`: opens the linkerd-viz dashboard.
- `pf_2_grafana_dashboard.sh`: opens Grafana with the admin password on the clipboard.
- `pf_3_headlamp_dashboard.sh`: opens Headlamp with a fresh token on the clipboard.
- `pf_4_haproxy_forward.sh`: forwards the HAProxy ingress to `http://localhost:8080`.

### cleanup

- `cleanup_1_cluster.sh`: deletes the kind cluster, which removes everything the init steps installed.

### util: shared helpers

- `util_build.sh`: helpers for build, verify and repro scripts.
- `util_measure.sh`: helpers for the CPU sampler.
- `util_kube.sh`: `k` (kubectl on `CONTEXT`).

### app: scripts for the apps we test

- `app/inspector_1_build_image.sh`: builds the `l4_proto_inspector` image.
- `app/inspector_2_deploy.sh`: deploys the inspector into ns `inspect`.
  - `app/inspector_2_deploy.yaml`: the inspector manifests.
- `app/inspector_3_send.sh`: sends a marker through the inspector and checks the echo.
- `app/inspector_4_verify.sh`: checks the inspector log shows the PROXY v2 header with the client identity.
- `app/inspector_5_cleanup.sh`: deletes ns `inspect`.
- `app/repro_1_deploy_pgppi.sh`: deploys pgppi, cert-manager, CloudNativePG and a Postgres cluster.
- `app/repro_2_e2e.sh`: runs the pg-ppi e2e tests.
- `app/repro_3_negative.sh`: runs negative checks against the repro cluster.

### examples

- `examples/`: runnable compositions of the scripts above; see `examples/CLAUDE.md`.

## Conventions

- A new script goes into an existing category and takes the next number in it.
  - We create a category only when none fits.
- Each script does one step so others can compose it.
  - Examples in `scripts/examples/` call scripts and hold no logic of their own (see `examples/CLAUDE.md`).
- Keeping bash simple is the main goal.
- Scripts run from the repo root; paths are relative to it, with no `SCRIPT_DIR`.
- Inputs are env vars, documented in the header.
  - Inputs naming what the script talks to (target URL, namespace) are required, with no default.
- We add no safety checks unless asked; the failing command reports the error.
- Manifests carry `<NAME_PLACEHOLDER>` tokens that the script replaces with `${text//<NAME_PLACEHOLDER>/$value}`.
- The header holds a `# Usage:` line and the env vars with their defaults.
- Shared helpers go in `util_` files, are sourced and never run.
  - We source them directly below the shebang, with no guard.
  - The caller owns `set -euo pipefail`.
- We write and edit `.sh` files only through the `coder-shell-script` agent.
- Manifests sit beside the script that applies them and share its name prefix.
- We add every new script to the catalog above in the same change.
