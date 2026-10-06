use serde::Serialize;

use crate::util::Hex;

/// Bytes of a chunk shown in `Chunk::preview_hex`.
pub const PREVIEW_LEN: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
/// Direction of a logged chunk.
pub enum FlowDirection {
    /// Client to app.
    Request,
    /// App to client.
    Response,
}

/// One PROXY v2 TLV; serializes as `{"type":"0xe0","text":"..."}` or `{"type":"0x01","hex":"..."}`.
///
/// Log consumers grep for the `0xE0` identity, so that value must appear as plain text.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Tlv {
    #[serde(rename = "type", serialize_with = "Tlv::serialize_kind")]
    /// TLV type byte, serialized as `0x..`.
    pub kind: u8,

    #[serde(skip_serializing_if = "Option::is_none")]
    /// Value as UTF-8 (lossy); set only for `IDENTITY`.
    pub text: Option<String>,

    #[serde(skip_serializing_if = "Option::is_none")]
    /// Value as hex; set for every type except `IDENTITY`.
    pub hex: Option<String>,
}

impl Tlv {
    /// TLV type carrying the client identity as UTF-8.
    pub const IDENTITY: u8 = 0xE0;

    /// Builds a TLV, filling `text` for `IDENTITY` and `hex` otherwise.
    pub fn new(kind: u8, value: &[u8]) -> Self {
        let (text, hex) = if kind == Self::IDENTITY {
            (Some(String::from_utf8_lossy(value).into_owned()), None)
        } else {
            (None, Some(Hex::encode(value)))
        };
        Self { kind, text, hex }
    }

    fn serialize_kind<S: serde::Serializer>(kind: &u8, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&format!("0x{kind:02x}"))
    }
}

/// One observation on a connection; serializes with an `event` tag so a log line greps flat.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "event")]
pub enum Event {
    /// A chunk of bytes seen in one direction.
    Chunk {
        /// Which way the bytes flowed.
        dir: FlowDirection,
        /// Full chunk length in bytes.
        len: usize,
        /// Hex of at most the first `PREVIEW_LEN` bytes.
        preview_hex: String,
    },
    /// A parsed PROXY v2 header.
    PpHeader {
        /// The whole header as hex.
        raw_hex: String,
        /// Protocol version; always 2.
        version: u8,
        /// `LOCAL`, `PROXY`, or the raw nibble as hex.
        command: String,
        /// `UNSPEC`, `TCP4`, `TCP6`, or the raw byte as hex.
        family: String,
        /// Source socket address; for unparsed families, the whole address block as hex.
        src: String,
        /// Destination socket address; empty for `UNSPEC` and unparsed families.
        dst: String,
        /// TLVs after the addresses, in header order.
        tlvs: Vec<Tlv>,
    },
    /// The connection was closed by an inspector.
    Closed {
        /// Why the inspector closed it.
        reason: String,
    },
}

impl Event {
    /// Builds a `Chunk` event for `data`, capping the preview at `PREVIEW_LEN` bytes.
    pub fn chunk(dir: FlowDirection, data: &[u8]) -> Self {
        Event::Chunk {
            dir,
            len: data.len(),
            preview_hex: Hex::encode(&data[..data.len().min(PREVIEW_LEN)]),
        }
    }
}
