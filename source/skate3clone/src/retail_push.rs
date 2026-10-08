//! Retail Skate 3 push-tree coordinate solver.
//!
//! This is a direct, named translation of TU3
//! `ComputeTargetCoefsFromSpeedAndStrength` at `0x82BAD258`.
//! `SkaterAnimShared::InitPushAttributes` builds each point from the CYC1
//! animation's duration, `*_Vel_B`, and `Vel_E` metadata.  The solver is not a
//! rectangular bilinear blend: the HSTR and LSTR rows have independent,
//! duration-corrected speed coordinates and are then combined by a third
//! duration-corrected end-velocity coordinate.

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PushAttributePoint {
    pub duration: f32,
    pub velocity_begin: f32,
    pub velocity_end: f32,
}

impl PushAttributePoint {
    pub const fn new(source_frames: u32, velocity_begin: f32, velocity_end: f32) -> Self {
        Self {
            // ABIN samples include both endpoints.  Andale's source duration
            // therefore spans numFrames - 1 intervals.
            duration: (source_frames - 1) as f32 / 60.0,
            velocity_begin,
            velocity_end,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PushAttributes {
    pub low_speed_high_strength: PushAttributePoint,
    pub high_speed_high_strength: PushAttributePoint,
    pub low_speed_low_strength: PushAttributePoint,
    pub high_speed_low_strength: PushAttributePoint,
}

// Exact CYC1 metadata recovered from OnBoard.abin.  The N and MONGO trees use
// the same authored velocities but have different source durations.
pub const REGULAR_PUSH_ATTRIBUTES: PushAttributes = PushAttributes {
    low_speed_high_strength: PushAttributePoint::new(13, 0.0, 4.5),
    high_speed_high_strength: PushAttributePoint::new(5, 8.5, 11.5),
    low_speed_low_strength: PushAttributePoint::new(15, 0.0, 1.0),
    high_speed_low_strength: PushAttributePoint::new(4, 8.5, 9.0),
};

pub const MONGO_PUSH_ATTRIBUTES: PushAttributes = PushAttributes {
    low_speed_high_strength: PushAttributePoint::new(9, 0.0, 4.5),
    high_speed_high_strength: PushAttributePoint::new(5, 8.5, 11.5),
    low_speed_low_strength: PushAttributePoint::new(11, 0.0, 1.0),
    high_speed_low_strength: PushAttributePoint::new(5, 8.5, 9.0),
};

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PushTreeCoefficients {
    /// `HStr_Vel_B`: LSP-to-HSP coordinate inside the HSTR row.
    pub high_strength_velocity_begin: f32,
    /// `LStr_Vel_B`: LSP-to-HSP coordinate inside the LSTR row.
    pub low_strength_velocity_begin: f32,
    /// `Vel_E`: LSTR-row-to-HSTR-row coordinate.
    pub velocity_end: f32,
}

impl PushTreeCoefficients {
    /// Leaf order matches `SkaterAnimShared::Init`: LSP_HSTR, HSP_HSTR,
    /// LSP_LSTR, HSP_LSTR.
    pub fn leaf_weights(self) -> [f32; 4] {
        let high_speed_high_strength = self.high_strength_velocity_begin.clamp(0.0, 1.0);
        let high_speed_low_strength = self.low_strength_velocity_begin.clamp(0.0, 1.0);
        let high_strength = self.velocity_end.clamp(0.0, 1.0);
        let low_strength = 1.0 - high_strength;
        [
            (1.0 - high_speed_high_strength) * high_strength,
            high_speed_high_strength * high_strength,
            (1.0 - high_speed_low_strength) * low_strength,
            high_speed_low_strength * low_strength,
        ]
    }
}

#[derive(Clone, Copy)]
struct RowSolution {
    coefficient: f32,
    duration: f32,
    velocity_end: f32,
}

fn solve_row(
    physical_speed: f32,
    low_speed: PushAttributePoint,
    high_speed: PushAttributePoint,
) -> RowSolution {
    let begin_min = low_speed.velocity_begin.min(high_speed.velocity_begin);
    let begin_max = low_speed.velocity_begin.max(high_speed.velocity_begin);
    let speed = physical_speed.clamp(begin_min, begin_max);

    // This is the rational interpolation at 0x82BAD474..0x82BAD4C0.  It
    // compensates for Andale's duration-weighted synchronized child clocks.
    let low_distance = (speed - low_speed.velocity_begin).max(0.0);
    let high_distance = (high_speed.velocity_begin - speed).max(0.0);
    let numerator = low_speed.duration * low_distance;
    let denominator = high_speed.duration * high_distance + numerator;
    let coefficient = if denominator > f32::EPSILON {
        (numerator / denominator).clamp(0.0, 1.0)
    } else if speed >= high_speed.velocity_begin {
        1.0
    } else {
        0.0
    };

    let low_weighted_duration = (1.0 - coefficient) * low_speed.duration;
    let high_weighted_duration = coefficient * high_speed.duration;
    let duration = low_weighted_duration + high_weighted_duration;
    let velocity_end = if duration > f32::EPSILON {
        (low_weighted_duration * low_speed.velocity_end
            + high_weighted_duration * high_speed.velocity_end)
            / duration
    } else {
        low_speed.velocity_end
    };

    RowSolution {
        coefficient,
        duration,
        velocity_end,
    }
}

pub fn compute_target_coefficients(
    attributes: PushAttributes,
    physical_speed: f32,
    push_delta_velocity: f32,
) -> PushTreeCoefficients {
    let high_strength = solve_row(
        physical_speed,
        attributes.low_speed_high_strength,
        attributes.high_speed_high_strength,
    );
    let low_strength = solve_row(
        physical_speed,
        attributes.low_speed_low_strength,
        attributes.high_speed_low_strength,
    );

    let requested_end_velocity = (physical_speed + push_delta_velocity).clamp(
        low_strength.velocity_end.min(high_strength.velocity_end),
        low_strength.velocity_end.max(high_strength.velocity_end),
    );

    // Outer rational interpolation at 0x82BAD56C..0x82BAD5A4.
    let low_numerator =
        low_strength.duration * (requested_end_velocity - low_strength.velocity_end);
    let denominator = high_strength.duration
        * (high_strength.velocity_end - requested_end_velocity)
        + low_numerator;
    let velocity_end = if denominator > f32::EPSILON {
        (low_numerator / denominator).clamp(0.0, 1.0)
    } else if requested_end_velocity >= high_strength.velocity_end {
        1.0
    } else {
        0.0
    };

    PushTreeCoefficients {
        high_strength_velocity_begin: high_strength.coefficient,
        low_strength_velocity_begin: low_strength.coefficient,
        velocity_end,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reconstruct_row(
        low: PushAttributePoint,
        high: PushAttributePoint,
        coefficient: f32,
        field: impl Fn(PushAttributePoint) -> f32,
    ) -> f32 {
        let low_weight = (1.0 - coefficient) * low.duration;
        let high_weight = coefficient * high.duration;
        (low_weight * field(low) + high_weight * field(high)) / (low_weight + high_weight)
    }

    #[test]
    fn zero_speed_hard_push_is_the_long_lsp_hstr_leaf() {
        let coefficients = compute_target_coefficients(REGULAR_PUSH_ATTRIBUTES, 0.0, 4.5);
        assert_eq!(
            coefficients,
            PushTreeCoefficients {
                high_strength_velocity_begin: 0.0,
                low_strength_velocity_begin: 0.0,
                velocity_end: 1.0,
            }
        );
        assert_eq!(coefficients.leaf_weights(), [1.0, 0.0, 0.0, 0.0]);
    }

    #[test]
    fn zero_speed_low_push_is_the_lsp_lstr_leaf() {
        let coefficients = compute_target_coefficients(REGULAR_PUSH_ATTRIBUTES, 0.0, 1.0);
        assert_eq!(coefficients.leaf_weights(), [0.0, 0.0, 1.0, 0.0]);
    }

    #[test]
    fn recovered_solver_reconstructs_requested_speed_and_end_velocity() {
        let physical_speed = 4.25;
        let push_delta = 2.25;
        let coefficients =
            compute_target_coefficients(REGULAR_PUSH_ATTRIBUTES, physical_speed, push_delta);

        let high_begin = reconstruct_row(
            REGULAR_PUSH_ATTRIBUTES.low_speed_high_strength,
            REGULAR_PUSH_ATTRIBUTES.high_speed_high_strength,
            coefficients.high_strength_velocity_begin,
            |point| point.velocity_begin,
        );
        let low_begin = reconstruct_row(
            REGULAR_PUSH_ATTRIBUTES.low_speed_low_strength,
            REGULAR_PUSH_ATTRIBUTES.high_speed_low_strength,
            coefficients.low_strength_velocity_begin,
            |point| point.velocity_begin,
        );
        assert!((high_begin - physical_speed).abs() < 1.0e-5);
        assert!((low_begin - physical_speed).abs() < 1.0e-5);

        let high_end = reconstruct_row(
            REGULAR_PUSH_ATTRIBUTES.low_speed_high_strength,
            REGULAR_PUSH_ATTRIBUTES.high_speed_high_strength,
            coefficients.high_strength_velocity_begin,
            |point| point.velocity_end,
        );
        let low_end = reconstruct_row(
            REGULAR_PUSH_ATTRIBUTES.low_speed_low_strength,
            REGULAR_PUSH_ATTRIBUTES.high_speed_low_strength,
            coefficients.low_strength_velocity_begin,
            |point| point.velocity_end,
        );
        let high_duration = solve_row(
            physical_speed,
            REGULAR_PUSH_ATTRIBUTES.low_speed_high_strength,
            REGULAR_PUSH_ATTRIBUTES.high_speed_high_strength,
        )
        .duration;
        let low_duration = solve_row(
            physical_speed,
            REGULAR_PUSH_ATTRIBUTES.low_speed_low_strength,
            REGULAR_PUSH_ATTRIBUTES.high_speed_low_strength,
        )
        .duration;
        let high_weight = coefficients.velocity_end * high_duration;
        let low_weight = (1.0 - coefficients.velocity_end) * low_duration;
        let reconstructed_end =
            (high_weight * high_end + low_weight * low_end) / (high_weight + low_weight);
        assert!((reconstructed_end - (physical_speed + push_delta)).abs() < 1.0e-5);
        assert!((coefficients.leaf_weights().iter().sum::<f32>() - 1.0).abs() < f32::EPSILON);
    }
}
