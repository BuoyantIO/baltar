use super::{Event, Inspector, Mode, Output, Verdict};

/// Runs inspectors in `--mode` order, each on the bytes the previous ones left.
pub struct Chain {
    inspectors: Vec<Box<dyn Inspector>>,
}

#[derive(Debug, PartialEq, Eq)]
/// Result of one chain step: bytes to forward, events to log and the verdict.
pub struct ChainOutput {
    /// Bytes left after every strip; empty on `Close`.
    pub forward: Vec<u8>,
    /// Events from every inspector that ran, then `Closed` on `Close`.
    pub events: Vec<Event>,
    /// `Close` from the first inspector that closed, else `Continue`.
    pub verdict: Verdict,
}

impl Chain {
    /// Builds one fresh inspector per mode, in order.
    pub fn new(modes: &[Mode]) -> Self {
        Self::from_inspectors(modes.iter().map(|m| m.inspector()).collect())
    }

    /// Wraps prebuilt inspectors; lets tests chain probes that no `Mode` builds.
    pub fn from_inspectors(inspectors: Vec<Box<dyn Inspector>>) -> Self {
        Self { inspectors }
    }

    /// Passes `data` through each inspector, stopping at the first `Close`.
    pub fn feed(&mut self, data: &[u8]) -> ChainOutput {
        let mut rest = data;
        let mut events = Vec::new();
        for inspector in &mut self.inspectors {
            // Each inspector sees only what earlier ones did not strip; the clamp guards
            // against an inspector reporting a strip longer than its input.
            let out = inspector.feed(rest);
            rest = &rest[out.strip.min(rest.len())..];
            if let Some(closed) = Self::absorb(out, &mut events) {
                return closed;
            }
        }
        // No inspector closed: forward whatever survived every strip.
        ChainOutput {
            forward: rest.to_vec(),
            events,
            verdict: Verdict::Continue,
        }
    }

    /// Signals client eof to each inspector, stopping at the first `Close`; forwards nothing.
    pub fn eof(&mut self) -> ChainOutput {
        // Every inspector gets eof so each can report its own truncation; the first close wins.
        let mut events = Vec::new();
        for inspector in &mut self.inspectors {
            if let Some(closed) = Self::absorb(inspector.eof(), &mut events) {
                return closed;
            }
        }
        // Eof carries no bytes, so there is never anything to forward.
        ChainOutput {
            forward: Vec::new(),
            events,
            verdict: Verdict::Continue,
        }
    }

    /// Appends `out.events`; on `Close` also appends `Event::Closed` and returns the final output.
    fn absorb(out: Output, events: &mut Vec<Event>) -> Option<ChainOutput> {
        // Keep the inspector's own events before any close marker so the log reads in order.
        events.extend(out.events);
        match out.verdict {
            Verdict::Continue => None,
            // The chain, not the inspector, adds `Closed` so it is logged exactly once,
            // and a closed connection forwards nothing.
            Verdict::Close(reason) => {
                events.push(Event::Closed {
                    reason: reason.clone(),
                });
                Some(ChainOutput {
                    forward: Vec::new(),
                    events: std::mem::take(events),
                    verdict: Verdict::Close(reason),
                })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::{FlowDirection, Raw};
    use crate::util::Hex;

    /// Test inspector: strips up to `strip` bytes, records what it saw, and optionally closes.
    struct Probe {
        name: &'static str,
        strip: usize,
        close: bool,
    }

    impl Inspector for Probe {
        fn feed(&mut self, data: &[u8]) -> Output {
            Output {
                events: vec![Event::Closed {
                    reason: format!("{}:{}", self.name, Hex::encode(data)),
                }],
                strip: self.strip.min(data.len()),
                verdict: if self.close {
                    Verdict::Close(self.name.to_string())
                } else {
                    Verdict::Continue
                },
            }
        }

        fn eof(&mut self) -> Output {
            Output::pass(Vec::new())
        }
    }

    impl Probe {
        fn boxed(name: &'static str, strip: usize, close: bool) -> Box<dyn Inspector> {
            Box::new(Self { name, strip, close })
        }

        fn saw(name: &str, data: &[u8]) -> Event {
            Event::Closed {
                reason: format!("{name}:{}", Hex::encode(data)),
            }
        }
    }

    /// Inspectors run in the order given and their events keep that order.
    ///
    /// Setup: `Chain::new(&[Mode::Raw, Mode::Raw])` fed `abc`, then two probes fed `x`.
    /// Catches: a chain that reorders or drops inspectors.
    #[test]
    fn chain_order() {
        // Two raw inspectors each log one chunk.
        let mut chain = Chain::new(&[Mode::Raw, Mode::Raw]);
        let out = chain.feed(b"abc");

        // Both chunks appear in order and all bytes are forwarded.
        let chunk = Event::chunk(FlowDirection::Request, b"abc");
        assert_eq!(out.events, vec![chunk.clone(), chunk]);
        assert_eq!(out.forward, b"abc");
        assert_eq!(out.verdict, Verdict::Continue);

        // Probes record what each saw, proving call order.
        let mut chain = Chain::from_inspectors(vec![
            Probe::boxed("a", 0, false),
            Probe::boxed("b", 0, false),
        ]);
        let out = chain.feed(b"x");
        assert_eq!(
            out.events,
            vec![Probe::saw("a", b"x"), Probe::saw("b", b"x")]
        );
    }

    /// Each inspector sees only bytes left after the previous strip, and only the remainder is forwarded.
    ///
    /// Setup: a probe stripping 2 bytes, then one stripping 1, then `Raw`, fed `abcdef`.
    /// Catches: strips applied to the original data instead of the remainder, or stripped bytes forwarded.
    #[test]
    fn strip_across_two_inspectors() {
        // Chain two stripping probes ahead of raw.
        let mut chain = Chain::from_inspectors(vec![
            Probe::boxed("a", 2, false),
            Probe::boxed("b", 1, false),
            Box::new(Raw),
        ]);
        let out = chain.feed(b"abcdef");

        // a sees all, b sees after a's strip, raw sees after both.
        assert_eq!(
            out.events,
            vec![
                Probe::saw("a", b"abcdef"),
                Probe::saw("b", b"cdef"),
                Event::chunk(FlowDirection::Request, b"def"),
            ]
        );
        assert_eq!(out.forward, b"def");

        // A probe that strips all it is fed (buffering) leaves nothing to forward.
        let mut chain = Chain::from_inspectors(vec![Probe::boxed("a", usize::MAX, false)]);
        assert!(chain.feed(b"abc").forward.is_empty());
    }

    /// The first `Close` stops the chain, adds `Closed`, and forwards nothing.
    ///
    /// Setup: probe `a` passes, probe `b` closes, probe `c` would log; fed `xy`.
    /// Catches: inspectors after a `Close` still running, or bytes forwarded on a closed connection.
    #[test]
    fn close_stops_chain() {
        // Middle probe closes.
        let mut chain = Chain::from_inspectors(vec![
            Probe::boxed("a", 0, false),
            Probe::boxed("b", 0, true),
            Probe::boxed("c", 0, false),
        ]);
        let out = chain.feed(b"xy");

        // c never runs; the close reason is logged and returned.
        assert_eq!(
            out.events,
            vec![
                Probe::saw("a", b"xy"),
                Probe::saw("b", b"xy"),
                Event::Closed { reason: "b".into() },
            ]
        );
        assert_eq!(out.verdict, Verdict::Close("b".into()));
        assert!(out.forward.is_empty());
    }
}
