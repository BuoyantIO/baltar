use std::fmt::Write;

/// Lowercase hex encoding for log fields.
pub struct Hex;

impl Hex {
    /// Encodes `data` as lowercase hex, two characters per byte, no separators.
    pub fn encode(data: &[u8]) -> String {
        data.iter()
            .fold(String::with_capacity(data.len() * 2), |mut s, b| {
                let _ = write!(s, "{b:02x}");
                s
            })
    }
}
