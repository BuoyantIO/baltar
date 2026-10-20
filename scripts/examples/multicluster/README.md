# multicluster

Reference run of a two-cluster Linkerd mirror setup. Run everything from the launchy-dev repo root.

## What it does

We build two kind clusters, the default `kind` cluster and `west`, mesh both under one shared trust anchor, and mirror `west` into the local cluster in gateway mode. `west` exports its `other` service, which the local cluster mirrors as `other-west`. `diagnose.sh` compares the local `local` service with the mirror: endpoints, served page and mTLS identity.

## Run it

```
./scripts/examples/multicluster/run.sh
```

`run.sh` composes the repo scripts in order, then applies the demo manifests and runs the diagnostics:

- `scripts/mc_0_trust_anchor.sh`: tool check and shared root/issuer into `out/anchor`.
- `scripts/init_1_create_cluster.sh` with no `CLUSTER_NAME` (default `kind`) then `=west` and this folder's `kind.yaml`.
- `scripts/init_2_install_linkerd.sh` with `CONTEXT` and the anchor env, once per cluster.
- `scripts/mc_1_multicluster.sh`: multicluster install on both, MetalLB on the local cluster, and the west-into-local Link.
- `east.yaml` / `west.yaml`: the demo workloads.
- `diagnose.sh`: endpoint resolution, real traffic and proxy-metrics identity, tee'd under `OUT_DIR` (default `out/mc_<timestamp>`).

## Files

- `kind.yaml`: minimal kind config with no host port, so the local cluster and west coexist on one host.
- `east.yaml`: the `local` service (identity `local-sa.tenant`) and a meshed `client`.
- `west.yaml`: the exported `other` service (identity `other-sa.tenant`).
- `diagnose.sh`: resolution, traffic and identity capture, persisted to the results dir.

## Teardown

```
./scripts/cleanup_1_cluster.sh
CLUSTER_NAME=west ./scripts/cleanup_1_cluster.sh
```
