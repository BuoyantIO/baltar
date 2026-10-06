use ::core::net::{Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6};

use super::{Event, Inspector, Output, Tlv, Verdict};
use crate::error::PpError;
use crate::util::Hex;

/// Parses, logs and strips one PROXY v2 header at the start of the stream, then passes everything through.
#[derive(Debug, Default)]
pub struct Pp {
    buf: Vec<u8>,
    done: bool,
}

impl Pp {
    /// The 12 bytes every PROXY v2 header starts with.
    pub const SIGNATURE: [u8; 12] = [
        0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A,
    ];
    /// Signature, version/command, family/protocol and the 16-bit length.
    const FIXED_LEN: usize = 16;

    /// Classifies the buffered prefix: fixed part incomplete, full header length known, or invalid.
    ///
    /// Checks the signature on every prefix so a non-PP stream closes on its first byte.
    fn parse_header(buf: &[u8]) -> ParseHeaderOutcome {
        // Compare only the bytes we have, so a mismatch is caught before the full signature arrives.
        let n = buf.len().min(Self::SIGNATURE.len());
        if buf[..n] != Self::SIGNATURE[..n] {
            return ParseHeaderOutcome::Invalid(PpError::BadSignature);
        }
        // Version and length live in the fixed part; wait for all of it.
        if buf.len() < Self::FIXED_LEN {
            return ParseHeaderOutcome::NeedFixed;
        }
        // High nibble of byte 12 is the version; only v2 is binary PROXY protocol.
        let version = buf[12] >> 4;
        if version != 2 {
            return ParseHeaderOutcome::Invalid(PpError::BadVersion(version));
        }
        // Bytes 14-15 give the length of everything after the fixed part.
        ParseHeaderOutcome::Known(
            Self::FIXED_LEN + usize::from(u16::from_be_bytes([buf[14], buf[15]])),
        )
    }

    fn parse(header: &[u8]) -> Result<Event, PpError> {
        // Low nibble of byte 12 is the command; unknown values are logged, not rejected.
        let command = match header[12] & 0x0F {
            0 => "LOCAL".to_string(),
            1 => "PROXY".to_string(),
            c => format!("0x{c:x}"),
        };
        // Byte 13 selects the address layout; a block shorter than that layout is malformed.
        let fam = header[13];
        let block = &header[Self::FIXED_LEN..];
        let short = || PpError::ShortAddress {
            family: fam,
            len: block.len(),
        };
        // Decode addresses per family; `rest` is what follows them, i.e. the TLVs.
        let (family, src, dst, rest) = match fam {
            0x00 => ("UNSPEC".to_string(), String::new(), String::new(), block),
            0x11 => {
                let a = block.get(..12).ok_or_else(short)?;
                let ip = |o: usize| Ipv4Addr::new(a[o], a[o + 1], a[o + 2], a[o + 3]);
                let port = |o: usize| u16::from_be_bytes([a[o], a[o + 1]]);
                (
                    "TCP4".to_string(),
                    SocketAddrV4::new(ip(0), port(8)).to_string(),
                    SocketAddrV4::new(ip(4), port(10)).to_string(),
                    &block[12..],
                )
            }
            0x21 => {
                let a = block.get(..36).ok_or_else(short)?;
                let ip = |o: usize| {
                    Ipv6Addr::from(<[u8; 16]>::try_from(&a[o..o + 16]).expect("16-byte slice"))
                };
                let port = |o: usize| u16::from_be_bytes([a[o], a[o + 1]]);
                (
                    "TCP6".to_string(),
                    SocketAddrV6::new(ip(0), port(32), 0, 0).to_string(),
                    SocketAddrV6::new(ip(16), port(34), 0, 0).to_string(),
                    &block[36..],
                )
            }
            // Address length of other families is not parsed, so the whole block (TLVs included) is logged as hex.
            _ => (
                format!("0x{fam:02x}"),
                Hex::encode(block),
                String::new(),
                &[][..],
            ),
        };
        // A malformed TLV fails the whole header rather than logging a partial list.
        Ok(Event::PpHeader {
            raw_hex: Hex::encode(header),
            version: 2,
            command,
            family,
            src,
            dst,
            tlvs: Self::tlvs(rest)?,
        })
    }

    fn tlvs(mut rest: &[u8]) -> Result<Vec<Tlv>, PpError> {
        let mut tlvs = Vec::new();
        while !rest.is_empty() {
            // Each TLV starts with a type byte and a 2-byte big-endian length; fewer than 3 bytes left is malformed.
            let [kind, hi, lo, ..] = *rest else {
                return Err(PpError::BadTlv);
            };
            // A declared length running past the header is malformed too.
            let end = 3 + usize::from(u16::from_be_bytes([hi, lo]));
            let value = rest.get(3..end).ok_or(PpError::BadTlv)?;
            tlvs.push(Tlv::new(kind, value));
            rest = &rest[end..];
        }
        Ok(tlvs)
    }

    /// `Chain` adds the `Closed` event, so the inspector returns none.
    fn close(err: PpError) -> Output {
        Output {
            events: Vec::new(),
            strip: 0,
            verdict: Verdict::Close(err.to_string()),
        }
    }

    fn buffering(len: usize) -> Output {
        Output {
            events: Vec::new(),
            strip: len,
            verdict: Verdict::Continue,
        }
    }
}

/// What the buffered prefix says about the PROXY v2 header length.
#[cfg_attr(test, derive(Debug, PartialEq, Eq))]
enum ParseHeaderOutcome {
    /// Signature matches so far, but the fixed part is not fully buffered yet.
    NeedFixed,
    /// Fixed part is valid; the header spans this many bytes in total.
    Known(usize),
    /// The prefix cannot start a PROXY v2 header.
    Invalid(PpError),
}

impl Inspector for Pp {
    fn feed(&mut self, data: &[u8]) -> Output {
        // After the header, every byte is payload and passes through untouched.
        if self.done {
            return Output::pass(Vec::new());
        }

        // Buffer until the header is complete, stripping each partial chunk so none leaks forward.
        let before = self.buf.len();
        self.buf.extend_from_slice(data);
        let total = match Self::parse_header(&self.buf) {
            ParseHeaderOutcome::Invalid(e) => return Self::close(e),
            ParseHeaderOutcome::Known(total) if self.buf.len() >= total => total,
            ParseHeaderOutcome::Known(_) | ParseHeaderOutcome::NeedFixed => {
                return Self::buffering(data.len());
            }
        };

        // Header complete: parse it once. Earlier chunks were already stripped, so strip
        // only this chunk's header bytes and forward the payload behind them.
        self.done = true;
        let buf = std::mem::take(&mut self.buf);
        match Self::parse(&buf[..total]) {
            Ok(event) => Output {
                events: vec![event],
                strip: total - before,
                verdict: Verdict::Continue,
            },
            Err(e) => Self::close(e),
        }
    }

    /// Eof before a complete header, including an empty stream, is a truncation.
    fn eof(&mut self) -> Output {
        // Eof after a parsed header is a normal half-close.
        if self.done {
            return Output::pass(Vec::new());
        }
        // Report the declared length if the fixed part arrived, else the fixed part itself.
        let need = match Self::parse_header(&self.buf) {
            ParseHeaderOutcome::Known(total) => total,
            ParseHeaderOutcome::NeedFixed | ParseHeaderOutcome::Invalid(_) => Self::FIXED_LEN,
        };
        Self::close(PpError::Truncated {
            have: self.buf.len(),
            need,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::Chain;

    /// Client identity Linkerd puts in TLV `0xE0` for ServiceAccount `client` in namespace `inspect`.
    const IDENTITY: &str = "client.inspect.serviceaccount.identity.linkerd.cluster.local";

    /// Builds PROXY v2 headers for tests.
    struct Fixture;

    impl Fixture {
        fn header(ver_cmd: u8, fam: u8, block: &[u8]) -> Vec<u8> {
            let mut h = Pp::SIGNATURE.to_vec();
            h.extend([ver_cmd, fam]);
            h.extend((block.len() as u16).to_be_bytes());
            h.extend(block);
            h
        }

        fn tlv(kind: u8, value: &[u8]) -> Vec<u8> {
            let mut t = vec![kind];
            t.extend((value.len() as u16).to_be_bytes());
            t.extend(value);
            t
        }

        /// TCP4 `10.0.0.1:1234 -> 10.0.0.2:5432` with an `0xE0` identity TLV.
        fn ipv4() -> Vec<u8> {
            let mut block = vec![10, 0, 0, 1, 10, 0, 0, 2];
            block.extend(1234u16.to_be_bytes());
            block.extend(5432u16.to_be_bytes());
            block.extend(Self::tlv(0xE0, IDENTITY.as_bytes()));
            Self::header(0x21, 0x11, &block)
        }

        fn ipv4_event() -> Event {
            let h = Self::ipv4();
            Event::PpHeader {
                raw_hex: Hex::encode(&h),
                version: 2,
                command: "PROXY".into(),
                family: "TCP4".into(),
                src: "10.0.0.1:1234".into(),
                dst: "10.0.0.2:5432".into(),
                tlvs: vec![Tlv::new(0xE0, IDENTITY.as_bytes())],
            }
        }
    }

    /// A TCP4 header parses with addresses and the `0xE0` TLV logged as plain text.
    ///
    /// Setup: TCP4 header with an `0xE0` identity TLV and a `0x01` TLV, fed in one call.
    /// Catches: wrong address/port decoding, or the identity serialized as hex so a log grep for it misses it.
    #[test]
    fn ipv4_with_identity_tlv() {
        // Header with the identity TLV plus an ALPN TLV that must stay hex.
        let mut block = vec![10, 0, 0, 1, 10, 0, 0, 2];
        block.extend(1234u16.to_be_bytes());
        block.extend(5432u16.to_be_bytes());
        block.extend(Fixture::tlv(0xE0, IDENTITY.as_bytes()));
        block.extend(Fixture::tlv(0x01, b"h2"));
        let h = Fixture::header(0x21, 0x11, &block);
        let out = Pp::default().feed(&h);

        // The whole header is stripped and logged.
        assert_eq!(out.strip, h.len());
        assert_eq!(out.verdict, Verdict::Continue);
        assert_eq!(
            out.events,
            vec![Event::PpHeader {
                raw_hex: Hex::encode(&h),
                version: 2,
                command: "PROXY".into(),
                family: "TCP4".into(),
                src: "10.0.0.1:1234".into(),
                dst: "10.0.0.2:5432".into(),
                tlvs: vec![Tlv::new(0xE0, IDENTITY.as_bytes()), Tlv::new(0x01, b"h2")],
            }]
        );

        // The JSON log line carries the identity as text and other TLVs as hex.
        let json = serde_json::to_string(&out.events[0]).unwrap();
        assert!(json.contains(&format!(r#"{{"type":"0xe0","text":"{IDENTITY}"}}"#)));
        assert!(json.contains(r#"{"type":"0x01","hex":"6832"}"#));
    }

    /// A TCP6 header parses into bracketed socket addresses.
    ///
    /// Setup: TCP6 `[::1]:1234 -> [fd00::2]:5432`, no TLVs.
    /// Catches: wrong IPv6 offsets (36-byte block) or port positions.
    #[test]
    fn ipv6() {
        // Build the 36-byte TCP6 address block.
        let mut block = Ipv6Addr::LOCALHOST.octets().to_vec();
        block.extend(Ipv6Addr::new(0xfd00, 0, 0, 0, 0, 0, 0, 2).octets());
        block.extend(1234u16.to_be_bytes());
        block.extend(5432u16.to_be_bytes());
        let h = Fixture::header(0x21, 0x21, &block);
        let out = Pp::default().feed(&h);

        // Addresses decode and nothing else is logged.
        assert_eq!(out.strip, h.len());
        assert_eq!(
            out.events,
            vec![Event::PpHeader {
                raw_hex: Hex::encode(&h),
                version: 2,
                command: "PROXY".into(),
                family: "TCP6".into(),
                src: "[::1]:1234".into(),
                dst: "[fd00::2]:5432".into(),
                tlvs: vec![],
            }]
        );
    }

    /// A LOCAL header with no addresses is accepted and stripped.
    ///
    /// Setup: version 2, command LOCAL, family UNSPEC, length 0, followed by payload.
    /// Catches: LOCAL rejected or its zero-length block misparsed.
    #[test]
    fn local() {
        // 16-byte LOCAL header plus payload in one feed.
        let h = Fixture::header(0x20, 0x00, &[]);
        let mut data = h.clone();
        data.extend(b"hi");
        let out = Pp::default().feed(&data);

        // Only the header is stripped; addresses are empty.
        assert_eq!(out.strip, 16);
        assert_eq!(
            out.events,
            vec![Event::PpHeader {
                raw_hex: Hex::encode(&h),
                version: 2,
                command: "LOCAL".into(),
                family: "UNSPEC".into(),
                src: String::new(),
                dst: String::new(),
                tlvs: vec![],
            }]
        );
    }

    /// Splitting header plus payload at any offset yields the same single event and forwarded payload.
    ///
    /// Setup: TCP4 header with identity TLV plus `payload`, fed through a `Chain` in two parts for every split.
    /// Catches: buffering bugs such as wrong strip on the completing feed or header bytes leaking forward.
    #[test]
    fn split_at_every_offset() {
        // Header followed by payload.
        let mut data = Fixture::ipv4();
        data.extend(b"payload");

        for i in 0..=data.len() {
            // Feed two parts through a fresh chain.
            let mut chain = Chain::from_inspectors(vec![Box::new(Pp::default())]);
            let a = chain.feed(&data[..i]);
            let b = chain.feed(&data[i..]);

            // Exactly one header event and the payload forwarded intact.
            let mut events = a.events;
            events.extend(b.events);
            assert_eq!(events, vec![Fixture::ipv4_event()], "split {i}");
            assert_eq!([a.forward, b.forward].concat(), b"payload", "split {i}");
            assert_eq!(b.verdict, Verdict::Continue, "split {i}");
        }
    }

    /// A stream not starting with the signature closes on its first byte with one `Closed` event.
    ///
    /// Setup: feed `G` through a `Chain`, then a full HTTP line to a bare `Pp`.
    /// Catches: waiting for 16 bytes before rejecting, or a duplicate `Closed` from `Pp` and `Chain`.
    #[test]
    fn bad_signature() {
        // One wrong byte is enough to close.
        let mut chain = Chain::from_inspectors(vec![Box::new(Pp::default())]);
        let out = chain.feed(b"G");
        let reason = PpError::BadSignature.to_string();
        assert_eq!(out.verdict, Verdict::Close(reason.clone()));
        assert_eq!(out.events, vec![Event::Closed { reason }]);
        assert!(out.forward.is_empty());

        // A correct prefix keeps buffering until a byte diverges.
        let mut pp = Pp::default();
        assert_eq!(pp.feed(&Pp::SIGNATURE[..5]).verdict, Verdict::Continue);
        assert!(matches!(pp.feed(b"X").verdict, Verdict::Close(_)));
    }

    /// A version other than 2 closes the stream.
    ///
    /// Setup: valid signature with version/command byte `0x11`.
    /// Catches: accepting a v1-style or garbage version byte.
    #[test]
    fn bad_version() {
        // Version nibble 1.
        let h = Fixture::header(0x11, 0x00, &[]);
        let out = Pp::default().feed(&h);
        assert_eq!(
            out.verdict,
            Verdict::Close(PpError::BadVersion(1).to_string())
        );
    }

    /// Eof before the header completes closes with a truncation reason and one `Closed` event.
    ///
    /// Setup: feed the first 20 bytes of a TCP4 header through a `Chain`, then `eof`.
    /// Catches: a partial header silently accepted or dropped at eof.
    #[test]
    fn truncated_at_eof() {
        // Partial header is buffered, nothing forwarded.
        let h = Fixture::ipv4();
        let mut chain = Chain::from_inspectors(vec![Box::new(Pp::default())]);
        let out = chain.feed(&h[..20]);
        assert!(out.events.is_empty());
        assert!(out.forward.is_empty());

        // Eof reports how much of the declared length arrived.
        let out = chain.eof();
        let reason = PpError::Truncated {
            have: 20,
            need: h.len(),
        }
        .to_string();
        assert_eq!(out.verdict, Verdict::Close(reason.clone()));
        assert_eq!(out.events, vec![Event::Closed { reason }]);
    }

    /// Bytes after the header in the same feed are forwarded, and later feeds pass through.
    ///
    /// Setup: header plus `SELECT 1` in one feed, then `more` through a `Chain`.
    /// Catches: stripping the whole first chunk or continuing to strip after the header.
    #[test]
    fn payload_after_header_kept() {
        // Header and payload in one chunk.
        let mut data = Fixture::ipv4();
        data.extend(b"SELECT 1");
        let mut chain = Chain::from_inspectors(vec![Box::new(Pp::default())]);
        let out = chain.feed(&data);
        assert_eq!(out.events, vec![Fixture::ipv4_event()]);
        assert_eq!(out.forward, b"SELECT 1");

        // Later chunks are untouched and log nothing.
        let out = chain.feed(b"more");
        assert!(out.events.is_empty());
        assert_eq!(out.forward, b"more");

        // Eof after the header is not a truncation.
        assert_eq!(chain.eof().verdict, Verdict::Continue);
    }

    /// Only the first header is parsed; a second one is forwarded as payload.
    ///
    /// Setup: two identical headers in one feed, then a third in a later feed.
    /// Catches: re-parsing or stripping headers after the first.
    #[test]
    fn second_header_as_payload() {
        // Two headers back to back.
        let h = Fixture::ipv4();
        let mut chain = Chain::from_inspectors(vec![Box::new(Pp::default())]);
        let out = chain.feed(&[h.clone(), h.clone()].concat());
        assert_eq!(out.events, vec![Fixture::ipv4_event()]);
        assert_eq!(out.forward, h);

        // A header in a later chunk is also payload.
        let out = chain.feed(&h);
        assert!(out.events.is_empty());
        assert_eq!(out.forward, h);
    }

    /// `parse_header` waits for more bytes while every buffered byte matches the signature.
    ///
    /// Setup: empty buffer, a 5-byte signature prefix, and the full signature plus 2 of the 4 fixed bytes.
    /// Catches: indexing past a short buffer, or rejecting a valid prefix before the fixed part arrives.
    #[test]
    fn parse_header_need_fixed() {
        // An empty buffer has nothing to reject yet.
        assert_eq!(Pp::parse_header(&[]), ParseHeaderOutcome::NeedFixed);

        // A matching signature prefix keeps buffering.
        assert_eq!(
            Pp::parse_header(&Pp::SIGNATURE[..5]),
            ParseHeaderOutcome::NeedFixed
        );

        // Full signature but the length field missing still keeps buffering.
        let h = Fixture::header(0x21, 0x11, &[]);
        assert_eq!(
            Pp::parse_header(&h[..Pp::FIXED_LEN - 2]),
            ParseHeaderOutcome::NeedFixed
        );
    }

    /// `parse_header` rejects a signature mismatch at whichever byte it appears.
    ///
    /// Setup: a wrong first byte, a correct prefix followed by a wrong byte, and a full header with its last signature byte flipped.
    /// Catches: comparing only once 12 or 16 bytes are buffered, or skipping later signature bytes.
    #[test]
    fn parse_header_bad_signature() {
        // First byte wrong.
        let bad = ParseHeaderOutcome::Invalid(PpError::BadSignature);
        assert_eq!(Pp::parse_header(b"G"), bad);

        // Correct prefix, then a diverging byte before the signature is complete.
        let mut partial = Pp::SIGNATURE[..5].to_vec();
        partial.push(b'X');
        assert_eq!(Pp::parse_header(&partial), bad);

        // Full fixed part with the final signature byte wrong.
        let mut h = Fixture::header(0x21, 0x00, &[]);
        h[11] ^= 0xFF;
        assert_eq!(Pp::parse_header(&h), bad);
    }

    /// `parse_header` rejects any version nibble other than 2 and reports the nibble.
    ///
    /// Setup: fixed parts with version nibbles 0 and 3.
    /// Catches: reading the version from the wrong nibble or byte.
    #[test]
    fn parse_header_bad_version() {
        // Version 0 and version 3, both with command PROXY.
        for (ver_cmd, ver) in [(0x01, 0), (0x31, 3)] {
            let h = Fixture::header(ver_cmd, 0x11, &[]);
            assert_eq!(
                Pp::parse_header(&h),
                ParseHeaderOutcome::Invalid(PpError::BadVersion(ver))
            );
        }
    }

    /// `parse_header` returns the total length as soon as exactly the fixed part is buffered.
    ///
    /// Setup: a 16-byte fixed part declaring 7 more bytes, none of which are present.
    /// Catches: waiting for the body before reporting length, or omitting `FIXED_LEN` from the total.
    #[test]
    fn parse_header_known_at_fixed_len() {
        // Fixed part only, declared length 7.
        let h = Fixture::header(0x21, 0x11, &[0; 7]);
        assert_eq!(
            Pp::parse_header(&h[..Pp::FIXED_LEN]),
            ParseHeaderOutcome::Known(Pp::FIXED_LEN + 7)
        );
    }

    /// `parse_header` handles the largest declared length without overflow or sign issues.
    ///
    /// Setup: a fixed part whose length field is `0xFFFF`.
    /// Catches: little-endian decoding or an arithmetic width that truncates the total.
    #[test]
    fn parse_header_max_len() {
        // Fixed part with the length bytes set to 0xFFFF.
        let mut h = Fixture::header(0x21, 0x11, &[]);
        h[14..16].copy_from_slice(&u16::MAX.to_be_bytes());
        assert_eq!(
            Pp::parse_header(&h),
            ParseHeaderOutcome::Known(Pp::FIXED_LEN + usize::from(u16::MAX))
        );
    }

    /// `parse` names LOCAL and PROXY commands and logs any other nibble as hex.
    ///
    /// Setup: UNSPEC headers with command nibbles 0, 1 and 0xF.
    /// Catches: rejecting an unknown command or swapping LOCAL and PROXY.
    #[test]
    fn parse_command_nibble() {
        for (ver_cmd, want) in [(0x20, "LOCAL"), (0x21, "PROXY"), (0x2F, "0xf")] {
            // Parse an empty UNSPEC header with this command.
            let h = Fixture::header(ver_cmd, 0x00, &[]);
            let Ok(Event::PpHeader { command, .. }) = Pp::parse(&h) else {
                panic!("0x{ver_cmd:02x} did not parse");
            };

            // The command string is the name or the raw nibble.
            assert_eq!(command, want);
        }
    }

    /// `parse` decodes addresses per family and logs an unknown family's block as hex.
    ///
    /// Setup: UNSPEC with a TLV, TCP4 from `Fixture::ipv4`, and family `0x31` with a 3-byte block.
    /// Catches: UNSPEC ignoring its TLVs, or an unknown family rejected or its block parsed as TLVs.
    #[test]
    fn parse_family() {
        // UNSPEC has no addresses, so its whole block is TLVs.
        let tlv = Fixture::tlv(0x01, b"h2");
        let h = Fixture::header(0x21, 0x00, &tlv);
        let Ok(Event::PpHeader {
            family, src, tlvs, ..
        }) = Pp::parse(&h)
        else {
            panic!("UNSPEC did not parse");
        };
        assert_eq!(family, "UNSPEC");
        assert_eq!(src, "");
        assert_eq!(tlvs, vec![Tlv::new(0x01, b"h2")]);

        // TCP4 decodes addresses, ports and the identity TLV.
        assert_eq!(Pp::parse(&Fixture::ipv4()), Ok(Fixture::ipv4_event()));

        // An unknown family keeps the raw block in `src` and parses no TLVs.
        let h = Fixture::header(0x21, 0x31, &[1, 2, 3]);
        let Ok(Event::PpHeader {
            family,
            src,
            dst,
            tlvs,
            ..
        }) = Pp::parse(&h)
        else {
            panic!("unknown family did not parse");
        };
        assert_eq!(family, "0x31");
        assert_eq!(src, "010203");
        assert_eq!(dst, "");
        assert!(tlvs.is_empty());
    }

    /// `parse` rejects an address block one byte shorter than its family's layout.
    ///
    /// Setup: TCP4 with an 11-byte block and TCP6 with a 35-byte block.
    /// Catches: panicking on out-of-range address offsets, or reporting the wrong family or length.
    #[test]
    fn parse_short_address() {
        for (fam, need) in [(0x11, 12), (0x21, 36)] {
            // Block one byte short of the family's address layout.
            let h = Fixture::header(0x21, fam, &vec![0; need - 1]);

            // The error carries the family byte and the bytes available.
            assert_eq!(
                Pp::parse(&h),
                Err(PpError::ShortAddress {
                    family: fam,
                    len: need - 1,
                })
            );
        }
    }

    /// `parse` reads TLVs that follow a TCP6 address block, including a zero-length one.
    ///
    /// Setup: TCP6 block of zeros followed by an empty `0x04` TLV and an `0xE0` identity TLV.
    /// Catches: TLV parsing starting at the wrong offset after 36 address bytes, or an empty TLV ending the list.
    #[test]
    fn parse_tlvs_after_ipv6_block() {
        // 36-byte address block, then two TLVs.
        let mut block = vec![0; 36];
        block.extend(Fixture::tlv(0x04, &[]));
        block.extend(Fixture::tlv(0xE0, IDENTITY.as_bytes()));
        let h = Fixture::header(0x21, 0x21, &block);

        // Both TLVs are returned in order.
        let Ok(Event::PpHeader { tlvs, .. }) = Pp::parse(&h) else {
            panic!("TCP6 with TLVs did not parse");
        };
        assert_eq!(
            tlvs,
            vec![Tlv::new(0x04, &[]), Tlv::new(0xE0, IDENTITY.as_bytes())]
        );
    }

    /// `parse` fails the whole header on a TLV that runs past its end.
    ///
    /// Setup: TCP4 address block followed by a 2-byte TLV stub, or by a TLV declaring 5 bytes but carrying 2.
    /// Catches: panicking on a short TLV, or returning the TLVs parsed before the bad one.
    #[test]
    fn parse_bad_tlv() {
        // A valid TLV first, so a partial list would be non-empty.
        let addrs = [10, 0, 0, 1, 10, 0, 0, 2, 0, 1, 0, 2];
        let good = Fixture::tlv(0x01, b"h2");

        for bad in [&[0xE0, 0x00][..], &[0xE0, 0x00, 0x05, 1, 2][..]] {
            // Truncated type/length header, then a value shorter than declared.
            let block = [&addrs[..], &good, bad].concat();
            let h = Fixture::header(0x21, 0x11, &block);
            assert_eq!(Pp::parse(&h), Err(PpError::BadTlv));
        }
    }
}
