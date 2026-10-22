# l4_proto_inspector

We run this L4 proxy between linkerd-proxy and an app. It logs client-to-app bytes as JSON lines and, in `pp` mode, parses and strips the PROXY v2 header (including TLV 0xE0, the client identity).

## Rules

- We write and edit `.rs` files only through the `coder-rust` agent.
- `target/` is build output: we never edit or commit it.

## Layout

- `src/main.rs`: clap CLI (`--listen`, `--upstream`, repeatable `--mode raw|pp`); prints each `Record` as JSON on stdout.
- `src/lib.rs`: declares the modules below.
- `src/error.rs`: `InspectorError` and subsystem errors such as `PpError`.
- `src/util.rs`: shared helpers, e.g. hex encoding.
- `src/core/`: sans-IO, no sockets or async. We keep all parsing logic here.
  - `mod.rs`: `Inspector` trait, `Output`, `Verdict`.
  - `chain.rs`: `Chain` runs inspectors in `--mode` order on the bytes earlier ones left.
  - `event.rs`: `Event`, `FlowDirection`, `Tlv`.
  - `mode.rs`: `Mode` (CLI value to inspector).
  - `pp.rs`: `Pp`, the PROXY v2 inspector.
  - `raw.rs`: `Raw`, logs bytes unchanged.
- `src/shell/`: tokio I/O around `core/`. No parsing here.
  - `mod.rs`: re-exports.
  - `proxy.rs`: `Proxy` accepts, connects upstream, feeds the `Chain`.
  - `sink.rs`: `LogSink` and `Record`, the event output.

## Tests

- Run `cargo test` in this directory.
- `tests/localhost.rs` runs the proxy on localhost against `tests/harness/`.
- We unit-test `core/` without sockets.

## Cluster scripts

`scripts/app/inspector_1` to `inspector_5` build, deploy, exercise and clean up the inspector; see `scripts/CLAUDE.md`.
