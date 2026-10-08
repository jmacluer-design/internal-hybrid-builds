//! Evidence-backed Skate 3 TU3 landing classification and MotionGraph slice.
//!
//! The air-to-ground landing-type classifier at TU3 `0x82DE61D0` is recovered
//! here. Board tilt limits, contact ABI, runout production, landing-adjust
//! transforms, and IK offsets remain separate providers.
#![allow(dead_code)]

pub const LANDING_ANIMATION_BLEND_SECONDS: f32 = 0.15;
pub const LANDING_WILL_EXPIRE_WINDOW_SECONDS: f32 = 0.1;
pub const LANDING_TRICK_LOCKOUT_SECONDS: f32 = 0.3;
pub const PRELAND_TIME_TO_LAND_SECONDS: f32 = 0.05;
pub const PUSH_AND_DISMOUNT_GATE_SECONDS: f32 = 0.1;
pub const STRAIGHT_CROUCH_EXIT_SECONDS: f32 = 0.2;
pub const SPIN_CROUCH_EXIT_SECONDS: f32 = 0.3;
pub const SKETCHY_CROUCH_EXIT_SECONDS: f32 = 0.4;

const RETAIL_LANDING_MINIMUM_SPEED: f32 = 2.0;
const RETAIL_LANDING_MINIMUM_VECTOR_PRODUCT: f32 = 1.0e-5;
const RETAIL_LANDING_ROTATION_DEADZONE: f32 = 0.1;
const RETAIL_LANDING_HEADING_STRAIGHT: f32 = 0.05;
const RETAIL_LANDING_HEADING_MILD: f32 = 0.2;
const RETAIL_LANDING_SPIN_PRESERVE_ERROR: f32 = 0.3;
const RETAIL_TWIST_INPUT_SCALE: f32 = 0.144_927_53;
const RETAIL_SIDE_SPEED_INPUT_SCALE: f32 = 0.101_010_1;

// physics_animation/default.xml PointGraphData4 values. sub_82481E10 is the
// exact piecewise-linear sampler used by the classifier.
const RETAIL_TWIST_CURVE: [(f32, f32); 4] = [
    (0.0, 0.0),
    (0.260_586_3, 0.506_944_4),
    (0.561_889_2, 0.812_5),
    (1.0, 1.0),
];
const RETAIL_SIDE_SPEED_CURVE: [(f32, f32); 4] = [
    (0.0, 0.0),
    (0.228_658_5, 0.215_277_8),
    (0.551_829_3, 0.819_444_4),
    (0.833_841_4, 1.0),
];

/// Six-word add-with-carry state used by the player-owned TU3 random provider.
///
/// `ChooseRandomLanding::Begin` calls the provider's vtable slot `+256`
/// (`0x8258FB60`), which forwards to `0x82970628` with the state at actor
/// random-provider `+3316`. The selected landing is
/// `abs(next_i32()) % numlandings`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RetailLandingRandom {
    pub calls: u32,
    pub words: [u32; 6],
}

impl RetailLandingRandom {
    /// State observed immediately before the first flat-ground landing in a
    /// fresh deterministic parity-harness boot on 2026-08-31.
    pub const FIRST_FLAT_OLLIE_CAPTURE: Self = Self {
        calls: 0,
        words: [
            4_063_039_062,
            2_284_922_601,
            3_324_304_687,
            117_621_916,
            2_654_289_789,
            1_876_900_708,
        ],
    };

    pub fn next_i32(&mut self) -> i32 {
        let mut carry;
        (self.words[4], carry) = self.words[4].overflowing_add(self.words[5]);
        (self.words[3], carry) = add_with_carry(self.words[3], self.words[4], carry);
        (self.words[2], carry) = add_with_carry(self.words[2], self.words[3], carry);
        (self.words[1], carry) = add_with_carry(self.words[1], self.words[2], carry);
        (self.words[0], _) = add_with_carry(self.words[0], self.words[1], carry);

        for word in self.words.iter_mut().rev() {
            *word = word.wrapping_add(1);
            if *word != 0 {
                break;
            }
        }
        self.calls = self.calls.wrapping_add(1);
        self.words[0] as i32
    }

    pub fn choose_variant(&mut self, variant_count: u8) -> u8 {
        assert!(variant_count > 0, "retail traps when numlandings is zero");
        let random = self.next_i32();
        let magnitude = if random < 0 {
            random.wrapping_neg() as u32
        } else {
            random as u32
        };
        (magnitude % u32::from(variant_count)) as u8
    }
}

impl Default for RetailLandingRandom {
    fn default() -> Self {
        Self::FIRST_FLAT_OLLIE_CAPTURE
    }
}

fn add_with_carry(left: u32, right: u32, carry: bool) -> (u32, bool) {
    let (sum, first_carry) = left.overflowing_add(right);
    let (sum, second_carry) = sum.overflowing_add(u32::from(carry));
    (sum, first_carry || second_carry)
}

/// Raw value exposed by the retail landing-data provider.
///
/// `HasLandingType` stores one of these values at condition-object offset
/// `+28`, then compares it with the provider word at provider-child `+56/+96`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct LandingTypeCode(pub u32);

impl LandingTypeCode {
    pub const STRAIGHT: Self = Self(0);
    pub const SKETCHY: Self = Self(1);
    pub const SPIN: Self = Self(2);
    /// Mild off-axis result. Landing.xml has no explicit condition for code 3,
    /// so it follows the authored Straight fallback child.
    pub const MILD_OFF_AXIS: Self = Self(3);
}

/// Inputs consumed by TU3's air-to-ground landing classifier.
///
/// `heading_delta_radians` is velocity heading minus board-forward heading on
/// the contact plane. `completed_rotation_radians` uses the skater's
/// retail-normalized BS-positive convention. The orientation byte at
/// SkateboardMotion `+273` reverses both normalized board tests.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailLandingClassifierInput {
    pub approach_speed_metres_per_second: f32,
    pub heading_delta_radians: Option<f32>,
    pub completed_rotation_radians: f32,
    pub orientation_reversed: bool,
}

/// Exact fields published by `0x82DE61D0` at PhysOut_Animation `+80..+96`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailLandingClassifierOutput {
    pub error: f32,
    pub raw_lateral_speed: f32,
    pub raw_alignment_dot: f32,
    pub signed_error: f32,
    pub provider_code: LandingTypeCode,
}

fn sample_retail_point_graph(points: &[(f32, f32); 4], input: f32) -> f32 {
    if input < points[0].0 {
        return points[0].1;
    }
    if input >= points[3].0 {
        return points[3].1;
    }
    for pair in points.windows(2) {
        let [(x0, y0), (x1, y1)] = pair else {
            unreachable!("windows(2) always contains two points")
        };
        if input < *x1 {
            let width = *x1 - *x0;
            return if width > 0.0 {
                (*y1 - *y0).mul_add((input - *x0) / width, *y0)
            } else {
                *y1
            };
        }
    }
    points[3].1
}

/// Port of the retail classifier at `0x82DE61D0`.
///
/// The function is called only on the filtered Air -> Ground transition in
/// retail. Contact admission and wipeout/runout remain outside this numeric
/// classifier, exactly as they are in the native pipeline.
pub fn classify_retail_landing_kinematics(
    input: RetailLandingClassifierInput,
) -> RetailLandingClassifierOutput {
    let Some(heading_delta) = input
        .heading_delta_radians
        .filter(|value| value.is_finite())
    else {
        return RetailLandingClassifierOutput {
            error: 0.0,
            raw_lateral_speed: 0.0,
            raw_alignment_dot: 0.0,
            signed_error: 0.0,
            provider_code: LandingTypeCode::STRAIGHT,
        };
    };
    let speed = input.approach_speed_metres_per_second.max(0.0);
    if !speed.is_finite() || speed < RETAIL_LANDING_MINIMUM_VECTOR_PRODUCT {
        return RetailLandingClassifierOutput {
            error: 0.0,
            raw_lateral_speed: 0.0,
            raw_alignment_dot: 0.0,
            signed_error: 0.0,
            provider_code: LandingTypeCode::STRAIGHT,
        };
    }

    let raw_sin = heading_delta.sin();
    let raw_cos = heading_delta.cos();
    let raw_lateral_speed = speed * raw_sin.abs();
    let raw_alignment_dot = speed * raw_cos.abs();
    if speed < RETAIL_LANDING_MINIMUM_SPEED {
        return RetailLandingClassifierOutput {
            error: 0.0,
            raw_lateral_speed,
            raw_alignment_dot,
            signed_error: 0.0,
            provider_code: LandingTypeCode::STRAIGHT,
        };
    }

    let orientation_sign = if input.orientation_reversed {
        -1.0
    } else {
        1.0
    };
    let heading_sin = raw_sin * orientation_sign;
    let alignment_dot = raw_cos * orientation_sign;
    let rotation = input.completed_rotation_radians;
    let twist_input =
        ((rotation.abs() - RETAIL_LANDING_ROTATION_DEADZONE) * RETAIL_TWIST_INPUT_SCALE).min(1.0);
    let side_speed_input = ((raw_lateral_speed - RETAIL_LANDING_ROTATION_DEADZONE)
        * RETAIL_SIDE_SPEED_INPUT_SCALE)
        .min(1.0);
    let twist_error = sample_retail_point_graph(&RETAIL_TWIST_CURVE, twist_input);
    let side_speed_error = sample_retail_point_graph(&RETAIL_SIDE_SPEED_CURVE, side_speed_input);

    let (mut provider_code, error) = if rotation.abs() > RETAIL_LANDING_ROTATION_DEADZONE {
        let product_is_positive = rotation * heading_sin > 0.0;
        let sketchy = if alignment_dot >= 0.0 {
            product_is_positive
        } else {
            !product_is_positive
        };
        (
            if sketchy {
                LandingTypeCode::SKETCHY
            } else {
                LandingTypeCode::SPIN
            },
            twist_error.max(side_speed_error),
        )
    } else {
        (LandingTypeCode::SKETCHY, side_speed_error)
    };
    let signed_error = error.copysign(rotation);

    if heading_sin.abs() < RETAIL_LANDING_HEADING_MILD {
        let preserve_spin = provider_code == LandingTypeCode::SPIN
            && signed_error.abs() > RETAIL_LANDING_SPIN_PRESERVE_ERROR;
        if !preserve_spin {
            provider_code = if heading_sin.abs() < RETAIL_LANDING_HEADING_STRAIGHT {
                LandingTypeCode::STRAIGHT
            } else {
                LandingTypeCode::MILD_OFF_AXIS
            };
        }
    }

    RetailLandingClassifierOutput {
        error,
        raw_lateral_speed,
        raw_alignment_dot,
        signed_error,
        provider_code,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LandingQuality {
    /// The XML state is named `Spin`; its animation resource is
    /// `B_LAND_NICE`.
    Spin,
    Sketchy,
    /// The authored default child when neither `spin` nor `sketchy` matches.
    Straight,
}

/// Touchdown facts retained at the boundary where retail's landing-data
/// provider publishes `LandingTypeCode`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LandingDecisionInput {
    pub filtered_state: FilteredPhysicsState,
    pub approach_speed_metres_per_second: f32,
    pub board_velocity_heading_delta_radians: Option<f32>,
    pub completed_rotation_radians: f32,
    pub tilt_too_large_for_preland: Option<bool>,
    pub physics_wants_runout: Option<bool>,
    pub provider_code: Option<LandingTypeCode>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LandingClassificationSource {
    /// Exact word read by `HasLandingType` from the retail landing-data child
    /// at provider-child `+56/+96`.
    RetailLandingDataProvider,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LandingClassification {
    pub quality: LandingQuality,
    pub source: LandingClassificationSource,
    pub evidence: LandingDecisionInput,
}

impl LandingQuality {
    pub const fn from_provider_code(code: LandingTypeCode) -> Self {
        match code {
            LandingTypeCode::SPIN => Self::Spin,
            LandingTypeCode::SKETCHY => Self::Sketchy,
            // `Straight` has no HasLandingType precondition in retail XML. It
            // is the fallback child for the canonical zero code and any
            // unrecognized provider value.
            _ => Self::Straight,
        }
    }

    pub const fn animation_plan(self) -> LandingAnimationPlan {
        match self {
            Self::Spin => LandingAnimationPlan {
                virtual_resource: "B_LAND_NICE",
                blend_seconds: LANDING_ANIMATION_BLEND_SECONDS,
                variant_selection: LandingVariantSelection::None,
                interruptible: false,
            },
            Self::Sketchy => LandingAnimationPlan {
                virtual_resource: "B_LAND_SKETCH",
                blend_seconds: LANDING_ANIMATION_BLEND_SECONDS,
                variant_selection: LandingVariantSelection::ExternalRetailSelection {
                    variant_count: 5,
                },
                interruptible: false,
            },
            Self::Straight => LandingAnimationPlan {
                virtual_resource: "BLEND_LAND",
                blend_seconds: LANDING_ANIMATION_BLEND_SECONDS,
                variant_selection: LandingVariantSelection::ExternalRetailSelection {
                    variant_count: 3,
                },
                interruptible: false,
            },
        }
    }

    pub const fn crouch_exit_gate_seconds(self) -> f32 {
        match self {
            Self::Spin => SPIN_CROUCH_EXIT_SECONDS,
            Self::Sketchy => SKETCHY_CROUCH_EXIT_SECONDS,
            Self::Straight => STRAIGHT_CROUCH_EXIT_SECONDS,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LandingVariantSelection {
    None,
    /// Retail invokes `ChooseRandomLanding` with this count. This plan retains
    /// the provider boundary so callers may inject synchronized retail state;
    /// `RetailLandingRandom` implements the recovered local provider.
    ExternalRetailSelection {
        variant_count: u8,
    },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LandingAnimationPlan {
    /// MotionGraph resource. It is not necessarily a physical ABIN leaf.
    pub virtual_resource: &'static str,
    pub blend_seconds: f32,
    pub variant_selection: LandingVariantSelection,
    pub interruptible: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LandingUnresolved {
    LandingTypeProviderRequired,
    TiltTooLargeProviderRequired,
    PhysicsWantsRunoutProviderRequired,
    CanLandOnBoardProviderRequired,
    TimeToLandProviderRequired,
    LandTargetEvaluationRequired,
    AbsorbLandAttributeRequired,
    CompetingDefaultPriorityTransitions { candidate_mask: u16 },
    RandomVariantSelectionRequired { variant_count: u8 },
    RandomVariantOutOfRange { variant: u8, variant_count: u8 },
    ConcreteAnimationLeafRequired,
    LandingAdjustTransformRequired,
    LandingOnSkateboardAdjustRequired,
    SkateboardOffsetTransformRequired,
    ContactAbiRequired,
    IkOffsetsRequired,
}

pub fn classify_landing(
    provider_code: Option<LandingTypeCode>,
) -> Result<LandingQuality, LandingUnresolved> {
    provider_code
        .map(LandingQuality::from_provider_code)
        .ok_or(LandingUnresolved::LandingTypeProviderRequired)
}

/// Classify only when the authoritative provider word is present, while
/// retaining the kinematic and contact facts needed to compare future captures.
pub fn classify_landing_decision(
    input: LandingDecisionInput,
) -> Result<LandingClassification, LandingUnresolved> {
    let quality = classify_landing(input.provider_code)?;
    Ok(LandingClassification {
        quality,
        source: LandingClassificationSource::RetailLandingDataProvider,
        evidence: input,
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FilteredPhysicsState {
    Ground,
    Air,
    Grind,
    Other(u32),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LandingNotEligible {
    FilteredStateIsNotGround,
    TiltTooLargeForPreland,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LandingAdmission {
    Enter(LandingQuality),
    Wipeout,
    NotEligible(LandingNotEligible),
    Unresolved(LandingUnresolved),
}

/// Applies only predicates visible at the authored `Land` boundary.
///
/// The function accepts provider results. It deliberately has no angle,
/// velocity, contact-count, or board-orientation parameters because no exact
/// retail thresholds for those inputs have been recovered.
pub fn arbitrate_landing_admission(
    filtered_state: FilteredPhysicsState,
    tilt_too_large_for_preland: Option<bool>,
    physics_wants_runout: Option<bool>,
    provider_code: Option<LandingTypeCode>,
) -> LandingAdmission {
    if filtered_state != FilteredPhysicsState::Ground {
        return LandingAdmission::NotEligible(LandingNotEligible::FilteredStateIsNotGround);
    }

    match tilt_too_large_for_preland {
        Some(true) => {
            return LandingAdmission::NotEligible(LandingNotEligible::TiltTooLargeForPreland);
        }
        Some(false) => {}
        None => {
            return LandingAdmission::Unresolved(LandingUnresolved::TiltTooLargeProviderRequired);
        }
    }

    match physics_wants_runout {
        Some(true) => return LandingAdmission::Wipeout,
        Some(false) => {}
        None => {
            return LandingAdmission::Unresolved(
                LandingUnresolved::PhysicsWantsRunoutProviderRequired,
            );
        }
    }

    match classify_landing(provider_code) {
        Ok(quality) => LandingAdmission::Enter(quality),
        Err(reason) => LandingAdmission::Unresolved(reason),
    }
}

/// Behaviours authored directly on the retail `Land` state.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LandingEntryPlan {
    pub create_playing_landing_attribute: bool,
    pub augment_score_as_landing: bool,
    pub mark_is_landing: bool,
    pub force_physics_skateboard: bool,
    pub attach_fakie_turn: bool,
    pub set_landing_data: bool,
    pub set_distance_to_board_adjusted_for_velocity: bool,
    pub trick_lockout_seconds: f32,
}

pub const LANDING_ENTRY_PLAN: LandingEntryPlan = LandingEntryPlan {
    create_playing_landing_attribute: true,
    augment_score_as_landing: true,
    mark_is_landing: true,
    force_physics_skateboard: true,
    attach_fakie_turn: true,
    set_landing_data: true,
    set_distance_to_board_adjusted_for_velocity: true,
    trick_lockout_seconds: LANDING_TRICK_LOCKOUT_SECONDS,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LandingTarget {
    Wipeout,
    Grinding,
    Trick,
    RidingIdle,
    Push,
    Anticipation,
    Sliding,
    UserDismount,
    OnBoard,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum TransitionBlend {
    Inherited,
    ChannelBlend {
        seconds: f32,
        use_channel_from_weights: bool,
    },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LandingTransition {
    pub target: LandingTarget,
    pub blend: TransitionBlend,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LandingTransitionSignals {
    /// Exact StateGraph `InParentStateForTime` input, supplied by the graph
    /// clock so this module does not invent update-order semantics.
    pub parent_state_time_seconds: f32,
    pub physics_wants_runout: Option<bool>,
    pub crouch_intent: bool,
    /// Target-state eligibility results are external because their target
    /// expressions live outside `Landing.xml`.
    pub grinding_target_eligible: bool,
    pub trick_target_eligible: bool,
    pub push_target_eligible: bool,
    pub anticipation_target_eligible: bool,
    pub sliding_target_eligible: bool,
    pub user_dismount_target_eligible: bool,
    pub absorb_land_attribute: Option<bool>,
    /// Result of retail `WillExpire InTime="0.1"`.
    pub animation_will_expire_within_point_one: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum LandingTransitionDecision {
    Stay,
    Take(LandingTransition),
    Unresolved(LandingUnresolved),
}

const CANDIDATE_GRINDING: u16 = 1 << 0;
const CANDIDATE_TRICK: u16 = 1 << 1;
const CANDIDATE_RIDING_IDLE: u16 = 1 << 2;
const CANDIDATE_PUSH: u16 = 1 << 3;
const CANDIDATE_ANTICIPATION: u16 = 1 << 4;
const CANDIDATE_SLIDING: u16 = 1 << 5;
const CANDIDATE_DISMOUNT: u16 = 1 << 6;
const CANDIDATE_ON_BOARD: u16 = 1 << 7;

/// Arbitrates explicit urgent priority and exact authored gates.
///
/// Retail XML does not assign relative priorities to the remaining parent and
/// child transitions. If more than one such target is externally eligible in
/// the same evaluation, this function reports the ambiguity instead of
/// inventing a document-order rule.
pub fn arbitrate_landing_transition(
    quality: LandingQuality,
    signals: LandingTransitionSignals,
) -> LandingTransitionDecision {
    match signals.physics_wants_runout {
        Some(true) => {
            return LandingTransitionDecision::Take(LandingTransition {
                target: LandingTarget::Wipeout,
                blend: TransitionBlend::Inherited,
            });
        }
        Some(false) => {}
        None => {
            return LandingTransitionDecision::Unresolved(
                LandingUnresolved::PhysicsWantsRunoutProviderRequired,
            );
        }
    }

    let mut candidates = 0_u16;
    let mut selected = None;
    let mut add = |mask, transition| {
        candidates |= mask;
        selected = Some(transition);
    };

    if signals.crouch_intent
        && signals.parent_state_time_seconds > quality.crouch_exit_gate_seconds()
    {
        add(
            CANDIDATE_RIDING_IDLE,
            LandingTransition {
                target: LandingTarget::RidingIdle,
                blend: TransitionBlend::ChannelBlend {
                    seconds: 1.0,
                    use_channel_from_weights: true,
                },
            },
        );
    }
    if signals.grinding_target_eligible {
        add(
            CANDIDATE_GRINDING,
            LandingTransition {
                target: LandingTarget::Grinding,
                blend: TransitionBlend::Inherited,
            },
        );
    }
    if signals.trick_target_eligible {
        add(
            CANDIDATE_TRICK,
            LandingTransition {
                target: LandingTarget::Trick,
                blend: TransitionBlend::Inherited,
            },
        );
    }
    if signals.push_target_eligible
        && signals.parent_state_time_seconds > PUSH_AND_DISMOUNT_GATE_SECONDS
    {
        add(
            CANDIDATE_PUSH,
            LandingTransition {
                target: LandingTarget::Push,
                blend: TransitionBlend::ChannelBlend {
                    seconds: 1.0,
                    use_channel_from_weights: true,
                },
            },
        );
    }
    if signals.anticipation_target_eligible {
        match signals.absorb_land_attribute {
            Some(false) => add(
                CANDIDATE_ANTICIPATION,
                LandingTransition {
                    target: LandingTarget::Anticipation,
                    blend: TransitionBlend::ChannelBlend {
                        seconds: 0.8,
                        use_channel_from_weights: true,
                    },
                },
            ),
            Some(true) => {}
            None => {
                return LandingTransitionDecision::Unresolved(
                    LandingUnresolved::AbsorbLandAttributeRequired,
                );
            }
        }
    }
    if signals.sliding_target_eligible {
        add(
            CANDIDATE_SLIDING,
            LandingTransition {
                target: LandingTarget::Sliding,
                blend: TransitionBlend::ChannelBlend {
                    seconds: 0.5,
                    use_channel_from_weights: true,
                },
            },
        );
    }
    if signals.user_dismount_target_eligible
        && signals.parent_state_time_seconds > PUSH_AND_DISMOUNT_GATE_SECONDS
    {
        add(
            CANDIDATE_DISMOUNT,
            LandingTransition {
                target: LandingTarget::UserDismount,
                blend: TransitionBlend::Inherited,
            },
        );
    }
    if signals.animation_will_expire_within_point_one {
        add(
            CANDIDATE_ON_BOARD,
            LandingTransition {
                target: LandingTarget::OnBoard,
                blend: TransitionBlend::Inherited,
            },
        );
    }

    if candidates == 0 {
        LandingTransitionDecision::Stay
    } else if candidates.count_ones() == 1 {
        LandingTransitionDecision::Take(selected.expect("one candidate has a transition"))
    } else {
        LandingTransitionDecision::Unresolved(
            LandingUnresolved::CompetingDefaultPriorityTransitions {
                candidate_mask: candidates,
            },
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LandingOnBoardAnimationPlan {
    pub virtual_resource: &'static str,
    pub blend_seconds: f32,
    pub transition_under: bool,
    pub set_blend_from: &'static str,
    pub set_blend_attribute: &'static str,
}

pub const LANDING_ON_BOARD_ANIMATION_PLAN: LandingOnBoardAnimationPlan =
    LandingOnBoardAnimationPlan {
        virtual_resource: "B_AIR_CYC",
        blend_seconds: 0.2,
        transition_under: true,
        set_blend_from: "lastAnim",
        set_blend_attribute: "disttocog",
    };

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PrelandEntry {
    EnterLandingOnBoard,
    NotEligible,
    Unresolved(LandingUnresolved),
}

/// Exact `LandingOnBoard` precondition:
/// `CanLandOnBoard && OBTimeToLand > 0.05`.
pub fn arbitrate_preland_entry(
    can_land_on_board: Option<bool>,
    ob_time_to_land_seconds: Option<f32>,
) -> PrelandEntry {
    match can_land_on_board {
        Some(false) => PrelandEntry::NotEligible,
        None => PrelandEntry::Unresolved(LandingUnresolved::CanLandOnBoardProviderRequired),
        Some(true) => match ob_time_to_land_seconds {
            Some(time) if time > PRELAND_TIME_TO_LAND_SECONDS => PrelandEntry::EnterLandingOnBoard,
            Some(_) => PrelandEntry::NotEligible,
            None => PrelandEntry::Unresolved(LandingUnresolved::TimeToLandProviderRequired),
        },
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PrelandTransition {
    Stay,
    Land,
    Wipeout,
    Unresolved(LandingUnresolved),
}

/// Arbitration while the non-interruptible `LandingOnBoard` state is active.
///
/// Losing `CanLandOnBoard` is the authored high-priority wipeout. The target
/// `Land` expression is evaluated externally.
pub fn arbitrate_preland_transition(
    can_land_on_board: Option<bool>,
    land_target_eligible: Option<bool>,
) -> PrelandTransition {
    match can_land_on_board {
        Some(false) => PrelandTransition::Wipeout,
        None => PrelandTransition::Unresolved(LandingUnresolved::CanLandOnBoardProviderRequired),
        Some(true) => match land_target_eligible {
            Some(true) => PrelandTransition::Land,
            Some(false) => PrelandTransition::Stay,
            None => PrelandTransition::Unresolved(LandingUnresolved::LandTargetEvaluationRequired),
        },
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct LandingRuntime {
    pub quality: LandingQuality,
    pub elapsed_seconds: f32,
}

impl LandingRuntime {
    pub const fn begin(quality: LandingQuality) -> Self {
        Self {
            quality,
            elapsed_seconds: 0.0,
        }
    }

    pub fn advance(&mut self, delta_seconds: f32) {
        self.elapsed_seconds += delta_seconds.max(0.0);
    }

    pub fn tricks_allowed(&self) -> bool {
        self.elapsed_seconds >= LANDING_TRICK_LOCKOUT_SECONDS
    }

    pub const fn animation_plan(&self) -> LandingAnimationPlan {
        self.quality.animation_plan()
    }

    pub fn validate_external_variant(
        &self,
        selected_variant: Option<u8>,
    ) -> Result<Option<u8>, LandingUnresolved> {
        match self.animation_plan().variant_selection {
            LandingVariantSelection::None => Ok(None),
            LandingVariantSelection::ExternalRetailSelection { variant_count } => {
                let Some(variant) = selected_variant else {
                    return Err(LandingUnresolved::RandomVariantSelectionRequired {
                        variant_count,
                    });
                };
                if variant >= variant_count {
                    return Err(LandingUnresolved::RandomVariantOutOfRange {
                        variant,
                        variant_count,
                    });
                }
                Ok(Some(variant))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn transition_signals(time: f32) -> LandingTransitionSignals {
        LandingTransitionSignals {
            parent_state_time_seconds: time,
            physics_wants_runout: Some(false),
            ..LandingTransitionSignals::default()
        }
    }

    #[test]
    fn retail_landing_type_codes_and_default_child_are_exact() {
        assert_eq!(
            classify_landing(Some(LandingTypeCode::SPIN)),
            Ok(LandingQuality::Spin)
        );
        assert_eq!(
            classify_landing(Some(LandingTypeCode::SKETCHY)),
            Ok(LandingQuality::Sketchy)
        );
        assert_eq!(
            classify_landing(Some(LandingTypeCode::STRAIGHT)),
            Ok(LandingQuality::Straight)
        );
        assert_eq!(
            classify_landing(Some(LandingTypeCode(99))),
            Ok(LandingQuality::Straight)
        );
        assert_eq!(
            classify_landing(None),
            Err(LandingUnresolved::LandingTypeProviderRequired)
        );
    }

    #[test]
    fn provider_observations_remain_authoritative_when_supplied() {
        let baseline = LandingDecisionInput {
            filtered_state: FilteredPhysicsState::Ground,
            approach_speed_metres_per_second: 4.0,
            board_velocity_heading_delta_radians: Some(0.0),
            completed_rotation_radians: 0.0,
            tilt_too_large_for_preland: Some(false),
            physics_wants_runout: Some(false),
            provider_code: Some(LandingTypeCode::SKETCHY),
        };
        let wildly_different = LandingDecisionInput {
            approach_speed_metres_per_second: 40.0,
            board_velocity_heading_delta_radians: Some(2.7),
            completed_rotation_radians: 8.0,
            ..baseline
        };
        assert_eq!(
            classify_landing_decision(baseline).unwrap().quality,
            LandingQuality::Sketchy
        );
        assert_eq!(
            classify_landing_decision(wildly_different).unwrap().quality,
            LandingQuality::Sketchy
        );
        assert_eq!(
            classify_landing_decision(LandingDecisionInput {
                provider_code: None,
                ..baseline
            }),
            Err(LandingUnresolved::LandingTypeProviderRequired)
        );
    }

    #[test]
    fn retail_classifier_keeps_forward_and_low_speed_landings_straight() {
        let forward = classify_retail_landing_kinematics(RetailLandingClassifierInput {
            approach_speed_metres_per_second: 4.0,
            heading_delta_radians: Some(0.0),
            completed_rotation_radians: 0.0,
            orientation_reversed: false,
        });
        assert_eq!(forward.provider_code, LandingTypeCode::STRAIGHT);
        assert_eq!(forward.signed_error, 0.0);

        let low_speed = classify_retail_landing_kinematics(RetailLandingClassifierInput {
            approach_speed_metres_per_second: 1.999,
            heading_delta_radians: Some(0.75),
            completed_rotation_radians: 0.6,
            orientation_reversed: false,
        });
        assert_eq!(low_speed.provider_code, LandingTypeCode::STRAIGHT);
        assert_eq!(low_speed.error, 0.0);
        assert!(low_speed.raw_lateral_speed > 0.0);
    }

    #[test]
    fn retail_classifier_distinguishes_mild_sketchy_and_completed_spin_routes() {
        let mild = classify_retail_landing_kinematics(RetailLandingClassifierInput {
            approach_speed_metres_per_second: 4.0,
            heading_delta_radians: Some(0.1_f32.asin()),
            completed_rotation_radians: 0.0,
            orientation_reversed: false,
        });
        assert_eq!(mild.provider_code, LandingTypeCode::MILD_OFF_AXIS);
        assert_eq!(
            LandingQuality::from_provider_code(mild.provider_code),
            LandingQuality::Straight
        );

        let sketchy = classify_retail_landing_kinematics(RetailLandingClassifierInput {
            approach_speed_metres_per_second: 4.0,
            heading_delta_radians: Some(0.5),
            completed_rotation_radians: 0.0,
            orientation_reversed: false,
        });
        assert_eq!(sketchy.provider_code, LandingTypeCode::SKETCHY);

        let completed_backside = classify_retail_landing_kinematics(RetailLandingClassifierInput {
            approach_speed_metres_per_second: 4.0,
            heading_delta_radians: Some(-0.5),
            completed_rotation_radians: 0.5,
            orientation_reversed: false,
        });
        assert_eq!(completed_backside.provider_code, LandingTypeCode::SPIN);
        assert!(completed_backside.signed_error > 0.0);

        let opposed_rotation = classify_retail_landing_kinematics(RetailLandingClassifierInput {
            heading_delta_radians: Some(0.5),
            ..RetailLandingClassifierInput {
                approach_speed_metres_per_second: 4.0,
                heading_delta_radians: None,
                completed_rotation_radians: 0.5,
                orientation_reversed: false,
            }
        });
        assert_eq!(opposed_rotation.provider_code, LandingTypeCode::SKETCHY);
    }

    #[test]
    fn retail_classifier_boundaries_use_native_strict_comparisons() {
        let at_straight_gate = classify_retail_landing_kinematics(RetailLandingClassifierInput {
            approach_speed_metres_per_second: 4.0,
            heading_delta_radians: Some(RETAIL_LANDING_HEADING_STRAIGHT.asin()),
            completed_rotation_radians: 0.0,
            orientation_reversed: false,
        });
        assert_eq!(
            at_straight_gate.provider_code,
            LandingTypeCode::MILD_OFF_AXIS
        );

        let at_mild_gate = classify_retail_landing_kinematics(RetailLandingClassifierInput {
            heading_delta_radians: Some(RETAIL_LANDING_HEADING_MILD.asin()),
            ..RetailLandingClassifierInput {
                approach_speed_metres_per_second: 4.0,
                heading_delta_radians: None,
                completed_rotation_radians: 0.0,
                orientation_reversed: false,
            }
        });
        assert_eq!(at_mild_gate.provider_code, LandingTypeCode::SKETCHY);

        let at_speed_gate = classify_retail_landing_kinematics(RetailLandingClassifierInput {
            approach_speed_metres_per_second: RETAIL_LANDING_MINIMUM_SPEED,
            heading_delta_radians: Some(0.5),
            completed_rotation_radians: 0.0,
            orientation_reversed: false,
        });
        assert_eq!(at_speed_gate.provider_code, LandingTypeCode::SKETCHY);
    }

    #[test]
    fn land_admission_uses_provider_predicates_without_angle_guesses() {
        assert_eq!(
            arbitrate_landing_admission(
                FilteredPhysicsState::Air,
                Some(false),
                Some(false),
                Some(LandingTypeCode::STRAIGHT),
            ),
            LandingAdmission::NotEligible(LandingNotEligible::FilteredStateIsNotGround)
        );
        assert_eq!(
            arbitrate_landing_admission(
                FilteredPhysicsState::Ground,
                Some(true),
                Some(false),
                Some(LandingTypeCode::STRAIGHT),
            ),
            LandingAdmission::NotEligible(LandingNotEligible::TiltTooLargeForPreland)
        );
        assert_eq!(
            arbitrate_landing_admission(
                FilteredPhysicsState::Ground,
                None,
                Some(false),
                Some(LandingTypeCode::STRAIGHT),
            ),
            LandingAdmission::Unresolved(LandingUnresolved::TiltTooLargeProviderRequired)
        );
    }

    #[test]
    fn runout_is_the_explicit_urgent_wipeout_route() {
        assert_eq!(
            arbitrate_landing_admission(
                FilteredPhysicsState::Ground,
                Some(false),
                Some(true),
                Some(LandingTypeCode::SPIN),
            ),
            LandingAdmission::Wipeout
        );

        let mut signals = transition_signals(0.0);
        signals.physics_wants_runout = Some(true);
        signals.grinding_target_eligible = true;
        assert_eq!(
            arbitrate_landing_transition(LandingQuality::Straight, signals),
            LandingTransitionDecision::Take(LandingTransition {
                target: LandingTarget::Wipeout,
                blend: TransitionBlend::Inherited,
            })
        );
    }

    #[test]
    fn animation_resources_blends_and_variant_counts_match_landing_xml() {
        let spin = LandingQuality::Spin.animation_plan();
        assert_eq!(spin.virtual_resource, "B_LAND_NICE");
        assert_eq!(spin.blend_seconds, 0.15);
        assert_eq!(spin.variant_selection, LandingVariantSelection::None);

        let sketchy = LandingQuality::Sketchy.animation_plan();
        assert_eq!(sketchy.virtual_resource, "B_LAND_SKETCH");
        assert_eq!(
            sketchy.variant_selection,
            LandingVariantSelection::ExternalRetailSelection { variant_count: 5 }
        );

        let straight = LandingQuality::Straight.animation_plan();
        assert_eq!(straight.virtual_resource, "BLEND_LAND");
        assert_eq!(
            straight.variant_selection,
            LandingVariantSelection::ExternalRetailSelection { variant_count: 3 }
        );
    }

    #[test]
    fn crouch_exit_thresholds_are_strict_greater_than() {
        for (quality, gate) in [
            (LandingQuality::Straight, 0.2),
            (LandingQuality::Spin, 0.3),
            (LandingQuality::Sketchy, 0.4),
        ] {
            let mut at = transition_signals(gate);
            at.crouch_intent = true;
            assert_eq!(
                arbitrate_landing_transition(quality, at),
                LandingTransitionDecision::Stay
            );

            let mut above = at;
            above.parent_state_time_seconds += 0.000_1;
            assert_eq!(
                arbitrate_landing_transition(quality, above),
                LandingTransitionDecision::Take(LandingTransition {
                    target: LandingTarget::RidingIdle,
                    blend: TransitionBlend::ChannelBlend {
                        seconds: 1.0,
                        use_channel_from_weights: true,
                    },
                })
            );
        }
    }

    #[test]
    fn push_and_dismount_share_the_strict_point_one_gate() {
        let mut push = transition_signals(0.1);
        push.push_target_eligible = true;
        assert_eq!(
            arbitrate_landing_transition(LandingQuality::Straight, push),
            LandingTransitionDecision::Stay
        );
        push.parent_state_time_seconds = 0.100_1;
        assert!(matches!(
            arbitrate_landing_transition(LandingQuality::Straight, push),
            LandingTransitionDecision::Take(LandingTransition {
                target: LandingTarget::Push,
                ..
            })
        ));

        let mut dismount = transition_signals(0.100_1);
        dismount.user_dismount_target_eligible = true;
        assert!(matches!(
            arbitrate_landing_transition(LandingQuality::Straight, dismount),
            LandingTransitionDecision::Take(LandingTransition {
                target: LandingTarget::UserDismount,
                ..
            })
        ));
    }

    #[test]
    fn absorb_land_blocks_anticipation_and_missing_attribute_stays_unresolved() {
        let mut signals = transition_signals(0.0);
        signals.anticipation_target_eligible = true;
        signals.absorb_land_attribute = Some(true);
        assert_eq!(
            arbitrate_landing_transition(LandingQuality::Straight, signals),
            LandingTransitionDecision::Stay
        );

        signals.absorb_land_attribute = Some(false);
        assert!(matches!(
            arbitrate_landing_transition(LandingQuality::Straight, signals),
            LandingTransitionDecision::Take(LandingTransition {
                target: LandingTarget::Anticipation,
                blend: TransitionBlend::ChannelBlend { seconds: 0.8, .. },
            })
        ));

        signals.absorb_land_attribute = None;
        assert_eq!(
            arbitrate_landing_transition(LandingQuality::Straight, signals),
            LandingTransitionDecision::Unresolved(LandingUnresolved::AbsorbLandAttributeRequired)
        );
    }

    #[test]
    fn unproven_same_priority_ties_are_reported_not_ordered() {
        let mut signals = transition_signals(1.0);
        signals.grinding_target_eligible = true;
        signals.trick_target_eligible = true;
        assert_eq!(
            arbitrate_landing_transition(LandingQuality::Spin, signals),
            LandingTransitionDecision::Unresolved(
                LandingUnresolved::CompetingDefaultPriorityTransitions {
                    candidate_mask: CANDIDATE_GRINDING | CANDIDATE_TRICK,
                }
            )
        );
    }

    #[test]
    fn preland_time_gate_is_strict_and_loss_of_acceptance_wipes_out() {
        assert_eq!(
            arbitrate_preland_entry(Some(true), Some(0.05)),
            PrelandEntry::NotEligible
        );
        assert_eq!(
            arbitrate_preland_entry(Some(true), Some(0.050_1)),
            PrelandEntry::EnterLandingOnBoard
        );
        assert_eq!(
            arbitrate_preland_transition(Some(false), Some(true)),
            PrelandTransition::Wipeout
        );
        assert_eq!(
            arbitrate_preland_transition(Some(true), Some(true)),
            PrelandTransition::Land
        );
    }

    #[test]
    fn landing_on_board_default_animation_plan_is_exact() {
        assert_eq!(
            LANDING_ON_BOARD_ANIMATION_PLAN,
            LandingOnBoardAnimationPlan {
                virtual_resource: "B_AIR_CYC",
                blend_seconds: 0.2,
                transition_under: true,
                set_blend_from: "lastAnim",
                set_blend_attribute: "disttocog",
            }
        );
    }

    #[test]
    fn lockout_is_partition_invariant_and_exactly_point_three() {
        let mut fine = LandingRuntime::begin(LandingQuality::Straight);
        let mut coarse = fine.clone();
        for _ in 0..36 {
            fine.advance(1.0 / 120.0);
        }
        coarse.advance(0.3);
        assert!((fine.elapsed_seconds - coarse.elapsed_seconds).abs() < 1.0e-6);
        assert!(fine.tricks_allowed());
        assert!(coarse.tricks_allowed());
    }

    #[test]
    fn recovered_random_provider_reproduces_the_fresh_harness_sequence() {
        let mut random = RetailLandingRandom::FIRST_FLAT_OLLIE_CAPTURE;
        assert_eq!(random.choose_variant(3), 2);
        assert_eq!(random.words[0], 1_436_176_877);
        assert_eq!(random.calls, 1);
        assert_eq!(
            (0..5).map(|_| random.choose_variant(3)).collect::<Vec<_>>(),
            vec![1, 0, 1, 2, 2]
        );
        assert_eq!(random.calls, 6);
    }

    #[test]
    fn externally_synchronized_random_variant_is_still_range_checked() {
        let straight = LandingRuntime::begin(LandingQuality::Straight);
        assert_eq!(
            straight.validate_external_variant(None),
            Err(LandingUnresolved::RandomVariantSelectionRequired { variant_count: 3 })
        );
        assert_eq!(straight.validate_external_variant(Some(2)), Ok(Some(2)));
        assert_eq!(
            straight.validate_external_variant(Some(3)),
            Err(LandingUnresolved::RandomVariantOutOfRange {
                variant: 3,
                variant_count: 3,
            })
        );

        let spin = LandingRuntime::begin(LandingQuality::Spin);
        assert_eq!(spin.validate_external_variant(Some(4)), Ok(None));
    }
}
