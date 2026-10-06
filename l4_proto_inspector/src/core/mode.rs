use std::str::FromStr;

use super::{Inspector, Pp, Raw};
use crate::error::InspectorError;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// Inspector selected by one `--mode` flag.
pub enum Mode {
    /// Log each chunk's length and hex preview.
    Raw,
    /// Log and strip a leading PROXY v2 header.
    Pp,
}

impl Mode {
    /// Builds a fresh inspector for one connection.
    pub fn inspector(self) -> Box<dyn Inspector> {
        match self {
            Mode::Raw => Box::new(Raw),
            Mode::Pp => Box::new(Pp::default()),
        }
    }
}

impl FromStr for Mode {
    type Err = InspectorError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "raw" => Ok(Mode::Raw),
            "pp" => Ok(Mode::Pp),
            _ => Err(InspectorError::UnknownMode),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Known names parse and an unknown name returns `InspectorError::UnknownMode`.
    ///
    /// Setup: parse `raw`, `pp` and `tls`.
    /// Catches: a typo in `--mode` silently falling back to a default inspector.
    #[test]
    fn unknown_mode_errors() {
        // Known names map to their variants.
        assert_eq!("raw".parse::<Mode>().unwrap(), Mode::Raw);
        assert_eq!("pp".parse::<Mode>().unwrap(), Mode::Pp);

        // An unknown name errors instead of defaulting.
        assert_eq!("tls".parse::<Mode>(), Err(InspectorError::UnknownMode));
    }
}
