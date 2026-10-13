use std::fmt;
use std::str::FromStr;

use super::{Assertion, Assertions, Finding, Outcome, PpTest, PpTestConfig, Report};
use crate::core::Mode;
use crate::error::InspectorError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// Assertion selected by one `--assert` flag.
pub enum AssertName {
    /// Checks the PROXY v2 header: command, family, `src` shape, `dst` port and TLV `0xE0` identity.
    PpTest,
    /// Test-only plugin that needs `pp` and reports one passing finding at close.
    #[cfg(test)]
    Probe,
}

impl AssertName {
    /// The `--mode` this plugin reads events from; activating it without that mode is an error.
    pub fn required_mode(self) -> Mode {
        match self {
            AssertName::PpTest => Mode::Pp,
            #[cfg(test)]
            AssertName::Probe => Mode::Pp,
        }
    }

    /// Takes this plugin's settings from `config`; a required flag left unset is the error.
    fn configure(self, config: &AssertConfig) -> Result<PluginConfig, InspectorError> {
        let missing = |flag| InspectorError::MissingFlag {
            assertion: self,
            flag,
        };
        match self {
            // Without an identity there is nothing to compare TLV `0xE0` with.
            AssertName::PpTest => Ok(PluginConfig::PpTest {
                identity: config
                    .pp_identity
                    .clone()
                    .ok_or_else(|| missing("--pp-identity"))?,
            }),
            #[cfg(test)]
            AssertName::Probe => Ok(PluginConfig::Probe),
        }
    }

    /// The name accepted by `--assert`.
    pub fn as_str(self) -> &'static str {
        match self {
            AssertName::PpTest => PpTest::NAME,
            #[cfg(test)]
            AssertName::Probe => "probe",
        }
    }
}

impl fmt::Display for AssertName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for AssertName {
    type Err = InspectorError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            PpTest::NAME => Ok(AssertName::PpTest),
            #[cfg(test)]
            "probe" => Ok(AssertName::Probe),
            _ => Err(InspectorError::UnknownAssert),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
/// Plugin-specific CLI flags as given; each plugin takes what it needs when the plan is built.
pub struct AssertConfig {
    /// `--pp-identity`: exact TLV `0xE0` text `pp_test` expects.
    pub pp_identity: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
/// One activated plugin with its validated settings.
enum PluginConfig {
    /// `pp_test` with its identity; the port comes from the bound listener.
    PpTest {
        /// Exact TLV `0xE0` text expected.
        identity: String,
    },
    /// Test-only plugin with no settings.
    #[cfg(test)]
    Probe,
}

impl PluginConfig {
    /// Builds a fresh plugin for one connection accepted on `listen_port`.
    fn build(&self, listen_port: u16) -> Box<dyn Assertion> {
        match self {
            PluginConfig::PpTest { identity } => Box::new(PpTest::new(PpTestConfig {
                identity: identity.clone(),
                listen_port,
            })),
            #[cfg(test)]
            PluginConfig::Probe => Box::new(tests::Probe),
        }
    }

    /// The plugin's `--assert` name, as shown in findings.
    fn name(&self) -> &'static str {
        match self {
            PluginConfig::PpTest { .. } => AssertName::PpTest.as_str(),
            #[cfg(test)]
            PluginConfig::Probe => AssertName::Probe.as_str(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
/// Validated `--assert` selection: builds the same plugins, in flag order, for each connection.
pub struct AssertPlan {
    /// Plugins in `--assert` order, each with its settings.
    plugins: Vec<PluginConfig>,
}

impl AssertPlan {
    /// Checks every plugin's required mode, then its required flags; the first gap is the error.
    pub fn new(
        names: Vec<AssertName>,
        modes: &[Mode],
        config: AssertConfig,
    ) -> Result<Self, InspectorError> {
        // A plugin without its inspector never sees its events, so reject at startup instead.
        if let Some(name) = names.iter().find(|n| !modes.contains(&n.required_mode())) {
            return Err(InspectorError::MissingMode {
                assertion: *name,
                mode: name.required_mode(),
            });
        }
        // A plugin missing a flag has nothing to compare against, so reject at startup too.
        let plugins = names
            .into_iter()
            .map(|n| n.configure(&config))
            .collect::<Result<_, _>>()?;
        Ok(Self { plugins })
    }

    /// Whether any `--assert` was given; without one the inspector runs as a plain proxy.
    pub fn is_active(&self) -> bool {
        !self.plugins.is_empty()
    }

    /// Builds fresh plugins for one connection accepted on `listen_port`, so no state leaks between connections.
    ///
    /// The port is the one actually bound, so `--listen host:0` still checks the header's `dst` port.
    pub fn build_assertions(&self, listen_port: u16) -> Assertions {
        Assertions::new(self.plugins.iter().map(|p| p.build(listen_port)).collect())
    }

    /// Fails every plugin for a run that ended before any client connected.
    ///
    /// Without a connection no plugin saw anything, so the run must not pass by silence.
    pub fn report_no_connection(&self) -> Report {
        let findings = self
            .plugins
            .iter()
            .map(|p| Finding::fail(p.name(), "connection", "accepted", "none"))
            .collect();
        Report {
            findings,
            outcome: Outcome::Fail,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::assert::{AssertOutput, Event};
    use crate::core::{Chain, Pp, Tlv};

    /// Test-only plugin behind `AssertName::Probe`: passes once at close.
    pub(super) struct Probe;

    impl Assertion for Probe {
        fn name(&self) -> &'static str {
            "probe"
        }
        fn event(&mut self, _event: &Event) -> AssertOutput {
            AssertOutput::none()
        }
        fn close(&mut self) -> AssertOutput {
            AssertOutput::report(vec![Finding::pass("probe", "close", "ok", "ok")])
        }
    }

    /// A known name parses, round-trips through `Display`, and an unknown name is `UnknownAssert`.
    ///
    /// Setup: parse `probe` and `nope`.
    /// Catches: a typo in `--assert` silently running no check, which would pass the run.
    #[test]
    fn unknown_assert_errors() {
        // The registered name maps to its variant and back.
        let name: AssertName = "probe".parse().unwrap();
        assert_eq!(name, AssertName::Probe);
        assert_eq!(name.to_string(), "probe");

        // An unknown name errors instead of being ignored.
        assert_eq!(
            "nope".parse::<AssertName>(),
            Err(InspectorError::UnknownAssert)
        );
    }

    /// A plugin activated without its required mode is `MissingMode` naming both.
    ///
    /// Setup: `probe` (needs `pp`) with only `raw`, and with no modes.
    /// Catches: a run that can never see its event starting anyway and failing late or passing.
    #[test]
    fn missing_mode_errors() {
        // `raw` alone does not produce the events `probe` needs.
        let err = InspectorError::MissingMode {
            assertion: AssertName::Probe,
            mode: Mode::Pp,
        };
        assert_eq!(
            AssertPlan::new(
                vec![AssertName::Probe],
                &[Mode::Raw],
                AssertConfig::default()
            ),
            Err(err.clone())
        );
        assert_eq!(
            AssertPlan::new(vec![AssertName::Probe], &[], AssertConfig::default()),
            Err(err.clone())
        );

        // The message names the assertion and the flag to add.
        assert_eq!(err.to_string(), "--assert probe needs --mode pp");
    }

    /// With its mode present a plan is active and builds fresh plugins per connection.
    ///
    /// Setup: `probe` twice with `pp` and `raw`; build two connections' assertions.
    /// Catches: plugins shared across connections, flag order lost, or a valid plan rejected.
    #[test]
    fn plan_builds_per_connection() {
        // Required mode present, in any position, validates.
        let plan = AssertPlan::new(
            vec![AssertName::Probe, AssertName::Probe],
            &[Mode::Raw, Mode::Pp],
            AssertConfig::default(),
        )
        .unwrap();
        assert!(plan.is_active());

        // Each connection gets its own plugins; both report all their findings.
        for _ in 0..2 {
            let report = plan.build_assertions(15432).close();
            assert_eq!(report.outcome, Outcome::Pass);
            assert_eq!(report.findings.len(), 2);
        }
    }

    /// No `--assert` is valid with any modes and yields an inactive plan with no plugins.
    ///
    /// Setup: empty name list with no modes.
    /// Catches: plain proxy runs rejected or treated as assertion runs.
    #[test]
    fn no_assert_is_inactive() {
        // Nothing to validate, so any mode list is fine.
        let plan = AssertPlan::new(Vec::new(), &[], AssertConfig::default()).unwrap();
        assert!(!plan.is_active());
        assert!(plan.build_assertions(15432).close().findings.is_empty());
    }

    /// `pp_test` is registered, needs `pp`, and round-trips through its name.
    ///
    /// Setup: parse `pp_test`.
    /// Catches: the plugin missing from release builds or bound to the wrong mode.
    #[test]
    fn pp_test_registered() {
        // The name maps to the variant and back.
        let name: AssertName = "pp_test".parse().unwrap();
        assert_eq!(name, AssertName::PpTest);
        assert_eq!(name.to_string(), "pp_test");

        // It reads `PpHeader` events, so it needs the `pp` inspector.
        assert_eq!(name.required_mode(), Mode::Pp);
    }

    /// `pp_test` without `--pp-identity` is `MissingFlag` naming the flag.
    ///
    /// Setup: `pp_test` with `pp`, first without the identity, then with it.
    /// Catches: a run starting with no identity to compare, which could never pass or fail meaningfully.
    #[test]
    fn pp_test_missing_flag_errors() {
        // Identity missing.
        let plan = |config| AssertPlan::new(vec![AssertName::PpTest], &[Mode::Pp], config);
        let err = plan(AssertConfig { pp_identity: None }).unwrap_err();
        assert_eq!(err.to_string(), "--assert pp_test needs --pp-identity");

        // The mode check comes first, so a missing mode is reported over a missing flag.
        assert!(matches!(
            AssertPlan::new(
                vec![AssertName::PpTest],
                &[Mode::Raw],
                AssertConfig::default()
            ),
            Err(InspectorError::MissingMode { .. })
        ));

        // Identity present builds an active plan; its fresh plugin saw no header, so it fails at close.
        let plan = plan(AssertConfig {
            pp_identity: Some("a.b".into()),
        })
        .unwrap();
        assert!(plan.is_active());
        assert_eq!(plan.build_assertions(15432).close().outcome, Outcome::Fail);
    }

    /// `build_assertions` hands `pp_test` the bound port, so only a header to that port passes.
    ///
    /// Setup: a TCP4 header to port 40001 with identity `a.b`, checked with port 40001 then 15432.
    /// Catches: `dst port` compared with the `--listen` text, which breaks `--listen host:0`.
    #[test]
    fn build_assertions_uses_bound_port() {
        // Header 10.0.0.1:1000 -> 10.0.0.2:40001 carrying TLV 0xE0 `a.b`.
        let mut block = vec![10, 0, 0, 1, 10, 0, 0, 2];
        block.extend_from_slice(&1000u16.to_be_bytes());
        block.extend_from_slice(&40001u16.to_be_bytes());
        block.extend_from_slice(&[Tlv::IDENTITY, 0, 3]);
        block.extend_from_slice(b"a.b");
        let mut data = Pp::SIGNATURE.to_vec();
        data.extend_from_slice(&[0x21, 0x11]);
        data.extend_from_slice(&(block.len() as u16).to_be_bytes());
        data.extend_from_slice(&block);

        // Drive the header through `pp` and the plan's plugins built for `port`.
        let plan = AssertPlan::new(
            vec![AssertName::PpTest],
            &[Mode::Pp],
            AssertConfig {
                pp_identity: Some("a.b".into()),
            },
        )
        .unwrap();
        let run = |port| {
            let mut chain = Chain::new(&[Mode::Pp]);
            let mut asserts = plan.build_assertions(port);
            asserts.open();
            asserts.observe(&chain.feed(&data).events);
            asserts.observe(&chain.eof().events);
            asserts.eof();
            asserts.close()
        };

        // The bound port matches the header; any other port fails only `dst port`.
        assert_eq!(run(40001).outcome, Outcome::Pass);
        let failed: Vec<_> = run(15432)
            .findings
            .into_iter()
            .filter(|f| f.outcome == Outcome::Fail)
            .map(|f| f.field)
            .collect();
        assert_eq!(failed, ["dst port"]);
    }

    /// A run with no connection fails with one `connection` finding per plugin, in flag order.
    ///
    /// Setup: a plan of `probe` then `pp_test`; ask for the no-connection report.
    /// Catches: a run stopped before any client passing because no plugin reported anything.
    #[test]
    fn report_no_connection() {
        // Two plugins, so the report must name both.
        let plan = AssertPlan::new(
            vec![AssertName::Probe, AssertName::PpTest],
            &[Mode::Pp],
            AssertConfig {
                pp_identity: Some("a.b".into()),
            },
        )
        .unwrap();
        let report = plan.report_no_connection();

        // Every finding fails, and so does the run.
        assert_eq!(report.outcome, Outcome::Fail);
        assert_eq!(
            report.findings,
            vec![
                Finding::fail("probe", "connection", "accepted", "none"),
                Finding::fail("pp_test", "connection", "accepted", "none"),
            ]
        );

        // An inactive plan has no plugins to fail, but the shell never asks it for this report.
        let empty = AssertPlan::new(Vec::new(), &[], AssertConfig::default()).unwrap();
        assert!(empty.report_no_connection().findings.is_empty());
    }
}
