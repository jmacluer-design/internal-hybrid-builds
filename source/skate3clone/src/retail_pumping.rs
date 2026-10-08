//! Evidence-only scalar port of Skate 3 TU3 pumping.
//!
//! Observed:
//! - `Pumping::Reset` is `0x82D8F1A0`.
//! - `Pumping::Update` is `0x82D8F228..0x82D8F46F`.
//! - The scalar producer is `0x82D8F470..0x82D8F7D7`.
//! - The force builder is `0x82D933D0..0x82D93517`.
//! - Graph words and scalar defaults are the decoded
//!   `physics_pumping/default` and `physics_mode/default` payloads.
//!
//! Derived:
//! - Prepared input `+96` is the `At` lane and `+112` is the `Pos` lane of
//!   the copied skateboard/deck-part `Matrix44Affine`.
//!
//! Unresolved:
//! - Fields named `state20_plus_*` and `state8_plus_*` retain their literal
//!   caller provenance. They are not assigned COM, animation, skeleton, or
//!   other semantic names here.
//! - Prepared scalar `+2612` retains its literal name. Its sign and zero
//!   behavior are part of force-direction construction.
//! - Retail bytes untouched by Reset remain explicit and are preserved.
//!
//! Floating-point policy:
//! - Scalar operations are kept in recovered f32 order and PPC `fmadds`
//!   sites use `f32::mul_add`.
//! - The recovered VMX reciprocal-square-root estimate table is reproduced.
//! - `acos` uses the Rust scalar-host implementation because no retail PPC
//!   execution oracle is run by this module. Tests that retain full pipeline
//!   output words therefore label those words as scalar-host results.

pub type RetailVector4 = [f32; 4];

pub const SCALAR_HOST_ROUNDING_NOTE: &str =
    "Expected pipeline bits use the Rust scalar host; no retail PPC oracle was executed.";

pub const RETAIL_VECTOR_LENGTH_EPSILON_SQUARED_WORD: u32 = 0x38D1_B717;
pub const RETAIL_TAU_WORD: u32 = 0x40C9_0FDB;
pub const RETAIL_INVERSE_TAU_WORD: u32 = 0x3E22_F983;
pub const RETAIL_PI_OVER_TWO_WORD: u32 = 0x3FC9_0FDB;
pub const RETAIL_TWO_OVER_PI_WORD: u32 = 0x3F22_F983;
pub const CALLER_VARIANT_1_DT_WORD: u32 = 0x3C88_8889;

pub const RETAIL_PUMP_VS_VELOCITY_WORDS: [u32; 20] = [
    0x0000_0000,
    0x0000_0000,
    0x4180_0000,
    0x4080_0000,
    0x0000_0000,
    0x401C_C4CA,
    0x4091_EDA8,
    0x40E0_500D,
    0x410C_ECD2,
    0x412A_F1D4,
    0x4143_2086,
    0x4163_3B30,
    0x4080_0000,
    0x401C_57C5,
    0x3F8C_CCCD,
    0x3F80_0000,
    0x3F76_DB6D,
    0x3F12_4925,
    0x3E20_EA12,
    0x3BEA_0EA1,
];

pub const RETAIL_PUMP_VS_TIME_WORDS: [u32; 20] = [
    0x0000_0000,
    0x0000_0000,
    0x3F80_0000,
    0x3F80_0000,
    0x0000_0000,
    0x3ECD_F7A8,
    0x3F01_AAF3,
    0x3F12_5863,
    0x3F27_3133,
    0x3F3D_B4F3,
    0x3F5C_8F6D,
    0x3F7E_BFCB,
    0x3F80_0000,
    0x3F80_0000,
    0x3F65_7C58,
    0x3F3B_6DB8,
    0x3EDD_41D6,
    0x3E7C_57C7,
    0x3DEA_0E9F,
    0x3DC5_7C58,
];

pub const RETAIL_MIN_CROUCH_WORDS: [u32; 16] = [
    0x0000_0000,
    0x3DB7_73E9,
    0x3E25_1B86,
    0x3EAE_47B7,
    0x3EEB_FCA8,
    0x3F1B_8497,
    0x3F4A_A1C7,
    0x3F80_0000,
    0x0000_0000,
    0x0000_0000,
    0x3CF9_14BF,
    0x3EBA_CF92,
    0x3F09_8376,
    0x3F2A_60DE,
    0x3F40_0000,
    0x3F4B_3E45,
];

pub const RETAIL_COMPRESSION_GROUND_WORDS: [u32; 16] = [
    0x0000_0000,
    0x3D92_C321,
    0x3E16_1904,
    0x3E73_7DE9,
    0x3EC3_2086,
    0x3F4B_0C82,
    0x3F70_2808,
    0x3F80_0000,
    0x0000_0000,
    0x3D33_E451,
    0x3E48_A60B,
    0x3EA4_5305,
    0x3EBE_4530,
    0x3EF5_9F22,
    0x3F41_BAD0,
    0x3F80_0000,
];

pub const RETAIL_COMPRESSION_DECK_WORDS: [u32; 16] = [
    0x0000_0000,
    0x3D79_525C,
    0x3DE5_4973,
    0x3E26_F4E0,
    0x3E74_DE99,
    0x3EA0_1AB0,
    0x3EBD_C620,
    0x3F07_3C1B,
    0x0000_0000,
    0x3E81_BAD0,
    0x3ED6_7C8A,
    0x3F19_F22A,
    0x3F44_5307,
    0x3F60_DD68,
    0x3F6D_D67C,
    0x3F80_0000,
];

/// Ordered by retail offsets `+356..+392`.
pub const RETAIL_PHYSICS_PUMPING_SCALAR_WORDS: [u32; 10] = [
    0x3F80_0000, // +356 RadiusDamping; not consumed by this path
    0x3C23_D70A, // +360 PumpMinFactor; not consumed by this path
    0x3DCC_CCCD, // +364 PumpEffectDamping
    0x4248_0000, // +368 PumpAngle; not consumed by this path
    0x3B83_126F, // +372 MinChangeInCOMBeforePumping
    0x3BC4_9BA6, // +376 MaxChangeInCOMBeforePumping
    0xC100_0000, // +380 CompressionGround
    0xC100_0000, // +384 CompressionDeck
    0x3F38_51EC, // +388 AverageHeightOfCOM; not consumed by this path
    0x3E4C_CCCD, // +392 AngularDamping
];

/// Ordered by retail `physics_mode` offsets `+8,+12,+16,+20,+24`.
pub const RETAIL_PHYSICS_MODE_WORDS: [u32; 5] = [
    0x3F33_3333, // +8 UnintentionalPumpScalar
    0x0000_0000, // +12 lower-rate operand
    0x4120_0000, // +16 upper-rate operand
    0x3F80_0000, // +20 absorption operand
    0x4190_0000, // +24 pumping factor
];

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EvalGraph8 {
    pub x: [f32; 8],
    pub y: [f32; 8],
}

const fn graph_from_words<const WORDS: usize>(words: [u32; WORDS], x_start: usize) -> EvalGraph8 {
    let mut x = [0.0; 8];
    let mut y = [0.0; 8];
    let mut index = 0;
    while index < 8 {
        x[index] = f32::from_bits(words[x_start + index]);
        y[index] = f32::from_bits(words[x_start + 8 + index]);
        index += 1;
    }
    EvalGraph8 { x, y }
}

/// Exact `0x82481E10` eight-point evaluator.
pub fn eval8(graph: &EvalGraph8, input: f32) -> f32 {
    if input < graph.x[0] {
        return graph.y[0];
    }
    if input >= graph.x[7] {
        return graph.y[7];
    }

    let mut upper = 1;
    while upper < 8 {
        if input < graph.x[upper] {
            let lower = upper - 1;
            let span = graph.x[upper] - graph.x[lower];
            if span <= 0.0 {
                return graph.y[upper];
            }
            let rise = graph.y[upper] - graph.y[lower];
            let slope = rise / span;
            let delta = input - graph.x[lower];
            return slope.mul_add(delta, graph.y[lower]);
        }
        upper += 1;
    }

    // Unordered input (NaN) reaches this retail endpoint.
    graph.y[7]
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailPumpingOperands {
    pub pump_vs_velocity: EvalGraph8,
    pub pump_vs_time: EvalGraph8,
    pub min_crouch: EvalGraph8,
    pub compression_ground_graph: EvalGraph8,
    pub compression_deck_graph: EvalGraph8,
    pub radius_damping_unused: f32,
    pub pump_min_factor_unused: f32,
    pub pump_effect_damping: f32,
    pub pump_angle_unused: f32,
    pub min_change_before_pumping: f32,
    pub max_change_before_pumping: f32,
    pub compression_ground: f32,
    pub compression_deck: f32,
    pub average_height_unused: f32,
    pub angular_damping: f32,
}

impl RetailPumpingOperands {
    pub const fn retail_default() -> Self {
        Self {
            pump_vs_velocity: graph_from_words(RETAIL_PUMP_VS_VELOCITY_WORDS, 4),
            pump_vs_time: graph_from_words(RETAIL_PUMP_VS_TIME_WORDS, 4),
            min_crouch: graph_from_words(RETAIL_MIN_CROUCH_WORDS, 0),
            compression_ground_graph: graph_from_words(RETAIL_COMPRESSION_GROUND_WORDS, 0),
            compression_deck_graph: graph_from_words(RETAIL_COMPRESSION_DECK_WORDS, 0),
            radius_damping_unused: f32::from_bits(RETAIL_PHYSICS_PUMPING_SCALAR_WORDS[0]),
            pump_min_factor_unused: f32::from_bits(RETAIL_PHYSICS_PUMPING_SCALAR_WORDS[1]),
            pump_effect_damping: f32::from_bits(RETAIL_PHYSICS_PUMPING_SCALAR_WORDS[2]),
            pump_angle_unused: f32::from_bits(RETAIL_PHYSICS_PUMPING_SCALAR_WORDS[3]),
            min_change_before_pumping: f32::from_bits(RETAIL_PHYSICS_PUMPING_SCALAR_WORDS[4]),
            max_change_before_pumping: f32::from_bits(RETAIL_PHYSICS_PUMPING_SCALAR_WORDS[5]),
            compression_ground: f32::from_bits(RETAIL_PHYSICS_PUMPING_SCALAR_WORDS[6]),
            compression_deck: f32::from_bits(RETAIL_PHYSICS_PUMPING_SCALAR_WORDS[7]),
            average_height_unused: f32::from_bits(RETAIL_PHYSICS_PUMPING_SCALAR_WORDS[8]),
            angular_damping: f32::from_bits(RETAIL_PHYSICS_PUMPING_SCALAR_WORDS[9]),
        }
    }
}

pub const RETAIL_PUMPING_OPERANDS: RetailPumpingOperands = RetailPumpingOperands::retail_default();

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailPhysicsModeOperands {
    pub unintentional_pump_scalar: f32,
    pub lower_rate: f32,
    pub upper_rate: f32,
    pub absorption: f32,
    pub factor: f32,
}

impl RetailPhysicsModeOperands {
    pub const fn retail_default() -> Self {
        Self {
            unintentional_pump_scalar: f32::from_bits(RETAIL_PHYSICS_MODE_WORDS[0]),
            lower_rate: f32::from_bits(RETAIL_PHYSICS_MODE_WORDS[1]),
            upper_rate: f32::from_bits(RETAIL_PHYSICS_MODE_WORDS[2]),
            absorption: f32::from_bits(RETAIL_PHYSICS_MODE_WORDS[3]),
            factor: f32::from_bits(RETAIL_PHYSICS_MODE_WORDS[4]),
        }
    }
}

pub const RETAIL_PHYSICS_MODE: RetailPhysicsModeOperands =
    RetailPhysicsModeOperands::retail_default();

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PumpingUpdateInput {
    pub a: RetailVector4,
    pub b: RetailVector4,
    pub c: RetailVector4,
    pub alpha: f32,
    pub dt: f32,
    pub state_byte: u8,
}

/// Literal inputs at the `0x82D37EA8` caller.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CallerVariant1Input {
    pub prepared_plus_96: RetailVector4,
    pub prepared_plus_112: RetailVector4,
    pub state20_plus_752: RetailVector4,
    pub state20_plus_1152: RetailVector4,
    pub state20_plus_1216: RetailVector4,
    pub state8_plus_11008: RetailVector4,
    pub state8_plus_15984: RetailVector4,
    pub prepared_plus_2476_flags: u32,
}

impl CallerVariant1Input {
    pub fn update_input(self) -> PumpingUpdateInput {
        let lhs = abs_bits(ppc_dot3(self.prepared_plus_96, self.state20_plus_1152));
        let rhs = abs_bits(ppc_dot3(self.state8_plus_15984, self.state20_plus_1152));
        let alpha = if lhs > rhs {
            let first = oriented_angle(
                self.prepared_plus_96,
                self.state20_plus_1152,
                self.state20_plus_752,
            );
            let second = oriented_angle(
                self.state8_plus_15984,
                self.state20_plus_1152,
                self.state20_plus_752,
            );
            abs_bits(wrap_signed_angle(first) - wrap_signed_angle(second))
        } else {
            0.0
        };

        PumpingUpdateInput {
            a: self.prepared_plus_112,
            b: self.state20_plus_1216,
            c: self.state8_plus_11008,
            alpha,
            dt: f32::from_bits(CALLER_VARIANT_1_DT_WORD),
            state_byte: ((self.prepared_plus_2476_flags >> 1) & 1) as u8,
        }
    }
}

/// Literal inputs at the `0x82D436A0` caller.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CallerVariant2Input {
    pub prepared_plus_96: RetailVector4,
    pub prepared_plus_112: RetailVector4,
    pub state20_plus_1152: RetailVector4,
    pub state20_plus_1216: RetailVector4,
    pub state8_plus_11008: RetailVector4,
    pub prepared_plus_2472: u16,
    pub prepared_plus_2604: f32,
    pub prepared_plus_2720: f32,
}

impl CallerVariant2Input {
    pub fn update_input(self) -> PumpingUpdateInput {
        let angle = angle3(self.prepared_plus_96, self.state20_plus_1152);
        let alpha = if self.prepared_plus_2720 == 0.0 {
            abs_bits(angle - f32::from_bits(RETAIL_PI_OVER_TWO_WORD))
        } else {
            0.0
        };

        PumpingUpdateInput {
            a: self.prepared_plus_112,
            b: self.state20_plus_1216,
            c: self.state8_plus_11008,
            alpha,
            dt: self.prepared_plus_2604,
            state_byte: (self.prepared_plus_2472 & 1) as u8,
        }
    }
}

/// Logical and byte-compatible state for the observed 96-byte allocation.
///
/// `new` safely initializes unresolved bytes to zero. Retail construction only
/// called Reset, so callers that model pre-existing allocation bytes may set
/// the unresolved arrays before calling `reset`; Reset preserves them.
#[repr(C, align(16))]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Pumping {
    pub previous_a_plus_0: RetailVector4,
    pub previous_b_plus_16: RetailVector4,
    pub damped_positive_dot_delta_plus_32: f32,
    pub timer_plus_36: f32,
    pub previous_dot_plus_40: f32,
    pub last_scalar_plus_44: f32,
    pub output_plus_48: f32,
    pub angular_rate_plus_52: f32,
    pub negative_speed_times_angular_rate_plus_56: f32,
    pub selected_compression_plus_60: f32,
    pub min_crouch_graph_plus_64: f32,
    pub deck_graph_plus_68: f32,
    pub unresolved_float_plus_72: f32,
    pub initialized_plus_76: u8,
    pub unresolved_bytes_plus_77_through_80: [u8; 4],
    pub caller_state_plus_81: u8,
    pub unresolved_bytes_plus_82_through_95: [u8; 14],
}

impl Default for Pumping {
    fn default() -> Self {
        Self::new()
    }
}

impl Pumping {
    pub const fn new() -> Self {
        Self {
            previous_a_plus_0: [0.0; 4],
            previous_b_plus_16: [0.0; 4],
            damped_positive_dot_delta_plus_32: 0.0,
            timer_plus_36: 0.0,
            previous_dot_plus_40: 0.0,
            last_scalar_plus_44: 0.0,
            output_plus_48: 0.0,
            angular_rate_plus_52: 0.0,
            negative_speed_times_angular_rate_plus_56: 0.0,
            selected_compression_plus_60: 0.0,
            min_crouch_graph_plus_64: 0.0,
            deck_graph_plus_68: 0.0,
            unresolved_float_plus_72: 0.0,
            initialized_plus_76: 0,
            unresolved_bytes_plus_77_through_80: [0; 4],
            caller_state_plus_81: 0,
            unresolved_bytes_plus_82_through_95: [0; 14],
        }
    }

    /// Exact observed Reset writes. Unresolved allocation bytes are untouched.
    pub fn reset(&mut self) {
        self.previous_a_plus_0 = [0.0; 4];
        self.previous_b_plus_16 = [0.0; 4];
        self.damped_positive_dot_delta_plus_32 = 0.0;
        self.timer_plus_36 = 0.0;
        self.previous_dot_plus_40 = 0.0;
        self.last_scalar_plus_44 = 0.0;
        self.output_plus_48 = 0.0;
        self.angular_rate_plus_52 = 0.0;
        self.negative_speed_times_angular_rate_plus_56 = 0.0;
        self.selected_compression_plus_60 = 0.0;
        self.min_crouch_graph_plus_64 = 0.0;
        self.deck_graph_plus_68 = 0.0;
        self.unresolved_float_plus_72 = 0.0;
        self.initialized_plus_76 = 0;
        self.caller_state_plus_81 = 0;
    }

    /// Port of `Pumping::Update` at `0x82D8F228`.
    pub fn update(
        &mut self,
        input: PumpingUpdateInput,
        pumping: &RetailPumpingOperands,
        mode: &RetailPhysicsModeOperands,
    ) -> f32 {
        self.output_plus_48 = 0.0;

        let current_dot = ppc_dot3(input.c, input.b);
        if self.initialized_plus_76 != 0 {
            self.caller_state_plus_81 = input.state_byte;

            let dot_change = current_dot - self.previous_dot_plus_40;
            let positive_dot_change = fsel(dot_change, dot_change, 0.0);
            let one_minus_damping = 1.0 - pumping.pump_effect_damping;
            let old_term = one_minus_damping * self.damped_positive_dot_delta_plus_32;
            let damped = positive_dot_change.mul_add(pumping.pump_effect_damping, old_term);
            self.damped_positive_dot_delta_plus_32 = damped;

            let (mut raw, timer) = if damped < pumping.min_change_before_pumping {
                (0.0, 0.0)
            } else {
                let timer = if damped > 0.0 {
                    self.timer_plus_36 + input.dt
                } else {
                    0.0
                };
                (damped, timer)
            };
            self.timer_plus_36 = timer;

            if abs_bits(raw) > pumping.max_change_before_pumping {
                let sign = if raw > 0.0 {
                    1.0
                } else if raw >= 0.0 {
                    0.0
                } else {
                    -1.0
                };
                raw = sign * pumping.max_change_before_pumping;
            }

            let time_graph = eval8(&pumping.pump_vs_time, timer);
            let signal = time_graph * raw;
            let helper = self.scalar_producer(input.a, input.b, input.alpha, input.dt, pumping);
            self.last_scalar_plus_44 = helper;

            let helper_signal = helper * signal;
            let mode_scale = if helper_signal > 0.0 {
                mode.factor
            } else {
                mode.absorption
            };
            let scaled_helper = helper * mode_scale;
            let candidate = scaled_helper * signal;
            self.output_plus_48 = candidate;

            let lower_delta = mode.lower_rate * input.dt;
            let upper = mode.upper_rate * input.dt;
            let lower = -lower_delta;
            let above_lower = fsel(lower - candidate, lower, candidate);
            self.output_plus_48 = fsel(upper - above_lower, above_lower, upper);
        }

        self.previous_a_plus_0 = input.a;
        self.previous_b_plus_16 = input.b;
        self.initialized_plus_76 = 1;
        self.previous_dot_plus_40 = current_dot;
        self.output_plus_48
    }

    /// Port of scalar producer `0x82D8F470`.
    pub fn scalar_producer(
        &mut self,
        current_a: RetailVector4,
        current_b: RetailVector4,
        alpha: f32,
        dt: f32,
        pumping: &RetailPumpingOperands,
    ) -> f32 {
        let delta_a = sub4(current_a, self.previous_a_plus_0);
        let reciprocal_dt = reciprocal_refined_twice(dt);
        let delta_velocity = scale4(delta_a, reciprocal_dt);
        let speed = length3_or_zero(delta_velocity);
        let velocity_graph = eval8(&pumping.pump_vs_velocity, speed);

        let tangent = cross3(delta_a, current_b);
        let previous_to_current_b = cross3(self.previous_b_plus_16, current_b);
        let tangent_length_squared = ppc_dot3(tangent, tangent);
        let angular_raw = if tangent_length_squared > 0.0 {
            let tangent_unit = normalize3_nonzero(tangent, tangent_length_squared);
            let b_change_over_dt = scale4(previous_to_current_b, reciprocal_dt);
            ppc_dot3(b_change_over_dt, tangent_unit)
        } else {
            0.0
        };

        let one_minus_angular_damping = 1.0 - pumping.angular_damping;
        let angular_raw_term = angular_raw * pumping.angular_damping;
        let angular_rate =
            one_minus_angular_damping.mul_add(self.angular_rate_plus_52, angular_raw_term);
        self.angular_rate_plus_52 = angular_rate;

        let speed_times_angular_rate = speed * angular_rate;
        self.negative_speed_times_angular_rate_plus_56 = -speed_times_angular_rate;

        let previous_b_y = self.previous_b_plus_16[1];
        let ground_y = clamp_zero_one_fsel(previous_b_y);
        let ground_angle = ground_y.acos();
        let ground_input_unclamped = ground_angle * f32::from_bits(RETAIL_TWO_OVER_PI_WORD);
        let ground_input = clamp_zero_one_fsel(ground_input_unclamped);

        let ground_graph = eval8(&pumping.compression_ground_graph, ground_input);
        let ground_compression = ground_graph * pumping.compression_ground;
        self.selected_compression_plus_60 = ground_compression;

        self.min_crouch_graph_plus_64 = eval8(&pumping.min_crouch, ground_input);

        let deck_input = alpha * f32::from_bits(RETAIL_TWO_OVER_PI_WORD);
        let deck_graph = eval8(&pumping.compression_deck_graph, deck_input);
        self.deck_graph_plus_68 = deck_graph;
        let deck_compression = deck_graph * pumping.compression_deck;

        let deck_squared = deck_compression * deck_compression;
        let ground_squared = ground_compression * ground_compression;
        if deck_squared > ground_squared {
            self.selected_compression_plus_60 = deck_compression;
        }

        angular_rate * velocity_graph
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PreparedPumpingForceInput {
    pub prepared_plus_96_at: RetailVector4,
    pub prepared_plus_2476_flags: u32,
    pub prepared_plus_2604_dt: f32,
    pub prepared_plus_2612: f32,
    pub prepared_plus_2660_total_mass: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PumpingForceOutput {
    pub force: RetailVector4,
    pub local_point: RetailVector4,
}

/// Port of force builder `0x82D933D0`; queueing/application are intentionally
/// outside this module.
pub fn build_pumping_force(
    pumping_output_plus_48: f32,
    prepared: PreparedPumpingForceInput,
    mode: &RetailPhysicsModeOperands,
) -> PumpingForceOutput {
    let mut scalar = pumping_output_plus_48;
    if prepared.prepared_plus_2476_flags & 0x2 == 0 {
        scalar *= mode.unintentional_pump_scalar;
    }

    let mass_scaled = prepared.prepared_plus_2660_total_mass * scalar;
    let magnitude = mass_scaled / prepared.prepared_plus_2604_dt;

    // `PrepareToolkitInput` writes +432 as (+96 At) * f32[+2612].
    let prepared_plus_432 = scale4(prepared.prepared_plus_96_at, prepared.prepared_plus_2612);
    let squared = ppc_dot3(prepared_plus_432, prepared_plus_432);
    let direction = if squared > 0.0 {
        normalize3_nonzero(prepared_plus_432, squared)
    } else {
        [0.0; 4]
    };

    PumpingForceOutput {
        force: scale4(direction, magnitude),
        local_point: [0.0; 4],
    }
}

fn fsel(test: f32, nonnegative: f32, negative: f32) -> f32 {
    if test >= 0.0 { nonnegative } else { negative }
}

fn abs_bits(value: f32) -> f32 {
    f32::from_bits(value.to_bits() & 0x7FFF_FFFF)
}

fn clamp_zero_one_fsel(value: f32) -> f32 {
    let nonnegative = fsel(-value, 0.0, value);
    fsel(1.0 - nonnegative, nonnegative, 1.0)
}

fn vmx_min(left: f32, right: f32) -> f32 {
    if left < right { left } else { right }
}

fn vmx_max(left: f32, right: f32) -> f32 {
    if left > right { left } else { right }
}

fn ppc_vmsum_result(value: f32) -> f32 {
    if !value.is_finite() {
        return f32::from_bits(0x7FC0_0000);
    }
    let mut bits = value.to_bits();
    if ((bits >> 23) & 0xFF) == 0 && bits & 0x007F_FFFF != 0 {
        bits &= 0x8000_0000;
    }
    f32::from_bits(bits)
}

/// Scalar expression matching the recovered SSE `dp_ps(..., 0xEF)` grouping:
/// `(x0*y0 + x1*y1) + (x2*y2 + 0)`, followed by guest result handling.
fn ppc_dot3(left: RetailVector4, right: RetailVector4) -> f32 {
    let product_x = left[0] * right[0];
    let product_y = left[1] * right[1];
    let product_z = left[2] * right[2];
    let xy = product_x + product_y;
    let z0 = product_z + 0.0;
    ppc_vmsum_result(xy + z0)
}

fn sub4(left: RetailVector4, right: RetailVector4) -> RetailVector4 {
    [
        left[0] - right[0],
        left[1] - right[1],
        left[2] - right[2],
        left[3] - right[3],
    ]
}

fn scale4(value: RetailVector4, scalar: f32) -> RetailVector4 {
    [
        value[0] * scalar,
        value[1] * scalar,
        value[2] * scalar,
        value[3] * scalar,
    ]
}

fn cross3(left: RetailVector4, right: RetailVector4) -> RetailVector4 {
    [
        left[1] * right[2] - left[2] * right[1],
        left[2] * right[0] - left[0] * right[2],
        left[0] * right[1] - left[1] * right[0],
        0.0,
    ]
}

fn reciprocal_refined_twice(value: f32) -> f32 {
    let mut estimate = 1.0 / value;
    let mut error = 1.0 - estimate * value;
    estimate = estimate * error + estimate;
    error = 1.0 - estimate * value;
    estimate * error + estimate
}

fn reciprocal_sqrt_refined(value: f32, refinement_count: usize) -> f32 {
    let mut estimate = ppc_vrsqrtefp(value);
    let mut count = 0;
    while count < refinement_count {
        let estimate_squared = estimate * estimate;
        let half_estimate = estimate * 0.5;
        let error = 1.0 - value * estimate_squared;
        estimate = half_estimate * error + estimate;
        count += 1;
    }
    estimate
}

fn length3_or_zero(value: RetailVector4) -> f32 {
    let squared = ppc_dot3(value, value);
    if squared == 0.0 {
        0.0
    } else {
        squared * reciprocal_sqrt_refined(squared, 2)
    }
}

fn normalize3_nonzero(value: RetailVector4, squared: f32) -> RetailVector4 {
    scale4(value, reciprocal_sqrt_refined(squared, 2))
}

fn normalize3_threshold(value: RetailVector4) -> Option<RetailVector4> {
    let squared = ppc_dot3(value, value);
    let epsilon_squared = f32::from_bits(RETAIL_VECTOR_LENGTH_EPSILON_SQUARED_WORD);
    if squared > epsilon_squared {
        Some(scale4(value, reciprocal_sqrt_refined(squared, 1)))
    } else {
        None
    }
}

fn angle3(first: RetailVector4, second: RetailVector4) -> f32 {
    let Some(first) = normalize3_threshold(first) else {
        return 0.0;
    };
    let Some(second) = normalize3_threshold(second) else {
        return 0.0;
    };
    let dot = ppc_dot3(first, second);
    let clamped_low = vmx_max(dot, -1.0);
    let clamped = vmx_min(clamped_low, 1.0);
    clamped.acos()
}

fn oriented_angle(first: RetailVector4, second: RetailVector4, axis: RetailVector4) -> f32 {
    let Some(first_normalized) = normalize3_threshold(first) else {
        return 0.0;
    };
    let Some(second_normalized) = normalize3_threshold(second) else {
        return 0.0;
    };

    let dot = ppc_dot3(first_normalized, second_normalized);
    let clamped_low = vmx_max(dot, -1.0);
    let clamped = vmx_min(clamped_low, 1.0);
    let angle = clamped.acos();
    let cross = cross3(first_normalized, second_normalized);
    let orientation = ppc_dot3(cross, axis);
    if orientation < 0.0 {
        f32::from_bits(RETAIL_TAU_WORD) - angle
    } else {
        angle
    }
}

fn wrap_signed_angle(angle: f32) -> f32 {
    let scaled = angle * f32::from_bits(RETAIL_INVERSE_TAU_WORD);
    let fraction = scaled - scaled.floor();
    let centered = if fraction > 0.5 {
        fraction - 1.0
    } else {
        fraction
    };
    centered * f32::from_bits(RETAIL_TAU_WORD)
}

/// Exact Xenon `vrsqrtefp` estimate table used by the static recompilation.
fn ppc_vrsqrtefp(value: f32) -> f32 {
    const TABLE: [u32; 32] = [
        0x0568_B4FD,
        0x04F3_AF97,
        0x048D_AAA5,
        0x0435_A618,
        0x03E7_A1E4,
        0x03A2_9DFE,
        0x0365_9A5C,
        0x032E_96F8,
        0x02FC_93CA,
        0x02D0_90CE,
        0x02A8_8DFE,
        0x0283_8B57,
        0x0261_88D4,
        0x0243_8673,
        0x0226_8431,
        0x020B_820B,
        0x03D2_7FFA,
        0x0380_7C29,
        0x0338_78AA,
        0x02F9_7572,
        0x02C2_7279,
        0x0292_6FB7,
        0x0266_6D26,
        0x023F_6AC0,
        0x021D_6881,
        0x01FD_6665,
        0x01E1_6468,
        0x01C7_6287,
        0x01AF_60C1,
        0x0199_5F12,
        0x0185_5D79,
        0x0173_5BF4,
    ];

    let bits = value.to_bits();
    let sign = bits >> 31;
    let biased_exp = (bits >> 23) & 0xFF;
    let mantissa = bits & 0x007F_FFFF;
    let result = if bits == 0xFF80_0000 {
        0x7FC0_0000
    } else if biased_exp == 0 {
        if sign != 0 { 0xFF80_0000 } else { 0x7F80_0000 }
    } else if biased_exp == 0xFF {
        if mantissa == 0 { 0 } else { bits | 0x0040_0000 }
    } else if sign != 0 {
        0x7FC0_0000
    } else {
        let unbiased_exp = biased_exp as i32 - 127;
        let index = ((((unbiased_exp as u32) << 4) & 16) | (mantissa >> 19)) ^ 16;
        let interpolation = (mantissa >> 9) & 1023;
        let entry = TABLE[index as usize];
        let slope = entry >> 16;
        let base = (entry << 10) & 0x03FF_FC00;
        let mut raw = base as i32 - (interpolation * slope) as i32;
        let mut result_exp = (127 - biased_exp as i32) >> 1;
        if raw & (1 << 25) == 0 {
            let value = (raw as u32) & 0x01FF_FFFF;
            let leading = value.leading_zeros() as i32;
            let shift = leading - 6;
            result_exp += 6 - leading;
            raw <<= shift;
        }
        if raw & 5 != 0 && raw & 2 != 0 {
            raw += 4;
        }
        let mut result = ((result_exp << 23) as u32).wrapping_add(0x3F80_0000)
            | (((raw as u32) >> 2) & 0x007F_FFFF);
        if ((result >> 23) & 0xFF) == 0 && result & 0x007F_FFFF != 0 {
            result = 0;
        }
        result
    };
    f32::from_bits(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{offset_of, size_of};

    fn bits8(values: [f32; 8]) -> [u32; 8] {
        values.map(f32::to_bits)
    }

    fn input(a: RetailVector4, b: RetailVector4, c: RetailVector4) -> PumpingUpdateInput {
        PumpingUpdateInput {
            a,
            b,
            c,
            alpha: 0.0,
            dt: f32::from_bits(CALLER_VARIANT_1_DT_WORD),
            state_byte: 1,
        }
    }

    #[test]
    fn raw_word_defaults_are_exact() {
        let defaults = RETAIL_PUMPING_OPERANDS;
        assert_eq!(
            bits8(defaults.pump_vs_velocity.x),
            RETAIL_PUMP_VS_VELOCITY_WORDS[4..12]
        );
        assert_eq!(
            bits8(defaults.pump_vs_velocity.y),
            RETAIL_PUMP_VS_VELOCITY_WORDS[12..20]
        );
        assert_eq!(
            bits8(defaults.pump_vs_time.x),
            RETAIL_PUMP_VS_TIME_WORDS[4..12]
        );
        assert_eq!(
            bits8(defaults.pump_vs_time.y),
            RETAIL_PUMP_VS_TIME_WORDS[12..20]
        );
        assert_eq!(bits8(defaults.min_crouch.x), RETAIL_MIN_CROUCH_WORDS[0..8]);
        assert_eq!(bits8(defaults.min_crouch.y), RETAIL_MIN_CROUCH_WORDS[8..16]);
        assert_eq!(
            bits8(defaults.compression_ground_graph.x),
            RETAIL_COMPRESSION_GROUND_WORDS[0..8]
        );
        assert_eq!(
            bits8(defaults.compression_ground_graph.y),
            RETAIL_COMPRESSION_GROUND_WORDS[8..16]
        );
        assert_eq!(
            bits8(defaults.compression_deck_graph.x),
            RETAIL_COMPRESSION_DECK_WORDS[0..8]
        );
        assert_eq!(
            bits8(defaults.compression_deck_graph.y),
            RETAIL_COMPRESSION_DECK_WORDS[8..16]
        );

        let scalar_bits = [
            defaults.radius_damping_unused.to_bits(),
            defaults.pump_min_factor_unused.to_bits(),
            defaults.pump_effect_damping.to_bits(),
            defaults.pump_angle_unused.to_bits(),
            defaults.min_change_before_pumping.to_bits(),
            defaults.max_change_before_pumping.to_bits(),
            defaults.compression_ground.to_bits(),
            defaults.compression_deck.to_bits(),
            defaults.average_height_unused.to_bits(),
            defaults.angular_damping.to_bits(),
        ];
        assert_eq!(scalar_bits, RETAIL_PHYSICS_PUMPING_SCALAR_WORDS);

        let mode = RETAIL_PHYSICS_MODE;
        assert_eq!(
            [
                mode.unintentional_pump_scalar.to_bits(),
                mode.lower_rate.to_bits(),
                mode.upper_rate.to_bits(),
                mode.absorption.to_bits(),
                mode.factor.to_bits(),
            ],
            RETAIL_PHYSICS_MODE_WORDS
        );
    }

    #[test]
    fn graph_boundaries_follow_retail_control_flow() {
        let graph = EvalGraph8 {
            x: [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0],
            y: [10.0, 20.0, 40.0, 80.0, 160.0, 320.0, 640.0, 1280.0],
        };
        assert_eq!(eval8(&graph, -1.0).to_bits(), 10.0f32.to_bits());
        assert_eq!(eval8(&graph, 0.0).to_bits(), 10.0f32.to_bits());
        assert_eq!(eval8(&graph, 0.5).to_bits(), 15.0f32.to_bits());
        assert_eq!(eval8(&graph, 7.0).to_bits(), 1280.0f32.to_bits());
        assert_eq!(eval8(&graph, 8.0).to_bits(), 1280.0f32.to_bits());
        assert_eq!(eval8(&graph, f32::NAN).to_bits(), 1280.0f32.to_bits());

        let degenerate = EvalGraph8 {
            x: [0.0, 1.0, 1.0, 3.0, 4.0, 5.0, 6.0, 7.0],
            y: [0.0, 1.0, 99.0, 3.0, 4.0, 5.0, 6.0, 7.0],
        };
        assert_eq!(eval8(&degenerate, 1.0).to_bits(), 99.0f32.to_bits());
    }

    #[test]
    fn reset_layout_and_untouched_bytes_match_observation() {
        assert_eq!(size_of::<Pumping>(), 96);
        assert_eq!(offset_of!(Pumping, previous_a_plus_0), 0);
        assert_eq!(offset_of!(Pumping, previous_b_plus_16), 16);
        assert_eq!(offset_of!(Pumping, damped_positive_dot_delta_plus_32), 32);
        assert_eq!(offset_of!(Pumping, unresolved_float_plus_72), 72);
        assert_eq!(offset_of!(Pumping, initialized_plus_76), 76);
        assert_eq!(offset_of!(Pumping, unresolved_bytes_plus_77_through_80), 77);
        assert_eq!(offset_of!(Pumping, caller_state_plus_81), 81);
        assert_eq!(offset_of!(Pumping, unresolved_bytes_plus_82_through_95), 82);

        let mut state = Pumping::new();
        state.previous_a_plus_0 = [1.0; 4];
        state.output_plus_48 = 2.0;
        state.initialized_plus_76 = 1;
        state.caller_state_plus_81 = 0xFF;
        state.unresolved_bytes_plus_77_through_80 = [1, 2, 3, 4];
        state.unresolved_bytes_plus_82_through_95 = [0xA5; 14];
        state.reset();

        assert_eq!(state.previous_a_plus_0.map(f32::to_bits), [0; 4]);
        assert_eq!(state.output_plus_48.to_bits(), 0);
        assert_eq!(state.initialized_plus_76, 0);
        assert_eq!(state.caller_state_plus_81, 0);
        assert_eq!(state.unresolved_bytes_plus_77_through_80, [1, 2, 3, 4]);
        assert_eq!(state.unresolved_bytes_plus_82_through_95, [0xA5; 14]);
    }

    #[test]
    fn first_call_only_primes_history_and_returns_positive_zero() {
        let mut state = Pumping::new();
        let first = input(
            [3.0, 4.0, 5.0, 6.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 2.0, 0.0, 0.0],
        );
        let output = state.update(first, &RETAIL_PUMPING_OPERANDS, &RETAIL_PHYSICS_MODE);
        assert_eq!(output.to_bits(), 0);
        assert_eq!(state.output_plus_48.to_bits(), 0);
        assert_eq!(state.initialized_plus_76, 1);
        assert_eq!(state.previous_a_plus_0, first.a);
        assert_eq!(state.previous_b_plus_16, first.b);
        assert_eq!(state.previous_dot_plus_40.to_bits(), 2.0f32.to_bits());
        assert_eq!(state.angular_rate_plus_52.to_bits(), 0);
    }

    #[test]
    fn nontrivial_multi_step_scalar_host_fixture() {
        let _rounding_scope = SCALAR_HOST_ROUNDING_NOTE;
        let mut state = Pumping::new();
        state.update(
            input(
                [0.0, 0.0, 0.0, 0.0],
                [0.0, 1.0, 0.0, 0.0],
                [0.0, 1.0, 0.0, 0.0],
            ),
            &RETAIL_PUMPING_OPERANDS,
            &RETAIL_PHYSICS_MODE,
        );

        let second = state.update(
            input(
                [-0.05, 0.0, 0.0, 0.0],
                [0.01, 0.99995, 0.0, 0.0],
                [0.011, 1.099945, 0.0, 0.0],
            ),
            &RETAIL_PUMPING_OPERANDS,
            &RETAIL_PHYSICS_MODE,
        );
        let second_words = [
            second.to_bits(),
            state.damped_positive_dot_delta_plus_32.to_bits(),
            state.timer_plus_36.to_bits(),
            state.angular_rate_plus_52.to_bits(),
            state.last_scalar_plus_44.to_bits(),
            state.selected_compression_plus_60.to_bits(),
        ];

        let third = state.update(
            input(
                [-0.11, 0.0, 0.0, 0.0],
                [0.02, 0.9998, 0.0, 0.0],
                [0.0224, 1.119776, 0.0, 0.0],
            ),
            &RETAIL_PUMPING_OPERANDS,
            &RETAIL_PHYSICS_MODE,
        );
        let third_words = [
            third.to_bits(),
            state.damped_positive_dot_delta_plus_32.to_bits(),
            state.timer_plus_36.to_bits(),
            state.angular_rate_plus_52.to_bits(),
            state.last_scalar_plus_44.to_bits(),
            state.selected_compression_plus_60.to_bits(),
        ];

        // Scalar-host words; see `SCALAR_HOST_ROUNDING_NOTE`.
        assert_eq!(
            second_words,
            [
                0x3CDE_2BF5,
                0x3C23_D70D,
                0x3C88_8889,
                0x3DF5_C28F,
                0x3E80_9254,
                0x8000_0000,
            ]
        );
        assert_eq!(
            third_words,
            [
                0x3D23_7D60,
                0x3C34_3965,
                0x3D08_8889,
                0x3E5D_323E,
                0x3EBD_3968,
                0xBCFF_B862,
            ]
        );
    }

    #[test]
    fn final_output_clamps_to_mode_upper_rate_times_dt() {
        let mut state = Pumping::new();
        state.update(
            input(
                [0.0, 0.0, 0.0, 0.0],
                [0.0, 1.0, 0.0, 0.0],
                [0.0, 1.0, 0.0, 0.0],
            ),
            &RETAIL_PUMPING_OPERANDS,
            &RETAIL_PHYSICS_MODE,
        );
        let dt = f32::from_bits(CALLER_VARIANT_1_DT_WORD);
        let mut high_factor_mode = RETAIL_PHYSICS_MODE;
        high_factor_mode.factor = 1800.0;
        let output = state.update(
            input(
                [-1.0, 0.0, 0.0, 0.0],
                [0.5, 0.8660254, 0.0, 0.0],
                [1.0, 1.7320508, 0.0, 0.0],
            ),
            &RETAIL_PUMPING_OPERANDS,
            &high_factor_mode,
        );
        assert_eq!(
            output.to_bits(),
            (RETAIL_PHYSICS_MODE.upper_rate * dt).to_bits()
        );
    }

    #[test]
    fn force_conversion_uses_mass_over_dt_and_plus_2612_sign() {
        let output = build_pumping_force(
            0.02,
            PreparedPumpingForceInput {
                prepared_plus_96_at: [1.0, 0.0, 0.0, 0.0],
                prepared_plus_2476_flags: 0x2,
                prepared_plus_2604_dt: 0.02,
                prepared_plus_2612: -1.0,
                prepared_plus_2660_total_mass: 10.0,
            },
            &RETAIL_PHYSICS_MODE,
        );
        assert_eq!(
            output.force.map(f32::to_bits),
            [-10.0f32, -0.0, -0.0, -0.0].map(f32::to_bits)
        );
        assert_eq!(output.local_point.map(f32::to_bits), [0; 4]);

        let zero_direction = build_pumping_force(
            1.0,
            PreparedPumpingForceInput {
                prepared_plus_96_at: [1.0, 0.0, 0.0, 0.0],
                prepared_plus_2476_flags: 0x2,
                prepared_plus_2604_dt: 0.5,
                prepared_plus_2612: 0.0,
                prepared_plus_2660_total_mass: 50.0,
            },
            &RETAIL_PHYSICS_MODE,
        );
        assert_eq!(zero_direction.force.map(f32::to_bits), [0; 4]);
    }

    #[test]
    fn caller_variants_keep_literal_channel_provenance() {
        let variant1 = CallerVariant1Input {
            prepared_plus_96: [1.0, 0.0, 0.0, 0.0],
            prepared_plus_112: [10.0, 20.0, 30.0, 1.0],
            state20_plus_752: [0.0, 0.0, 1.0, 0.0],
            state20_plus_1152: [0.0, 1.0, 0.0, 0.0],
            state20_plus_1216: [0.0, 1.0, 0.0, 0.0],
            state8_plus_11008: [0.0, 2.0, 0.0, 0.0],
            state8_plus_15984: [0.0, 1.0, 0.0, 0.0],
            prepared_plus_2476_flags: 0x2,
        }
        .update_input();
        assert_eq!(variant1.a, [10.0, 20.0, 30.0, 1.0]);
        assert_eq!(variant1.b, [0.0, 1.0, 0.0, 0.0]);
        assert_eq!(variant1.c, [0.0, 2.0, 0.0, 0.0]);
        assert_eq!(variant1.dt.to_bits(), CALLER_VARIANT_1_DT_WORD);
        assert_eq!(variant1.state_byte, 1);

        let variant2 = CallerVariant2Input {
            prepared_plus_96: [1.0, 0.0, 0.0, 0.0],
            prepared_plus_112: [4.0, 5.0, 6.0, 1.0],
            state20_plus_1152: [0.0, 1.0, 0.0, 0.0],
            state20_plus_1216: [0.0, 0.0, 1.0, 0.0],
            state8_plus_11008: [0.0, 0.0, 3.0, 0.0],
            prepared_plus_2472: 3,
            prepared_plus_2604: 0.02,
            prepared_plus_2720: -0.0,
        }
        .update_input();
        assert_eq!(variant2.a, [4.0, 5.0, 6.0, 1.0]);
        assert_eq!(variant2.b, [0.0, 0.0, 1.0, 0.0]);
        assert_eq!(variant2.c, [0.0, 0.0, 3.0, 0.0]);
        assert_eq!(variant2.state_byte, 1);
        assert_eq!(variant2.dt.to_bits(), 0.02f32.to_bits());
    }
}
