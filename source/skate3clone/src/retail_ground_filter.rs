//! Proven frame gates from Skate 3 TU3's grounded/air state filter.
//!
//! Static dataflow through `0x82DE5BA0` establishes these three predicates,
//! but not the semantic producer of every raw state code. This module
//! therefore accepts the observed counters and booleans explicitly instead of
//! inventing a replacement state machine.

#![allow(dead_code)]

pub mod tu3 {
    pub const FILTER_GROUNDED_STATE: u32 = 0x82DE_5BA0;
}

/// Established air accepts ground on the fourth consecutive family-200 frame
/// only when that frame also carries contact evidence.
pub const fn established_air_accepts_ground(
    consecutive_family_200_frames: u32,
    has_contact_evidence: bool,
) -> bool {
    has_contact_evidence && consecutive_family_200_frames > 3
}

/// Established ground accepts air after both observed debounce counters pass.
///
/// Contact evidence is not read by this branch in TU3 and is deliberately not
/// accepted as an argument.
pub const fn established_ground_accepts_air(
    consecutive_family_200_frames: u32,
    frames_since_special: u32,
) -> bool {
    consecutive_family_200_frames > 3 && frames_since_special > 9
}

/// Raw state 201 may reacquire only on its sixth family-200 frame, with
/// contact evidence present and the observed veto clear.
pub const fn raw_201_accepts_reacquisition(
    consecutive_family_200_frames: u32,
    has_contact_evidence: bool,
    reacquisition_veto: bool,
) -> bool {
    has_contact_evidence && !reacquisition_veto && consecutive_family_200_frames > 5
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn established_air_requires_four_frames_and_contact() {
        assert!(!established_air_accepts_ground(3, true));
        assert!(!established_air_accepts_ground(4, false));
        assert!(established_air_accepts_ground(4, true));
    }

    #[test]
    fn established_ground_requires_both_counter_boundaries() {
        assert!(!established_ground_accepts_air(3, 10));
        assert!(!established_ground_accepts_air(4, 9));
        assert!(established_ground_accepts_air(4, 10));
    }

    #[test]
    fn raw_201_reacquisition_requires_six_frames_contact_and_clear_veto() {
        assert!(!raw_201_accepts_reacquisition(5, true, false));
        assert!(!raw_201_accepts_reacquisition(6, false, false));
        assert!(!raw_201_accepts_reacquisition(6, true, true));
        assert!(raw_201_accepts_reacquisition(6, true, false));
    }
}
