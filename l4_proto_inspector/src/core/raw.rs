use super::{Event, FlowDirection, Inspector, Output};

#[derive(Debug, Default)]
/// Logs every client-to-app chunk as `Event::Chunk` and forwards it unchanged.
pub struct Raw;

impl Inspector for Raw {
    fn feed(&mut self, data: &[u8]) -> Output {
        Output::pass(vec![Event::chunk(FlowDirection::Request, data)])
    }

    fn eof(&mut self) -> Output {
        // Client eof: the client half-closed, so no more request bytes will arrive.
        // Raw buffers nothing and validates no framing, so there is nothing left to log
        // and no partial state that could make eof an error; passing lets the chain continue.
        // `Pp::eof` differs: it closes when eof lands before a complete header (truncation).
        Output::pass(Vec::new())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::util::Hex;

    /// The preview holds hex of at most the first 64 bytes while `len` is the full chunk size.
    ///
    /// Setup: feed `Raw` 100 bytes.
    /// Catches: an uncapped preview flooding the log, or `len` reporting the capped size.
    #[test]
    fn preview_capped_at_64() {
        // Feed a chunk longer than the cap.
        let data: Vec<u8> = (0..100).collect();
        let out = Raw.feed(&data);

        // Expect one uncapped length, a 64-byte preview, and no strip.
        assert_eq!(out.strip, 0);
        assert_eq!(
            out.events,
            vec![Event::Chunk {
                dir: FlowDirection::Request,
                len: 100,
                preview_hex: Hex::encode(&data[..64]),
            }]
        );
    }
}
