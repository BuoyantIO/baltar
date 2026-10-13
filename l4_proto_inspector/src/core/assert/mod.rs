use std::fmt;

use super::{Event, Verdict};

/// The `pp_test` plugin: checks the PROXY v2 header Linkerd sends.
mod pp_test;
/// `--assert` names, their required modes and flags, and per-connection plugin construction.
mod registry;

pub use pp_test::{PpTest, PpTestConfig};
pub use registry::{AssertConfig, AssertName, AssertPlan};

/// One sans-IO check over a single connection; `Assertions` runs several in activation order.
///
/// Every hook may report findings. A plugin that waits for an event it never sees must report
/// a failing finding from `close`, so a run without that event cannot pass silently.
pub trait Assertion: Send {
    /// Name used in findings, e.g. `pp_test`.
    fn name(&self) -> &'static str;
    /// Handles the connection being accepted, before any bytes.
    fn open(&mut self) -> AssertOutput {
        AssertOutput::none()
    }
    /// Handles one event the chain produced, in chain order.
    fn event(&mut self, event: &Event) -> AssertOutput;
    /// Handles client eof.
    fn eof(&mut self) -> AssertOutput {
        AssertOutput::none()
    }
    /// Handles the connection closing; the last chance to fail on a missing event.
    fn close(&mut self) -> AssertOutput;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// Pass or fail, for one finding or a whole run.
pub enum Outcome {
    /// The check held.
    Pass,
    /// The check did not hold.
    Fail,
}

impl fmt::Display for Outcome {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Outcome::Pass => write!(f, "PASS"),
            Outcome::Fail => write!(f, "FAIL"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
/// One checked field: which assertion, what it expected, what it saw, and whether that held.
pub struct Finding {
    /// Name of the assertion that reported it.
    pub assertion: &'static str,
    /// Field checked, e.g. `tlv 0xe0`.
    pub field: String,
    /// Expected value or the rule it must satisfy.
    pub expected: String,
    /// Value observed on the connection.
    pub observed: String,
    /// Whether the observed value met the expectation.
    pub outcome: Outcome,
}

impl Finding {
    /// Builds a passing finding.
    pub fn pass(
        assertion: &'static str,
        field: impl Into<String>,
        expected: impl Into<String>,
        observed: impl Into<String>,
    ) -> Self {
        Self::build(assertion, field, expected, observed, Outcome::Pass)
    }

    /// Builds a failing finding.
    pub fn fail(
        assertion: &'static str,
        field: impl Into<String>,
        expected: impl Into<String>,
        observed: impl Into<String>,
    ) -> Self {
        Self::build(assertion, field, expected, observed, Outcome::Fail)
    }

    /// Shared constructor behind `pass` and `fail`.
    fn build(
        assertion: &'static str,
        field: impl Into<String>,
        expected: impl Into<String>,
        observed: impl Into<String>,
        outcome: Outcome,
    ) -> Self {
        Self {
            assertion,
            field: field.into(),
            expected: expected.into(),
            observed: observed.into(),
            outcome,
        }
    }
}

/// Renders as one line, so each finding is one stderr line a human can grep.
impl fmt::Display for Finding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{} {} {}: expected {:?}, observed {:?}",
            self.outcome, self.assertion, self.field, self.expected, self.observed
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
/// What one assertion hook produced.
pub struct AssertOutput {
    /// Findings, in the order checked.
    pub findings: Vec<Finding>,
    /// `Close` lets a failed check end the connection early.
    pub verdict: Verdict,
}

impl AssertOutput {
    /// No findings; keep the connection open.
    pub fn none() -> Self {
        Self::report(Vec::new())
    }

    /// Reports `findings` and keeps the connection open.
    pub fn report(findings: Vec<Finding>) -> Self {
        Self {
            findings,
            verdict: Verdict::Continue,
        }
    }
}

/// Every activated assertion for one connection, run on every hook in activation order.
pub struct Assertions {
    /// Plugins in activation order.
    plugins: Vec<Box<dyn Assertion>>,
    /// Findings from every hook so far, in the order reported.
    findings: Vec<Finding>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
/// The end of a connection's checks: every finding and the run's outcome.
pub struct Report {
    /// Every finding, in the order reported.
    pub findings: Vec<Finding>,
    /// `Fail` if any finding failed, else `Pass`.
    pub outcome: Outcome,
}

impl Assertions {
    /// Wraps fresh plugins for one connection, in activation order.
    pub fn new(plugins: Vec<Box<dyn Assertion>>) -> Self {
        Self {
            plugins,
            findings: Vec::new(),
        }
    }

    /// Runs every plugin's `open` hook.
    pub fn open(&mut self) -> Verdict {
        self.run_hook(|p| p.open())
    }

    /// Runs every plugin's `event` hook on each event, in event order.
    pub fn observe(&mut self, events: &[Event]) -> Verdict {
        // Every event reaches every plugin even after a close, so each plugin's findings are complete.
        let mut verdict = Verdict::Continue;
        for event in events {
            let step = self.run_hook(|p| p.event(event));
            if verdict == Verdict::Continue {
                verdict = step;
            }
        }
        verdict
    }

    /// Runs every plugin's `eof` hook.
    pub fn eof(&mut self) -> Verdict {
        self.run_hook(|p| p.eof())
    }

    /// Runs every plugin's `close` hook and returns the report; consuming `self` runs it once.
    pub fn close(mut self) -> Report {
        // The connection is already ending, so a `Close` from this hook changes nothing.
        let _ = self.run_hook(|p| p.close());
        // One failing finding from any plugin fails the whole run.
        let outcome = if self.findings.iter().any(|f| f.outcome == Outcome::Fail) {
            Outcome::Fail
        } else {
            Outcome::Pass
        };
        Report {
            findings: self.findings,
            outcome,
        }
    }

    /// Calls `hook` on every plugin in order, keeps their findings, and returns the first `Close`.
    fn run_hook(&mut self, mut hook: impl FnMut(&mut dyn Assertion) -> AssertOutput) -> Verdict {
        // Unlike the chain, a close does not stop later plugins: each must see every hook.
        let mut verdict = Verdict::Continue;
        for plugin in &mut self.plugins {
            let out = hook(plugin.as_mut());
            self.findings.extend(out.findings);
            if verdict == Verdict::Continue {
                verdict = out.verdict;
            }
        }
        verdict
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{Chain, Mode, Pp};

    /// Test-only plugins and inputs.
    struct Fixture;

    /// Reports one finding per hook, named after the hook, failing or closing at chosen hooks.
    struct Probe {
        /// Name reported in findings.
        name: &'static str,
        /// Hook at which the finding fails; every other hook passes.
        fail_at: Option<&'static str>,
        /// Hook at which the plugin returns `Close`.
        close_at: Option<&'static str>,
    }

    impl Probe {
        /// Builds the finding and verdict for `hook`.
        fn step(&self, hook: &'static str) -> AssertOutput {
            let finding = if self.fail_at == Some(hook) {
                Finding::fail(self.name, hook, "ok", "bad")
            } else {
                Finding::pass(self.name, hook, "ok", "ok")
            };
            AssertOutput {
                findings: vec![finding],
                verdict: if self.close_at == Some(hook) {
                    Verdict::Close(self.name.to_string())
                } else {
                    Verdict::Continue
                },
            }
        }
    }

    impl Assertion for Probe {
        fn name(&self) -> &'static str {
            self.name
        }
        fn open(&mut self) -> AssertOutput {
            self.step("open")
        }
        fn event(&mut self, _event: &Event) -> AssertOutput {
            self.step("event")
        }
        fn eof(&mut self) -> AssertOutput {
            self.step("eof")
        }
        fn close(&mut self) -> AssertOutput {
            self.step("close")
        }
    }

    /// Passes once it sees a `PpHeader`; fails at close if it never did.
    #[derive(Default)]
    struct SawHeader {
        /// Whether a `PpHeader` event arrived.
        seen: bool,
    }

    impl Assertion for SawHeader {
        fn name(&self) -> &'static str {
            "saw_header"
        }
        fn event(&mut self, event: &Event) -> AssertOutput {
            // Only the header matters; chunks and closes are ignored.
            if !matches!(event, Event::PpHeader { .. }) {
                return AssertOutput::none();
            }
            self.seen = true;
            AssertOutput::report(vec![Finding::pass(
                self.name(),
                "pp header",
                "present",
                "present",
            )])
        }
        fn close(&mut self) -> AssertOutput {
            // A connection that never carried the header must not pass by silence.
            if self.seen {
                return AssertOutput::none();
            }
            AssertOutput::report(vec![Finding::fail(
                self.name(),
                "pp header",
                "present",
                "absent",
            )])
        }
    }

    impl Fixture {
        /// Boxes a `Probe`.
        fn probe(
            name: &'static str,
            fail_at: Option<&'static str>,
            close_at: Option<&'static str>,
        ) -> Box<dyn Assertion> {
            Box::new(Probe {
                name,
                fail_at,
                close_at,
            })
        }

        /// A PROXY v2 TCP4 header with no TLVs: 10.0.0.1:1000 -> 10.0.0.2:15432.
        fn pp_header() -> Vec<u8> {
            let mut h = Pp::SIGNATURE.to_vec();
            h.extend_from_slice(&[0x21, 0x11, 0x00, 0x0C]);
            h.extend_from_slice(&[10, 0, 0, 1, 10, 0, 0, 2]);
            h.extend_from_slice(&1000u16.to_be_bytes());
            h.extend_from_slice(&15432u16.to_be_bytes());
            h
        }

        /// Drives `chain` and `asserts` through one connection carrying `data`, then closes.
        fn run(mut chain: Chain, mut asserts: Assertions, data: &[u8]) -> Report {
            asserts.open();
            let out = chain.feed(data);
            asserts.observe(&out.events);
            asserts.observe(&chain.eof().events);
            asserts.eof();
            asserts.close()
        }
    }

    /// Plugins all passing yield a passing report with every hook's findings in activation order.
    ///
    /// Setup: two passing probes driven through open, two events, eof and close.
    /// Catches: hooks skipped, plugins run out of order, or a pass reported as fail.
    #[test]
    fn all_pass() {
        // Two probes that never fail.
        let mut asserts = Assertions::new(vec![
            Fixture::probe("a", None, None),
            Fixture::probe("b", None, None),
        ]);
        let ev = Event::Closed { reason: "x".into() };

        // Each hook continues while nothing closes.
        assert_eq!(asserts.open(), Verdict::Continue);
        assert_eq!(asserts.observe(&[ev.clone(), ev]), Verdict::Continue);
        assert_eq!(asserts.eof(), Verdict::Continue);
        let report = asserts.close();

        // Findings follow hook order, and within a hook, activation order.
        let seen: Vec<_> = report
            .findings
            .iter()
            .map(|f| (f.assertion, f.field.as_str()))
            .collect();
        assert_eq!(
            seen,
            vec![
                ("a", "open"),
                ("b", "open"),
                ("a", "event"),
                ("b", "event"),
                ("a", "event"),
                ("b", "event"),
                ("a", "eof"),
                ("b", "eof"),
                ("a", "close"),
                ("b", "close"),
            ]
        );
        assert_eq!(report.outcome, Outcome::Pass);

        // No plugins means nothing failed.
        assert_eq!(Assertions::new(Vec::new()).close().outcome, Outcome::Pass);
    }

    /// One failing finding from any plugin fails the run while other plugins' findings are kept.
    ///
    /// Setup: probe `a` passes, probe `b` fails at eof.
    /// Catches: a later pass masking an earlier failure, or a failing plugin hiding the others.
    #[test]
    fn one_fail_fails_run() {
        // b fails only at eof; a passes everywhere.
        let mut asserts = Assertions::new(vec![
            Fixture::probe("a", None, None),
            Fixture::probe("b", Some("eof"), None),
        ]);
        asserts.open();
        asserts.eof();
        let report = asserts.close();

        // The run fails and exactly b's eof finding is the failure.
        assert_eq!(report.outcome, Outcome::Fail);
        let failed: Vec<_> = report
            .findings
            .iter()
            .filter(|f| f.outcome == Outcome::Fail)
            .collect();
        assert_eq!(failed.len(), 1);
        assert_eq!(
            (failed[0].assertion, failed[0].field.as_str()),
            ("b", "eof")
        );
        assert_eq!(report.findings.len(), 6);
    }

    /// A plugin that never sees its event fails at close; one that does passes.
    ///
    /// Setup: `Chain` with `pp` then `raw`, fed a real PROXY v2 header, then plain bytes.
    /// Catches: a run with no header passing because no finding was reported.
    #[test]
    fn fail_at_close() {
        // With the header, the plugin passes on the event and stays silent at close.
        let mut data = Fixture::pp_header();
        data.extend_from_slice(b"hello");
        let report = Fixture::run(
            Chain::new(&[Mode::Pp, Mode::Raw]),
            Assertions::new(vec![Box::new(SawHeader::default())]),
            &data,
        );
        assert_eq!(report.outcome, Outcome::Pass);
        assert_eq!(
            report.findings,
            vec![Finding::pass(
                "saw_header",
                "pp header",
                "present",
                "present"
            )]
        );

        // Without pp in the chain no header event exists, so close reports the failure.
        let report = Fixture::run(
            Chain::new(&[Mode::Raw]),
            Assertions::new(vec![Box::new(SawHeader::default())]),
            b"hello",
        );
        assert_eq!(report.outcome, Outcome::Fail);
        assert_eq!(
            report.findings,
            vec![Finding::fail(
                "saw_header",
                "pp header",
                "present",
                "absent"
            )]
        );
    }

    /// The first `Close` is returned, yet every plugin still runs on that hook and on each event.
    ///
    /// Setup: probe `a` closes on event, probe `b` closes on event too; two events observed.
    /// Catches: later plugins skipped after a close, or the wrong close reason returned.
    #[test]
    fn first_close_wins_all_run() {
        // Both close on events; a is first in activation order.
        let mut asserts = Assertions::new(vec![
            Fixture::probe("a", None, Some("event")),
            Fixture::probe("b", None, Some("event")),
        ]);
        let ev = Event::Closed { reason: "x".into() };
        assert_eq!(
            asserts.observe(&[ev.clone(), ev]),
            Verdict::Close("a".into())
        );

        // Both plugins saw both events despite the close.
        assert_eq!(asserts.close().findings.len(), 6);
    }

    /// A finding renders as one line naming outcome, assertion, field, expected and observed.
    ///
    /// Setup: a failing identity finding.
    /// Catches: a multi-line or field-dropping message on stderr.
    #[test]
    fn finding_display() {
        // Quotes keep empty or spaced values visible.
        let f = Finding::fail("pp_test", "tlv 0xe0", "a.b", "c d");
        assert_eq!(
            f.to_string(),
            r#"FAIL pp_test tlv 0xe0: expected "a.b", observed "c d""#
        );
    }
}
