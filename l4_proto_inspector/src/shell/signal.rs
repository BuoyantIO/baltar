use tokio::signal::unix::{Signal, SignalKind, signal};

use crate::error::InspectorError;

/// SIGTERM and SIGINT, caught so an assertion run can still report its verdict when stopped.
pub struct Shutdown {
    /// SIGTERM, as sent by Kubernetes when a pod is deleted.
    term: Signal,
    /// SIGINT, as sent by Ctrl-C.
    int: Signal,
}

impl Shutdown {
    /// Installs both handlers; on failure writes the OS reason to stderr and returns `Signal`.
    ///
    /// Install before binding, so a signal that arrives early ends the run instead of killing it.
    pub fn listen() -> Result<Self, InspectorError> {
        let install = |kind| {
            signal(kind).map_err(|e| {
                eprintln!("signal: {e}");
                InspectorError::Signal
            })
        };
        Ok(Self {
            term: install(SignalKind::terminate())?,
            int: install(SignalKind::interrupt())?,
        })
    }

    /// Resolves at the first SIGTERM or SIGINT and names it on stderr.
    pub async fn wait(mut self) {
        let name = tokio::select! {
            _ = self.term.recv() => "SIGTERM",
            _ = self.int.recv() => "SIGINT",
        };
        eprintln!("{name}: ending run");
    }
}
