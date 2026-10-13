# Writing an assertion plugin

An assertion plugin is a sans-IO check that reads the events the `--mode` chain produces on one connection and reports `Finding`s. With any `--assert`, the binary checks its first connection, prints each finding on stderr, and exits 0 (pass), 1 (fail) or 2 (error). We use `pp_test` (`src/core/assert/pp_test.rs`) as the worked example throughout.

## How events reach plugins

```
 client bytes
     |
     v
 Chain (--mode pp --mode raw)  ---- forward ---->  app
     |  ChainOutput.events: PpHeader, Chunk, Closed
     v
 Assertions::observe  -->  each plugin's event(), in --assert order
     |  open() / eof() / close() hooks around it
     v
 Assertions::close  -->  Report { findings, outcome }
     |
     v
 main.rs: one stderr line per Finding, "verdict: PASS|FAIL", exit 0 / 1 / 2
```

Only client-to-app events reach plugins: `Conn::request` in `src/shell/proxy.rs` calls `Assertions::observe`, while the response loop only logs.

## The `Assertion` hooks

The trait lives in `src/core/assert/mod.rs`. Each hook returns an `AssertOutput`: findings plus a `Verdict`.

- `name`: the name shown in findings; `pp_test` returns `PpTest::NAME`.
- `open`: the connection was accepted, before any bytes; defaults to `AssertOutput::none()`.
- `event`: one `Event` from the chain, in chain order; required.
- `eof`: client eof; defaults to no findings.
- `close`: the connection is ending; required, and the last chance to report.

Rules we follow:

- Build findings with `Finding::pass` or `Finding::fail`, one per checked field.
  - `pp_test` reports `command`, `family`, `src`, `dst port` and `tlv 0xe0` from `PpTest::check_header`.
- A plugin waiting for an event it never sees must fail from `close`, so silence never passes.
  - `pp_test` reports `pp header` absent in `close`, quoting the first `Event::Closed` reason it saw.
- Return `AssertOutput::report` to keep the connection open; set `verdict: Verdict::Close(reason)` only to end it early.
- `Assertions` runs every plugin on every hook even after a `Close`, so each plugin's findings stay complete.
- The run fails if any finding fails (`Assertions::close`); plugins do not compute the overall `Outcome`.
- Plugins are built fresh per connection by `AssertPlan::build_assertions`, so per-connection state is plain fields (`PpTest::seen`).

## Registering a name

The registry is `src/core/assert/registry.rs`. To add a plugin:

1. Add `src/core/assert/<name>.rs` with the plugin struct, a `NAME` constant and `impl Assertion`; declare it with `mod` and `pub use` in `src/core/assert/mod.rs`.
2. Add a variant to `AssertName` and an arm in each of `AssertName::as_str`, `FromStr for AssertName`, `AssertName::required_mode` and `AssertName::configure`.
3. Add a `PluginConfig` variant holding the plugin's validated settings, with arms in `PluginConfig::build` and `PluginConfig::name`.

An unknown `--assert` name fails `FromStr` with `InspectorError::UnknownAssert`; clap reports it as a usage error, which exits 2.

## Declaring the required mode and flags

- `AssertName::required_mode` returns the `Mode` whose events the plugin reads; `pp_test` returns `Mode::Pp`, since only `Pp` emits `Event::PpHeader`.
- `AssertPlan::new` rejects a plugin whose mode is not in `--mode` with `InspectorError::MissingMode`, before binding.
- A plugin-specific flag needs three edits:
  - a field on `Cli` in `src/main.rs` (as `pp_identity`), copied into `AssertConfig` in `Cli::run`;
  - an `Option` field on `AssertConfig` (as `AssertConfig::pp_identity`);
  - an arm in `AssertName::configure` that maps a missing value to `InspectorError::MissingFlag`.
- Values known only after binding come from `PluginConfig::build`; `pp_test` gets the bound port there as `PpTestConfig::listen_port`, so `--listen host:0` works.
- A plugin needing a new inspector first needs a `Mode` variant in `src/core/mode.rs` with its `Display` and `FromStr` arms.

## Core tests

We test plugins without sockets: a `Chain` feeds an `Assertions` holding the plugin, then we assert on the `Report`.

- In the plugin file, a `Fixture::run` drives `open`, `observe` on `Chain::feed` and `Chain::eof` events, `eof`, then `close`.
  - `pp_test` covers pass, each failing field, a missing header (`no_header`), and helpers such as `classify_src`.
- In `registry.rs`, a test like `pp_test_registered` checks the name round-trips and the required mode.
- A test like `pp_test_missing_flag_errors` checks the `MissingFlag` message and that a missing mode is reported first.
- The test-only `AssertName::Probe` exercises the registry without depending on a real plugin.
- Binary tests in `tests/localhost.rs` spawn the real binary through `Inspector` in `tests/harness/mod.rs` and check `RunOutcome::code`.
  - Examples: `assert_right_identity_exits_0`, `assert_wrong_identity_exits_1`, `assert_unknown_name_exits_2`.

Run them with `cargo test` in this crate.

## Exit codes

`Exit::classify` in `src/main.rs` maps the run's result to the process exit code:

- 0: every finding passed (`Outcome::Pass`).
- 1: at least one finding failed (`Outcome::Fail`), including a run stopped before any client (`AssertPlan::report_no_connection`).
- 2: any `InspectorError`, such as `UnknownAssert`, `MissingMode`, `MissingFlag`, `Bind` or `Dial`, and clap usage errors.

A `Relay` error mid-connection does not exit 2: `Proxy::run_once` still reports the findings gathered so far, so a real result is not hidden. A SIGTERM or SIGINT (`Shutdown`) ends the run the same way.
