mod chain;
mod event;
mod mode;
mod pp;
mod raw;

pub use chain::{Chain, ChainOutput};
pub use event::{Event, FlowDirection, Tlv};
pub use mode::Mode;
pub use pp::Pp;
pub use raw::Raw;

/// One sans-IO step over client-to-app bytes; `Chain` runs several in order.
pub trait Inspector: Send {
    /// Inspects the next chunk, which holds only bytes earlier inspectors did not strip.
    fn feed(&mut self, data: &[u8]) -> Output;
    /// Handles client eof; may close if the stream ended too early.
    fn eof(&mut self) -> Output;
}

#[derive(Debug, Clone, PartialEq, Eq)]
/// Whether the connection stays open after an inspector step.
pub enum Verdict {
    /// Keep copying bytes.
    Continue,
    /// Drop both sockets; carries the reason logged in `Event::Closed`.
    Close(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
/// What one inspector step produced.
pub struct Output {
    /// Events to log, in order.
    pub events: Vec<Event>,
    /// Leading bytes of `data` consumed; the rest goes to the next inspector.
    pub strip: usize,
    /// Whether to keep the connection open.
    pub verdict: Verdict,
}

impl Output {
    /// Logs `events`, strips nothing and continues.
    pub fn pass(events: Vec<Event>) -> Self {
        Self {
            events,
            strip: 0,
            verdict: Verdict::Continue,
        }
    }
}
