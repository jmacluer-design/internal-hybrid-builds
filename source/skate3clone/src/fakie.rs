//! Evidence-backed Skate 3 TU3 fakie riding and automatic switch slice.
//!
//! The retail graph keeps four concepts separate:
//! `IsRidingFakie`, `IsRidingSwitch`, `IsMirrored`, and
//! `IsRollingBackwards`. This module therefore compares planar travel with
//! the logical skater-facing heading while the retail physics-animation
//! authority permits the test; it never treats a negative world-space
//! velocity component as fakie.

use std::f32::consts::{PI, TAU};

/// `UpdateRidingFakie` constructor default at `0x82BB2248`.
pub const RIDING_FAKIE_HIGH_SPEED_THRESHOLD: f32 = 1.0;
/// `UpdateRidingFakie` constructor default at `0x82BB2248`.
pub const RIDING_FAKIE_LOW_SPEED_THRESHOLD: f32 = 0.5;
/// Sustained low-speed backward travel required by `UpdateRidingFakie`.
pub const RIDING_FAKIE_SLOW_BACKWARD_SECONDS: f32 = 0.2;
/// `MotionGraph_OnBoard.xml` override supplied to `UpdateRidingFakie`.
pub const RIDING_FAKIE_FROM_RESET_SECONDS: f32 = 1.0;
/// Static `UpdateRidingFakie::Update` compares the normalized travel/facing
/// dot product against this value.
pub const RIDING_FAKIE_BACKWARD_DOT_THRESHOLD: f32 = -0.5;
/// `MotionGraphIncludes/ground.xml` enters `Turning.Switch` only after the
/// skater has remained in `Turning.Idle` for strictly more than 0.6 seconds.
pub const SWITCH_IDLE_DELAY_SECONDS: f32 = 0.6;
/// `MotionGraphIncludes/switch.xml`: `PlayAnimation B_SWITCH time="0.1"`.
pub const SWITCH_BLEND_IN_SECONDS: f32 = 0.1;
/// `MotionGraphIncludes/switch.xml`: leave at `WillExpire InTime="0.02"`.
pub const SWITCH_WILL_EXPIRE_SECONDS: f32 = 0.02;
/// The neutral style-0 physical B_SWITCH family leaf is 23 samples at 30 Hz.
pub const SWITCH_CLIP_DURATION_SECONDS: f32 = 22.0 / 30.0;
/// Returning `Turning.Idle` authors a 0.2-second BTREE_RIDING entry blend.
pub const SWITCH_TO_RIDING_BLEND_SECONDS: f32 = 0.2;
/// `FakieHeadChannel::Update` initializes the MotionGraph parameter named
/// `torso` to 0.5; stance-provider branches can override it to 0 or 1.
///
/// This is a blend-tree coordinate, not an animation layer weight and not a
/// Bevy skeleton-part mask.
pub const FAKIE_TORSO_PARAMETER_NEUTRAL: f32 = 0.5;
/// `FakieHeadChannel::Update` at `0x82BAC778` clamps each retail update
/// toward the selected endpoint by `[-0.01, 0.01]`.
pub const FAKIE_CHANNEL_MAX_DELTA_PER_UPDATE: f32 = 0.01;
/// MotionGraph animation behaviours update at the retail 60 Hz animation
/// cadence; Bevy's fixed simulation runs faster and scales the authored
/// per-update bound by elapsed time.
pub const FAKIE_CHANNEL_UPDATE_HZ: f32 = 60.0;
/// The animation request assembled by `FakieHeadChannel::Update` contains
/// 0.3-second in/out blend values around `B_FAKIE_CHANNEL`.
pub const FAKIE_CHANNEL_BLEND_SECONDS: f32 = 0.3;
/// `FAKIE_CHANNEL_CYC` contains 50 authored samples at 30 Hz. Cyclic playback
/// wraps from sample 49 to sample 0 over the fiftieth interval.
pub const FAKIE_CLIP_DURATION_SECONDS: f32 = 50.0 / 30.0;

/// Physical retail leaf used as the source evidence for the fakie channel.
#[cfg(test)]
pub const FAKIE_SOURCE_CLIP: &str = "FAKIE_CHANNEL_CYC";
/// Neutral retail B_FAKIE_CHANNEL result baked over R_IDLE_HCOM_000 using the
/// per-bone weights stored in OnBoard.abin: SPINE2=.5, SPINE3=.7, and the
/// NECK/NECK1/HEAD chain=1. Hips, legs, feet, arms, and board remain riding.
pub const FAKIE_RIDING_CLIP: &str = "RETAIL__B_FAKIE_CHANNEL__R_IDLE_HCOM_000";
pub const SWITCH_NEUTRAL_STYLE_ZERO_CLIP: &str = "R_SWITCH_RIDE_N_0_N";

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum TrickApproach {
    #[default]
    Regular,
    Fakie,
}

impl TrickApproach {
    pub const fn label(self) -> &'static str {
        match self {
            Self::Regular => "regular",
            Self::Fakie => "fakie",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum FakiePhase {
    #[default]
    Regular,
    RidingFakie,
    Switching,
}

impl FakiePhase {
    pub const fn label(self) -> &'static str {
        match self {
            Self::Regular => "regular",
            Self::RidingFakie => "fakie",
            Self::Switching => "fakie shuffle",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FakiePresentationSample {
    pub clip: &'static str,
    pub weight: f32,
    pub seek_time_seconds: f32,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct FakiePresentation {
    pub samples: Vec<FakiePresentationSample>,
    pub weight: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum MotionOrientation {
    FacingTravel {
        travel_alignment: f32,
        board_longitudinal_speed: f32,
    },
    Fakie {
        travel_alignment: f32,
        board_longitudinal_speed: f32,
    },
    Stationary,
    Invalid,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum FakieStepEvent {
    #[default]
    None,
    SwitchStarted,
    SwitchCompleted,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FakieRuntime {
    pub phase: FakiePhase,
    /// Retail's `IsRidingSwitch` remains distinct from `IsRidingFakie`.
    /// `B_SWITCH` toggles this stance while leaving board travel untouched.
    pub riding_switch: bool,
    /// Eligible `Turning.Idle` time. Leaving that parent state resets this
    /// clock, matching `InParentStateForTime greater="0.6"`.
    pub eligible_idle_seconds: f32,
    pub slowly_rolling_backward_seconds: f32,
    pub time_since_orientation_reset_seconds: f32,
    pub switch_elapsed_seconds: f32,
    pub switch_out_elapsed_seconds: Option<f32>,
    torso_parameter_value: f32,
    animation_channel_weight_value: f32,
    /// Logical skater-facing heading relative to board yaw. Retail exposes
    /// fakie through the skater-animation provider, independently from its
    /// board-local `IsRollingBackwards` physics condition.
    pub logical_facing_yaw_offset: f32,
}

impl Default for FakieRuntime {
    fn default() -> Self {
        Self {
            phase: FakiePhase::Regular,
            riding_switch: false,
            eligible_idle_seconds: 0.0,
            slowly_rolling_backward_seconds: 0.0,
            time_since_orientation_reset_seconds: 0.0,
            switch_elapsed_seconds: 0.0,
            switch_out_elapsed_seconds: None,
            torso_parameter_value: 0.0,
            animation_channel_weight_value: 0.0,
            logical_facing_yaw_offset: 0.0,
        }
    }
}

impl FakieRuntime {
    pub const fn is_riding_fakie(&self) -> bool {
        matches!(self.phase, FakiePhase::RidingFakie | FakiePhase::Switching)
    }

    pub const fn is_riding_switch(&self) -> bool {
        self.riding_switch
    }

    pub const fn trick_approach(&self) -> TrickApproach {
        if self.is_riding_fakie() {
            TrickApproach::Fakie
        } else {
            TrickApproach::Regular
        }
    }

    pub const fn blocks_new_trick(&self) -> bool {
        matches!(self.phase, FakiePhase::Switching)
    }

    /// Reproduce the recovered continuous `UpdateRidingFakie` filter from
    /// independent travel and logical skater-facing headings.
    pub fn observe_motion(
        &mut self,
        delta_seconds: f32,
        velocity_x: f32,
        velocity_z: f32,
        board_yaw: f32,
        motion_eligible: bool,
    ) -> MotionOrientation {
        if !delta_seconds.is_finite()
            || delta_seconds <= 0.0
            || !velocity_x.is_finite()
            || !velocity_z.is_finite()
            || !board_yaw.is_finite()
        {
            return MotionOrientation::Invalid;
        }
        self.time_since_orientation_reset_seconds += delta_seconds;

        let speed_squared = velocity_x * velocity_x + velocity_z * velocity_z;
        if speed_squared <= f32::EPSILON {
            self.slowly_rolling_backward_seconds = 0.0;
            if self.phase != FakiePhase::Switching {
                self.leave_fakie();
            }
            return MotionOrientation::Stationary;
        }
        let speed = speed_squared.sqrt();

        let board_forward_x = board_yaw.sin();
        let board_forward_z = board_yaw.cos();
        let board_longitudinal_speed = velocity_x * board_forward_x + velocity_z * board_forward_z;

        let logical_facing_yaw = board_yaw + self.logical_facing_yaw_offset;
        let travel_alignment =
            (velocity_x * logical_facing_yaw.sin() + velocity_z * logical_facing_yaw.cos()) / speed;
        let orientation = if travel_alignment < RIDING_FAKIE_BACKWARD_DOT_THRESHOLD {
            MotionOrientation::Fakie {
                travel_alignment,
                board_longitudinal_speed,
            }
        } else {
            MotionOrientation::FacingTravel {
                travel_alignment,
                board_longitudinal_speed,
            }
        };

        if self.phase == FakiePhase::Switching {
            return orientation;
        }
        if !motion_eligible {
            self.slowly_rolling_backward_seconds = 0.0;
            return orientation;
        }
        if self.time_since_orientation_reset_seconds <= RIDING_FAKIE_FROM_RESET_SECONDS {
            self.slowly_rolling_backward_seconds = 0.0;
            self.leave_fakie();
            return orientation;
        }

        let rolling_backward = travel_alignment < RIDING_FAKIE_BACKWARD_DOT_THRESHOLD;
        let should_enter_fakie = if rolling_backward && speed > RIDING_FAKIE_HIGH_SPEED_THRESHOLD {
            self.slowly_rolling_backward_seconds = 0.0;
            true
        } else if rolling_backward && speed > RIDING_FAKIE_LOW_SPEED_THRESHOLD {
            self.slowly_rolling_backward_seconds += delta_seconds;
            self.slowly_rolling_backward_seconds > RIDING_FAKIE_SLOW_BACKWARD_SECONDS
        } else {
            self.slowly_rolling_backward_seconds = 0.0;
            false
        };

        if should_enter_fakie {
            if self.phase != FakiePhase::RidingFakie {
                self.phase = FakiePhase::RidingFakie;
                self.eligible_idle_seconds = 0.0;
                self.switch_elapsed_seconds = 0.0;
                self.switch_out_elapsed_seconds = None;
            }
        } else {
            self.leave_fakie();
        }
        orientation
    }

    /// Advance only the recovered fakie/switch state. `blocked` represents
    /// leaving retail's `Turning.Idle` for anticipation, trick, landing, push,
    /// brake, slide, grind, manual, or another committed state.
    pub fn step(&mut self, delta_seconds: f32, blocked: bool) -> FakieStepEvent {
        if !delta_seconds.is_finite() || delta_seconds <= 0.0 {
            return FakieStepEvent::None;
        }

        if let Some(elapsed) = self.switch_out_elapsed_seconds.as_mut() {
            *elapsed += delta_seconds;
            if *elapsed + f32::EPSILON >= SWITCH_TO_RIDING_BLEND_SECONDS {
                self.switch_out_elapsed_seconds = None;
            }
        }

        let event = match self.phase {
            FakiePhase::Regular => FakieStepEvent::None,
            FakiePhase::RidingFakie => {
                if blocked {
                    self.eligible_idle_seconds = 0.0;
                    FakieStepEvent::None
                } else if self.riding_switch {
                    // ground.xml: IsRidingSwitch bypasses the otherwise strict
                    // >0.6 s Turning.Idle delay.
                    self.phase = FakiePhase::Switching;
                    self.switch_elapsed_seconds = 0.0;
                    FakieStepEvent::SwitchStarted
                } else {
                    self.eligible_idle_seconds += delta_seconds;
                    if self.eligible_idle_seconds > SWITCH_IDLE_DELAY_SECONDS {
                        self.phase = FakiePhase::Switching;
                        self.switch_elapsed_seconds = 0.0;
                        FakieStepEvent::SwitchStarted
                    } else {
                        FakieStepEvent::None
                    }
                }
            }
            FakiePhase::Switching => {
                self.switch_elapsed_seconds += delta_seconds;
                if self.switch_elapsed_seconds + SWITCH_WILL_EXPIRE_SECONDS + f32::EPSILON
                    >= SWITCH_CLIP_DURATION_SECONDS
                {
                    self.phase = FakiePhase::Regular;
                    self.riding_switch = !self.riding_switch;
                    self.logical_facing_yaw_offset =
                        wrap_angle(self.logical_facing_yaw_offset + PI);
                    self.switch_out_elapsed_seconds = Some(0.0);
                    FakieStepEvent::SwitchCompleted
                } else {
                    FakieStepEvent::None
                }
            }
        };
        self.step_torso_channel(delta_seconds);
        event
    }

    pub fn presentation(&self, _ride_phase_seconds: f32) -> FakiePresentation {
        match self.phase {
            // FakieHeadChannel is a global request layered over the currently
            // selected MotionGraph action. The animation adapter applies its
            // weight to action-relative baked partners; it is not a primary
            // idle replacement in this phase.
            FakiePhase::RidingFakie => FakiePresentation::default(),
            FakiePhase::Switching => {
                let switch_weight =
                    (self.switch_elapsed_seconds / SWITCH_BLEND_IN_SECONDS).clamp(0.0, 1.0);
                let mut samples = Vec::with_capacity(1);
                if switch_weight > f32::EPSILON {
                    samples.push(FakiePresentationSample {
                        clip: SWITCH_NEUTRAL_STYLE_ZERO_CLIP,
                        weight: switch_weight,
                        seek_time_seconds: self.switch_elapsed_seconds,
                    });
                }
                FakiePresentation {
                    samples,
                    weight: switch_weight,
                }
            }
            FakiePhase::Regular => {
                if let Some(elapsed) = self.switch_out_elapsed_seconds {
                    let weight = 1.0 - (elapsed / SWITCH_TO_RIDING_BLEND_SECONDS).clamp(0.0, 1.0);
                    return FakiePresentation {
                        samples: vec![FakiePresentationSample {
                            clip: SWITCH_NEUTRAL_STYLE_ZERO_CLIP,
                            weight: 1.0,
                            seek_time_seconds: SWITCH_CLIP_DURATION_SECONDS
                                - SWITCH_WILL_EXPIRE_SECONDS,
                        }],
                        weight,
                    };
                }
                FakiePresentation::default()
            }
        }
    }

    /// Current value of retail's MotionGraph `torso` blend coordinate.
    pub fn torso_parameter(&self) -> f32 {
        self.torso_parameter_value
    }

    /// Weight of the independent `B_FAKIE_CHANNEL` animation request.
    pub fn animation_channel_weight(&self) -> f32 {
        self.animation_channel_weight_value
    }

    fn desired_torso_parameter(&self) -> f32 {
        if self.is_riding_fakie() {
            FAKIE_TORSO_PARAMETER_NEUTRAL
        } else {
            0.0
        }
    }

    fn step_torso_channel(&mut self, delta_seconds: f32) {
        let target = self.desired_torso_parameter();
        let maximum_delta =
            FAKIE_CHANNEL_MAX_DELTA_PER_UPDATE * FAKIE_CHANNEL_UPDATE_HZ * delta_seconds;
        let delta = target - self.torso_parameter_value;
        self.torso_parameter_value = if delta.abs() <= maximum_delta {
            target
        } else {
            self.torso_parameter_value + delta.signum() * maximum_delta
        };

        let animation_target = if self.is_riding_fakie() { 1.0 } else { 0.0 };
        let maximum_animation_delta = delta_seconds / FAKIE_CHANNEL_BLEND_SECONDS;
        let animation_delta = animation_target - self.animation_channel_weight_value;
        self.animation_channel_weight_value = if animation_delta.abs() <= maximum_animation_delta {
            animation_target
        } else {
            self.animation_channel_weight_value + animation_delta.signum() * maximum_animation_delta
        };
    }

    fn leave_fakie(&mut self) {
        self.phase = FakiePhase::Regular;
        self.eligible_idle_seconds = 0.0;
        self.switch_elapsed_seconds = 0.0;
    }
}

fn wrap_angle(angle: f32) -> f32 {
    (angle + PI).rem_euclid(TAU) - PI
}

#[cfg(test)]
mod tests {
    use super::*;

    const DT: f32 = 1.0 / 120.0;

    fn enter_landed_180() -> FakieRuntime {
        let mut runtime = FakieRuntime {
            time_since_orientation_reset_seconds: RIDING_FAKIE_FROM_RESET_SECONDS,
            ..FakieRuntime::default()
        };
        let orientation = runtime.observe_motion(DT, 0.0, 4.0, PI, true);
        assert!(matches!(orientation, MotionOrientation::Fakie { .. }));
        runtime
    }

    fn settle_fakie_channel(runtime: &mut FakieRuntime) {
        for _ in 0..120 {
            runtime.step(DT, true);
        }
    }

    #[test]
    fn landed_180_uses_facing_vs_travel_and_enters_dedicated_fakie_channel() {
        let mut runtime = enter_landed_180();
        assert_eq!(runtime.phase, FakiePhase::RidingFakie);
        assert_eq!(runtime.trick_approach(), TrickApproach::Fakie);
        assert!(runtime.presentation(0.25).samples.is_empty());
        assert_eq!(runtime.torso_parameter(), 0.0);
        settle_fakie_channel(&mut runtime);
        assert_eq!(runtime.torso_parameter(), FAKIE_TORSO_PARAMETER_NEUTRAL);
        assert_eq!(runtime.animation_channel_weight(), 1.0);
        let presentation = runtime.presentation(0.25);
        assert_eq!(presentation, FakiePresentation::default());
    }

    #[test]
    fn runtime_uses_the_weighted_composition_instead_of_the_raw_channel() {
        assert_eq!(FAKIE_SOURCE_CLIP, "FAKIE_CHANNEL_CYC");
        assert_eq!(
            FAKIE_RIDING_CLIP,
            "RETAIL__B_FAKIE_CHANNEL__R_IDLE_HCOM_000"
        );
        assert_ne!(FAKIE_RIDING_CLIP, FAKIE_SOURCE_CLIP);

        let mut runtime = enter_landed_180();
        settle_fakie_channel(&mut runtime);
        let presentation = runtime.presentation(0.25);
        assert_eq!(presentation, FakiePresentation::default());
    }

    #[test]
    fn world_negative_velocity_does_not_define_fakie() {
        let mut runtime = FakieRuntime {
            time_since_orientation_reset_seconds: RIDING_FAKIE_FROM_RESET_SECONDS,
            ..FakieRuntime::default()
        };
        let orientation = runtime.observe_motion(DT, 0.0, -4.0, PI, true);
        assert!(matches!(
            orientation,
            MotionOrientation::FacingTravel { .. }
        ));
        assert_eq!(runtime.phase, FakiePhase::Regular);
    }

    #[test]
    fn low_speed_fakie_requires_recovered_point_two_second_filter() {
        let mut runtime = FakieRuntime {
            time_since_orientation_reset_seconds: RIDING_FAKIE_FROM_RESET_SECONDS,
            ..FakieRuntime::default()
        };
        for _ in 0..23 {
            runtime.observe_motion(DT, 0.0, 0.75, PI, true);
            assert_eq!(runtime.phase, FakiePhase::Regular);
        }
        runtime.observe_motion(DT, 0.0, 0.75, PI, true);
        assert_eq!(runtime.phase, FakiePhase::RidingFakie);
    }

    #[test]
    fn continuous_motion_update_recovers_after_an_ineligible_touchdown_sample() {
        let mut runtime = FakieRuntime {
            time_since_orientation_reset_seconds: RIDING_FAKIE_FROM_RESET_SECONDS,
            ..FakieRuntime::default()
        };
        runtime.observe_motion(DT, 0.0, 4.0, PI, false);
        assert_eq!(runtime.phase, FakiePhase::Regular);

        runtime.observe_motion(DT, 0.0, 4.0, PI, true);
        assert_eq!(runtime.phase, FakiePhase::RidingFakie);
    }

    #[test]
    fn airborne_fakie_trick_preserves_approach_until_ground_motion_resolves_again() {
        let mut runtime = enter_landed_180();
        runtime.observe_motion(DT, 0.0, 4.0, PI, false);
        assert_eq!(runtime.phase, FakiePhase::RidingFakie);
        assert_eq!(runtime.trick_approach(), TrickApproach::Fakie);
    }

    #[test]
    fn strict_point_six_delay_enters_authored_switch_leaf() {
        let mut runtime = enter_landed_180();
        settle_fakie_channel(&mut runtime);
        for _ in 0..72 {
            assert_eq!(runtime.step(DT, false), FakieStepEvent::None);
        }
        assert!((runtime.eligible_idle_seconds - 0.6).abs() < 1.0e-6);
        assert_eq!(runtime.phase, FakiePhase::RidingFakie);

        assert_eq!(runtime.step(DT, false), FakieStepEvent::SwitchStarted);
        assert_eq!(runtime.phase, FakiePhase::Switching);
        runtime.step(SWITCH_BLEND_IN_SECONDS * 0.5, false);
        let presentation = runtime.presentation(0.0);
        assert_eq!(presentation.samples.len(), 1);
        assert_eq!(presentation.samples[0].clip, SWITCH_NEUTRAL_STYLE_ZERO_CLIP);
        assert_eq!(runtime.torso_parameter(), FAKIE_TORSO_PARAMETER_NEUTRAL);
    }

    #[test]
    fn flickit_blocking_resets_parent_idle_clock_then_defers_full_delay() {
        let mut runtime = enter_landed_180();
        for _ in 0..60 {
            runtime.step(DT, false);
        }
        for _ in 0..240 {
            runtime.step(DT, true);
        }
        assert_eq!(runtime.eligible_idle_seconds, 0.0);
        assert_eq!(runtime.phase, FakiePhase::RidingFakie);

        for _ in 0..72 {
            runtime.step(DT, false);
        }
        assert_eq!(runtime.phase, FakiePhase::RidingFakie);
        runtime.step(DT, false);
        assert_eq!(runtime.phase, FakiePhase::Switching);
    }

    #[test]
    fn torso_parameter_uses_retail_point_zero_one_per_update_slew_bound() {
        let mut runtime = enter_landed_180();
        runtime.step(1.0 / FAKIE_CHANNEL_UPDATE_HZ, true);
        assert!((runtime.torso_parameter() - FAKIE_CHANNEL_MAX_DELTA_PER_UPDATE).abs() < 1.0e-6);
        settle_fakie_channel(&mut runtime);
        while runtime.phase == FakiePhase::RidingFakie {
            runtime.step(DT, false);
        }
        runtime.step(SWITCH_BLEND_IN_SECONDS * 0.5, false);
        assert_eq!(runtime.torso_parameter(), FAKIE_TORSO_PARAMETER_NEUTRAL);
    }

    #[test]
    fn fakie_animation_request_uses_recovered_point_three_second_blend() {
        let mut runtime = enter_landed_180();
        runtime.step(FAKIE_CHANNEL_BLEND_SECONDS * 0.5, true);
        assert!((runtime.animation_channel_weight() - 0.5).abs() < 1.0e-6);
        runtime.step(FAKIE_CHANNEL_BLEND_SECONDS * 0.5, true);
        assert_eq!(runtime.animation_channel_weight(), 1.0);
    }

    #[test]
    fn switch_completion_reorients_logical_facing_without_board_or_travel_mutation() {
        let mut runtime = enter_landed_180();
        while runtime.phase == FakiePhase::RidingFakie {
            runtime.step(DT, false);
        }
        while runtime.phase == FakiePhase::Switching {
            runtime.step(DT, false);
        }
        assert_eq!(runtime.phase, FakiePhase::Regular);
        assert!(runtime.is_riding_switch());
        assert!((runtime.logical_facing_yaw_offset.abs() - PI).abs() < 1.0e-6);

        let orientation = runtime.observe_motion(DT, 0.0, 4.0, PI, true);
        assert!(matches!(
            orientation,
            MotionOrientation::FacingTravel { .. }
        ));
    }

    #[test]
    fn switch_stance_fakie_uses_the_retail_immediate_shuffle_route() {
        let mut runtime = FakieRuntime {
            riding_switch: true,
            logical_facing_yaw_offset: PI,
            time_since_orientation_reset_seconds: RIDING_FAKIE_FROM_RESET_SECONDS,
            ..FakieRuntime::default()
        };
        runtime.observe_motion(DT, 0.0, 4.0, 0.0, true);
        assert_eq!(runtime.phase, FakiePhase::RidingFakie);
        assert_eq!(runtime.step(DT, false), FakieStepEvent::SwitchStarted);
    }
}
