//! Recovered Skate 3 TU3 Ollie/Nollie anticipation motion-graph slice.
//!
//! The state order and transition values in this module come from
//! `AnticInto.xml`, `AnticCyc.xml`, and `AnticOut.xml`. The continuous
//! Compression filter and the Andale endpoint interpolation were recovered
//! from TU3 code and read-only SK8 runtime captures.

use crate::basic_trick_graph::BasicTrickAnimationRequest;
use crate::trick_animation::{
    AnticipationParameters, TrickAnimationParameters, adapt_basic_trick_request,
};
use crate::trick_catalog::{AnticipationSide, AnticipationStrength};
use crate::trick_input::AnticipationIdentity;

pub const INTO_BLEND_SECONDS: f32 = 0.2;
pub const INTO_PLAYBACK_SPEED: f32 = 1.2;
pub const INTO_WILL_EXPIRE_SECONDS: f32 = 0.07;
pub const CYCLE_BLEND_SECONDS: f32 = 0.3;
pub const OUT_BLEND_SECONDS: f32 = 0.15;
pub const COMPRESSION_UPDATE_HZ: f32 = 60.0;
pub const COMPRESSION_RAMP_SECONDS: f32 = 0.2;
pub const COMPRESSION_BLEND_RISING: f32 = 0.166;
pub const COMPRESSION_BLEND_FALLING: f32 = 0.05;
const ANDALE_EDGE_MARGIN: f32 = 0.01;

const TRANSITION_CLIP_SAMPLES: f32 = 15.0;
const TRANSITION_CLIP_HZ: f32 = 30.0;
const TRANSITION_CLIP_DURATION_SECONDS: f32 = (TRANSITION_CLIP_SAMPLES - 1.0) / TRANSITION_CLIP_HZ;
pub const INTO_TO_CYCLE_SECONDS: f32 =
    TRANSITION_CLIP_DURATION_SECONDS / INTO_PLAYBACK_SPEED - INTO_WILL_EXPIRE_SECONDS;
pub const OUT_COMPLETE_SECONDS: f32 = TRANSITION_CLIP_DURATION_SECONDS;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnticipationPhase {
    Into,
    Cycle,
    Out,
    Complete,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AnticipationAnimationSample {
    pub clip: &'static str,
    pub weight: f32,
    pub seek_time_seconds: f32,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct AnticipationAnimationState {
    pub samples: Vec<AnticipationAnimationSample>,
    pub weight: f32,
}

#[derive(Clone, Debug, PartialEq)]
struct AnticipationCycleTransition {
    source: AnticipationAnimationState,
    elapsed_seconds: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AnticipationRuntime {
    pub side: AnticipationSide,
    pub identity: AnticipationIdentity,
    /// Recovered L/N/R blend coordinate supplied to the physical anticipation
    /// leaves. Right-stick sector selection is independent from this axis.
    pub direction_coordinate: f32,
    pub phase: AnticipationPhase,
    pub phase_time_seconds: f32,
    /// Time spent in the held Into/Cycle states. This is the source for the
    /// measured pop-charge curve; Out time is deliberately excluded.
    pub charge_seconds: f32,
    /// Retail FilterMotionGraphIntent output published as `Compression`.
    pub compression_value: f32,
    /// Last per-update delta retained by the retail filter state.
    pub compression_delta: f32,
    compression_elapsed_seconds: f32,
    compression_accumulator_seconds: f32,
    cycle_transition: Option<AnticipationCycleTransition>,
    out_source: Option<AnticipationAnimationState>,
}

impl AnticipationRuntime {
    #[allow(dead_code)] // Retained as the Ollie/Nollie regression-test entry point.
    pub fn begin(side: AnticipationSide) -> Self {
        let identity = match side {
            AnticipationSide::Tail => AnticipationIdentity::Ollie,
            AnticipationSide::Nose => AnticipationIdentity::Nollie,
        };
        Self::begin_directional(identity, 0.0)
    }

    pub fn begin_directional(identity: AnticipationIdentity, direction_coordinate: f32) -> Self {
        Self {
            side: anticipation_side(identity),
            identity,
            direction_coordinate,
            phase: AnticipationPhase::Into,
            phase_time_seconds: 0.0,
            charge_seconds: 0.0,
            compression_value: 0.0,
            compression_delta: 0.0,
            compression_elapsed_seconds: 0.0,
            compression_accumulator_seconds: 0.0,
            cycle_transition: None,
            out_source: None,
        }
    }

    pub fn update_held_identity(
        &mut self,
        identity: AnticipationIdentity,
        direction_coordinate: f32,
    ) -> bool {
        if !self.is_held() || anticipation_side(identity) != self.side {
            return false;
        }
        let changes_cycle_resource =
            anticipation_cycle_resource(identity) != anticipation_cycle_resource(self.identity);
        if self.phase == AnticipationPhase::Cycle && changes_cycle_resource {
            // Every AnticCyc child enters through PlayAnimation time="0.3"
            // transitionUnder="true". Preserve the exact evaluated outgoing
            // pose (including an interrupted prior blend), restart the new
            // cycle leaf at zero, and let the source clock continue under it.
            let source = self.animation_state();
            self.phase_time_seconds = 0.0;
            self.cycle_transition = Some(AnticipationCycleTransition {
                source,
                elapsed_seconds: 0.0,
            });
        }
        self.identity = identity;
        self.direction_coordinate = direction_coordinate;
        true
    }

    pub fn is_held(&self) -> bool {
        matches!(
            self.phase,
            AnticipationPhase::Into | AnticipationPhase::Cycle
        )
    }

    pub fn request_cancel(&mut self) {
        if !self.is_held() {
            return;
        }
        self.out_source = Some(self.animation_state());
        self.cycle_transition = None;
        self.phase = AnticipationPhase::Out;
        self.phase_time_seconds = 0.0;
    }

    pub fn step(&mut self, delta_seconds: f32) {
        if self.is_held() {
            self.advance_compression_filter(delta_seconds.max(0.0), 1.0);
        }
        let mut remaining = delta_seconds.max(0.0);
        while remaining > 0.0 && self.phase != AnticipationPhase::Complete {
            let boundary = match self.phase {
                AnticipationPhase::Into => INTO_TO_CYCLE_SECONDS,
                AnticipationPhase::Cycle => {
                    self.phase_time_seconds += remaining;
                    self.charge_seconds += remaining;
                    let transition_complete =
                        if let Some(transition) = self.cycle_transition.as_mut() {
                            transition.elapsed_seconds += remaining;
                            for sample in &mut transition.source.samples {
                                sample.seek_time_seconds += remaining;
                            }
                            transition.elapsed_seconds + f32::EPSILON >= CYCLE_BLEND_SECONDS
                        } else {
                            false
                        };
                    if transition_complete {
                        self.cycle_transition = None;
                    }
                    return;
                }
                AnticipationPhase::Out => OUT_COMPLETE_SECONDS,
                AnticipationPhase::Complete => return,
            };
            let until_boundary = (boundary - self.phase_time_seconds).max(0.0);
            let consumed = remaining.min(until_boundary);
            self.phase_time_seconds += consumed;
            if self.is_held() {
                self.charge_seconds += consumed;
            }
            remaining -= consumed;
            if self.phase_time_seconds + f32::EPSILON < boundary {
                return;
            }
            self.phase_time_seconds = 0.0;
            self.phase = match self.phase {
                AnticipationPhase::Into => AnticipationPhase::Cycle,
                AnticipationPhase::Out => AnticipationPhase::Complete,
                phase => phase,
            };
        }
    }

    fn advance_compression_filter(&mut self, delta_seconds: f32, raw_value: f32) {
        const UPDATE_SECONDS: f32 = 1.0 / COMPRESSION_UPDATE_HZ;
        self.compression_accumulator_seconds += delta_seconds;
        while self.compression_accumulator_seconds + f32::EPSILON >= UPDATE_SECONDS {
            self.compression_accumulator_seconds -= UPDATE_SECONDS;
            self.compression_elapsed_seconds += UPDATE_SECONDS;
            let blend = if raw_value >= self.compression_value {
                COMPRESSION_BLEND_RISING
            } else {
                COMPRESSION_BLEND_FALLING
            };
            let ramp =
                (self.compression_elapsed_seconds / COMPRESSION_RAMP_SECONDS).clamp(0.0, 1.0);
            self.compression_delta = blend * ramp * (raw_value - self.compression_value);
            self.compression_value += self.compression_delta;
        }
    }

    pub fn animation_state(&self) -> AnticipationAnimationState {
        match self.phase {
            AnticipationPhase::Into => AnticipationAnimationState {
                samples: resolved_phase_samples(
                    self.side,
                    self.identity,
                    AnticipationPhase::Into,
                    self.phase_time_seconds * INTO_PLAYBACK_SPEED,
                    self.compression_value,
                    self.direction_coordinate,
                ),
                weight: transition_in_weight(self.phase_time_seconds, INTO_BLEND_SECONDS),
            },
            AnticipationPhase::Cycle => {
                if let Some(transition) = &self.cycle_transition {
                    let blend =
                        transition_in_weight(transition.elapsed_seconds, CYCLE_BLEND_SECONDS);
                    let mut samples =
                        weighted_samples(transition.source.samples.clone(), 1.0 - blend);
                    samples.extend(weighted_samples(
                        resolved_phase_samples(
                            self.side,
                            self.identity,
                            AnticipationPhase::Cycle,
                            self.phase_time_seconds,
                            self.compression_value,
                            self.direction_coordinate,
                        ),
                        blend,
                    ));
                    return AnticipationAnimationState {
                        samples,
                        weight: 1.0,
                    };
                }
                let blend = transition_in_weight(self.phase_time_seconds, CYCLE_BLEND_SECONDS);
                let mut samples = weighted_samples(
                    resolved_phase_samples(
                        self.side,
                        self.identity,
                        AnticipationPhase::Into,
                        INTO_TO_CYCLE_SECONDS * INTO_PLAYBACK_SPEED,
                        self.compression_value,
                        self.direction_coordinate,
                    ),
                    1.0 - blend,
                );
                samples.extend(weighted_samples(
                    resolved_phase_samples(
                        self.side,
                        self.identity,
                        AnticipationPhase::Cycle,
                        self.phase_time_seconds,
                        self.compression_value,
                        self.direction_coordinate,
                    ),
                    blend,
                ));
                AnticipationAnimationState {
                    samples,
                    weight: 1.0,
                }
            }
            AnticipationPhase::Out => {
                let blend = transition_in_weight(self.phase_time_seconds, OUT_BLEND_SECONDS);
                let source = self.out_source.clone().unwrap_or_default();
                let mut samples = weighted_samples(source.samples, 1.0 - blend);
                samples.extend(weighted_samples(
                    resolved_phase_samples(
                        self.side,
                        self.identity,
                        AnticipationPhase::Out,
                        self.phase_time_seconds,
                        self.compression_value,
                        self.direction_coordinate,
                    ),
                    blend,
                ));
                AnticipationAnimationState {
                    samples,
                    weight: source.weight + (1.0 - source.weight) * blend,
                }
            }
            AnticipationPhase::Complete => AnticipationAnimationState::default(),
        }
    }

    pub fn phase_label(&self) -> &'static str {
        match self.phase {
            AnticipationPhase::Into => "into",
            AnticipationPhase::Cycle => "cycle",
            AnticipationPhase::Out => "out",
            AnticipationPhase::Complete => "complete",
        }
    }
}

fn resolved_phase_samples(
    side: AnticipationSide,
    identity: AnticipationIdentity,
    phase: AnticipationPhase,
    local_time_seconds: f32,
    compression: f32,
    direction_coordinate: f32,
) -> Vec<AnticipationAnimationSample> {
    let resource = match (side, phase) {
        (AnticipationSide::Tail, AnticipationPhase::Into) => "B_ANTIC_INTO",
        (AnticipationSide::Nose, AnticipationPhase::Into) => "B_N_ANTIC_INTO",
        (_, AnticipationPhase::Cycle) => anticipation_cycle_resource(identity),
        (AnticipationSide::Tail, AnticipationPhase::Out) => "B_ANTIC_OUT",
        (AnticipationSide::Nose, AnticipationPhase::Out) => "B_N_ANTIC_OUT",
        (_, AnticipationPhase::Complete) => return Vec::new(),
    };
    let normal_weight = andale_endpoint_weight(compression);
    let endpoints = [
        (AnticipationStrength::High, 1.0 - normal_weight),
        (AnticipationStrength::Normal, normal_weight),
    ];
    let mut samples = Vec::new();
    for (strength, endpoint_weight) in endpoints {
        if endpoint_weight <= 0.0 {
            continue;
        }
        let adapted = adapt_basic_trick_request(
            BasicTrickAnimationRequest {
                resource,
                local_time_seconds,
                transition_seconds: 0.0,
                repeats: phase == AnticipationPhase::Cycle,
            },
            TrickAnimationParameters::Anticipation(AnticipationParameters {
                strength,
                direction: direction_coordinate,
            }),
        )
        .expect("the recovered anticipation endpoint catalog is complete");
        samples.extend(
            adapted
                .samples
                .into_iter()
                .map(|sample| AnticipationAnimationSample {
                    clip: sample.clip_name(),
                    weight: sample.weight * endpoint_weight,
                    seek_time_seconds: sample.seek_time_seconds,
                }),
        );
    }
    samples
}

pub const fn anticipation_side(identity: AnticipationIdentity) -> AnticipationSide {
    match identity {
        AnticipationIdentity::Ollie
        | AnticipationIdentity::PopShuvit
        | AnticipationIdentity::FsPopShuvit
        | AnticipationIdentity::ThreeSixtyPopShuvit
        | AnticipationIdentity::FsThreeSixtyPopShuvit => AnticipationSide::Tail,
        AnticipationIdentity::Nollie
        | AnticipationIdentity::NolliePopShuvit
        | AnticipationIdentity::NollieFsPopShuvit
        | AnticipationIdentity::NollieThreeSixtyPopShuvit
        | AnticipationIdentity::NollieFsThreeSixtyPopShuvit => AnticipationSide::Nose,
    }
}

pub const fn anticipation_cycle_resource(identity: AnticipationIdentity) -> &'static str {
    match identity {
        AnticipationIdentity::Ollie => "B_ANTIC_CYC",
        AnticipationIdentity::Nollie => "B_N_ANTIC_CYC",
        AnticipationIdentity::PopShuvit | AnticipationIdentity::ThreeSixtyPopShuvit => {
            "B_ANTIC_360SHUVIT_CYC"
        }
        AnticipationIdentity::FsPopShuvit | AnticipationIdentity::FsThreeSixtyPopShuvit => {
            "B_ANTIC_FS360SHUVIT_CYC"
        }
        AnticipationIdentity::NolliePopShuvit | AnticipationIdentity::NollieThreeSixtyPopShuvit => {
            "B_ANTIC_N360SHUVIT_CYC"
        }
        AnticipationIdentity::NollieFsPopShuvit
        | AnticipationIdentity::NollieFsThreeSixtyPopShuvit => "B_ANTIC_NFS360SHUVIT_CYC",
    }
}

/// Exact endpoint easing used by Andale's blend node after its 1% edge guard.
pub(crate) fn andale_endpoint_weight(value: f32) -> f32 {
    let usable_range = 1.0 - 2.0 * ANDALE_EDGE_MARGIN;
    let normalized = ((value - ANDALE_EDGE_MARGIN) / usable_range).clamp(0.0, 1.0);
    if normalized <= 0.5 {
        4.0 * normalized * normalized * (1.0 - normalized)
    } else {
        1.0 - 4.0 * (1.0 - normalized) * (1.0 - normalized) * normalized
    }
}

fn weighted_samples(
    samples: Vec<AnticipationAnimationSample>,
    weight: f32,
) -> Vec<AnticipationAnimationSample> {
    samples
        .into_iter()
        .map(|sample| AnticipationAnimationSample {
            weight: sample.weight * weight,
            ..sample
        })
        .collect()
}

fn transition_in_weight(time: f32, duration: f32) -> f32 {
    if duration > 0.0 {
        (time / duration).clamp(0.0, 1.0)
    } else {
        1.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DT: f32 = 1.0 / 120.0;

    #[test]
    fn into_uses_authored_speed_expiry_and_blend() {
        let mut anticipation = AnticipationRuntime::begin(AnticipationSide::Tail);
        anticipation.step(DT);
        let state = anticipation.animation_state();
        assert_eq!(anticipation.phase, AnticipationPhase::Into);
        assert!((state.weight - DT / INTO_BLEND_SECONDS).abs() < 1.0e-6);
        assert_eq!(
            state
                .samples
                .iter()
                .find(|sample| sample.weight > 0.0)
                .map(|sample| sample.clip),
            Some("R_HIGHANTIC_OLLIE_N_0_INTO")
        );
        assert!(
            (state
                .samples
                .iter()
                .find(|sample| sample.weight > 0.0)
                .unwrap()
                .seek_time_seconds
                - DT * INTO_PLAYBACK_SPEED)
                .abs()
                < 1.0e-6
        );

        anticipation.step(INTO_TO_CYCLE_SECONDS - DT);
        assert_eq!(anticipation.phase, AnticipationPhase::Cycle);
        assert!((anticipation.charge_seconds - INTO_TO_CYCLE_SECONDS).abs() < 1.0e-6);
    }

    #[test]
    fn cycle_crossfades_from_into_over_retail_window() {
        let mut anticipation = AnticipationRuntime::begin(AnticipationSide::Nose);
        anticipation.step(INTO_TO_CYCLE_SECONDS + CYCLE_BLEND_SECONDS * 0.5);
        let state = anticipation.animation_state();
        assert_eq!(anticipation.phase, AnticipationPhase::Cycle);
        let into_weight: f32 = state
            .samples
            .iter()
            .filter(|sample| sample.clip.ends_with("_INTO"))
            .map(|sample| sample.weight)
            .sum();
        let cycle_weight: f32 = state
            .samples
            .iter()
            .filter(|sample| sample.clip.ends_with("_CYC"))
            .map(|sample| sample.weight)
            .sum();
        assert!((into_weight - 0.5).abs() < 1.0e-5);
        assert!((cycle_weight - 0.5).abs() < 1.0e-5);
        assert!(
            state
                .samples
                .iter()
                .any(|sample| { sample.clip == "R_ANTIC_NOLLIE_N_0_CYC" && sample.weight > 0.0 })
        );
    }

    #[test]
    fn cancel_plays_authored_out_then_completes() {
        let mut anticipation = AnticipationRuntime::begin(AnticipationSide::Tail);
        anticipation.step(0.1);
        let charge = anticipation.charge_seconds;
        let compression = anticipation.compression_value;
        anticipation.request_cancel();
        anticipation.step(OUT_BLEND_SECONDS);
        let state = anticipation.animation_state();
        assert_eq!(anticipation.phase, AnticipationPhase::Out);
        assert!((anticipation.charge_seconds - charge).abs() < f32::EPSILON);
        assert!((anticipation.compression_value - compression).abs() < f32::EPSILON);
        assert!(
            state
                .samples
                .iter()
                .any(|sample| sample.clip == "R_ANTIC_OLLIE_N_0_OUT")
        );
        assert!(
            state
                .samples
                .iter()
                .any(|sample| sample.clip == "R_HIGHANTIC_OLLIE_N_0_OUT")
        );
        anticipation.step(OUT_COMPLETE_SECONDS - OUT_BLEND_SECONDS);
        assert_eq!(anticipation.phase, AnticipationPhase::Complete);
        assert!(anticipation.animation_state().samples.is_empty());
    }

    #[test]
    fn full_stick_endpoint_never_publishes_a_virtual_resource() {
        for side in [AnticipationSide::Tail, AnticipationSide::Nose] {
            let anticipation = AnticipationRuntime::begin(side);
            let state = anticipation.animation_state();
            assert!(
                state
                    .samples
                    .iter()
                    .all(|sample| !sample.clip.starts_with("B_"))
            );
        }
    }

    #[test]
    fn held_flat_ground_endpoint_never_selects_the_upright_highantic_family() {
        for side in [AnticipationSide::Tail, AnticipationSide::Nose] {
            let mut anticipation = AnticipationRuntime::begin(side);
            anticipation.step(2.0);
            let state = anticipation.animation_state();
            assert_eq!(anticipation.phase, AnticipationPhase::Cycle);
            assert_eq!(state.weight, 1.0);
            let normal: f32 = state
                .samples
                .iter()
                .filter(|sample| sample.clip.starts_with("R_ANTIC_"))
                .map(|sample| sample.weight)
                .sum();
            let high: f32 = state
                .samples
                .iter()
                .filter(|sample| sample.clip.starts_with("R_HIGHANTIC_"))
                .map(|sample| sample.weight)
                .sum();
            assert!(normal > 0.999);
            assert!(high < 0.001);
        }
    }

    #[test]
    fn every_retail_sector_selects_its_authored_cycle_family() {
        let cases = [
            (AnticipationIdentity::Ollie, "R_ANTIC_OLLIE_N_0_CYC"),
            (AnticipationIdentity::PopShuvit, "R_ANTIC_360SHUVIT_N_0_CYC"),
            (
                AnticipationIdentity::ThreeSixtyPopShuvit,
                "R_ANTIC_360SHUVIT_N_0_CYC",
            ),
            (
                AnticipationIdentity::FsPopShuvit,
                "R_ANTIC_FS360SHUVIT_N_0_CYC",
            ),
            (
                AnticipationIdentity::FsThreeSixtyPopShuvit,
                "R_ANTIC_FS360SHUVIT_N_0_CYC",
            ),
            (AnticipationIdentity::Nollie, "R_ANTIC_NOLLIE_N_0_CYC"),
            (
                AnticipationIdentity::NolliePopShuvit,
                "R_ANTIC_N360SHUVIT_N_0_CYC",
            ),
            (
                AnticipationIdentity::NollieThreeSixtyPopShuvit,
                "R_ANTIC_N360SHUVIT_N_0_CYC",
            ),
            (
                AnticipationIdentity::NollieFsPopShuvit,
                "R_ANTIC_NFS360SHUVIT_N_0_CYC",
            ),
            (
                AnticipationIdentity::NollieFsThreeSixtyPopShuvit,
                "R_ANTIC_NFS360SHUVIT_N_0_CYC",
            ),
        ];
        for (identity, expected_clip) in cases {
            let mut anticipation = AnticipationRuntime::begin_directional(identity, 0.0);
            anticipation.step(2.0);
            assert_eq!(anticipation.phase, AnticipationPhase::Cycle);
            assert!(
                anticipation
                    .animation_state()
                    .samples
                    .iter()
                    .any(|sample| sample.clip == expected_clip && sample.weight > 0.999),
                "{identity:?} did not select {expected_clip}"
            );
        }
    }

    #[test]
    fn shuv_cycle_preserves_exported_left_neutral_right_interpolation() {
        let mut anticipation = AnticipationRuntime::begin_directional(
            AnticipationIdentity::ThreeSixtyPopShuvit,
            -0.25,
        );
        anticipation.step(2.0);
        let state = anticipation.animation_state();
        let weight = |suffix: &str| {
            state
                .samples
                .iter()
                .filter(|sample| sample.clip.contains(suffix))
                .map(|sample| sample.weight)
                .sum::<f32>()
        };
        assert!((weight("_L_0_CYC") - 0.25).abs() < 1.0e-5);
        assert!((weight("_N_0_CYC") - 0.75).abs() < 1.0e-5);
        assert!(weight("_R_0_CYC") < 1.0e-5);
    }

    #[test]
    fn updating_within_the_same_tail_or_nose_side_changes_cycle_family() {
        let mut anticipation = AnticipationRuntime::begin(AnticipationSide::Tail);
        assert!(anticipation.update_held_identity(AnticipationIdentity::PopShuvit, 0.0));
        assert!(!anticipation.update_held_identity(AnticipationIdentity::Nollie, 0.0));
        anticipation.step(2.0);
        assert!(
            anticipation
                .animation_state()
                .samples
                .iter()
                .any(|sample| sample.clip == "R_ANTIC_360SHUVIT_N_0_CYC")
        );
    }

    #[test]
    fn held_cycle_family_switch_uses_authored_transition_under_blend() {
        let mut anticipation = AnticipationRuntime::begin(AnticipationSide::Tail);
        anticipation.step(INTO_TO_CYCLE_SECONDS + CYCLE_BLEND_SECONDS);
        let source_time = anticipation.phase_time_seconds;
        assert!(anticipation.update_held_identity(AnticipationIdentity::PopShuvit, 0.0));

        let entry = anticipation.animation_state();
        let entry_weight = |name: &str| {
            entry
                .samples
                .iter()
                .filter(|sample| sample.clip == name)
                .map(|sample| sample.weight)
                .sum::<f32>()
        };
        assert!((entry_weight("R_ANTIC_OLLIE_N_0_CYC") - 1.0).abs() < 1.0e-5);
        assert!(entry_weight("R_ANTIC_360SHUVIT_N_0_CYC") < 1.0e-5);

        anticipation.step(CYCLE_BLEND_SECONDS * 0.5);
        let midpoint = anticipation.animation_state();
        let sample = |name: &str| {
            midpoint
                .samples
                .iter()
                .find(|sample| sample.clip == name && sample.weight > 0.0)
                .unwrap()
        };
        let old = sample("R_ANTIC_OLLIE_N_0_CYC");
        let new = sample("R_ANTIC_360SHUVIT_N_0_CYC");
        assert!((old.weight - 0.5).abs() < 1.0e-5);
        assert!((new.weight - 0.5).abs() < 1.0e-5);
        assert!((old.seek_time_seconds - (source_time + CYCLE_BLEND_SECONDS * 0.5)).abs() < 1.0e-6);
        assert!((new.seek_time_seconds - CYCLE_BLEND_SECONDS * 0.5).abs() < 1.0e-6);

        anticipation.step(CYCLE_BLEND_SECONDS * 0.5);
        let settled = anticipation.animation_state();
        assert!(
            settled
                .samples
                .iter()
                .filter(|sample| sample.clip == "R_ANTIC_360SHUVIT_N_0_CYC")
                .map(|sample| sample.weight)
                .sum::<f32>()
                > 0.999
        );
        assert!(
            settled
                .samples
                .iter()
                .all(|sample| sample.clip != "R_ANTIC_OLLIE_N_0_CYC")
        );
    }

    #[test]
    fn same_authored_cycle_family_does_not_restart_for_pop_to_360_identity() {
        let mut anticipation =
            AnticipationRuntime::begin_directional(AnticipationIdentity::PopShuvit, 0.0);
        anticipation.step(INTO_TO_CYCLE_SECONDS + CYCLE_BLEND_SECONDS + 0.25);
        let before = anticipation.phase_time_seconds;
        assert!(anticipation.update_held_identity(AnticipationIdentity::ThreeSixtyPopShuvit, 0.0));
        assert_eq!(anticipation.phase_time_seconds, before);
        assert!(anticipation.cycle_transition.is_none());
    }

    #[test]
    fn retargeting_an_active_cycle_blend_uses_the_evaluated_pose_as_last_animation() {
        let mut anticipation = AnticipationRuntime::begin(AnticipationSide::Tail);
        anticipation.step(INTO_TO_CYCLE_SECONDS + CYCLE_BLEND_SECONDS);
        assert!(anticipation.update_held_identity(AnticipationIdentity::PopShuvit, 0.0));
        anticipation.step(CYCLE_BLEND_SECONDS * 0.5);
        let before = anticipation.animation_state();

        assert!(anticipation.update_held_identity(AnticipationIdentity::FsPopShuvit, 0.0));
        let after = anticipation.animation_state();
        let positive = |state: &AnticipationAnimationState| {
            state
                .samples
                .iter()
                .filter(|sample| sample.weight > 0.0)
                .map(|sample| (sample.clip, sample.weight, sample.seek_time_seconds))
                .collect::<Vec<_>>()
        };
        assert_eq!(positive(&after), positive(&before));

        anticipation.step(CYCLE_BLEND_SECONDS);
        let settled = anticipation.animation_state();
        assert!(
            settled
                .samples
                .iter()
                .filter(|sample| sample.clip == "R_ANTIC_FS360SHUVIT_N_0_CYC")
                .map(|sample| sample.weight)
                .sum::<f32>()
                > 0.999
        );
    }

    #[test]
    fn compression_filter_matches_the_captured_retail_sequence() {
        let expected = [
            0.013833333_f32,
            0.041117277,
            0.080910914,
            0.13176717,
            0.19181994,
            0.25889888,
        ];
        let mut anticipation = AnticipationRuntime::begin(AnticipationSide::Tail);
        for value in expected {
            anticipation.step(DT);
            anticipation.step(DT);
            assert!((anticipation.compression_value - value).abs() < 1.0e-7);
        }
    }

    #[test]
    fn andale_endpoint_curve_matches_captured_command_weights() {
        let captured = [
            (0.041117277_f32, 0.0039047874_f32),
            (0.080910914, 0.019427389),
            (0.13176717, 0.054081324),
            (0.19181994, 0.11214131),
            (0.25889888, 0.19248861),
            (0.6192711, 0.64411855),
        ];
        for (input, expected) in captured {
            assert!((andale_endpoint_weight(input) - expected).abs() < 1.0e-6);
        }
    }
}
