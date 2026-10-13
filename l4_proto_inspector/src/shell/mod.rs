/// Accept loop, per-connection copy loops, and the one-connection assertion run.
mod proxy;
/// SIGTERM and SIGINT handling that ends an assertion run.
mod signal;
/// Event records and the channel they are sent on.
mod sink;

pub use proxy::Proxy;
pub use signal::Shutdown;
pub use sink::{LogSink, Record};
