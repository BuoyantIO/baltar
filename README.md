# baltar

We stand up a Linkerd test cluster and measure it: CPU per container, latency per hop, meshed vs. unmeshed, under load. The cluster is a local `kind` cluster by default.

## Prerequisites

- Docker, `kind`, `kubectl`, `helm`, the `linkerd` CLI, `curl` and the Go (mikefarah) `yq`.
  - `scripts/init_0_prerequisites.sh` checks these and lists the optional tools (`step`, `bombardier`, `jq`).
- BEL
  - a `.no_commit_bel` file in the repo root with a line `BUOYANT_LICENSE=<license>`: `cp .no_commit_bel_example .no_commit_bel`, then fill in the license.
- Both macOS or Linux are supported for majority of operations.
- Linux
  - Compiling the Linkerd proxy source, because it uses Linux-only networking code.
  - Checking a custom Linkerd build, because the CLI it produces runs only on Linux.
  - Building the protocol inspector, because its image expects a binary built on Linux.

## Quick start

- Run `scripts/init_0_prerequisites.sh` first; it fails fast if the host lacks a requirement.
- Run `scripts/init_1` to `scripts/init_7` in order; `init_2_install_bel.sh` replaces `init_2_install_linkerd.sh` for BEL.
- Or run `scripts/examples/grafana/run.sh` for Linkerd, viz and Grafana in one step.
- HAProxy sits on NodePort `31080` (`HAPROXY_NODEPORT`), published to the host on `localhost:8080` via `scripts/pf_4_haproxy_forward.sh`.
- Run `scripts/cleanup_1_cluster.sh` to tear everything down.

## More

- Script catalog and conventions: `scripts/CLAUDE.md`.
- Example compositions: `scripts/examples/CLAUDE.md`.
- Measurement method and setup traps: `USAGE.md`.
- Project structure and rules: `CLAUDE.md`.
- Load test results: `results.md`.
