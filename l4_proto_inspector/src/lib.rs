//! L4 middle proxy that logs, and for PROXY v2 strips, what clients send before it reaches the app.
#![warn(missing_docs)]

/// Sans-IO inspectors and the chain that runs them over client-to-app bytes.
pub mod core;
/// Crate error `InspectorError` and its subsystem errors.
pub mod error;
/// Tokio TCP proxy and the event sink that drive the core.
pub mod shell;
/// Helpers shared across modules.
pub mod util;
