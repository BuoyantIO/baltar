use std::fmt;

/// The crate's error: what the CLI or a library caller can act on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InspectorError {
    /// The `pp` inspector rejected a stream header.
    Pp(PpError),
    /// `--mode` named an inspector other than `raw` or `pp`.
    UnknownMode,
    /// The listen address could not be bound or read back.
    Bind,
    /// The listener stopped accepting clients.
    Accept,
}

impl fmt::Display for InspectorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            InspectorError::Pp(e) => write!(f, "{e}"),
            InspectorError::UnknownMode => write!(f, "unknown mode, expected raw or pp"),
            InspectorError::Bind => write!(f, "cannot listen on this address"),
            InspectorError::Accept => write!(f, "listener failed"),
        }
    }
}

impl std::error::Error for InspectorError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            InspectorError::Pp(e) => Some(e),
            _ => None,
        }
    }
}

impl From<PpError> for InspectorError {
    fn from(e: PpError) -> Self {
        InspectorError::Pp(e)
    }
}

/// Why `pp` rejected the start of a stream; its `Display` is the `Close` reason.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PpError {
    /// The stream does not start with the 12-byte PROXY v2 signature.
    BadSignature,
    /// The version nibble is not 2; carries the nibble read.
    BadVersion(u8),
    /// The address block is shorter than its family requires.
    ShortAddress {
        /// Family/protocol byte from the header.
        family: u8,
        /// Bytes available in the address block.
        len: usize,
    },
    /// A TLV header or value runs past the end of the header.
    BadTlv,
    /// Eof arrived before the whole header.
    Truncated {
        /// Header bytes received.
        have: usize,
        /// Header bytes required; 16 until the length field is read.
        need: usize,
    },
}

impl fmt::Display for PpError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PpError::BadSignature => write!(f, "pp: bad PROXY v2 signature"),
            PpError::BadVersion(v) => write!(f, "pp: version {v}, expected 2"),
            PpError::ShortAddress { family, len } => {
                write!(
                    f,
                    "pp: {len}-byte address block too short for family 0x{family:02x}"
                )
            }
            PpError::BadTlv => write!(f, "pp: malformed TLV"),
            PpError::Truncated { have, need } => {
                write!(f, "pp: eof after {have} of {need} header bytes")
            }
        }
    }
}

impl std::error::Error for PpError {}
