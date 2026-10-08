//! Held right-stick projection into the recovered TU3 Manual/ManualBrake inputs.
//!
//! The transport boundary is intentionally separate from Flickit. Flickit keeps
//! ownership of notification history; this controller samples the already
//! dead-zone-conditioned held stick without consuming or synthesizing events.

use bevy::prelude::Vec2;

use crate::manual_balance::{InputError, ManualIntentSample, produce_manual_intents};

pub const TU3_MANUAL_ENGAGE_SECONDS: f32 = 0.2;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ManualControlState {
    engage_seconds: f64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ManualControlStep {
    pub intents: ManualIntentSample,
    pub engage_seconds: f32,
    pub entry_ready: bool,
}

impl ManualControlState {
    pub const fn engage_seconds(self) -> f32 {
        self.engage_seconds as f32
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// Project one fixed-step held-stick sample.
    ///
    /// `right_stick` is the live input-map value after the project's recovered
    /// radial dead zone. Its Y sign already matches the ActionGraph convention:
    /// negative is tail manual and positive is nose manual.
    pub fn step(
        &mut self,
        right_stick: Vec2,
        delta_seconds: f32,
        suppressed: bool,
        manual_already_active: bool,
    ) -> Result<ManualControlStep, InputError> {
        let magnitude = right_stick.length().clamp(0.0, 1.0);
        let intents = produce_manual_intents(right_stick.y, magnitude, suppressed)?;
        let sign = intents.manual.map_or(0, |manual| manual.signum() as i8);

        if sign == 0 || suppressed {
            self.reset();
        } else if !manual_already_active {
            // CreateMGTimeIntentFromAGIntent resets only when Manual is absent.
            // A direct tail/nose sign crossing retains the elapsed presence.
            if delta_seconds.is_finite() && delta_seconds > 0.0 {
                let retail_fixed_delta = 1.0 / 120.0;
                self.engage_seconds += if (delta_seconds - retail_fixed_delta as f32).abs() < 1.0e-7
                {
                    retail_fixed_delta
                } else {
                    f64::from(delta_seconds)
                };
            }
        }

        Ok(ManualControlStep {
            intents,
            engage_seconds: self.engage_seconds as f32,
            entry_ready: !manual_already_active
                && intents.manual.is_some()
                && self.engage_seconds > f64::from(TU3_MANUAL_ENGAGE_SECONDS),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DT: f32 = 1.0 / 120.0;

    #[test]
    fn partial_down_and_up_route_to_tail_and_nose_without_notifications() {
        let mut tail = ManualControlState::default();
        let mut nose = ManualControlState::default();
        let down = tail.step(Vec2::new(0.0, -0.6), DT, false, false).unwrap();
        let up = nose.step(Vec2::new(0.0, 0.6), DT, false, false).unwrap();
        assert_eq!(down.intents.manual, Some(-0.6));
        assert_eq!(up.intents.manual, Some(0.6));
    }

    #[test]
    fn entry_timing_is_strict_and_frame_partition_invariant() {
        let mut fixed = ManualControlState::default();
        for _ in 0..24 {
            assert!(
                !fixed
                    .step(Vec2::new(0.0, -0.7), DT, false, false)
                    .unwrap()
                    .entry_ready
            );
        }
        assert_eq!(fixed.engage_seconds().to_bits(), 0.2_f32.to_bits());
        assert!(
            fixed
                .step(Vec2::new(0.0, -0.7), DT, false, false)
                .unwrap()
                .entry_ready
        );

        let mut partitioned = ManualControlState::default();
        for _ in 0..10 {
            partitioned
                .step(Vec2::new(0.0, -0.7), 0.025, false, false)
                .unwrap();
        }
        assert!(partitioned.engage_seconds() > TU3_MANUAL_ENGAGE_SECONDS);
    }

    #[test]
    fn dead_zone_release_resets_but_sign_change_preserves_presence_time() {
        let mut state = ManualControlState::default();
        for _ in 0..12 {
            state.step(Vec2::new(0.0, -0.5), DT, false, false).unwrap();
        }
        assert!(state.engage_seconds() > 0.0);
        state.step(Vec2::ZERO, DT, false, false).unwrap();
        assert_eq!(state.engage_seconds(), 0.0);
        state.step(Vec2::new(0.0, 0.5), DT, false, false).unwrap();
        assert_eq!(state.engage_seconds(), DT);
        state.step(Vec2::new(0.0, -0.5), DT, false, false).unwrap();
        assert_eq!(state.engage_seconds(), 2.0 * DT);
    }

    #[test]
    fn full_input_publishes_brake_and_does_not_add_an_entry_threshold() {
        let mut state = ManualControlState::default();
        let mut candidate = ManualControlStep::default();
        for _ in 0..25 {
            candidate = state.step(Vec2::new(0.0, -1.0), DT, false, false).unwrap();
        }
        assert!(candidate.entry_ready);
        assert!(candidate.intents.manual_brake.is_some());
        let active = state.step(Vec2::new(0.0, -1.0), DT, false, true).unwrap();
        assert!(active.intents.manual_brake.is_some());
    }

    #[test]
    fn small_same_side_changes_preserve_hold_time() {
        let mut state = ManualControlState::default();
        state.step(Vec2::new(0.0, 0.45), 0.1, false, false).unwrap();
        state
            .step(Vec2::new(0.08, 0.52), 0.11, false, false)
            .unwrap();
        assert!(state.engage_seconds() > TU3_MANUAL_ENGAGE_SECONDS);
    }
}
