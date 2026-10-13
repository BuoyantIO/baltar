# launchy-dev

We stand up a Linkerd test cluster and measure it: CPU per container, latency per hop, meshed vs. unmeshed, under load. The cluster is a local `kind` cluster by default.
The same scripts also run against an Azure VM for load driven over a public IP.

## Quick start

- Run `scripts/init_0_prerequisites.sh` first; it fails fast if the host lacks a requirement.
- Run `scripts/init_1` to `scripts/init_7` in order; `init_2_install_bel.sh` replaces `init_2_install_linkerd.sh` for BEL.
- Or run `scripts/examples/grafana/run.sh` for Linkerd, viz and Grafana in one step.
- HAProxy sits on NodePort `31080` (`HAPROXY_NODEPORT`), published to the host on `localhost:8080` via `scripts/pf_4_haproxy_forward.sh`.
- Run `scripts/cleanup_1_cluster.sh` to tear everything down.

## More

- Script catalog and conventions: `scripts/CLAUDE.md`.
- Example compositions: `scripts/examples/CLAUDE.md`.
- Project rules and workflow: `CLAUDE.md`.
- Measurements and findings: `knowledge.md`.
