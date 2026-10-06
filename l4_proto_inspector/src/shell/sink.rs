use std::time::Instant;

use serde::Serialize;
use tokio::sync::mpsc::UnboundedSender;

use crate::core::Event;

/// One log line: an event stamped with time since start and its connection id.
#[derive(Debug, Clone, Serialize)]
pub struct Record {
    /// Milliseconds since the process started.
    pub ms: u64,
    /// Connection id, starting at 1 in accept order.
    pub conn: u64,
    /// The event, flattened into the line.
    #[serde(flatten)]
    pub event: Event,
}

/// Where connections send their events; `main` prints them, tests read the channel.
#[derive(Clone)]
pub struct LogSink {
    tx: UnboundedSender<Record>,
    start: Instant,
}

impl LogSink {
    /// Sends records on `tx`, timestamped relative to `start`.
    pub fn new(tx: UnboundedSender<Record>, start: Instant) -> Self {
        Self { tx, start }
    }

    /// Stamps and sends each event for connection `conn`; drops them if the receiver is gone.
    pub fn emit(&self, conn: u64, events: impl IntoIterator<Item = Event>) {
        let ms = self.start.elapsed().as_millis() as u64;
        for event in events {
            // A closed receiver means nobody is listening; dropping the event is fine.
            let _ = self.tx.send(Record { ms, conn, event });
        }
    }
}
