//! Deterministic vertical slice of Skate 3 TU3's basic trick motion graph.
//!
//! This module deliberately models only behavior established by the recovered
//! retail XML and animation-bank metadata. Input gesture recognition, low/high
//! interpolation, contact thresholds, and concrete leaves behind virtual
//! `B_*`/`BLEND_*` resources remain outside this module until runtime evidence
//! resolves them.
#![allow(dead_code)]

use crate::board_authority::BoardAuthority;

const RETAIL_ANIMATION_HZ: f32 = 60.0;
const GROUND_TO_AIR_WILL_EXPIRE_SECONDS: f32 = 0.05;
const AIR_TO_BASELINE_WILL_EXPIRE_SECONDS: f32 = 0.05;
const AIR_BASELINE_BLEND_SECONDS: f32 = 0.2;
const LAND_BLEND_SECONDS: f32 = 0.15;
const POST_LAND_TRICK_LOCKOUT_SECONDS: f32 = 0.3;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BasicTrickKind {
    Ollie,
    Nollie,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrickHeightEndpoint {
    Low,
    High,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailClipSpec {
    pub resource: &'static str,
    pub samples: u16,
    pub sample_rate_hz: f32,
}

impl RetailClipSpec {
    /// Last authored sample timestamp. The RX2/ABIN export uses a sample at
    /// time zero, so N samples span N-1 sample intervals.
    pub fn authored_duration_seconds(self) -> f32 {
        self.samples.saturating_sub(1) as f32 / self.sample_rate_hz
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BasicTrickClipPair {
    pub ground: RetailClipSpec,
    pub air: RetailClipSpec,
}

pub const fn basic_trick_clips(
    kind: BasicTrickKind,
    endpoint: TrickHeightEndpoint,
) -> BasicTrickClipPair {
    let (ground_name, ground_samples, air_name, air_samples) = match (kind, endpoint) {
        (BasicTrickKind::Ollie, TrickHeightEndpoint::Low) => ("OLLIE_LOW_G", 13, "OLLIE_LOW_A", 29),
        (BasicTrickKind::Ollie, TrickHeightEndpoint::High) => {
            ("OLLIE_HIGH_G", 13, "OLLIE_HIGH_A", 19)
        }
        (BasicTrickKind::Nollie, TrickHeightEndpoint::Low) => {
            ("NOLLIE_LOW_G", 13, "NOLLIE_LOW_A", 29)
        }
        (BasicTrickKind::Nollie, TrickHeightEndpoint::High) => {
            ("NOLLIE_HIGH_G", 13, "NOLLIE_HIGH_A", 24)
        }
    };
    BasicTrickClipPair {
        ground: RetailClipSpec {
            resource: ground_name,
            samples: ground_samples,
            sample_rate_hz: RETAIL_ANIMATION_HZ,
        },
        air: RetailClipSpec {
            resource: air_name,
            samples: air_samples,
            sample_rate_hz: RETAIL_ANIMATION_HZ,
        },
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LandingAnimationResource {
    Straight,
    Nice,
    Sketchy,
}

impl LandingAnimationResource {
    pub const fn resource(self) -> &'static str {
        match self {
            Self::Straight => "BLEND_LAND",
            Self::Nice => "B_LAND_NICE",
            Self::Sketchy => "B_LAND_SKETCH",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum BasicTrickPhase {
    GroundLeaf,
    AirLeaf,
    AirBaseline,
    Landing { resource: LandingAnimationResource },
    PostLandLockout,
    Complete,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct BasicTrickSignals {
    /// The first observed loss of supporting wheel contact.
    pub wheel_lifted: bool,
    /// Retail has committed to its established in-air state.
    pub established_airborne: bool,
    /// Landing classification must come from the recovered contact/landing
    /// pipeline. This runtime intentionally does not classify contacts.
    pub landed: Option<LandingAnimationResource>,
    /// Raised by the animation graph when the selected landing resource ends.
    pub landing_animation_finished: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BasicTrickAnimationRequest {
    /// May be a concrete ABIN leaf or a virtual blend resource. Callers must
    /// resolve virtual resources before requesting a Bevy clip.
    pub resource: &'static str,
    pub local_time_seconds: f32,
    pub transition_seconds: f32,
    pub repeats: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WeightedBasicTrickAnimationRequest {
    pub request: BasicTrickAnimationRequest,
    pub weight: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct BasicTrickRuntime {
    pub kind: BasicTrickKind,
    pub height_endpoint: TrickHeightEndpoint,
    pub phase: BasicTrickPhase,
    pub phase_time_seconds: f32,
    pub board_authority: BoardAuthority,
    clips: BasicTrickClipPair,
}

impl BasicTrickRuntime {
    pub fn begin(kind: BasicTrickKind, height_endpoint: TrickHeightEndpoint) -> Self {
        Self {
            kind,
            height_endpoint,
            phase: BasicTrickPhase::GroundLeaf,
            phase_time_seconds: 0.0,
            board_authority: BoardAuthority::Physics,
            clips: basic_trick_clips(kind, height_endpoint),
        }
    }

    pub fn animation_request(&self) -> Option<BasicTrickAnimationRequest> {
        let (resource, local_time_seconds, transition_seconds, repeats) = match self.phase {
            BasicTrickPhase::GroundLeaf => (
                self.clips.ground.resource,
                self.phase_time_seconds,
                0.0,
                false,
            ),
            BasicTrickPhase::AirLeaf
                if self.phase_time_seconds < GROUND_TO_AIR_WILL_EXPIRE_SECONDS =>
            {
                // LeftGround requests `_A` as a retail sequence. Entering the
                // graph state at Ground's WillExpire boundary queues `_A`; it
                // does not discard Ground's final 0.05 seconds.
                (
                    self.clips.ground.resource,
                    self.clips.ground.authored_duration_seconds()
                        - GROUND_TO_AIR_WILL_EXPIRE_SECONDS
                        + self.phase_time_seconds,
                    0.0,
                    false,
                )
            }
            BasicTrickPhase::AirLeaf => (
                self.clips.air.resource,
                self.phase_time_seconds - GROUND_TO_AIR_WILL_EXPIRE_SECONDS,
                0.0,
                false,
            ),
            BasicTrickPhase::AirBaseline => (
                "B_AIR_CYC",
                self.phase_time_seconds,
                AIR_BASELINE_BLEND_SECONDS,
                true,
            ),
            BasicTrickPhase::Landing { resource } => (
                resource.resource(),
                self.phase_time_seconds,
                LAND_BLEND_SECONDS,
                false,
            ),
            BasicTrickPhase::PostLandLockout | BasicTrickPhase::Complete => return None,
        };
        Some(BasicTrickAnimationRequest {
            resource,
            local_time_seconds,
            transition_seconds,
            repeats,
        })
    }

    /// Physical playback layers after applying retail sequence and
    /// `transitionUnder` timing.
    ///
    /// `T_Ollie.xml` queues `_A` behind Ground, then `air.xml` blends
    /// `B_AIR_CYC` for 0.2 seconds while the final 0.05 seconds of `_A`
    /// continue underneath.
    pub fn animation_layers(&self) -> Vec<WeightedBasicTrickAnimationRequest> {
        let Some(target) = self.animation_request() else {
            return Vec::new();
        };
        if self.phase != BasicTrickPhase::AirBaseline
            || self.phase_time_seconds >= AIR_BASELINE_BLEND_SECONDS
        {
            return vec![WeightedBasicTrickAnimationRequest {
                request: target,
                weight: 1.0,
            }];
        }

        let target_weight = (self.phase_time_seconds / AIR_BASELINE_BLEND_SECONDS).clamp(0.0, 1.0);
        let source_time = (self.clips.air.authored_duration_seconds()
            - AIR_TO_BASELINE_WILL_EXPIRE_SECONDS
            + self
                .phase_time_seconds
                .min(AIR_TO_BASELINE_WILL_EXPIRE_SECONDS))
        .min(self.clips.air.authored_duration_seconds());
        vec![
            WeightedBasicTrickAnimationRequest {
                request: BasicTrickAnimationRequest {
                    resource: self.clips.air.resource,
                    local_time_seconds: source_time,
                    transition_seconds: 0.0,
                    repeats: false,
                },
                weight: 1.0 - target_weight,
            },
            WeightedBasicTrickAnimationRequest {
                request: target,
                weight: target_weight,
            },
        ]
    }

    pub fn tricks_allowed(&self) -> bool {
        self.phase == BasicTrickPhase::Complete
    }

    pub fn step(&mut self, delta_seconds: f32, signals: BasicTrickSignals) {
        if self.phase == BasicTrickPhase::Complete {
            return;
        }

        if let Some(resource) = signals.landed {
            self.phase = BasicTrickPhase::Landing { resource };
            self.phase_time_seconds = 0.0;
            self.board_authority = BoardAuthority::Physics;
            return;
        }

        if signals.wheel_lifted
            && matches!(
                self.phase,
                BasicTrickPhase::GroundLeaf | BasicTrickPhase::AirLeaf
            )
            && self.board_authority == BoardAuthority::Physics
        {
            self.board_authority = BoardAuthority::FollowAnimationData;
        }
        if signals.established_airborne
            && matches!(
                self.phase,
                BasicTrickPhase::GroundLeaf
                    | BasicTrickPhase::AirLeaf
                    | BasicTrickPhase::AirBaseline
            )
        {
            self.board_authority = BoardAuthority::Animation;
        }

        if matches!(self.phase, BasicTrickPhase::Landing { .. })
            && signals.landing_animation_finished
        {
            self.phase = BasicTrickPhase::PostLandLockout;
            self.phase_time_seconds = 0.0;
            return;
        }

        let mut unconsumed = delta_seconds.max(0.0);
        // A large deterministic test step can cross more than one authored
        // boundary. Carrying overflow makes the graph independent of render
        // cadence and preserves the fixed-clock phase.
        while unconsumed > 0.0 {
            let boundary = match self.phase {
                BasicTrickPhase::GroundLeaf => Some(
                    (self.clips.ground.authored_duration_seconds()
                        - GROUND_TO_AIR_WILL_EXPIRE_SECONDS)
                        .max(0.0),
                ),
                BasicTrickPhase::AirLeaf => {
                    // LeftGround begins at Ground's 0.05 second WillExpire
                    // boundary. Its sequence first consumes those queued
                    // Ground frames, then reaches `_A`'s own 0.05 second
                    // WillExpire boundary after exactly one `_A` duration.
                    Some(self.clips.air.authored_duration_seconds())
                }
                BasicTrickPhase::PostLandLockout => Some(POST_LAND_TRICK_LOCKOUT_SECONDS),
                BasicTrickPhase::AirBaseline
                | BasicTrickPhase::Landing { .. }
                | BasicTrickPhase::Complete => None,
            };

            let Some(boundary) = boundary else {
                self.phase_time_seconds += unconsumed;
                break;
            };
            let remaining = (boundary - self.phase_time_seconds).max(0.0);
            if unconsumed + f32::EPSILON < remaining {
                self.phase_time_seconds += unconsumed;
                break;
            }

            unconsumed = (unconsumed - remaining).max(0.0);
            self.phase_time_seconds = 0.0;
            self.phase = match self.phase {
                BasicTrickPhase::GroundLeaf => BasicTrickPhase::AirLeaf,
                BasicTrickPhase::AirLeaf => BasicTrickPhase::AirBaseline,
                BasicTrickPhase::PostLandLockout => BasicTrickPhase::Complete,
                phase => phase,
            };
            if self.phase == BasicTrickPhase::Complete {
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DT: f32 = 1.0 / 120.0;

    #[test]
    fn recovered_basic_clip_catalog_has_exact_endpoints() {
        let ollie_low = basic_trick_clips(BasicTrickKind::Ollie, TrickHeightEndpoint::Low);
        assert_eq!(ollie_low.ground.resource, "OLLIE_LOW_G");
        assert_eq!(ollie_low.ground.samples, 13);
        assert_eq!(ollie_low.air.resource, "OLLIE_LOW_A");
        assert_eq!(ollie_low.air.samples, 29);

        let nollie_high = basic_trick_clips(BasicTrickKind::Nollie, TrickHeightEndpoint::High);
        assert_eq!(nollie_high.ground.resource, "NOLLIE_HIGH_G");
        assert_eq!(nollie_high.air.resource, "NOLLIE_HIGH_A");
        assert_eq!(nollie_high.air.samples, 24);
    }

    #[test]
    fn ground_leaf_enters_air_leaf_at_retail_will_expire_window() {
        let mut trick = BasicTrickRuntime::begin(BasicTrickKind::Ollie, TrickHeightEndpoint::Low);
        let transition_at =
            trick.clips.ground.authored_duration_seconds() - GROUND_TO_AIR_WILL_EXPIRE_SECONDS;
        trick.step(transition_at - DT, BasicTrickSignals::default());
        assert_eq!(trick.phase, BasicTrickPhase::GroundLeaf);
        trick.step(DT, BasicTrickSignals::default());
        assert_eq!(trick.phase, BasicTrickPhase::AirLeaf);
        let queued_ground = trick.animation_request().unwrap();
        assert_eq!(queued_ground.resource, "OLLIE_LOW_G");
        assert!(
            (queued_ground.local_time_seconds
                - (trick.clips.ground.authored_duration_seconds()
                    - GROUND_TO_AIR_WILL_EXPIRE_SECONDS))
                .abs()
                < 1.0e-6
        );
    }

    #[test]
    fn sequence_consumes_ground_tail_before_starting_air_at_zero() {
        let mut trick = BasicTrickRuntime::begin(BasicTrickKind::Ollie, TrickHeightEndpoint::Low);
        let ground_transition_at =
            trick.clips.ground.authored_duration_seconds() - GROUND_TO_AIR_WILL_EXPIRE_SECONDS;
        trick.step(ground_transition_at, BasicTrickSignals::default());
        trick.step(
            GROUND_TO_AIR_WILL_EXPIRE_SECONDS,
            BasicTrickSignals::default(),
        );
        let air = trick.animation_request().unwrap();
        assert_eq!(air.resource, "OLLIE_LOW_A");
        assert!(air.local_time_seconds.abs() < 1.0e-6);
    }

    #[test]
    fn air_baseline_blends_over_retail_window_and_finishes_the_air_tail_underneath() {
        let mut trick = BasicTrickRuntime::begin(BasicTrickKind::Ollie, TrickHeightEndpoint::Low);
        let ground_transition_at =
            trick.clips.ground.authored_duration_seconds() - GROUND_TO_AIR_WILL_EXPIRE_SECONDS;
        trick.step(
            ground_transition_at + trick.clips.air.authored_duration_seconds(),
            BasicTrickSignals::default(),
        );
        assert_eq!(trick.phase, BasicTrickPhase::AirBaseline);

        trick.step(
            AIR_BASELINE_BLEND_SECONDS * 0.5,
            BasicTrickSignals::default(),
        );
        let layers = trick.animation_layers();
        assert_eq!(layers.len(), 2);
        assert_eq!(layers[0].request.resource, "OLLIE_LOW_A");
        assert_eq!(layers[1].request.resource, "B_AIR_CYC");
        assert!((layers[0].weight - 0.5).abs() < 1.0e-6);
        assert!((layers[1].weight - 0.5).abs() < 1.0e-6);
        assert!(
            (layers[0].request.local_time_seconds - trick.clips.air.authored_duration_seconds())
                .abs()
                < 1.0e-6
        );

        trick.step(
            AIR_BASELINE_BLEND_SECONDS * 0.5,
            BasicTrickSignals::default(),
        );
        let layers = trick.animation_layers();
        assert_eq!(layers.len(), 1);
        assert_eq!(layers[0].request.resource, "B_AIR_CYC");
        assert_eq!(layers[0].weight, 1.0);
    }

    #[test]
    fn board_authority_follows_the_observed_contact_lifecycle() {
        let mut trick = BasicTrickRuntime::begin(BasicTrickKind::Ollie, TrickHeightEndpoint::High);
        assert_eq!(trick.board_authority, BoardAuthority::Physics);

        trick.step(
            DT,
            BasicTrickSignals {
                wheel_lifted: true,
                ..BasicTrickSignals::default()
            },
        );
        assert_eq!(trick.board_authority, BoardAuthority::FollowAnimationData);

        trick.step(
            DT,
            BasicTrickSignals {
                established_airborne: true,
                ..BasicTrickSignals::default()
            },
        );
        assert_eq!(trick.board_authority, BoardAuthority::Animation);

        trick.step(
            DT,
            BasicTrickSignals {
                landed: Some(LandingAnimationResource::Straight),
                ..BasicTrickSignals::default()
            },
        );
        assert_eq!(trick.board_authority, BoardAuthority::Physics);
        assert_eq!(
            trick.animation_request().map(|request| request.resource),
            Some("BLEND_LAND")
        );
    }

    #[test]
    fn landing_finishes_into_exact_post_land_lockout() {
        let mut trick = BasicTrickRuntime::begin(BasicTrickKind::Nollie, TrickHeightEndpoint::Low);
        trick.step(
            0.0,
            BasicTrickSignals {
                landed: Some(LandingAnimationResource::Nice),
                ..BasicTrickSignals::default()
            },
        );
        trick.step(
            0.0,
            BasicTrickSignals {
                landing_animation_finished: true,
                ..BasicTrickSignals::default()
            },
        );
        assert_eq!(trick.phase, BasicTrickPhase::PostLandLockout);
        assert!(!trick.tricks_allowed());
        trick.step(
            POST_LAND_TRICK_LOCKOUT_SECONDS - DT,
            BasicTrickSignals::default(),
        );
        assert!(!trick.tricks_allowed());
        trick.step(DT, BasicTrickSignals::default());
        assert_eq!(trick.phase, BasicTrickPhase::Complete);
        assert!(trick.tricks_allowed());
    }

    #[test]
    fn phase_progression_is_fixed_step_partition_invariant() {
        let mut fine = BasicTrickRuntime::begin(BasicTrickKind::Nollie, TrickHeightEndpoint::High);
        let mut coarse = fine.clone();
        for _ in 0..120 {
            fine.step(DT, BasicTrickSignals::default());
        }
        coarse.step(1.0, BasicTrickSignals::default());
        assert_eq!(fine.phase, coarse.phase);
        assert!((fine.phase_time_seconds - coarse.phase_time_seconds).abs() < 1.0e-5);
    }

    #[test]
    fn height_interpolation_is_not_silently_invented() {
        let low = BasicTrickRuntime::begin(BasicTrickKind::Ollie, TrickHeightEndpoint::Low);
        let high = BasicTrickRuntime::begin(BasicTrickKind::Ollie, TrickHeightEndpoint::High);
        assert_ne!(low.clips.air.samples, high.clips.air.samples);
        assert!(matches!(
            low.height_endpoint,
            TrickHeightEndpoint::Low | TrickHeightEndpoint::High
        ));
    }
}
