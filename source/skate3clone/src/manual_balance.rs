//! Deterministic Skate 3 TU3 manual-balance conditioning.
//!
//! This module is intentionally independent of the simulation and state graph.
//! The retail configuration is available explicitly through
//! [`ManualBalanceConfig::tu3_retail`]; callers that supply data dynamically
//! must validate it and cannot silently fall back to a guessed curve.
#![allow(dead_code)] // Public evidence boundaries are activated incrementally.

use core::fmt;

/// The ManualBrake threshold loaded by the intent producer at `0x8259BA50`.
pub const TU3_MANUAL_BRAKE_THRESHOLD: f32 = f32::from_bits(0x3F66_6666);

/// The ManualBrake gain loaded by the intent producer at `0x8259BA60`.
pub const TU3_MANUAL_BRAKE_GAIN: f32 = f32::from_bits(0x411F_FFFE);

/// Duration explicitly configured by `SetManualOutTimer` in `ground.xml`.
pub const TU3_MANUAL_OUT_TIMER_SECONDS: f32 = f32::from_bits(0x3DCC_CCCD);

/// Retail `manual_clamp_vel`, applied once per SetManualAngle update.
pub const TU3_MANUAL_CLAMP_VELOCITY: f32 = f32::from_bits(0x3D23_D70A);

/// Retail `manual_clamp_acc`, applied once per SetManualAngle update.
pub const TU3_MANUAL_CLAMP_ACCELERATION: f32 = f32::from_bits(0x3CA3_D70A);

/// One point in a PointGraphEval-compatible graph.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CurvePoint {
    pub input: f32,
    pub output: f32,
}

impl CurvePoint {
    pub const fn from_bits(input: u32, output: u32) -> Self {
        Self {
            input: f32::from_bits(input),
            output: f32::from_bits(output),
        }
    }
}

/// The eight `manual_balance` points extracted from TU3's retail
/// `anim_motion/manual` VLT collection.
pub const TU3_MANUAL_BALANCE_POINTS: [CurvePoint; 8] = [
    CurvePoint::from_bits(0x0000_0000, 0x0000_0000),
    CurvePoint::from_bits(0x3E00_0000, 0x0000_0000),
    CurvePoint::from_bits(0x3E80_0000, 0x0000_0000),
    CurvePoint::from_bits(0x3EC0_0000, 0x0000_0000),
    CurvePoint::from_bits(0x3F00_0000, 0x0000_0000),
    CurvePoint::from_bits(0x3F20_0000, 0x0000_0000),
    CurvePoint::from_bits(0x3F4E_0ADF, 0x0000_0000),
    CurvePoint::from_bits(0x3F80_0000, 0x3F80_0000),
];

/// Unvalidated conditioner data.
///
/// Optional fields make missing live/VLT data explicit. Validation rejects
/// every missing field instead of substituting a balance curve or coefficient.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ManualBalanceConfig<'a> {
    pub curve: Option<&'a [CurvePoint]>,
    pub max_velocity_per_update: Option<f32>,
    pub max_acceleration_per_update: Option<f32>,
}

impl<'a> ManualBalanceConfig<'a> {
    /// A deliberately incomplete configuration for telemetry-driven callers.
    pub const fn absent() -> Self {
        Self {
            curve: None,
            max_velocity_per_update: None,
            max_acceleration_per_update: None,
        }
    }

    /// The exact retail TU3 VLT configuration recovered for `anim_motion/manual`.
    pub const fn tu3_retail() -> Self {
        Self {
            curve: Some(&TU3_MANUAL_BALANCE_POINTS),
            max_velocity_per_update: Some(TU3_MANUAL_CLAMP_VELOCITY),
            max_acceleration_per_update: Some(TU3_MANUAL_CLAMP_ACCELERATION),
        }
    }

    pub fn validate(self) -> Result<ValidatedManualBalanceConfig<'a>, ConfigError> {
        let curve = self.curve.ok_or(ConfigError::MissingCurve)?;
        if curve.is_empty() {
            return Err(ConfigError::EmptyCurve);
        }

        for (index, point) in curve.iter().enumerate() {
            if !point.input.is_finite() {
                return Err(ConfigError::NonFiniteCurveInput { index });
            }
            if !point.output.is_finite() {
                return Err(ConfigError::NonFiniteCurveOutput { index });
            }
            if index > 0 && point.input <= curve[index - 1].input {
                return Err(ConfigError::NonIncreasingCurveInput { index });
            }
        }

        let max_velocity_per_update = self
            .max_velocity_per_update
            .ok_or(ConfigError::MissingVelocityClamp)?;
        validate_limit(max_velocity_per_update, LimitKind::Velocity)?;

        let max_acceleration_per_update = self
            .max_acceleration_per_update
            .ok_or(ConfigError::MissingAccelerationClamp)?;
        validate_limit(max_acceleration_per_update, LimitKind::Acceleration)?;

        Ok(ValidatedManualBalanceConfig {
            curve,
            max_velocity_per_update,
            max_acceleration_per_update,
        })
    }
}

fn validate_limit(value: f32, kind: LimitKind) -> Result<(), ConfigError> {
    if !value.is_finite() {
        return Err(ConfigError::NonFiniteLimit { kind });
    }
    if value < 0.0 {
        return Err(ConfigError::NegativeLimit { kind });
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LimitKind {
    Velocity,
    Acceleration,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConfigError {
    MissingCurve,
    EmptyCurve,
    NonFiniteCurveInput { index: usize },
    NonFiniteCurveOutput { index: usize },
    NonIncreasingCurveInput { index: usize },
    MissingVelocityClamp,
    MissingAccelerationClamp,
    NonFiniteLimit { kind: LimitKind },
    NegativeLimit { kind: LimitKind },
}

impl fmt::Display for ConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Self::MissingCurve => formatter.write_str("manual-balance curve is absent"),
            Self::EmptyCurve => formatter.write_str("manual-balance curve is empty"),
            Self::NonFiniteCurveInput { index } => {
                write!(formatter, "curve input at index {index} is not finite")
            }
            Self::NonFiniteCurveOutput { index } => {
                write!(formatter, "curve output at index {index} is not finite")
            }
            Self::NonIncreasingCurveInput { index } => {
                write!(
                    formatter,
                    "curve input at index {index} is not strictly increasing"
                )
            }
            Self::MissingVelocityClamp => formatter.write_str("manual velocity clamp is absent"),
            Self::MissingAccelerationClamp => {
                formatter.write_str("manual acceleration clamp is absent")
            }
            Self::NonFiniteLimit { kind } => write!(formatter, "{kind:?} limit is not finite"),
            Self::NegativeLimit { kind } => write!(formatter, "{kind:?} limit is negative"),
        }
    }
}

impl std::error::Error for ConfigError {}

/// Configuration whose completeness and numeric invariants have been checked.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ValidatedManualBalanceConfig<'a> {
    curve: &'a [CurvePoint],
    max_velocity_per_update: f32,
    max_acceleration_per_update: f32,
}

impl<'a> ValidatedManualBalanceConfig<'a> {
    pub fn curve(&self) -> &'a [CurvePoint] {
        self.curve
    }

    pub fn max_velocity_per_update(&self) -> f32 {
        self.max_velocity_per_update
    }

    pub fn max_acceleration_per_update(&self) -> f32 {
        self.max_acceleration_per_update
    }

    /// Evaluate with the exact control flow recovered at `0x82481E10`:
    /// clamp to endpoint outputs and linearly interpolate between points.
    pub fn evaluate_curve(&self, input: f32) -> Result<f32, InputError> {
        if !input.is_finite() {
            return Err(InputError::NonFiniteManualIntent);
        }
        Ok(evaluate_validated_curve(self.curve, input))
    }
}

fn evaluate_validated_curve(points: &[CurvePoint], input: f32) -> f32 {
    if input < points[0].input {
        return points[0].output;
    }

    let last = points.len() - 1;
    if input >= points[last].input {
        return points[last].output;
    }

    if points.len() == 1 {
        return points[0].output;
    }

    for upper_index in 1..points.len() {
        let upper = points[upper_index];
        if input < upper.input {
            let lower = points[upper_index - 1];
            let slope = (upper.output - lower.output) / (upper.input - lower.input);
            return slope * (input - lower.input) + lower.output;
        }
    }

    // The endpoint checks and validated ordering make this unreachable.
    points[last].output
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InputError {
    NonFiniteManualIntent,
    NonFiniteConditionedMagnitude,
    NonFiniteSignedAxis,
}

impl fmt::Display for InputError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NonFiniteManualIntent => formatter.write_str("manual intent is not finite"),
            Self::NonFiniteConditionedMagnitude => {
                formatter.write_str("conditioned input magnitude is not finite")
            }
            Self::NonFiniteSignedAxis => formatter.write_str("signed input axis is not finite"),
        }
    }
}

impl std::error::Error for InputError {}

/// Persistent state stored at SetManualAngle instance offsets `+8` and `+12`.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ManualBalanceConditioner {
    angle: f32,
    velocity: f32,
}

/// Values produced by one deterministic retail update.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ManualBalanceStep {
    pub signed_target: f32,
    pub angle: f32,
    pub velocity: f32,
}

impl ManualBalanceConditioner {
    pub const fn new() -> Self {
        Self {
            angle: 0.0,
            velocity: 0.0,
        }
    }

    pub fn angle(&self) -> f32 {
        self.angle
    }

    pub fn velocity(&self) -> f32 {
        self.velocity
    }

    /// Mirrors SetManualAngle::Begin at `0x82BA8C48`.
    pub fn reset(&mut self) {
        self.angle = 0.0;
        self.velocity = 0.0;
    }

    /// Mirrors one SetManualAngle::Update at `0x82BA8C60`.
    ///
    /// TU3 does not multiply these limits by delta time. An absent Manual
    /// intent is represented by `0.0`, matching the value consumed by the
    /// retail behaviour.
    pub fn update(
        &mut self,
        manual_intent: f32,
        config: &ValidatedManualBalanceConfig<'_>,
    ) -> Result<ManualBalanceStep, InputError> {
        if !manual_intent.is_finite() {
            return Err(InputError::NonFiniteManualIntent);
        }

        let unsigned_target = evaluate_validated_curve(config.curve, manual_intent.abs());
        // PPC `fsel` selects the positive graph result for both +0.0 and -0.0.
        let signed_target = if manual_intent >= 0.0 {
            unsigned_target
        } else {
            -unsigned_target
        };

        let desired_velocity = (signed_target - self.angle).clamp(
            -config.max_velocity_per_update,
            config.max_velocity_per_update,
        );
        let acceleration = (desired_velocity - self.velocity).clamp(
            -config.max_acceleration_per_update,
            config.max_acceleration_per_update,
        );

        self.velocity += acceleration;
        self.angle += self.velocity;

        Ok(ManualBalanceStep {
            signed_target,
            angle: self.angle,
            velocity: self.velocity,
        })
    }
}

/// Action-graph intents emitted by the producer at `0x8259BA28`.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ManualIntentSample {
    pub manual: Option<f32>,
    pub manual_brake: Option<f32>,
}

/// Reproduce the relevant Manual/ManualBrake portion of
/// `ActionGraphInputListener::Fill`.
///
/// `suppression_bit_9` is the integer bit tested by the PPC
/// `extrwi ..., 1, 22` instructions. The caller is responsible for producing
/// the same conditioned magnitude and signed axis supplied to TU3.
pub fn produce_manual_intents(
    signed_axis: f32,
    conditioned_magnitude: f32,
    suppression_bit_9: bool,
) -> Result<ManualIntentSample, InputError> {
    if !signed_axis.is_finite() {
        return Err(InputError::NonFiniteSignedAxis);
    }
    if !conditioned_magnitude.is_finite() {
        return Err(InputError::NonFiniteConditionedMagnitude);
    }
    if suppression_bit_9 {
        return Ok(ManualIntentSample::default());
    }

    let manual = if signed_axis > 0.0 {
        Some(conditioned_magnitude)
    } else if signed_axis < 0.0 {
        Some(-conditioned_magnitude)
    } else {
        None
    };

    let manual_brake = if conditioned_magnitude > TU3_MANUAL_BRAKE_THRESHOLD {
        let unsigned_brake =
            (conditioned_magnitude - TU3_MANUAL_BRAKE_THRESHOLD) * TU3_MANUAL_BRAKE_GAIN;
        Some(if signed_axis > 0.0 {
            unsigned_brake
        } else {
            -unsigned_brake
        })
    } else {
        None
    };

    Ok(ManualIntentSample {
        manual,
        manual_brake,
    })
}

/// `PowerSlideManualAtt::Update` publishes balance only for a present,
/// strictly negative Manual intent.
pub fn powerslide_manual_balance(manual_intent: Option<f32>) -> Option<f32> {
    manual_intent.filter(|value| *value < 0.0)
}

/// Exact `RegisteredManualOutTimerIsActive` condition at `0x82BA78B0`.
pub fn manual_out_timer_is_active(remaining: f32) -> bool {
    remaining > 0.0
}

/// Inputs consumed by the state graph but owned by the physics/timer provider.
///
/// TU3's `PhysicsWantsManualExit` condition reads a boolean from its provider;
/// the writer and physical causes are intentionally not guessed here.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ManualExitInputs {
    pub physics_wants_manual_exit: bool,
    pub manual_out_timer_remaining: f32,
}

impl ManualExitInputs {
    pub fn manual_out_timer_is_active(self) -> bool {
        manual_out_timer_is_active(self.manual_out_timer_remaining)
    }

    /// NoseManual.xml's exact Out-state expression.
    pub fn nose_manual_wants_out(self, manual_intent: Option<f32>) -> bool {
        self.physics_wants_manual_exit || !manual_intent.is_some_and(|value| value > 0.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn retail_config() -> ValidatedManualBalanceConfig<'static> {
        ManualBalanceConfig::tu3_retail().validate().unwrap()
    }

    fn assert_bits_eq(actual: f32, expected: f32) {
        assert_eq!(
            actual.to_bits(),
            expected.to_bits(),
            "actual={actual:?}, expected={expected:?}"
        );
    }

    #[test]
    fn configuration_must_be_present_and_well_formed() {
        assert_eq!(
            ManualBalanceConfig::absent().validate(),
            Err(ConfigError::MissingCurve)
        );

        let empty = ManualBalanceConfig {
            curve: Some(&[]),
            max_velocity_per_update: Some(0.04),
            max_acceleration_per_update: Some(0.02),
        };
        assert_eq!(empty.validate(), Err(ConfigError::EmptyCurve));

        let points = [
            CurvePoint {
                input: 0.0,
                output: 0.0,
            },
            CurvePoint {
                input: 0.0,
                output: 1.0,
            },
        ];
        let unordered = ManualBalanceConfig {
            curve: Some(&points),
            max_velocity_per_update: Some(0.04),
            max_acceleration_per_update: Some(0.02),
        };
        assert_eq!(
            unordered.validate(),
            Err(ConfigError::NonIncreasingCurveInput { index: 1 })
        );

        let missing_velocity = ManualBalanceConfig {
            curve: Some(&TU3_MANUAL_BALANCE_POINTS),
            max_velocity_per_update: None,
            max_acceleration_per_update: Some(0.02),
        };
        assert_eq!(
            missing_velocity.validate(),
            Err(ConfigError::MissingVelocityClamp)
        );
    }

    #[test]
    fn configured_curve_clamps_endpoints_and_interpolates() {
        let points = [
            CurvePoint {
                input: 1.0,
                output: 10.0,
            },
            CurvePoint {
                input: 3.0,
                output: 20.0,
            },
            CurvePoint {
                input: 5.0,
                output: 16.0,
            },
        ];
        let config = ManualBalanceConfig {
            curve: Some(&points),
            max_velocity_per_update: Some(1.0),
            max_acceleration_per_update: Some(1.0),
        }
        .validate()
        .unwrap();

        assert_bits_eq(config.evaluate_curve(0.0).unwrap(), 10.0);
        assert_bits_eq(config.evaluate_curve(1.0).unwrap(), 10.0);
        assert_bits_eq(config.evaluate_curve(2.0).unwrap(), 15.0);
        assert_bits_eq(config.evaluate_curve(4.0).unwrap(), 18.0);
        assert_bits_eq(config.evaluate_curve(5.0).unwrap(), 16.0);
        assert_bits_eq(config.evaluate_curve(9.0).unwrap(), 16.0);
    }

    #[test]
    fn retail_curve_preserves_exact_dead_zone_and_endpoint() {
        let config = retail_config();
        let final_zero = f32::from_bits(0x3F4E_0ADF);
        let next = f32::from_bits(final_zero.to_bits() + 1);

        assert_bits_eq(config.evaluate_curve(final_zero).unwrap(), 0.0);
        assert!(config.evaluate_curve(next).unwrap() > 0.0);
        assert_bits_eq(config.evaluate_curve(1.0).unwrap(), 1.0);
        assert_bits_eq(config.evaluate_curve(2.0).unwrap(), 1.0);
    }

    #[test]
    fn conditioner_applies_velocity_then_acceleration_clamps_per_update() {
        let config = retail_config();
        let mut conditioner = ManualBalanceConditioner::new();

        let first = conditioner.update(1.0, &config).unwrap();
        assert_bits_eq(first.signed_target, 1.0);
        assert_bits_eq(first.velocity, TU3_MANUAL_CLAMP_ACCELERATION);
        assert_bits_eq(first.angle, TU3_MANUAL_CLAMP_ACCELERATION);

        let second = conditioner.update(1.0, &config).unwrap();
        assert_bits_eq(second.velocity, TU3_MANUAL_CLAMP_VELOCITY);
        assert_bits_eq(
            second.angle,
            TU3_MANUAL_CLAMP_ACCELERATION + TU3_MANUAL_CLAMP_VELOCITY,
        );

        let reverse = conditioner.update(-1.0, &config).unwrap();
        assert_bits_eq(reverse.signed_target, -1.0);
        assert_bits_eq(
            reverse.velocity,
            TU3_MANUAL_CLAMP_VELOCITY - TU3_MANUAL_CLAMP_ACCELERATION,
        );
    }

    #[test]
    fn begin_reset_zeros_both_persistent_fields() {
        let config = retail_config();
        let mut conditioner = ManualBalanceConditioner::new();
        conditioner.update(1.0, &config).unwrap();
        conditioner.update(1.0, &config).unwrap();

        conditioner.reset();

        assert_bits_eq(conditioner.angle(), 0.0);
        assert_bits_eq(conditioner.velocity(), 0.0);
        assert_eq!(conditioner, ManualBalanceConditioner::new());
    }

    #[test]
    fn update_partitioning_is_deterministic() {
        let config = retail_config();
        let inputs = [1.0, 1.0, 0.9, -1.0, -1.0, 0.0, 0.75, 1.0];
        let mut contiguous = ManualBalanceConditioner::new();
        for input in inputs {
            contiguous.update(input, &config).unwrap();
        }

        let mut partitioned = ManualBalanceConditioner::new();
        for chunk in inputs.chunks(3) {
            for &input in chunk {
                partitioned.update(input, &config).unwrap();
            }
        }

        assert_eq!(contiguous.angle().to_bits(), partitioned.angle().to_bits());
        assert_eq!(
            contiguous.velocity().to_bits(),
            partitioned.velocity().to_bits()
        );
    }

    #[test]
    fn intent_producer_uses_exact_threshold_sign_and_suppression_gate() {
        let at_threshold = produce_manual_intents(1.0, TU3_MANUAL_BRAKE_THRESHOLD, false).unwrap();
        assert_eq!(at_threshold.manual, Some(TU3_MANUAL_BRAKE_THRESHOLD));
        assert_eq!(at_threshold.manual_brake, None);

        let above = f32::from_bits(TU3_MANUAL_BRAKE_THRESHOLD.to_bits() + 1);
        let nose = produce_manual_intents(1.0, above, false).unwrap();
        let tail = produce_manual_intents(-1.0, above, false).unwrap();
        assert!(nose.manual_brake.unwrap() > 0.0);
        assert!(tail.manual_brake.unwrap() < 0.0);
        assert_eq!(nose.manual, Some(above));
        assert_eq!(tail.manual, Some(-above));

        let suppressed = produce_manual_intents(-1.0, 1.0, true).unwrap();
        assert_eq!(suppressed, ManualIntentSample::default());
    }

    #[test]
    fn powerslide_and_exit_gates_are_strict() {
        assert_eq!(
            powerslide_manual_balance(Some(-f32::EPSILON)),
            Some(-f32::EPSILON)
        );
        assert_eq!(powerslide_manual_balance(Some(-0.0)), None);
        assert_eq!(powerslide_manual_balance(Some(0.0)), None);
        assert_eq!(powerslide_manual_balance(Some(1.0)), None);
        assert_eq!(powerslide_manual_balance(None), None);

        assert!(!manual_out_timer_is_active(-f32::EPSILON));
        assert!(!manual_out_timer_is_active(-0.0));
        assert!(!manual_out_timer_is_active(0.0));
        assert!(manual_out_timer_is_active(f32::EPSILON));

        let no_physics_exit = ManualExitInputs::default();
        assert!(!no_physics_exit.nose_manual_wants_out(Some(f32::EPSILON)));
        assert!(no_physics_exit.nose_manual_wants_out(Some(0.0)));
        assert!(no_physics_exit.nose_manual_wants_out(None));

        let physics_exit = ManualExitInputs {
            physics_wants_manual_exit: true,
            manual_out_timer_remaining: 0.0,
        };
        assert!(physics_exit.nose_manual_wants_out(Some(1.0)));
    }
}
