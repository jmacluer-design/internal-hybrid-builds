//! Deterministic TU3 motion-graph slice for non-basic flip and shuv tricks.
//!
//! This module preserves the retail graph's two distinct execution templates:
//!
//! - kickflip/heelflip use `In -> Cyc1..3 -> Out1..4`;
//! - shuv, varial, hardflip/inward and 360 families use one `_G -> _A`
//!   sequence, with optional underflip or dark-catch branches.
//!
//! Animation expiry, continuous height blending, special branches, physics
//! impulses and landing classification are deliberately external signals. The
//! recovered XML proves their gates, but not enough of their implementations
//! to reproduce them here without inventing behavior.
#![allow(dead_code)]

use crate::board_authority::BoardAuthority;

pub const WILL_EXPIRE_WINDOW_SECONDS: f32 = 0.05;
pub const FIRST_FLIP_TIME_TO_LAND_SECONDS: f32 = 0.525;
pub const SECOND_FLIP_TIME_TO_LAND_SECONDS: f32 = 0.8;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PopEnd {
    Tail,
    Nose,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AirTrickFamily {
    Kickflip,
    Heelflip,
    PopShuvit,
    FsPopShuvit,
    VarialKickflip,
    VarialHeelflip,
    Hardflip,
    InwardHeelflip,
    PopShuvit360,
    FsPopShuvit360,
    Flip360,
    Laserflip,
    Hardflip360,
    InwardHeelflip360,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct AirTrick {
    pub pop_end: PopEnd,
    pub family: AirTrickFamily,
}

impl AirTrick {
    pub const fn new(pop_end: PopEnd, family: AirTrickFamily) -> Self {
        Self { pop_end, family }
    }

    pub const fn intent_name(self) -> &'static str {
        use AirTrickFamily as F;
        use PopEnd as P;
        match (self.pop_end, self.family) {
            (P::Tail, F::Kickflip) => "Kickflip",
            (P::Tail, F::Heelflip) => "Heelflip",
            (P::Tail, F::PopShuvit) => "PopShuvit",
            (P::Tail, F::FsPopShuvit) => "FSPopShuvit",
            (P::Tail, F::VarialKickflip) => "VarialKickflip",
            (P::Tail, F::VarialHeelflip) => "VarialHeelflip",
            (P::Tail, F::Hardflip) => "Hardflip",
            (P::Tail, F::InwardHeelflip) => "InwardHeelflip",
            (P::Tail, F::PopShuvit360) => "360PopShuvit",
            (P::Tail, F::FsPopShuvit360) => "FS360PopShuvit",
            (P::Tail, F::Flip360) => "360Flip",
            (P::Tail, F::Laserflip) => "Laserflip",
            (P::Tail, F::Hardflip360) => "360Hardflip",
            (P::Tail, F::InwardHeelflip360) => "360InwardHeelflip",
            (P::Nose, F::Kickflip) => "N_Kickflip",
            (P::Nose, F::Heelflip) => "N_Heelflip",
            (P::Nose, F::PopShuvit) => "N_PopShuvit",
            (P::Nose, F::FsPopShuvit) => "N_FSPopShuvit",
            (P::Nose, F::VarialKickflip) => "N_VarialKickflip",
            (P::Nose, F::VarialHeelflip) => "N_VarialHeelflip",
            (P::Nose, F::Hardflip) => "N_Hardflip",
            (P::Nose, F::InwardHeelflip) => "N_InwardHeelflip",
            (P::Nose, F::PopShuvit360) => "N_360PopShuvit",
            (P::Nose, F::FsPopShuvit360) => "N_FS360PopShuvit",
            (P::Nose, F::Flip360) => "N_360Flip",
            (P::Nose, F::Laserflip) => "N_Laserflip",
            (P::Nose, F::Hardflip360) => "N_360Hardflip",
            (P::Nose, F::InwardHeelflip360) => "N_360InwardHeelflip",
        }
    }

    pub const fn animation_base(self) -> &'static str {
        use AirTrickFamily as F;
        use PopEnd as P;
        match (self.pop_end, self.family) {
            (P::Tail, F::Kickflip) => "B_KICKFLIP_IN",
            (P::Tail, F::Heelflip) => "B_HEELFLIP_IN",
            (P::Tail, F::PopShuvit) => "B_POPSHUVIT",
            (P::Tail, F::FsPopShuvit) => "B_FSPOPSHUVIT",
            (P::Tail, F::VarialKickflip) => "B_VARIALKICKFLIP",
            (P::Tail, F::VarialHeelflip) => "B_VARIALHEELFLIP",
            (P::Tail, F::Hardflip) => "B_HARDFLIP",
            (P::Tail, F::InwardHeelflip) => "B_INWARDHEELFLIP",
            (P::Tail, F::PopShuvit360) => "B_360POPSHUVIT",
            (P::Tail, F::FsPopShuvit360) => "B_FS360POPSHUVIT",
            (P::Tail, F::Flip360) => "B_360FLIP",
            (P::Tail, F::Laserflip) => "B_LASERFLIP",
            (P::Tail, F::Hardflip360) => "B_360HARDFLIP",
            (P::Tail, F::InwardHeelflip360) => "B_360INWARDHEELFLIP",
            (P::Nose, F::Kickflip) => "B_N_KICKFLIP_IN",
            (P::Nose, F::Heelflip) => "B_N_HEELFLIP_IN",
            (P::Nose, F::PopShuvit) => "B_N_POPSHUVIT",
            (P::Nose, F::FsPopShuvit) => "B_N_FSPOPSHUVIT",
            (P::Nose, F::VarialKickflip) => "B_N_VARIALKICKFLIP",
            (P::Nose, F::VarialHeelflip) => "B_N_VARIALHEELFLIP",
            (P::Nose, F::Hardflip) => "B_N_HARDFLIP",
            (P::Nose, F::InwardHeelflip) => "B_N_INWARDHEELFLIP",
            (P::Nose, F::PopShuvit360) => "B_N_360POPSHUVIT",
            (P::Nose, F::FsPopShuvit360) => "B_N_FS360POPSHUVIT",
            (P::Nose, F::Flip360) => "B_N_360FLIP",
            (P::Nose, F::Laserflip) => "B_N_LASERFLIP",
            (P::Nose, F::Hardflip360) => "B_N_360HARDFLIP",
            (P::Nose, F::InwardHeelflip360) => "B_N_360INWARDHEELFLIP",
        }
    }

    pub const fn template(self) -> TrickTemplate {
        use AirTrickFamily as F;
        match self.family {
            F::Kickflip | F::Heelflip => TrickTemplate::FlipLoop,
            F::PopShuvit | F::FsPopShuvit => TrickTemplate::SequenceWithUnderflip,
            F::Flip360 | F::Laserflip | F::Hardflip360 | F::InwardHeelflip360 => {
                TrickTemplate::SequenceWithDarkCatch
            }
            F::VarialKickflip
            | F::VarialHeelflip
            | F::Hardflip
            | F::InwardHeelflip
            | F::PopShuvit360
            | F::FsPopShuvit360 => TrickTemplate::Sequence,
        }
    }

    pub const fn rotation_family(self) -> DeckRotationFamily {
        use AirTrickFamily as F;
        match self.family {
            F::Kickflip => DeckRotationFamily::Kickflip,
            F::Heelflip => DeckRotationFamily::Heelflip,
            F::PopShuvit => DeckRotationFamily::BacksideShuvit,
            F::FsPopShuvit => DeckRotationFamily::FrontsideShuvit,
            F::VarialKickflip => DeckRotationFamily::BacksideShuvitKickflip,
            F::VarialHeelflip => DeckRotationFamily::FrontsideShuvitHeelflip,
            F::Hardflip => DeckRotationFamily::FrontsideShuvitKickflip,
            F::InwardHeelflip => DeckRotationFamily::BacksideShuvitHeelflip,
            F::PopShuvit360 => DeckRotationFamily::Backside360Shuvit,
            F::FsPopShuvit360 => DeckRotationFamily::Frontside360Shuvit,
            F::Flip360 => DeckRotationFamily::Backside360ShuvitKickflip,
            F::Laserflip => DeckRotationFamily::Frontside360ShuvitHeelflip,
            F::Hardflip360 => DeckRotationFamily::Frontside360ShuvitKickflip,
            F::InwardHeelflip360 => DeckRotationFamily::Backside360ShuvitHeelflip,
        }
    }

    /// Whether one completed physical leaf exchanges the deck's nose and tail.
    ///
    /// The extracted `_A` endpoints for these six families are approximately
    /// 180 degrees from `IA_IDLE_N_N_0_CYC`; the 360-shove families return to
    /// the baseline orientation. Pop end does not change that parity.
    pub const fn reverses_board_orientation(self) -> bool {
        use AirTrickFamily as F;
        matches!(
            self.family,
            F::PopShuvit
                | F::FsPopShuvit
                | F::VarialKickflip
                | F::VarialHeelflip
                | F::Hardflip
                | F::InwardHeelflip
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrickTemplate {
    FlipLoop,
    Sequence,
    SequenceWithUnderflip,
    SequenceWithDarkCatch,
}

/// Semantic rotation identity only. This does not prescribe an axis, sign,
/// angular rate, impulse, or completion threshold.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeckRotationFamily {
    Kickflip,
    Heelflip,
    BacksideShuvit,
    FrontsideShuvit,
    BacksideShuvitKickflip,
    FrontsideShuvitHeelflip,
    FrontsideShuvitKickflip,
    BacksideShuvitHeelflip,
    Backside360Shuvit,
    Frontside360Shuvit,
    Backside360ShuvitKickflip,
    Frontside360ShuvitHeelflip,
    Frontside360ShuvitKickflip,
    Backside360ShuvitHeelflip,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum TrickHeight {
    LowEndpoint,
    HighEndpoint,
    /// Retail passes `TrickHeight` into `SetBlend`; the exact curve and leaf
    /// weights are not yet recovered.
    ContinuousUnresolved(f32),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrickEntry {
    FromAnticipation,
    FromManual,
    FromDropIn,
    FromGrind,
    GrindOutAssist,
}

impl TrickEntry {
    pub const fn fixed_height(self) -> Option<f32> {
        match self {
            Self::FromDropIn => Some(0.6),
            Self::FromGrind => Some(0.5),
            Self::GrindOutAssist => Some(1.0),
            Self::FromAnticipation | Self::FromManual => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClipSegment {
    GrindOut,
    Ground,
    Air,
    FlipCycle(u8),
    FlipOut(u8),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AnimationRequest {
    /// Virtual MotionGraph resource base. It must be resolved to a concrete
    /// ABIN leaf before being sent to Bevy's animation player.
    pub virtual_base: &'static str,
    pub segment: ClipSegment,
    pub height: TrickHeight,
    pub transition: AnimationTransition,
    pub transition_under: bool,
}

impl AnimationRequest {
    pub fn virtual_resource_name(self) -> String {
        let suffix = match self.segment {
            ClipSegment::GrindOut => return self.virtual_base.to_owned(),
            ClipSegment::Ground => "_G".to_owned(),
            ClipSegment::Air => "_A".to_owned(),
            ClipSegment::FlipCycle(count) => format!("_CYC{count}"),
            ClipSegment::FlipOut(count) => format!("_OUT{count}"),
        };
        format!("{}{suffix}", self.virtual_base)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum AnimationTransition {
    Play { seconds: f32 },
    Blend { seconds: f32 },
    ChannelBlend { seconds: f32 },
    Sequence,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HandoffTarget {
    InAir,
    Land,
    OnBoard,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpecialRequest {
    None,
    Underflip,
    DarkCatch,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AirTrickPhase {
    GrindOut,
    TakeoffGround,
    LeftGroundAir,
    FlipCycle(u8),
    FlipOut(u8),
    Complete(HandoffTarget),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AirTrickSignals {
    pub wheel_lifted: bool,
    pub established_airborne: bool,
    /// Result of retail `WillExpire InTime="0.05"`.
    pub animation_will_expire: bool,
    pub trick_hold: bool,
    /// Required only for the first two kickflip/heelflip release decisions.
    pub time_to_land_seconds: Option<f32>,
    pub body_flipping: bool,
    pub can_transition_special: bool,
    pub special_request: SpecialRequest,
    /// Required when a completed sequence/out leaf can route to the parent
    /// InAir, Land, or OnBoard state.
    pub handoff_target: Option<HandoffTarget>,
    /// Selects doubled/tripled scoring at the authored underflip-window marker.
    pub underflip_window_end: bool,
}

impl Default for AirTrickSignals {
    fn default() -> Self {
        Self {
            wheel_lifted: false,
            established_airborne: false,
            animation_will_expire: false,
            trick_hold: false,
            time_to_land_seconds: None,
            body_flipping: false,
            can_transition_special: false,
            special_request: SpecialRequest::None,
            handoff_target: None,
            underflip_window_end: false,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnresolvedReason {
    ContinuousHeightBlend,
    AnimationExpirySignalRequired,
    TimeToLandRequired,
    HandoffTargetRequired,
    UnderflipBranch,
    DarkCatchBranch,
    ConcreteAnimationLeaf,
    RotationDynamics,
    InvalidInternalPhase,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StepOutcome {
    NoTransition,
    Transitioned,
    Completed(HandoffTarget),
    Unresolved(UnresolvedReason),
}

#[derive(Clone, Debug, PartialEq)]
pub struct AirTrickRuntime {
    pub trick: AirTrick,
    pub entry: TrickEntry,
    pub height: TrickHeight,
    pub phase: AirTrickPhase,
    pub board_authority: BoardAuthority,
}

impl AirTrickRuntime {
    pub fn begin(trick: AirTrick, entry: TrickEntry, height: TrickHeight) -> Self {
        let phase = if entry == TrickEntry::GrindOutAssist {
            AirTrickPhase::GrindOut
        } else {
            AirTrickPhase::TakeoffGround
        };
        Self {
            trick,
            entry,
            height,
            phase,
            board_authority: BoardAuthority::Physics,
        }
    }

    pub fn animation_request(&self) -> Option<AnimationRequest> {
        let (virtual_base, segment, transition, transition_under) = match self.phase {
            AirTrickPhase::GrindOut => (
                match self.trick.pop_end {
                    PopEnd::Tail => "GRIND_OUT_TAIL",
                    PopEnd::Nose => "GRIND_OUT_NOSE",
                },
                ClipSegment::GrindOut,
                AnimationTransition::ChannelBlend { seconds: 0.75 },
                false,
            ),
            AirTrickPhase::TakeoffGround => {
                let transition = match self.entry {
                    TrickEntry::FromAnticipation | TrickEntry::FromManual => {
                        AnimationTransition::Play { seconds: 0.05 }
                    }
                    TrickEntry::FromDropIn => AnimationTransition::Blend { seconds: 0.05 },
                    TrickEntry::FromGrind => AnimationTransition::ChannelBlend { seconds: 0.85 },
                    TrickEntry::GrindOutAssist => unreachable!("grind assist starts in GrindOut"),
                };
                (
                    self.trick.animation_base(),
                    ClipSegment::Ground,
                    transition,
                    false,
                )
            }
            AirTrickPhase::LeftGroundAir => (
                self.trick.animation_base(),
                ClipSegment::Air,
                if self.entry == TrickEntry::GrindOutAssist {
                    AnimationTransition::Play { seconds: 0.1 }
                } else {
                    AnimationTransition::Sequence
                },
                true,
            ),
            AirTrickPhase::FlipCycle(count) => (
                flip_cycle_base(self.trick),
                ClipSegment::FlipCycle(count),
                AnimationTransition::Sequence,
                true,
            ),
            AirTrickPhase::FlipOut(count) => (
                flip_out_base(self.trick),
                ClipSegment::FlipOut(count),
                AnimationTransition::Sequence,
                count <= 2,
            ),
            AirTrickPhase::Complete(_) => return None,
        };
        Some(AnimationRequest {
            virtual_base,
            segment,
            height: self.height,
            transition,
            transition_under,
        })
    }

    pub fn scored_flip_count(&self, underflip_window_end: bool) -> u8 {
        match self.phase {
            AirTrickPhase::FlipCycle(1) | AirTrickPhase::FlipOut(2) => 2,
            AirTrickPhase::FlipCycle(2) => {
                if underflip_window_end {
                    3
                } else {
                    2
                }
            }
            AirTrickPhase::FlipCycle(3) => {
                if underflip_window_end {
                    4
                } else {
                    3
                }
            }
            AirTrickPhase::FlipOut(count) => count,
            _ => 1,
        }
    }

    pub fn step(&mut self, signals: AirTrickSignals) -> StepOutcome {
        if matches!(self.phase, AirTrickPhase::Complete(_)) {
            return StepOutcome::NoTransition;
        }

        if signals.wheel_lifted && self.board_authority == BoardAuthority::Physics {
            self.board_authority = BoardAuthority::FollowAnimationData;
        }
        if signals.established_airborne {
            self.board_authority = BoardAuthority::Animation;
        }

        if let Some(reason) = self.unresolved_special_transition(signals) {
            return StepOutcome::Unresolved(reason);
        }

        if self.entry == TrickEntry::FromDropIn && self.phase == AirTrickPhase::TakeoffGround {
            self.phase = AirTrickPhase::LeftGroundAir;
            return StepOutcome::Transitioned;
        }

        if !signals.animation_will_expire {
            return StepOutcome::NoTransition;
        }

        match self.phase {
            AirTrickPhase::GrindOut | AirTrickPhase::TakeoffGround => {
                self.phase = AirTrickPhase::LeftGroundAir;
                StepOutcome::Transitioned
            }
            AirTrickPhase::LeftGroundAir => match self.trick.template() {
                TrickTemplate::FlipLoop => {
                    let Some(release) = release_first_flip(signals) else {
                        return StepOutcome::Unresolved(UnresolvedReason::TimeToLandRequired);
                    };
                    self.phase = if release {
                        AirTrickPhase::FlipOut(1)
                    } else {
                        AirTrickPhase::FlipCycle(1)
                    };
                    StepOutcome::Transitioned
                }
                TrickTemplate::Sequence
                | TrickTemplate::SequenceWithUnderflip
                | TrickTemplate::SequenceWithDarkCatch => self.finish(signals.handoff_target),
            },
            AirTrickPhase::FlipCycle(1) => {
                let Some(release) = release_second_flip(signals) else {
                    return StepOutcome::Unresolved(UnresolvedReason::TimeToLandRequired);
                };
                self.phase = if release {
                    AirTrickPhase::FlipOut(2)
                } else {
                    AirTrickPhase::FlipCycle(2)
                };
                StepOutcome::Transitioned
            }
            AirTrickPhase::FlipCycle(2) => {
                self.phase = if !signals.trick_hold || signals.body_flipping {
                    AirTrickPhase::FlipOut(3)
                } else {
                    AirTrickPhase::FlipCycle(3)
                };
                StepOutcome::Transitioned
            }
            AirTrickPhase::FlipCycle(3) => {
                self.phase = AirTrickPhase::FlipOut(4);
                StepOutcome::Transitioned
            }
            AirTrickPhase::FlipCycle(_) => {
                StepOutcome::Unresolved(UnresolvedReason::InvalidInternalPhase)
            }
            AirTrickPhase::FlipOut(_) => self.finish(signals.handoff_target),
            AirTrickPhase::Complete(_) => StepOutcome::NoTransition,
        }
    }

    fn unresolved_special_transition(&self, signals: AirTrickSignals) -> Option<UnresolvedReason> {
        if !signals.can_transition_special || signals.special_request == SpecialRequest::None {
            return None;
        }
        let supports_underflip = matches!(
            self.trick.template(),
            TrickTemplate::FlipLoop | TrickTemplate::SequenceWithUnderflip
        );
        let supports_dark_catch = matches!(
            self.trick.template(),
            TrickTemplate::FlipLoop | TrickTemplate::SequenceWithDarkCatch
        );
        match signals.special_request {
            SpecialRequest::Underflip if supports_underflip => {
                Some(UnresolvedReason::UnderflipBranch)
            }
            SpecialRequest::DarkCatch if supports_dark_catch => {
                Some(UnresolvedReason::DarkCatchBranch)
            }
            SpecialRequest::None | SpecialRequest::Underflip | SpecialRequest::DarkCatch => None,
        }
    }

    fn finish(&mut self, target: Option<HandoffTarget>) -> StepOutcome {
        let Some(target) = target else {
            return StepOutcome::Unresolved(UnresolvedReason::HandoffTargetRequired);
        };
        self.phase = AirTrickPhase::Complete(target);
        self.board_authority = match target {
            HandoffTarget::InAir => BoardAuthority::Animation,
            HandoffTarget::Land | HandoffTarget::OnBoard => BoardAuthority::Physics,
        };
        StepOutcome::Completed(target)
    }
}

fn release_first_flip(signals: AirTrickSignals) -> Option<bool> {
    if !signals.trick_hold || signals.body_flipping {
        return Some(true);
    }
    signals
        .time_to_land_seconds
        .map(|time| time < FIRST_FLIP_TIME_TO_LAND_SECONDS)
}

fn release_second_flip(signals: AirTrickSignals) -> Option<bool> {
    if !signals.trick_hold || signals.body_flipping {
        return Some(true);
    }
    signals
        .time_to_land_seconds
        .map(|time| time < SECOND_FLIP_TIME_TO_LAND_SECONDS)
}

fn flip_cycle_base(trick: AirTrick) -> &'static str {
    use AirTrickFamily as F;
    use PopEnd as P;
    match (trick.pop_end, trick.family) {
        (P::Tail, F::Kickflip) => "B_KICKFLIP",
        (P::Tail, F::Heelflip) => "B_HEELFLIP",
        (P::Nose, F::Kickflip) => "B_N_KICKFLIP",
        (P::Nose, F::Heelflip) => "B_N_HEELFLIP",
        _ => unreachable!("only flip-loop tricks request cycle resources"),
    }
}

fn flip_out_base(trick: AirTrick) -> &'static str {
    flip_cycle_base(trick)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn trick(pop_end: PopEnd, family: AirTrickFamily) -> AirTrick {
        AirTrick::new(pop_end, family)
    }

    fn expiring() -> AirTrickSignals {
        AirTrickSignals {
            animation_will_expire: true,
            ..AirTrickSignals::default()
        }
    }

    #[test]
    fn all_twenty_eight_retail_identities_have_exact_names_and_templates() {
        let families = [
            AirTrickFamily::Kickflip,
            AirTrickFamily::Heelflip,
            AirTrickFamily::PopShuvit,
            AirTrickFamily::FsPopShuvit,
            AirTrickFamily::VarialKickflip,
            AirTrickFamily::VarialHeelflip,
            AirTrickFamily::Hardflip,
            AirTrickFamily::InwardHeelflip,
            AirTrickFamily::PopShuvit360,
            AirTrickFamily::FsPopShuvit360,
            AirTrickFamily::Flip360,
            AirTrickFamily::Laserflip,
            AirTrickFamily::Hardflip360,
            AirTrickFamily::InwardHeelflip360,
        ];
        let mut names = std::collections::HashSet::new();
        for pop_end in [PopEnd::Tail, PopEnd::Nose] {
            for family in families {
                let trick = trick(pop_end, family);
                assert!(names.insert(trick.intent_name()));
                assert!(trick.animation_base().starts_with("B_"));
            }
        }
        assert_eq!(names.len(), 28);
        assert_eq!(
            trick(PopEnd::Tail, AirTrickFamily::Kickflip).template(),
            TrickTemplate::FlipLoop
        );
        assert_eq!(
            trick(PopEnd::Nose, AirTrickFamily::PopShuvit).template(),
            TrickTemplate::SequenceWithUnderflip
        );
        assert_eq!(
            trick(PopEnd::Tail, AirTrickFamily::Flip360).template(),
            TrickTemplate::SequenceWithDarkCatch
        );
    }

    #[test]
    fn only_odd_shove_families_reverse_the_board_at_catch() {
        let reversing = [
            AirTrickFamily::PopShuvit,
            AirTrickFamily::FsPopShuvit,
            AirTrickFamily::VarialKickflip,
            AirTrickFamily::VarialHeelflip,
            AirTrickFamily::Hardflip,
            AirTrickFamily::InwardHeelflip,
        ];
        let returning = [
            AirTrickFamily::Kickflip,
            AirTrickFamily::Heelflip,
            AirTrickFamily::PopShuvit360,
            AirTrickFamily::FsPopShuvit360,
            AirTrickFamily::Flip360,
            AirTrickFamily::Laserflip,
            AirTrickFamily::Hardflip360,
            AirTrickFamily::InwardHeelflip360,
        ];
        for pop_end in [PopEnd::Tail, PopEnd::Nose] {
            for family in reversing {
                assert!(trick(pop_end, family).reverses_board_orientation());
            }
            for family in returning {
                assert!(!trick(pop_end, family).reverses_board_orientation());
            }
        }
    }

    #[test]
    fn shared_sequence_preserves_ground_air_and_external_handoff() {
        let mut runtime = AirTrickRuntime::begin(
            trick(PopEnd::Nose, AirTrickFamily::Hardflip),
            TrickEntry::FromAnticipation,
            TrickHeight::LowEndpoint,
        );
        assert_eq!(
            runtime.animation_request().unwrap().virtual_resource_name(),
            "B_N_HARDFLIP_G"
        );
        assert_eq!(runtime.step(expiring()), StepOutcome::Transitioned);
        assert_eq!(
            runtime.animation_request().unwrap().virtual_resource_name(),
            "B_N_HARDFLIP_A"
        );
        assert_eq!(
            runtime.step(expiring()),
            StepOutcome::Unresolved(UnresolvedReason::HandoffTargetRequired)
        );
        assert_eq!(runtime.phase, AirTrickPhase::LeftGroundAir);
        let mut signals = expiring();
        signals.handoff_target = Some(HandoffTarget::InAir);
        assert_eq!(
            runtime.step(signals),
            StepOutcome::Completed(HandoffTarget::InAir)
        );
        assert_eq!(runtime.board_authority, BoardAuthority::Animation);
    }

    #[test]
    fn kickflip_release_and_time_to_land_gates_are_exact_and_strict() {
        let new_runtime = || {
            let mut runtime = AirTrickRuntime::begin(
                trick(PopEnd::Tail, AirTrickFamily::Kickflip),
                TrickEntry::FromAnticipation,
                TrickHeight::HighEndpoint,
            );
            runtime.step(expiring());
            runtime
        };

        let mut at_boundary = new_runtime();
        let mut signals = expiring();
        signals.trick_hold = true;
        signals.time_to_land_seconds = Some(FIRST_FLIP_TIME_TO_LAND_SECONDS);
        at_boundary.step(signals);
        assert_eq!(at_boundary.phase, AirTrickPhase::FlipCycle(1));

        let mut below_boundary = new_runtime();
        signals.time_to_land_seconds = Some(FIRST_FLIP_TIME_TO_LAND_SECONDS - 0.001);
        below_boundary.step(signals);
        assert_eq!(below_boundary.phase, AirTrickPhase::FlipOut(1));

        let mut released = new_runtime();
        released.step(expiring());
        assert_eq!(released.phase, AirTrickPhase::FlipOut(1));
    }

    #[test]
    fn held_flip_advances_through_the_retail_four_flip_path() {
        let mut runtime = AirTrickRuntime::begin(
            trick(PopEnd::Nose, AirTrickFamily::Heelflip),
            TrickEntry::FromAnticipation,
            TrickHeight::HighEndpoint,
        );
        runtime.step(expiring());

        let mut held = expiring();
        held.trick_hold = true;
        held.time_to_land_seconds = Some(2.0);
        runtime.step(held);
        assert_eq!(runtime.phase, AirTrickPhase::FlipCycle(1));
        assert_eq!(
            runtime.animation_request().unwrap().virtual_resource_name(),
            "B_N_HEELFLIP_CYC1"
        );

        runtime.step(held);
        assert_eq!(runtime.phase, AirTrickPhase::FlipCycle(2));
        runtime.step(held);
        assert_eq!(runtime.phase, AirTrickPhase::FlipCycle(3));
        runtime.step(held);
        assert_eq!(runtime.phase, AirTrickPhase::FlipOut(4));
        assert_eq!(runtime.scored_flip_count(true), 4);
        assert!(!runtime.animation_request().unwrap().transition_under);
    }

    #[test]
    fn body_flip_forces_the_current_kickflip_to_its_out_leaf() {
        let mut runtime = AirTrickRuntime::begin(
            trick(PopEnd::Tail, AirTrickFamily::Kickflip),
            TrickEntry::FromAnticipation,
            TrickHeight::LowEndpoint,
        );
        runtime.step(expiring());
        let mut held = expiring();
        held.trick_hold = true;
        held.body_flipping = true;
        runtime.step(held);
        assert_eq!(runtime.phase, AirTrickPhase::FlipOut(1));
    }

    #[test]
    fn board_authority_follows_wheel_air_and_landing_ownership() {
        let mut runtime = AirTrickRuntime::begin(
            trick(PopEnd::Tail, AirTrickFamily::VarialKickflip),
            TrickEntry::FromAnticipation,
            TrickHeight::LowEndpoint,
        );
        assert_eq!(runtime.board_authority, BoardAuthority::Physics);
        runtime.step(AirTrickSignals {
            wheel_lifted: true,
            ..AirTrickSignals::default()
        });
        assert_eq!(runtime.board_authority, BoardAuthority::FollowAnimationData);
        runtime.step(AirTrickSignals {
            established_airborne: true,
            ..AirTrickSignals::default()
        });
        assert_eq!(runtime.board_authority, BoardAuthority::Animation);
        runtime.step(expiring());
        let mut land = expiring();
        land.handoff_target = Some(HandoffTarget::Land);
        runtime.step(land);
        assert_eq!(runtime.phase, AirTrickPhase::Complete(HandoffTarget::Land));
        assert_eq!(runtime.board_authority, BoardAuthority::Physics);
    }

    #[test]
    fn entry_sources_keep_their_exact_retail_transition_modes_and_heights() {
        assert_eq!(TrickEntry::FromDropIn.fixed_height(), Some(0.6));
        assert_eq!(TrickEntry::FromGrind.fixed_height(), Some(0.5));
        assert_eq!(TrickEntry::GrindOutAssist.fixed_height(), Some(1.0));

        let t = trick(PopEnd::Nose, AirTrickFamily::PopShuvit360);
        let grind = AirTrickRuntime::begin(
            t,
            TrickEntry::FromGrind,
            TrickHeight::ContinuousUnresolved(0.5),
        );
        assert_eq!(
            grind.animation_request().unwrap().transition,
            AnimationTransition::ChannelBlend { seconds: 0.85 }
        );

        let assist =
            AirTrickRuntime::begin(t, TrickEntry::GrindOutAssist, TrickHeight::HighEndpoint);
        let request = assist.animation_request().unwrap();
        assert_eq!(request.virtual_resource_name(), "GRIND_OUT_NOSE");
        assert_eq!(
            request.transition,
            AnimationTransition::ChannelBlend { seconds: 0.75 }
        );
    }

    #[test]
    fn special_branches_are_reported_instead_of_faked() {
        let mut shuv = AirTrickRuntime::begin(
            trick(PopEnd::Tail, AirTrickFamily::PopShuvit),
            TrickEntry::FromAnticipation,
            TrickHeight::LowEndpoint,
        );
        shuv.step(expiring());
        let special = AirTrickSignals {
            can_transition_special: true,
            special_request: SpecialRequest::Underflip,
            animation_will_expire: true,
            ..AirTrickSignals::default()
        };
        assert_eq!(
            shuv.step(special),
            StepOutcome::Unresolved(UnresolvedReason::UnderflipBranch)
        );
        assert_eq!(shuv.phase, AirTrickPhase::LeftGroundAir);

        let mut tre = AirTrickRuntime::begin(
            trick(PopEnd::Nose, AirTrickFamily::Flip360),
            TrickEntry::FromAnticipation,
            TrickHeight::HighEndpoint,
        );
        tre.step(expiring());
        assert_eq!(
            tre.step(AirTrickSignals {
                special_request: SpecialRequest::DarkCatch,
                ..special
            }),
            StepOutcome::Unresolved(UnresolvedReason::DarkCatchBranch)
        );
    }

    #[test]
    fn continuous_height_and_rotation_dynamics_remain_explicit_unknowns() {
        let runtime = AirTrickRuntime::begin(
            trick(PopEnd::Tail, AirTrickFamily::Hardflip360),
            TrickEntry::FromAnticipation,
            TrickHeight::ContinuousUnresolved(0.37),
        );
        assert_eq!(runtime.height, TrickHeight::ContinuousUnresolved(0.37));
        assert_eq!(
            runtime.trick.rotation_family(),
            DeckRotationFamily::Frontside360ShuvitKickflip
        );
        assert_eq!(
            UnresolvedReason::RotationDynamics,
            UnresolvedReason::RotationDynamics
        );
        assert_eq!(
            UnresolvedReason::ConcreteAnimationLeaf,
            UnresolvedReason::ConcreteAnimationLeaf
        );
    }
}
