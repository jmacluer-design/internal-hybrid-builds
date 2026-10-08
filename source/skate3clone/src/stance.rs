//! Retail natural/current stance separation.
//!
//! Skate 3 TU3 exposes `IsRidingGoofy`, `IsRidingSwitch`, and `IsMirrored`
//! independently. Static evaluator `0x82BA5AA8` compares two stance bytes,
//! while the natural-stance initializer, graph predicates, and decoded
//! B_SWITCH endpoint establish the player-facing result: switching flips the
//! current regular/goofy stance. This module keeps that relationship explicit
//! instead of treating "switch" as another name for goofy.

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum NaturalStance {
    #[default]
    Regular,
    Goofy,
}

impl NaturalStance {
    pub const fn is_goofy(self) -> bool {
        matches!(self, Self::Goofy)
    }

    pub const fn label(self) -> &'static str {
        match self {
            Self::Regular => "regular",
            Self::Goofy => "goofy",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum RidingStance {
    #[default]
    Regular,
    Goofy,
}

impl RidingStance {
    /// Retail `IsRidingGoofy`: natural-goofy XOR `IsRidingSwitch`.
    pub const fn from_natural_and_switch(natural: NaturalStance, riding_switch: bool) -> Self {
        if natural.is_goofy() ^ riding_switch {
            Self::Goofy
        } else {
            Self::Regular
        }
    }

    pub const fn is_goofy(self) -> bool {
        matches!(self, Self::Goofy)
    }

    pub const fn label(self) -> &'static str {
        match self {
            Self::Regular => "regular",
            Self::Goofy => "goofy",
        }
    }
}

/// State consumed by retail `IsMirrored` trick routing.
///
/// The player-facing words "regular" and "switch" are intentionally absent:
/// a naturally goofy skater is mirrored in their ordinary stance and becomes
/// unmirrored when riding switch.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum MirrorState {
    #[default]
    Unmirrored,
    Mirrored,
}

impl MirrorState {
    pub const fn from_riding_stance(stance: RidingStance) -> Self {
        if stance.is_goofy() {
            Self::Mirrored
        } else {
            Self::Unmirrored
        }
    }

    pub const fn is_mirrored(self) -> bool {
        matches!(self, Self::Mirrored)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retail_riding_goofy_is_natural_stance_xor_switch() {
        assert_eq!(
            RidingStance::from_natural_and_switch(NaturalStance::Regular, false),
            RidingStance::Regular
        );
        assert_eq!(
            RidingStance::from_natural_and_switch(NaturalStance::Regular, true),
            RidingStance::Goofy
        );
        assert_eq!(
            RidingStance::from_natural_and_switch(NaturalStance::Goofy, false),
            RidingStance::Goofy
        );
        assert_eq!(
            RidingStance::from_natural_and_switch(NaturalStance::Goofy, true),
            RidingStance::Regular
        );
    }

    #[test]
    fn mirror_state_follows_actual_riding_stance_not_switch_flag() {
        assert_eq!(
            MirrorState::from_riding_stance(RidingStance::Regular),
            MirrorState::Unmirrored
        );
        assert_eq!(
            MirrorState::from_riding_stance(RidingStance::Goofy),
            MirrorState::Mirrored
        );
    }
}
