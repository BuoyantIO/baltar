use ::core::net::{IpAddr, SocketAddr};
use std::fmt;

use super::{AssertOutput, Assertion, Finding};
use crate::core::{Event, Tlv};

#[derive(Debug, Clone, PartialEq, Eq)]
/// Settings for `pp_test`, from `--pp-identity` and the `--listen` port.
pub struct PpTestConfig {
    /// Exact text TLV `0xE0` must carry.
    pub identity: String,
    /// Port the header's `dst` must carry: the port the inspector listens on.
    pub listen_port: u16,
}

/// Checks the PROXY v2 header on one connection: command, family, `src` shape, `dst` port and identity.
///
/// `src` is checked only for shape, since the client pod IP and ephemeral port vary per run.
pub struct PpTest {
    /// What the header must carry.
    config: PpTestConfig,
    /// Whether a `PpHeader` event arrived.
    seen: bool,
    /// First close reason logged before any header; explains a missing header.
    closed: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// Whether a header's `src` is a usable client address, or why not.
enum SrcClass {
    /// A unicast address of the header's family.
    Valid,
    /// Not an `ip:port` text, e.g. empty for `UNSPEC`.
    Unparsable,
    /// An IPv4 address in a `TCP6` header or the reverse.
    WrongFamily,
    /// `0.0.0.0` or `::`.
    Unspecified,
    /// `127.0.0.0/8`, `::1`, or an IPv4-mapped loopback.
    Loopback,
    /// A multicast group address.
    Multicast,
    /// `255.255.255.255`.
    Broadcast,
}

impl fmt::Display for SrcClass {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            SrcClass::Valid => "valid",
            SrcClass::Unparsable => "not ip:port",
            SrcClass::WrongFamily => "family mismatch",
            SrcClass::Unspecified => "unspecified",
            SrcClass::Loopback => "loopback",
            SrcClass::Multicast => "multicast",
            SrcClass::Broadcast => "broadcast",
        })
    }
}

impl PpTest {
    /// Name accepted by `--assert` and shown in findings.
    pub const NAME: &'static str = "pp_test";

    /// Builds a fresh check for one connection.
    pub fn new(config: PpTestConfig) -> Self {
        Self {
            config,
            seen: false,
            closed: None,
        }
    }

    /// Checks every field of one header, one finding per field.
    fn check_header(
        &self,
        command: &str,
        family: &str,
        src: &str,
        dst: &str,
        tlvs: &[Tlv],
    ) -> Vec<Finding> {
        vec![
            Self::check_command(command),
            Self::check_family(family),
            Self::check_src(family, src),
            Self::check_dst_port(dst, self.config.listen_port),
            Self::check_identity(tlvs, &self.config.identity),
        ]
    }

    /// `LOCAL` carries no client, so only `PROXY` passes.
    fn check_command(command: &str) -> Finding {
        Self::finding(command == "PROXY", "command", "PROXY", command)
    }

    /// Only TCP families carry the client address Linkerd must forward.
    fn check_family(family: &str) -> Finding {
        let ok = matches!(family, "TCP4" | "TCP6");
        Self::finding(ok, "family", "TCP4 or TCP6", family)
    }

    /// Passes any unicast `src` of the header's family; the observed text names why one fails.
    fn check_src(family: &str, src: &str) -> Finding {
        let class = Self::classify_src(family, src);
        let observed = match class {
            SrcClass::Valid => src.to_string(),
            _ => format!("{src} ({class})"),
        };
        Self::finding(
            class == SrcClass::Valid,
            "src",
            format!("unicast {family} ip:port, not loopback or unspecified"),
            observed,
        )
    }

    /// Classifies `src` text against the header family.
    fn classify_src(family: &str, src: &str) -> SrcClass {
        // `pp` renders TCP addresses as `ip:port`; anything else is not a client address.
        let Ok(addr) = src.parse::<SocketAddr>() else {
            return SrcClass::Unparsable;
        };
        // The address must match the header's declared family.
        match (family, addr.ip()) {
            ("TCP4", IpAddr::V4(_)) | ("TCP6", IpAddr::V6(_)) => {}
            _ => return SrcClass::WrongFamily,
        }
        // A mapped IPv4 address in a TCP6 header is judged as the IPv4 address it carries.
        let ip = addr.ip().to_canonical();
        if ip.is_unspecified() {
            SrcClass::Unspecified
        } else if ip.is_loopback() {
            SrcClass::Loopback
        } else if ip.is_multicast() {
            SrcClass::Multicast
        } else if matches!(ip, IpAddr::V4(v4) if v4.is_broadcast()) {
            SrcClass::Broadcast
        } else {
            SrcClass::Valid
        }
    }

    /// The original destination port must be the one the inspector listens on.
    fn check_dst_port(dst: &str, listen_port: u16) -> Finding {
        let port = Self::parse_port(dst);
        Self::finding(
            port == Some(listen_port),
            "dst port",
            listen_port.to_string(),
            port.map_or_else(|| format!("{dst} (not ip:port)"), |p| p.to_string()),
        )
    }

    /// Port of an `ip:port` text; `None` when the text is not one.
    fn parse_port(addr: &str) -> Option<u16> {
        addr.parse::<SocketAddr>().ok().map(|a| a.port())
    }

    /// Exactly one `0xE0` TLV with exactly `expected`; other TLV types are allowed.
    fn check_identity(tlvs: &[Tlv], expected: &str) -> Finding {
        // Collect every identity TLV, so a duplicate fails instead of hiding behind the first.
        let ids: Vec<&str> = tlvs
            .iter()
            .filter(|t| t.kind == Tlv::IDENTITY)
            .filter_map(|t| t.text.as_deref())
            .collect();
        let observed = if ids.is_empty() {
            "absent".to_string()
        } else {
            ids.join(", ")
        };
        Self::finding(ids == [expected], "tlv 0xe0", expected, observed)
    }

    /// Builds a pass or fail finding under this plugin's name.
    fn finding(
        ok: bool,
        field: &str,
        expected: impl Into<String>,
        observed: impl Into<String>,
    ) -> Finding {
        if ok {
            Finding::pass(Self::NAME, field, expected, observed)
        } else {
            Finding::fail(Self::NAME, field, expected, observed)
        }
    }
}

impl Assertion for PpTest {
    fn name(&self) -> &'static str {
        Self::NAME
    }

    fn event(&mut self, event: &Event) -> AssertOutput {
        match event {
            // `pp` emits at most one header per connection; check it once.
            Event::PpHeader {
                command,
                family,
                src,
                dst,
                tlvs,
                ..
            } if !self.seen => {
                self.seen = true;
                AssertOutput::report(self.check_header(command, family, src, dst, tlvs))
            }
            // A close before the header, e.g. a bad signature, explains its absence at close.
            Event::Closed { reason } if !self.seen && self.closed.is_none() => {
                self.closed = Some(reason.clone());
                AssertOutput::none()
            }
            _ => AssertOutput::none(),
        }
    }

    fn close(&mut self) -> AssertOutput {
        // A connection without a header must fail, or a proxy that sends none would pass.
        if self.seen {
            return AssertOutput::none();
        }
        let observed = match &self.closed {
            Some(reason) => format!("absent ({reason})"),
            None => "absent".to_string(),
        };
        AssertOutput::report(vec![Finding::fail(
            Self::NAME,
            "pp header",
            "present",
            observed,
        )])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::assert::{Assertions, Outcome, Report};
    use crate::core::{Chain, Mode, Pp};

    /// Client identity Linkerd puts in TLV `0xE0` for ServiceAccount `client` in namespace `inspect`.
    const IDENTITY: &str = "client.inspect.serviceaccount.identity.linkerd.cluster.local";
    /// Port the inspector listens on in these tests.
    const PORT: u16 = 15432;

    /// Builds PROXY v2 headers and drives them through a `pp` + `raw` chain with `pp_test`.
    struct Fixture;

    impl Fixture {
        /// The config every test expects: `IDENTITY` on `PORT`.
        fn config() -> PpTestConfig {
            PpTestConfig {
                identity: IDENTITY.to_string(),
                listen_port: PORT,
            }
        }

        /// One TLV: type, big-endian length, value.
        fn tlv(kind: u8, value: &[u8]) -> Vec<u8> {
            let mut t = vec![kind];
            t.extend((value.len() as u16).to_be_bytes());
            t.extend(value);
            t
        }

        /// A v2 header with the given command nibble, family byte and address-plus-TLV block.
        fn header(cmd: u8, fam: u8, block: &[u8]) -> Vec<u8> {
            let mut h = Pp::SIGNATURE.to_vec();
            h.extend([0x20 | cmd, fam]);
            h.extend((block.len() as u16).to_be_bytes());
            h.extend(block);
            h
        }

        /// TCP4 PROXY header `src:40000 -> 10.0.0.2:dst_port` carrying `identity` plus an ALPN TLV.
        fn tcp4(src: [u8; 4], dst_port: u16, identity: &str) -> Vec<u8> {
            let mut block = src.to_vec();
            block.extend([10, 0, 0, 2]);
            block.extend(40000u16.to_be_bytes());
            block.extend(dst_port.to_be_bytes());
            block.extend(Self::tlv(0x01, b"h2"));
            block.extend(Self::tlv(Tlv::IDENTITY, identity.as_bytes()));
            Self::header(1, 0x11, &block)
        }

        /// Runs one connection carrying `data` then eof, and returns the report.
        fn run(data: &[u8]) -> Report {
            let mut chain = Chain::new(&[Mode::Pp, Mode::Raw]);
            let mut asserts = Assertions::new(vec![Box::new(PpTest::new(Self::config()))]);
            asserts.open();
            asserts.observe(&chain.feed(data).events);
            asserts.observe(&chain.eof().events);
            asserts.eof();
            asserts.close()
        }

        /// Failing findings as `(field, observed)`.
        fn failures(report: &Report) -> Vec<(&str, &str)> {
            report
                .findings
                .iter()
                .filter(|f| f.outcome == Outcome::Fail)
                .map(|f| (f.field.as_str(), f.observed.as_str()))
                .collect()
        }
    }

    /// A Linkerd-shaped header with the right identity passes every field.
    ///
    /// Setup: TCP4 `10.0.0.1 -> 10.0.0.2:15432` with an ALPN TLV and the expected identity, then payload.
    /// Catches: extra TLVs rejected, a field check reporting fail on good input, or a missing field check.
    #[test]
    fn pass() {
        // Header plus payload, as Linkerd sends it.
        let mut data = Fixture::tcp4([10, 0, 0, 1], PORT, IDENTITY);
        data.extend(b"hello");
        let report = Fixture::run(&data);

        // All five fields pass, in check order.
        assert_eq!(report.outcome, Outcome::Pass);
        let fields: Vec<_> = report.findings.iter().map(|f| f.field.as_str()).collect();
        assert_eq!(fields, ["command", "family", "src", "dst port", "tlv 0xe0"]);
    }

    /// A different identity in TLV `0xE0` fails, naming expected and observed.
    ///
    /// Setup: otherwise valid TCP4 header carrying `other.identity`.
    /// Catches: a prefix or substring match, or the identity never compared.
    #[test]
    fn wrong_identity() {
        // Only the identity differs from the passing header.
        let report = Fixture::run(&Fixture::tcp4([10, 0, 0, 1], PORT, "other.identity"));

        // Exactly the identity finding fails, with both values.
        assert_eq!(report.outcome, Outcome::Fail);
        let fail = report
            .findings
            .iter()
            .find(|f| f.outcome == Outcome::Fail)
            .unwrap();
        assert_eq!(
            fail.to_string(),
            format!(r#"FAIL pp_test tlv 0xe0: expected "{IDENTITY}", observed "other.identity""#)
        );
        assert_eq!(Fixture::failures(&report).len(), 1);
    }

    /// A loopback `src` fails, since it means the proxy forwarded its own address, not the client's.
    ///
    /// Setup: TCP4 header from `127.0.0.1`.
    /// Catches: `src` accepted without a shape check.
    #[test]
    fn loopback_src() {
        // Everything but `src` is valid.
        let report = Fixture::run(&Fixture::tcp4([127, 0, 0, 1], PORT, IDENTITY));
        assert_eq!(
            Fixture::failures(&report),
            [("src", "127.0.0.1:40000 (loopback)")]
        );
    }

    /// A `dst` port other than the listen port fails.
    ///
    /// Setup: TCP4 header to port 5432 while the inspector listens on 15432.
    /// Catches: `dst` ignored, or the source port compared instead.
    #[test]
    fn wrong_dst_port() {
        // Everything but the destination port is valid.
        let report = Fixture::run(&Fixture::tcp4([10, 0, 0, 1], 5432, IDENTITY));
        assert_eq!(Fixture::failures(&report), [("dst port", "5432")]);
    }

    /// A LOCAL header fails on command, family, addresses and identity.
    ///
    /// Setup: LOCAL command, family UNSPEC, no TLVs.
    /// Catches: a health-check style header passing as a proxied client connection.
    #[test]
    fn local_command() {
        // LOCAL carries no addresses or TLVs.
        let report = Fixture::run(&Fixture::header(0, 0x00, &[]));

        // Every field fails, each naming what was seen.
        assert_eq!(
            Fixture::failures(&report),
            [
                ("command", "LOCAL"),
                ("family", "UNSPEC"),
                ("src", " (not ip:port)"),
                ("dst port", " (not ip:port)"),
                ("tlv 0xe0", "absent"),
            ]
        );
    }

    /// A connection without a PROXY header fails at close, naming why `pp` closed.
    ///
    /// Setup: plain `hello` bytes, then an empty stream.
    /// Catches: a run passing because no header meant no failing finding.
    #[test]
    fn no_header() {
        // `pp` rejects the first byte, so close reports the missing header with that reason.
        let report = Fixture::run(b"hello");
        assert_eq!(
            Fixture::failures(&report),
            [("pp header", "absent (pp: bad PROXY v2 signature)")]
        );

        // An empty stream is a truncation, also reported at close.
        let report = Fixture::run(b"");
        assert_eq!(
            Fixture::failures(&report),
            [("pp header", "absent (pp: eof after 0 of 16 header bytes)")]
        );
    }

    /// A TCP6 header with a global `src` passes.
    ///
    /// Setup: TCP6 `[fd00::1]:40000 -> [fd00::2]:15432` with the identity TLV.
    /// Catches: IPv6 addresses failing the `src` or `dst` parse.
    #[test]
    fn tcp6_pass() {
        // 36-byte TCP6 block, then the identity.
        let mut block = [0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1].to_vec();
        block.extend([0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2]);
        block.extend(40000u16.to_be_bytes());
        block.extend(PORT.to_be_bytes());
        block.extend(Fixture::tlv(Tlv::IDENTITY, IDENTITY.as_bytes()));
        let report = Fixture::run(&Fixture::header(1, 0x21, &block));
        assert_eq!(report.outcome, Outcome::Pass);
    }

    /// `classify_src` accepts unicast addresses of the header family and names each rejection.
    ///
    /// Setup: IPv4, IPv6 and mapped addresses across every class.
    /// Catches: a loopback, unspecified, multicast or broadcast client, or a family mismatch, passing.
    #[test]
    fn classify_src() {
        // Unicast private and public addresses pass in their own family.
        for (fam, src) in [
            ("TCP4", "10.244.0.7:40000"),
            ("TCP4", "8.8.8.8:1"),
            ("TCP6", "[fd00::1]:40000"),
            ("TCP6", "[::ffff:10.0.0.1]:1"),
        ] {
            assert_eq!(PpTest::classify_src(fam, src), SrcClass::Valid, "{src}");
        }

        // Each rejection names its class.
        for (fam, src, class) in [
            ("TCP4", "", SrcClass::Unparsable),
            ("TCP4", "10.0.0.1", SrcClass::Unparsable),
            ("UNSPEC", "10.0.0.1:1", SrcClass::WrongFamily),
            ("TCP4", "[fd00::1]:1", SrcClass::WrongFamily),
            ("TCP6", "10.0.0.1:1", SrcClass::WrongFamily),
            ("TCP4", "0.0.0.0:1", SrcClass::Unspecified),
            ("TCP6", "[::]:1", SrcClass::Unspecified),
            ("TCP4", "127.1.2.3:1", SrcClass::Loopback),
            ("TCP6", "[::1]:1", SrcClass::Loopback),
            ("TCP6", "[::ffff:127.0.0.1]:1", SrcClass::Loopback),
            ("TCP4", "224.0.0.1:1", SrcClass::Multicast),
            ("TCP6", "[ff02::1]:1", SrcClass::Multicast),
            ("TCP4", "255.255.255.255:1", SrcClass::Broadcast),
        ] {
            assert_eq!(PpTest::classify_src(fam, src), class, "{fam} {src}");
        }
    }

    /// `parse_port` reads the port of IPv4 and IPv6 `ip:port` text and rejects anything else.
    ///
    /// Setup: both address forms, an empty string and a bare IP.
    /// Catches: splitting on the last `:` without brackets, or a default port for bad input.
    #[test]
    fn parse_port() {
        // Both families yield their port.
        assert_eq!(PpTest::parse_port("10.0.0.2:15432"), Some(15432));
        assert_eq!(PpTest::parse_port("[fd00::2]:15432"), Some(15432));

        // Non-address text has no port.
        assert_eq!(PpTest::parse_port(""), None);
        assert_eq!(PpTest::parse_port("fd00::2"), None);
    }

    /// `check_identity` passes only on exactly one `0xE0` TLV equal to the expected text.
    ///
    /// Setup: TLV lists with the identity plus others, none, a prefix, and a duplicate.
    /// Catches: extra TLV types failing, a prefix match passing, or a second identity ignored.
    #[test]
    fn check_identity() {
        // The expected identity and an unrelated TLV.
        let id = Tlv::new(Tlv::IDENTITY, IDENTITY.as_bytes());
        let alpn = Tlv::new(0x01, b"h2");

        // Other TLV types around the identity are allowed.
        let f = PpTest::check_identity(&[alpn.clone(), id.clone()], IDENTITY);
        assert_eq!(f.outcome, Outcome::Pass);

        // No identity is reported as absent.
        let f = PpTest::check_identity(&[alpn], IDENTITY);
        assert_eq!((f.outcome, f.observed.as_str()), (Outcome::Fail, "absent"));

        // A prefix of the expected text is not a match.
        let short = Tlv::new(Tlv::IDENTITY, b"client.inspect");
        assert_eq!(
            PpTest::check_identity(&[short], IDENTITY).outcome,
            Outcome::Fail
        );

        // Two identities fail, and both are shown.
        let f = PpTest::check_identity(&[id.clone(), id], IDENTITY);
        assert_eq!(f.outcome, Outcome::Fail);
        assert_eq!(f.observed, format!("{IDENTITY}, {IDENTITY}"));
    }

    /// `check_command`, `check_family` and `check_dst_port` pass only their exact expected values.
    ///
    /// Setup: each fn with a good and a bad input.
    /// Catches: case-insensitive or prefix matches, or a missing port passing.
    #[test]
    fn check_scalar_fields() {
        // Command must be PROXY.
        assert_eq!(PpTest::check_command("PROXY").outcome, Outcome::Pass);
        assert_eq!(PpTest::check_command("LOCAL").outcome, Outcome::Fail);

        // Family must be a TCP family.
        assert_eq!(PpTest::check_family("TCP6").outcome, Outcome::Pass);
        assert_eq!(PpTest::check_family("0x12").outcome, Outcome::Fail);

        // `dst` port must equal the listen port.
        assert_eq!(
            PpTest::check_dst_port("10.0.0.2:15432", PORT).outcome,
            Outcome::Pass
        );
        assert_eq!(PpTest::check_dst_port("", PORT).outcome, Outcome::Fail);
    }
}
