# Examples

We keep each example as a thin composition of existing scripts, so it shows a workflow without duplicating logic.

## Examples

- `grafana`: cluster with Linkerd, viz and Grafana, then a port-forward to the dashboard.
  - Runs `init_0` to `init_4`, then `pf_2_grafana_dashboard.sh`.
- `custom_image`: builds a custom proxy and Linkerd control plane, installs them and verifies.
  - Runs `build_1_proxy.sh` to `build_5_verify_linkerd2.sh`.
- `bel`: installs BEL, deploys the echo app and drives load with fortio.
  - Runs `init_2_install_bel.sh`, `init_9_deploy_echo.sh`, `test_load_3_fortio.sh`.
- `load_test`: measures resource use around a load run.
  - Runs `dev_5_measure_start.sh`, one `test_load_*` script, `dev_6_measure_stop.sh`.
- `multicluster`: two-cluster mirror setup with one exported service.
  - Runs `mc_0_trust_anchor.sh`, `init_1` (east and west), `init_2` (both), `mc_1_multicluster.sh`, then applies its own manifests and `diagnose.sh`.

## Rules

- Each example is a folder `scripts/examples/<name>/` with one `run.sh`.
- `run.sh` only calls scripts one directory up (`scripts/*`, `scripts/app/*`), in order.
- We add no logic to `run.sh` that belongs in a script.
  - We create that script in `scripts/` instead, in the matching category: `init`, `dev`, `test`, `build`, `pf`.
- Inputs are env vars with defaults.
- `run.sh` is idempotent wherever the scripts it calls are.
- `run.sh` ends by naming its cleanup: `scripts/cleanup_1_cluster.sh` or an app cleanup.
