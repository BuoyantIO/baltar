use std::process::ExitCode;
use std::time::Instant;

use clap::Parser;
use l4_proto_inspector::core::Mode;
use l4_proto_inspector::core::assert::{AssertConfig, AssertName, AssertPlan, Outcome};
use l4_proto_inspector::error::InspectorError;
use l4_proto_inspector::shell::{LogSink, Proxy, Record, Shutdown};
use tokio::sync::mpsc::{self, UnboundedReceiver};

/// Command-line flags.
#[derive(Parser)]
#[command(
    name = "l4_proto_inspector",
    version,
    about = "L4 middle proxy that logs what it sees",
    after_help = "With --assert, the run checks one connection and exits 0 (pass), 1 (fail) or 2 (error)."
)]
struct Cli {
    /// Address to accept clients on, e.g. 0.0.0.0:15432.
    #[arg(long)]
    listen: String,
    /// Address of the app to forward to, e.g. 127.0.0.1:9000.
    #[arg(long)]
    upstream: String,
    /// Inspector to run on client-to-app bytes; repeat to chain them in order.
    #[arg(long = "mode", value_name = "raw|pp", default_value = "raw")]
    modes: Vec<Mode>,
    /// Assertion to run on the one connection; repeat to activate several, run in flag order.
    #[arg(long = "assert", value_name = "NAME")]
    asserts: Vec<AssertName>,
    /// Identity `--assert pp_test` expects in PROXY v2 TLV 0xE0, compared exactly.
    #[arg(long, value_name = "ID")]
    pp_identity: Option<String>,
}

/// Process exit codes; the code is the verdict of an `--assert` run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Exit {
    /// Every assertion passed, or a plain run ended cleanly.
    Pass,
    /// An assertion reported a failing finding.
    Fail,
    /// Bad flags, bind, dial or signal setup failed; also clap's own usage-error code.
    Error,
}

impl Exit {
    /// Maps a run's result to its exit code.
    fn classify(result: Result<Outcome, InspectorError>) -> Self {
        match result {
            Ok(Outcome::Pass) => Exit::Pass,
            Ok(Outcome::Fail) => Exit::Fail,
            Err(_) => Exit::Error,
        }
    }

    /// The numeric process exit code.
    fn code(self) -> u8 {
        match self {
            Exit::Pass => 0,
            Exit::Fail => 1,
            Exit::Error => 2,
        }
    }
}

impl Cli {
    /// Validates flags, then serves until killed, or checks one connection when `--assert` is given.
    async fn run(self, sink: LogSink) -> Result<Outcome, InspectorError> {
        // A plugin missing its mode or flags can never pass, so refuse to start.
        let plan = AssertPlan::new(
            self.asserts,
            &self.modes,
            AssertConfig {
                pp_identity: self.pp_identity,
            },
        )?;
        // Catch signals before binding, so an early SIGTERM still ends in a verdict.
        let shutdown = if plan.is_active() {
            Some(Shutdown::listen()?)
        } else {
            None
        };

        let proxy = Proxy::bind(&self.listen, self.upstream, self.modes, sink).await?;
        // The bound address, so callers of `--listen host:0` can find the port.
        eprintln!("listening on {}", proxy.local_addr()?);

        // Without assertions there is no verdict: serve until killed, as a plain proxy.
        let Some(shutdown) = shutdown else {
            proxy.run().await?;
            return Ok(Outcome::Pass);
        };

        // One connection, then report every finding as one stderr line each.
        let report = proxy.run_once(&plan, shutdown.wait()).await?;
        for finding in &report.findings {
            eprintln!("{finding}");
        }
        eprintln!("verdict: {}", report.outcome);
        Ok(report.outcome)
    }

    /// Prints each record as one JSON line on stdout until every sink is dropped.
    async fn print_events(mut rx: UnboundedReceiver<Record>) {
        while let Some(record) = rx.recv().await {
            match serde_json::to_string(&record) {
                Ok(line) => println!("{line}"),
                Err(e) => eprintln!("serialize event: {e}"),
            }
        }
    }
}

#[tokio::main]
async fn main() -> ExitCode {
    let start = Instant::now();
    // clap exits 2 on usage errors itself, matching `Exit::Error`.
    let cli = Cli::parse();
    let (tx, rx) = mpsc::unbounded_channel();
    let printer = tokio::spawn(Cli::print_events(rx));

    // The run owns the only sender, so once it returns the printer drains and ends.
    let result = cli.run(LogSink::new(tx, start)).await;
    if let Err(e) = &result {
        eprintln!("{e}");
    }
    let _ = printer.await;
    ExitCode::from(Exit::classify(result).code())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `--assert` defaults to none, and an unknown name is a clap parse error.
    ///
    /// Setup: parse argv without `--assert`, then with `--assert nope`.
    /// Catches: plain runs gaining assertions, or an unknown name accepted and ignored.
    #[test]
    fn assert_flag_parses() {
        // Without the flag no assertion is active.
        let base = ["l4_proto_inspector", "--listen", "a:1", "--upstream", "b:2"];
        let cli = Cli::try_parse_from(base).unwrap();
        assert!(cli.asserts.is_empty());

        // An unregistered name fails parsing with clap's value-validation error.
        let err = Cli::try_parse_from(base.iter().chain(&["--assert", "nope"])).err();
        assert_eq!(
            err.map(|e| e.kind()),
            Some(clap::error::ErrorKind::ValueValidation)
        );

        // `pp_test` and its identity flag parse together.
        let argv = base
            .iter()
            .chain(&["--assert", "pp_test", "--pp-identity", "a.b"]);
        let cli = Cli::try_parse_from(argv).unwrap();
        assert_eq!(cli.asserts, [AssertName::PpTest]);
        assert_eq!(cli.pp_identity.as_deref(), Some("a.b"));
    }

    /// Clap's usage errors exit 2, the same code as any other setup error.
    ///
    /// Setup: parse argv with an unknown `--assert` name and with `--listen` missing.
    /// Catches: a typo in flags exiting 1 and being read as an assertion failure.
    #[test]
    fn usage_errors_exit_2() {
        // An unknown assertion and a missing required flag both exit with `Exit::Error`.
        let base = ["l4_proto_inspector", "--listen", "a:1", "--upstream", "b:2"];
        let unknown = Cli::try_parse_from(base.iter().chain(&["--assert", "nope"])).err();
        let missing = Cli::try_parse_from(["l4_proto_inspector", "--upstream", "b:2"]).err();
        for err in [unknown, missing] {
            assert_eq!(
                err.map(|e| e.exit_code()),
                Some(i32::from(Exit::Error.code()))
            );
        }
    }

    /// Pass, fail and every error map to exit codes 0, 1 and 2.
    ///
    /// Setup: classify each outcome and two kinds of error.
    /// Catches: a setup error exiting 1, which a caller would read as an assertion failure.
    #[test]
    fn classify_exit_codes() {
        // Outcomes map to 0 and 1.
        assert_eq!(Exit::classify(Ok(Outcome::Pass)).code(), 0);
        assert_eq!(Exit::classify(Ok(Outcome::Fail)).code(), 1);

        // Setup and runtime errors both map to 2.
        assert_eq!(Exit::classify(Err(InspectorError::Bind)).code(), 2);
        assert_eq!(Exit::classify(Err(InspectorError::Dial)).code(), 2);
    }
}
