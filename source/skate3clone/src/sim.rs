use std::{collections::VecDeque, sync::OnceLock};

use bevy::prelude::*;
use serde::Deserialize;

use crate::air_trick_animation::{
    AirTrickAnimationAdapterRequest, AirTrickAnimationFailure, adapt_air_trick_for_bevy,
};
use crate::air_trick_graph::{
    AirTrick, AirTrickFamily, AirTrickPhase, AirTrickRuntime, AirTrickSignals,
    StepOutcome as AirTrickStepOutcome, TrickEntry as AirTrickEntry, TrickHeight as AirTrickHeight,
    WILL_EXPIRE_WINDOW_SECONDS,
};
use crate::anticipation_graph::{
    AnticipationAnimationState, AnticipationPhase, AnticipationRuntime, andale_endpoint_weight,
    anticipation_side,
};
use crate::basic_trick_graph::{
    BasicTrickKind, BasicTrickPhase, BasicTrickRuntime, BasicTrickSignals,
    LandingAnimationResource, TrickHeightEndpoint,
};
use crate::board_authority::BoardAuthority;
use crate::contact_friction::{
    BoardContactState, ContactFrictionInput, ContactFrictionOutput, integrate_contact_friction,
};
use crate::fakie::{FakieRuntime, FakieStepEvent, TrickApproach};
use crate::foot_placement::{
    FootPlacementCoordinator, FootPlacementError, FootPlacementFrame, FootPlacementOutput,
};
use crate::grab_animation::{
    GrabAnimationFailure, GrabAnimationParameters, grab_clip_duration_seconds,
};
use crate::grab_graph::{
    BasicGrabInput, GrabDomain, GrabFootRelease, GrabIdentity, GrabPhase, GrabRuntime, GrabSignals,
    GrabTrick, GrabTweakDirection, PhysicalGrabHands, board_adjust_direction, select_full_grab,
};
use crate::grind_chromosome::{
    ClassificationError as GrindClassificationError, ClassificationResult as GrindClassification,
    EnumValueError as GrindEnumValueError, GrindChromosome, classify as classify_grind,
};
use crate::grind_contact::{
    ChromosomeAssemblyError, ChromosomeProviderValues, assemble_raw_chromosome,
};
use crate::grind_graph::{
    GrindBoardAuthority, GrindPhase, GrindRuntime, GrindSelection, GrindSignals, GrindTemplate,
    UnknownCanonicalGrind,
};
use crate::ground_provider::{GroundProvider, GroundVec3, SurfaceId};
use crate::landing_animation::{
    LandingLeafUnresolved, LandingTreeParameters, NonStraightLandingAxes, resolve_landing_tree,
    resolve_non_straight_landing,
};
use crate::landing_graph::{
    FilteredPhysicsState, LANDING_WILL_EXPIRE_WINDOW_SECONDS, LandingAdmission,
    LandingDecisionInput, LandingQuality, LandingRuntime, LandingTarget, LandingTransitionDecision,
    LandingTransitionSignals, LandingTypeCode, LandingUnresolved, RetailLandingClassifierInput,
    RetailLandingRandom, TransitionBlend, arbitrate_landing_admission,
    arbitrate_landing_transition, classify_retail_landing_kinematics,
};
use crate::manual_animation::{
    BevyManualAnimation, ManualAnimationAdapterRequest, ManualAnimationFailure,
    ManualAnimationParameters, RETAIL_NEUTRAL_RIDING_DIST_TO_COG, adapt_manual_for_bevy,
    manual_visual_duration_seconds, manual_visual_repeats, resolve_manual_visual_tree,
};
use crate::manual_balance::{
    InputError as ManualBalanceInputError, ManualBalanceConditioner, ManualBalanceConfig,
    ManualBalanceStep, TU3_MANUAL_OUT_TIMER_SECONDS,
};
use crate::manual_contact::{ManualDeckContact, apply_manual_deck_drag, project_manual_deck};
use crate::manual_control::{ManualControlState, ManualControlStep};
use crate::manual_graph::{
    ManualEntryContext, ManualKind, ManualPhase, ManualRuntime, ManualSignals,
    requested_manual_kind,
};
use crate::offboard::{OffboardControl, OffboardRuntime};
use crate::offboard_animation::{
    OffboardAnimationAdapterRequest, OffboardAnimationParameters, adapt_offboard_for_bevy,
};
use crate::retail_push::{
    MONGO_PUSH_ATTRIBUTES, PushAttributes, PushTreeCoefficients, REGULAR_PUSH_ATTRIBUTES,
    compute_target_coefficients,
};
use crate::retail_skateboard::{
    CAPTURED_CANDIDATE_SIDE_MINIMUM, CAPTURED_CARVE_CURVATURE,
    CAPTURED_SLIDE_OUT_YAW_RESPONSE_SECONDS, CAPTURED_SLIDE_YAW_RESPONSE_SECONDS,
    active_slide_intent, board_basis, candidate_slide_weight, captured_slide_yaw_rate,
    local_velocity, rolling_turn_axis, should_leave_active_slide, slide_decel_target,
    stance_local_slide_stick,
};
use crate::riding_forces::{
    BodyTiltFrameEvidence, BodyTiltOutput, BodyTiltState, BodyTiltStepError, ForceQueueCompletion,
    PostPhysicsBranchInput, PostPhysicsPlan, SkateboardForce, SkateboardForceQueue,
    complete_force_queue, plan_post_physics,
};
use crate::skateboard_body::{
    BODY_COUNT, BodyPoseSet, PoseAuthority, PostPhysicsInput, PostPhysicsOutput,
    SkateboardBodyState, Vector3 as SkateboardVector3, WheelContact,
};
use crate::skateboard_solver::{
    BodyContactChannel, ContactBridgeInput, ContactBridgeOutput, ContactRecord, SolverError,
    WheelBridgeInput, bridge_post_physics,
};
use crate::stance::{MirrorState, NaturalStance, RidingStance};
#[cfg(test)]
use crate::transition::build_transition_ground;
use crate::transition::{TransitionPhase, TransitionRuntime, TransitionStepInput};
use crate::trick_animation::{
    StraightLandingParameters, TrickAnimationParameters, UnresolvedTrickAnimation,
    adapt_basic_trick_request,
};
use crate::trick_catalog::{AnticipationSide, LandingPosture, LandingVariant};
use crate::trick_input::{
    AnticipationClassification, AnticipationIdentity, AnticipationSignal, MatcherMode, PatternId,
    PopRecognition, RawStickSample, RecognitionFrame, RetailConfiguredRecognitionFrame,
    SelectedPatternContact, Stick2, TrickInputRecognizer, classify_anticipation,
    filter_recognizer_components, normalize_raw_axis_pair, raw_right_stick_to_pattern_node,
    resolve_trick_identity, square_identity_for_gesture,
};

pub const FIXED_HZ: f64 = 120.0;
pub const MAX_SPEED: f32 = 12.5;

const ANTICIPATION_TO_TRICK_BLEND_SECONDS: f32 = 0.05;
// MotionGraphIncludes/ground.xml applies this override on every Push ->
// Anticipation transition. The two dedicated mongo bridge clips contain 13
// samples at 60 Hz, exactly spanning the same 0.2-second interval.
const PUSH_TO_ANTICIPATION_BLEND_SECONDS: f32 = 0.2;
const MONGO_PUSH_TO_ANTIC_CLIP: &str = "MONGO_PUSH_TO_ANTIC";
const MONGO_PUSH_TO_NANTIC_CLIP: &str = "MONGO_PUSH_TO_NANTIC";
const RETAIL_OLLIE_CARRIER_JSON: &str =
    include_str!("../research/fixtures/retail_ollie_carriers.json");

// Runtime projection traces captured from sub_82BAFFF0 for every observable
// integer anticipation hold from 2 through 30 retail frames. Each row is:
// (hold frames, first mode-2 projection, maximum downward projection, updates).
// This signal is intentionally independent from the rendered board-origin
// carrier: retail obtains it from the auxiliary physics provider at actor+0x708.
const RETAIL_LANDING_PROJECTION_FIXTURES: [(f32, f32, f32, u8); 29] = [
    (2.0, 3.316_497_6, 3.868_102_8, 44),
    (3.0, 3.315_582, 3.837_432_6, 44),
    (4.0, 3.313_751, 3.860_778_6, 44),
    (5.0, 3.309_631, 3.665_771_2, 43),
    (6.0, 3.303_222_4, 3.681_793, 43),
    (7.0, 3.455_657_7, 3.756_408_5, 44),
    (8.0, 3.441_009_3, 3.768_768, 44),
    (9.0, 3.429_107_4, 3.779_754_4, 44),
    (10.0, 3.425_903, 3.588_867, 43),
    (11.0, 3.420_867_7, 3.600_768_8, 43),
    (12.0, 3.415_374_5, 3.773_803_5, 44),
    (13.0, 3.411_254_6, 3.584_747, 43),
    (14.0, 3.408_508, 3.768_310_3, 44),
    (15.0, 3.404_388_2, 3.740_844_5, 44),
    (16.0, 3.401_183_8, 3.717_040_8, 44),
    (17.0, 3.399_810_6, 3.713_378_7, 44),
    (18.0, 3.397_521_7, 3.714_752, 44),
    (19.0, 3.394_775_2, 3.716_583, 44),
    (20.0, 3.394_317_4, 3.716_583, 44),
    (21.0, 3.394_775_2, 3.717_040_8, 44),
    (22.0, 3.393_401_9, 3.717_040_8, 44),
    (23.0, 3.393_859_6, 3.716_125_2, 44),
    (24.0, 3.391_570_8, 3.715_667_5, 44),
    (25.0, 3.392_944, 3.715_667_5, 44),
    (26.0, 3.392_486_3, 3.715_667_5, 44),
    (27.0, 3.393_401_9, 3.715_667_5, 44),
    (28.0, 3.392_944, 3.715_209_7, 44),
    (29.0, 3.393_859_6, 3.716_125_2, 44),
    (30.0, 3.392_486_3, 3.715_667_5, 44),
];

// PhysOut_Animation +72 at each SetLandingData call in the synchronized
// 2..30-frame retail charge sweep. SetLandingData copies this independent
// provider field to the authored DISTTOCOG animation attribute.
const RETAIL_LANDING_DISTANCE_TO_COG_FIXTURES: [(f32, f32); 29] = [
    (2.0, 0.865_234_4),
    (3.0, 0.862_625_1),
    (4.0, 0.863_174_44),
    (5.0, 0.920_837_4),
    (6.0, 0.920_074_46),
    (7.0, 0.917_373_66),
    (8.0, 0.914_947_5),
    (9.0, 0.913_146_97),
    (10.0, 0.967_353_8),
    (11.0, 0.966_957_1),
    (12.0, 0.907_753),
    (13.0, 0.963_912_96),
    (14.0, 0.907_844_54),
    (15.0, 0.907_882_7),
    (16.0, 0.908_485_4),
    (17.0, 0.908_744_8),
    (18.0, 0.908_905),
    (19.0, 0.909_004_2),
    (20.0, 0.909_126_3),
    (21.0, 0.909_133_9),
    (22.0, 0.909_225_46),
    (23.0, 0.909_278_87),
    (24.0, 0.909_263_6),
    (25.0, 0.909_317),
    (26.0, 0.909_301_76),
    (27.0, 0.909_271_24),
    (28.0, 0.909_324_65),
    (29.0, 0.909_301_76),
    (30.0, 0.909_324_65),
];

// Runtime-oracle constants measured from the TU3 retail harness. Push motion
// is phase driven instead of applying one instantaneous impulse when the
// state starts. ComputeFirstPushStrength (TU3 0x82BAD7A8) separately retains
// the maximum held-button result and stops changing it after release.
const PUSH_SPEED_CAP: f32 = 8.50;
const PUSH_INTO_TRANSITION_SECONDS: f32 = 0.3;
const PUSH_INTO_PROPULSION_START_SECONDS: f32 = 0.300;
const PUSH_INTO_PROPULSION_END_SECONDS: f32 = 0.483;
// The measured first-drive window came from the 31-sample, 60 Hz
// R_PUSHLSP_LSTR_MONGO_0_INTO leaf: (31 - 1) / 60 = 0.5 seconds.
// Shorter synchronized leaves retain that authored fractional window so
// WillExpire cannot cut their drive short.
const PUSH_REFERENCE_INTO_SOURCE_SECONDS: f32 = 0.500;
const PUSH_DRIVE_DELIVERY_PROFILE: [(f32, f32); 5] = [
    (0.00, 0.000),
    (0.14, 0.058),
    (0.50, 0.517),
    (0.86, 0.962),
    (1.00, 1.000),
];
// Live TU3 push-attribute payload recovered from the authorized retail
// runtime. sub_82BAD658 divides the NewPush intent by the speed graph, clamps
// the coordinate, and evaluates this output graph. These values are push
// delta velocity in m/s, not a normalized animation weight.
const PUSH_STRENGTH_OUTPUT_GRAPH: [(f32, f32); 8] = [
    (0.000_000_0, 0.750_000),
    (0.241_699_9, 1.044_643),
    (0.342_629_5, 1.430_357),
    (0.419_654_7, 2.041_071),
    (0.515_272_3, 2.523_214),
    (0.767_596_3, 2.973_214),
    (0.884_462_2, 3.503_571),
    (1.000_000_0, 4.500_000),
];
const PUSH_STRENGTH_NORMALIZER_GRAPH: [(f32, f32); 8] = [
    (0.000_000, 0.226_785_7),
    (0.323_932_9, 0.250_000_0),
    (1.038_274, 0.250_000_0),
    (2.878_486, 0.250_000_0),
    (4.616_866, 0.250_000_0),
    (5.553_785, 0.250_000_0),
    (6.671_315, 0.250_000_0),
    (8.477_424, 0.250_000_0),
];
// The synchronized one-, six-, and eighteen-frame rest captures settle on
// output-graph points 3, 6, and 8. Convert those observed coordinates back to
// NewPush intent with the recovered zero-speed normalizer. The final point is
// a linear continuation of the measured 6f..18f segment to the graph's
// moving-speed 0.25 normalizer; it affects only holds beyond the measured
// 0.3-second full-strength rest case.
const PUSH_HELD_INTENT_PROFILE: [(f32, f32); 5] = [
    (0.000_000_0, 0.095_171_68),
    (1.0 / 60.0, 0.095_171_68),
    (6.0 / 60.0, 0.174_079_87),
    (18.0 / 60.0, 0.226_785_70),
    (0.388_090_04, 0.250_000_00),
];
const BRAKE_LEAD_IN_SECONDS: f32 = 0.22;
const CARVE_TURN_RATE_MAXIMUM: f32 = 2.25;
const CARVE_TURN_RATE_MINIMUM: f32 = 0.42;
const CARVE_TURN_RATE_INTERCEPT: f32 = 3.08;
const CARVE_TURN_RATE_SPEED_SLOPE: f32 = 0.90;
const SLIDE_DECEL_SMOOTHING: f32 = 0.5;
const CARVE_YAW_RESPONSE_SECONDS: f32 = 0.135_631_81;

// Retail-oracle body-spin curve fitted from
// 20260815T234406836Z-sandbox-ollie-bodyspin-right-79b36609 and corroborated
// against PhysState_KnownAir::CalculateBodySpinSpeed (TU3 0x82D360B0).
const BODY_SPIN_INPUT_DEADZONE: f32 = 0.001;
const BODY_SPIN_ACCELERATION: f32 = 53.5;
const BODY_SPIN_INPUT_DAMPING: f32 = 2.35;
const BODY_SPIN_MAXIMUM_SPEED: f32 = 7.93;
const BODY_SPIN_RELEASE_DECELERATION: f32 = 12.0;
const BODY_SPIN_CLIP_DURATION_SECONDS: f32 = 55.0 / 60.0;
pub(crate) const BODY_SPIN_BACKSIDE_CLIP: &str = "IA_BODYSPIN_OLLIE_BS_0_N";
pub(crate) const BODY_SPIN_FRONTSIDE_CLIP: &str = "IA_BODYSPIN_OLLIE_FS_0_N";
/// The selected retail `CameraHigh` graph gives `low_ollie` a 0.5-second
/// transition out to `bl_high_chase`.
const HIGH_CAMERA_LOW_OLLIE_TRANSITION_OUT_SECONDS: f32 = 0.5;

// Full-stick physical board rates from synchronized held-through-touchdown
// takes:
// work/dual-ollie-left-stick-left-before-fix.csv
// work/dual-ollie-left-stick-right-held-through-landing-final.csv
//
// Each row is (normalized first-air-to-touchdown time, left-stick-left speed,
// left-stick-right speed). Retail's left ramp is measurably slower for the
// first three samples; both directions converge before the peak. The time
// filter then reduces the rate even while the raw stick remains held.
const OLLIE_HELD_BODY_SPIN_SPEED: &[(f32, f32, f32)] = &[
    (0.000_000, 0.000, 0.000),
    (0.069_767, 2.144, 2.944),
    (0.139_535, 4.921, 5.721),
    (0.209_302, 7.531, 7.612),
    (0.279_070, 7.790, 7.790),
    (0.348_837, 7.969, 7.969),
    (0.418_605, 7.878, 7.878),
    (0.488_372, 7.784, 7.784),
    (0.558_140, 7.690, 7.690),
    (0.627_907, 7.502, 7.502),
    (0.697_674, 7.308, 7.308),
    (0.767_442, 7.113, 7.113),
    (0.837_209, 6.918, 6.918),
    (0.906_977, 6.723, 6.723),
    (0.976_744, 6.555, 6.555),
    (1.000_000, 6.504, 6.504),
];

const INPUT_DEADZONE: f32 = 0.22;
// MotionGraphIncludes/GrabsTweaks/{T_FSBSGrab,T_MuteStaleGrab,DBLGrab}.xml.
// FilterMotionGraphIntent applies these as per-update response coefficients;
// the recovered update clamps the resulting output delta by clampVel.
const GRAB_TWEAK_FILTER_BLEND: f32 = 0.116;
const GRAB_TWEAK_FILTER_BLEND_OUT: f32 = 0.133;
const GRAB_TWEAK_FILTER_CLAMP_VELOCITY: f32 = 0.1;
const BOARD_ADJUST_FILTER_BLEND: f32 = 0.25;
const BOARD_ADJUST_FILTER_BLEND_OUT: f32 = 0.08;
const BOARD_ADJUST_FILTER_CLAMP_ACCELERATION: f32 = 0.03;
const BOARD_ADJUST_FILTER_CLAMP_VELOCITY: f32 = 0.2;
const LEFT_INPUT_DEADZONE: f32 = 0.22;
const RETAIL_RIGHT_STICK_DIVIDE_GUARD: f32 = f32::from_bits(0x3A83_126F);
const RETAIL_RIGHT_STICK_DEADZONE: f32 = f32::from_bits(0x3E80_0000);
const RETAIL_RIGHT_STICK_REMAP_GAIN: f32 = f32::from_bits(0x3FB6_DB6E);
const REPUSH_COOLDOWN: f32 = 0.34;
const MOVING_BRAKE_THRESHOLD: f32 = 0.15;
const RANDOM_IDLE_DELAY_SECONDS: f32 = 3.0;
const RETAIL_ANIMATION_HZ: f32 = 60.0;
const RETAIL_SLIDE_BRAKE_ANIMATION_HZ: f32 = 30.0;
const SEQUENCE_WILL_EXPIRE_SECONDS: f32 = 0.01;
const PUSH_OUT_WILL_EXPIRE_SECONDS: f32 = 0.1;
// Push.xml exits PushEnd at WillExpire 0.1 into Turning.Idle. The default
// Turning.Idle BTREE_RIDING behaviour authors a 0.2-second entry blend.
const PUSH_TO_RIDING_BLEND_SECONDS: f32 = 0.2;
const SLIDE_WILL_EXPIRE_SECONDS: f32 = 0.05;
const SLIDE_PARENT_LEAVE_GUARD_SECONDS: f32 = 0.3;
const SLIDE_INTO_BLEND_SECONDS: f32 = 0.2;
const SLIDE_CYCLE_BLEND_SECONDS: f32 = 0.1;
const SLIDE_OUT_BLEND_SECONDS: f32 = 0.2;
const SLIDE_TO_RIDING_BLEND_SECONDS: f32 = 0.2;
const BRAKE_OUT_WILL_EXPIRE_SECONDS: f32 = 0.1;
// The recovered retail palette follows R_IDLE_HCOM_000 from source frame 40
// at capture time zero (stable fits over six independent idle sub-windows).
const INITIAL_RIDE_PHASE_SECONDS: f32 = 40.0 / RETAIL_ANIMATION_HZ;
const RIDE_CLIP_DURATION_SECONDS: f32 = 100.0 / RETAIL_ANIMATION_HZ;

// Measured from the retail RX2 wheel geometry (63.8 mm diameter).
pub const WHEEL_RADIUS: f32 = 0.0319;

#[derive(Resource, Clone, Debug)]
pub struct SkateGround {
    pub provider: GroundProvider,
    pub transition_test: bool,
}

#[derive(Resource, Clone, Copy, Debug, Default)]
pub struct LevelSpawn {
    pub position: Vec3,
    pub yaw: f32,
}

impl Default for SkateGround {
    fn default() -> Self {
        Self::flat_parity()
    }
}

impl SkateGround {
    pub fn flat_parity() -> Self {
        let mut provider = GroundProvider::new();
        // Fixture surface corresponding to the existing shared flat parity
        // map. This is map data, not a claimed retail contact constant.
        provider
            .add_plane(GroundVec3::ZERO, GroundVec3::Y, SurfaceId(1))
            .expect("the built-in flat parity surface is valid");
        Self {
            provider,
            transition_test: false,
        }
    }

    #[cfg(test)]
    pub fn transition_test() -> Self {
        Self {
            provider: build_transition_ground(),
            transition_test: true,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct AnimationSample {
    pub clip: String,
    pub weight: f32,
    pub seek_time_seconds: f32,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ActionAnimationState {
    pub samples: Vec<AnimationSample>,
    pub weight: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ActionHandoff {
    pub source: ActionAnimationState,
    pub elapsed_seconds: f32,
    pub duration_seconds: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PushAnticipationHandoff {
    pub source: ActionAnimationState,
    pub bridge_clip: Option<&'static str>,
    pub elapsed_seconds: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct SkateboardOffsetTransition {
    from_reversal: f32,
    to_reversal: f32,
    elapsed_seconds: f32,
    duration_seconds: f32,
}

impl SkateboardOffsetTransition {
    fn weight(self) -> f32 {
        if self.duration_seconds <= f32::EPSILON {
            1.0
        } else {
            (self.elapsed_seconds / self.duration_seconds).clamp(0.0, 1.0)
        }
    }

    fn reversal(self) -> f32 {
        self.from_reversal + (self.to_reversal - self.from_reversal) * self.weight()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrickContext {
    pub name: String,
    pub approach: TrickApproach,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PushFoot {
    Regular,
    Mongo,
}

impl PushFoot {
    pub fn label(self) -> &'static str {
        match self {
            Self::Regular => "A / right-foot push",
            Self::Mongo => "X / left-foot push",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[allow(dead_code)] // Exported retail LSTR branch; no verified analogue selector yet.
pub enum PushStrength {
    Low,
    High,
}

impl PushStrength {
    fn code(self) -> &'static str {
        match self {
            Self::Low => "LSTR",
            Self::High => "HSTR",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpeedBand {
    Low,
    High,
}

impl SpeedBand {
    fn code(self) -> &'static str {
        match self {
            Self::Low => "LSP",
            Self::High => "HSP",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PushDirection {
    Left,
    Neutral,
    Right,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PushPhase {
    Into,
    Contact,
    Cycle,
    Out,
}

impl PushPhase {
    pub fn label(self) -> &'static str {
        match self {
            Self::Into => "push start",
            Self::Contact => "push contact",
            Self::Cycle => "push cycle",
            Self::Out => "push out",
        }
    }
}

#[derive(Clone, Debug)]
pub struct PushRuntime {
    pub foot: PushFoot,
    pub direction: PushDirection,
    pub turn_coefficient: f32,
    pub phase: PushPhase,
    pub phase_time: f32,
    pub phase_duration: f32,
    pub queued_repush: bool,
    pub hold_time: f32,
    pub strength: f32,
    pub strength_frozen: bool,
    pub queued_repush_hold_time: f32,
    pub queued_repush_strength: f32,
    pub queued_repush_strength_frozen: bool,
    pub repeat_count: u32,
    pub coefficients: PushTreeCoefficients,
    pub target_coefficients: PushTreeCoefficients,
    pub push_delta_velocity: f32,
    pub transition_from_samples: Vec<AnimationSample>,
    pub contact_start_speed: f32,
    pub contact_target_speed: f32,
    pub contact_propulsion_enabled: bool,
}

impl PushRuntime {
    fn new(foot: PushFoot, speed: f32, steer: f32) -> Self {
        // ComputeFirstPushStrength begins at zero and ramps while the INTO
        // animation's NewPush intent remains present. SetPushCoefs copies the
        // first valid target immediately, so the tree starts at the
        // duration-correct LSTR coordinate rather than an invented HSTR leaf.
        let coefficients = compute_target_coefficients(push_attributes(foot), speed, 0.0);
        let mut runtime = Self {
            foot,
            direction: direction_band(steer),
            turn_coefficient: 0.0,
            phase: PushPhase::Into,
            phase_time: 0.0,
            phase_duration: 0.0,
            queued_repush: false,
            hold_time: 0.0,
            strength: 0.0,
            strength_frozen: false,
            queued_repush_hold_time: 0.0,
            queued_repush_strength: 0.0,
            queued_repush_strength_frozen: false,
            repeat_count: 0,
            coefficients,
            target_coefficients: coefficients,
            push_delta_velocity: 0.0,
            transition_from_samples: Vec::new(),
            contact_start_speed: speed,
            contact_target_speed: speed,
            contact_propulsion_enabled: false,
        };
        runtime.phase_duration = runtime.retail_phase_duration();
        runtime
    }

    fn set_phase(&mut self, phase: PushPhase) {
        self.phase = phase;
        self.phase_time = 0.0;
        if phase != PushPhase::Out {
            self.transition_from_samples.clear();
        }
        self.phase_duration = self.retail_phase_duration();
        if phase == PushPhase::Contact {
            self.contact_start_speed = 0.0;
            self.contact_target_speed = 0.0;
            self.contact_propulsion_enabled = false;
        }
    }

    fn begin_out(&mut self) {
        let outgoing = self.animation_samples();
        self.set_phase(PushPhase::Out);
        self.transition_from_samples = outgoing;
    }

    fn queue_repush(&mut self) {
        if self.queued_repush {
            return;
        }
        self.queued_repush = true;
        self.queued_repush_hold_time = 0.0;
        self.queued_repush_strength = 0.0;
        self.queued_repush_strength_frozen = false;
    }

    fn charge_first_push(&mut self, dt: f32, held: bool) {
        if self.phase != PushPhase::Into || self.strength_frozen {
            return;
        }
        if held {
            self.hold_time += dt;
            self.strength = self.strength.max(push_strength_for_hold_time(
                self.hold_time,
                self.contact_start_speed,
            ));
            self.set_requested_delta(self.contact_start_speed, self.strength);
        } else {
            self.strength_frozen = true;
        }
    }

    fn charge_queued_repush(&mut self, dt: f32, held: bool, speed: f32) {
        if !self.queued_repush || self.queued_repush_strength_frozen {
            return;
        }
        if held {
            self.queued_repush_hold_time += dt;
            self.queued_repush_strength = self.queued_repush_strength.max(
                push_strength_for_hold_time(self.queued_repush_hold_time, speed),
            );
        } else {
            self.queued_repush_strength_frozen = true;
        }
    }

    fn set_requested_delta(&mut self, speed: f32, strength: f32) {
        self.push_delta_velocity = strength
            .clamp(0.0, PUSH_STRENGTH_OUTPUT_GRAPH[7].1)
            .min((PUSH_SPEED_CAP - speed).max(0.0));
        self.contact_target_speed = speed + self.push_delta_velocity;
    }

    pub fn animation_clip(&self) -> String {
        if self.phase == PushPhase::Out {
            let strength = if self.coefficients.velocity_end >= 0.5 {
                "H"
            } else {
                "L"
            };
            return match self.foot {
                // Retail's B_MONGO tree moves the right foot and B_PUSH moves
                // the left. The old port had these two source families
                // reversed for the controller actions.
                PushFoot::Regular => format!("R_PUSH_{strength}_M_N_OUT_MIDFRONT"),
                PushFoot::Mongo => format!("R_PUSH_{strength}_N_OUT_MIDFRONT"),
            };
        }

        self.weighted_clips()
            .into_iter()
            .max_by(|left, right| left.1.total_cmp(&right.1))
            .map(|(clip, _)| clip)
            .unwrap_or_else(|| {
                self.clip_for_direction(SpeedBand::Low, PushStrength::Low, PushDirection::Neutral)
            })
    }

    fn retail_phase_duration(&self) -> f32 {
        let source_duration = self.blended_source_duration()
            + if self.phase == PushPhase::Into {
                PUSH_INTO_TRANSITION_SECONDS
            } else {
                0.0
            };
        let will_expire = match self.phase {
            PushPhase::Into | PushPhase::Contact | PushPhase::Cycle => SEQUENCE_WILL_EXPIRE_SECONDS,
            PushPhase::Out => PUSH_OUT_WILL_EXPIRE_SECONDS,
        };
        (source_duration - will_expire).max(1.0 / FIXED_HZ as f32)
    }

    fn phase_code(&self) -> &'static str {
        match self.phase {
            PushPhase::Into => "INTO",
            PushPhase::Contact => "CYC1",
            PushPhase::Cycle => "CYC2",
            PushPhase::Out => unreachable!(),
        }
    }

    fn clip_for_direction(
        &self,
        speed: SpeedBand,
        strength: PushStrength,
        direction: PushDirection,
    ) -> String {
        if self.phase == PushPhase::Out {
            return self.animation_clip();
        }
        let pose = match (self.foot, direction) {
            (PushFoot::Regular, _) => "MONGO_0",
            (PushFoot::Mongo, PushDirection::Left) => "LEFT_0",
            (PushFoot::Mongo, PushDirection::Right) => "RIGHT_0",
            _ => "N_0",
        };
        format!(
            "R_PUSH{}_{}_{}_{}",
            speed.code(),
            strength.code(),
            pose,
            self.phase_code()
        )
    }

    fn direction_weights(&self) -> [(PushDirection, f32); 3] {
        if self.foot == PushFoot::Regular {
            return [
                (PushDirection::Left, 0.0),
                (PushDirection::Neutral, 1.0),
                (PushDirection::Right, 0.0),
            ];
        }
        let turn = self.turn_coefficient.clamp(-1.0, 1.0);
        [
            (PushDirection::Left, (-turn).max(0.0)),
            (PushDirection::Neutral, 1.0 - turn.abs()),
            (PushDirection::Right, turn.max(0.0)),
        ]
    }

    fn weighted_clips(&self) -> Vec<(String, f32)> {
        self.tree_leaf_weights()
            .into_iter()
            .flat_map(|(speed, strength, tree_weight)| {
                self.direction_weights()
                    .into_iter()
                    .map(move |(direction, direction_weight)| {
                        (
                            self.clip_for_direction(speed, strength, direction),
                            tree_weight * direction_weight,
                        )
                    })
            })
            .filter(|(_, weight)| *weight > 0.0001)
            .collect()
    }

    fn tree_leaf_weights(&self) -> [(SpeedBand, PushStrength, f32); 4] {
        let [
            low_speed_high_strength,
            high_speed_high_strength,
            low_speed_low_strength,
            high_speed_low_strength,
        ] = self.coefficients.leaf_weights();
        [
            (SpeedBand::Low, PushStrength::High, low_speed_high_strength),
            (
                SpeedBand::High,
                PushStrength::High,
                high_speed_high_strength,
            ),
            (SpeedBand::Low, PushStrength::Low, low_speed_low_strength),
            (SpeedBand::High, PushStrength::Low, high_speed_low_strength),
        ]
    }

    fn blended_source_duration(&self) -> f32 {
        if self.phase == PushPhase::Out {
            return source_clip_duration(push_source_clip_frames(&self.animation_clip()), 60.0);
        }
        self.weighted_clips()
            .into_iter()
            .map(|(clip, weight)| {
                source_clip_duration(push_source_clip_frames(&clip), RETAIL_ANIMATION_HZ) * weight
            })
            .sum()
    }

    pub fn animation_samples(&self) -> Vec<AnimationSample> {
        let source_phase_time = if self.phase == PushPhase::Into {
            (self.phase_time - PUSH_INTO_TRANSITION_SECONDS).max(0.0)
        } else {
            self.phase_time
        };
        let source_phase_duration = self.blended_source_duration();
        let phase_progress = if source_phase_duration > 0.0 {
            (source_phase_time / source_phase_duration).clamp(0.0, 1.0)
        } else {
            0.0
        };
        if self.phase == PushPhase::Out {
            let clip = self.animation_clip();
            let duration =
                source_clip_duration(push_source_clip_frames(&clip), RETAIL_ANIMATION_HZ);
            return vec![AnimationSample {
                clip,
                weight: 1.0,
                seek_time_seconds: phase_progress * duration,
            }];
        }

        self.weighted_clips()
            .into_iter()
            .map(|(clip, weight)| {
                let duration =
                    source_clip_duration(push_source_clip_frames(&clip), RETAIL_ANIMATION_HZ);
                AnimationSample {
                    clip,
                    weight,
                    seek_time_seconds: phase_progress * duration,
                }
            })
            .collect()
    }

    pub fn transition_samples(&self) -> Vec<AnimationSample> {
        if self.phase != PushPhase::Out || self.transition_from_samples.is_empty() {
            return self.animation_samples();
        }
        let blend = transition_in_weight(self.phase_time, 0.2);
        let mut samples = self
            .transition_from_samples
            .iter()
            .map(|sample| AnimationSample {
                clip: sample.clip.clone(),
                weight: sample.weight * (1.0 - blend),
                seek_time_seconds: sample.seek_time_seconds,
            })
            .collect::<Vec<_>>();
        samples.extend(self.animation_samples().into_iter().map(|mut sample| {
            sample.weight *= blend;
            sample
        }));
        samples
    }

    fn begin_contact_propulsion(&mut self, speed: f32, strength: f32) {
        // Retail keeps push effort in shared push state independently of the
        // speed-cap-limited velocity still available to the board. A repeated
        // held push therefore remains HSTR even when physical headroom is zero.
        self.strength = strength;
        self.strength_frozen = true;
        self.contact_start_speed = speed;
        self.set_requested_delta(speed, strength);
        self.contact_propulsion_enabled = true;
    }

    fn into_drive_source_window(&self) -> (f32, f32) {
        let source_duration = self.blended_source_duration();
        if source_duration >= PUSH_INTO_PROPULSION_END_SECONDS {
            return (
                PUSH_INTO_PROPULSION_START_SECONDS,
                PUSH_INTO_PROPULSION_END_SECONDS,
            );
        }

        let start = source_duration
            * (PUSH_INTO_PROPULSION_START_SECONDS / PUSH_REFERENCE_INTO_SOURCE_SECONDS);
        let authored_end = source_duration
            * (PUSH_INTO_PROPULSION_END_SECONDS / PUSH_REFERENCE_INTO_SOURCE_SECONDS);
        let will_expire_end = (source_duration - SEQUENCE_WILL_EXPIRE_SECONDS).max(start);
        (start, authored_end.min(will_expire_end))
    }

    pub fn drive_progress(&self) -> f32 {
        if !self.contact_propulsion_enabled {
            return 0.0;
        }
        match self.phase {
            PushPhase::Into => {
                let playback_time = (self.phase_time - PUSH_INTO_TRANSITION_SECONDS).max(0.0);
                let (drive_start, drive_end) = self.into_drive_source_window();
                ((playback_time - drive_start) / (drive_end - drive_start).max(f32::EPSILON))
                    .clamp(0.0, 1.0)
            }
            PushPhase::Contact => (self.phase_time / self.phase_duration).clamp(0.0, 1.0),
            PushPhase::Cycle | PushPhase::Out => 0.0,
        }
    }
}

fn push_strength_for_hold_time(hold_time: f32, speed: f32) -> f32 {
    let held_intent = sample_retail_point_graph(&PUSH_HELD_INTENT_PROFILE, hold_time);
    let normalizer = sample_retail_point_graph(&PUSH_STRENGTH_NORMALIZER_GRAPH, speed.abs());
    let coordinate = if normalizer > f32::EPSILON {
        held_intent / normalizer
    } else {
        1.0
    };
    sample_retail_point_graph(&PUSH_STRENGTH_OUTPUT_GRAPH, coordinate.clamp(0.0, 1.0))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BrakePhase {
    MovingInto,
    MovingCycle,
    MovingOut,
    StandInto,
    StandFromMoving,
    StandCycle,
    StandOut,
}

impl BrakePhase {
    fn label(self) -> &'static str {
        match self {
            Self::MovingInto => "brake start",
            Self::MovingCycle => "braking",
            Self::MovingOut => "brake out",
            Self::StandInto => "stand brake start",
            Self::StandFromMoving => "brake to stand",
            Self::StandCycle => "standing brake",
            Self::StandOut => "stand brake out",
        }
    }
}

#[derive(Clone, Debug)]
pub struct BrakeRuntime {
    pub phase: BrakePhase,
    pub phase_time: f32,
    pub phase_duration: f32,
}

impl BrakeRuntime {
    fn new(speed: f32) -> Self {
        let phase = if speed < MOVING_BRAKE_THRESHOLD {
            BrakePhase::StandInto
        } else {
            BrakePhase::MovingInto
        };
        Self {
            phase,
            phase_time: 0.0,
            phase_duration: brake_phase_duration(phase),
        }
    }

    fn set_phase(&mut self, phase: BrakePhase) {
        self.phase = phase;
        self.phase_time = 0.0;
        self.phase_duration = brake_phase_duration(phase);
    }

    fn animation_clip(&self, speed: f32) -> &'static str {
        match self.phase {
            BrakePhase::MovingInto => "R_BRAKE_N_N_0_INTO",
            BrakePhase::MovingCycle if speed < 2.0 => "R_BRAKE_N_N_0_CYC1",
            BrakePhase::MovingCycle => "R_BRAKE_N_N_0_CYC",
            BrakePhase::MovingOut => "R_BRAKE_N_N_0_OUT",
            BrakePhase::StandInto => "R_STAND_IDLE2_N_0_INTO",
            BrakePhase::StandFromMoving => "R_STAND_FROMLSBRAKE_N_0_TR",
            BrakePhase::StandCycle => "R_STAND_IDLE2_N_0_CYC",
            BrakePhase::StandOut => "R_STAND_IDLE2_N_0_OUT",
        }
    }

    fn repeats(&self) -> bool {
        matches!(self.phase, BrakePhase::MovingCycle | BrakePhase::StandCycle)
    }

    fn animation_samples(&self, speed: f32) -> Vec<AnimationSample> {
        if self.phase == BrakePhase::MovingCycle {
            // Brake.xml runs SetSpeed against the `Speed` animation-tree
            // attribute. OnBoard.abin defines the two cycle leaves at SPEED=0
            // (CYC1) and SPEED=4 (CYC), so this is the retail linear tree.
            let moving_weight = (speed / 4.0).clamp(0.0, 1.0);
            return vec![
                AnimationSample {
                    clip: "R_BRAKE_N_N_0_CYC1".to_owned(),
                    weight: 1.0 - moving_weight,
                    seek_time_seconds: self.phase_time,
                },
                AnimationSample {
                    clip: "R_BRAKE_N_N_0_CYC".to_owned(),
                    weight: moving_weight,
                    seek_time_seconds: self.phase_time,
                },
            ];
        }

        vec![AnimationSample {
            clip: self.animation_clip(speed).to_owned(),
            weight: 1.0,
            seek_time_seconds: self.phase_time,
        }]
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SlideSide {
    Frontside,
    Backside,
}

impl SlideSide {
    fn code(self) -> &'static str {
        match self {
            Self::Frontside => "FS",
            Self::Backside => "BS",
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Frontside => "frontside powerslide",
            Self::Backside => "backside powerslide",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SlideOut {
    Angle000,
    Angle090,
    Angle180,
}

impl SlideOut {
    fn code(self) -> &'static str {
        match self {
            Self::Angle000 => "OUT_000",
            Self::Angle090 => "OUT_090",
            Self::Angle180 => "OUT_180",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SlidePhase {
    Into,
    Cycle,
    Out(SlideOut),
}

impl SlidePhase {
    pub fn label(self) -> &'static str {
        match self {
            Self::Into => "slide into",
            Self::Cycle => "slide cycle",
            Self::Out(SlideOut::Angle000) => "slide out 000",
            Self::Out(SlideOut::Angle090) => "slide out 090",
            Self::Out(SlideOut::Angle180) => "slide out 180",
        }
    }
}

#[derive(Clone, Debug)]
pub struct SlideRuntime {
    pub side: SlideSide,
    pub phase: SlidePhase,
    pub phase_time: f32,
    pub phase_duration: f32,
    pub total_time: f32,
    pub rotation: f32,
    pub decel: f32,
    pub decel_target: f32,
    pub distance_to_cog: f32,
    pub transition_from_samples: Vec<AnimationSample>,
    pub transition_from_phase: Option<SlidePhase>,
    pub transition_duration: f32,
    pub control: Vec2,
    pub control_target: Vec2,
    pub entry_lateral_abs: f32,
    pub intent: f32,
    pub intent_target: f32,
    leave_condition: bool,
}

impl SlideRuntime {
    fn new(steer: f32) -> Self {
        let side = if steer > 0.0 {
            SlideSide::Frontside
        } else {
            SlideSide::Backside
        };
        let mut runtime = Self {
            side,
            phase: SlidePhase::Into,
            phase_time: 0.0,
            phase_duration: 0.0,
            total_time: 0.0,
            rotation: 0.0,
            decel: 0.0,
            decel_target: 0.0,
            // Normal slide leaves in OnBoard.abin are authored at this exact
            // DISTTOCOG coordinate. LOW leaves are 0.572022259 and will become
            // a second tree axis when crouching is brought into scope.
            distance_to_cog: 0.964176595,
            transition_from_samples: Vec::new(),
            transition_from_phase: None,
            transition_duration: 0.0,
            control: Vec2::new(steer, -1.0),
            control_target: Vec2::new(steer, -1.0),
            entry_lateral_abs: steer.abs().max(CAPTURED_CANDIDATE_SIDE_MINIMUM),
            intent: 1.0,
            intent_target: 1.0,
            leave_condition: false,
        };
        runtime.phase_duration = runtime.retail_phase_duration();
        runtime
    }

    fn set_phase(&mut self, phase: SlidePhase, phase_time: f32) {
        self.phase = phase;
        self.phase_time = phase_time;
        self.transition_from_samples.clear();
        self.transition_from_phase = None;
        self.transition_duration = 0.0;
        self.phase_duration = self.retail_phase_duration();
    }

    fn begin_cycle(&mut self) {
        let overshoot = (self.phase_time - self.phase_duration).max(0.0);
        self.phase_time = self.phase_duration;
        let outgoing = self.animation_samples();
        self.set_phase(SlidePhase::Cycle, overshoot);
        self.transition_from_samples = outgoing;
        self.transition_from_phase = Some(SlidePhase::Into);
        self.transition_duration = SLIDE_CYCLE_BLEND_SECONDS;
    }

    fn begin_out(&mut self, out: SlideOut) {
        let outgoing = self.animation_samples();
        let outgoing_phase = self.phase;
        self.set_phase(SlidePhase::Out(out), 0.0);
        self.transition_from_samples = outgoing;
        self.transition_from_phase = Some(outgoing_phase);
        self.transition_duration = SLIDE_OUT_BLEND_SECONDS;
    }

    pub fn animation_clip(&self) -> String {
        let endpoint = if self.decel >= 0.5 {
            SpeedBand::High
        } else {
            SpeedBand::Low
        };
        self.clip_for(endpoint)
    }

    fn clip_for(&self, endpoint: SpeedBand) -> String {
        let phase = match self.phase {
            SlidePhase::Into => "INTO",
            SlidePhase::Cycle => "CYC",
            SlidePhase::Out(out) => out.code(),
        };
        format!("R_SLIDE_{}_{}_{}", self.side.code(), endpoint.code(), phase)
    }

    fn blended_source_duration(&self) -> f32 {
        [SpeedBand::Low, SpeedBand::High]
            .into_iter()
            .zip([1.0 - self.decel, self.decel])
            .map(|(endpoint, weight)| {
                source_clip_duration(
                    slide_source_clip_frames(self.side, endpoint, self.phase),
                    RETAIL_SLIDE_BRAKE_ANIMATION_HZ,
                ) * weight
            })
            .sum()
    }

    fn retail_phase_duration(&self) -> f32 {
        (self.blended_source_duration() - SLIDE_WILL_EXPIRE_SECONDS).max(1.0 / FIXED_HZ as f32)
    }

    fn animation_samples(&self) -> Vec<AnimationSample> {
        let source_duration = self.blended_source_duration();
        let progress = if source_duration > f32::EPSILON {
            (self.phase_time / source_duration).clamp(0.0, 1.0)
        } else {
            0.0
        };

        [SpeedBand::Low, SpeedBand::High]
            .into_iter()
            .zip([1.0 - self.decel, self.decel])
            .filter(|(_, weight)| *weight > 0.0001)
            .map(|(endpoint, weight)| {
                let frames = slide_source_clip_frames(self.side, endpoint, self.phase);
                let duration = source_clip_duration(frames, RETAIL_SLIDE_BRAKE_ANIMATION_HZ);
                AnimationSample {
                    clip: self.clip_for(endpoint),
                    weight,
                    seek_time_seconds: progress * duration,
                }
            })
            .collect()
    }

    fn transition_samples(&self) -> Vec<AnimationSample> {
        if self.transition_duration <= f32::EPSILON || self.transition_from_samples.is_empty() {
            return self.animation_samples();
        }

        // INTO -> CYCLE uses the authored 0.1 second PlayAnimation handoff and
        // keeps advancing the outgoing INTO clip. OUT alone carries
        // blendWithCurrentFrame, so its outgoing pose remains frozen.
        let blend = transition_in_weight(self.phase_time, self.transition_duration);
        let mut samples = self
            .transition_from_samples
            .iter()
            .map(|sample| AnimationSample {
                clip: sample.clip.clone(),
                weight: sample.weight * (1.0 - blend),
                seek_time_seconds: if matches!(self.phase, SlidePhase::Cycle) {
                    let endpoint = if sample.clip.contains("_HSP_") {
                        SpeedBand::High
                    } else {
                        SpeedBand::Low
                    };
                    let source_phase = self.transition_from_phase.unwrap_or(SlidePhase::Into);
                    let duration = source_clip_duration(
                        slide_source_clip_frames(self.side, endpoint, source_phase),
                        RETAIL_SLIDE_BRAKE_ANIMATION_HZ,
                    );
                    (sample.seek_time_seconds + self.phase_time).min(duration)
                } else {
                    sample.seek_time_seconds
                },
            })
            .collect::<Vec<_>>();
        samples.extend(self.animation_samples().into_iter().map(|mut sample| {
            sample.weight *= blend;
            sample
        }));
        samples
    }
}

#[derive(Clone, Debug)]
pub struct RandomIdleRuntime {
    pub variant: u8,
    pub phase_time: f32,
    pub phase_duration: f32,
}

impl RandomIdleRuntime {
    fn new(variant: u8) -> Self {
        let frames = if variant == 1 { 201.0 } else { 481.0 };
        Self {
            variant,
            phase_time: 0.0,
            phase_duration: (frames - 1.0) / RETAIL_ANIMATION_HZ - SEQUENCE_WILL_EXPIRE_SECONDS,
        }
    }

    fn animation_clip(&self) -> &'static str {
        if self.variant == 1 {
            "R_STAND_STAT_VER1_N_0_CYC"
        } else {
            "R_STAND_STAT_VER2_N_0_CYC"
        }
    }
}

/// Live Bevy-side owner for the recovered basic-trick graph.
///
/// Gesture recognition and contact classification are separate recovered
/// systems. This wrapper accepts their typed results and ensures only concrete
/// catalog leaves can reach the animation player.
#[derive(Clone, Debug, PartialEq)]
pub struct BasicTrickPlayback {
    pub runtime: BasicTrickRuntime,
    pub straight_landing_parameters: Option<StraightLandingParameters>,
}

#[derive(Clone, Debug, Deserialize)]
struct RetailOllieCarrierDocument {
    schema: u32,
    sample_rate_hz: f32,
    cases: Vec<RetailOllieCarrierCase>,
}

#[derive(Clone, Debug, Deserialize)]
struct RetailOllieCarrierCase {
    hold_frames: u8,
    flick_frame: usize,
    first_air_frame: usize,
    touchdown_frame: usize,
    samples: Vec<RetailOllieCarrierSample>,
}

#[derive(Clone, Copy, Debug, Deserialize)]
struct RetailOllieCarrierSample {
    board_height: f32,
    skater_height: f32,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct RetailOllieCarrierPose {
    board_height: f32,
    skater_height: f32,
}

fn retail_ollie_carriers() -> &'static RetailOllieCarrierDocument {
    static DOCUMENT: OnceLock<RetailOllieCarrierDocument> = OnceLock::new();
    DOCUMENT.get_or_init(|| {
        let document: RetailOllieCarrierDocument = serde_json::from_str(RETAIL_OLLIE_CARRIER_JSON)
            .expect("the generated retail Ollie carrier fixture must be valid JSON");
        assert_eq!(document.schema, 1);
        assert_eq!(document.sample_rate_hz, RETAIL_ANIMATION_HZ);
        assert_eq!(document.cases.len(), 29);
        assert_eq!(
            document
                .cases
                .iter()
                .map(|case| case.hold_frames)
                .collect::<Vec<_>>(),
            (2_u8..=30).collect::<Vec<_>>()
        );
        document
    })
}

fn carrier_case_bracket(
    charge_seconds: f32,
) -> (
    &'static RetailOllieCarrierCase,
    &'static RetailOllieCarrierCase,
    f32,
) {
    let document = retail_ollie_carriers();
    let hold_frames = (charge_seconds.max(0.0) * document.sample_rate_hz).clamp(2.0, 30.0);
    let upper_hold = hold_frames.ceil() as u8;
    let lower_hold = hold_frames.floor() as u8;
    let lower = &document.cases[usize::from(lower_hold - 2)];
    let upper = &document.cases[usize::from(upper_hold - 2)];
    (lower, upper, hold_frames - f32::from(lower_hold))
}

fn sample_carrier_case(
    case: &RetailOllieCarrierCase,
    frame_position: f32,
) -> RetailOllieCarrierPose {
    if frame_position < 0.0 {
        let weight = (frame_position + 1.0).clamp(0.0, 1.0);
        let first = case.samples[0];
        return RetailOllieCarrierPose {
            board_height: first.board_height * weight,
            skater_height: first.skater_height * weight,
        };
    }
    let lower_index = (frame_position.floor() as usize).min(case.samples.len() - 1);
    let upper_index = (lower_index + 1).min(case.samples.len() - 1);
    let weight = (frame_position - lower_index as f32).clamp(0.0, 1.0);
    let lower = case.samples[lower_index];
    let upper = case.samples[upper_index];
    RetailOllieCarrierPose {
        board_height: lower.board_height + (upper.board_height - lower.board_height) * weight,
        skater_height: lower.skater_height + (upper.skater_height - lower.skater_height) * weight,
    }
}

fn blend_carrier_pose(
    lower: RetailOllieCarrierPose,
    upper: RetailOllieCarrierPose,
    weight: f32,
) -> RetailOllieCarrierPose {
    RetailOllieCarrierPose {
        board_height: lower.board_height + (upper.board_height - lower.board_height) * weight,
        skater_height: lower.skater_height + (upper.skater_height - lower.skater_height) * weight,
    }
}

// Retained as evidence for the isolated oracle channel. The pre-flick values
// describe the crouch already authored into R_ANTIC_*; they are not an
// additional world-space carrier for the rendered skeleton.
#[allow(dead_code)]
fn retail_anticipation_carrier(charge_seconds: f32) -> RetailOllieCarrierPose {
    let (lower, upper, blend) = carrier_case_bracket(charge_seconds);
    let frame_position = charge_seconds.max(0.0) * RETAIL_ANIMATION_HZ - 1.0;
    let lower_pose = sample_carrier_case(
        lower,
        frame_position.min(lower.flick_frame.saturating_sub(1) as f32),
    );
    let upper_pose = sample_carrier_case(
        upper,
        frame_position.min(upper.flick_frame.saturating_sub(1) as f32),
    );
    blend_carrier_pose(lower_pose, upper_pose, blend)
}

fn retail_released_carrier(
    charge_seconds: f32,
    elapsed_since_flick_seconds: f32,
) -> RetailOllieCarrierPose {
    let (lower, upper, blend) = carrier_case_bracket(charge_seconds);
    let release_frames = elapsed_since_flick_seconds.max(0.0) * RETAIL_ANIMATION_HZ;
    let lower_frame = lower.flick_frame as f32 - 1.0 + release_frames;
    let upper_frame = upper.flick_frame as f32 - 1.0 + release_frames;
    blend_carrier_pose(
        sample_carrier_case(lower, lower_frame),
        sample_carrier_case(upper, upper_frame),
        blend,
    )
}

fn retail_released_timing_seconds(
    charge_seconds: f32,
    selector: impl Fn(&RetailOllieCarrierCase) -> usize,
) -> f32 {
    let (lower, upper, blend) = carrier_case_bracket(charge_seconds);
    let relative = |case: &RetailOllieCarrierCase| {
        (selector(case) + 1 - case.flick_frame) as f32 / RETAIL_ANIMATION_HZ
    };
    let lower_seconds = relative(lower);
    lower_seconds + (relative(upper) - lower_seconds) * blend
}

/// Evidence-backed board/skater carrier for the captured flat-ground Ollie.
///
/// Retail advances the skater physics centre and skateboard body on distinct
/// paths. Keeping both measured channels prevents the board trajectory from
/// lifting the entire character and preserves the post-touchdown recovery.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PopMotion {
    pub charge_seconds: f32,
    pub launch_speed: f32,
    pub ground_height: f32,
    pub separated_from_ground: bool,
    fixed_steps_since_flick: u16,
    pub elapsed_since_flick_seconds: f32,
    pub board_height: f32,
    pub skater_height: f32,
    takeoff_view_yaw: f32,
    first_air_seconds: f32,
    touchdown_seconds: f32,
    recovery_end_seconds: f32,
    pub touched_down: bool,
    transition_touchdown_seconds: Option<f32>,
    retail_projection_velocity_y: f32,
    retail_projection_delta_per_frame: f32,
    retail_projection_touchdown_velocity_y: f32,
}

impl BasicTrickPlayback {
    #[allow(dead_code)] // Wired once retail winner publication is recovered.
    fn begin(kind: BasicTrickKind, height_endpoint: TrickHeightEndpoint) -> Self {
        Self {
            runtime: BasicTrickRuntime::begin(kind, height_endpoint),
            straight_landing_parameters: None,
        }
    }

    fn animation_state(&self) -> Result<Option<ActionAnimationState>, UnresolvedTrickAnimation> {
        let layers = self.runtime.animation_layers();
        if layers.is_empty() {
            return Ok(None);
        }
        let mut samples = Vec::new();
        for layer in layers {
            let parameters = match self.runtime.phase {
                BasicTrickPhase::Landing {
                    resource: LandingAnimationResource::Straight,
                } => self
                    .straight_landing_parameters
                    .map(TrickAnimationParameters::StraightLanding)
                    .unwrap_or(TrickAnimationParameters::None),
                _ => TrickAnimationParameters::None,
            };
            let adapted = adapt_basic_trick_request(layer.request, parameters)?;
            samples.extend(
                adapted
                    .samples
                    .into_iter()
                    .filter(|sample| sample.weight * layer.weight > 0.0)
                    .map(|sample| AnimationSample {
                        clip: sample.clip_name().to_owned(),
                        weight: sample.weight * layer.weight,
                        seek_time_seconds: sample.seek_time_seconds,
                    }),
            );
        }
        Ok(Some(ActionAnimationState {
            samples,
            weight: 1.0,
        }))
    }

    pub fn phase_label(&self) -> &'static str {
        match self.runtime.phase {
            BasicTrickPhase::GroundLeaf => "ground_leaf",
            BasicTrickPhase::AirLeaf => "air_leaf",
            BasicTrickPhase::AirBaseline => "air_baseline",
            BasicTrickPhase::Landing { .. } => "landing",
            BasicTrickPhase::PostLandLockout => "post_land_lockout",
            BasicTrickPhase::Complete => "complete",
        }
    }

    pub fn requested_resource(&self) -> Option<&'static str> {
        self.runtime
            .animation_request()
            .map(|request| request.resource)
    }
}

/// Live Bevy-side owner for the recovered non-basic flip/shuv graph.
///
/// Its animation requests remain virtual until a verified physical-leaf
/// adapter resolves them. Starting this runtime therefore advances graph and
/// authority state without ever substituting a guessed animation.
#[derive(Clone, Debug, PartialEq)]
pub struct AirTrickPlayback {
    pub runtime: AirTrickRuntime,
    pub phase_time_seconds: f32,
    /// Segment whose authored tail remains under the air-baseline blend after
    /// the graph has already moved to `Complete(InAir)`.
    completion_source_segment: Option<crate::air_trick_graph::ClipSegment>,
}

#[derive(Clone, Copy)]
struct FlipEndpointPair {
    low: &'static str,
    high: &'static str,
    low_frames: u16,
    high_frames: u16,
}

const FLIP_GROUND_SEQUENCE_LEAD_SECONDS: f32 = 0.05;
pub(crate) const SEQUENCE_TO_AIR_BASELINE_BLEND_SECONDS: f32 = 0.2;
const AIR_BASELINE_CLIP: &str = "IA_IDLE_N_N_0_CYC";

fn flip_endpoint_pair(
    trick: AirTrick,
    segment: crate::air_trick_graph::ClipSegment,
) -> Option<FlipEndpointPair> {
    use crate::air_trick_graph::ClipSegment;
    use crate::air_trick_graph::PopEnd;
    use AirTrickFamily as F;

    let pair = |low, high, low_frames, high_frames| FlipEndpointPair {
        low,
        high,
        low_frames,
        high_frames,
    };
    match (trick.pop_end, trick.family, segment) {
        (PopEnd::Tail, F::Kickflip, ClipSegment::Ground) => Some(FlipEndpointPair {
            low: "KICKFLIP_IN_LOW_G",
            high: "KICKFLIP_IN_HIGH_G",
            low_frames: 13,
            high_frames: 13,
        }),
        (PopEnd::Tail, F::Kickflip, ClipSegment::Air) => Some(FlipEndpointPair {
            low: "KICKFLIP_IN_LOW_A",
            high: "KICKFLIP_IN_HIGH_A",
            low_frames: 11,
            high_frames: 14,
        }),
        (PopEnd::Tail, F::Heelflip, ClipSegment::Ground) => Some(FlipEndpointPair {
            low: "HEELFLIP_IN_LOW_G",
            high: "HEELFLIP_IN_HIGH_G",
            low_frames: 13,
            high_frames: 13,
        }),
        (PopEnd::Tail, F::Heelflip, ClipSegment::Air) => Some(FlipEndpointPair {
            low: "HEELFLIP_IN_LOW_A",
            high: "HEELFLIP_IN_HIGH_A",
            low_frames: 12,
            high_frames: 12,
        }),
        (PopEnd::Nose, F::Kickflip, ClipSegment::Ground) => Some(FlipEndpointPair {
            low: "N_KICKFLIP_IN_LOW_G",
            high: "N_KICKFLIP_IN_HIGH_G",
            low_frames: 13,
            high_frames: 13,
        }),
        (PopEnd::Nose, F::Kickflip, ClipSegment::Air) => Some(FlipEndpointPair {
            low: "N_KICKFLIP_IN_LOW_A",
            high: "N_KICKFLIP_IN_HIGH_A",
            low_frames: 17,
            high_frames: 17,
        }),
        (PopEnd::Nose, F::Heelflip, ClipSegment::Ground) => Some(FlipEndpointPair {
            low: "N_HEELFLIP_IN_LOW_G",
            high: "N_HEELFLIP_IN_HIGH_G",
            low_frames: 13,
            high_frames: 13,
        }),
        (PopEnd::Nose, F::Heelflip, ClipSegment::Air) => Some(FlipEndpointPair {
            low: "N_HEELFLIP_IN_LOW_A",
            high: "N_HEELFLIP_IN_HIGH_A",
            low_frames: 14,
            high_frames: 14,
        }),
        (PopEnd::Tail, F::PopShuvit, ClipSegment::Ground) => {
            Some(pair("POPSHUVIT_LOW_G", "POPSHUVIT_HIGH_G", 13, 13))
        }
        (PopEnd::Tail, F::PopShuvit, ClipSegment::Air) => {
            Some(pair("POPSHUVIT_LOW_A", "POPSHUVIT_HIGH_A", 24, 24))
        }
        (PopEnd::Tail, F::FsPopShuvit, ClipSegment::Ground) => {
            Some(pair("FSPOPSHUVIT_D_LOW_G", "FSPOPSHUVIT_D_HIGH_G", 13, 13))
        }
        (PopEnd::Tail, F::FsPopShuvit, ClipSegment::Air) => {
            Some(pair("FSPOPSHUVIT_D_LOW_A", "FSPOPSHUVIT_D_HIGH_A", 24, 24))
        }
        (PopEnd::Tail, F::VarialKickflip, ClipSegment::Ground) => Some(pair(
            "VARIALKICKFLIP_LOW_G",
            "VARIALKICKFLIP_HIGH_G",
            13,
            13,
        )),
        (PopEnd::Tail, F::VarialKickflip, ClipSegment::Air) => Some(pair(
            "VARIALKICKFLIP_LOW_A",
            "VARIALKICKFLIP_HIGH_A",
            30,
            30,
        )),
        (PopEnd::Tail, F::VarialHeelflip, ClipSegment::Ground) => Some(pair(
            "VARIALHEELFLIP_D_LOW_G",
            "VARIALHEELFLIP_D_HIGH_G",
            13,
            13,
        )),
        (PopEnd::Tail, F::VarialHeelflip, ClipSegment::Air) => Some(pair(
            "VARIALHEELFLIP_D_LOW_A",
            "VARIALHEELFLIP_D_HIGH_A",
            25,
            25,
        )),
        (PopEnd::Tail, F::Hardflip, ClipSegment::Ground) => {
            Some(pair("HARDFLIP_LOW_G", "HARDFLIP_HIGH_G", 13, 13))
        }
        (PopEnd::Tail, F::Hardflip, ClipSegment::Air) => {
            Some(pair("HARDFLIP_LOW_A", "HARDFLIP_HIGH_A", 27, 33))
        }
        (PopEnd::Tail, F::InwardHeelflip, ClipSegment::Ground) => Some(pair(
            "INWARDHEELFLIP_LOW_G",
            "INWARDHEELFLIP_HIGH_G",
            12,
            12,
        )),
        (PopEnd::Tail, F::InwardHeelflip, ClipSegment::Air) => Some(pair(
            "INWARDHEELFLIP_LOW_A",
            "INWARDHEELFLIP_HIGH_A",
            29,
            31,
        )),
        (PopEnd::Tail, F::PopShuvit360, ClipSegment::Ground) => {
            Some(pair("360POPSHUVIT_LOW_G", "360POPSHUVIT_HIGH_G", 13, 13))
        }
        (PopEnd::Tail, F::PopShuvit360, ClipSegment::Air) => {
            Some(pair("360POPSHUVIT_LOW_A", "360POPSHUVIT_HIGH_A", 29, 31))
        }
        (PopEnd::Tail, F::FsPopShuvit360, ClipSegment::Ground) => Some(pair(
            "FS360POPSHUVIT_LOW_G",
            "FS360POPSHUVIT_HIGH_G",
            13,
            13,
        )),
        (PopEnd::Tail, F::FsPopShuvit360, ClipSegment::Air) => Some(pair(
            "FS360POPSHUVIT_LOW_A",
            "FS360POPSHUVIT_HIGH_A",
            30,
            30,
        )),
        (PopEnd::Tail, F::Flip360, ClipSegment::Ground) => {
            Some(pair("360FLIP_D_LOW_G", "360FLIP_D_HIGH_G", 13, 13))
        }
        (PopEnd::Tail, F::Flip360, ClipSegment::Air) => {
            Some(pair("360FLIP_D_LOW_A", "360FLIP_D_HIGH_A", 28, 33))
        }
        (PopEnd::Tail, F::Laserflip, ClipSegment::Ground) => {
            Some(pair("LASERFLIP_LOW_G", "LASERFLIP_HIGH_G", 13, 13))
        }
        (PopEnd::Tail, F::Laserflip, ClipSegment::Air) => {
            Some(pair("LASERFLIP_LOW_A", "LASERFLIP_HIGH_A", 28, 28))
        }
        (PopEnd::Tail, F::Hardflip360, ClipSegment::Ground) => {
            Some(pair("360HARDFLIP_LOW_G", "360HARDFLIP_HIGH_G", 13, 13))
        }
        (PopEnd::Tail, F::Hardflip360, ClipSegment::Air) => {
            Some(pair("360HARDFLIP_LOW_A", "360HARDFLIP_HIGH_A", 31, 33))
        }
        (PopEnd::Tail, F::InwardHeelflip360, ClipSegment::Ground) => Some(pair(
            "360INWARDHEELFLIP_LOW_G",
            "360INWARDHEELFLIP_HIGH_G",
            13,
            13,
        )),
        (PopEnd::Tail, F::InwardHeelflip360, ClipSegment::Air) => Some(pair(
            "360INWARDHEELFLIP_LOW_A",
            "360INWARDHEELFLIP_HIGH_A",
            30,
            38,
        )),
        (PopEnd::Nose, F::PopShuvit, ClipSegment::Ground) => {
            Some(pair("N_POPSHUVIT_LOW_G", "N_POPSHUVIT_HIGH_G", 13, 13))
        }
        (PopEnd::Nose, F::PopShuvit, ClipSegment::Air) => {
            Some(pair("N_POPSHUVIT_LOW_A", "N_POPSHUVIT_HIGH_A", 23, 23))
        }
        (PopEnd::Nose, F::FsPopShuvit, ClipSegment::Ground) => {
            Some(pair("N_FSPOPSHUVIT_LOW_G", "N_FSPOPSHUVIT_HIGH_G", 13, 13))
        }
        (PopEnd::Nose, F::FsPopShuvit, ClipSegment::Air) => {
            Some(pair("N_FSPOPSHUVIT_LOW_A", "N_FSPOPSHUVIT_HIGH_A", 24, 24))
        }
        (PopEnd::Nose, F::VarialKickflip, ClipSegment::Ground) => Some(pair(
            "N_VARIALKICKFLIP_LOW_G",
            "N_VARIALKICKFLIP_HIGH_G",
            13,
            13,
        )),
        (PopEnd::Nose, F::VarialKickflip, ClipSegment::Air) => Some(pair(
            "N_VARIALKICKFLIP_LOW_A",
            "N_VARIALKICKFLIP_HIGH_A",
            29,
            32,
        )),
        (PopEnd::Nose, F::VarialHeelflip, ClipSegment::Ground) => Some(pair(
            "N_VARIALHEELFLIP_LOW_G",
            "N_VARIALHEELFLIP_HIGH_G",
            13,
            13,
        )),
        (PopEnd::Nose, F::VarialHeelflip, ClipSegment::Air) => Some(pair(
            "N_VARIALHEELFLIP_LOW_A",
            "N_VARIALHEELFLIP_HIGH_A",
            29,
            29,
        )),
        (PopEnd::Nose, F::Hardflip, ClipSegment::Ground) => {
            Some(pair("N_HARDFLIP_LOW_G", "N_HARDFLIP_HIGH_G", 13, 13))
        }
        (PopEnd::Nose, F::Hardflip, ClipSegment::Air) => {
            Some(pair("N_HARDFLIP_LOW_A", "N_HARDFLIP_HIGH_A", 26, 32))
        }
        (PopEnd::Nose, F::InwardHeelflip, ClipSegment::Ground) => Some(pair(
            "N_INWARDHEELFLIP_LOW_G",
            "N_INWARDHEELFLIP_HIGH_G",
            13,
            13,
        )),
        (PopEnd::Nose, F::InwardHeelflip, ClipSegment::Air) => Some(pair(
            "N_INWARDHEELFLIP_LOW_A",
            "N_INWARDHEELFLIP_HIGH_A",
            28,
            28,
        )),
        (PopEnd::Nose, F::PopShuvit360, ClipSegment::Ground) => Some(pair(
            "N_360POPSHUVIT_LOW_G",
            "N_360POPSHUVIT_HIGH_G",
            13,
            13,
        )),
        (PopEnd::Nose, F::PopShuvit360, ClipSegment::Air) => Some(pair(
            "N_360POPSHUVIT_LOW_A",
            "N_360POPSHUVIT_HIGH_A",
            28,
            31,
        )),
        (PopEnd::Nose, F::FsPopShuvit360, ClipSegment::Ground) => Some(pair(
            "N_FS360POPSHUVIT_LOW_G",
            "N_FS360POPSHUVIT_HIGH_G",
            13,
            13,
        )),
        (PopEnd::Nose, F::FsPopShuvit360, ClipSegment::Air) => Some(pair(
            "N_FS360POPSHUVIT_LOW_A",
            "N_FS360POPSHUVIT_HIGH_A",
            28,
            33,
        )),
        (PopEnd::Nose, F::Flip360, ClipSegment::Ground) => {
            Some(pair("N_360FLIP_LOW_G", "N_360FLIP_HIGH_G", 13, 13))
        }
        (PopEnd::Nose, F::Flip360, ClipSegment::Air) => {
            Some(pair("N_360FLIP_LOW_A", "N_360FLIP_HIGH_A", 29, 29))
        }
        (PopEnd::Nose, F::Laserflip, ClipSegment::Ground) => {
            Some(pair("N_LASERFLIP_LOW_G", "N_LASERFLIP_HIGH_G", 13, 13))
        }
        (PopEnd::Nose, F::Laserflip, ClipSegment::Air) => {
            Some(pair("N_LASERFLIP_LOW_A", "N_LASERFLIP_HIGH_A", 28, 32))
        }
        (PopEnd::Nose, F::Hardflip360, ClipSegment::Ground) => {
            Some(pair("N_360HARDFLIP_LOW_G", "N_360HARDFLIP_HIGH_G", 13, 13))
        }
        (PopEnd::Nose, F::Hardflip360, ClipSegment::Air) => {
            Some(pair("N_360HARDFLIP_LOW_A", "N_360HARDFLIP_HIGH_A", 28, 33))
        }
        (PopEnd::Nose, F::InwardHeelflip360, ClipSegment::Ground) => Some(pair(
            "N_360INWARDHEELFLIP_LOW_G",
            "N_360INWARDHEELFLIP_HIGH_G",
            13,
            13,
        )),
        (PopEnd::Nose, F::InwardHeelflip360, ClipSegment::Air) => Some(pair(
            "N_360INWARDHEELFLIP_LOW_A",
            "N_360INWARDHEELFLIP_HIGH_A",
            31,
            33,
        )),
        _ => None,
    }
}

fn flip_loop_endpoint_pair(
    trick: AirTrick,
    segment: crate::air_trick_graph::ClipSegment,
) -> Option<FlipEndpointPair> {
    use crate::air_trick_graph::ClipSegment;
    use crate::air_trick_graph::PopEnd;
    use AirTrickFamily as F;

    let pair = |low, high, low_frames, high_frames| FlipEndpointPair {
        low,
        high,
        low_frames,
        high_frames,
    };
    match (trick.pop_end, trick.family, segment) {
        (PopEnd::Tail, F::Kickflip, ClipSegment::FlipCycle(1)) => {
            Some(pair("T_LOW_KICK_CYC1", "T_HI_KICK_CYC1", 13, 12))
        }
        (PopEnd::Tail, F::Kickflip, ClipSegment::FlipCycle(2)) => {
            Some(pair("T_LOW_KICK_CYC2", "T_HI_KICK_CYC2", 27, 29))
        }
        (PopEnd::Tail, F::Kickflip, ClipSegment::FlipCycle(3)) => {
            Some(pair("T_LOW_KICK_CYC3", "T_HI_KICK_CYC3", 27, 27))
        }
        (PopEnd::Tail, F::Kickflip, ClipSegment::FlipOut(1)) => Some(pair(
            "T_KICKFLIP_LOW_4FLIPS_0_OUT1",
            "T_KICKFLIP_HI_4FLIPS_0_OUT1",
            17,
            12,
        )),
        (PopEnd::Tail, F::Kickflip, ClipSegment::FlipOut(2)) => Some(pair(
            "T_KICKFLIP_LOW_4FLIPS_0_OUT2",
            "T_KICKFLIP_HI_4FLIPS_0_OUT2",
            27,
            27,
        )),
        (PopEnd::Tail, F::Kickflip, ClipSegment::FlipOut(3)) => Some(pair(
            "T_KICKFLIP_LOW_4FLIPS_0_OUT3",
            "T_KICKFLIP_HI_4FLIPS_0_OUT3",
            27,
            28,
        )),
        (PopEnd::Tail, F::Kickflip, ClipSegment::FlipOut(4)) => {
            Some(pair("T_LOW_KICK_OUT4", "T_HI_KICK_OUT4", 31, 27))
        }
        (PopEnd::Tail, F::Heelflip, ClipSegment::FlipCycle(1)) => {
            Some(pair("T_LOW_HEEL_CYC1", "T_HI_HEEL_CYC1", 13, 13))
        }
        (PopEnd::Tail, F::Heelflip, ClipSegment::FlipCycle(2)) => {
            Some(pair("T_LOW_HEEL_CYC2", "T_HI_HEEL_CYC2", 28, 28))
        }
        (PopEnd::Tail, F::Heelflip, ClipSegment::FlipCycle(3)) => {
            Some(pair("T_LOW_HEEL_CYC3", "T_HI_HEEL_CYC3", 29, 29))
        }
        (PopEnd::Tail, F::Heelflip, ClipSegment::FlipOut(1)) => Some(pair(
            "T_HEELFLIP_LOW_4FLIPS_0_OUT1",
            "T_HEELFLIP_HI_4FLIPS_0_OUT1",
            13,
            16,
        )),
        (PopEnd::Tail, F::Heelflip, ClipSegment::FlipOut(2)) => Some(pair(
            "T_HEELFLIP_LOW_4FLIPS_0_OUT2",
            "T_HEELFLIP_HI_4FLIPS_0_OUT2",
            28,
            28,
        )),
        (PopEnd::Tail, F::Heelflip, ClipSegment::FlipOut(3)) => Some(pair(
            "T_HEELFLIP_LOW_4FLIPS_0_OUT3",
            "T_HEELFLIP_HI_4FLIPS_0_OUT3",
            28,
            28,
        )),
        (PopEnd::Tail, F::Heelflip, ClipSegment::FlipOut(4)) => {
            Some(pair("T_LOW_HEEL_OUT4", "T_HI_HEEL_OUT4", 29, 29))
        }
        (PopEnd::Nose, F::Kickflip, ClipSegment::FlipCycle(1)) => {
            Some(pair("T_LOW_N_KICK_CYC1", "T_HI_N_KICK_CYC1", 13, 13))
        }
        (PopEnd::Nose, F::Kickflip, ClipSegment::FlipCycle(2)) => {
            Some(pair("T_LOW_N_KICK_CYC2", "T_HI_N_KICK_CYC2", 25, 25))
        }
        (PopEnd::Nose, F::Kickflip, ClipSegment::FlipCycle(3)) => {
            Some(pair("T_LOW_N_KICK_CYC3", "T_HI_N_KICK_CYC3", 27, 27))
        }
        (PopEnd::Nose, F::Kickflip, ClipSegment::FlipOut(1)) => Some(pair(
            "T_N_KICKFLIP_LOW_4FLIPS_0_OUT1",
            "T_N_KICKFLIP_HI_4FLIPS_0_OUT1",
            17,
            13,
        )),
        (PopEnd::Nose, F::Kickflip, ClipSegment::FlipOut(2)) => Some(pair(
            "T_N_KICKFLIP_LOW_4FLIPS_0_OUT2",
            "T_N_KICKFLIP_HI_4FLIPS_0_OUT2",
            25,
            25,
        )),
        (PopEnd::Nose, F::Kickflip, ClipSegment::FlipOut(3)) => Some(pair(
            "T_N_KICKFLIP_LOW_4FLIPS_0_OUT3",
            "T_N_KICKFLIP_HI_4FLIPS_0_OUT3",
            26,
            25,
        )),
        (PopEnd::Nose, F::Kickflip, ClipSegment::FlipOut(4)) => {
            Some(pair("T_LOW_N_KICK_OUT4", "T_HI_N_KICK_OUT4", 30, 30))
        }
        (PopEnd::Nose, F::Heelflip, ClipSegment::FlipCycle(1)) => {
            Some(pair("T_LOW_N_HEEL_CYC1", "T_HI_N_HEEL_CYC1", 11, 11))
        }
        (PopEnd::Nose, F::Heelflip, ClipSegment::FlipCycle(2)) => {
            Some(pair("T_LOW_N_HEEL_CYC2", "T_HI_N_HEEL_CYC2", 22, 22))
        }
        (PopEnd::Nose, F::Heelflip, ClipSegment::FlipCycle(3)) => {
            Some(pair("T_LOW_N_HEEL_CYC3", "T_HI_N_HEEL_CYC3", 24, 24))
        }
        (PopEnd::Nose, F::Heelflip, ClipSegment::FlipOut(1)) => Some(pair(
            "T_N_HEELFLIP_LOW_4FLIPS_0_OUT1",
            "T_N_HEELFLIP_HI_4FLIPS_0_OUT1",
            13,
            13,
        )),
        (PopEnd::Nose, F::Heelflip, ClipSegment::FlipOut(2)) => Some(pair(
            "T_N_HEELFLIP_LOW_4FLIPS_0_OUT2",
            "T_N_HEELFLIP_HI_4FLIPS_0_OUT2",
            29,
            29,
        )),
        (PopEnd::Nose, F::Heelflip, ClipSegment::FlipOut(3)) => Some(pair(
            "T_N_HEELFLIP_LOW_4FLIPS_0_OUT3",
            "T_N_HEELFLIP_HI_4FLIPS_0_OUT3",
            30,
            30,
        )),
        (PopEnd::Nose, F::Heelflip, ClipSegment::FlipOut(4)) => {
            Some(pair("T_LOW_N_HEEL_OUT4", "T_HI_N_HEEL_OUT4", 23, 23))
        }
        _ => None,
    }
}

fn air_trick_height_weight(height: AirTrickHeight) -> Option<f32> {
    match height {
        AirTrickHeight::LowEndpoint => Some(0.0),
        AirTrickHeight::HighEndpoint => Some(1.0),
        AirTrickHeight::ContinuousUnresolved(value) if value.is_finite() => {
            Some(value.clamp(0.0, 1.0))
        }
        AirTrickHeight::ContinuousUnresolved(_) => None,
    }
}

fn flip_samples(
    endpoints: FlipEndpointPair,
    height_weight: f32,
    seek_time_seconds: f32,
) -> Vec<AnimationSample> {
    [
        (endpoints.low, 1.0 - height_weight),
        (endpoints.high, height_weight),
    ]
    .into_iter()
    .filter(|(_, weight)| *weight > 0.0)
    .map(|(clip, weight)| AnimationSample {
        clip: clip.to_owned(),
        weight,
        seek_time_seconds,
    })
    .collect()
}

fn flip_duration_seconds(endpoints: FlipEndpointPair, height_weight: f32) -> f32 {
    let low = endpoints.low_frames.saturating_sub(1) as f32 / RETAIL_ANIMATION_HZ;
    let high = endpoints.high_frames.saturating_sub(1) as f32 / RETAIL_ANIMATION_HZ;
    low + (high - low) * height_weight
}

fn sequence_tail_seek_time(authored_duration_seconds: f32, transition_elapsed_seconds: f32) -> f32 {
    let tail_start = (authored_duration_seconds - WILL_EXPIRE_WINDOW_SECONDS).max(0.0);
    (tail_start
        + transition_elapsed_seconds
            .max(0.0)
            .min(WILL_EXPIRE_WINDOW_SECONDS))
    .min(authored_duration_seconds)
}

impl AirTrickPlayback {
    pub fn phase_label(&self) -> &'static str {
        match self.runtime.phase {
            AirTrickPhase::GrindOut => "grind_out",
            AirTrickPhase::TakeoffGround => "takeoff_ground",
            AirTrickPhase::LeftGroundAir => "left_ground_air",
            AirTrickPhase::FlipCycle(_) => "flip_cycle",
            AirTrickPhase::FlipOut(_) => "flip_out",
            AirTrickPhase::Complete(_) => "complete",
        }
    }

    pub fn requested_resource(&self) -> Option<String> {
        self.runtime
            .animation_request()
            .map(|request| request.virtual_resource_name())
    }

    fn animation_state(&self) -> Result<Option<ActionAnimationState>, AirTrickAnimationFailure> {
        if let Some(state) = self.flip_animation_state() {
            return Ok(Some(state));
        }
        let Some(graph) = self.runtime.animation_request() else {
            return Ok(None);
        };
        let adapted = adapt_air_trick_for_bevy(AirTrickAnimationAdapterRequest {
            graph,
            local_time_seconds: self.phase_time_seconds,
            playback_speed: 1.0,
            repeats: false,
        })?;
        let resolved = adapted.resolved();
        Ok(Some(ActionAnimationState {
            samples: vec![AnimationSample {
                clip: resolved.sample.clip.name.to_owned(),
                weight: resolved.sample.weight,
                seek_time_seconds: resolved.sample.seek_time_seconds,
            }],
            weight: 1.0,
        }))
    }

    fn authored_phase_duration_seconds(&self) -> Result<Option<f32>, AirTrickAnimationFailure> {
        if let Some(duration) = self.flip_phase_duration_seconds() {
            return Ok(Some(duration));
        }
        let Some(graph) = self.runtime.animation_request() else {
            return Ok(None);
        };
        let adapted = adapt_air_trick_for_bevy(AirTrickAnimationAdapterRequest {
            graph,
            local_time_seconds: 0.0,
            playback_speed: 1.0,
            repeats: false,
        })?;
        Ok(Some(
            adapted.resolved().sample.clip.authored_duration_seconds(),
        ))
    }

    fn flip_animation_state(&self) -> Option<ActionAnimationState> {
        use crate::air_trick_graph::ClipSegment;

        let height_weight = air_trick_height_weight(self.runtime.height)?;
        let trick = self.runtime.trick;
        if self.runtime.phase
            == AirTrickPhase::Complete(crate::air_trick_graph::HandoffTarget::InAir)
        {
            let source_segment = self.completion_source_segment?;
            let endpoints = flip_loop_endpoint_pair(trick, source_segment).or_else(|| {
                (source_segment == ClipSegment::Air)
                    .then(|| flip_endpoint_pair(trick, ClipSegment::Air))
                    .flatten()
            })?;
            let authored_duration = flip_duration_seconds(endpoints, height_weight);
            let blend = transition_in_weight(
                self.phase_time_seconds,
                SEQUENCE_TO_AIR_BASELINE_BLEND_SECONDS,
            );
            let mut samples = flip_samples(
                endpoints,
                height_weight,
                // Both the common one-shot graph and T_Kickflip exit their
                // final sequence at WillExpire 0.05. air.xml then blends
                // B_AIR_CYC over 0.2 seconds while transitionUnder keeps the
                // unconsumed source tail alive.
                sequence_tail_seek_time(authored_duration, self.phase_time_seconds),
            );
            for sample in &mut samples {
                sample.weight *= 1.0 - blend;
            }
            samples.retain(|sample| sample.weight > 0.0);
            if blend > 0.0 {
                samples.push(AnimationSample {
                    clip: AIR_BASELINE_CLIP.to_owned(),
                    weight: blend,
                    seek_time_seconds: self.phase_time_seconds,
                });
            }
            return Some(ActionAnimationState {
                samples,
                weight: 1.0,
            });
        }
        let (endpoints, seek_time_seconds) = match self.runtime.phase {
            AirTrickPhase::TakeoffGround => (
                flip_endpoint_pair(trick, ClipSegment::Ground)?,
                self.phase_time_seconds,
            ),
            AirTrickPhase::LeftGroundAir
                if self.phase_time_seconds < FLIP_GROUND_SEQUENCE_LEAD_SECONDS =>
            {
                let ground = flip_endpoint_pair(trick, ClipSegment::Ground)?;
                (
                    ground,
                    (flip_duration_seconds(ground, height_weight)
                        - FLIP_GROUND_SEQUENCE_LEAD_SECONDS
                        + self.phase_time_seconds)
                        .max(0.0),
                )
            }
            AirTrickPhase::LeftGroundAir => (
                flip_endpoint_pair(trick, ClipSegment::Air)?,
                self.phase_time_seconds - FLIP_GROUND_SEQUENCE_LEAD_SECONDS,
            ),
            AirTrickPhase::FlipCycle(count) => (
                flip_loop_endpoint_pair(trick, ClipSegment::FlipCycle(count))?,
                self.phase_time_seconds,
            ),
            AirTrickPhase::FlipOut(count) => (
                flip_loop_endpoint_pair(trick, ClipSegment::FlipOut(count))?,
                self.phase_time_seconds,
            ),
            _ => return None,
        };
        Some(ActionAnimationState {
            samples: flip_samples(endpoints, height_weight, seek_time_seconds),
            weight: 1.0,
        })
    }

    fn flip_phase_duration_seconds(&self) -> Option<f32> {
        use crate::air_trick_graph::ClipSegment;

        let height_weight = air_trick_height_weight(self.runtime.height)?;
        let trick = self.runtime.trick;
        match self.runtime.phase {
            AirTrickPhase::TakeoffGround => Some(flip_duration_seconds(
                flip_endpoint_pair(trick, ClipSegment::Ground)?,
                height_weight,
            )),
            AirTrickPhase::LeftGroundAir => Some(
                FLIP_GROUND_SEQUENCE_LEAD_SECONDS
                    + flip_duration_seconds(
                        flip_endpoint_pair(trick, ClipSegment::Air)?,
                        height_weight,
                    ),
            ),
            AirTrickPhase::FlipCycle(count) => Some(flip_duration_seconds(
                flip_loop_endpoint_pair(trick, ClipSegment::FlipCycle(count))?,
                height_weight,
            )),
            AirTrickPhase::FlipOut(count) => Some(flip_duration_seconds(
                flip_loop_endpoint_pair(trick, ClipSegment::FlipOut(count))?,
                height_weight,
            )),
            _ => None,
        }
    }
}

/// Live Bevy-side owner for the recovered airborne grab graph.
///
/// The runtime is deliberately kept separate from animation playback because
/// retail resources in this graph are virtual MotionGraph names.
#[derive(Clone, Debug, PartialEq)]
pub struct GrabPlayback {
    pub runtime: GrabRuntime,
    pub trick: GrabTrick,
    pub tweak: GrabTweakDirection,
    pub entry_adjust: GrabTweakDirection,
    pub tweak_armed: bool,
    pub phase_clip_override: Option<&'static str>,
    pub domain: GrabDomain,
    pub mirrored: bool,
    pub phase_time_seconds: f32,
    pub animation_parameters: GrabAnimationParameters,
    pub blend_from: Option<AnimationSample>,
    pub blend_sources: Vec<AnimationSample>,
    pub blend_elapsed_seconds: f32,
    pub blend_duration_seconds: f32,
    pub tweak_filter_progress: Option<f32>,
    pub tweak_filter_blending_out: bool,
    pub tweak_filter_sources: Vec<AnimationSample>,
    pub tweak_filter_velocity: f32,
    pub tweak_filter_retail_progress: f32,
    pub tweak_filter_pending_step: Option<(f32, f32)>,
    pub tweak_filter_accumulator_seconds: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct LandingPlayback {
    pub runtime: LandingRuntime,
    pub selected_variant: Option<u8>,
    pub straight_landing_parameters: Option<StraightLandingParameters>,
    pub straight_landing_blend: Option<StraightLandingBlend>,
    /// Complete authored Andale-tree inputs. Automatic measured landings
    /// always populate this; the older endpoint seam remains for isolated
    /// provider tests.
    pub tree_parameters: Option<LandingTreeParameters>,
    /// Legacy explicit endpoint seam retained for isolated provider tests.
    /// Automatic measured landings use `tree_parameters`.
    pub non_straight_axes: Option<NonStraightLandingAxes>,
}

/// Concrete BLEND_LAND branch weights produced by the retail Andale tree.
///
/// `compression_weight` selects L_LCOM -> the high-compression subtree. The
/// latter blends L_HCOM_LIMP -> L_LAND_HIGH using `high_landing_weight`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StraightLandingBlend {
    pub compression_weight: f32,
    pub high_landing_weight: f32,
}

// BLEND_LAND's AVGVELY MultiBlend endpoints, recovered from sub_82D25378 and
// confirmed by a hardware write-watch in
// work/frida-landing-watchpoint-detail-0611.jsonl.
const RETAIL_LANDING_AVG_VELOCITY_LOW: f32 = 2.68;
const RETAIL_LANDING_AVG_VELOCITY_HIGH: f32 = 6.0;

fn straight_landing_blend(average_velocity_y: f32) -> StraightLandingBlend {
    let raw_high_landing = ((average_velocity_y - RETAIL_LANDING_AVG_VELOCITY_LOW)
        / (RETAIL_LANDING_AVG_VELOCITY_HIGH - RETAIL_LANDING_AVG_VELOCITY_LOW))
        .clamp(0.0, 1.0);
    StraightLandingBlend {
        // Every controlled flat-ground BLEND_LAND capture selected the high
        // Compression branch at 1.0. Inclined and non-straight landing
        // classification remains owned by the separate landing provider.
        compression_weight: 1.0,
        high_landing_weight: andale_endpoint_weight(raw_high_landing),
    }
}

const fn landing_variant_index(variant: LandingVariant) -> u8 {
    match variant {
        LandingVariant::One => 0,
        LandingVariant::Two => 1,
        LandingVariant::Three => 2,
    }
}

const fn landing_variant_from_index(index: u8) -> Option<LandingVariant> {
    match index {
        0 => Some(LandingVariant::One),
        1 => Some(LandingVariant::Two),
        2 => Some(LandingVariant::Three),
        _ => None,
    }
}

impl LandingPlayback {
    pub fn requested_resource(&self) -> &'static str {
        self.runtime.animation_plan().virtual_resource
    }

    fn animation_state(&self) -> Result<ActionAnimationState, UnresolvedTrickAnimation> {
        let plan = self.runtime.animation_plan();
        if let Some(parameters) = self.tree_parameters {
            return Ok(ActionAnimationState {
                samples: resolve_landing_tree(self.runtime.quality, parameters)
                    .into_iter()
                    .map(|sample| AnimationSample {
                        clip: sample.name.to_owned(),
                        weight: sample.weight,
                        seek_time_seconds: self.runtime.elapsed_seconds,
                    })
                    .collect(),
                weight: 1.0,
            });
        }
        if matches!(
            self.runtime.quality,
            LandingQuality::Spin | LandingQuality::Sketchy
        ) {
            let clip = resolve_non_straight_landing(
                self.runtime.quality,
                self.non_straight_axes,
                self.selected_variant,
            )
            .map_err(|reason| UnresolvedTrickAnimation {
                source_resource: plan.virtual_resource,
                reason: crate::trick_animation::AdapterUnresolvedReason::NonStraightLandingEndpoint(
                    reason,
                ),
            })?;
            return Ok(ActionAnimationState {
                samples: vec![AnimationSample {
                    clip: clip.name.to_owned(),
                    weight: 1.0,
                    seek_time_seconds: self.runtime.elapsed_seconds,
                }],
                weight: 1.0,
            });
        }
        let parameters = match self.runtime.quality {
            LandingQuality::Straight => self
                .straight_landing_parameters
                .map(TrickAnimationParameters::StraightLanding)
                .unwrap_or(TrickAnimationParameters::None),
            LandingQuality::Spin | LandingQuality::Sketchy => unreachable!("returned above"),
        };
        let adapted = adapt_basic_trick_request(
            crate::basic_trick_graph::BasicTrickAnimationRequest {
                resource: plan.virtual_resource,
                local_time_seconds: self.runtime.elapsed_seconds,
                transition_seconds: plan.blend_seconds,
                repeats: false,
            },
            parameters,
        )?;
        let mut samples = adapted
            .samples
            .into_iter()
            .map(|sample| AnimationSample {
                clip: sample.clip_name().to_owned(),
                weight: sample.weight,
                seek_time_seconds: sample.seek_time_seconds,
            })
            .collect::<Vec<_>>();
        if let (LandingQuality::Straight, Some(parameters), Some(blend), [high_landing]) = (
            self.runtime.quality,
            self.straight_landing_parameters,
            self.straight_landing_blend,
            samples.as_slice(),
        ) {
            let suffix = match parameters.variant {
                LandingVariant::One => 1,
                LandingVariant::Two => 2,
                LandingVariant::Three => 3,
            };
            let compression = blend.compression_weight.clamp(0.0, 1.0);
            let high_landing_weight = blend.high_landing_weight.clamp(0.0, 1.0);
            let high_branch_weight = compression;
            let seek_time_seconds = high_landing.seek_time_seconds;
            samples = vec![
                AnimationSample {
                    clip: format!("L_LCOM_{suffix}"),
                    weight: 1.0 - compression,
                    seek_time_seconds,
                },
                AnimationSample {
                    clip: format!("L_HCOM_LIMP_{suffix}"),
                    weight: high_branch_weight * (1.0 - high_landing_weight),
                    seek_time_seconds,
                },
                AnimationSample {
                    clip: high_landing.clip.clone(),
                    weight: high_branch_weight * high_landing_weight,
                    seek_time_seconds,
                },
            ];
            debug_assert!(samples.iter().all(|sample| {
                crate::trick_catalog::physical_clip_by_name(&sample.clip).is_some()
            }));
        }
        Ok(ActionAnimationState {
            samples,
            weight: 1.0,
        })
    }

    fn authored_duration_seconds(&self) -> Result<f32, UnresolvedTrickAnimation> {
        let state = self.animation_state()?;
        let duration = state
            .samples
            .iter()
            .filter_map(|sample| {
                if let Some(clip) = crate::trick_catalog::physical_clip_by_name(&sample.clip) {
                    Some(clip.authored_duration_seconds())
                } else {
                    crate::landing_animation::decoded_landing_clip_by_name(&sample.clip)
                        .map(|clip| clip.authored_duration_seconds())
                }
            })
            .fold(0.0_f32, f32::max);
        Ok(duration)
    }
}

impl GrabPlayback {
    pub fn phase_label(&self) -> &'static str {
        match self.runtime.phase {
            GrabPhase::Into => "into",
            GrabPhase::Cycle => "cycle",
            GrabPhase::Out => "out",
            GrabPhase::ToDouble => "to_double",
            GrabPhase::FromDouble => "from_double",
            GrabPhase::Complete => "complete",
            GrabPhase::WipeOut => "wipeout",
            GrabPhase::Land => "land",
            GrabPhase::ToOffBoard => "to_offboard",
            GrabPhase::ExternalBranch(_) => "external_branch",
        }
    }

    pub fn requested_resource(&self) -> Option<&'static str> {
        self.active_clip_name()
    }

    fn animation_state(&self) -> Result<Option<ActionAnimationState>, GrabAnimationFailure> {
        let Some(clip) = self.active_clip_name() else {
            return Ok(None);
        };
        let speed = self.playback_speed();
        let seek_time_seconds = self.phase_time_seconds * speed;
        let blend_weight = self.tweak_filter_progress.unwrap_or_else(|| {
            transition_in_weight(self.blend_elapsed_seconds, self.blend_duration_seconds)
        });
        let mut samples = Vec::with_capacity(
            self.tweak_filter_sources
                .len()
                .max(self.blend_sources.len())
                .max(1)
                + 1,
        );
        if self.tweak_filter_progress.is_some() {
            samples.extend(
                self.tweak_filter_sources
                    .iter()
                    .filter(|source| source.weight > 0.0 && blend_weight < 1.0)
                    .map(|source| AnimationSample {
                        weight: source.weight * (1.0 - blend_weight),
                        ..source.clone()
                    }),
            );
        } else if !self.blend_sources.is_empty() && blend_weight < 1.0 {
            samples.extend(
                self.blend_sources
                    .iter()
                    .filter(|source| source.weight > 0.0)
                    .map(|source| AnimationSample {
                        weight: source.weight * (1.0 - blend_weight),
                        ..source.clone()
                    }),
            );
        } else if let Some(source) = &self.blend_from
            && blend_weight < 1.0
        {
            samples.push(AnimationSample {
                weight: 1.0 - blend_weight,
                ..source.clone()
            });
        }
        samples.push(AnimationSample {
            clip: clip.to_owned(),
            weight: blend_weight,
            seek_time_seconds,
        });
        let weight = match self.runtime.phase {
            GrabPhase::Out => {
                let duration = self.phase_duration_seconds().unwrap_or(0.1);
                let remaining = (duration - self.phase_time_seconds).max(0.0);
                (remaining / 0.1).clamp(0.0, 1.0)
            }
            _ => 1.0,
        };
        Ok(Some(ActionAnimationState { samples, weight }))
    }

    fn playback_speed(&self) -> f32 {
        if matches!(
            self.phase_clip_override,
            Some("GR_DSMNT_N_CHRIST_TO_SUPER" | "GR_DSMNT_N_NOFOOT_TO_SUPER")
        ) {
            return 1.3;
        }
        match (self.domain, self.runtime.phase, self.trick) {
            // The private action bank contains the complete authored Into
            // trajectories at their native 30 Hz sample clock. Advancing
            // these physical leaves again by the MotionGraph playbackSpeed
            // values made the visible reach finish 1.2x--3x early. Keep
            // graph constants documented in `grab_graph`; the explicit Bevy
            // leaf clock consumes each authored Into once at native speed.
            (GrabDomain::Air, GrabPhase::Into, _) => 1.0,
            (
                GrabDomain::Air,
                GrabPhase::Out,
                GrabTrick::Fs | GrabTrick::Bs | GrabTrick::Double,
            ) => 2.0,
            (
                GrabDomain::Air,
                GrabPhase::Out,
                GrabTrick::NoFoot
                | GrabTrick::Christ
                | GrabTrick::OneFootFs(_)
                | GrabTrick::OneFootBs(_)
                | GrabTrick::OneFootNose(_)
                | GrabTrick::OneFootTail(_)
                | GrabTrick::Airwalk
                | GrabTrick::Tailwalk,
            ) => 1.2,
            _ => 1.0,
        }
    }

    fn active_clip_name(&self) -> Option<&'static str> {
        if let Some(clip) = self.phase_clip_override {
            return Some(clip);
        }
        if self.domain == GrabDomain::Ground {
            return Some(
                match (self.runtime.phase, self.runtime.identity, self.trick) {
                    (GrabPhase::Into, _, GrabTrick::Coffin) => "GR_GROUND_N_COFFIN_0_INTO",
                    (GrabPhase::Cycle, _, GrabTrick::Coffin) => "GR_GROUND_N_COFFIN_0_CYC",
                    (GrabPhase::Out, _, GrabTrick::Coffin) => "GR_GROUND_N_COFFIN_0_OUT",
                    (GrabPhase::Into, GrabIdentity::Fs, _) => "GR_CROUCH2GRAB_N_FS_0_INTO",
                    (GrabPhase::Into, GrabIdentity::Bs, _) => "GR_CROUCH2GRAB_N_BS_0_INTO",
                    (GrabPhase::Into, GrabIdentity::Double, _) => "GR_CROUCH2GRAB_N_DBL_0_INTO",
                    (GrabPhase::Cycle, GrabIdentity::Fs, _) => "GR_GROUND_N_FS_0_CYC",
                    (GrabPhase::Cycle, GrabIdentity::Bs, _) => "GR_GROUND_N_BS_0_CYC",
                    (GrabPhase::Cycle, GrabIdentity::Double, _) => "GR_GROUND_N_DBL_0_CYC",
                    (GrabPhase::Out, GrabIdentity::Fs, _) => "GR_GROUND_N_FS_0_OUT",
                    (GrabPhase::Out, GrabIdentity::Bs, _) => "GR_GROUND_N_BS_0_OUT",
                    (GrabPhase::Out, GrabIdentity::Double, _) => "GR_GROUND_N_DBL_0_OUT",
                    (GrabPhase::ToDouble, GrabIdentity::Fs, _) => "GR_GRAB_N_FS2DBL_0_TR",
                    (GrabPhase::ToDouble, GrabIdentity::Bs, _) => "GR_GRAB_N_BS2DBL_0_TR",
                    (GrabPhase::FromDouble, GrabIdentity::Fs, _) => "GR_GRAB_N_DBL2FS_0_TR",
                    (GrabPhase::FromDouble, GrabIdentity::Bs, _) => "GR_GRAB_N_DBL2BS_0_TR",
                    _ => return None,
                },
            );
        }

        let phase = self.runtime.phase;
        Some(match self.trick {
            GrabTrick::Fs => match phase {
                GrabPhase::Into => "GR_GRAB_N_FS_0_INTO",
                GrabPhase::Out => "GR_GRAB_N_FS_0_OUT",
                GrabPhase::ToDouble => "GR_FS2DBL_0_TR",
                GrabPhase::FromDouble => "GR_DBL2FS_0_TR",
                GrabPhase::Cycle => match self.tweak {
                    GrabTweakDirection::Neutral => "GR_GRAB_N_FS_0_CYC",
                    GrabTweakDirection::Up => "GR_NBONE_N_FS_0_CYC",
                    GrabTweakDirection::Down => "GR_TBONE_N_FS_0_CYC",
                    GrabTweakDirection::Left => "GR_STIFFY_N_FS_0_CYC",
                    GrabTweakDirection::Right => "GR_TKNEE_N_FS_0_CYC",
                },
                _ => return None,
            },
            GrabTrick::Bs => match phase {
                GrabPhase::Into => "GR_GRAB_N_BS_0_INTO",
                GrabPhase::Out => "GR_GRAB_N_BS_0_OUT",
                GrabPhase::ToDouble => "GR_BS2DBL_0_TR",
                GrabPhase::FromDouble => "GR_DBL2BS_0_TR",
                GrabPhase::Cycle => match self.tweak {
                    GrabTweakDirection::Neutral => "GR_GRAB_N_BS_0_CYC",
                    GrabTweakDirection::Up => "GR_MELON_N_BS_0_CYC",
                    GrabTweakDirection::Down => "GR_GRAB_N_BS_METHOD_CYC",
                    GrabTweakDirection::Left => "GR_CBONE_N_BS_0_CYC",
                    GrabTweakDirection::Right => "GR_METHOD_N_BS_0_CYC",
                },
                _ => return None,
            },
            GrabTrick::Double => match phase {
                GrabPhase::Into => "GR_GRAB_N_DBL_0_INTO",
                GrabPhase::Out => "GR_GRAB_N_DBL_0_OUT",
                GrabPhase::Cycle => match self.tweak {
                    GrabTweakDirection::Neutral => "GR_GRAB_N_DBL_0_CYC",
                    GrabTweakDirection::Up => "GR_GRAB_N_DBL_BACKTW_CYC",
                    GrabTweakDirection::Down => "GR_GRAB_N_DBL_FRONTTW_CYC",
                    GrabTweakDirection::Left => "GR_GRAB_N_DBL_LEFTTW_CYC",
                    GrabTweakDirection::Right => "GR_GRAB_N_DBL_RIGHTTW_CYC",
                },
                _ => return None,
            },
            GrabTrick::Mute => phase_clip(
                phase,
                "GR_MUTEGRAB_N_0_INTO",
                match self.tweak {
                    GrabTweakDirection::Neutral => "GR_MUTEGRAB_N_0_CYC",
                    GrabTweakDirection::Up => "GR_MUTEGRAB_N_NOSE_CYC",
                    GrabTweakDirection::Down => "GR_MUTEGRAB_TAIL_N_0_CYC",
                    GrabTweakDirection::Left => "GR_MUTEGRAB_JAPAN_N_0_CYC",
                    GrabTweakDirection::Right => "GR_MUTEGRAB_N_1_CYC",
                },
                "GR_MUTEGRAB_N_0_OUT",
            )?,
            GrabTrick::Stale => phase_clip(
                phase,
                "GR_STALEGRAB_N_0_INTO",
                match self.tweak {
                    GrabTweakDirection::Neutral => "GR_STALEGRAB_N_0_CYC",
                    GrabTweakDirection::Up => "GR_STALEGRAB_NOSE_N_0_CYC",
                    GrabTweakDirection::Down => "GR_STALEGRAB_TAIL_N_0_CYC",
                    GrabTweakDirection::Left => "GR_STALEGRAB_TUCKKNEE_N_0_CYC",
                    GrabTweakDirection::Right => "GR_STALEGRAB_N_1_CYC",
                },
                "GR_STALEGRAB_N_0_OUT",
            )?,
            GrabTrick::Nose => directional_family_clip(
                phase,
                self.tweak,
                (
                    "GR_NOSEGRAB_N_BS_0_INTO",
                    "GR_NOSEGRAB_N_BS_0_CYC",
                    "GR_NOSEGRAB_N_BS_0_OUT",
                ),
                (
                    "GR_NOSEGRAB_TBONE_N_0_INTO",
                    "GR_NOSEGRAB_TBONE_N_0_CYC",
                    "GR_NOSEGRAB_TBONE_N_0_OUT",
                ),
                (
                    "GR_NOSEGRAB_SHIFTY_BS_0_INTO",
                    "GR_NOSEGRAB_SHIFTY_BS_0_CYC",
                    "GR_NOSEGRAB_SHIFTY_BS_0_OUT",
                ),
                (
                    "GR_NOSEGRAB_SHIFTY_FS_0_INTO",
                    "GR_NOSEGRAB_SHIFTY_FS_0_CYC",
                    "GR_NOSEGRAB_SHIFTY_FS_0_OUT",
                ),
            )?,
            GrabTrick::Tail => directional_family_clip(
                phase,
                self.tweak,
                (
                    "GR_TAILGRAB_N_BS_0_INTO",
                    "GR_TAILGRAB_N_BS_0_CYC",
                    "GR_TAILGRAB_N_BS_0_OUT",
                ),
                (
                    "GR_TAILGRAB_NBONE_N_0_INTO",
                    "GR_TAILGRAB_NBONE_N_0_CYC",
                    "GR_TAILGRAB_NBONE_N_0_OUT",
                ),
                (
                    "GR_TAILGRAB_SHIFTY_BS_0_INTO",
                    "GR_TAILGRAB_SHIFTY_BS_0_CYC",
                    "GR_TAILGRAB_SHIFTY_BS_0_OUT",
                ),
                (
                    "GR_TAILGRAB_SHIFTY_FS_0_INTO",
                    "GR_TAILGRAB_SHIFTY_FS_0_CYC",
                    "GR_TAILGRAB_SHIFTY_FS_0_OUT",
                ),
            )?,
            GrabTrick::Crail => directional_family_clip(
                phase,
                self.tweak,
                (
                    "GR_CRAILGRAB_N_0_INTO",
                    "GR_CRAILGRAB_N_0_CYC",
                    "GR_CRAILGRAB_N_0_OUT",
                ),
                (
                    "GR_CRAILGRAB_N_0_INTO",
                    "GR_CRAILGRAB_N_0_CYC",
                    "GR_CRAILGRAB_N_0_OUT",
                ),
                (
                    "GR_CRAILGRAB_SHIFTY_BS_0_INTO",
                    "GR_CRAILGRAB_SHIFTY_BS_0_CYC",
                    "GR_CRAILGRAB_SHIFTY_BS_0_OUT",
                ),
                (
                    "GR_CRAILGRAB_SHIFTY_FS_0_INTO",
                    "GR_CRAILGRAB_SHIFTY_FS_0_CYC",
                    "GR_CRAILGRAB_SHIFTY_FS_0_OUT",
                ),
            )?,
            GrabTrick::Seatbelt => directional_family_clip(
                phase,
                self.tweak,
                (
                    "GR_SEATBELTGRAB_N_0_INTO",
                    "GR_SEATBELTGRAB_N_0_CYC",
                    "GR_SEATBELTGRAB_N_0_OUT",
                ),
                (
                    "GR_SEATBELTGRAB_N_0_INTO",
                    "GR_SEATBELTGRAB_N_0_CYC",
                    "GR_SEATBELTGRAB_N_0_OUT",
                ),
                (
                    "GR_SEATBELTGRAB_SHIFTY_BS_0_INTO",
                    "GR_SEATBELTGRAB_SHIFTY_BS_0_CYC",
                    "GR_SEATBELTGRAB_SHIFTY_BS_0_OUT",
                ),
                (
                    "GR_SEATBELTGRAB_SHIFTY_FS_0_INTO",
                    "GR_SEATBELTGRAB_SHIFTY_FS_0_CYC",
                    "GR_SEATBELTGRAB_SHIFTY_FS_0_OUT",
                ),
            )?,
            GrabTrick::Rocket => phase_clip(
                phase,
                "GR_NOSEGRAB_ROCKETAIR_N_0_INTO",
                "GR_NOSEGRAB_ROCKETAIR_N_0_CYC",
                "GR_NOSEGRAB_ROCKETAIR_N_0_OUT",
            )?,
            GrabTrick::NoFoot => phase_clip(
                phase,
                "GR_DSMNT_NOFOOT_FS_0_INTO",
                "GR_DSMNT_NOFOOT_FS_0_CYC",
                "GR_DSMNT_NOFOOT_FS_0_OUT",
            )?,
            GrabTrick::Christ => phase_clip(
                phase,
                "GR_DSMNT_CHRIST_BS_0_INTO",
                "GR_DSMNT_CHRIST_BS_0_CYC",
                "GR_DSMNT_CHRIST_BS_0_OUT",
            )?,
            GrabTrick::OneFootFs(foot) => one_foot_clip(phase, "FS", foot)?,
            GrabTrick::OneFootBs(foot) => one_foot_clip(phase, "BS", foot)?,
            GrabTrick::OneFootNose(foot) => one_foot_clip(phase, "NOSE", foot)?,
            GrabTrick::OneFootTail(foot) => one_foot_clip(phase, "TAIL", foot)?,
            GrabTrick::Airwalk => phase_clip(
                phase,
                "2FT_AIR_GRAB_N_NOSE_0_INTO",
                "2FT_AIR_GRAB_N_NOSE_0_CYC",
                "2FT_AIR_GRAB_N_NOSE_0_OUT",
            )?,
            GrabTrick::Tailwalk => phase_clip(
                phase,
                "2FT_AIR_GRAB_N_TAIL_0_INTO",
                "2FT_AIR_GRAB_N_TAIL_0_CYC",
                "2FT_AIR_GRAB_N_TAIL_0_OUT",
            )?,
            GrabTrick::Superman => phase_clip(
                phase,
                "GR_DSMNT_SUPER_DBL_0_INTO",
                "GR_DSMNT_SUPER_DBL_0_CYC",
                "GR_DSMNT_SUPER_DBL_0_OUT",
            )?,
            GrabTrick::Coffin => phase_clip(
                phase,
                "GR_GROUND_N_COFFIN_0_INTO",
                "GR_GROUND_N_COFFIN_0_CYC",
                "GR_GROUND_N_COFFIN_0_OUT",
            )?,
        })
    }

    fn phase_duration_seconds(&self) -> Option<f32> {
        Some(grab_clip_duration_seconds(self.active_clip_name()?)? / self.playback_speed())
    }

    pub fn active_physical_hands(&self) -> Option<PhysicalGrabHands> {
        match self.runtime.phase {
            GrabPhase::Out | GrabPhase::Complete => None,
            GrabPhase::ToDouble | GrabPhase::FromDouble => Some(PhysicalGrabHands::Both),
            _ => Some(self.trick.physical_hands(self.mirrored)),
        }
    }

    /// The authored Out states release `HandBusy` immediately, but the old
    /// grab leaf remains in the `PlayAnimation time=...` transition. Fade the
    /// established OnBoard hand constraint by that exact source contribution
    /// so Bevy does not remove the solved arm on the CYC -> OUT boundary.
    pub fn hand_ik_constraint(&self) -> Option<(PhysicalGrabHands, f32)> {
        match self.runtime.phase {
            GrabPhase::Complete => None,
            GrabPhase::Out => {
                let weight =
                    transition_out_weight(self.blend_elapsed_seconds, self.blend_duration_seconds);
                (weight > f32::EPSILON)
                    .then_some((self.trick.physical_hands(self.mirrored), weight))
            }
            GrabPhase::ToDouble | GrabPhase::FromDouble => Some((PhysicalGrabHands::Both, 1.0)),
            _ => Some((self.trick.physical_hands(self.mirrored), 1.0)),
        }
    }
}

fn phase_clip(
    phase: GrabPhase,
    into: &'static str,
    cycle: &'static str,
    out: &'static str,
) -> Option<&'static str> {
    match phase {
        GrabPhase::Into => Some(into),
        GrabPhase::Cycle => Some(cycle),
        GrabPhase::Out => Some(out),
        _ => None,
    }
}

fn directional_family_clip(
    phase: GrabPhase,
    tweak: GrabTweakDirection,
    neutral: (&'static str, &'static str, &'static str),
    vertical: (&'static str, &'static str, &'static str),
    left: (&'static str, &'static str, &'static str),
    right: (&'static str, &'static str, &'static str),
) -> Option<&'static str> {
    let family = match tweak {
        GrabTweakDirection::Neutral | GrabTweakDirection::Down => neutral,
        GrabTweakDirection::Up => vertical,
        GrabTweakDirection::Left => left,
        GrabTweakDirection::Right => right,
    };
    phase_clip(phase, family.0, family.1, family.2)
}

fn one_foot_clip(
    phase: GrabPhase,
    family: &'static str,
    foot: crate::grab_graph::ReleasedFoot,
) -> Option<&'static str> {
    use crate::grab_graph::ReleasedFoot;
    match (family, foot, phase) {
        ("FS", ReleasedFoot::Left, GrabPhase::Into) => Some("1FT_AIR_GRAB_N_FSL_0_INTO"),
        ("FS", ReleasedFoot::Left, GrabPhase::Cycle) => Some("1FT_AIR_GRAB_N_FSL_0_CYC"),
        ("FS", ReleasedFoot::Left, GrabPhase::Out) => Some("1FT_AIR_GRAB_N_FSL_0_OUT"),
        ("FS", ReleasedFoot::Right, GrabPhase::Into) => Some("1FT_AIR_GRAB_N_FSR_0_INTO"),
        ("FS", ReleasedFoot::Right, GrabPhase::Cycle) => Some("1FT_AIR_GRAB_N_FSR_0_CYC"),
        ("FS", ReleasedFoot::Right, GrabPhase::Out) => Some("1FT_AIR_GRAB_N_FSR_0_OUT"),
        ("BS", ReleasedFoot::Left, GrabPhase::Into) => Some("1FT_AIR_GRAB_N_BSL_0_INTO"),
        ("BS", ReleasedFoot::Left, GrabPhase::Cycle) => Some("1FT_AIR_GRAB_N_BSL_0_CYC"),
        ("BS", ReleasedFoot::Left, GrabPhase::Out) => Some("1FT_AIR_GRAB_N_BSL_0_OUT"),
        ("BS", ReleasedFoot::Right, GrabPhase::Into) => Some("1FT_AIR_GRAB_N_BSR_0_INTO"),
        ("BS", ReleasedFoot::Right, GrabPhase::Cycle) => Some("1FT_AIR_GRAB_N_BSR_0_CYC"),
        ("BS", ReleasedFoot::Right, GrabPhase::Out) => Some("1FT_AIR_GRAB_N_BSR_0_OUT"),
        ("NOSE", ReleasedFoot::Left, GrabPhase::Into) => Some("1FT_AIR_GRAB_N_NOSEL_0_INTO"),
        ("NOSE", ReleasedFoot::Left, GrabPhase::Cycle) => Some("1FT_AIR_GRAB_N_NOSEL_0_CYC"),
        ("NOSE", ReleasedFoot::Left, GrabPhase::Out) => Some("1FT_AIR_GRAB_N_NOSEL_0_OUT"),
        ("NOSE", ReleasedFoot::Right, GrabPhase::Into) => Some("1FT_AIR_GRAB_N_NOSER_0_INTO"),
        ("NOSE", ReleasedFoot::Right, GrabPhase::Cycle) => Some("1FT_AIR_GRAB_N_NOSER_0_CYC"),
        ("NOSE", ReleasedFoot::Right, GrabPhase::Out) => Some("1FT_AIR_GRAB_N_NOSER_0_OUT"),
        ("TAIL", ReleasedFoot::Left, GrabPhase::Into) => Some("1FT_AIR_GRAB_N_TAILL_0_INTO"),
        ("TAIL", ReleasedFoot::Left, GrabPhase::Cycle) => Some("1FT_AIR_GRAB_N_TAILL_0_CYC"),
        ("TAIL", ReleasedFoot::Left, GrabPhase::Out) => Some("1FT_AIR_GRAB_N_TAILL_0_OUT"),
        ("TAIL", ReleasedFoot::Right, GrabPhase::Into) => Some("1FT_AIR_GRAB_N_TAILR_0_INTO"),
        ("TAIL", ReleasedFoot::Right, GrabPhase::Cycle) => Some("1FT_AIR_GRAB_N_TAILR_0_CYC"),
        ("TAIL", ReleasedFoot::Right, GrabPhase::Out) => Some("1FT_AIR_GRAB_N_TAILR_0_OUT"),
        _ => None,
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct GrabTweakFilterConfig {
    blend: f32,
    blend_out: f32,
    clamp_acceleration: Option<f32>,
    clamp_velocity: f32,
}

fn grab_tweak_filter_config(trick: GrabTrick) -> Option<GrabTweakFilterConfig> {
    match trick {
        GrabTrick::Fs | GrabTrick::Bs | GrabTrick::Double | GrabTrick::Mute | GrabTrick::Stale => {
            Some(GrabTweakFilterConfig {
                blend: GRAB_TWEAK_FILTER_BLEND,
                blend_out: GRAB_TWEAK_FILTER_BLEND_OUT,
                clamp_acceleration: None,
                clamp_velocity: GRAB_TWEAK_FILTER_CLAMP_VELOCITY,
            })
        }
        GrabTrick::Nose | GrabTrick::Tail | GrabTrick::Crail | GrabTrick::Seatbelt => {
            Some(GrabTweakFilterConfig {
                blend: BOARD_ADJUST_FILTER_BLEND,
                blend_out: BOARD_ADJUST_FILTER_BLEND_OUT,
                clamp_acceleration: Some(BOARD_ADJUST_FILTER_CLAMP_ACCELERATION),
                clamp_velocity: BOARD_ADJUST_FILTER_CLAMP_VELOCITY,
            })
        }
        _ => None,
    }
}

fn step_grab_tweak_filter(
    progress: f32,
    previous_velocity: f32,
    blending_out: bool,
    config: GrabTweakFilterConfig,
) -> (f32, f32) {
    let coefficient = if blending_out {
        config.blend_out
    } else {
        config.blend
    };
    let mut velocity = (1.0 - progress.clamp(0.0, 1.0)) * coefficient;
    if let Some(clamp_acceleration) = config.clamp_acceleration {
        velocity = velocity.clamp(
            previous_velocity - clamp_acceleration,
            previous_velocity + clamp_acceleration,
        );
    }
    velocity = velocity.clamp(-config.clamp_velocity, config.clamp_velocity);
    ((progress + velocity).clamp(0.0, 1.0), velocity)
}

/// Emit one 60 Hz sample without changing the recovered filter's duration.
///
/// The retail filter itself is a discrete 30 Hz recurrence. The first call
/// emits the midpoint toward its next state; the second commits that exact
/// state. Consequently every second output is the original 30 Hz trajectory
/// while the animation mixer receives a fresh weight at 60 Hz.
fn step_grab_tweak_filter_output(
    retail_progress: &mut f32,
    retail_velocity: &mut f32,
    pending_step: &mut Option<(f32, f32)>,
    blending_out: bool,
    config: GrabTweakFilterConfig,
) -> f32 {
    if let Some((next_progress, next_velocity)) = pending_step.take() {
        *retail_progress = next_progress;
        *retail_velocity = next_velocity;
        next_progress
    } else {
        let (next_progress, next_velocity) =
            step_grab_tweak_filter(*retail_progress, *retail_velocity, blending_out, config);
        *pending_step = Some((next_progress, next_velocity));
        0.5 * (*retail_progress + next_progress)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct GrindPlayback {
    pub classification: GrindClassification,
    pub runtime: GrindRuntime,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ManualPlayback {
    pub entry: ManualEntryContext,
    pub runtime: ManualRuntime,
    pub balance_conditioner: ManualBalanceConditioner,
    pub manual_angle_behaviour_active_last_step: bool,
    pub manual_angle_update_accumulator_seconds: f32,
    pub phase_time_seconds: f32,
    pub total_time_seconds: f32,
    pub presentation_balance: f32,
    pub out_timer_remaining_seconds: Option<f32>,
    pub release_balance: f32,
    pub visual_transition: Option<ManualVisualTransition>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ManualVisualTransition {
    pub source_samples: Vec<AnimationSample>,
    pub source_action_weight: f32,
    pub elapsed_seconds: f32,
    pub duration_seconds: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ManualRidingHandoff {
    pub source: ActionAnimationState,
    pub elapsed_seconds: f32,
    pub duration_seconds: f32,
}

impl ManualPlayback {
    fn manual_angle_behaviour_active(&self) -> bool {
        self.runtime.phase == ManualPhase::Cycle
            && matches!(
                self.runtime.speed_band,
                crate::manual_graph::ManualSpeedBand::TailRollingBackward
                    | crate::manual_graph::ManualSpeedBand::NoseRollingForward
            )
    }

    fn entry_transition_weight(&self, entry_transition_seconds: f32) -> f32 {
        if entry_transition_seconds <= f32::EPSILON {
            1.0
        } else {
            (self.total_time_seconds / entry_transition_seconds).clamp(0.0, 1.0)
        }
    }

    fn selector_action_weight(&self) -> f32 {
        match self.runtime.phase {
            // The decoded B_* tree consumes MANUAL_ANGLE, parent-published
            // DISTTOCOG and spin inside the selector. It does not use Manual
            // magnitude to blend the complete action against riding; doing
            // that double-blended the pelvis and produced the old tail wobble.
            ManualPhase::Cycle
            | ManualPhase::Revert(_)
            | ManualPhase::NoseInto
            | ManualPhase::Brake
            | ManualPhase::NoseOut => 1.0,
            ManualPhase::ExitRequested | ManualPhase::Complete => 0.0,
        }
    }

    fn action_weight(&self, entry_transition_seconds: f32) -> f32 {
        self.selector_action_weight() * self.entry_transition_weight(entry_transition_seconds)
    }

    fn deck_balance(&self) -> f32 {
        // Entry begins from the four-wheel riding pose. Apply the exact
        // PlayAnimation transition duration to the physics-owned board pitch
        // as well, keeping the board, feet and authored pose synchronized.
        let entry_transition_seconds = match self.runtime.kind {
            ManualKind::Tail => 0.3,
            ManualKind::Nose => 0.1,
        };
        self.presentation_balance * self.entry_transition_weight(entry_transition_seconds)
    }

    fn animation_parameters(&self) -> ManualAnimationParameters {
        match self.runtime.phase {
            ManualPhase::NoseInto => ManualAnimationParameters {
                spin: Some(self.runtime.spin),
                distance_to_cog: Some(RETAIL_NEUTRAL_RIDING_DIST_TO_COG),
                ..ManualAnimationParameters::default()
            },
            ManualPhase::Cycle => ManualAnimationParameters {
                balance: Some(self.runtime.balance),
                spin: Some(self.runtime.spin),
                distance_to_cog: Some(RETAIL_NEUTRAL_RIDING_DIST_TO_COG),
                manual_angle: matches!(
                    self.runtime.speed_band,
                    crate::manual_graph::ManualSpeedBand::TailRollingBackward
                        | crate::manual_graph::ManualSpeedBand::NoseRollingForward
                )
                .then_some(self.balance_conditioner.angle()),
                ..ManualAnimationParameters::default()
            },
            ManualPhase::Brake => ManualAnimationParameters {
                // Both retail Brake states replace live Manual with
                // CreateAttribute(balance, +/-1.0).
                balance: Some(if self.runtime.kind == ManualKind::Tail {
                    -1.0
                } else {
                    1.0
                }),
                spin: self.runtime.brake_moving.then_some(self.runtime.spin),
                manual_brake: Some(1.0),
                ..ManualAnimationParameters::default()
            },
            ManualPhase::Revert(direction) => ManualAnimationParameters {
                balance: Some(self.runtime.balance),
                revert_dir: Some(direction.attribute()),
                ..ManualAnimationParameters::default()
            },
            ManualPhase::NoseOut | ManualPhase::ExitRequested | ManualPhase::Complete => {
                ManualAnimationParameters {
                    distance_to_cog: Some(RETAIL_NEUTRAL_RIDING_DIST_TO_COG),
                    ..ManualAnimationParameters::default()
                }
            }
        }
    }

    fn adapted_animation(&self) -> Result<Option<BevyManualAnimation>, ManualAnimationFailure> {
        let Some(request) = self.runtime.animation_request() else {
            return Ok(None);
        };
        adapt_manual_for_bevy(ManualAnimationAdapterRequest {
            source_resource: request.resource,
            local_time_seconds: self.phase_time_seconds,
            transition_seconds: request.transition_seconds,
            playback_speed: 1.0,
            repeats: request.repeats,
            apply_posture: false,
            parameters: self.animation_parameters(),
        })
        .map(Some)
    }

    fn unblended_animation_state(
        &self,
    ) -> Result<Option<ActionAnimationState>, ManualAnimationFailure> {
        let Some(request) = self.runtime.animation_request() else {
            return Ok(None);
        };
        if let Ok(Some(adapted)) = self.adapted_animation() {
            return Ok(Some(ActionAnimationState {
                samples: vec![AnimationSample {
                    clip: adapted.leaf().name.to_owned(),
                    weight: 1.0,
                    seek_time_seconds: adapted.local_time_seconds,
                }],
                weight: self.action_weight(request.transition_seconds),
            }));
        }
        let resolved = resolve_manual_visual_tree(ManualAnimationAdapterRequest {
            source_resource: request.resource,
            local_time_seconds: self.phase_time_seconds,
            transition_seconds: request.transition_seconds,
            playback_speed: 1.0,
            repeats: request.repeats,
            apply_posture: false,
            parameters: self.animation_parameters(),
        })?;
        Ok(Some(ActionAnimationState {
            samples: resolved
                .samples
                .into_iter()
                .map(|sample| AnimationSample {
                    clip: sample.physical_leaf.to_owned(),
                    weight: sample.weight,
                    seek_time_seconds: sample.local_time_seconds,
                })
                .collect(),
            weight: self.action_weight(request.transition_seconds),
        }))
    }

    fn animation_state(&self) -> Result<Option<ActionAnimationState>, ManualAnimationFailure> {
        let target = self.unblended_animation_state()?;
        let Some(transition) = self.visual_transition.as_ref() else {
            return Ok(target);
        };
        let Some(mut target) = target else {
            return Ok(None);
        };
        let progress =
            transition_in_weight(transition.elapsed_seconds, transition.duration_seconds);
        let source_contribution =
            transition.source_action_weight.clamp(0.0, 1.0) * (1.0 - progress);
        let target_contribution = target.weight.clamp(0.0, 1.0) * progress;
        let mut samples = transition
            .source_samples
            .iter()
            .cloned()
            .map(|mut sample| {
                if let Some(duration) = manual_visual_duration_seconds(&sample.clip) {
                    let advanced = sample.seek_time_seconds + transition.elapsed_seconds;
                    sample.seek_time_seconds = if manual_visual_repeats(&sample.clip) == Some(true)
                    {
                        advanced.rem_euclid(duration)
                    } else {
                        advanced.min(duration)
                    };
                }
                AnimationSample {
                    weight: sample.weight * source_contribution,
                    ..sample
                }
            })
            .collect::<Vec<_>>();
        samples.extend(target.samples.drain(..).map(|sample| AnimationSample {
            weight: sample.weight * target_contribution,
            ..sample
        }));
        target.samples = samples;
        target.weight = (source_contribution + target_contribution).clamp(0.0, 1.0);
        Ok(Some(target))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
#[allow(dead_code)] // Rail acquisition calls this integration boundary later.
pub enum BeginGrindError {
    Classification(GrindClassificationError),
    GraphRoute(UnknownCanonicalGrind),
}

#[derive(Clone, Debug, PartialEq)]
pub enum BeginGrindFromContactError {
    Provider(ChromosomeAssemblyError),
    Enum(GrindEnumValueError),
    Graph(BeginGrindError),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BeginRecoveredActionError {
    /// Retail ActionGraph arbitration has not selected this request because
    /// another recovered action currently owns the motion graph.
    MotionGraphOccupied,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RidingPostPhysicsState {
    pub plan: PostPhysicsPlan,
    pub queue_completion: ForceQueueCompletion,
}

/// Live transport for the recovered Flickit preprocessing and pattern database.
///
/// PatternNode progression and winner arbitration are exact. Retail invokes
/// them once per upstream input notification; because the outer Oracle-to-input
/// mapping is still unresolved, the live fixed-step geometry probe remains a
/// separate recognizer and cannot accidentally advance retail PatternNodes.
#[derive(Debug)]
pub struct TrickInputBridge {
    /// Exact notification-driven retail recognizer.
    pub recognizer: TrickInputRecognizer,
    geometry_probe_recognizer: TrickInputRecognizer,
    pub last_frame: Option<RecognitionFrame>,
    pub last_retail_frame: Option<RetailConfiguredRecognitionFrame>,
    pub probe_sample_count: u64,
    pub retail_notification_count: u64,
    fixed_tick_phase: u8,
}

impl Default for TrickInputBridge {
    fn default() -> Self {
        Self {
            recognizer: TrickInputRecognizer::new()
                .expect("embedded retail Flickit pattern files must parse"),
            geometry_probe_recognizer: TrickInputRecognizer::new()
                .expect("embedded retail Flickit pattern files must parse"),
            last_frame: None,
            last_retail_frame: None,
            probe_sample_count: 0,
            retail_notification_count: 0,
            fixed_tick_phase: 0,
        }
    }
}

impl TrickInputBridge {
    pub const fn cadence_label(&self) -> &'static str {
        "geometry_probe_60hz_not_retail"
    }

    pub const fn retail_cadence_label(&self) -> &'static str {
        "notification_driven_0x82859E70"
    }

    fn step_probe(&mut self, pad: CanonicalPadState, mirror_state: MirrorState) {
        // The project simulation is 120 Hz. Sampling every second fixed tick
        // gives the dual-run harness one observation per 60 Hz retail frame,
        // while the label above prevents this probe clock being mistaken for a
        // recovered recognizer cadence.
        self.fixed_tick_phase ^= 1;
        if self.fixed_tick_phase != 0 {
            return;
        }
        self.last_frame = Some(self.geometry_probe_recognizer.observe_raw(
            RawStickSample {
                x: pad.right_x,
                y: pad.right_y,
            },
            None,
            mirror_state,
        ));
        self.probe_sample_count = self.probe_sample_count.saturating_add(1);
    }

    /// Advance the exact retail PatternNode and winner path for one observed
    /// upstream input notification.
    #[allow(dead_code)]
    pub fn observe_retail_notification(
        &mut self,
        pad: CanonicalPadState,
        mirror_state: MirrorState,
        mode: MatcherMode,
    ) -> &RetailConfiguredRecognitionFrame {
        let processed =
            filter_recognizer_components(raw_right_stick_to_pattern_node(pad.right_x, pad.right_y));
        self.last_retail_frame =
            Some(
                self.recognizer
                    .observe_processed_retail(processed, None, mirror_state, mode),
            );
        self.retail_notification_count = self.retail_notification_count.saturating_add(1);
        self.last_retail_frame
            .as_ref()
            .expect("retail recognition frame was just stored")
    }

    /// Accept a winner captured from retail without replaying its preceding
    /// PatternNode notifications.
    #[allow(dead_code)]
    pub fn accept_observed_retail_winner(&mut self, id: PatternId) -> bool {
        self.recognizer.accept_resolved_candidate(id)
    }

    fn reset_retail_gesture_state(&mut self) {
        self.recognizer.reset_gesture_state();
        self.last_retail_frame = None;
    }

    pub fn processed_sample(&self) -> Stick2 {
        self.last_frame
            .as_ref()
            .map_or(Stick2::ZERO, |frame| frame.processed_sample)
    }

    pub fn geometry_candidate_count(&self) -> usize {
        self.last_frame
            .as_ref()
            .map_or(0, |frame| match &frame.pop {
                PopRecognition::NoGeometryCandidate => 0,
                PopRecognition::GeometryCandidates { candidates, .. } => candidates.len(),
            })
    }

    pub fn publication_status_label(&self) -> &'static str {
        self.last_frame
            .as_ref()
            .map_or("not_sampled", |frame| match frame.pop {
                PopRecognition::NoGeometryCandidate => "no_geometry_candidate",
                PopRecognition::GeometryCandidates { .. } => {
                    "blocked_pattern_node_timing_and_arbitration"
                }
            })
    }

    pub fn selected_contact_label(&self) -> &'static str {
        self.last_frame.as_ref().map_or("not_sampled", |frame| {
            match frame.selected_pattern_contact {
                SelectedPatternContact::NoSelectedPattern => "none",
                SelectedPatternContact::Held { .. } => "held",
                SelectedPatternContact::Released { .. } => "released",
            }
        })
    }

    pub fn retail_winner_name(&self) -> Option<&str> {
        self.last_retail_frame
            .as_ref()
            .and_then(|frame| frame.winner.as_ref().map(|(_, name)| name.as_str()))
    }

    pub fn retail_selected_pattern_held_name(&self) -> Option<&str> {
        self.recognizer.selected_pattern_held_name()
    }

    pub fn retail_selected_contact_label(&self) -> &'static str {
        self.last_retail_frame
            .as_ref()
            .map_or("not_sampled", |frame| {
                match frame.selected_pattern_contact {
                    SelectedPatternContact::NoSelectedPattern => "none",
                    SelectedPatternContact::Held { .. } => "held",
                    SelectedPatternContact::Released { .. } => "released",
                }
            })
    }
}

#[derive(Resource, Debug)]
pub struct SkateSim {
    pub position: Vec3,
    pub velocity: Vec3,
    pub yaw: f32,
    pub view_yaw: f32,
    pub yaw_rate: f32,
    pub body_spin_angle: f32,
    pub body_spin_velocity: f32,
    pub body_spin_animation_phase_seconds: f32,
    /// True once processed airborne lateral input crosses the existing body
    /// spin deadzone. This identifies whether the captured neutral landing
    /// fixture is still applicable without comparing accumulated float angle
    /// to exact zero.
    pub airborne_body_spin_input_observed: bool,
    pub planar_acceleration: Vec3,
    pub lateral_friction_rate: f32,
    pub last_contact_friction: ContactFrictionOutput,
    pub candidate_slide_weight: f32,
    pub candidate_slide_active: bool,
    pub left_stick: Vec2,
    pub right_stick: Vec2,
    pub left_trigger: f32,
    pub right_trigger: f32,
    pub steer: f32,
    /// Recovered SkaterAnim lateral-mirror provider. Kept separate from
    /// forward/fakie ownership until that graph route is recovered.
    pub slide_control_mirrored: bool,
    pub deck_roll: f32,
    pub deck_roll_velocity: f32,
    /// Logical nose/tail parity retained after an odd-shove catch. Retail
    /// maintains this through Skeleton::UpdateSkateboardOffsetTransform rather
    /// than blending the physical trick endpoint back through 180 degrees.
    board_reversed: bool,
    skateboard_offset_transition: Option<SkateboardOffsetTransition>,
    pub body_tilt: f32,
    pub wheel_spin: f32,
    pub ground_contact_valid: bool,
    pub ground_normal: Vec3,
    pub ground_surface_id: Option<u32>,
    pub transition: TransitionRuntime,
    pub board_authority: BoardAuthority,
    pub skateboard_body: SkateboardBodyState,
    pub contact_channels: [BodyContactChannel; BODY_COUNT],
    pub skateboard_airborne_time_seconds: f32,
    pub last_contact_bridge: Option<ContactBridgeOutput>,
    pub foot_placement: FootPlacementCoordinator,
    pub last_foot_placement: Option<FootPlacementOutput>,
    pub riding_force_queue: SkateboardForceQueue,
    pub last_riding_post_physics: Option<RidingPostPhysicsState>,
    pub body_tilt_conditioner: BodyTiltState,
    pub offboard: Option<OffboardRuntime>,
    /// Mount animation retained after its retail physics handoff. This is
    /// presentation-only; onboard control and board physics already own the
    /// skater while it fades to riding.
    pub offboard_visual: Option<OffboardRuntime>,
    pub trick_input: TrickInputBridge,
    /// Character-selected stance. Retail keeps this persistent preference
    /// separate from `IsRidingSwitch`.
    pub natural_stance: NaturalStance,
    pub fakie: FakieRuntime,
    pub active_trick_context: Option<TrickContext>,
    pub anticipation: Option<AnticipationRuntime>,
    pub push_anticipation_handoff: Option<PushAnticipationHandoff>,
    pub trick_handoff: Option<ActionHandoff>,
    pub basic_trick: Option<BasicTrickPlayback>,
    pub air_trick: Option<AirTrickPlayback>,
    pub grab: Option<GrabPlayback>,
    pub grab_pre_adjust: GrabTweakDirection,
    pub landing: Option<LandingPlayback>,
    pub grind: Option<GrindPlayback>,
    pub manual: Option<ManualPlayback>,
    pub manual_riding_handoff: Option<ManualRidingHandoff>,
    pub manual_control: ManualControlState,
    pub manual_deck_contact: ManualDeckContact,
    pub deck_pitch: f32,
    pub pop_motion: Option<PopMotion>,
    pub landed_this_step: bool,
    /// Maximum positive-magnitude downward projection accumulated while the
    /// retail physics state is airborne and later published as `AVGVELY`.
    /// The value survives contact long enough for `SetLandingData` to copy it
    /// into BLEND_LAND.
    pub landing_average_velocity_y: f32,
    pub landing_random: RetailLandingRandom,
    /// Last integer written to the shared RANDOM animation attribute by
    /// ChooseRandomLanding. Spin/Nice does not invoke the chooser and therefore
    /// retains this value, matching Landing.xml.
    pub landing_random_attribute: u8,
    pub last_landing_decision_input: Option<LandingDecisionInput>,
    pub last_landing_admission: Option<LandingAdmission>,
    pub push: Option<PushRuntime>,
    pub brake: Option<BrakeRuntime>,
    pub slide: Option<SlideRuntime>,
    pub random_idle: Option<RandomIdleRuntime>,
    pub brake_hold_time: f32,
    pub brake_active: bool,
    pub powerslide_rotation: f32,
    pub idle_no_input_time: f32,
    pub animation_clip: Option<String>,
    pub animation_speed: f32,
    pub animation_repeat: bool,
    pub animation_transition_seconds: f32,
    pub animation_sequence: bool,
    pub animation_revision: u64,
    pub ride_phase_time: f32,
    pub elapsed: f32,
    pub last_push_elapsed: f32,
    random_idle_counter: u32,
    push_cooldown: f32,
    retail_animation_accumulator: f32,
}

impl Default for SkateSim {
    fn default() -> Self {
        Self {
            position: Vec3::ZERO,
            velocity: Vec3::ZERO,
            yaw: 0.0,
            view_yaw: 0.0,
            yaw_rate: 0.0,
            body_spin_angle: 0.0,
            body_spin_velocity: 0.0,
            body_spin_animation_phase_seconds: 0.0,
            airborne_body_spin_input_observed: false,
            planar_acceleration: Vec3::ZERO,
            lateral_friction_rate: 0.0,
            last_contact_friction: ContactFrictionOutput::default(),
            candidate_slide_weight: 0.0,
            candidate_slide_active: false,
            left_stick: Vec2::ZERO,
            right_stick: Vec2::ZERO,
            left_trigger: 0.0,
            right_trigger: 0.0,
            steer: 0.0,
            slide_control_mirrored: false,
            deck_roll: 0.0,
            deck_roll_velocity: 0.0,
            board_reversed: false,
            skateboard_offset_transition: None,
            body_tilt: 0.0,
            wheel_spin: 0.0,
            ground_contact_valid: true,
            ground_normal: Vec3::Y,
            ground_surface_id: Some(1),
            transition: TransitionRuntime::default(),
            board_authority: BoardAuthority::Physics,
            skateboard_body: SkateboardBodyState::default(),
            contact_channels: [BodyContactChannel::default(); BODY_COUNT],
            skateboard_airborne_time_seconds: 0.0,
            last_contact_bridge: None,
            foot_placement: FootPlacementCoordinator::new(),
            last_foot_placement: None,
            riding_force_queue: SkateboardForceQueue::default(),
            last_riding_post_physics: None,
            body_tilt_conditioner: BodyTiltState::default(),
            offboard: None,
            offboard_visual: None,
            trick_input: TrickInputBridge::default(),
            natural_stance: NaturalStance::Regular,
            fakie: FakieRuntime::default(),
            active_trick_context: None,
            anticipation: None,
            push_anticipation_handoff: None,
            trick_handoff: None,
            basic_trick: None,
            air_trick: None,
            grab: None,
            grab_pre_adjust: GrabTweakDirection::Neutral,
            landing: None,
            grind: None,
            manual: None,
            manual_riding_handoff: None,
            manual_control: ManualControlState::default(),
            manual_deck_contact: ManualDeckContact::default(),
            deck_pitch: 0.0,
            pop_motion: None,
            landed_this_step: false,
            landing_average_velocity_y: 0.0,
            landing_random: RetailLandingRandom::default(),
            landing_random_attribute: 0,
            last_landing_decision_input: None,
            last_landing_admission: None,
            push: None,
            brake: None,
            slide: None,
            random_idle: None,
            brake_hold_time: 0.0,
            brake_active: false,
            powerslide_rotation: 0.0,
            idle_no_input_time: 0.0,
            animation_clip: None,
            animation_speed: 1.0,
            animation_repeat: false,
            animation_transition_seconds: 0.2,
            animation_sequence: false,
            animation_revision: 0,
            ride_phase_time: INITIAL_RIDE_PHASE_SECONDS,
            elapsed: 0.0,
            last_push_elapsed: -10.0,
            random_idle_counter: 0,
            push_cooldown: 0.0,
            retail_animation_accumulator: 0.0,
        }
    }
}

impl SkateSim {
    pub fn speed(&self) -> f32 {
        self.transition.speed(self.velocity)
    }

    pub fn local_longitudinal_speed(&self) -> f32 {
        if self.transition.is_enabled() {
            self.transition.longitudinal_speed(self.velocity)
        } else {
            local_velocity(self.velocity, self.yaw).longitudinal
        }
    }

    pub fn local_lateral_speed(&self) -> f32 {
        if self.transition.is_enabled() {
            let right = self
                .transition
                .support_up
                .cross(self.transition.support_forward)
                .normalize_or(Vec3::X);
            self.velocity.dot(right)
        } else {
            local_velocity(self.velocity, self.yaw).lateral
        }
    }

    pub fn state_label(&self) -> &'static str {
        if let Some(offboard) = &self.offboard {
            return offboard.state_label();
        }
        if let Some(anticipation) = &self.anticipation {
            return match anticipation.phase {
                AnticipationPhase::Into => "trick anticipation into",
                AnticipationPhase::Cycle => "trick anticipation",
                AnticipationPhase::Out => "trick anticipation out",
                AnticipationPhase::Complete => "trick anticipation complete",
            };
        }
        if let Some(playback) = &self.basic_trick {
            return match playback.runtime.phase {
                BasicTrickPhase::GroundLeaf => "basic trick ground",
                BasicTrickPhase::AirLeaf => "basic trick air",
                BasicTrickPhase::AirBaseline => "airborne",
                BasicTrickPhase::Landing { .. } => "landing",
                BasicTrickPhase::PostLandLockout => "post-land lockout",
                BasicTrickPhase::Complete => "basic trick complete",
            };
        }
        if let Some(playback) = &self.landing {
            return match playback.runtime.quality {
                LandingQuality::Spin => "spin landing",
                LandingQuality::Sketchy => "sketchy landing",
                LandingQuality::Straight => "straight landing",
            };
        }
        if let Some(playback) = &self.grab {
            return match playback.runtime.phase {
                GrabPhase::Into => "grab into",
                GrabPhase::Cycle => playback.trick.label(),
                GrabPhase::Out => "grab out",
                GrabPhase::ToDouble => "grab to double",
                GrabPhase::FromDouble => "grab from double",
                GrabPhase::Complete => "grab complete",
                GrabPhase::WipeOut => "grab wipeout",
                GrabPhase::Land => "grab landing",
                GrabPhase::ToOffBoard => "grab dismount",
                GrabPhase::ExternalBranch(_) => "grab external branch",
            };
        }
        if let Some(playback) = &self.air_trick {
            return match playback.runtime.phase {
                AirTrickPhase::GrindOut => "air trick grind out",
                AirTrickPhase::TakeoffGround => "air trick takeoff",
                AirTrickPhase::LeftGroundAir => "air trick",
                AirTrickPhase::FlipCycle(_) => "air trick cycle",
                AirTrickPhase::FlipOut(_) => "air trick out",
                AirTrickPhase::Complete(_) => "air trick complete",
            };
        }
        if let Some(playback) = &self.grind {
            return match playback.runtime.phase {
                GrindPhase::Cycle => "grinding",
                GrindPhase::GrabInto => "grind grab into",
                GrindPhase::GrabCycle => "grind grab",
                GrindPhase::GrabOut => "grind grab out",
                GrindPhase::ExitingToAir => "grind air exit",
                GrindPhase::TrickOut => "grind trick out",
                GrindPhase::Complete => "grind complete",
            };
        }
        if let Some(playback) = &self.manual {
            return match playback.runtime.phase {
                ManualPhase::NoseInto => "nose manual into",
                ManualPhase::Cycle => match playback.runtime.kind {
                    ManualKind::Tail => "manual",
                    ManualKind::Nose => "nose manual",
                },
                ManualPhase::Brake => "manual brake",
                ManualPhase::NoseOut => "nose manual out",
                ManualPhase::Revert(_) => "manual revert",
                ManualPhase::ExitRequested => "manual exit",
                ManualPhase::Complete => "manual complete",
            };
        }
        if let Some(slide) = &self.slide {
            return match slide.phase {
                SlidePhase::Into | SlidePhase::Cycle => slide.side.label(),
                SlidePhase::Out(_) => "powerslide out",
            };
        }
        if let Some(brake) = &self.brake {
            return brake.phase.label();
        }
        if let Some(push) = &self.push {
            return push.phase.label();
        }
        if self.transition.phase == TransitionPhase::Airborne {
            return "transition air";
        }
        if self.fakie.is_riding_fakie() {
            return self.fakie.phase.label();
        }
        if self.fakie.is_riding_switch() {
            return "switch";
        }
        if self.random_idle.is_some() {
            return "stationary idle";
        }
        if self.speed() > 0.25 {
            "rolling"
        } else {
            "idle"
        }
    }

    fn reset(&mut self, spawn: LevelSpawn) {
        let revision = self.animation_revision.wrapping_add(1);
        let natural_stance = self.natural_stance;
        *self = Self::default();
        self.position = spawn.position;
        self.yaw = spawn.yaw;
        self.view_yaw = spawn.yaw;
        self.animation_revision = revision;
        // Respawn/reset does not rewrite the skater's CAC stance setting.
        self.natural_stance = natural_stance;
    }

    fn set_animation(
        &mut self,
        clip: Option<String>,
        repeat: bool,
        transition_seconds: f32,
        sequence: bool,
    ) {
        self.animation_clip = clip;
        self.animation_speed = 1.0;
        self.animation_repeat = repeat;
        self.animation_transition_seconds = transition_seconds;
        self.animation_sequence = sequence;
        self.animation_revision = self.animation_revision.wrapping_add(1);
    }

    fn set_animation_from_push(&mut self) {
        let Some(push) = &self.push else {
            self.set_animation(None, false, 0.2, false);
            return;
        };
        let transition = match push.phase {
            PushPhase::Into => 0.3,
            PushPhase::Contact | PushPhase::Cycle => 0.0,
            PushPhase::Out => 0.2,
        };
        let sequence = matches!(push.phase, PushPhase::Contact | PushPhase::Cycle);
        self.set_animation(Some(push.animation_clip()), false, transition, sequence);
    }

    fn set_animation_from_brake(&mut self) {
        let Some(brake) = &self.brake else {
            self.set_animation(None, false, 0.2, false);
            return;
        };
        let clip = brake.animation_clip(self.speed()).to_owned();
        let repeats = brake.repeats();
        self.set_animation(Some(clip), repeats, 0.2, false);
    }

    fn set_animation_from_slide(&mut self) {
        let Some(slide) = &self.slide else {
            self.set_animation(None, false, 0.2, false);
            return;
        };
        let repeat = slide.phase == SlidePhase::Cycle;
        let transition = match slide.phase {
            SlidePhase::Into => SLIDE_INTO_BLEND_SECONDS,
            SlidePhase::Cycle => SLIDE_CYCLE_BLEND_SECONDS,
            SlidePhase::Out(_) => SLIDE_OUT_BLEND_SECONDS,
        };
        self.set_animation(Some(slide.animation_clip()), repeat, transition, false);
    }

    fn set_animation_from_random_idle(&mut self) {
        let Some(idle) = &self.random_idle else {
            self.set_animation(None, false, 0.2, false);
            return;
        };
        self.set_animation(Some(idle.animation_clip().to_owned()), false, 0.2, false);
    }

    pub fn action_animation_state(&self) -> ActionAnimationState {
        if let Some(offboard) = &self.offboard {
            return validated_offboard_animation_state(offboard);
        }
        if let Some(offboard_visual) = &self.offboard_visual {
            return validated_offboard_animation_state(offboard_visual);
        }
        if let Some(anticipation) = &self.anticipation {
            let target = action_state_from_anticipation(anticipation.animation_state());
            return self.apply_trick_handoff(self.apply_push_anticipation_handoff(target));
        }
        if let Ok(Some(state)) = self.landing_animation_state() {
            return self.apply_trick_handoff(state);
        }
        if let Ok(Some(state)) = self.grab_animation_state() {
            return self.apply_body_spin_overlay(self.apply_trick_handoff(state));
        }
        if self.grab.is_some() {
            // The adapter returns typed unresolved/missing-asset failures; an
            // unverified resource is never forwarded to Bevy.
            return ActionAnimationState::default();
        }
        if let Ok(Some(state)) = self.basic_trick_animation_state() {
            return self.apply_body_spin_overlay(self.apply_trick_handoff(state));
        }
        if let Ok(Some(state)) = self.air_trick_animation_state() {
            return self.apply_body_spin_overlay(self.apply_trick_handoff(state));
        }
        if self.air_trick.is_some() {
            // Typed adapter failures block unresolved trees, blend weights,
            // and physical leaves absent from the pinned GLB.
            return ActionAnimationState::default();
        }
        if self.grind.is_some() {
            // Grind graph resources remain virtual until selected-leaf
            // telemetry establishes their concrete ABIN leaves.
            return ActionAnimationState::default();
        }
        if let Ok(Some(state)) = self.manual_animation_state() {
            return state;
        }
        if self.manual.is_some() {
            // The evidence-gated adapter blocks unresolved selectors and
            // physical leaves absent from the pinned Bevy asset. Tail has no
            // authored OUT leaf, so its retained source can still be blending
            // to riding while the physical out timer owns Manual.
            return self.apply_manual_riding_handoff(ActionAnimationState::default());
        }
        if let Some(push) = &self.push {
            return self.apply_manual_riding_handoff(self.apply_trick_handoff(
                ActionAnimationState {
                    samples: push.transition_samples(),
                    weight: push_action_weight(push),
                },
            ));
        }
        if let Some(brake) = &self.brake {
            return self.apply_manual_riding_handoff(ActionAnimationState {
                samples: brake.animation_samples(self.speed()),
                weight: match brake.phase {
                    BrakePhase::MovingInto | BrakePhase::StandInto => {
                        transition_in_weight(brake.phase_time, 0.2)
                    }
                    BrakePhase::MovingOut | BrakePhase::StandOut => {
                        transition_out_weight(brake.phase_time, 0.2)
                    }
                    _ => 1.0,
                },
            });
        }
        if let Some(slide) = &self.slide {
            return self.apply_manual_riding_handoff(ActionAnimationState {
                samples: slide.transition_samples(),
                weight: match slide.phase {
                    SlidePhase::Into => {
                        transition_in_weight(slide.phase_time, SLIDE_INTO_BLEND_SECONDS)
                    }
                    SlidePhase::Cycle | SlidePhase::Out(_) => 1.0,
                },
            });
        }
        let fakie = self.fakie.presentation(self.ride_phase_time);
        if fakie.weight > f32::EPSILON {
            return self.apply_trick_handoff(ActionAnimationState {
                samples: fakie
                    .samples
                    .into_iter()
                    .map(|sample| AnimationSample {
                        clip: sample.clip.to_owned(),
                        weight: sample.weight,
                        seek_time_seconds: sample.seek_time_seconds,
                    })
                    .collect(),
                weight: fakie.weight,
            });
        }
        if let Some(idle) = &self.random_idle {
            return self.apply_manual_riding_handoff(ActionAnimationState {
                samples: vec![AnimationSample {
                    clip: idle.animation_clip().to_owned(),
                    weight: 1.0,
                    seek_time_seconds: idle.phase_time,
                }],
                weight: transition_in_weight(idle.phase_time, 0.2),
            });
        }
        self.apply_manual_riding_handoff(self.apply_trick_handoff(ActionAnimationState::default()))
    }

    fn apply_manual_riding_handoff(&self, target: ActionAnimationState) -> ActionAnimationState {
        let Some(handoff) = &self.manual_riding_handoff else {
            return target;
        };
        let progress = transition_in_weight(handoff.elapsed_seconds, handoff.duration_seconds);
        let source_contribution = handoff.source.weight.clamp(0.0, 1.0) * (1.0 - progress);
        let target_contribution = target.weight.clamp(0.0, 1.0) * progress;
        let mut samples = handoff
            .source
            .samples
            .iter()
            .cloned()
            .map(|mut sample| {
                if let Some(duration) = manual_visual_duration_seconds(&sample.clip) {
                    let advanced = sample.seek_time_seconds + handoff.elapsed_seconds;
                    sample.seek_time_seconds = if manual_visual_repeats(&sample.clip) == Some(true)
                    {
                        advanced.rem_euclid(duration)
                    } else {
                        advanced.min(duration)
                    };
                }
                sample.weight *= source_contribution;
                sample
            })
            .collect::<Vec<_>>();
        samples.extend(target.samples.into_iter().map(|mut sample| {
            sample.weight *= target_contribution;
            sample
        }));
        ActionAnimationState {
            samples,
            weight: (source_contribution + target_contribution).clamp(0.0, 1.0),
        }
    }

    fn apply_trick_handoff(&self, target: ActionAnimationState) -> ActionAnimationState {
        let Some(handoff) = &self.trick_handoff else {
            return target;
        };
        let progress = transition_in_weight(handoff.elapsed_seconds, handoff.duration_seconds);
        let source_contribution = handoff.source.weight.clamp(0.0, 1.0) * (1.0 - progress);
        let target_contribution = target.weight.clamp(0.0, 1.0) * progress;
        let mut samples = handoff
            .source
            .samples
            .iter()
            .cloned()
            .map(|sample| AnimationSample {
                weight: sample.weight * source_contribution,
                ..sample
            })
            .collect::<Vec<_>>();
        samples.extend(target.samples.into_iter().map(|sample| AnimationSample {
            weight: sample.weight * target_contribution,
            ..sample
        }));
        ActionAnimationState {
            samples,
            weight: (source_contribution + target_contribution).clamp(0.0, 1.0),
        }
    }

    fn apply_push_anticipation_handoff(
        &self,
        target: ActionAnimationState,
    ) -> ActionAnimationState {
        let Some(handoff) = &self.push_anticipation_handoff else {
            return target;
        };
        let progress =
            transition_in_weight(handoff.elapsed_seconds, PUSH_TO_ANTICIPATION_BLEND_SECONDS);
        let source_weight = if handoff.bridge_clip.is_some() {
            1.0
        } else {
            handoff.source.weight.clamp(0.0, 1.0)
        };
        let source_contribution = source_weight * (1.0 - progress);
        let source = handoff.bridge_clip.map_or_else(
            || handoff.source.samples.clone(),
            |clip| {
                vec![AnimationSample {
                    clip: clip.to_owned(),
                    weight: 1.0,
                    seek_time_seconds: handoff
                        .elapsed_seconds
                        .min(PUSH_TO_ANTICIPATION_BLEND_SECONDS),
                }]
            },
        );
        let mut samples = source
            .into_iter()
            .map(|sample| AnimationSample {
                weight: sample.weight * source_contribution,
                ..sample
            })
            .collect::<Vec<_>>();
        // AnticInto has its own riding-entry weight. The retail transition
        // hook overrides that entry with the push blend, so use its normalized
        // child weights here instead of multiplying the 0.2-second ramp twice.
        samples.extend(target.samples.into_iter().map(|sample| AnimationSample {
            weight: sample.weight * progress,
            ..sample
        }));
        ActionAnimationState {
            samples,
            weight: (source_contribution + progress).clamp(0.0, 1.0),
        }
    }

    fn apply_body_spin_overlay(&self, mut target: ActionAnimationState) -> ActionAnimationState {
        if self.ground_contact_valid
            || self.body_spin_velocity.abs() <= BODY_SPIN_INPUT_DEADZONE
            || target.weight <= f32::EPSILON
        {
            return target;
        }
        let clip = if self.body_spin_velocity > 0.0 {
            BODY_SPIN_BACKSIDE_CLIP
        } else {
            BODY_SPIN_FRONTSIDE_CLIP
        };
        target.samples.push(AnimationSample {
            clip: clip.to_owned(),
            // BodySpin::Update filters the physics intent before sending it to
            // the directional upper-body animation. The observed speed/cap
            // ratio is retained as that endpoint coordinate.
            weight: (self.body_spin_velocity.abs() / BODY_SPIN_MAXIMUM_SPEED).clamp(0.0, 1.0),
            seek_time_seconds: self.body_spin_animation_phase_seconds,
        });
        target
    }

    /// Resolve the active basic trick through the physical animation catalog.
    ///
    /// A typed error is returned for still-unresolved retail virtual resources;
    /// callers never receive a guessed substitute clip.
    pub fn basic_trick_animation_state(
        &self,
    ) -> Result<Option<ActionAnimationState>, UnresolvedTrickAnimation> {
        self.basic_trick
            .as_ref()
            .map(BasicTrickPlayback::animation_state)
            .unwrap_or(Ok(None))
    }

    /// Resolve the active grab through the evidence-backed physical animation
    /// adapter. Virtual blend resources and clips absent from the pinned GLB
    /// remain typed failures.
    pub fn grab_animation_state(
        &self,
    ) -> Result<Option<ActionAnimationState>, GrabAnimationFailure> {
        self.grab
            .as_ref()
            .map(GrabPlayback::animation_state)
            .unwrap_or(Ok(None))
    }

    pub fn landing_animation_state(
        &self,
    ) -> Result<Option<ActionAnimationState>, UnresolvedTrickAnimation> {
        self.landing
            .as_ref()
            .map(LandingPlayback::animation_state)
            .transpose()
    }

    pub fn manual_animation_state(
        &self,
    ) -> Result<Option<ActionAnimationState>, ManualAnimationFailure> {
        self.manual
            .as_ref()
            .map(ManualPlayback::animation_state)
            .unwrap_or(Ok(None))
    }

    pub fn air_trick_animation_state(
        &self,
    ) -> Result<Option<ActionAnimationState>, AirTrickAnimationFailure> {
        self.air_trick
            .as_ref()
            .map(AirTrickPlayback::animation_state)
            .unwrap_or(Ok(None))
    }

    /// Supply one completed seven-body pose/compression step. Retail's contact
    /// record reducer is the separate `apply_recovered_contact_bridge` path;
    /// this method never fabricates those 96-byte records.
    #[allow(dead_code)] // Awaiting the recovered per-wheel solver bridge.
    pub fn apply_skateboard_post_physics(
        &mut self,
        step: u64,
        contacts: [WheelContact; 4],
        body_poses: BodyPoseSet,
    ) -> PostPhysicsOutput {
        let pose_authority = match self.board_authority {
            BoardAuthority::Physics => PoseAuthority::Physics,
            BoardAuthority::FollowAnimationData => PoseAuthority::FollowAnimationData,
            BoardAuthority::Animation => PoseAuthority::Animation,
        };
        self.skateboard_body.update_post_physics(PostPhysicsInput {
            step,
            contacts,
            body_poses,
            pose_authority,
        })
    }

    /// Apply the exact recovered TU3 contact-record reduction while preserving
    /// persistent channels and airborne time across fixed steps.
    ///
    /// The unresolved wheel-normal angle threshold remains a typed caller
    /// requirement. This result is deliberately not projected into the older
    /// compression bridge because that relation has not been proven.
    #[allow(dead_code)] // Physics backend supplies retail-shaped contact records.
    pub fn apply_recovered_contact_bridge(
        &mut self,
        fixed_delta_seconds: f32,
        reference_direction: SkateboardVector3,
        records: &[ContactRecord],
        wheels: [WheelBridgeInput; 4],
        force_dominant_surface_12: bool,
    ) -> Result<&ContactBridgeOutput, SolverError> {
        let output = bridge_post_physics(ContactBridgeInput {
            fixed_delta_seconds,
            reference_direction,
            records,
            previous_channels: self.contact_channels,
            wheels,
            force_dominant_surface_12,
            previous_airborne_time_seconds: self.skateboard_airborne_time_seconds,
        })?;
        self.contact_channels = output.channels;
        self.skateboard_airborne_time_seconds = output.airborne_time_seconds;
        self.last_contact_bridge = Some(output);
        Ok(self
            .last_contact_bridge
            .as_ref()
            .expect("contact bridge output was just stored"))
    }

    /// Coordinate authored compact toe targets and externally observed contact
    /// events before the existing Bevy two-bone solver consumes them.
    #[allow(dead_code)] // Animation channel/marker extractor supplies frames.
    pub fn apply_foot_placement_frame(
        &mut self,
        frame: FootPlacementFrame,
    ) -> Result<&FootPlacementOutput, FootPlacementError> {
        let output = self.foot_placement.step(frame)?;
        self.last_foot_placement = Some(output);
        Ok(self
            .last_foot_placement
            .as_ref()
            .expect("foot-placement output was just stored"))
    }

    #[allow(dead_code)] // Used by recovered force producers as they are integrated.
    pub fn add_skateboard_force(&mut self, force: SkateboardForce) -> bool {
        self.riding_force_queue.add(force)
    }

    /// Resolve the observed top-level post-physics branch and its exact queue
    /// lifetime. The force/contact solver remains a separate recovered module.
    #[allow(dead_code)] // Used by the recovered solver bridge.
    pub fn complete_riding_post_physics(
        &mut self,
        input: PostPhysicsBranchInput,
    ) -> RidingPostPhysicsState {
        let plan = plan_post_physics(input);
        let queue_completion = complete_force_queue(&mut self.riding_force_queue, plan);
        let state = RidingPostPhysicsState {
            plan,
            queue_completion,
        };
        self.last_riding_post_physics = Some(state);
        state
    }

    /// Advance TU3's exact discrete body-tilt conditioner only when all
    /// point-graph, orientation, and clamp inputs are evidence-backed.
    #[allow(dead_code)] // Live point-graph and clamp inputs are still unresolved.
    pub fn step_recovered_body_tilt(
        &mut self,
        evidence: BodyTiltFrameEvidence,
    ) -> Result<Option<BodyTiltOutput>, BodyTiltStepError> {
        self.body_tilt_conditioner.step(evidence)
    }

    /// Enter a recovered non-basic flip/shuv graph only after an external
    /// retail ActionGraph winner has been observed.
    #[allow(dead_code)] // Awaiting recovered Flickit winner publication.
    pub fn begin_air_trick(
        &mut self,
        trick: AirTrick,
        entry: AirTrickEntry,
        height: AirTrickHeight,
    ) -> Result<(), BeginRecoveredActionError> {
        if self.basic_trick.is_some()
            || self.air_trick.is_some()
            || self.grab.is_some()
            || self.grind.is_some()
            || self.manual.is_some()
        {
            return Err(BeginRecoveredActionError::MotionGraphOccupied);
        }
        self.push = None;
        self.brake = None;
        self.slide = None;
        self.random_idle = None;
        self.anticipation = None;
        self.push_anticipation_handoff = None;
        self.trick_handoff = None;
        self.pop_motion = None;
        self.landed_this_step = false;
        self.body_spin_angle = 0.0;
        self.body_spin_velocity = 0.0;
        self.body_spin_animation_phase_seconds = 0.0;
        self.airborne_body_spin_input_observed = false;
        let runtime = AirTrickRuntime::begin(trick, entry, height);
        self.board_authority = runtime.board_authority;
        self.air_trick = Some(AirTrickPlayback {
            runtime,
            phase_time_seconds: 0.0,
            completion_source_segment: None,
        });
        Ok(())
    }

    /// Advance the air-trick graph using externally recovered contact,
    /// animation-expiry, and handoff signals.
    #[allow(dead_code)] // Called by the recovered air/contact integration.
    pub fn step_air_trick(
        &mut self,
        delta_seconds: f32,
        signals: AirTrickSignals,
    ) -> Option<AirTrickStepOutcome> {
        let playback = self.air_trick.as_mut()?;
        let previous_phase = playback.runtime.phase;
        let previous_segment = playback
            .runtime
            .animation_request()
            .map(|request| request.segment);
        let outcome = playback.runtime.step(signals);
        if delta_seconds.is_finite() && delta_seconds >= 0.0 {
            if playback.runtime.phase == previous_phase {
                playback.phase_time_seconds += delta_seconds;
            } else {
                playback.phase_time_seconds = 0.0;
            }
        }
        self.board_authority = playback.runtime.board_authority;
        let retain_sequence_air_finish = matches!(
            outcome,
            AirTrickStepOutcome::Completed(crate::air_trick_graph::HandoffTarget::InAir)
        );
        if retain_sequence_air_finish {
            playback.completion_source_segment = previous_segment;
        }
        let reverses_board = matches!(outcome, AirTrickStepOutcome::Completed(_))
            && playback.runtime.trick.reverses_board_orientation();
        if matches!(outcome, AirTrickStepOutcome::Completed(_)) && !retain_sequence_air_finish {
            self.air_trick = None;
        }
        if reverses_board {
            self.begin_board_reversal_transition();
        }
        Some(outcome)
    }

    /// Enter the recovered grab graph only after retail input/action
    /// arbitration has supplied the winning identity.
    #[allow(dead_code)] // Awaiting recovered action winner publication.
    pub fn begin_grab(&mut self, identity: GrabIdentity) -> Result<(), BeginRecoveredActionError> {
        let trick = match identity {
            GrabIdentity::Fs => GrabTrick::Fs,
            GrabIdentity::Bs => GrabTrick::Bs,
            GrabIdentity::Double => GrabTrick::Double,
            GrabIdentity::Mute => GrabTrick::Mute,
            GrabIdentity::Stale => GrabTrick::Stale,
            GrabIdentity::Coffin => GrabTrick::Coffin,
            GrabIdentity::Superman => GrabTrick::Superman,
        };
        self.begin_grab_trick(trick, GrabTweakDirection::Neutral, false)
    }

    pub fn begin_grab_trick(
        &mut self,
        trick: GrabTrick,
        entry_adjust: GrabTweakDirection,
        mirrored: bool,
    ) -> Result<(), BeginRecoveredActionError> {
        if self.grab.is_some()
            || self.grind.is_some()
            || self.manual.is_some()
            || self.landing.is_some()
        {
            return Err(BeginRecoveredActionError::MotionGraphOccupied);
        }
        // Preserve the evaluated lower-priority action at the exact admission
        // boundary. Air grabs must enter from the live pop/flip pose rather
        // than from the riding tree underneath the action layer.
        let source = self.action_animation_state();
        self.push = None;
        self.brake = None;
        self.slide = None;
        self.random_idle = None;
        let runtime = GrabRuntime::begin(trick.base_identity());
        let domain = if self.ground_contact_valid {
            GrabDomain::Ground
        } else {
            GrabDomain::Air
        };
        self.board_authority = if domain == GrabDomain::Air {
            trick.board_authority()
        } else {
            BoardAuthority::Physics
        };
        self.grab = Some(GrabPlayback {
            runtime,
            trick,
            tweak: GrabTweakDirection::Neutral,
            entry_adjust,
            tweak_armed: entry_adjust == GrabTweakDirection::Neutral,
            phase_clip_override: None,
            domain,
            mirrored,
            phase_time_seconds: 0.0,
            animation_parameters: GrabAnimationParameters::None,
            blend_from: None,
            blend_sources: Vec::new(),
            blend_elapsed_seconds: 0.1,
            blend_duration_seconds: 0.1,
            tweak_filter_progress: None,
            tweak_filter_blending_out: false,
            tweak_filter_sources: Vec::new(),
            tweak_filter_velocity: 0.0,
            tweak_filter_retail_progress: 0.0,
            tweak_filter_pending_step: None,
            tweak_filter_accumulator_seconds: 0.0,
        });
        self.trick_handoff = Some(ActionHandoff {
            source,
            elapsed_seconds: 0.0,
            duration_seconds: 0.1,
        });
        Ok(())
    }

    /// Supply only filtered tweak coordinates observed at the retail graph
    /// boundary. Passing `None` restores the parameter-free contract.
    #[allow(dead_code)] // Selected-leaf telemetry supplies this boundary later.
    pub fn set_grab_animation_parameters(&mut self, parameters: GrabAnimationParameters) -> bool {
        let Some(playback) = self.grab.as_mut() else {
            return false;
        };
        playback.animation_parameters = parameters;
        true
    }

    /// Advance the grab graph with externally classified physics, landing, and
    /// ActionGraph branch signals.
    #[allow(dead_code)] // Called by the recovered air/contact integration.
    pub fn step_grab(&mut self, delta_seconds: f32, signals: GrabSignals) -> Option<GrabPhase> {
        let playback = self.grab.as_mut()?;
        if !delta_seconds.is_finite() || delta_seconds < 0.0 {
            return Some(playback.runtime.phase);
        }
        let previous_phase = playback.runtime.phase;
        playback.runtime.step(signals);
        if playback.runtime.phase == previous_phase {
            playback.phase_time_seconds += delta_seconds;
        } else {
            playback.phase_time_seconds = 0.0;
            playback.animation_parameters = GrabAnimationParameters::None;
        }
        playback.blend_elapsed_seconds += delta_seconds;
        self.board_authority = if playback.domain == GrabDomain::Air {
            BoardAuthority::Animation
        } else {
            BoardAuthority::Physics
        };
        let phase = playback.runtime.phase;
        if phase == GrabPhase::Complete {
            self.grab = None;
        }
        Some(phase)
    }

    pub fn active_grab_hands(&self) -> Option<PhysicalGrabHands> {
        self.grab
            .as_ref()
            .and_then(GrabPlayback::active_physical_hands)
    }

    pub fn active_grab_hand_ik(&self) -> Option<(PhysicalGrabHands, f32)> {
        self.grab
            .as_ref()
            .and_then(GrabPlayback::hand_ik_constraint)
    }

    pub fn active_grab_foot_release(&self) -> GrabFootRelease {
        self.grab
            .as_ref()
            .filter(|playback| {
                !matches!(playback.runtime.phase, GrabPhase::Out | GrabPhase::Complete)
            })
            .map_or(GrabFootRelease::None, |playback| {
                playback.trick.foot_release()
            })
    }

    /// Apply the recovered landing admission boundary using provider decisions,
    /// then hand the exact resource identity into an active basic trick.
    ///
    /// No tilt, contact, or runout thresholds are reconstructed here: their
    /// retail provider results are explicit optional inputs.
    #[allow(dead_code)] // Contact/landing providers call this boundary.
    pub fn arbitrate_and_begin_landing(
        &mut self,
        filtered_state: FilteredPhysicsState,
        tilt_too_large_for_preland: Option<bool>,
        physics_wants_runout: Option<bool>,
        provider_code: Option<LandingTypeCode>,
        straight_landing_parameters: Option<StraightLandingParameters>,
    ) -> LandingAdmission {
        let admission = arbitrate_landing_admission(
            filtered_state,
            tilt_too_large_for_preland,
            physics_wants_runout,
            provider_code,
        );
        self.last_landing_admission = Some(admission);
        let LandingAdmission::Enter(quality) = admission else {
            return admission;
        };

        let resource = match quality {
            LandingQuality::Spin => LandingAnimationResource::Nice,
            LandingQuality::Sketchy => LandingAnimationResource::Sketchy,
            LandingQuality::Straight => LandingAnimationResource::Straight,
        };
        if self.basic_trick.is_some() {
            self.step_basic_trick(
                0.0,
                BasicTrickSignals {
                    landed: Some(resource),
                    ..BasicTrickSignals::default()
                },
                straight_landing_parameters,
            );
        }
        self.air_trick = None;
        self.grab = None;
        self.grind = None;
        self.manual = None;
        self.push = None;
        self.brake = None;
        self.slide = None;
        self.random_idle = None;
        self.board_authority = BoardAuthority::Physics;
        self.landing = Some(LandingPlayback {
            runtime: LandingRuntime::begin(quality),
            selected_variant: straight_landing_parameters
                .map(|parameters| landing_variant_index(parameters.variant)),
            straight_landing_parameters,
            straight_landing_blend: None,
            tree_parameters: None,
            non_straight_axes: None,
        });
        admission
    }

    /// Preserve the complete touchdown observation alongside the authoritative
    /// provider-based admission result.
    #[allow(dead_code)] // External retail landing-data providers use this seam.
    pub fn arbitrate_and_begin_observed_landing(
        &mut self,
        input: LandingDecisionInput,
        straight_landing_parameters: Option<StraightLandingParameters>,
    ) -> LandingAdmission {
        self.last_landing_decision_input = Some(input);
        self.arbitrate_and_begin_landing(
            input.filtered_state,
            input.tilt_too_large_for_preland,
            input.physics_wants_runout,
            input.provider_code,
            straight_landing_parameters,
        )
    }

    /// Supply an explicit decoded endpoint for isolated provider tests.
    ///
    /// Live measured landings evaluate the recovered B_LAND_NICE /
    /// B_LAND_SKETCH tree through `LandingTreeParameters` instead.
    #[allow(dead_code)] // Retained as an explicit provider/unit-test seam.
    pub fn set_non_straight_landing_axes(
        &mut self,
        axes: NonStraightLandingAxes,
    ) -> Result<bool, LandingLeafUnresolved> {
        let Some(playback) = self.landing.as_mut() else {
            return Ok(false);
        };
        if playback.runtime.quality == LandingQuality::Straight {
            return Err(LandingLeafUnresolved::StraightUsesBlendLand);
        }
        playback.non_straight_axes = Some(axes);
        Ok(true)
    }

    /// Store a variant produced by retail RNG only after validating its range.
    #[allow(dead_code)] // Runtime selected-variant telemetry supplies this.
    pub fn set_landing_variant(&mut self, selected_variant: u8) -> Result<bool, LandingUnresolved> {
        let Some(playback) = self.landing.as_mut() else {
            return Ok(false);
        };
        let validated = playback
            .runtime
            .validate_external_variant(Some(selected_variant))?;
        playback.selected_variant = validated;
        if let Some(parameters) = playback.straight_landing_parameters.as_mut() {
            parameters.variant = landing_variant_from_index(selected_variant).ok_or(
                LandingUnresolved::RandomVariantOutOfRange {
                    variant: selected_variant,
                    variant_count: 3,
                },
            )?;
        }
        Ok(true)
    }

    /// Advance landing time and arbitrate exact authored exits. A taken target
    /// is returned to the caller that owns the destination state.
    #[allow(dead_code)] // ActionGraph target providers call this boundary.
    pub fn step_landing(
        &mut self,
        delta_seconds: f32,
        mut signals: LandingTransitionSignals,
    ) -> Option<LandingTransitionDecision> {
        let playback = self.landing.as_mut()?;
        if delta_seconds.is_finite() && delta_seconds >= 0.0 {
            playback.runtime.advance(delta_seconds);
        }
        signals.parent_state_time_seconds = playback.runtime.elapsed_seconds;
        let decision = arbitrate_landing_transition(playback.runtime.quality, signals);
        if matches!(decision, LandingTransitionDecision::Take(_)) {
            self.landing = None;
            self.body_spin_angle = 0.0;
            self.body_spin_velocity = 0.0;
            self.body_spin_animation_phase_seconds = 0.0;
            self.airborne_body_spin_input_observed = false;
        }
        Some(decision)
    }

    /// Enter a grind from the exact six-field TU3 chromosome plus externally
    /// resolved graph-resource/template selection. Rail acquisition and those
    /// virtual-resource choices are not inferred here.
    #[allow(dead_code)] // Rail classification supplies this boundary later.
    pub fn begin_grind(
        &mut self,
        chromosome: GrindChromosome,
        base_animation_resource: impl Into<String>,
        template: GrindTemplate,
    ) -> Result<(), BeginGrindError> {
        let classification = classify_grind(chromosome).map_err(BeginGrindError::Classification)?;
        let selection = GrindSelection::new(
            classification.canonical_name,
            base_animation_resource,
            template,
        )
        .map_err(BeginGrindError::GraphRoute)?;
        let runtime = GrindRuntime::begin(selection);
        debug_assert_eq!(runtime.board_authority, GrindBoardAuthority::Physics);
        self.board_authority = BoardAuthority::Physics;
        self.basic_trick = None;
        self.air_trick = None;
        self.grab = None;
        self.landing = None;
        self.manual = None;
        self.push = None;
        self.brake = None;
        self.slide = None;
        self.random_idle = None;
        self.grind = Some(GrindPlayback {
            classification,
            runtime,
        });
        Ok(())
    }

    /// Assemble a grind chromosome exclusively from retail provider digits,
    /// then enter the recovered classifier/graph boundary.
    #[allow(dead_code)] // Rail contact providers supply this boundary.
    pub fn begin_grind_from_contact_provider(
        &mut self,
        values: ChromosomeProviderValues,
        base_animation_resource: impl Into<String>,
        template: GrindTemplate,
    ) -> Result<(), BeginGrindFromContactError> {
        let raw = assemble_raw_chromosome(values).map_err(BeginGrindFromContactError::Provider)?;
        let chromosome =
            GrindChromosome::try_from(raw.as_array()).map_err(BeginGrindFromContactError::Enum)?;
        self.begin_grind(chromosome, base_animation_resource, template)
            .map_err(BeginGrindFromContactError::Graph)
    }

    #[allow(dead_code)] // Called by the rail/contact integration once supplied.
    pub fn step_grind(&mut self, signals: GrindSignals) {
        let Some(playback) = self.grind.as_mut() else {
            return;
        };
        playback.runtime.step(signals);
        self.board_authority = BoardAuthority::Physics;
        if playback.runtime.phase == GrindPhase::Complete {
            self.grind = None;
        }
    }

    /// Enter the recovered manual graph from an externally accumulated entry
    /// context and explicitly supplied board-local Z speed.
    #[allow(dead_code)] // Manual intent projection/engage accumulation is external.
    pub fn begin_manual(&mut self, entry: ManualEntryContext, board_local_speed_z: f32) -> bool {
        let Some(kind) = requested_manual_kind(entry) else {
            return false;
        };
        self.basic_trick = None;
        self.air_trick = None;
        self.grab = None;
        self.landing = None;
        self.grind = None;
        self.push = None;
        self.brake = None;
        self.slide = None;
        self.random_idle = None;
        self.manual_riding_handoff = None;
        self.manual = Some(ManualPlayback {
            entry,
            runtime: ManualRuntime::begin(kind, board_local_speed_z),
            balance_conditioner: ManualBalanceConditioner::new(),
            manual_angle_behaviour_active_last_step: false,
            manual_angle_update_accumulator_seconds: 0.0,
            phase_time_seconds: 0.0,
            total_time_seconds: 0.0,
            presentation_balance: entry.manual,
            out_timer_remaining_seconds: None,
            release_balance: entry.manual,
            visual_transition: None,
        });
        true
    }

    #[allow(dead_code)] // Called by the recovered balance/contact integration.
    pub fn step_manual(
        &mut self,
        delta_seconds: f32,
        signals: ManualSignals,
    ) -> Result<Option<ManualBalanceStep>, ManualBalanceInputError> {
        let Some(playback) = self.manual.as_mut() else {
            return Ok(None);
        };
        if let Some(transition) = playback.visual_transition.as_mut() {
            transition.elapsed_seconds += delta_seconds.max(0.0);
            if transition.elapsed_seconds >= transition.duration_seconds {
                playback.visual_transition = None;
            }
        }
        let source_animation = playback.animation_state().ok().flatten();
        let previous_resource = playback
            .runtime
            .animation_request()
            .map(|request| request.resource);
        let manual_angle_was_active = playback.manual_angle_behaviour_active_last_step;
        if playback.out_timer_remaining_seconds.is_none() {
            let same_side_intent = match playback.runtime.kind {
                ManualKind::Tail => signals.manual < 0.0,
                ManualKind::Nose => signals.manual > 0.0,
            };
            if signals.physics_wants_manual_exit || !same_side_intent {
                playback.out_timer_remaining_seconds = Some(TU3_MANUAL_OUT_TIMER_SECONDS);
                playback.release_balance = playback.presentation_balance;
            } else {
                playback.presentation_balance = signals.manual;
            }
        }
        let previous_phase = playback.runtime.phase;
        playback.runtime.step(signals);
        let manual_angle_is_active = playback.manual_angle_behaviour_active();
        let config = ManualBalanceConfig::tu3_retail()
            .validate()
            .expect("embedded TU3 manual balance configuration is valid");
        let mut balance_step = None;
        if manual_angle_is_active && !manual_angle_was_active {
            // `SetManualAngle` is owned by only the two rolling CYCLE children
            // that publish MANUAL_ANGLE. Entering either child constructs the
            // behaviour and calls Begin (0x82BA8C48), which clears +8/+12.
            // Nose INTO, both LOW bands, Brake, OUT, and Revert must not
            // pre-charge this state.
            playback.balance_conditioner.reset();
            playback.manual_angle_update_accumulator_seconds = 0.0;
            // The retail behaviour receives one Update on its first active
            // StateGraph frame.
            balance_step = Some(
                playback
                    .balance_conditioner
                    .update(signals.manual, &config)?,
            );
        } else if manual_angle_is_active {
            if delta_seconds.is_finite() && delta_seconds >= 0.0 {
                playback.manual_angle_update_accumulator_seconds += delta_seconds;
            }
            let animation_step = 1.0 / RETAIL_ANIMATION_HZ;
            while playback.manual_angle_update_accumulator_seconds + f32::EPSILON >= animation_step
            {
                playback.manual_angle_update_accumulator_seconds -= animation_step;
                balance_step = Some(
                    playback
                        .balance_conditioner
                        .update(signals.manual, &config)?,
                );
            }
        } else {
            playback.manual_angle_update_accumulator_seconds = 0.0;
        }
        playback.manual_angle_behaviour_active_last_step = manual_angle_is_active;
        let next_request = playback.runtime.animation_request();
        let next_resource = next_request.map(|request| request.resource);
        let animation_resource_changed = next_resource != previous_resource;
        if delta_seconds.is_finite() && delta_seconds >= 0.0 {
            playback.total_time_seconds += delta_seconds;
            if playback.runtime.phase == previous_phase && !animation_resource_changed {
                playback.phase_time_seconds += delta_seconds;
            } else {
                playback.phase_time_seconds = 0.0;
            }
        }
        if animation_resource_changed {
            playback.visual_transition = source_animation.clone().and_then(|source| {
                let duration_seconds = next_request?.transition_seconds;
                (duration_seconds > f32::EPSILON && !source.samples.is_empty()).then_some(
                    ManualVisualTransition {
                        source_samples: source.samples,
                        source_action_weight: source.weight,
                        elapsed_seconds: 0.0,
                        duration_seconds,
                    },
                )
            });
        }
        let began_tail_exit = playback.runtime.kind == ManualKind::Tail
            && previous_phase != ManualPhase::ExitRequested
            && playback.runtime.phase == ManualPhase::ExitRequested;
        let completed_nose_out = playback.runtime.kind == ManualKind::Nose
            && previous_phase == ManualPhase::NoseOut
            && playback.runtime.phase == ManualPhase::Complete;
        let riding_handoff_source = (began_tail_exit || completed_nose_out)
            .then_some(source_animation)
            .flatten();
        if let Some(remaining) = playback.out_timer_remaining_seconds.as_mut() {
            *remaining = (*remaining - delta_seconds.max(0.0)).max(0.0);
            playback.presentation_balance = playback.release_balance
                * (*remaining / TU3_MANUAL_OUT_TIMER_SECONDS).clamp(0.0, 1.0);
        }
        let tail_out_complete = playback.runtime.kind == ManualKind::Tail
            && playback.runtime.phase == ManualPhase::ExitRequested
            && playback.out_timer_remaining_seconds == Some(0.0);
        if playback.runtime.phase == ManualPhase::Complete || tail_out_complete {
            self.manual = None;
        }
        if let Some(source) = riding_handoff_source {
            // OnGround.RidingIdle.Riding.Turning.Idle.Default enters
            // BTREE_RIDING with PlayAnimation time="0.2". Tail has no
            // authored OUT resource; nose reaches this destination after its
            // authored OUT leaf expires.
            self.manual_riding_handoff = Some(ManualRidingHandoff {
                source,
                elapsed_seconds: 0.0,
                duration_seconds: 0.2,
            });
        }
        Ok(balance_step)
    }

    /// Begin a graph-selected basic trick. The recovered Flickit classifier is
    /// responsible for choosing `kind` and `height_endpoint`.
    #[allow(dead_code)] // Not called by geometry candidates without retail arbitration.
    pub fn begin_basic_trick(
        &mut self,
        kind: BasicTrickKind,
        height_endpoint: TrickHeightEndpoint,
    ) {
        self.anticipation = None;
        self.push_anticipation_handoff = None;
        self.trick_handoff = None;
        self.pop_motion = None;
        self.landed_this_step = false;
        self.body_spin_angle = 0.0;
        self.body_spin_velocity = 0.0;
        self.body_spin_animation_phase_seconds = 0.0;
        self.airborne_body_spin_input_observed = false;
        self.push = None;
        self.brake = None;
        self.slide = None;
        self.grind = None;
        self.manual = None;
        self.air_trick = None;
        self.grab = None;
        self.landing = None;
        self.random_idle = None;
        self.brake_hold_time = 0.0;
        self.brake_active = false;
        self.powerslide_rotation = 0.0;
        let playback = BasicTrickPlayback::begin(kind, height_endpoint);
        self.board_authority = playback.runtime.board_authority;
        self.basic_trick = Some(playback);
    }

    /// Advance the recovered graph with externally classified physics signals.
    ///
    /// Straight-landing blend coordinates must come from the landing pipeline;
    /// omitting them deliberately leaves `BLEND_LAND` unresolved.
    pub fn step_basic_trick(
        &mut self,
        delta_seconds: f32,
        signals: BasicTrickSignals,
        straight_landing_parameters: Option<StraightLandingParameters>,
    ) {
        let Some(playback) = self.basic_trick.as_mut() else {
            return;
        };
        if signals.landed == Some(LandingAnimationResource::Straight) {
            playback.straight_landing_parameters = straight_landing_parameters;
        }
        playback.runtime.step(delta_seconds, signals);
        self.board_authority = playback.runtime.board_authority;
        if playback.runtime.phase == BasicTrickPhase::Complete {
            self.basic_trick = None;
        }
    }

    pub fn visual_skater_root_offset_y(&self) -> f32 {
        // The extracted R_ANTIC_* and OLLIE_* poses already contain the
        // measured pelvis motion relative to SKATEBOARD_ROOT. The isolated
        // oracle's skater-position channel observes that same pose motion; it
        // is retained in PopMotion for telemetry, but applying it to the
        // complete rig would count it twice while foot IK keeps the feet on
        // their authored board targets.
        0.0
    }

    pub fn visual_skater_yaw_offset(&self) -> f32 {
        // The synchronized `skater_z_axis` is a pose-space axis: projecting
        // it onto the ground changes its apparent heading as the authored
        // Ollie and BodySpin clips tilt the skater. It is not a second world
        // yaw carrier. SkateSim::yaw owns the board and lower-body heading;
        // the extracted directional BodySpin leaf supplies the relative pose.
        0.0
    }

    pub const fn riding_stance(&self) -> RidingStance {
        RidingStance::from_natural_and_switch(self.natural_stance, self.fakie.is_riding_switch())
    }

    pub const fn is_riding_goofy(&self) -> bool {
        self.riding_stance().is_goofy()
    }

    pub const fn flickit_mirror_state(&self) -> MirrorState {
        // TU3 `IsRidingGoofy` is natural-goofy XOR riding-switch.
        // `IsRidingFakie` remains a separate trick-approach predicate.
        MirrorState::from_riding_stance(self.riding_stance())
    }

    /// The authored B_SWITCH endpoint is already the reflected/goofy pose.
    /// Its short transition-under window therefore uses the recovered baked
    /// mirrored HCOM source rather than mixing opposite stance bases.
    pub const fn stance_source_is_pre_mirrored(&self) -> bool {
        self.fakie.switch_out_elapsed_seconds.is_some()
    }

    /// Whether the final blended character pose needs Andale's mirror command.
    ///
    /// During the B_SWITCH transition-under window the source pose is already
    /// mirrored, so a regular target stance needs the inverse operation while
    /// a goofy target stance needs none.
    pub const fn should_use_mirrored_character_animation(&self) -> bool {
        self.is_riding_goofy() ^ self.stance_source_is_pre_mirrored()
    }

    /// MotionGraph-side turn value used to select riding lean clips.
    ///
    /// `ActionGraphIncludes/onground.xml` authors `FakieTurn` as a negated
    /// copy of `Turn`. Spatial pose mirroring also flips left/right, so the
    /// source blend coordinate must be negated once for every later mirror.
    pub fn riding_animation_source_tilt(&self) -> f32 {
        // switch.xml deliberately attaches ordinary `Turn`; the negated
        // FakieTurn route applies while riding fakie before B_SWITCH starts.
        let fakie_turn = if self.fakie.phase == crate::fakie::FakiePhase::RidingFakie {
            -self.body_tilt
        } else {
            self.body_tilt
        };
        let post_mirror_sign = if self.should_use_mirrored_character_animation() {
            -1.0
        } else {
            1.0
        };
        let pre_mirror_sign = if self.stance_source_is_pre_mirrored() {
            -1.0
        } else {
            1.0
        };
        fakie_turn * post_mirror_sign * pre_mirror_sign
    }

    pub fn visual_world_rotation(&self) -> Quat {
        if self.transition.is_enabled() {
            self.transition.visual_rotation()
        } else {
            Quat::from_rotation_y(self.yaw + self.visual_skater_yaw_offset())
        }
    }

    pub fn visual_board_correction_y(&self) -> f32 {
        // The physical board carrier already owns SkateSim::position.y. With
        // no duplicate skater-root carrier there is no inverse board
        // correction to apply inside the authored skeleton hierarchy.
        0.0
    }

    /// Post-animation deck nose/tail offset, expressed as a normalized half
    /// turn. Zero is the exported baseline and one is a 180-degree reversal.
    ///
    /// The transition duration comes directly from air.xml's `B_AIR_CYC`
    /// sequence-to-air blend. Applying the offset with the same weight cancels
    /// the otherwise visible unwind of the physical odd-shove endpoint.
    pub fn visual_board_reversal(&self) -> f32 {
        self.skateboard_offset_transition
            .map(SkateboardOffsetTransition::reversal)
            .unwrap_or(if self.board_reversed { 1.0 } else { 0.0 })
    }

    pub(crate) fn visual_board_reversal_transition(&self) -> Option<(f32, f32, f32)> {
        self.skateboard_offset_transition.map(|transition| {
            (
                transition.to_reversal,
                transition.elapsed_seconds,
                transition.duration_seconds,
            )
        })
    }

    fn begin_board_reversal_transition(&mut self) {
        let from_reversal = self.visual_board_reversal();
        self.board_reversed = !self.board_reversed;
        self.skateboard_offset_transition = Some(SkateboardOffsetTransition {
            from_reversal,
            to_reversal: if self.board_reversed { 1.0 } else { 0.0 },
            elapsed_seconds: 0.0,
            duration_seconds: SEQUENCE_TO_AIR_BASELINE_BLEND_SECONDS,
        });
    }

    fn step_skateboard_offset_transition(&mut self, delta_seconds: f32) {
        let Some(transition) = self.skateboard_offset_transition.as_mut() else {
            return;
        };
        if delta_seconds.is_finite() && delta_seconds >= 0.0 {
            transition.elapsed_seconds += delta_seconds;
        }
        if transition.weight() >= 1.0 {
            self.skateboard_offset_transition = None;
        }
    }

    pub fn is_onboard(&self) -> bool {
        self.offboard.is_none()
    }
}

fn sample_ollie_held_body_spin_speed(phase: f32, spin_direction: f32) -> f32 {
    let phase = phase.clamp(0.0, 1.0);
    for pair in OLLIE_HELD_BODY_SPIN_SPEED.windows(2) {
        let (lower_phase, lower_left_speed, lower_right_speed) = pair[0];
        let (upper_phase, upper_left_speed, upper_right_speed) = pair[1];
        if phase <= upper_phase {
            let span = upper_phase - lower_phase;
            let blend = if span > f32::EPSILON {
                (phase - lower_phase) / span
            } else {
                0.0
            };
            let (lower_speed, upper_speed) = if spin_direction >= 0.0 {
                (lower_left_speed, upper_left_speed)
            } else {
                (lower_right_speed, upper_right_speed)
            };
            return lower_speed + (upper_speed - lower_speed) * blend;
        }
    }
    let (_, left_speed, right_speed) =
        OLLIE_HELD_BODY_SPIN_SPEED[OLLIE_HELD_BODY_SPIN_SPEED.len() - 1];
    if spin_direction >= 0.0 {
        left_speed
    } else {
        right_speed
    }
}

fn action_state_from_anticipation(state: AnticipationAnimationState) -> ActionAnimationState {
    ActionAnimationState {
        samples: state
            .samples
            .into_iter()
            .map(|sample| AnimationSample {
                clip: sample.clip.to_owned(),
                weight: sample.weight,
                seek_time_seconds: sample.seek_time_seconds,
            })
            .collect(),
        weight: state.weight,
    }
}

fn validated_offboard_animation_state(runtime: &OffboardRuntime) -> ActionAnimationState {
    let requested = runtime.animation_state();
    let mut samples = Vec::with_capacity(requested.samples.len());
    for sample in requested.samples {
        let Ok(adapted) = adapt_offboard_for_bevy(OffboardAnimationAdapterRequest {
            resource: &sample.clip,
            local_time_seconds: sample.seek_time_seconds,
            parameters: OffboardAnimationParameters::None,
        }) else {
            // A virtual, unknown, or unavailable resource cannot reach Bevy.
            return ActionAnimationState::default();
        };
        let resolved = adapted.resolved();
        samples.push(AnimationSample {
            clip: resolved.clip.name.to_owned(),
            weight: sample.weight,
            seek_time_seconds: resolved.seek_time_seconds,
        });
    }
    ActionAnimationState {
        samples,
        weight: requested.weight,
    }
}

#[derive(Resource, Default, Debug)]
pub struct SkateInput {
    pub left_stick: Vec2,
    pub right_stick: Vec2,
    pub left_trigger: f32,
    pub right_trigger: f32,
    /// Raw XInput-shaped state retained for deterministic SK8 Engine replays.
    pub canonical_pad: CanonicalPadState,
    /// Right-stick state changes captured at the input backend cadence. Retail
    /// advances PatternNodes from upstream notifications, not the 120 Hz
    /// physics clock, so fixed update drains this queue exactly once.
    pub right_stick_notifications: VecDeque<CanonicalPadState>,
    pub pending_push: Option<PushFoot>,
    pub regular_push_held: bool,
    pub mongo_push_held: bool,
    pub brake_held: bool,
    pub toggle_offboard_pending: bool,
    pub reset: bool,
    pub gamepads_detected: usize,
    pub gamepads_usable: usize,
    pub active_gamepad: Option<String>,
}

impl SkateInput {
    /// Store one backend-visible canonical pad state and preserve right-stick
    /// changes as retail-style input notifications for the Flickit matcher.
    ///
    /// Live input, deterministic replays, and the dual oracle must all use this
    /// boundary so a held state is not miscounted as repeated PatternNode input.
    pub fn observe_canonical_pad(&mut self, pad: CanonicalPadState) {
        if self.canonical_pad.right_x != pad.right_x || self.canonical_pad.right_y != pad.right_y {
            self.right_stick_notifications.push_back(pad);
        }
        self.canonical_pad = pad;
    }
}

#[derive(Clone, Copy, Default, Debug, PartialEq, Eq)]
pub struct CanonicalPadState {
    pub buttons: u16,
    pub left_trigger: u8,
    pub right_trigger: u8,
    pub left_x: i16,
    pub left_y: i16,
    pub right_x: i16,
    pub right_y: i16,
}

pub fn sample_input(
    keyboard: Res<ButtonInput<KeyCode>>,
    gamepads: Query<(Option<&Name>, &Gamepad)>,
    mut input: ResMut<SkateInput>,
    mut xinput_cache: Local<XInputCache>,
) {
    let keyboard_x =
        (keyboard.pressed(KeyCode::KeyD) as i8 - keyboard.pressed(KeyCode::KeyA) as i8) as f32;
    let keyboard_y =
        (keyboard.pressed(KeyCode::KeyW) as i8 - keyboard.pressed(KeyCode::KeyS) as i8) as f32;
    let keyboard_right_x = (keyboard.pressed(KeyCode::ArrowRight) as i8
        - keyboard.pressed(KeyCode::ArrowLeft) as i8) as f32;
    let keyboard_right_y = (keyboard.pressed(KeyCode::ArrowUp) as i8
        - keyboard.pressed(KeyCode::ArrowDown) as i8) as f32;
    let keyboard_right_stick = Vec2::new(keyboard_right_x, keyboard_right_y).clamp_length_max(1.0);
    let keyboard_left_trigger = keyboard.pressed(KeyCode::KeyQ) as u8 as f32;
    let keyboard_right_trigger = keyboard.pressed(KeyCode::KeyE) as u8 as f32;
    // A steep down/side diagonal is the verified retail powerslide input.
    // A digital keyboard has no half-axis, so S weights A/D to reproduce the
    // same normalized (±0.447, -0.894) vector used by the oracle capture.
    let keyboard_stick = if keyboard_y < 0.0 && keyboard_x != 0.0 {
        Vec2::new(keyboard_x * 0.5, keyboard_y).normalize()
    } else {
        Vec2::new(keyboard_x, keyboard_y)
    };

    let mut left_stick = keyboard_stick;
    let mut right_stick = keyboard_right_stick;
    let mut regular_pressed = keyboard.just_pressed(KeyCode::Space);
    let mut mongo_pressed = keyboard.just_pressed(KeyCode::ShiftLeft);
    let mut regular_held = keyboard.pressed(KeyCode::Space);
    let mut mongo_held = keyboard.pressed(KeyCode::ShiftLeft);
    let mut brake_held = keyboard.pressed(KeyCode::KeyB);
    let mut toggle_pressed = keyboard.just_pressed(KeyCode::KeyY);
    let mut toggle_held = keyboard.pressed(KeyCode::KeyY);
    let mut reset = keyboard.just_pressed(KeyCode::KeyR);
    let non_vjoy_bevy_gamepad_available = gamepads
        .iter()
        .any(|(name, _)| !is_vjoy_name(name.map(Name::as_str).unwrap_or_default()));
    let xinput_samples = poll_xinput(&mut xinput_cache);
    let use_xinput_fallback = !non_vjoy_bevy_gamepad_available && !xinput_samples.is_empty();
    let physical_gamepad_available = non_vjoy_bevy_gamepad_available || use_xinput_fallback;
    let mut strongest_gamepad_stick = Vec2::ZERO;
    let mut strongest_gamepad_right_stick = Vec2::ZERO;
    let mut strongest_left_trigger = 0.0_f32;
    let mut strongest_right_trigger = 0.0_f32;
    let mut strongest_canonical_pad = CanonicalPadState::default();
    let mut strongest_activity = 0.0_f32;
    let mut active_gamepad = None;
    let mut detected = 0;
    let mut usable = 0;

    // Do not bind input to enumeration order. On this machine vJoy enumerates
    // before the physical pad, which made the old `.next()` path permanently
    // read an idle virtual device. Merge button edges across every usable pad
    // and use the strongest live stick.
    for (name, gamepad) in &gamepads {
        detected += 1;
        let name = name.map(Name::as_str).unwrap_or("unnamed gamepad");
        if physical_gamepad_available && is_vjoy_name(name) {
            continue;
        }
        usable += 1;

        let gamepad_stick = remap_radial_deadzone(gamepad.left_stick(), LEFT_INPUT_DEADZONE);
        let gamepad_right_stick = remap_retail_right_stick(gamepad.right_stick());
        let left_trigger = gamepad
            .get(GamepadButton::LeftTrigger2)
            .unwrap_or(0.0)
            .clamp(0.0, 1.0);
        let right_trigger = gamepad
            .get(GamepadButton::RightTrigger2)
            .unwrap_or(0.0)
            .clamp(0.0, 1.0);
        if gamepad_stick.length_squared() > strongest_gamepad_stick.length_squared() {
            strongest_gamepad_stick = gamepad_stick;
            strongest_canonical_pad.left_x = normalized_axis_to_i16(gamepad.left_stick().x);
            strongest_canonical_pad.left_y = normalized_axis_to_i16(gamepad.left_stick().y);
        }
        if gamepad_right_stick.length_squared() > strongest_gamepad_right_stick.length_squared() {
            strongest_gamepad_right_stick = gamepad_right_stick;
            strongest_canonical_pad.right_x = normalized_axis_to_i16(gamepad.right_stick().x);
            strongest_canonical_pad.right_y = normalized_axis_to_i16(gamepad.right_stick().y);
        }
        if left_trigger > strongest_left_trigger {
            strongest_left_trigger = left_trigger;
            strongest_canonical_pad.left_trigger = normalized_trigger_to_u8(left_trigger);
        }
        if right_trigger > strongest_right_trigger {
            strongest_right_trigger = right_trigger;
            strongest_canonical_pad.right_trigger = normalized_trigger_to_u8(right_trigger);
        }
        regular_pressed |= gamepad.just_pressed(GamepadButton::South);
        mongo_pressed |= gamepad.just_pressed(GamepadButton::West);
        regular_held |= gamepad.pressed(GamepadButton::South);
        mongo_held |= gamepad.pressed(GamepadButton::West);
        brake_held |= gamepad.pressed(GamepadButton::East);
        toggle_pressed |= gamepad.just_pressed(GamepadButton::North);
        toggle_held |= gamepad.pressed(GamepadButton::North);
        reset |= gamepad.just_pressed(GamepadButton::Start);

        let button_activity = [
            GamepadButton::South,
            GamepadButton::West,
            GamepadButton::East,
            GamepadButton::North,
            GamepadButton::Start,
        ]
        .into_iter()
        .filter(|button| gamepad.pressed(*button))
        .count() as f32;
        let activity = gamepad_stick.length()
            + gamepad_right_stick.length()
            + left_trigger
            + right_trigger
            + button_activity;
        if activity > strongest_activity {
            strongest_activity = activity;
            active_gamepad = Some(name.to_owned());
        }
    }

    if use_xinput_fallback {
        for sample in &xinput_samples {
            detected += 1;
            usable += 1;
            if sample.left_stick.length_squared() > strongest_gamepad_stick.length_squared() {
                strongest_gamepad_stick = sample.left_stick;
                strongest_canonical_pad.left_x = sample.canonical_pad.left_x;
                strongest_canonical_pad.left_y = sample.canonical_pad.left_y;
            }
            let sample_right_stick = remap_retail_right_stick(Vec2::new(
                sample.canonical_pad.right_x as f32 / 32_768.0,
                sample.canonical_pad.right_y as f32 / 32_768.0,
            ));
            if sample_right_stick.length_squared() > strongest_gamepad_right_stick.length_squared()
            {
                strongest_gamepad_right_stick = sample_right_stick;
                strongest_canonical_pad.right_x = sample.canonical_pad.right_x;
                strongest_canonical_pad.right_y = sample.canonical_pad.right_y;
            }
            let sample_left_trigger = sample.canonical_pad.left_trigger as f32 / u8::MAX as f32;
            if sample_left_trigger > strongest_left_trigger {
                strongest_left_trigger = sample_left_trigger;
                strongest_canonical_pad.left_trigger = sample.canonical_pad.left_trigger;
            }
            let sample_right_trigger = sample.canonical_pad.right_trigger as f32 / u8::MAX as f32;
            if sample_right_trigger > strongest_right_trigger {
                strongest_right_trigger = sample_right_trigger;
                strongest_canonical_pad.right_trigger = sample.canonical_pad.right_trigger;
            }
            regular_pressed |= sample.regular_just_pressed;
            mongo_pressed |= sample.mongo_just_pressed;
            regular_held |= sample.regular_held;
            mongo_held |= sample.mongo_held;
            brake_held |= sample.brake_held;
            toggle_pressed |= sample.toggle_just_pressed;
            toggle_held |= sample.toggle_held;
            reset |= sample.reset_just_pressed;

            let activity = sample.left_stick.length()
                + sample_right_stick.length()
                + sample_left_trigger
                + sample_right_trigger
                + [
                    sample.regular_held,
                    sample.mongo_held,
                    sample.brake_held,
                    sample.toggle_held,
                ]
                .into_iter()
                .filter(|pressed| *pressed)
                .count() as f32;
            if activity > strongest_activity {
                strongest_activity = activity;
                active_gamepad = Some(sample.name.clone());
            }
        }
    }

    if keyboard_stick == Vec2::ZERO {
        left_stick = strongest_gamepad_stick;
    }
    if keyboard_right_stick == Vec2::ZERO {
        right_stick = strongest_gamepad_right_stick;
    }

    input.left_stick = left_stick.clamp_length_max(1.0);
    input.right_stick = right_stick.clamp_length_max(1.0);
    input.regular_push_held = regular_held;
    input.mongo_push_held = mongo_held;
    input.brake_held = brake_held;
    if keyboard_stick != Vec2::ZERO {
        strongest_canonical_pad.left_x = normalized_axis_to_i16(keyboard_stick.x);
        strongest_canonical_pad.left_y = normalized_axis_to_i16(keyboard_stick.y);
    }
    if keyboard_right_stick != Vec2::ZERO {
        strongest_canonical_pad.right_x = normalized_axis_to_i16(keyboard_right_stick.x);
        strongest_canonical_pad.right_y = normalized_axis_to_i16(keyboard_right_stick.y);
    }
    if keyboard_left_trigger > 0.0 {
        strongest_canonical_pad.left_trigger = u8::MAX;
        strongest_left_trigger = 1.0;
    }
    if keyboard_right_trigger > 0.0 {
        strongest_canonical_pad.right_trigger = u8::MAX;
        strongest_right_trigger = 1.0;
    }
    input.left_trigger = strongest_left_trigger;
    input.right_trigger = strongest_right_trigger;
    strongest_canonical_pad.buttons &= !(0x1000 | 0x2000 | 0x4000 | 0x8000);
    strongest_canonical_pad.buttons |= u16::from(regular_held) * 0x1000;
    strongest_canonical_pad.buttons |= u16::from(brake_held) * 0x2000;
    strongest_canonical_pad.buttons |= u16::from(mongo_held) * 0x4000;
    strongest_canonical_pad.buttons |= u16::from(toggle_held) * 0x8000;
    input.observe_canonical_pad(strongest_canonical_pad);
    if input.pending_push.is_none() {
        input.pending_push = if regular_pressed {
            Some(PushFoot::Regular)
        } else if mongo_pressed {
            Some(PushFoot::Mongo)
        } else {
            None
        };
    }
    input.toggle_offboard_pending |= toggle_pressed;
    input.reset |= reset;
    input.gamepads_detected = detected;
    input.gamepads_usable = usable;
    if let Some(active_gamepad) = active_gamepad {
        input.active_gamepad = Some(active_gamepad);
    }
}

pub fn log_gamepad_inventory(
    gamepads: Query<(Entity, Option<&Name>, &Gamepad)>,
    mut previous_inventory: Local<String>,
) {
    let mut entries: Vec<_> = gamepads
        .iter()
        .map(|(entity, name, gamepad)| {
            format!(
                "{} [{entity:?} vid={:?} pid={:?}]",
                name.map(Name::as_str).unwrap_or("unnamed gamepad"),
                gamepad.vendor_id(),
                gamepad.product_id()
            )
        })
        .collect();
    entries.sort();
    let inventory = entries.join(" | ");
    if *previous_inventory != inventory {
        if inventory.is_empty() {
            info!("GAMEPAD_INVENTORY none");
        } else {
            info!("GAMEPAD_INVENTORY {inventory}");
        }
        *previous_inventory = inventory;
    }
}

/// Root-command TrickHeight weights measured at the retail Kickflip tree for
/// every fixed-clock charge from two through thirty frames.
///
/// Kickflip and Heelflip produced the same value at six frames and retained it
/// unchanged through their G, A, and OUT1 trees. The repeated 20/21-frame value
/// was confirmed by an isolated 21-frame capture.
const RETAIL_FLIP_HEIGHT_WEIGHTS: [f32; 29] = [
    0.003_904_787_4,
    0.019_427_389,
    0.054_081_324,
    0.112_141_31,
    0.192_488_61,
    0.288_127_8,
    0.387_566_63,
    0.477_522_58,
    0.556_820_2,
    0.644_118_55,
    0.729_712_9,
    0.799_880_03,
    0.854_665_16,
    0.896_082_9,
    0.926_681_9,
    0.948_894_6,
    0.964_793_5,
    0.976_036_2,
    0.983_899_83,
    0.983_899_83,
    0.993_067_74,
    0.995_587_47,
    0.997_268_2,
    0.998_370_05,
    0.999_076_37,
    0.999_514_5,
    0.999_773_8,
    0.999_915_8,
    0.999_981_46,
];

fn retail_flip_height_weight(charge_seconds: f32) -> f32 {
    let frame_position = (charge_seconds.max(0.0) * RETAIL_ANIMATION_HZ).clamp(2.0, 30.0);
    let lower_frame = frame_position.floor();
    let upper_frame = frame_position.ceil();
    let lower = RETAIL_FLIP_HEIGHT_WEIGHTS[(lower_frame as usize) - 2];
    let upper = RETAIL_FLIP_HEIGHT_WEIGHTS[(upper_frame as usize) - 2];
    lower + (upper - lower) * (frame_position - lower_frame)
}

fn retail_basic_trick_height_endpoint(charge_seconds: f32) -> TrickHeightEndpoint {
    // The synchronized thirty-frame Ollie capture reaches the recovered
    // OLLIE_HIGH_A tuck: HIPS moves 0.510 m toward SKATEBOARD_ROOT at the
    // 1.156 m board apex. OLLIE_LOW_A only authors about 0.09 m of that
    // relative motion. Interior low/high interpolation is still unresolved,
    // so only the measured maximum-charge endpoint is promoted here.
    if (charge_seconds * RETAIL_ANIMATION_HZ).round() >= 30.0 {
        TrickHeightEndpoint::High
    } else {
        TrickHeightEndpoint::Low
    }
}

const SINGLE_ROTATION_FLICKIT_TRICKS: [(&str, AirTrick); 24] = {
    use crate::air_trick_graph::PopEnd::{Nose, Tail};
    use AirTrickFamily as F;
    [
        ("PopShuvit", AirTrick::new(Tail, F::PopShuvit)),
        ("FSPopShuvit", AirTrick::new(Tail, F::FsPopShuvit)),
        ("VarialKickflip", AirTrick::new(Tail, F::VarialKickflip)),
        ("VarialHeelflip", AirTrick::new(Tail, F::VarialHeelflip)),
        ("Hardflip", AirTrick::new(Tail, F::Hardflip)),
        ("InwardHeelflip", AirTrick::new(Tail, F::InwardHeelflip)),
        ("360PopShuvit", AirTrick::new(Tail, F::PopShuvit360)),
        ("FS360PopShuvit", AirTrick::new(Tail, F::FsPopShuvit360)),
        ("360Flip", AirTrick::new(Tail, F::Flip360)),
        ("Laserflip", AirTrick::new(Tail, F::Laserflip)),
        ("360Hardflip", AirTrick::new(Tail, F::Hardflip360)),
        (
            "360InwardHeelflip",
            AirTrick::new(Tail, F::InwardHeelflip360),
        ),
        ("N_PopShuvit", AirTrick::new(Nose, F::PopShuvit)),
        ("N_FSPopShuvit", AirTrick::new(Nose, F::FsPopShuvit)),
        ("N_VarialKickflip", AirTrick::new(Nose, F::VarialKickflip)),
        ("N_VarialHeelflip", AirTrick::new(Nose, F::VarialHeelflip)),
        ("N_Hardflip", AirTrick::new(Nose, F::Hardflip)),
        ("N_InwardHeelflip", AirTrick::new(Nose, F::InwardHeelflip)),
        ("N_360PopShuvit", AirTrick::new(Nose, F::PopShuvit360)),
        ("N_FS360PopShuvit", AirTrick::new(Nose, F::FsPopShuvit360)),
        ("N_360Flip", AirTrick::new(Nose, F::Flip360)),
        ("N_Laserflip", AirTrick::new(Nose, F::Laserflip)),
        ("N_360Hardflip", AirTrick::new(Nose, F::Hardflip360)),
        (
            "N_360InwardHeelflip",
            AirTrick::new(Nose, F::InwardHeelflip360),
        ),
    ]
};

fn single_rotation_flickit_trick(winner: &str) -> Option<AirTrick> {
    SINGLE_ROTATION_FLICKIT_TRICKS
        .iter()
        .find_map(|(name, trick)| (*name == winner).then_some(*trick))
}

/// Route gesture identities whose selected physical endpoint trees and
/// AnticStrength/TrickHeight weights are runtime-verified and exported.
fn begin_verified_endpoint_trick(sim: &mut SkateSim, winner: &str) -> bool {
    if !sim.is_onboard()
        || sim.offboard_visual.is_some()
        || sim.fakie.blocks_new_trick()
        || sim.basic_trick.is_some()
        || sim.air_trick.is_some()
        || sim.grab.is_some()
        || sim.landing.is_some()
        || sim.grind.is_some()
        || sim.manual.is_some()
    {
        return false;
    }

    // ActionGraphIncludes/T_Trick.xml resolves the raw gesture through
    // IsMirrored before MotionGraph selects its physical family. Keep
    // unsupported endpoint families on their existing evidence-gated route;
    // the currently verified Kickflip/Heelflip pair is exact in both stances.
    let resolved = square_identity_for_gesture(winner)
        .map(|descriptor| resolve_trick_identity(descriptor, sim.flickit_mirror_state(), false))
        .map(|identity| identity.selected_name)
        .filter(|selected| {
            matches!(
                *selected,
                "Ollie" | "Nollie" | "Kickflip" | "Heelflip" | "360Flip"
            )
        })
        .unwrap_or(winner);

    let anticipation_source = sim
        .anticipation
        .as_ref()
        .map(|_| sim.action_animation_state());
    let anticipation = sim.anticipation.take();
    let anticipation_charge_seconds = anticipation
        .as_ref()
        .map_or(0.0, |runtime| runtime.charge_seconds);
    let began = match resolved {
        "Ollie" => {
            let endpoint = retail_basic_trick_height_endpoint(anticipation_charge_seconds);
            sim.begin_basic_trick(BasicTrickKind::Ollie, endpoint);
            begin_measured_ollie_pop(sim, anticipation_charge_seconds);
            true
        }
        "Nollie" => {
            let endpoint = retail_basic_trick_height_endpoint(anticipation_charge_seconds);
            sim.begin_basic_trick(BasicTrickKind::Nollie, endpoint);
            begin_measured_ollie_pop(sim, anticipation_charge_seconds);
            true
        }
        "Kickflip" | "Heelflip" | "N_Kickflip" | "N_Heelflip" => {
            let family = if matches!(resolved, "Kickflip" | "N_Kickflip") {
                AirTrickFamily::Kickflip
            } else {
                AirTrickFamily::Heelflip
            };
            let pop_end = if resolved.starts_with("N_") {
                crate::air_trick_graph::PopEnd::Nose
            } else {
                crate::air_trick_graph::PopEnd::Tail
            };
            let height_weight = retail_flip_height_weight(anticipation_charge_seconds);
            let began = sim
                .begin_air_trick(
                    AirTrick::new(pop_end, family),
                    AirTrickEntry::FromAnticipation,
                    AirTrickHeight::ContinuousUnresolved(height_weight),
                )
                .is_ok();
            if began {
                begin_measured_ollie_pop(sim, anticipation_charge_seconds);
            }
            began
        }
        _ if single_rotation_flickit_trick(winner).is_some() => {
            let height = match retail_basic_trick_height_endpoint(anticipation_charge_seconds) {
                TrickHeightEndpoint::Low => AirTrickHeight::LowEndpoint,
                TrickHeightEndpoint::High => AirTrickHeight::HighEndpoint,
            };
            let trick = single_rotation_flickit_trick(winner)
                .expect("guard proved this is a supported one-shot Flickit trick");
            let began = sim
                .begin_air_trick(trick, AirTrickEntry::FromAnticipation, height)
                .is_ok();
            if began {
                // T_Trick, T_TrickWithUnderflip, and
                // T_TrickWithDarkCatch all use the same FromAntic
                // AnticStrength/TrickHeight entry contract as T_Ollie.
                begin_measured_ollie_pop(sim, anticipation_charge_seconds);
            }
            began
        }
        _ => false,
    };
    if began {
        sim.active_trick_context = Some(TrickContext {
            name: resolved.to_owned(),
            approach: sim.fakie.trick_approach(),
        });
        if let Some(source) = anticipation_source {
            sim.trick_handoff = Some(ActionHandoff {
                source,
                elapsed_seconds: 0.0,
                duration_seconds: ANTICIPATION_TO_TRICK_BLEND_SECONDS,
            });
        }
    } else {
        sim.anticipation = anticipation;
    }
    began
}

fn begin_measured_ollie_pop(sim: &mut SkateSim, charge_seconds: f32) {
    let projection = retail_landing_projection_fixture(charge_seconds);
    let carrier = retail_released_carrier(charge_seconds, 0.0);
    let first_air_seconds =
        retail_released_timing_seconds(charge_seconds, |case| case.first_air_frame);
    let touchdown_seconds =
        retail_released_timing_seconds(charge_seconds, |case| case.touchdown_frame);
    let recovery_end_seconds =
        retail_released_timing_seconds(charge_seconds, |case| case.samples.len() - 1);
    let ground_height = sim.position.y;
    sim.position.y = ground_height + carrier.board_height;
    sim.velocity.y = 0.0;
    sim.pop_motion = Some(PopMotion {
        charge_seconds,
        // The provider's first mode-2 projection is retained for telemetry;
        // visual board lift begins later on its independent measured channel.
        launch_speed: projection.launch_velocity_y,
        ground_height,
        separated_from_ground: false,
        fixed_steps_since_flick: 0,
        elapsed_since_flick_seconds: 0.0,
        board_height: carrier.board_height,
        skater_height: carrier.skater_height,
        takeoff_view_yaw: sim.view_yaw,
        first_air_seconds,
        touchdown_seconds,
        recovery_end_seconds,
        touched_down: false,
        transition_touchdown_seconds: None,
        retail_projection_velocity_y: projection.launch_velocity_y,
        retail_projection_delta_per_frame: projection.delta_per_frame,
        retail_projection_touchdown_velocity_y: projection.touchdown_velocity_y,
    });
    sim.landed_this_step = false;
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct RetailLandingProjectionFixture {
    launch_velocity_y: f32,
    touchdown_velocity_y: f32,
    delta_per_frame: f32,
}

fn retail_landing_projection_fixture(charge_seconds: f32) -> RetailLandingProjectionFixture {
    let hold_frames = (charge_seconds.max(0.0) * RETAIL_ANIMATION_HZ).clamp(
        RETAIL_LANDING_PROJECTION_FIXTURES[0].0,
        RETAIL_LANDING_PROJECTION_FIXTURES[RETAIL_LANDING_PROJECTION_FIXTURES.len() - 1].0,
    );
    let upper_index = RETAIL_LANDING_PROJECTION_FIXTURES
        .partition_point(|fixture| fixture.0 < hold_frames)
        .min(RETAIL_LANDING_PROJECTION_FIXTURES.len() - 1);
    let lower_index = upper_index.saturating_sub(1);
    let lower = RETAIL_LANDING_PROJECTION_FIXTURES[lower_index];
    let upper = RETAIL_LANDING_PROJECTION_FIXTURES[upper_index];
    let interpolation = if upper.0 > lower.0 {
        ((hold_frames - lower.0) / (upper.0 - lower.0)).clamp(0.0, 1.0)
    } else {
        0.0
    };
    let launch_velocity_y = lower.1 + (upper.1 - lower.1) * interpolation;
    let touchdown_velocity_y = lower.2 + (upper.2 - lower.2) * interpolation;
    let update_count = lower.3 as f32 + (upper.3 as f32 - lower.3 as f32) * interpolation;
    let delta_per_frame = -(launch_velocity_y + touchdown_velocity_y) / (update_count - 1.0);
    RetailLandingProjectionFixture {
        launch_velocity_y,
        touchdown_velocity_y,
        delta_per_frame,
    }
}

fn retail_landing_distance_to_cog_fixture(charge_seconds: f32) -> f32 {
    let hold_frames = (charge_seconds.max(0.0) * RETAIL_ANIMATION_HZ).clamp(
        RETAIL_LANDING_DISTANCE_TO_COG_FIXTURES[0].0,
        RETAIL_LANDING_DISTANCE_TO_COG_FIXTURES[RETAIL_LANDING_DISTANCE_TO_COG_FIXTURES.len() - 1]
            .0,
    );
    let upper_index = RETAIL_LANDING_DISTANCE_TO_COG_FIXTURES
        .partition_point(|fixture| fixture.0 < hold_frames)
        .min(RETAIL_LANDING_DISTANCE_TO_COG_FIXTURES.len() - 1);
    let lower_index = upper_index.saturating_sub(1);
    let lower = RETAIL_LANDING_DISTANCE_TO_COG_FIXTURES[lower_index];
    let upper = RETAIL_LANDING_DISTANCE_TO_COG_FIXTURES[upper_index];
    if upper.0 > lower.0 {
        let weight = ((hold_frames - lower.0) / (upper.0 - lower.0)).clamp(0.0, 1.0);
        (upper.1 - lower.1).mul_add(weight, lower.1)
    } else {
        lower.1
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct AnticipationAdmission {
    identity: AnticipationIdentity,
    side: AnticipationSide,
    magnitude: f32,
    angle_radians: f32,
}

fn anticipation_admission(
    pad: CanonicalPadState,
    mirror_state: MirrorState,
) -> Option<AnticipationAdmission> {
    let stick = normalize_raw_axis_pair(pad.right_x, pad.right_y);
    let magnitude = stick.length();
    // The user-facing/raw XInput sequence places tail anticipation at stick
    // down. Angle zero therefore points down; the recovered ActionGraph sector
    // boundaries are then applied verbatim.
    let angle = stick.x.atan2(-stick.y);
    let classification = classify_anticipation(
        AnticipationSignal {
            magnitude,
            angle_radians: angle,
        },
        mirror_state,
    );
    let identity = match classification {
        AnticipationClassification::Classified { identity, .. } => identity,
        // Retail XML uses inclusive comparisons at every shared boundary.
        // State arbitration at exactly those floating-point values remains
        // unresolved; declaration order is retained here as the narrow runtime
        // fallback while the pure classifier continues to expose ambiguity.
        AnticipationClassification::AmbiguousBoundary { candidates, .. } => *candidates.first()?,
        _ => return None,
    };
    Some(AnticipationAdmission {
        identity,
        side: anticipation_side(identity),
        magnitude,
        angle_radians: angle,
    })
}

fn can_begin_anticipation(sim: &SkateSim) -> bool {
    sim.is_onboard()
        && sim.offboard_visual.is_none()
        && !sim.fakie.blocks_new_trick()
        && sim.ground_contact_valid
        && sim.anticipation.is_none()
        && sim.basic_trick.is_none()
        && sim.air_trick.is_none()
        && sim.grab.is_none()
        && sim.landing.is_none()
        && sim.grind.is_none()
        && sim.manual.is_none()
}

fn can_begin_manual(sim: &SkateSim, landed_from_previous_step: bool) -> bool {
    let ordinary_ground_entry = sim.basic_trick.is_none()
        && sim.air_trick.is_none()
        && sim.grab.is_none()
        && sim.landing.is_none();
    // air.xml routes directly to both manual branches before its ordinary
    // Land transition. fixed_step's previous-step touchdown flag is the
    // existing deterministic seam for that route.
    let landing_entry = landed_from_previous_step
        && sim.landing.is_none()
        && (sim.basic_trick.is_some() || sim.air_trick.is_some() || sim.grab.is_some());
    sim.is_onboard()
        && sim.offboard_visual.is_none()
        && sim.ground_contact_valid
        && sim.anticipation.is_none()
        && sim.grind.is_none()
        && sim.manual.is_none()
        && sim.push.is_none()
        && sim.brake.is_none()
        && sim.slide.is_none()
        && (ordinary_ground_entry || landing_entry)
}

fn manual_animation_remaining_seconds(playback: &ManualPlayback) -> Option<f32> {
    // The exact decoded INTO and OUT leaves both contain 15 samples at 30 Hz.
    // The final-sample duration is therefore 14/30 seconds.
    let duration = match playback.runtime.phase {
        ManualPhase::NoseInto | ManualPhase::NoseOut => 14.0 / 30.0,
        _ => return None,
    };
    Some((duration - playback.phase_time_seconds).max(0.0))
}

fn step_held_manual_control(sim: &mut SkateSim, dt: f32, landed_from_previous_step: bool) {
    if let Some(handoff) = sim.manual_riding_handoff.as_mut() {
        handoff.elapsed_seconds += dt.max(0.0);
        if handoff.elapsed_seconds >= handoff.duration_seconds {
            sim.manual_riding_handoff = None;
        }
    }
    let manual_was_active = sim.manual.is_some();
    // The producer's owner bit 0x200 is recovered but its writer/semantic name
    // is not. Do not map unrelated graph owners onto that bit. Arbitration is
    // enforced by can_begin_manual without mutating the published intent.
    let suppression_bit_9 = false;
    let control = sim
        .manual_control
        .step(sim.right_stick, dt, suppression_bit_9, manual_was_active)
        .unwrap_or(ManualControlStep::default());

    if control.entry_ready
        && can_begin_manual(sim, landed_from_previous_step)
        && let Some(manual) = control.intents.manual
    {
        let slope_degrees = sim
            .ground_normal
            .normalize_or_zero()
            .dot(Vec3::Y)
            .clamp(-1.0, 1.0)
            .acos()
            .to_degrees();
        let entry = ManualEntryContext {
            manual,
            manual_engage_time_seconds: control.engage_seconds,
            last_state_was_air: landed_from_previous_step,
            center_of_mass_velocity_y: sim.velocity.y,
            surface_slope_degrees: slope_degrees,
        };
        let local_speed = sim.local_longitudinal_speed();
        sim.begin_manual(entry, local_speed);
    }

    let Some(playback) = sim.manual.as_ref() else {
        sim.deck_pitch = 0.0;
        sim.manual_deck_contact = ManualDeckContact::default();
        return;
    };
    let kind = playback.runtime.kind;
    let animation_remaining_seconds = manual_animation_remaining_seconds(playback);
    let manual = control.intents.manual.filter(|manual| match kind {
        ManualKind::Tail => *manual < 0.0,
        ManualKind::Nose => *manual > 0.0,
    });
    let manual_brake = control
        .intents
        .manual_brake
        .is_some_and(|brake| match kind {
            ManualKind::Tail => brake < 0.0,
            ManualKind::Nose => brake > 0.0,
        });
    let physics_wants_manual_exit = !sim.ground_contact_valid || manual.is_none();
    let signals = ManualSignals {
        manual: manual.unwrap_or(0.0),
        // Retail Manual attaches processed Turn to the selector's `spin`.
        // The physics-owned deck response is already published to body_tilt
        // on the recovered 60 Hz animation clock. Using it here keeps the
        // full-body FS/neutral/BS leaves synchronized with the board instead
        // of jumping with instantaneous post-dead-zone stick X.
        spin: sim.body_tilt,
        manual_brake,
        board_local_speed_z: sim.local_longitudinal_speed(),
        physics_wants_manual_exit,
        slide_fs_180: false,
        slide_bs_180: false,
        animation_remaining_seconds,
    };
    let _ = sim.step_manual(dt, signals);

    if let Some(playback) = sim.manual.as_ref() {
        sim.manual_deck_contact =
            project_manual_deck(playback.runtime.kind, playback.deck_balance());
        sim.deck_pitch = sim.manual_deck_contact.pitch_radians;
    } else {
        sim.manual_deck_contact = ManualDeckContact::default();
        sim.deck_pitch = 0.0;
    }
}

fn begin_anticipation(sim: &mut SkateSim, identity: AnticipationIdentity) {
    if !can_begin_anticipation(sim) {
        return;
    }
    let side = anticipation_side(identity);
    let push_source = sim.push.as_ref().map(|_| sim.action_animation_state());
    let bridge_clip = sim.push.as_ref().and_then(|push| {
        // The exact MongoPushFootToFar condition compares the active
        // push-foot toe to `push_contact` and gates at -0.5. This source-level
        // port does not own the post-animation toe transform yet. Contact and
        // Cycle are the two recovered states in which the MONGO family has
        // authored the right push foot off-board, so only that bounded route
        // uses the dedicated retail bridge; all other routes retain the
        // graph's ordinary 0.2-second push-frame blend.
        (push.foot == PushFoot::Regular
            && matches!(push.phase, PushPhase::Contact | PushPhase::Cycle))
        .then_some(match side {
            AnticipationSide::Tail => MONGO_PUSH_TO_ANTIC_CLIP,
            AnticipationSide::Nose => MONGO_PUSH_TO_NANTIC_CLIP,
        })
    });
    sim.push = None;
    sim.brake = None;
    sim.slide = None;
    sim.random_idle = None;
    sim.brake_hold_time = 0.0;
    sim.brake_active = false;
    sim.idle_no_input_time = 0.0;
    // `AnticDirection` drives the exported L/N/R endpoint blend, but its
    // upstream projection has not been proven. Neutral is evidence-safe;
    // sector identity still selects the authored directional windup family.
    sim.anticipation = Some(AnticipationRuntime::begin_directional(identity, 0.0));
    sim.push_anticipation_handoff = push_source.map(|source| PushAnticipationHandoff {
        source,
        bridge_clip,
        elapsed_seconds: 0.0,
    });
}

fn step_anticipation_and_handoff(sim: &mut SkateSim, dt: f32) {
    if let Some(anticipation) = sim.anticipation.as_mut() {
        anticipation.step(dt);
        if anticipation.phase == AnticipationPhase::Complete {
            sim.anticipation = None;
        }
    }
    if let Some(handoff) = sim.push_anticipation_handoff.as_mut() {
        handoff.elapsed_seconds += dt;
        if handoff.elapsed_seconds + f32::EPSILON >= PUSH_TO_ANTICIPATION_BLEND_SECONDS {
            sim.push_anticipation_handoff = None;
        }
    }
    if let Some(handoff) = sim.trick_handoff.as_mut() {
        handoff.elapsed_seconds += dt;
        if handoff.elapsed_seconds + f32::EPSILON >= handoff.duration_seconds {
            sim.trick_handoff = None;
        }
    }
}

fn begin_recovered_flat_ground_landing(
    sim: &mut SkateSim,
    visual_test_quality: Option<LandingQuality>,
) {
    let source = sim.action_animation_state();
    let landing_blend = straight_landing_blend(sim.landing_average_velocity_y);
    let landing_distance_to_cog = sim
        .pop_motion
        .as_ref()
        .map(|motion| retail_landing_distance_to_cog_fixture(motion.charge_seconds));
    let approach_speed = sim.speed();
    let velocity_heading =
        (approach_speed > f32::EPSILON).then(|| sim.velocity.x.atan2(sim.velocity.z));
    let board_velocity_heading_delta_radians =
        velocity_heading.map(|heading| wrap_angle(heading - sim.yaw));
    // The clone currently publishes the regular, BS-positive board convention:
    // positive body spin selects IA_BODYSPIN_OLLIE_BS_0_N. This is the same
    // convention SetLandingData passes to B_LAND_* when its orientation query
    // returns regular.
    let classifier = classify_retail_landing_kinematics(RetailLandingClassifierInput {
        approach_speed_metres_per_second: approach_speed,
        heading_delta_radians: board_velocity_heading_delta_radians,
        completed_rotation_radians: sim.body_spin_angle,
        orientation_reversed: false,
    });
    let observed_provider_code = visual_test_quality
        .map(|quality| match quality {
            LandingQuality::Straight => LandingTypeCode::STRAIGHT,
            LandingQuality::Spin => LandingTypeCode::SPIN,
            LandingQuality::Sketchy => LandingTypeCode::SKETCHY,
        })
        .unwrap_or(classifier.provider_code);
    let quality = LandingQuality::from_provider_code(observed_provider_code);
    let random_attribute = match quality {
        LandingQuality::Straight => sim.landing_random.choose_variant(3),
        LandingQuality::Sketchy => sim.landing_random.choose_variant(5),
        // Spin has no ChooseRandomLanding behaviour in Landing.xml.
        LandingQuality::Spin => sim.landing_random_attribute,
    };
    if quality != LandingQuality::Spin {
        sim.landing_random_attribute = random_attribute;
    }
    let parameters = (quality == LandingQuality::Straight).then(|| {
        StraightLandingParameters {
            // Fresh flat-ground harness captures resolve BLEND_LAND to the
            // L_LAND_HIGH_AGGR family. Variant indices 0/1/2 map to 1/2/3.
            posture: LandingPosture::Aggressive,
            variant: landing_variant_from_index(random_attribute)
                .expect("ChooseRandomLanding modulo three is always in range"),
        }
    });
    let decision_input = LandingDecisionInput {
        filtered_state: FilteredPhysicsState::Ground,
        approach_speed_metres_per_second: approach_speed,
        board_velocity_heading_delta_radians,
        completed_rotation_radians: sim.body_spin_angle,
        tilt_too_large_for_preland: Some(false),
        physics_wants_runout: Some(false),
        provider_code: Some(observed_provider_code),
    };
    sim.last_landing_decision_input = Some(decision_input);
    let admission = sim.arbitrate_and_begin_landing(
        decision_input.filtered_state,
        decision_input.tilt_too_large_for_preland,
        decision_input.physics_wants_runout,
        decision_input.provider_code,
        parameters,
    );

    if let LandingAdmission::Enter(entered_quality) = admission {
        let playback = sim
            .landing
            .as_mut()
            .expect("successful landing admission creates playback");
        if let Some(distance_to_cog) = landing_distance_to_cog {
            playback.tree_parameters = Some(LandingTreeParameters {
                spin: classifier.signed_error,
                distance_to_cog,
                average_velocity_y: sim.landing_average_velocity_y,
                random_attribute,
                straight_posture: LandingPosture::Aggressive,
            });
        } else if matches!(
            visual_test_quality,
            Some(LandingQuality::Spin | LandingQuality::Sketchy)
        ) {
            // Unit-level visual-provider fixtures predate the measured pop
            // carrier. Keep their explicit endpoint seam out of live landings.
            playback.non_straight_axes = Some(NonStraightLandingAxes {
                side: crate::landing_animation::LandingSide::Backside,
                compression: crate::landing_animation::LandingCompression::High,
                impact: Some(crate::landing_animation::LandingImpact::High),
            });
        }
        if entered_quality == LandingQuality::Sketchy {
            sim.set_landing_variant(random_attribute)
                .expect("retail modulo-five sketch variant is in range");
        }
        if entered_quality == LandingQuality::Straight {
            sim.landing
                .as_mut()
                .expect("successful straight landing admission creates playback")
                .straight_landing_blend = Some(landing_blend);
        }
        // Every Landing.xml quality child enters its animation with blend=0.15.
        sim.trick_handoff = Some(ActionHandoff {
            source,
            elapsed_seconds: 0.0,
            duration_seconds: crate::landing_graph::LANDING_ANIMATION_BLEND_SECONDS,
        });
    }
}

fn held_push_foot(input: &SkateInput) -> Option<PushFoot> {
    if input.regular_push_held {
        Some(PushFoot::Regular)
    } else if input.mongo_push_held {
        Some(PushFoot::Mongo)
    } else {
        None
    }
}

fn transition_blend_seconds(blend: TransitionBlend) -> Option<f32> {
    match blend {
        TransitionBlend::Inherited => None,
        TransitionBlend::ChannelBlend { seconds, .. } => Some(seconds),
    }
}

fn step_recovered_landing(
    sim: &mut SkateSim,
    input: &mut SkateInput,
    dt: f32,
    began_this_step: bool,
) {
    if sim.landing.is_none() || began_this_step {
        return;
    }
    // ActionGraphIncludes/onground.xml continuously maps held RightPush,
    // LeftPush, and AnticMag/AnticAngle AG intents into MotionGraph intents.
    // Landing.xml evaluates those destination states directly while Landing
    // owns the graph. They are level-sensitive intents, not one-shot edges.
    let anticipation_admission =
        anticipation_admission(input.canonical_pad, sim.flickit_mirror_state());
    let push_foot = held_push_foot(input);
    let animation_will_expire = sim.landing.as_ref().is_some_and(|playback| {
        playback.authored_duration_seconds().is_ok_and(|duration| {
            playback.runtime.elapsed_seconds + dt + LANDING_WILL_EXPIRE_WINDOW_SECONDS >= duration
        })
    });
    let exit_source = sim.action_animation_state();
    let decision = sim.step_landing(
        dt,
        LandingTransitionSignals {
            physics_wants_runout: Some(false),
            push_target_eligible: push_foot.is_some(),
            anticipation_target_eligible: anticipation_admission.is_some(),
            absorb_land_attribute: anticipation_admission.map(|_| false),
            animation_will_expire_within_point_one: animation_will_expire,
            ..default()
        },
    );
    let Some(LandingTransitionDecision::Take(transition)) = decision else {
        return;
    };

    match transition.target {
        LandingTarget::Anticipation => {
            let Some(admission) = anticipation_admission else {
                return;
            };
            sim.basic_trick = None;
            sim.air_trick = None;
            begin_anticipation(sim, admission.identity);
            if sim.anticipation.is_some()
                && let Some(duration_seconds) = transition_blend_seconds(transition.blend)
            {
                sim.trick_handoff = Some(ActionHandoff {
                    source: exit_source,
                    elapsed_seconds: 0.0,
                    duration_seconds,
                });
            }
        }
        LandingTarget::Push => {
            let Some(foot) = push_foot else {
                return;
            };
            sim.basic_trick = None;
            sim.air_trick = None;
            input.pending_push = None;
            request_push(sim, foot);
            if sim.push.is_some()
                && let Some(duration_seconds) = transition_blend_seconds(transition.blend)
            {
                sim.trick_handoff = Some(ActionHandoff {
                    source: exit_source,
                    elapsed_seconds: 0.0,
                    duration_seconds,
                });
            }
        }
        LandingTarget::OnBoard => {
            sim.basic_trick = None;
            sim.air_trick = None;
            sim.board_authority = BoardAuthority::Physics;
            sim.trick_handoff = Some(ActionHandoff {
                source: exit_source,
                elapsed_seconds: 0.0,
                duration_seconds: LANDING_WILL_EXPIRE_WINDOW_SECONDS,
            });
        }
        _ => {}
    }
}

fn grab_transition_samples(playback: &GrabPlayback) -> Vec<AnimationSample> {
    playback
        .animation_state()
        .ok()
        .flatten()
        .map(|state| state.samples)
        .unwrap_or_default()
}

fn set_basic_grab_phase(
    playback: &mut GrabPlayback,
    identity: GrabIdentity,
    phase: GrabPhase,
    blend_seconds: f32,
) {
    let sources = grab_transition_samples(playback);
    let source = sources.first().cloned();
    playback.runtime.identity = identity;
    playback.trick = match identity {
        GrabIdentity::Fs => GrabTrick::Fs,
        GrabIdentity::Bs => GrabTrick::Bs,
        GrabIdentity::Double => GrabTrick::Double,
        GrabIdentity::Mute => GrabTrick::Mute,
        GrabIdentity::Stale => GrabTrick::Stale,
        GrabIdentity::Coffin => GrabTrick::Coffin,
        GrabIdentity::Superman => GrabTrick::Superman,
    };
    playback.tweak = GrabTweakDirection::Neutral;
    playback.runtime.phase = phase;
    playback.phase_time_seconds = 0.0;
    playback.animation_parameters = GrabAnimationParameters::None;
    playback.phase_clip_override = None;
    playback.blend_from = source;
    playback.blend_sources = sources;
    playback.blend_elapsed_seconds = 0.0;
    playback.blend_duration_seconds = blend_seconds.max(0.0);
    playback.tweak_filter_progress = None;
    playback.tweak_filter_blending_out = false;
    playback.tweak_filter_sources.clear();
    playback.tweak_filter_velocity = 0.0;
    playback.tweak_filter_retail_progress = 0.0;
    playback.tweak_filter_pending_step = None;
    playback.tweak_filter_accumulator_seconds = 0.0;
}

fn set_grab_trick_phase(
    playback: &mut GrabPlayback,
    trick: GrabTrick,
    phase: GrabPhase,
    blend_seconds: f32,
) {
    let sources = grab_transition_samples(playback);
    let source = sources.first().cloned();
    playback.runtime.identity = trick.base_identity();
    playback.trick = trick;
    playback.runtime.phase = phase;
    playback.phase_time_seconds = 0.0;
    playback.animation_parameters = GrabAnimationParameters::None;
    playback.phase_clip_override = None;
    playback.blend_from = source;
    playback.blend_sources = sources;
    playback.blend_elapsed_seconds = 0.0;
    playback.blend_duration_seconds = blend_seconds.max(0.0);
    playback.tweak_filter_progress = None;
    playback.tweak_filter_blending_out = false;
    playback.tweak_filter_sources.clear();
    playback.tweak_filter_velocity = 0.0;
    playback.tweak_filter_retail_progress = 0.0;
    playback.tweak_filter_pending_step = None;
    playback.tweak_filter_accumulator_seconds = 0.0;
}

fn set_grab_transition_override(
    playback: &mut GrabPlayback,
    target: GrabTrick,
    clip: &'static str,
    blend_seconds: f32,
) {
    let sources = grab_transition_samples(playback);
    let source = sources.first().cloned();
    playback.runtime.identity = target.base_identity();
    playback.trick = target;
    playback.runtime.phase = GrabPhase::Into;
    playback.phase_time_seconds = 0.0;
    playback.animation_parameters = GrabAnimationParameters::None;
    playback.phase_clip_override = Some(clip);
    playback.blend_from = source;
    playback.blend_sources = sources;
    playback.blend_elapsed_seconds = 0.0;
    playback.blend_duration_seconds = blend_seconds.max(0.0);
    playback.tweak_filter_progress = None;
    playback.tweak_filter_blending_out = false;
    playback.tweak_filter_sources.clear();
    playback.tweak_filter_velocity = 0.0;
    playback.tweak_filter_retail_progress = 0.0;
    playback.tweak_filter_pending_step = None;
    playback.tweak_filter_accumulator_seconds = 0.0;
}

fn step_basic_grab_controls(
    sim: &mut SkateSim,
    canonical_pad: CanonicalPadState,
    delta_seconds: f32,
) {
    let input = BasicGrabInput::from_raw(
        canonical_pad.left_trigger,
        canonical_pad.right_trigger,
        false,
    );
    let trigger_identity = input.identity();
    let expected_domain = if sim.ground_contact_valid {
        GrabDomain::Ground
    } else {
        GrabDomain::Air
    };
    let right_x = canonical_pad.right_x as f32 / i16::MAX as f32;
    let right_y = canonical_pad.right_y as f32 / i16::MAX as f32;
    let live_adjust = if Vec2::new(right_x, right_y).length() <= INPUT_DEADZONE {
        GrabTweakDirection::Neutral
    } else {
        board_adjust_direction(right_x, right_y, input.mirrored)
    };

    if sim.grab.is_none() && trigger_identity.is_none() {
        sim.grab_pre_adjust = live_adjust;
    }
    let selected = select_full_grab(
        input,
        expected_domain,
        sim.grab
            .as_ref()
            .map_or(sim.grab_pre_adjust, |playback| playback.entry_adjust),
        canonical_pad.buttons,
    );

    if sim.grab.is_none()
        && selected.is_some()
        && sim.offboard.is_none()
        && sim.grind.is_none()
        && sim.manual.is_none()
        && sim.landing.is_none()
    {
        let selection = selected.expect("checked above");
        if sim
            .begin_grab_trick(selection.trick, sim.grab_pre_adjust, input.mirrored)
            .is_ok()
            && let Some(playback) = sim.grab.as_mut()
        {
            playback.blend_from = None;
            playback.blend_elapsed_seconds = playback.blend_duration_seconds;
        }
    }

    let Some(playback) = sim.grab.as_mut() else {
        return;
    };
    playback.mirrored = input.mirrored;
    playback.phase_time_seconds += delta_seconds.max(0.0);
    playback.blend_elapsed_seconds += delta_seconds.max(0.0);
    if let Some(progress) = playback.tweak_filter_progress {
        for source in &mut playback.tweak_filter_sources {
            let source_duration = grab_clip_duration_seconds(&source.clip).unwrap_or(0.0);
            source.seek_time_seconds += delta_seconds.max(0.0);
            if source_duration > 0.0 {
                source.seek_time_seconds %= source_duration;
            }
        }
        let config = grab_tweak_filter_config(playback.trick)
            .expect("a live tweak filter is only started for supported grab families");
        playback.tweak_filter_accumulator_seconds += delta_seconds.max(0.0);
        // FilterMotionGraphIntent::Update (TU3 0x82BB17D0) is a discrete
        // update with no delta-time multiplier. Preserve its exact 30 Hz
        // sequence at every even 60 Hz output sample and emit the midpoint to
        // the next proven step on odd samples. This is temporal resampling:
        // the tweak takes exactly as long as the native filter while Bevy
        // receives a new weight every render-oriented 60 Hz tick.
        let output_step_seconds = 1.0 / RETAIL_ANIMATION_HZ;
        let mut progress = progress;
        while playback.tweak_filter_accumulator_seconds + f32::EPSILON >= output_step_seconds {
            progress = step_grab_tweak_filter_output(
                &mut playback.tweak_filter_retail_progress,
                &mut playback.tweak_filter_velocity,
                &mut playback.tweak_filter_pending_step,
                playback.tweak_filter_blending_out,
                config,
            );
            playback.tweak_filter_accumulator_seconds -= output_step_seconds;
        }
        playback.tweak_filter_progress = Some(progress);
        if progress >= 1.0 {
            playback.tweak_filter_progress = None;
            playback.tweak_filter_sources.clear();
        }
    } else if playback.blend_elapsed_seconds >= playback.blend_duration_seconds {
        playback.blend_from = None;
        playback.blend_sources.clear();
    }

    if selected.is_some() && playback.domain != expected_domain {
        let selection = selected.expect("checked above");
        playback.domain = expected_domain;
        playback.entry_adjust = if expected_domain == GrabDomain::Ground {
            GrabTweakDirection::Neutral
        } else {
            playback.entry_adjust
        };
        set_grab_trick_phase(playback, selection.trick, GrabPhase::Cycle, 0.2);
    }

    if playback.domain == GrabDomain::Air {
        if live_adjust == GrabTweakDirection::Neutral {
            playback.tweak_armed = true;
        }
        let desired_tweak = if playback.tweak_armed {
            live_adjust
        } else {
            GrabTweakDirection::Neutral
        };
        if playback.runtime.phase == GrabPhase::Cycle
            && grab_tweak_filter_config(playback.trick).is_some()
            && desired_tweak != playback.tweak
        {
            let sources = playback
                .animation_state()
                .ok()
                .flatten()
                .map(|state| state.samples)
                .unwrap_or_default();
            playback.tweak = desired_tweak;
            playback.blend_from = None;
            playback.blend_sources.clear();
            playback.blend_elapsed_seconds = 0.0;
            playback.blend_duration_seconds = 0.1;
            playback.tweak_filter_progress = Some(0.0);
            playback.tweak_filter_blending_out = desired_tweak == GrabTweakDirection::Neutral;
            playback.tweak_filter_sources = sources;
            playback.tweak_filter_velocity = 0.0;
            playback.tweak_filter_retail_progress = 0.0;
            playback.tweak_filter_pending_step = None;
            playback.tweak_filter_accumulator_seconds = 0.0;
        }
    }

    let expired = playback
        .phase_duration_seconds()
        .is_some_and(|duration| playback.phase_time_seconds + 1.0e-6 >= duration);
    match playback.runtime.phase {
        GrabPhase::Into if expired => match selected.map(|selection| selection.trick) {
            None => {
                let trick = playback.trick;
                set_grab_trick_phase(playback, trick, GrabPhase::Out, 0.1)
            }
            Some(trick) if trick == playback.trick => {
                set_grab_trick_phase(playback, trick, GrabPhase::Cycle, 0.1)
            }
            Some(GrabTrick::Double) if matches!(playback.trick, GrabTrick::Fs | GrabTrick::Bs) => {
                set_basic_grab_phase(
                    playback,
                    playback.runtime.identity,
                    GrabPhase::ToDouble,
                    0.1,
                )
            }
            Some(trick) => set_grab_trick_phase(playback, trick, GrabPhase::Into, 0.1),
        },
        GrabPhase::Cycle => match selected.map(|selection| selection.trick) {
            None => {
                let trick = playback.trick;
                set_grab_trick_phase(playback, trick, GrabPhase::Out, 0.1)
            }
            Some(trick) if trick == playback.trick => {
                if let Some(duration) = playback.phase_duration_seconds()
                    && duration > 0.0
                {
                    playback.phase_time_seconds %= duration;
                }
            }
            Some(GrabTrick::Double) if matches!(playback.trick, GrabTrick::Fs | GrabTrick::Bs) => {
                set_basic_grab_phase(
                    playback,
                    playback.runtime.identity,
                    GrabPhase::ToDouble,
                    0.1,
                )
            }
            Some(GrabTrick::Superman) if playback.trick == GrabTrick::Christ => {
                set_grab_transition_override(
                    playback,
                    GrabTrick::Superman,
                    "GR_DSMNT_N_CHRIST_TO_SUPER",
                    0.1,
                )
            }
            Some(GrabTrick::Superman) if playback.trick == GrabTrick::NoFoot => {
                set_grab_transition_override(
                    playback,
                    GrabTrick::Superman,
                    "GR_DSMNT_N_NOFOOT_TO_SUPER",
                    0.1,
                )
            }
            Some(GrabTrick::Christ) if playback.trick == GrabTrick::Superman => {
                set_grab_transition_override(
                    playback,
                    GrabTrick::Christ,
                    "GR_DSMNT_N_SUPER_TO_CHRIST",
                    0.1,
                )
            }
            Some(GrabTrick::NoFoot) if playback.trick == GrabTrick::Superman => {
                set_grab_transition_override(
                    playback,
                    GrabTrick::NoFoot,
                    "GR_DSMNT_N_SUPER_TO_NOFOOT",
                    0.1,
                )
            }
            Some(trick)
                if playback.trick == GrabTrick::Double
                    && matches!(trick, GrabTrick::Fs | GrabTrick::Bs) =>
            {
                set_basic_grab_phase(playback, trick.base_identity(), GrabPhase::FromDouble, 0.1)
            }
            Some(trick) => set_grab_trick_phase(playback, trick, GrabPhase::Into, 0.1),
        },
        GrabPhase::ToDouble if expired => match selected.map(|selection| selection.trick) {
            None => set_grab_trick_phase(playback, GrabTrick::Double, GrabPhase::Out, 0.1),
            Some(GrabTrick::Double) => {
                set_basic_grab_phase(playback, GrabIdentity::Double, GrabPhase::Cycle, 0.1)
            }
            Some(trick) if matches!(trick, GrabTrick::Fs | GrabTrick::Bs) => {
                set_basic_grab_phase(playback, trick.base_identity(), GrabPhase::FromDouble, 0.1)
            }
            Some(trick) => set_grab_trick_phase(playback, trick, GrabPhase::Into, 0.1),
        },
        GrabPhase::FromDouble if expired => match selected.map(|selection| selection.trick) {
            None => {
                let trick = playback.trick;
                set_grab_trick_phase(playback, trick, GrabPhase::Out, 0.1)
            }
            Some(GrabTrick::Double) => set_basic_grab_phase(
                playback,
                playback.runtime.identity,
                GrabPhase::ToDouble,
                0.1,
            ),
            Some(trick) => set_grab_trick_phase(playback, trick, GrabPhase::Cycle, 0.1),
        },
        GrabPhase::Out if selected.is_some() => set_grab_trick_phase(
            playback,
            selected.expect("checked above").trick,
            GrabPhase::Into,
            0.1,
        ),
        GrabPhase::Out if expired => {
            playback.runtime.phase = GrabPhase::Complete;
        }
        _ => {}
    }

    if playback.runtime.phase == GrabPhase::Complete {
        sim.grab = None;
        sim.board_authority = BoardAuthority::Physics;
    } else {
        sim.board_authority = if playback.domain == GrabDomain::Air {
            playback.trick.board_authority()
        } else {
            BoardAuthority::Physics
        };
    }
}

pub fn fixed_step(
    mut sim: ResMut<SkateSim>,
    mut input: ResMut<SkateInput>,
    ground: Res<SkateGround>,
    level_spawn: Option<Res<LevelSpawn>>,
) {
    let dt = 1.0 / FIXED_HZ as f32;
    sim.elapsed += dt;
    sim.push_cooldown = (sim.push_cooldown - dt).max(0.0);
    sim.left_stick = input.left_stick;
    sim.right_stick = input.right_stick;
    sim.left_trigger = input.left_trigger;
    sim.right_trigger = input.right_trigger;
    sim.steer = input.left_stick.x;
    let landed_from_previous_step = std::mem::take(&mut sim.landed_this_step);

    if input.reset {
        input.reset = false;
        input.pending_push = None;
        input.regular_push_held = false;
        input.mongo_push_held = false;
        input.brake_held = false;
        input.toggle_offboard_pending = false;
        input.right_stick_notifications.clear();
        sim.reset(level_spawn.as_deref().copied().unwrap_or_default());
        return;
    }

    sim.step_skateboard_offset_transition(dt);
    let flickit_mirror_state = sim.flickit_mirror_state();
    sim.trick_input
        .step_probe(input.canonical_pad, flickit_mirror_state);
    while let Some(notification) = input.right_stick_notifications.pop_front() {
        let flickit_mirror_state = sim.flickit_mirror_state();
        let anticipation_admission = anticipation_admission(notification, flickit_mirror_state);
        let winner = sim
            .trick_input
            .observe_retail_notification(notification, flickit_mirror_state, MatcherMode::Default)
            .winner
            .as_ref()
            .map(|(_, name)| name.clone());
        let trick_began = winner
            .as_deref()
            .is_some_and(|winner| begin_verified_endpoint_trick(&mut sim, winner));
        if !trick_began {
            if sim.anticipation.is_none() {
                if let Some(admission) = anticipation_admission {
                    begin_anticipation(&mut sim, admission.identity);
                }
            } else if let Some(runtime) = sim.anticipation.as_mut()
                && runtime.is_held()
            {
                match anticipation_admission {
                    Some(admission) if admission.side == runtime.side => {
                        runtime.update_held_identity(admission.identity, 0.0);
                    }
                    _ => runtime.request_cancel(),
                }
            }
        }
    }
    step_anticipation_and_handoff(&mut sim, dt);

    let toggle_offboard = std::mem::take(&mut input.toggle_offboard_pending);
    if sim.offboard.is_none() && toggle_offboard {
        begin_dismount(&mut sim);
    } else if toggle_offboard && let Some(offboard) = sim.offboard.as_mut() {
        offboard.request_mount();
    }

    if sim.offboard.is_some() {
        step_offboard(&mut sim, &mut input, dt);
        apply_ground_contact(&mut sim, &ground);
        step_retail_animation_signals(&mut sim, dt);
        return;
    }

    step_mount_visual_blend(&mut sim, dt);
    step_basic_grab_controls(&mut sim, input.canonical_pad, dt);
    step_held_manual_control(&mut sim, dt, landed_from_previous_step);

    // The authored basic-trick clock advances independently of render cadence.
    // Wheel lift comes from the measured pop carrier's four-centimetre
    // separation boundary. Touchdown enters the recovered BLEND_LAND state
    // before its former airborne owner is advanced.
    let held_grab_crossed_to_ground = sim.grab.as_ref().is_some_and(|playback| {
        playback.domain == GrabDomain::Ground
            && !matches!(playback.runtime.phase, GrabPhase::Out | GrabPhase::Complete)
    });
    let began_landing_this_step = landed_from_previous_step
        && sim.landing.is_none()
        && !held_grab_crossed_to_ground
        && (sim.basic_trick.is_some() || sim.air_trick.is_some() || sim.grab.is_some());
    if began_landing_this_step {
        begin_recovered_flat_ground_landing(&mut sim, None);
    }
    if sim.basic_trick.is_some() {
        let wheel_lifted = sim
            .pop_motion
            .as_ref()
            .is_some_and(|motion| motion.separated_from_ground)
            && !sim.ground_contact_valid;
        let established_airborne = wheel_lifted
            && sim
                .basic_trick
                .as_ref()
                .is_some_and(|playback| playback.runtime.phase != BasicTrickPhase::GroundLeaf);
        sim.step_basic_trick(
            dt,
            BasicTrickSignals {
                wheel_lifted,
                established_airborne,
                ..default()
            },
            None,
        );
        // Once the exact G/A sequence has ended, retain the ground provider's
        // already-confirmed OnBoard authority instead of parking on the
        // B_AIR_CYC selector when no landing state owns the graph.
        if sim.landing.is_none()
            && sim.ground_contact_valid
            && sim
                .basic_trick
                .as_ref()
                .is_some_and(|playback| playback.runtime.phase == BasicTrickPhase::AirBaseline)
        {
            sim.basic_trick = None;
            sim.board_authority = BoardAuthority::Physics;
        }
    }
    if let Some(playback) = sim.air_trick.as_ref() {
        let wheel_lifted = sim
            .pop_motion
            .as_ref()
            .is_some_and(|motion| motion.separated_from_ground)
            && !sim.ground_contact_valid;
        let established_airborne = wheel_lifted
            && playback.runtime.phase != crate::air_trick_graph::AirTrickPhase::TakeoffGround;
        let animation_will_expire = playback
            .authored_phase_duration_seconds()
            .ok()
            .flatten()
            .is_some_and(|duration| {
                playback.phase_time_seconds + dt + WILL_EXPIRE_WINDOW_SECONDS >= duration
            });
        let handoff_target = if landed_from_previous_step {
            crate::air_trick_graph::HandoffTarget::Land
        } else if sim.ground_contact_valid {
            crate::air_trick_graph::HandoffTarget::OnBoard
        } else {
            crate::air_trick_graph::HandoffTarget::InAir
        };
        let trick_hold = sim.trick_input.retail_selected_pattern_held_name()
            == Some(playback.runtime.trick.intent_name());
        let time_to_land_seconds = sim
            .pop_motion
            .as_ref()
            .map(|motion| (motion.touchdown_seconds - motion.elapsed_since_flick_seconds).max(0.0));
        sim.step_air_trick(
            dt,
            AirTrickSignals {
                wheel_lifted,
                established_airborne,
                animation_will_expire,
                trick_hold,
                time_to_land_seconds,
                handoff_target: Some(handoff_target),
                ..default()
            },
        );
    }
    step_recovered_landing(&mut sim, &mut input, dt, began_landing_this_step);
    let anticipation_owns_motion_graph = sim.anticipation.is_some();
    let basic_trick_owns_motion_graph = sim.basic_trick.is_some();
    let air_trick_owns_motion_graph = sim.air_trick.is_some();
    let grab_owns_motion_graph = sim.grab.is_some();
    let landing_owns_motion_graph = sim.landing.is_some();
    let grind_owns_motion_graph = sim.grind.is_some();
    let manual_owns_motion_graph = sim.manual.is_some();

    let speed = sim.speed();
    sim.candidate_slide_weight = candidate_slide_weight(sim.left_stick, speed);
    sim.candidate_slide_active = sim.candidate_slide_weight >= 1.0 - f32::EPSILON;
    let slide_requested = can_enter_powerslide(sim.left_stick, speed, sim.ground_contact_valid);
    if !anticipation_owns_motion_graph
        && !basic_trick_owns_motion_graph
        && !air_trick_owns_motion_graph
        && !grab_owns_motion_graph
        && !landing_owns_motion_graph
        && !grind_owns_motion_graph
        && !manual_owns_motion_graph
        && sim.slide.is_none()
        && slide_requested
    {
        begin_slide(&mut sim);
    }

    let slide_owns_motion_graph = sim.slide.is_some();

    if anticipation_owns_motion_graph
        || basic_trick_owns_motion_graph
        || air_trick_owns_motion_graph
        || grab_owns_motion_graph
        || landing_owns_motion_graph
        || grind_owns_motion_graph
        || manual_owns_motion_graph
    {
        sim.brake_hold_time = 0.0;
        sim.brake_active = false;
        input.pending_push = None;
    } else if slide_owns_motion_graph {
        sim.brake_hold_time = 0.0;
        sim.brake_active = false;
        step_slide_state(&mut sim, dt);
        input.pending_push = None;
    } else {
        step_brake_state(&mut sim, dt, input.brake_held);
        if sim.brake.is_none() {
            if let Some(foot) = input.pending_push.take() {
                request_push(&mut sim, foot);
            }
            let active_push_held = sim.push.as_ref().is_some_and(|push| match push.foot {
                PushFoot::Regular => input.regular_push_held,
                PushFoot::Mongo => input.mongo_push_held,
            });
            step_push_state(&mut sim, dt, active_push_held);
        } else {
            input.pending_push = None;
        }
    }

    let slide_physics_active = sim
        .slide
        .as_ref()
        .is_some_and(|slide| !matches!(slide.phase, SlidePhase::Out(_)));
    let transition_pop_launch = if ground.transition_test {
        advance_transition_pop_motion(&mut sim, dt)
    } else {
        None
    };
    let airborne_pop_motion = sim
        .pop_motion
        .as_ref()
        .is_some_and(|motion| motion.separated_from_ground && !motion.touched_down);
    let pop_spin_window = sim
        .pop_motion
        .as_ref()
        .is_some_and(|motion| !motion.touched_down);
    if !grind_owns_motion_graph {
        if ground.transition_test {
            let physically_airborne = sim.transition.phase == TransitionPhase::Airborne
                || transition_pop_launch.is_some();
            let yaw_before_motion = sim.yaw;
            if physically_airborne {
                step_airborne_body_spin(&mut sim, dt);
            } else if !air_trick_owns_motion_graph && !pop_spin_window {
                step_heading(&mut sim, dt, slide_physics_active);
            }
            let heading_delta = wrap_angle(sim.yaw - yaw_before_motion);
            let velocity_before_motion = sim.velocity;
            let transition_input = TransitionStepInput {
                dt,
                activation_yaw: sim.yaw,
                heading_delta,
                // The exact Pumping conditioner and force direction are
                // recovered. Mapping the live crouch channel into its missing
                // animated-COM operands is the isolated provisional bridge.
                pump_intent: (-sim.right_stick.y).max(0.0),
                powersliding: slide_physics_active,
                braking: sim.brake_active && input.brake_held,
                maximum_speed: MAX_SPEED,
                pop_launch_speed: transition_pop_launch,
            };
            let mut transition = std::mem::take(&mut sim.transition);
            let mut transition_position = sim.position;
            let mut transition_velocity = sim.velocity;
            let transition_output = transition.step(
                &ground.provider,
                &mut transition_position,
                &mut transition_velocity,
                transition_input,
            );
            sim.position = transition_position;
            sim.velocity = transition_velocity;
            sim.transition = transition;
            sim.planar_acceleration = transition_output.friction.acceleration;
            sim.lateral_friction_rate = transition_output.friction.lateral_rate;
            sim.last_contact_friction = transition_output.friction;
            sim.ground_contact_valid = transition_output.filtered_grounded;
            sim.ground_normal = sim.transition.support_up;
            sim.ground_surface_id = transition_output.surface_id;
            if sim.transition.is_physically_grounded() {
                let rolling_distance = sim.velocity.dot(sim.transition.support_forward) * dt;
                sim.wheel_spin = (sim.wheel_spin - rolling_distance / WHEEL_RADIUS)
                    .rem_euclid(std::f32::consts::TAU);
            }
            if transition_output.landed_this_step {
                let impact_speed =
                    (-velocity_before_motion.dot(sim.transition.support_up)).max(0.0);
                sim.landing_average_velocity_y = sim.landing_average_velocity_y.max(impact_speed);
                sim.landed_this_step = true;
                if let Some(motion) = sim.pop_motion.as_mut()
                    && motion.separated_from_ground
                    && !motion.touched_down
                {
                    motion.touched_down = true;
                    motion.transition_touchdown_seconds = Some(motion.elapsed_since_flick_seconds);
                }
            }
        } else {
            if airborne_pop_motion {
                step_airborne_body_spin(&mut sim, dt);
            } else if !air_trick_owns_motion_graph && !pop_spin_window {
                step_heading(&mut sim, dt, slide_physics_active);
            }
            if airborne_pop_motion {
                step_airborne_planar_motion(&mut sim, dt);
            } else {
                step_velocity(
                    &mut sim,
                    dt,
                    slide_physics_active,
                    input.brake_held,
                    landed_from_previous_step,
                );
            }
            if sim.pop_motion.is_some() {
                step_retail_pop_carrier(&mut sim, dt);
            }
            apply_ground_contact(&mut sim, &ground);
        }
    }
    step_view_heading(&mut sim, pop_spin_window);

    let velocity_x = sim.velocity.x;
    let velocity_z = sim.velocity.z;
    let board_yaw = sim.yaw;
    // TU3 UpdateRidingFakie accepts PhysicsAnimationState values 1 and 2:
    // FORCE_PHYSICS_SKATEBOARD and FORCE_ANIM_SKATEBOARD. It rejects the
    // brief FOLLOW_ANIMATION_DATA takeoff handoff (value 0), so established
    // air remains eligible instead of delaying fakie until touchdown.
    let fakie_motion_eligible = riding_fakie_motion_eligible(sim.board_authority);
    sim.fakie
        .observe_motion(dt, velocity_x, velocity_z, board_yaw, fakie_motion_eligible);
    let fakie_shuffle_blocked = sim.right_stick.length() > INPUT_DEADZONE
        || sim.anticipation.is_some()
        || sim.basic_trick.is_some()
        || sim.air_trick.is_some()
        || sim.grab.is_some()
        || sim.landing.is_some()
        || sim.grind.is_some()
        || sim.manual.is_some()
        || sim.push.is_some()
        || sim.brake.is_some()
        || sim.slide.is_some();
    if sim.fakie.step(dt, fakie_shuffle_blocked) != FakieStepEvent::None {
        sim.random_idle = None;
        sim.idle_no_input_time = 0.0;
        sim.animation_revision = sim.animation_revision.wrapping_add(1);
    }

    let active_input = sim.left_stick.length_squared() > 0.0001
        || input.brake_held
        || input.regular_push_held
        || input.mongo_push_held
        || sim.push.is_some()
        || sim.brake.is_some()
        || sim.slide.is_some()
        || sim.anticipation.is_some()
        || sim.basic_trick.is_some()
        || sim.air_trick.is_some()
        || sim.grab.is_some()
        || sim.landing.is_some()
        || sim.grind.is_some()
        || sim.manual.is_some();
    step_random_idle(&mut sim, dt, active_input);
    step_board_lean(&mut sim, dt, slide_physics_active);
    step_retail_animation_signals(&mut sim, dt);
}

fn begin_dismount(sim: &mut SkateSim) {
    let offboard = OffboardRuntime::begin_dismount(sim.speed(), sim.yaw);
    let clip = offboard.primary_clip();
    let repeats = offboard.repeats();
    let transition = offboard.transition_seconds();
    sim.trick_input.reset_retail_gesture_state();
    sim.offboard = Some(offboard);
    sim.offboard_visual = None;
    sim.fakie = FakieRuntime::default();
    sim.active_trick_context = None;
    sim.anticipation = None;
    sim.push_anticipation_handoff = None;
    sim.trick_handoff = None;
    sim.basic_trick = None;
    sim.air_trick = None;
    sim.grab = None;
    sim.landing = None;
    sim.grind = None;
    sim.manual = None;
    sim.pop_motion = None;
    sim.landed_this_step = false;
    sim.body_spin_angle = 0.0;
    sim.body_spin_velocity = 0.0;
    sim.body_spin_animation_phase_seconds = 0.0;
    sim.airborne_body_spin_input_observed = false;
    sim.transition = TransitionRuntime::default();
    sim.push = None;
    sim.brake = None;
    sim.slide = None;
    sim.random_idle = None;
    sim.brake_hold_time = 0.0;
    sim.brake_active = false;
    sim.powerslide_rotation = 0.0;
    sim.idle_no_input_time = 0.0;
    sim.set_animation(Some(clip), repeats, transition, false);
}

fn step_offboard(sim: &mut SkateSim, input: &mut SkateInput, dt: f32) {
    input.pending_push = None;
    let Some(mut offboard) = sim.offboard.take() else {
        return;
    };

    let old_velocity = sim.velocity;
    let previous_yaw = sim.yaw;
    let step = offboard.step(
        dt,
        OffboardControl {
            left_stick: sim.left_stick,
            // TU3 ActionGraphInputListener::Fill emits OB_Sprint when input-map
            // timer 78 is positive and timer 79 is non-positive. Runtime
            // telemetry identifies timer 78 as Xbox A.
            sprint_held: input.regular_push_held,
            world_yaw: sim.yaw,
        },
    );
    sim.yaw_rate = step.yaw_rate;
    sim.yaw += sim.yaw_rate * dt;
    sim.view_yaw = step.view_yaw;
    let motion_yaw = (previous_yaw + sim.yaw) * 0.5;
    let mut world_delta = Quat::from_rotation_y(motion_yaw) * step.local_delta;
    // Ground-provider locomotion follows the authored horizontal root while
    // collision support owns world height.
    world_delta.y = 0.0;
    sim.position += world_delta;
    sim.velocity = world_delta / dt;
    sim.velocity.y = 0.0;
    sim.planar_acceleration = (sim.velocity - old_velocity) / dt;
    sim.lateral_friction_rate = 0.0;
    sim.last_contact_friction = ContactFrictionOutput::default();
    sim.candidate_slide_weight = 0.0;
    sim.candidate_slide_active = false;
    sim.deck_roll = 0.0;
    sim.deck_roll_velocity = 0.0;
    sim.body_tilt = 0.0;

    if step.mounted {
        sim.offboard = None;
        sim.board_authority = BoardAuthority::Physics;
        sim.offboard_visual = Some(offboard);
        return;
    }

    let clip = offboard.primary_clip();
    if sim.animation_clip.as_deref() != Some(clip.as_str()) {
        sim.set_animation(
            Some(clip),
            offboard.repeats(),
            offboard.transition_seconds(),
            false,
        );
    }
    sim.offboard = Some(offboard);
}

fn step_mount_visual_blend(sim: &mut SkateSim, dt: f32) {
    let Some(mut visual) = sim.offboard_visual.take() else {
        return;
    };
    debug_assert!(visual.riding_handoff_active());
    // Physical root motion is intentionally ignored after the retail handoff.
    // The retained runtime advances only the authored mount-to-riding fade.
    visual.step(
        dt,
        OffboardControl {
            world_yaw: sim.yaw,
            ..OffboardControl::default()
        },
    );
    if visual.riding_handoff_blend_finished() {
        sim.set_animation(None, false, 0.0, false);
    } else {
        sim.offboard_visual = Some(visual);
    }
}

fn apply_ground_contact(sim: &mut SkateSim, ground: &SkateGround) {
    let origin = GroundVec3::new(sim.position.x, sim.position.y + 2.0, sim.position.z);
    let result = ground
        .provider
        .query_down(origin, 4.0)
        .expect("finite fixed-step ground probe");
    if let Some(motion) = sim.pop_motion.as_ref() {
        let touching = motion.touched_down || !motion.separated_from_ground;
        sim.ground_contact_valid = touching;
        if let Some(contact) = result.contact() {
            sim.ground_normal = Vec3::new(contact.normal.x, contact.normal.y, contact.normal.z);
            sim.ground_surface_id = touching.then_some(contact.surface_id.0);
        } else {
            sim.ground_surface_id = None;
        }
        return;
    }
    if let Some(contact) = result.contact() {
        sim.ground_contact_valid = true;
        sim.position.y = contact.point.y;
        sim.ground_normal = Vec3::new(contact.normal.x, contact.normal.y, contact.normal.z);
        sim.ground_surface_id = Some(contact.surface_id.0);
    } else {
        sim.ground_contact_valid = false;
        sim.ground_surface_id = None;
    }
}

fn step_board_lean(sim: &mut SkateSim, dt: f32, powersliding: bool) {
    // SettingBodyTilt reads the board/physics result, not the raw stick. Keep a
    // second-order board state so direction changes have angular velocity and
    // acceleration continuity before the 60 Hz animation signal is published.
    let articulation_scale = if powersliding { 0.38 } else { 1.0 };
    let maximum_roll = (0.08 + sim.speed() * 0.015).clamp(0.08, 0.245) * articulation_scale;
    let control_steer = if powersliding {
        sim.slide
            .as_ref()
            .map_or(sim.steer, |slide| slide.control.x)
    } else {
        sim.steer
    };
    let target_roll = control_steer * maximum_roll;
    let angular_frequency = 11.0;
    let acceleration = angular_frequency * angular_frequency * (target_roll - sim.deck_roll)
        - 2.0 * angular_frequency * sim.deck_roll_velocity;
    sim.deck_roll_velocity += acceleration * dt;
    sim.deck_roll += sim.deck_roll_velocity * dt;
}

fn step_retail_animation_signals(sim: &mut SkateSim, dt: f32) {
    sim.retail_animation_accumulator += dt;
    let animation_step = 1.0 / RETAIL_ANIMATION_HZ;
    while sim.retail_animation_accumulator + f32::EPSILON >= animation_step {
        sim.retail_animation_accumulator -= animation_step;
        update_landing_average_velocity_y(sim);
        sim.ride_phase_time =
            (sim.ride_phase_time + animation_step).rem_euclid(RIDE_CLIP_DURATION_SECONDS);

        let maximum_roll = (0.08 + sim.speed() * 0.015).clamp(0.08, 0.245);
        sim.body_tilt = if maximum_roll > f32::EPSILON {
            (sim.deck_roll / maximum_roll).clamp(-1.0, 1.0)
        } else {
            0.0
        };

        let speed = sim.speed();
        let body_tilt = sim.body_tilt;
        if let Some(push) = sim.push.as_mut() {
            push.turn_coefficient = body_tilt;
            push.direction = direction_band(body_tilt);
            push.target_coefficients =
                compute_target_coefficients(push_attributes(push.foot), speed, push.strength);
            // SetPushCoefs is a 60 Hz conditioner over the three current
            // blend-tree coefficients. TU3 conditions the two `*_Vel_B`
            // coordinates together and `Vel_E` through a second path.
            push.coefficients.high_strength_velocity_begin = move_towards(
                push.coefficients.high_strength_velocity_begin,
                push.target_coefficients.high_strength_velocity_begin,
                1.0 / 12.0,
            );
            push.coefficients.low_strength_velocity_begin = move_towards(
                push.coefficients.low_strength_velocity_begin,
                push.target_coefficients.low_strength_velocity_begin,
                1.0 / 12.0,
            );
            push.coefficients.velocity_end = move_towards(
                push.coefficients.velocity_end,
                push.target_coefficients.velocity_end,
                1.0 / 12.0,
            );
            // AnimationTree::GetDuration is coefficient-dependent. Retail's
            // WillExpire checks therefore follow the changing tree rather than
            // freezing the duration selected on state entry.
            push.phase_duration = push.retail_phase_duration();
        }
        let velocity = sim.velocity;
        let yaw = sim.yaw;
        if let Some(slide) = sim.slide.as_mut()
            && !matches!(slide.phase, SlidePhase::Out(_))
        {
            slide.decel_target = slide_decel_target(velocity, yaw);
            // PowerSlideDecel applies the configured scalar as an exponential
            // one-step blend at the retail 60 Hz animation update.
            slide.decel = slide.decel_target * SLIDE_DECEL_SMOOTHING
                + slide.decel * (1.0 - SLIDE_DECEL_SMOOTHING);
            slide.phase_duration = slide.retail_phase_duration();
        }
    }
}

fn update_landing_average_velocity_y(sim: &mut SkateSim) {
    let Some(motion) = sim
        .pop_motion
        .as_mut()
        .filter(|motion| motion.separated_from_ground && !motion.touched_down)
    else {
        return;
    };

    // sub_82BAFFF0 projects the auxiliary provider's physics velocity onto its
    // reference-up vector. The flat-ground traces above recover that separate
    // projection stream directly; do not substitute the rendered carrier's Y.
    let projection = motion.retail_projection_velocity_y;
    if projection < 0.0 {
        sim.landing_average_velocity_y = sim.landing_average_velocity_y.max(-projection);
    }
    motion.retail_projection_velocity_y = (projection + motion.retail_projection_delta_per_frame)
        .max(-motion.retail_projection_touchdown_velocity_y);
}

fn begin_slide(sim: &mut SkateSim) {
    sim.trick_input.reset_retail_gesture_state();
    sim.push = None;
    sim.brake = None;
    sim.random_idle = None;
    sim.brake_hold_time = 0.0;
    sim.brake_active = false;
    sim.powerslide_rotation = 0.0;
    let control = stance_local_slide_stick(sim.left_stick, sim.slide_control_mirrored);
    let mut slide = SlideRuntime::new(control.x);
    slide.control = control;
    slide.control_target = control;
    slide.intent = active_slide_intent(control, false);
    slide.intent_target = slide.intent;
    sim.slide = Some(slide);
    sim.set_animation_from_slide();
}

fn step_slide_state(sim: &mut SkateSim, dt: f32) {
    let mut phase_changed = false;
    let mut finished = false;
    let mut finished_overshoot = 0.0;
    let speed = sim.speed();
    let stick = sim.left_stick;
    let contact_valid = sim.ground_contact_valid;
    let mirrored_stance = sim.slide_control_mirrored;

    if let Some(slide) = sim.slide.as_mut() {
        slide.phase_time += dt;
        slide.total_time += dt;
        if slide.transition_duration > 0.0
            && slide.phase_time + f32::EPSILON >= slide.transition_duration
        {
            slide.transition_from_samples.clear();
            slide.transition_from_phase = None;
            slide.transition_duration = 0.0;
        }
        slide.control_target = stance_local_slide_stick(stick, mirrored_stance);
        slide.intent_target = active_slide_intent(stick, mirrored_stance);
        let response = 1.0 - (-dt / CAPTURED_SLIDE_YAW_RESPONSE_SECONDS).exp();
        slide.control += (slide.control_target - slide.control) * response;
        slide.intent += (slide.intent_target - slide.intent) * response;

        // ShouldLeaveSlide is a live parent-transition condition. The slide
        // state itself is latched, but a transient pre-guard release is not
        // remembered forever if the processed control becomes active again.
        slide.leave_condition = should_leave_active_slide(stick, speed, contact_valid);

        match slide.phase {
            SlidePhase::Into | SlidePhase::Cycle
                if slide.leave_condition && slide.total_time > SLIDE_PARENT_LEAVE_GUARD_SECONDS =>
            {
                let out = slide_out_for_rotation(slide.rotation);
                slide.begin_out(out);
                phase_changed = true;
            }
            SlidePhase::Into if slide.phase_time >= slide.phase_duration => {
                slide.begin_cycle();
                phase_changed = true;
            }
            SlidePhase::Out(_) if slide.phase_time >= slide.phase_duration => {
                finished_overshoot = slide.phase_time - slide.phase_duration;
                slide.phase_time = slide.phase_duration;
                finished = true;
            }
            _ => {}
        }
    }

    if finished {
        let exit_source = sim.action_animation_state();
        sim.slide = None;
        sim.powerslide_rotation = 0.0;
        sim.set_animation(None, false, 0.2, false);
        sim.trick_handoff = Some(ActionHandoff {
            source: exit_source,
            elapsed_seconds: finished_overshoot.min(SLIDE_TO_RIDING_BLEND_SECONDS),
            duration_seconds: SLIDE_TO_RIDING_BLEND_SECONDS,
        });
    } else if phase_changed {
        sim.set_animation_from_slide();
    }
}

fn step_brake_state(sim: &mut SkateSim, dt: f32, brake_held: bool) {
    if brake_held {
        sim.brake_hold_time += dt;
    } else {
        sim.brake_hold_time = 0.0;
    }
    sim.brake_active =
        brake_held && sim.brake_hold_time >= BRAKE_LEAD_IN_SECONDS && sim.speed() > 0.0;

    if sim.brake.is_none() && brake_held {
        sim.trick_input.reset_retail_gesture_state();
        sim.push = None;
        sim.random_idle = None;
        sim.brake = Some(BrakeRuntime::new(sim.speed()));
        sim.set_animation_from_brake();
    }
    let Some(phase) = sim.brake.as_ref().map(|brake| brake.phase) else {
        return;
    };
    let current_speed = sim.speed();

    let mut next_phase = None;
    let mut finished = false;
    if let Some(brake) = sim.brake.as_mut() {
        brake.phase_time += dt;
        match phase {
            BrakePhase::MovingInto if brake.phase_time >= brake.phase_duration => {
                next_phase = Some(BrakePhase::MovingCycle);
            }
            BrakePhase::MovingCycle if current_speed < MOVING_BRAKE_THRESHOLD => {
                next_phase = Some(BrakePhase::StandFromMoving);
            }
            BrakePhase::MovingCycle if !brake_held => {
                next_phase = Some(BrakePhase::MovingOut);
            }
            BrakePhase::MovingOut if brake.phase_time >= brake.phase_duration => {
                finished = true;
            }
            BrakePhase::StandInto if brake.phase_time >= brake.phase_duration => {
                next_phase = Some(BrakePhase::StandCycle);
            }
            BrakePhase::StandFromMoving if !brake_held => {
                next_phase = Some(BrakePhase::StandOut);
            }
            BrakePhase::StandFromMoving if brake.phase_time >= brake.phase_duration => {
                next_phase = Some(BrakePhase::StandCycle);
            }
            BrakePhase::StandCycle if !brake_held => {
                next_phase = Some(BrakePhase::StandOut);
            }
            BrakePhase::StandOut if brake.phase_time >= brake.phase_duration => {
                finished = true;
            }
            _ => {}
        }
    }

    if finished {
        sim.brake = None;
        sim.brake_active = false;
        sim.set_animation(None, false, 0.2, false);
    } else if let Some(next_phase) = next_phase {
        if let Some(brake) = sim.brake.as_mut() {
            brake.set_phase(next_phase);
        }
        sim.set_animation_from_brake();
    }
}

fn request_push(sim: &mut SkateSim, foot: PushFoot) {
    if let Some(push) = sim.push.as_mut() {
        sim.trick_input.reset_retail_gesture_state();
        push.queue_repush();
        return;
    }
    if sim.push_cooldown > 0.0 || sim.brake.is_some() || sim.slide.is_some() {
        return;
    }

    sim.trick_input.reset_retail_gesture_state();
    sim.random_idle = None;
    sim.push = Some(PushRuntime::new(foot, sim.speed(), sim.steer));
    sim.push_cooldown = REPUSH_COOLDOWN;
    sim.last_push_elapsed = sim.elapsed;
    sim.set_animation_from_push();
}

fn step_push_state(sim: &mut SkateSim, dt: f32, push_held: bool) {
    let speed_before_step = sim.speed();
    let mut propulsion_target = None;
    let mut begin_contact = false;
    let mut contact_strength = 0.0;
    let mut phase_changed = false;
    let mut finished = false;

    if let Some(push) = sim.push.as_mut() {
        push.charge_first_push(dt, push_held);
        push.charge_queued_repush(dt, push_held, speed_before_step);
        push.phase_time += dt;
        if push.phase == PushPhase::Into {
            let playback_time = (push.phase_time - PUSH_INTO_TRANSITION_SECONDS).max(0.0);
            let (drive_start, drive_end) = push.into_drive_source_window();
            if playback_time >= drive_start {
                if !push.contact_propulsion_enabled {
                    push.begin_contact_propulsion(speed_before_step, push.strength);
                }
                let progress = ((playback_time - drive_start)
                    / (drive_end - drive_start).max(f32::EPSILON))
                .clamp(0.0, 1.0);
                let profile = sample_piecewise_curve(&PUSH_DRIVE_DELIVERY_PROFILE, progress);
                propulsion_target = Some(
                    push.contact_start_speed
                        + (push.contact_target_speed - push.contact_start_speed) * profile,
                );
            }
        } else if push.phase == PushPhase::Contact && push.contact_propulsion_enabled {
            let progress = (push.phase_time / push.phase_duration).clamp(0.0, 1.0);
            let profile = sample_piecewise_curve(&PUSH_DRIVE_DELIVERY_PROFILE, progress);
            propulsion_target = Some(
                push.contact_start_speed
                    + (push.contact_target_speed - push.contact_start_speed) * profile,
            );
        }
        if push.phase_time >= push.phase_duration {
            match push.phase {
                PushPhase::Into => {
                    push.set_phase(PushPhase::Contact);
                }
                PushPhase::Contact => push.set_phase(PushPhase::Cycle),
                PushPhase::Cycle if push_held || push.queued_repush => {
                    contact_strength = if push.queued_repush {
                        push.queued_repush_strength
                    } else {
                        PUSH_STRENGTH_OUTPUT_GRAPH[7].1
                    };
                    push.queued_repush = false;
                    push.queued_repush_hold_time = 0.0;
                    push.queued_repush_strength = 0.0;
                    push.queued_repush_strength_frozen = false;
                    push.repeat_count = push.repeat_count.saturating_add(1);
                    push.set_phase(PushPhase::Contact);
                    begin_contact = true;
                }
                PushPhase::Cycle => push.begin_out(),
                PushPhase::Out => finished = true,
            }
            phase_changed = !finished;
        }
    }

    let exit_source = finished.then(|| sim.action_animation_state());
    if begin_contact {
        if let Some(push) = sim.push.as_mut() {
            push.begin_contact_propulsion(speed_before_step, contact_strength);
        }
        sim.last_push_elapsed = sim.elapsed;
        sim.push_cooldown = REPUSH_COOLDOWN;
    }
    if let Some(target) = propulsion_target {
        apply_push_propulsion(sim, target);
    }

    if finished {
        sim.push = None;
        sim.set_animation(None, false, 0.2, false);
        sim.trick_handoff = exit_source.map(|source| ActionHandoff {
            source,
            elapsed_seconds: 0.0,
            duration_seconds: PUSH_TO_RIDING_BLEND_SECONDS,
        });
    } else if phase_changed {
        sim.set_animation_from_push();
    }
}

fn apply_push_propulsion(sim: &mut SkateSim, target_forward_speed: f32) {
    let forward = if sim.transition.is_enabled() && sim.transition.is_physically_grounded() {
        sim.transition.support_forward
    } else {
        Vec3::new(sim.yaw.sin(), 0.0, sim.yaw.cos())
    };
    let current_forward_speed = sim.velocity.dot(forward);
    if target_forward_speed > current_forward_speed {
        sim.velocity += forward * (target_forward_speed - current_forward_speed);
    }
}

fn step_heading(sim: &mut SkateSim, dt: f32, powersliding: bool) {
    let low_speed_turn_rate = (CARVE_TURN_RATE_INTERCEPT
        - sim.speed() * CARVE_TURN_RATE_SPEED_SLOPE)
        .clamp(CARVE_TURN_RATE_MINIMUM, CARVE_TURN_RATE_MAXIMUM);
    let rolling_curvature_rate = sim.speed() * CAPTURED_CARVE_CURVATURE;
    let carve_turn_rate = low_speed_turn_rate.max(rolling_curvature_rate);
    let rolling_target = -rolling_turn_axis(sim.left_stick) * carve_turn_rate;
    let slide_target = sim.slide.as_ref().map_or_else(
        || -sim.steer.signum() * captured_slide_yaw_rate(sim.speed()),
        |slide| {
            // PowerSliding updates both processed channels. Preserve the
            // latched authored FS/BS leaf, but let the conditioned lateral
            // channel continuously scale and reverse physical yaw through
            // zero. Entry calibration keeps the matched capture's initial
            // rate unchanged without introducing a second sensitivity.
            let lateral = (slide.control.x / slide.entry_lateral_abs).clamp(-1.0, 1.0);
            -lateral * slide.intent.clamp(0.0, 1.0) * captured_slide_yaw_rate(sim.speed())
        },
    );

    let slide_out = sim
        .slide
        .as_ref()
        .is_some_and(|slide| matches!(slide.phase, SlidePhase::Out(_)));
    let (target_yaw_rate, response_seconds) = if powersliding {
        (slide_target, CAPTURED_SLIDE_YAW_RESPONSE_SECONDS)
    } else if slide_out {
        // ShouldLeaveSlide clears the physical slide-state bit, but the
        // PowerSliding angular state continues through the authored out.
        (0.0, CAPTURED_SLIDE_OUT_YAW_RESPONSE_SECONDS)
    } else {
        let candidate = sim.candidate_slide_weight;
        (
            rolling_target + (slide_target - rolling_target) * candidate,
            CARVE_YAW_RESPONSE_SECONDS
                + (CAPTURED_SLIDE_YAW_RESPONSE_SECONDS - CARVE_YAW_RESPONSE_SECONDS) * candidate,
        )
    };

    let response = 1.0 - (-dt / response_seconds).exp();
    sim.yaw_rate += (target_yaw_rate - sim.yaw_rate) * response;

    let turn_delta = sim.yaw_rate * dt;
    sim.yaw += turn_delta;
    if powersliding {
        sim.powerslide_rotation += turn_delta.abs();
        if let Some(slide) = sim.slide.as_mut() {
            slide.rotation += turn_delta.abs();
        }
    }
}

fn step_airborne_body_spin(sim: &mut SkateSim, dt: f32) {
    let spin_input = -sim.left_stick.x;
    if spin_input.abs() > BODY_SPIN_INPUT_DEADZONE {
        sim.airborne_body_spin_input_observed = true;
    }
    let full_stick_pop_speed = sim.pop_motion.as_ref().and_then(|motion| {
        let airborne_duration = motion.touchdown_seconds - motion.first_air_seconds;
        (spin_input.abs() >= 1.0 - f32::EPSILON && airborne_duration > f32::EPSILON).then(|| {
            // The captured rate at sample N is the interval ending at N.
            // Advance one retail sample so fixed-step integration consumes
            // the same right-endpoint rate instead of lagging the oracle by
            // one 60 Hz poll.
            let phase = ((motion.elapsed_since_flick_seconds - motion.first_air_seconds)
                / airborne_duration
                + 1.0 / 57.0)
                .clamp(0.0, 1.0);
            spin_input.signum() * sample_ollie_held_body_spin_speed(phase, spin_input)
        })
    });
    if let Some(retail_speed) = full_stick_pop_speed {
        sim.body_spin_velocity = retail_speed;
    } else if spin_input.abs() > BODY_SPIN_INPUT_DEADZONE {
        sim.body_spin_velocity += (spin_input * BODY_SPIN_ACCELERATION
            - BODY_SPIN_INPUT_DAMPING * sim.body_spin_velocity)
            * dt;
        sim.body_spin_velocity = sim
            .body_spin_velocity
            .clamp(-BODY_SPIN_MAXIMUM_SPEED, BODY_SPIN_MAXIMUM_SPEED);
    } else {
        sim.body_spin_velocity = move_towards(
            sim.body_spin_velocity,
            0.0,
            BODY_SPIN_RELEASE_DECELERATION * dt,
        );
    }

    let spin_delta = sim.body_spin_velocity * dt;
    sim.yaw += spin_delta;
    sim.yaw_rate = sim.body_spin_velocity;
    sim.body_spin_angle += spin_delta;
    sim.body_spin_animation_phase_seconds = (sim.body_spin_animation_phase_seconds
        + spin_delta.abs() / std::f32::consts::TAU * BODY_SPIN_CLIP_DURATION_SECONDS)
        .rem_euclid(BODY_SPIN_CLIP_DURATION_SECONDS);
}

fn step_view_heading(sim: &mut SkateSim, pop_spin_window: bool) {
    // Retail keeps the chase-camera heading owned by the takeoff direction
    // from flick through touchdown while PhysBodySpin rotates the skater and
    // board underneath it. Grounded riding resumes the existing
    // heading-follow behavior.
    if pop_spin_window {
        return;
    }

    // Board/skater yaw and travel heading deliberately diverge after a 180.
    // Retail's fakie provider keeps those concepts separate; chasing raw
    // board yaw here makes the camera orbit to the direction the deck faces
    // instead of remaining behind the direction of travel.
    let logical_facing_yaw = sim.yaw + sim.fakie.logical_facing_yaw_offset;
    let speed_squared = sim.velocity.x * sim.velocity.x + sim.velocity.z * sim.velocity.z;
    let target_heading = if sim.fakie.is_riding_fakie() && speed_squared > f32::EPSILON {
        sim.velocity.x.atan2(sim.velocity.z)
    } else {
        logical_facing_yaw
    };

    if let Some(motion) = sim.pop_motion.as_ref()
        && motion.touched_down
    {
        let elapsed_since_touchdown =
            (motion.elapsed_since_flick_seconds - motion.touchdown_seconds).max(0.0);
        if elapsed_since_touchdown < HIGH_CAMERA_LOW_OLLIE_TRANSITION_OUT_SECONDS {
            let transition_weight =
                elapsed_since_touchdown / HIGH_CAMERA_LOW_OLLIE_TRANSITION_OUT_SECONDS;
            sim.view_yaw = lerp_angle(motion.takeoff_view_yaw, target_heading, transition_weight);
            return;
        }
    }

    sim.view_yaw = target_heading;
}

fn riding_fakie_motion_eligible(board_authority: BoardAuthority) -> bool {
    matches!(
        board_authority,
        BoardAuthority::Physics | BoardAuthority::Animation
    )
}

fn wrap_angle(angle: f32) -> f32 {
    (angle + std::f32::consts::PI).rem_euclid(std::f32::consts::TAU) - std::f32::consts::PI
}

fn lerp_angle(current: f32, target: f32, weight: f32) -> f32 {
    current + wrap_angle(target - current) * weight.clamp(0.0, 1.0)
}

fn step_velocity(
    sim: &mut SkateSim,
    dt: f32,
    powersliding: bool,
    brake_held: bool,
    touchdown_this_step: bool,
) {
    let contact = if sim.ground_contact_valid {
        if sim.manual.is_some() && sim.deck_pitch.abs() > f32::EPSILON {
            BoardContactState {
                touching_wheels: 2,
                deck_touching: sim.manual_deck_contact.touching,
                surface_id: sim.ground_surface_id,
            }
        } else {
            BoardContactState::four_wheels(sim.ground_surface_id)
        }
    } else {
        BoardContactState::airborne()
    };
    let velocity_before = sim.velocity;
    let result = integrate_contact_friction(ContactFrictionInput {
        velocity: sim.velocity,
        board_yaw: sim.yaw,
        fixed_delta_seconds: dt,
        contact,
        touchdown_this_step,
        powersliding,
        braking: sim.brake_active && brake_held,
        maximum_speed: MAX_SPEED,
    });
    sim.velocity = apply_manual_deck_drag(result.velocity, dt, &mut sim.manual_deck_contact);
    sim.planar_acceleration = (sim.velocity - velocity_before) / dt;
    sim.lateral_friction_rate = result.lateral_rate;
    sim.last_contact_friction = result;
    sim.position.x += sim.velocity.x * dt;
    sim.position.z += sim.velocity.z * dt;
    let (forward, _) = board_basis(sim.yaw);
    let rolling_distance = sim.velocity.dot(forward) * dt;
    sim.wheel_spin =
        (sim.wheel_spin - rolling_distance / WHEEL_RADIUS).rem_euclid(std::f32::consts::TAU);
}

fn step_airborne_planar_motion(sim: &mut SkateSim, dt: f32) {
    let response = integrate_contact_friction(ContactFrictionInput {
        velocity: sim.velocity,
        board_yaw: sim.yaw,
        fixed_delta_seconds: dt,
        contact: BoardContactState::airborne(),
        touchdown_this_step: false,
        powersliding: false,
        braking: false,
        maximum_speed: MAX_SPEED,
    });
    sim.planar_acceleration = response.acceleration;
    sim.lateral_friction_rate = response.lateral_rate;
    sim.last_contact_friction = response;
    sim.position.x += sim.velocity.x * dt;
    sim.position.z += sim.velocity.z * dt;
}

/// Advances the evidence-backed Ollie animation/provider clocks while the
/// transition test's provisional physical carrier owns world motion.
///
/// Unlike the flat fixture, transition touchdown is collision-driven. The
/// measured flat-ground touchdown frame remains an animation timing input but
/// cannot force the board onto a ramp or deck that it has not reached.
fn advance_transition_pop_motion(sim: &mut SkateSim, _dt: f32) -> Option<f32> {
    let mut launch_speed = None;
    let mut recovery_finished = false;
    {
        let Some(motion) = sim.pop_motion.as_mut() else {
            return None;
        };
        motion.fixed_steps_since_flick = motion.fixed_steps_since_flick.saturating_add(1);
        motion.elapsed_since_flick_seconds =
            f32::from(motion.fixed_steps_since_flick) / FIXED_HZ as f32;
        let carrier =
            retail_released_carrier(motion.charge_seconds, motion.elapsed_since_flick_seconds);
        motion.board_height = carrier.board_height;
        motion.skater_height = carrier.skater_height;

        let first_air_step = (motion.first_air_seconds * FIXED_HZ as f32).round() as u16;
        if !motion.separated_from_ground && motion.fixed_steps_since_flick >= first_air_step {
            motion.separated_from_ground = true;
            launch_speed = Some(motion.launch_speed);
            sim.landing_average_velocity_y = 0.0;
        }

        if motion.touched_down {
            let touchdown = motion
                .transition_touchdown_seconds
                .unwrap_or(motion.touchdown_seconds);
            let recovered_tail = (motion.recovery_end_seconds - motion.touchdown_seconds).max(0.0);
            recovery_finished = motion.elapsed_since_flick_seconds >= touchdown + recovered_tail;
        }
    }

    if recovery_finished {
        sim.pop_motion = None;
    }
    launch_speed
}

fn step_retail_pop_carrier(sim: &mut SkateSim, dt: f32) {
    let (
        previous_collision_resolved_board_height,
        collision_resolved_board_height,
        first_air_seconds,
        touchdown_seconds,
        recovery_end_seconds,
        newly_separated,
        newly_touched_down,
        recovery_finished,
    ) = {
        let motion = sim
            .pop_motion
            .as_mut()
            .expect("the retail carrier is stepped only while active");
        let previous_board_height = motion.board_height;
        motion.fixed_steps_since_flick = motion.fixed_steps_since_flick.saturating_add(1);
        motion.elapsed_since_flick_seconds =
            f32::from(motion.fixed_steps_since_flick) / FIXED_HZ as f32;
        let carrier =
            retail_released_carrier(motion.charge_seconds, motion.elapsed_since_flick_seconds);
        motion.board_height = carrier.board_height;
        motion.skater_height = carrier.skater_height;
        let first_air_step = (motion.first_air_seconds * FIXED_HZ as f32).round() as u16;
        let touchdown_step = (motion.touchdown_seconds * FIXED_HZ as f32).round() as u16;
        let recovery_end_step = (motion.recovery_end_seconds * FIXED_HZ as f32).round() as u16;
        let newly_separated =
            !motion.separated_from_ground && motion.fixed_steps_since_flick >= first_air_step;
        if newly_separated {
            motion.separated_from_ground = true;
        }
        let newly_touched_down =
            !motion.touched_down && motion.fixed_steps_since_flick >= touchdown_step;
        if newly_touched_down {
            motion.touched_down = true;
        }
        // The isolated provider reports an unconstrained carrier, including
        // tiny pre-contact noise and a large negative post-contact recovery.
        // The synchronized native skeleton capture proves that collision
        // resolution holds SKATEBOARD_ROOT at its settled plane. Preserve the
        // raw channel in PopMotion for telemetry while preventing the
        // physical/render root from following it underground.
        let previous_collision_resolved_board_height = previous_board_height.max(0.0);
        let collision_resolved_board_height = motion.board_height.max(0.0);
        (
            previous_collision_resolved_board_height,
            collision_resolved_board_height,
            motion.first_air_seconds,
            motion.touchdown_seconds,
            motion.recovery_end_seconds,
            newly_separated,
            newly_touched_down,
            motion.fixed_steps_since_flick >= recovery_end_step,
        )
    };

    sim.position.y = sim
        .pop_motion
        .as_ref()
        .expect("the retail carrier remains active during this step")
        .ground_height
        + collision_resolved_board_height;
    sim.velocity.y =
        (collision_resolved_board_height - previous_collision_resolved_board_height) / dt;
    if newly_separated {
        sim.landing_average_velocity_y = 0.0;
    }
    if newly_touched_down {
        sim.landing_average_velocity_y = sim
            .pop_motion
            .as_ref()
            .expect("touchdown occurs with an active retail carrier")
            .retail_projection_touchdown_velocity_y;
        sim.landed_this_step = true;
    }

    // Keep the measured post-contact board/skater recovery alive after the
    // graph enters BLEND_LAND. It converges to the settled baseline before
    // returning transform ownership to the normal riding systems.
    if recovery_finished {
        let ground_height = sim
            .pop_motion
            .as_ref()
            .expect("recovery completion occurs with an active carrier")
            .ground_height;
        sim.position.y = ground_height;
        sim.velocity.y = 0.0;
        sim.pop_motion = None;
    }

    debug_assert!(first_air_seconds <= touchdown_seconds);
    debug_assert!(touchdown_seconds <= recovery_end_seconds);
}

fn step_random_idle(sim: &mut SkateSim, dt: f32, active_input: bool) {
    let eligible = !active_input && sim.speed() < 0.1;
    if !eligible {
        sim.idle_no_input_time = 0.0;
        if sim.random_idle.take().is_some() {
            sim.set_animation(None, false, 0.2, false);
        }
        return;
    }

    if let Some(idle) = sim.random_idle.as_mut() {
        idle.phase_time += dt;
        if idle.phase_time >= idle.phase_duration {
            sim.random_idle = None;
            sim.idle_no_input_time = 0.0;
            sim.set_animation(None, false, 0.2, false);
        }
        return;
    }

    sim.idle_no_input_time += dt;
    if sim.idle_no_input_time >= RANDOM_IDLE_DELAY_SECONDS {
        sim.random_idle_counter = sim.random_idle_counter.wrapping_add(1);
        let variant = if sim.random_idle_counter % 2 == 1 {
            1
        } else {
            2
        };
        sim.random_idle = Some(RandomIdleRuntime::new(variant));
        sim.idle_no_input_time = 0.0;
        sim.set_animation_from_random_idle();
    }
}

fn push_action_weight(push: &PushRuntime) -> f32 {
    match push.phase {
        PushPhase::Into => transition_in_weight(push.phase_time, 0.3),
        PushPhase::Contact | PushPhase::Cycle | PushPhase::Out => 1.0,
    }
}

fn transition_in_weight(time: f32, duration: f32) -> f32 {
    if duration > 0.0 {
        (time / duration).clamp(0.0, 1.0)
    } else {
        1.0
    }
}

fn transition_out_weight(time: f32, duration: f32) -> f32 {
    1.0 - transition_in_weight(time, duration)
}

fn push_attributes(foot: PushFoot) -> PushAttributes {
    match foot {
        // B_MONGO_PUSH uses the MONGO_0 leaves and B_PUSH uses the N/LEFT/RIGHT
        // leaves. This is the same family mapping used by `clip_for`.
        PushFoot::Regular => MONGO_PUSH_ATTRIBUTES,
        PushFoot::Mongo => REGULAR_PUSH_ATTRIBUTES,
    }
}

fn source_clip_duration(sample_count: u32, sample_rate: f32) -> f32 {
    sample_count.saturating_sub(1) as f32 / sample_rate
}

fn sample_piecewise_curve(points: &[(f32, f32)], x: f32) -> f32 {
    let x = x.clamp(0.0, 1.0);
    sample_retail_point_graph(points, x)
}

fn sample_retail_point_graph(points: &[(f32, f32)], x: f32) -> f32 {
    if let Some(&(first_x, first_y)) = points.first() {
        if x <= first_x {
            return first_y;
        }
    }
    for pair in points.windows(2) {
        let (x0, y0) = pair[0];
        let (x1, y1) = pair[1];
        if x <= x1 {
            let t = if x1 > x0 { (x - x0) / (x1 - x0) } else { 0.0 };
            return y0 + (y1 - y0) * t;
        }
    }
    points.last().map_or(0.0, |(_, y)| *y)
}

fn can_enter_powerslide(stick: Vec2, speed: f32, contact_valid: bool) -> bool {
    contact_valid && candidate_slide_weight(stick, speed) >= 1.0 - f32::EPSILON
}

fn slide_out_for_rotation(rotation: f32) -> SlideOut {
    let degrees = rotation.to_degrees().rem_euclid(360.0);
    let folded = if degrees > 180.0 {
        360.0 - degrees
    } else {
        degrees
    };
    if folded < 45.0 {
        SlideOut::Angle000
    } else if folded < 135.0 {
        SlideOut::Angle090
    } else {
        SlideOut::Angle180
    }
}

fn brake_phase_duration(phase: BrakePhase) -> f32 {
    let (frames, will_expire) = match phase {
        BrakePhase::MovingInto => (7.0, SEQUENCE_WILL_EXPIRE_SECONDS),
        BrakePhase::MovingCycle => (20.0, 0.0),
        BrakePhase::MovingOut => (16.0, BRAKE_OUT_WILL_EXPIRE_SECONDS),
        BrakePhase::StandInto => (18.0, SEQUENCE_WILL_EXPIRE_SECONDS),
        BrakePhase::StandFromMoving => (23.0, BRAKE_OUT_WILL_EXPIRE_SECONDS),
        BrakePhase::StandCycle => (60.0, 0.0),
        BrakePhase::StandOut => (18.0, BRAKE_OUT_WILL_EXPIRE_SECONDS),
    };
    ((frames - 1.0) / RETAIL_SLIDE_BRAKE_ANIMATION_HZ - will_expire).max(1.0 / FIXED_HZ as f32)
}

fn slide_source_clip_frames(side: SlideSide, speed: SpeedBand, phase: SlidePhase) -> u32 {
    match (side, speed, phase) {
        (_, _, SlidePhase::Into) => 23,
        (_, _, SlidePhase::Cycle) => 48,
        (SlideSide::Frontside, SpeedBand::High, SlidePhase::Out(SlideOut::Angle000)) => 20,
        (SlideSide::Frontside, SpeedBand::High, SlidePhase::Out(SlideOut::Angle090)) => 13,
        (SlideSide::Frontside, SpeedBand::High, SlidePhase::Out(SlideOut::Angle180)) => 18,
        (SlideSide::Frontside, SpeedBand::Low, SlidePhase::Out(SlideOut::Angle000)) => 17,
        (SlideSide::Frontside, SpeedBand::Low, SlidePhase::Out(SlideOut::Angle090)) => 13,
        (SlideSide::Frontside, SpeedBand::Low, SlidePhase::Out(SlideOut::Angle180)) => 18,
        (SlideSide::Backside, SpeedBand::High, SlidePhase::Out(SlideOut::Angle000)) => 13,
        (SlideSide::Backside, SpeedBand::High, SlidePhase::Out(SlideOut::Angle090)) => 23,
        (SlideSide::Backside, SpeedBand::High, SlidePhase::Out(SlideOut::Angle180)) => 14,
        (SlideSide::Backside, SpeedBand::Low, SlidePhase::Out(SlideOut::Angle000)) => 13,
        (SlideSide::Backside, SpeedBand::Low, SlidePhase::Out(SlideOut::Angle090)) => 13,
        (SlideSide::Backside, SpeedBand::Low, SlidePhase::Out(SlideOut::Angle180)) => 17,
    }
}

fn direction_band(steer: f32) -> PushDirection {
    if steer < -0.33 {
        PushDirection::Left
    } else if steer > 0.33 {
        PushDirection::Right
    } else {
        PushDirection::Neutral
    }
}

fn push_source_clip_frames(name: &str) -> u32 {
    if name.ends_with("_OUT_MIDFRONT") {
        return if name.starts_with("R_PUSH_H_M") {
            19
        } else {
            21
        };
    }
    if name.contains("LSP_LSTR") && name.ends_with("_INTO") {
        if name.contains("MONGO") {
            31
        } else if name.contains("LEFT") || name.contains("RIGHT") {
            39
        } else {
            11
        }
    } else if name.contains("LSP_LSTR") && name.ends_with("_CYC1") {
        if name.contains("MONGO") {
            11
        } else if name.contains("LEFT") || name.contains("RIGHT") {
            9
        } else {
            15
        }
    } else if name.contains("LSP_LSTR") && name.ends_with("_CYC2") {
        if name.contains("MONGO") {
            42
        } else if name.contains("LEFT") || name.contains("RIGHT") {
            45
        } else {
            27
        }
    } else if name.contains("LSP_HSTR") && name.ends_with("_INTO") {
        if name.contains("MONGO") { 33 } else { 41 }
    } else if name.contains("LSP_HSTR") && name.ends_with("_CYC1") {
        if name.contains("MONGO") { 9 } else { 13 }
    } else if name.contains("LSP_HSTR") && name.ends_with("_CYC2") {
        55
    } else if name.contains("HSP_LSTR") && name.ends_with("_INTO") {
        if name.contains("MONGO") { 33 } else { 35 }
    } else if name.contains("HSP_LSTR") && name.ends_with("_CYC1") {
        if name.contains("MONGO") { 5 } else { 4 }
    } else if name.contains("HSP_LSTR") && name.ends_with("_CYC2") {
        if name.contains("MONGO") { 59 } else { 60 }
    } else if name.contains("HSP_HSTR") && name.ends_with("_INTO") {
        if name.contains("MONGO") {
            43
        } else if name.contains("LEFT") || name.contains("RIGHT") {
            35
        } else {
            32
        }
    } else if name.contains("HSP_HSTR") && name.ends_with("_CYC1") {
        5
    } else if name.contains("HSP_HSTR") && name.ends_with("_CYC2") {
        56
    } else {
        30
    }
}

fn remap_radial_deadzone(value: Vec2, deadzone: f32) -> Vec2 {
    let magnitude = value.length();
    if magnitude <= deadzone {
        Vec2::ZERO
    } else {
        value / magnitude * ((magnitude - deadzone) / (1.0 - deadzone)).clamp(0.0, 1.0)
    }
}

fn remap_retail_right_stick(value: Vec2) -> Vec2 {
    let magnitude = value.length();
    if magnitude < RETAIL_RIGHT_STICK_DIVIDE_GUARD {
        return Vec2::ZERO;
    }
    let scale = ((magnitude - RETAIL_RIGHT_STICK_DEADZONE) * RETAIL_RIGHT_STICK_REMAP_GAIN)
        .clamp(0.0, 1.0)
        / magnitude;
    value * scale
}

fn is_vjoy_name(name: &str) -> bool {
    name.to_ascii_lowercase().contains("vjoy")
}

#[derive(Default)]
pub(crate) struct XInputCache {
    previous_buttons: [u16; 4],
    connected_mask: u8,
}

struct XInputSample {
    name: String,
    left_stick: Vec2,
    canonical_pad: CanonicalPadState,
    regular_held: bool,
    regular_just_pressed: bool,
    mongo_held: bool,
    mongo_just_pressed: bool,
    brake_held: bool,
    toggle_held: bool,
    toggle_just_pressed: bool,
    reset_just_pressed: bool,
}

#[cfg(target_os = "windows")]
fn poll_xinput(cache: &mut XInputCache) -> Vec<XInputSample> {
    const XINPUT_GAMEPAD_START: u16 = 0x0010;
    const XINPUT_GAMEPAD_A: u16 = 0x1000;
    const XINPUT_GAMEPAD_B: u16 = 0x2000;
    const XINPUT_GAMEPAD_X: u16 = 0x4000;
    const XINPUT_GAMEPAD_Y: u16 = 0x8000;
    const XINPUT_LEFT_THUMB_DEADZONE: f32 = 7_849.0 / 32_767.0;

    let Some(xinput_get_state) = xinput_get_state() else {
        return Vec::new();
    };
    let mut samples = Vec::new();
    let mut connected_mask = 0_u8;
    let mut next_buttons = [0_u16; 4];
    for user_index in 0..4_u32 {
        let mut state = XInputState::default();
        // XInputGetState only writes the caller-owned POD state and returns a
        // Win32 error code. Slot polling is the documented XInput discovery
        // path and has no process-global side effects.
        let result = unsafe { xinput_get_state(user_index, &mut state) };
        if result != 0 {
            continue;
        }

        let slot = user_index as usize;
        connected_mask |= 1 << slot;
        next_buttons[slot] = state.gamepad.buttons;
        let previous = cache.previous_buttons[slot];
        let current = state.gamepad.buttons;
        let raw_stick = Vec2::new(
            normalize_thumb_axis(state.gamepad.thumb_lx),
            normalize_thumb_axis(state.gamepad.thumb_ly),
        );
        samples.push(XInputSample {
            name: format!("XInput controller {}", user_index + 1),
            left_stick: remap_radial_deadzone(raw_stick, XINPUT_LEFT_THUMB_DEADZONE),
            canonical_pad: CanonicalPadState {
                buttons: current,
                left_trigger: state.gamepad.left_trigger,
                right_trigger: state.gamepad.right_trigger,
                left_x: state.gamepad.thumb_lx,
                left_y: state.gamepad.thumb_ly,
                right_x: state.gamepad.thumb_rx,
                right_y: state.gamepad.thumb_ry,
            },
            regular_held: current & XINPUT_GAMEPAD_A != 0,
            regular_just_pressed: button_just_pressed(previous, current, XINPUT_GAMEPAD_A),
            mongo_held: current & XINPUT_GAMEPAD_X != 0,
            mongo_just_pressed: button_just_pressed(previous, current, XINPUT_GAMEPAD_X),
            brake_held: current & XINPUT_GAMEPAD_B != 0,
            toggle_held: current & XINPUT_GAMEPAD_Y != 0,
            toggle_just_pressed: button_just_pressed(previous, current, XINPUT_GAMEPAD_Y),
            reset_just_pressed: button_just_pressed(previous, current, XINPUT_GAMEPAD_START),
        });
    }

    if connected_mask != cache.connected_mask {
        info!(
            "XINPUT_INVENTORY connected_mask=0b{:04b} controllers={}",
            connected_mask,
            connected_mask.count_ones()
        );
    }
    cache.connected_mask = connected_mask;
    cache.previous_buttons = next_buttons;
    samples
}

#[cfg(not(target_os = "windows"))]
fn poll_xinput(_cache: &mut XInputCache) -> Vec<XInputSample> {
    Vec::new()
}

fn normalize_thumb_axis(value: i16) -> f32 {
    if value >= 0 {
        value as f32 / i16::MAX as f32
    } else {
        value as f32 / -(i16::MIN as f32)
    }
}

pub(crate) fn normalized_axis_to_i16(value: f32) -> i16 {
    let value = value.clamp(-1.0, 1.0);
    if value >= 0.0 {
        (value * i16::MAX as f32).round() as i16
    } else {
        (value * -(i16::MIN as f32)).round() as i16
    }
}

fn normalized_trigger_to_u8(value: f32) -> u8 {
    (value.clamp(0.0, 1.0) * u8::MAX as f32).round() as u8
}

pub(crate) fn canonical_axis_to_normalized(value: i16) -> f32 {
    normalize_thumb_axis(value)
}

fn button_just_pressed(previous: u16, current: u16, mask: u16) -> bool {
    previous & mask == 0 && current & mask != 0
}

#[cfg(target_os = "windows")]
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct XInputGamepad {
    buttons: u16,
    left_trigger: u8,
    right_trigger: u8,
    thumb_lx: i16,
    thumb_ly: i16,
    thumb_rx: i16,
    thumb_ry: i16,
}

#[cfg(target_os = "windows")]
#[repr(C)]
#[derive(Clone, Copy, Default)]
struct XInputState {
    packet_number: u32,
    gamepad: XInputGamepad,
}

#[cfg(target_os = "windows")]
type XInputGetStateFn = unsafe extern "system" fn(user_index: u32, state: *mut XInputState) -> u32;

#[cfg(target_os = "windows")]
fn xinput_get_state() -> Option<XInputGetStateFn> {
    use std::sync::OnceLock;

    static FUNCTION: OnceLock<Option<XInputGetStateFn>> = OnceLock::new();
    *FUNCTION.get_or_init(|| {
        for library_name in ["xinput1_4.dll", "xinput1_3.dll", "xinput9_1_0.dll"] {
            // The loaded module is intentionally retained for the process
            // lifetime because the returned function pointer belongs to it.
            let Ok(library) = (unsafe { libloading::Library::new(library_name) }) else {
                continue;
            };
            let function = unsafe {
                library
                    .get::<XInputGetStateFn>(b"XInputGetState\0")
                    .ok()
                    .map(|symbol| *symbol)
            };
            if let Some(function) = function {
                std::mem::forget(library);
                info!("XINPUT_BACKEND loaded={library_name}");
                return Some(function);
            }
        }
        warn!("XINPUT_BACKEND unavailable");
        None
    })
}

fn move_towards(current: f32, target: f32, maximum_delta: f32) -> f32 {
    let delta = target - current;
    if delta.abs() <= maximum_delta {
        target
    } else {
        current + delta.signum() * maximum_delta
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::air_trick_graph::{AirTrickFamily, PopEnd};
    use crate::foot_placement::{
        CompactTargetSample, ContactOwnership, Foot, FootPair, IkWeight, ObservedSkeletonIkPart,
        OnboardMotion, RawSkeletonIkMode, TargetMatrix,
    };
    use crate::grind_chromosome::{Alignment, Approach, BoardEnd, ContactFamily, Height, Travel};
    use crate::riding_forces::{RetailVec4, SkateboardForceType, UnresolvedBodyTiltInput};
    use crate::skateboard_body::{BodyId, WheelId};
    use crate::skateboard_solver::{PeerChannelEffect, Required as SolverRequired};
    use crate::trick_catalog::{LandingPosture, LandingVariant};

    const DT: f32 = 1.0 / FIXED_HZ as f32;

    fn grab_pad(left: bool, right: bool) -> CanonicalPadState {
        CanonicalPadState {
            left_trigger: if left { u8::MAX } else { 0 },
            right_trigger: if right { u8::MAX } else { 0 },
            ..default()
        }
    }

    fn tick_grab(sim: &mut SkateSim, left: bool, right: bool, ticks: usize) {
        for _ in 0..ticks {
            step_basic_grab_controls(sim, grab_pad(left, right), DT);
        }
    }

    fn tick_grab_pad(sim: &mut SkateSim, pad: CanonicalPadState, ticks: usize) {
        for _ in 0..ticks {
            step_basic_grab_controls(sim, pad, DT);
        }
    }

    fn transition_fixed_step_app(sim: SkateSim) -> App {
        let mut app = App::new();
        app.insert_resource(sim)
            .init_resource::<SkateInput>()
            .insert_resource(SkateGround::transition_test())
            .add_systems(Update, fixed_step);
        app
    }

    #[test]
    fn retail_right_stick_dead_zone_and_gain_match_recovered_constants() {
        assert_eq!(remap_retail_right_stick(Vec2::new(0.0, 0.25)), Vec2::ZERO);
        let just_live = remap_retail_right_stick(Vec2::new(0.0, 0.250_1));
        assert!(just_live.y > 0.0);
        let saturated = remap_retail_right_stick(Vec2::new(0.0, 0.95));
        assert!((saturated.y - 1.0).abs() < 1.0e-6);
    }

    #[test]
    fn canonical_input_boundary_queues_only_right_stick_state_changes() {
        let first = CanonicalPadState {
            right_x: -7_702,
            right_y: 29_554,
            ..default()
        };
        let second = CanonicalPadState {
            right_x: 11_620,
            right_y: -28_423,
            ..default()
        };
        let mut input = SkateInput::default();

        input.observe_canonical_pad(first);
        input.observe_canonical_pad(first);
        input.observe_canonical_pad(second);

        assert_eq!(
            input
                .right_stick_notifications
                .into_iter()
                .collect::<Vec<_>>(),
            vec![first, second]
        );
    }

    #[test]
    fn flickit_bridge_uses_retail_preprocessing_without_publishing_a_guess() {
        let mut bridge = TrickInputBridge::default();
        let pad = CanonicalPadState {
            right_x: i16::MAX,
            right_y: 0,
            ..default()
        };
        bridge.step_probe(pad, MirrorState::Unmirrored);
        assert_eq!(bridge.probe_sample_count, 0);
        bridge.step_probe(pad, MirrorState::Unmirrored);
        assert_eq!(bridge.probe_sample_count, 1);
        assert!((bridge.processed_sample().x - 1.0).abs() < 1.0e-6);
        assert_eq!(bridge.processed_sample().y, 0.0);
        assert_eq!(bridge.selected_contact_label(), "none");
        assert!(matches!(
            bridge.publication_status_label(),
            "no_geometry_candidate" | "blocked_pattern_node_timing_and_arbitration"
        ));
    }

    #[test]
    fn flickit_retail_notification_path_publishes_the_recovered_stable_winner() {
        let mut bridge = TrickInputBridge::default();
        let first = CanonicalPadState {
            right_x: 0,
            right_y: i16::MIN,
            ..default()
        };
        let second = CanonicalPadState {
            right_x: 0,
            right_y: i16::MAX,
            ..default()
        };
        assert!(
            bridge
                .observe_retail_notification(first, MirrorState::Unmirrored, MatcherMode::Default)
                .winner
                .is_none()
        );
        let frame = bridge.observe_retail_notification(
            second,
            MirrorState::Unmirrored,
            MatcherMode::Default,
        );
        assert_eq!(
            frame.winner.as_ref().map(|(_, name)| name.as_str()),
            Some("Ollie")
        );
        assert_eq!(bridge.retail_notification_count, 2);
        assert_eq!(
            bridge.retail_cadence_label(),
            "notification_driven_0x82859E70"
        );
    }

    #[test]
    fn starting_a_push_discards_an_incomplete_flickit_gesture() {
        let mut sim = SkateSim::default();
        let nose = CanonicalPadState {
            right_y: i16::MAX,
            ..default()
        };
        let neutral = CanonicalPadState::default();
        let tail = CanonicalPadState {
            right_y: i16::MIN,
            ..default()
        };

        assert!(
            sim.trick_input
                .observe_retail_notification(nose, MirrorState::Unmirrored, MatcherMode::Default,)
                .winner
                .is_none()
        );
        assert!(
            sim.trick_input
                .observe_retail_notification(
                    neutral,
                    MirrorState::Unmirrored,
                    MatcherMode::Default,
                )
                .winner
                .is_none()
        );

        request_push(&mut sim, PushFoot::Regular);

        let post_push = sim.trick_input.observe_retail_notification(
            tail,
            MirrorState::Unmirrored,
            MatcherMode::Default,
        );
        assert!(
            post_push.winner.is_none(),
            "a new tail press must not complete the pre-push nose gesture"
        );
        let fresh_release = sim.trick_input.observe_retail_notification(
            nose,
            MirrorState::Unmirrored,
            MatcherMode::Default,
        );
        assert_eq!(
            fresh_release.winner.as_ref().map(|(_, name)| name.as_str()),
            Some("Ollie"),
            "a complete gesture made after the push boundary must still publish"
        );
    }

    #[test]
    fn toolkit_kickflip_sequence_uses_raw_down_then_up_right() {
        let mut bridge = TrickInputBridge::default();
        let tail_antic = CanonicalPadState {
            right_x: 0,
            right_y: i16::MIN,
            ..default()
        };
        let up_right = CanonicalPadState {
            right_x: i16::MAX,
            right_y: i16::MAX,
            ..default()
        };
        assert!(
            bridge
                .observe_retail_notification(
                    tail_antic,
                    MirrorState::Unmirrored,
                    MatcherMode::Default
                )
                .winner
                .is_none()
        );
        let frame = bridge.observe_retail_notification(
            up_right,
            MirrorState::Unmirrored,
            MatcherMode::Default,
        );
        assert_eq!(
            frame.winner.as_ref().map(|(_, name)| name.as_str()),
            Some("Kickflip")
        );
    }

    #[test]
    fn synchronized_flip360_path_survives_multi_pattern_arbitration() {
        let mut bridge = TrickInputBridge::default();
        let points = [
            (-31_644, -8_801),
            (-16_290, -27_524),
            // This remains inside 360Flip's 0.4 tolerance while avoiding an
            // earlier three-point 90_PopShuvit completion.
            (-5_898, -32_112),
            (29_772, 13_294),
        ];
        for (index, (right_x, right_y)) in points.into_iter().enumerate() {
            let frame = bridge.observe_retail_notification(
                CanonicalPadState {
                    right_x,
                    right_y,
                    ..default()
                },
                MirrorState::Unmirrored,
                MatcherMode::Default,
            );
            if index + 1 < points.len() {
                assert!(frame.winner.is_none(), "winner published at point {index}");
            } else {
                assert_eq!(
                    frame.winner.as_ref().map(|(_, name)| name.as_str()),
                    Some("360Flip")
                );
            }
        }
    }

    #[test]
    fn every_primary_single_rotation_flickit_path_wins_retail_arbitration() {
        let database = crate::trick_input::RetailPatternDatabase::load_embedded().unwrap();
        let skater = database
            .files
            .iter()
            .find(|file| file.source == crate::trick_input::PatternSource::Skater)
            .unwrap();

        for (expected, _) in SINGLE_ROTATION_FLICKIT_TRICKS {
            let pattern = skater
                .patterns
                .iter()
                .find(|pattern| pattern.name == expected)
                .unwrap_or_else(|| panic!("skater.pat has no primary {expected} pattern"));
            let mut coordinates = pattern
                .coordinates
                .iter()
                .map(|coordinate| coordinate.position)
                .collect::<Vec<_>>();
            // Four-node gestures can geometrically complete a shorter rotated
            // shuv node at their third notification. These interior points
            // remain inside the authored 0.4 target tolerance while avoiding
            // that earlier completion in a discrete deterministic fixture.
            if coordinates.len() == 4 {
                coordinates[2] = match expected {
                    "360Flip" => Stick2::new(-0.188_571, 0.988_571),
                    "Laserflip" => Stick2::new(0.24, 0.988_571),
                    "360Hardflip" => Stick2::new(0.23, 0.988_571),
                    "360InwardHeelflip" => Stick2::new(-0.248_571, 0.977_143),
                    "N_360Flip" => Stick2::new(-0.252_857, -0.977_143),
                    "N_Laserflip" => Stick2::new(0.111_429, -0.975_714),
                    "N_360Hardflip" => Stick2::new(0.2, -0.977_143),
                    "N_360InwardHeelflip" => Stick2::new(-0.065_714, -1.0),
                    _ => coordinates[2],
                };
                assert!(
                    coordinates[2].distance_squared(pattern.coordinates[2].position)
                        <= pattern.tolerance_squared
                );
            }
            let mut recognizer = TrickInputRecognizer::new().unwrap();
            let mut published = None;
            for coordinate in &coordinates {
                let frame = recognizer.observe_processed_retail(
                    *coordinate,
                    None,
                    MirrorState::Unmirrored,
                    MatcherMode::Default,
                );
                if let Some((_, name)) = frame.winner {
                    published = Some(name);
                }
            }
            assert_eq!(
                published.as_deref(),
                Some(expected),
                "deterministic primary path did not publish {expected}"
            );
        }
    }

    #[test]
    fn smooth_ground_flickit_paths_are_not_stolen_by_other_pattern_contexts() {
        let database = crate::trick_input::RetailPatternDatabase::load_embedded().unwrap();
        let skater = database
            .files
            .iter()
            .find(|file| file.source == crate::trick_input::PatternSource::Skater)
            .unwrap();
        let mut checked = 0;
        let mut checked_nollie = 0;

        for (expected, _) in SINGLE_ROTATION_FLICKIT_TRICKS {
            let pattern = skater
                .patterns
                .iter()
                .find(|pattern| pattern.name == expected)
                .unwrap_or_else(|| panic!("skater.pat has no primary {expected} pattern"));
            if pattern.coordinates.len() == 4 {
                // The four-node families have separately pinned interior
                // samples which avoid a valid shorter shuv completion.
                continue;
            }
            let mut samples = vec![pattern.coordinates[0].position];
            for coordinates in pattern.coordinates.windows(2) {
                for step in 1..=6 {
                    let weight = step as f32 / 6.0;
                    samples.push(Stick2::new(
                        coordinates[0].position.x
                            + (coordinates[1].position.x - coordinates[0].position.x) * weight,
                        coordinates[0].position.y
                            + (coordinates[1].position.y - coordinates[0].position.y) * weight,
                    ));
                }
            }

            let mut recognizer = TrickInputRecognizer::new().unwrap();
            let published = samples.into_iter().find_map(|sample| {
                recognizer
                    .observe_processed_retail(
                        sample,
                        None,
                        MirrorState::Unmirrored,
                        MatcherMode::Default,
                    )
                    .winner
                    .map(|(_, name)| name)
            });
            assert_eq!(
                published.as_deref(),
                Some(expected),
                "smooth primary path was stolen before {expected}"
            );
            checked += 1;
            checked_nollie += expected.starts_with("N_") as usize;
        }
        assert_eq!(checked, 16);
        assert_eq!(checked_nollie, 8);
    }

    #[test]
    fn every_single_rotation_winner_routes_to_physical_low_and_high_sequences() {
        use crate::air_trick_graph::ClipSegment;

        for (winner, expected_trick) in SINGLE_ROTATION_FLICKIT_TRICKS {
            assert_eq!(single_rotation_flickit_trick(winner), Some(expected_trick));
            let ground = flip_endpoint_pair(expected_trick, ClipSegment::Ground).unwrap();
            let air = flip_endpoint_pair(expected_trick, ClipSegment::Air).unwrap();
            for clip in [ground.low, ground.high, air.low, air.high] {
                assert!(
                    !clip.starts_with("B_"),
                    "{winner} resolved to virtual resource {clip}"
                );
            }
            assert!(ground.low_frames > 1);
            assert!(ground.high_frames > 1);
            assert!(air.low_frames > 1);
            assert!(air.high_frames > 1);

            let mut sim = SkateSim::default();
            sim.anticipation = Some(AnticipationRuntime::begin(match expected_trick.pop_end {
                PopEnd::Tail => AnticipationSide::Tail,
                PopEnd::Nose => AnticipationSide::Nose,
            }));
            assert!(begin_verified_endpoint_trick(&mut sim, winner));
            assert_eq!(
                sim.air_trick.as_ref().unwrap().runtime.trick,
                expected_trick
            );
            let state = sim.air_trick_animation_state().unwrap().unwrap();
            assert_eq!(state.samples[0].clip, ground.low);
        }
    }

    #[test]
    fn looping_flip_identities_use_their_retail_loop_router() {
        use crate::air_trick_graph::ClipSegment;

        let cases = [
            (
                "Kickflip",
                AirTrick::new(PopEnd::Tail, AirTrickFamily::Kickflip),
                [
                    "KICKFLIP_IN_LOW_G",
                    "KICKFLIP_IN_HIGH_G",
                    "KICKFLIP_IN_LOW_A",
                    "KICKFLIP_IN_HIGH_A",
                ],
            ),
            (
                "Heelflip",
                AirTrick::new(PopEnd::Tail, AirTrickFamily::Heelflip),
                [
                    "HEELFLIP_IN_LOW_G",
                    "HEELFLIP_IN_HIGH_G",
                    "HEELFLIP_IN_LOW_A",
                    "HEELFLIP_IN_HIGH_A",
                ],
            ),
            (
                "N_Kickflip",
                AirTrick::new(PopEnd::Nose, AirTrickFamily::Kickflip),
                [
                    "N_KICKFLIP_IN_LOW_G",
                    "N_KICKFLIP_IN_HIGH_G",
                    "N_KICKFLIP_IN_LOW_A",
                    "N_KICKFLIP_IN_HIGH_A",
                ],
            ),
            (
                "N_Heelflip",
                AirTrick::new(PopEnd::Nose, AirTrickFamily::Heelflip),
                [
                    "N_HEELFLIP_IN_LOW_G",
                    "N_HEELFLIP_IN_HIGH_G",
                    "N_HEELFLIP_IN_LOW_A",
                    "N_HEELFLIP_IN_HIGH_A",
                ],
            ),
        ];
        for (winner, expected_trick, expected_clips) in cases {
            assert_eq!(
                single_rotation_flickit_trick(winner),
                None,
                "{winner} must not fall through the one-shot router"
            );
            let ground = flip_endpoint_pair(expected_trick, ClipSegment::Ground).unwrap();
            let air = flip_endpoint_pair(expected_trick, ClipSegment::Air).unwrap();
            assert_eq!([ground.low, ground.high, air.low, air.high], expected_clips);
            assert!(
                expected_clips
                    .iter()
                    .all(|clip| !clip.starts_with("COMBINED_"))
            );
            let mut sim = SkateSim::default();
            assert!(begin_verified_endpoint_trick(&mut sim, winner));
            assert_eq!(
                sim.air_trick.as_ref().unwrap().runtime.trick,
                expected_trick
            );
            assert_eq!(
                sim.air_trick_animation_state().unwrap().unwrap().samples[0].clip,
                expected_clips[0]
            );
        }
    }

    #[test]
    fn all_flip_loop_families_resolve_every_cycle_and_out_to_physical_clips() {
        use crate::air_trick_graph::ClipSegment;

        let tricks = [
            AirTrick::new(PopEnd::Tail, AirTrickFamily::Kickflip),
            AirTrick::new(PopEnd::Tail, AirTrickFamily::Heelflip),
            AirTrick::new(PopEnd::Nose, AirTrickFamily::Kickflip),
            AirTrick::new(PopEnd::Nose, AirTrickFamily::Heelflip),
        ];
        for trick in tricks {
            for count in 1..=3 {
                let pair = flip_loop_endpoint_pair(trick, ClipSegment::FlipCycle(count)).unwrap();
                for clip in [pair.low, pair.high] {
                    assert!(
                        !clip.starts_with("B_"),
                        "{} cycle {count} resolved to virtual resource {clip}",
                        trick.intent_name()
                    );
                }
                assert!(pair.low_frames > 1);
                assert!(pair.high_frames > 1);
            }
            for count in 1..=4 {
                let pair = flip_loop_endpoint_pair(trick, ClipSegment::FlipOut(count)).unwrap();
                for clip in [pair.low, pair.high] {
                    assert!(
                        !clip.starts_with("B_"),
                        "{} out {count} resolved to virtual resource {clip}",
                        trick.intent_name()
                    );
                }
                assert!(pair.low_frames > 1);
                assert!(pair.high_frames > 1);
            }
        }
    }

    #[test]
    fn release_after_each_authored_hold_window_selects_single_through_quad_outs() {
        use crate::air_trick_graph::{ClipSegment, HandoffTarget};

        let tricks = [
            AirTrick::new(PopEnd::Tail, AirTrickFamily::Kickflip),
            AirTrick::new(PopEnd::Tail, AirTrickFamily::Heelflip),
            AirTrick::new(PopEnd::Nose, AirTrickFamily::Kickflip),
            AirTrick::new(PopEnd::Nose, AirTrickFamily::Heelflip),
        ];
        for trick in tricks {
            for desired_flip_count in 1..=4 {
                let mut sim = SkateSim::default();
                sim.begin_air_trick(
                    trick,
                    AirTrickEntry::FromAnticipation,
                    AirTrickHeight::LowEndpoint,
                )
                .unwrap();

                assert_eq!(
                    sim.step_air_trick(
                        0.0,
                        AirTrickSignals {
                            animation_will_expire: true,
                            ..default()
                        },
                    ),
                    Some(AirTrickStepOutcome::Transitioned)
                );
                assert_eq!(
                    sim.air_trick.as_ref().unwrap().runtime.phase,
                    AirTrickPhase::LeftGroundAir
                );

                for completed_cycles in 0..desired_flip_count {
                    let should_hold = completed_cycles + 1 < desired_flip_count;
                    let outcome = sim.step_air_trick(
                        0.0,
                        AirTrickSignals {
                            animation_will_expire: true,
                            trick_hold: should_hold,
                            time_to_land_seconds: Some(2.0),
                            ..default()
                        },
                    );
                    assert_eq!(outcome, Some(AirTrickStepOutcome::Transitioned));
                }

                let expected_phase = AirTrickPhase::FlipOut(desired_flip_count);
                assert_eq!(
                    sim.air_trick.as_ref().unwrap().runtime.phase,
                    expected_phase,
                    "{} did not select OUT{desired_flip_count}",
                    trick.intent_name()
                );
                let expected_out =
                    flip_loop_endpoint_pair(trick, ClipSegment::FlipOut(desired_flip_count))
                        .unwrap();
                let out_state = sim.air_trick_animation_state().unwrap().unwrap();
                assert_eq!(out_state.samples[0].clip, expected_out.low);

                assert_eq!(
                    sim.step_air_trick(
                        0.0,
                        AirTrickSignals {
                            animation_will_expire: true,
                            handoff_target: Some(HandoffTarget::InAir),
                            ..default()
                        },
                    ),
                    Some(AirTrickStepOutcome::Completed(HandoffTarget::InAir))
                );
                let catch = sim.air_trick_animation_state().unwrap().unwrap();
                assert_eq!(catch.samples[0].clip, expected_out.low);
                assert!(
                    (catch.samples[0].seek_time_seconds
                        - (flip_duration_seconds(expected_out, 0.0) - WILL_EXPIRE_WINDOW_SECONDS))
                        .abs()
                        < 1.0e-6
                );

                sim.step_air_trick(1.0 / RETAIL_ANIMATION_HZ, AirTrickSignals::default());
                let blended_catch = sim.air_trick_animation_state().unwrap().unwrap();
                assert_eq!(blended_catch.samples[0].clip, expected_out.low);
                assert_eq!(blended_catch.samples[1].clip, AIR_BASELINE_CLIP);
            }
        }
    }

    #[test]
    fn every_single_rotation_sequence_retains_its_catch_tail_under_air_idle() {
        use crate::air_trick_graph::ClipSegment;
        use crate::air_trick_graph::HandoffTarget;

        for (winner, trick) in SINGLE_ROTATION_FLICKIT_TRICKS {
            let air = flip_endpoint_pair(trick, ClipSegment::Air).unwrap();
            let duration = flip_duration_seconds(air, 0.0);
            let mut sim = SkateSim::default();
            sim.begin_air_trick(
                trick,
                AirTrickEntry::FromAnticipation,
                AirTrickHeight::LowEndpoint,
            )
            .unwrap();
            {
                let playback = sim.air_trick.as_mut().unwrap();
                playback.runtime.phase = AirTrickPhase::LeftGroundAir;
                playback.phase_time_seconds =
                    FLIP_GROUND_SEQUENCE_LEAD_SECONDS + duration - WILL_EXPIRE_WINDOW_SECONDS;
            }

            assert_eq!(
                sim.step_air_trick(
                    0.0,
                    AirTrickSignals {
                        established_airborne: true,
                        animation_will_expire: true,
                        handoff_target: Some(HandoffTarget::InAir),
                        ..default()
                    },
                ),
                Some(AirTrickStepOutcome::Completed(HandoffTarget::InAir)),
                "{winner} did not enter its retail InAir handoff"
            );
            let catch = sim.action_animation_state();
            assert_eq!(catch.samples[0].clip, air.low, "{winner}");
            assert!(
                (catch.samples[0].seek_time_seconds - (duration - WILL_EXPIRE_WINDOW_SECONDS))
                    .abs()
                    < 1.0e-6,
                "{winner} skipped its unconsumed physical A tail"
            );

            sim.step_air_trick(1.0 / RETAIL_ANIMATION_HZ, AirTrickSignals::default());
            let next = sim.action_animation_state();
            assert_eq!(next.samples.len(), 2, "{winner}");
            assert_eq!(next.samples[0].clip, air.low, "{winner}");
            assert_eq!(next.samples[1].clip, AIR_BASELINE_CLIP, "{winner}");
        }
    }

    #[test]
    fn odd_shove_completion_toggles_board_parity_but_360_families_do_not() {
        use crate::air_trick_graph::HandoffTarget;

        let complete = |sim: &mut SkateSim, family| {
            sim.begin_air_trick(
                AirTrick::new(PopEnd::Tail, family),
                AirTrickEntry::FromAnticipation,
                AirTrickHeight::LowEndpoint,
            )
            .unwrap();
            sim.air_trick.as_mut().unwrap().runtime.phase = AirTrickPhase::LeftGroundAir;
            sim.step_air_trick(
                0.0,
                AirTrickSignals {
                    established_airborne: true,
                    animation_will_expire: true,
                    handoff_target: Some(HandoffTarget::InAir),
                    ..default()
                },
            )
        };

        let mut sim = SkateSim::default();
        assert_eq!(
            complete(&mut sim, AirTrickFamily::PopShuvit),
            Some(AirTrickStepOutcome::Completed(HandoffTarget::InAir))
        );
        assert_eq!(sim.visual_board_reversal(), 0.0);
        assert_eq!(
            sim.visual_board_reversal_transition(),
            Some((1.0, 0.0, SEQUENCE_TO_AIR_BASELINE_BLEND_SECONDS))
        );
        sim.step_skateboard_offset_transition(SEQUENCE_TO_AIR_BASELINE_BLEND_SECONDS);
        assert_eq!(sim.visual_board_reversal(), 1.0);

        sim.air_trick = None;
        assert_eq!(
            complete(&mut sim, AirTrickFamily::Flip360),
            Some(AirTrickStepOutcome::Completed(HandoffTarget::InAir))
        );
        assert_eq!(sim.visual_board_reversal(), 1.0);
        assert_eq!(sim.visual_board_reversal_transition(), None);

        sim.air_trick = None;
        assert_eq!(
            complete(&mut sim, AirTrickFamily::VarialKickflip),
            Some(AirTrickStepOutcome::Completed(HandoffTarget::InAir))
        );
        assert_eq!(
            sim.visual_board_reversal_transition(),
            Some((0.0, 0.0, SEQUENCE_TO_AIR_BASELINE_BLEND_SECONDS))
        );
        sim.step_skateboard_offset_transition(SEQUENCE_TO_AIR_BASELINE_BLEND_SECONDS);
        assert_eq!(sim.visual_board_reversal(), 0.0);
    }

    #[test]
    fn seven_body_post_physics_uses_independent_wheel_compressions_and_authority() {
        let mut sim = SkateSim::default();
        let contacts = [1.0, 3.0, 5.0, 7.0].map(|compression| WheelContact {
            touching: true,
            compression,
            ..default()
        });
        let physics = sim.apply_skateboard_post_physics(17, contacts, BodyPoseSet::default());
        assert_eq!(physics.compression.front, 2.0);
        assert_eq!(physics.compression.back, 6.0);
        assert_eq!(physics.compression.all_wheels, 4.0);
        assert!(physics.physics_pose.is_some());

        sim.board_authority = BoardAuthority::Animation;
        let animation_owned =
            sim.apply_skateboard_post_physics(18, contacts, BodyPoseSet::default());
        assert!(animation_owned.physics_pose.is_none());
        assert_eq!(sim.skateboard_body.last_step, Some(18));
    }

    #[test]
    fn riding_force_queue_and_post_physics_branch_use_retail_capacity_and_lifetime() {
        let mut sim = SkateSim::default();
        let force =
            SkateboardForce::new(SkateboardForceType(7), RetailVec4::ZERO, RetailVec4::ZERO);
        for _ in 0..21 {
            assert!(sim.add_skateboard_force(force));
        }
        assert!(!sim.add_skateboard_force(force));
        let state = sim.complete_riding_post_physics(PostPhysicsBranchInput::default());
        assert_eq!(state.queue_completion.submitted_to_solver, 21);
        assert_eq!(state.queue_completion.discarded_without_solver, 0);
        assert!(sim.riding_force_queue.is_empty());
    }

    #[test]
    fn recovered_body_tilt_refuses_missing_retail_inputs() {
        let mut sim = SkateSim::default();
        let error = sim
            .step_recovered_body_tilt(BodyTiltFrameEvidence::Unresolved(
                UnresolvedBodyTiltInput::SpeedPointGraphSample,
            ))
            .unwrap_err();
        assert_eq!(
            error,
            BodyTiltStepError::Unresolved(UnresolvedBodyTiltInput::SpeedPointGraphSample)
        );
        assert_eq!(sim.body_tilt_conditioner, BodyTiltState::default());
    }

    #[test]
    fn exact_grind_chromosome_enters_virtual_graph_without_guessing_a_leaf() {
        let mut sim = SkateSim::default();
        let chromosome = GrindChromosome::new(
            Approach::Frontside,
            BoardEnd::Nose,
            Alignment::Twisted,
            Height::High,
            Travel::Forward,
            ContactFamily::FiftyFifty,
        );
        sim.begin_grind(chromosome, "B_GRIND5050", GrindTemplate::Plain)
            .unwrap();

        let playback = sim.grind.as_ref().unwrap();
        assert_eq!(playback.classification.table_index, 0);
        assert_eq!(playback.classification.canonical_name, "FS_50_50");
        assert_eq!(playback.runtime.phase, GrindPhase::Cycle);
        assert_eq!(sim.board_authority, BoardAuthority::Physics);
        let request = playback.runtime.animation_request().unwrap();
        assert_eq!(request.resource.name, "B_GRIND5050");
        assert!(sim.action_animation_state().samples.is_empty());
    }

    #[test]
    fn recovered_manual_entry_enters_decoded_virtual_selector_tree() {
        let mut sim = SkateSim::default();
        assert!(!sim.begin_manual(
            ManualEntryContext {
                manual: -1.0,
                manual_engage_time_seconds: 0.2,
                ..default()
            },
            -1.0,
        ));
        assert!(sim.begin_manual(
            ManualEntryContext {
                manual: -1.0,
                manual_engage_time_seconds: 0.201,
                ..default()
            },
            -1.0,
        ));

        let playback = sim.manual.as_ref().unwrap();
        assert_eq!(playback.runtime.kind, ManualKind::Tail);
        assert_eq!(playback.runtime.phase, ManualPhase::Cycle);
        assert_eq!(
            playback
                .runtime
                .animation_request()
                .map(|request| request.resource),
            Some("B_TAIL_MANUAL")
        );
        assert_eq!(
            sim.action_animation_state().samples[0].clip,
            "M_IDLE_N_0_CYC"
        );

        let balance = sim
            .step_manual(
                DT,
                ManualSignals {
                    manual: -1.0,
                    board_local_speed_z: -1.0,
                    ..default()
                },
            )
            .unwrap()
            .unwrap();
        assert_eq!(balance.velocity.to_bits(), (-0.02_f32).to_bits());
        assert_eq!(balance.angle.to_bits(), (-0.02_f32).to_bits());
    }

    #[test]
    fn held_partial_stick_enters_tail_and_nose_manual_on_flat_ground() {
        for (stick_y, expected) in [(-0.65, ManualKind::Tail), (0.65, ManualKind::Nose)] {
            let mut sim = SkateSim::default();
            sim.velocity = Vec3::new(0.0, 0.0, 4.0);
            sim.right_stick = Vec2::new(0.0, stick_y);
            for _ in 0..24 {
                step_held_manual_control(&mut sim, DT, false);
                assert!(sim.manual.is_none());
            }
            step_held_manual_control(&mut sim, DT, false);
            assert_eq!(
                sim.manual.as_ref().map(|playback| playback.runtime.kind),
                Some(expected)
            );
            assert!(sim.deck_pitch.signum() == stick_y.signum());
        }
    }

    #[test]
    fn manual_entry_uses_play_animation_time_without_scaling_nose_into_by_balance() {
        let mut nose = SkateSim::default();
        assert!(nose.begin_manual(
            ManualEntryContext {
                manual: 0.5,
                manual_engage_time_seconds: 0.201,
                ..default()
            },
            2.0,
        ));
        for _ in 0..6 {
            nose.step_manual(
                DT,
                ManualSignals {
                    manual: 0.5,
                    board_local_speed_z: 2.0,
                    ..default()
                },
            )
            .unwrap();
        }
        assert!((nose.action_animation_state().weight - 0.5).abs() < 1.0e-5);
        for _ in 0..6 {
            nose.step_manual(
                DT,
                ManualSignals {
                    manual: 0.5,
                    board_local_speed_z: 2.0,
                    ..default()
                },
            )
            .unwrap();
        }
        assert!((nose.action_animation_state().weight - 1.0).abs() < 1.0e-5);

        let mut tail = SkateSim::default();
        assert!(tail.begin_manual(
            ManualEntryContext {
                manual: -0.5,
                manual_engage_time_seconds: 0.201,
                ..default()
            },
            -2.0,
        ));
        for _ in 0..18 {
            tail.step_manual(
                DT,
                ManualSignals {
                    manual: -0.5,
                    board_local_speed_z: -2.0,
                    ..default()
                },
            )
            .unwrap();
        }
        // Manual magnitude does not scale the complete selector action. It
        // reaches half weight solely through the authored entry transition.
        assert!((tail.action_animation_state().weight - 0.5).abs() < 1.0e-5);
    }

    #[test]
    fn nose_into_does_not_precharge_cycle_owned_manual_angle() {
        let mut sim = SkateSim::default();
        assert!(sim.begin_manual(
            ManualEntryContext {
                manual: 1.0,
                manual_engage_time_seconds: 0.201,
                ..default()
            },
            2.0,
        ));

        for _ in 0..48 {
            let step = sim
                .step_manual(
                    DT,
                    ManualSignals {
                        manual: 1.0,
                        board_local_speed_z: 2.0,
                        animation_remaining_seconds: Some(0.2),
                        ..default()
                    },
                )
                .unwrap();
            assert_eq!(step, None);
        }
        let playback = sim.manual.as_ref().unwrap();
        assert_eq!(playback.runtime.phase, ManualPhase::NoseInto);
        assert_eq!(
            playback.balance_conditioner.angle().to_bits(),
            0.0_f32.to_bits()
        );
        assert_eq!(
            playback.balance_conditioner.velocity().to_bits(),
            0.0_f32.to_bits()
        );

        let first_cycle_step = sim
            .step_manual(
                DT,
                ManualSignals {
                    manual: 1.0,
                    board_local_speed_z: 2.0,
                    animation_remaining_seconds: Some(0.04),
                    ..default()
                },
            )
            .unwrap()
            .unwrap();
        assert_eq!(
            sim.manual.as_ref().unwrap().runtime.phase,
            ManualPhase::Cycle
        );
        assert_eq!(first_cycle_step.velocity.to_bits(), 0.02_f32.to_bits());
        assert_eq!(first_cycle_step.angle.to_bits(), 0.02_f32.to_bits());
    }

    #[test]
    fn manual_angle_conditioner_resets_when_reentering_its_retail_speed_child() {
        let mut sim = SkateSim::default();
        assert!(sim.begin_manual(
            ManualEntryContext {
                manual: -1.0,
                manual_engage_time_seconds: 0.201,
                ..default()
            },
            -2.0,
        ));
        for _ in 0..8 {
            sim.step_manual(
                DT,
                ManualSignals {
                    manual: -1.0,
                    board_local_speed_z: -2.0,
                    ..default()
                },
            )
            .unwrap();
        }
        assert!(sim.manual.as_ref().unwrap().balance_conditioner.angle() < -0.1);

        let inactive = sim
            .step_manual(
                DT,
                ManualSignals {
                    manual: -1.0,
                    board_local_speed_z: 0.0,
                    ..default()
                },
            )
            .unwrap();
        assert_eq!(inactive, None);

        let reentered = sim
            .step_manual(
                DT,
                ManualSignals {
                    manual: -1.0,
                    board_local_speed_z: -2.0,
                    ..default()
                },
            )
            .unwrap()
            .unwrap();
        assert_eq!(reentered.velocity.to_bits(), (-0.02_f32).to_bits());
        assert_eq!(reentered.angle.to_bits(), (-0.02_f32).to_bits());
    }

    #[test]
    fn manual_angle_updates_on_the_retail_sixty_hertz_graph_clock() {
        let entry = ManualEntryContext {
            manual: -1.0,
            manual_engage_time_seconds: 0.201,
            ..default()
        };
        let signals = ManualSignals {
            manual: -1.0,
            board_local_speed_z: -2.0,
            ..default()
        };
        let mut partitioned = SkateSim::default();
        let mut contiguous = SkateSim::default();
        assert!(partitioned.begin_manual(entry, -2.0));
        assert!(contiguous.begin_manual(entry, -2.0));

        let first = partitioned.step_manual(DT, signals).unwrap().unwrap();
        contiguous.step_manual(DT, signals).unwrap().unwrap();
        assert_eq!(first.angle.to_bits(), (-0.02_f32).to_bits());

        assert_eq!(partitioned.step_manual(DT, signals).unwrap(), None);
        let partitioned_second = partitioned.step_manual(DT, signals).unwrap().unwrap();
        let contiguous_second = contiguous
            .step_manual(1.0 / RETAIL_ANIMATION_HZ, signals)
            .unwrap()
            .unwrap();
        assert_eq!(
            partitioned_second.angle.to_bits(),
            contiguous_second.angle.to_bits()
        );
        assert_eq!(
            partitioned_second.velocity.to_bits(),
            contiguous_second.velocity.to_bits()
        );
        assert_eq!(partitioned_second.angle.to_bits(), (-0.06_f32).to_bits());
    }

    #[test]
    fn nose_into_to_cycle_preserves_source_weight_and_clamps_the_outgoing_leaf() {
        let mut sim = SkateSim::default();
        assert!(sim.begin_manual(
            ManualEntryContext {
                manual: 0.5,
                manual_engage_time_seconds: 0.201,
                ..default()
            },
            2.0,
        ));
        {
            let playback = sim.manual.as_mut().unwrap();
            playback.total_time_seconds = 1.0;
            playback.phase_time_seconds = 0.42;
        }
        sim.step_manual(
            DT,
            ManualSignals {
                manual: 0.5,
                board_local_speed_z: 2.0,
                animation_remaining_seconds: Some(0.04),
                ..default()
            },
        )
        .unwrap();
        assert_eq!(
            sim.manual.as_ref().unwrap().runtime.phase,
            ManualPhase::Cycle
        );
        assert!((sim.action_animation_state().weight - 1.0).abs() < 1.0e-5);

        for _ in 0..18 {
            sim.step_manual(
                DT,
                ManualSignals {
                    manual: 0.5,
                    board_local_speed_z: 2.0,
                    ..default()
                },
            )
            .unwrap();
        }
        let action = sim.action_animation_state();
        // At half of the 0.3 s handoff both complete selector actions
        // contribute 0.5; balance is resolved inside the Cycle tree.
        assert!((action.weight - 1.0).abs() < 1.0e-5);
        let outgoing = action
            .samples
            .iter()
            .find(|sample| sample.clip == "M_NOSEIDLE_N_0_INTO")
            .unwrap();
        let duration =
            crate::manual_animation::manual_visual_duration_seconds(&outgoing.clip).unwrap();
        assert!((outgoing.seek_time_seconds - duration).abs() < 1.0e-5);
    }

    #[test]
    fn nose_out_is_not_erased_by_the_short_manual_out_timer() {
        let mut sim = SkateSim::default();
        assert!(sim.begin_manual(
            ManualEntryContext {
                manual: 0.5,
                manual_engage_time_seconds: 0.201,
                ..default()
            },
            2.0,
        ));
        let playback = sim.manual.as_mut().unwrap();
        playback.runtime.phase = ManualPhase::NoseOut;
        playback.total_time_seconds = 1.0;
        playback.presentation_balance = 0.0;
        let action = sim.action_animation_state();
        assert_eq!(action.weight, 1.0);
        assert_eq!(action.samples[0].clip, "M_NOSEIDLE_N_0_OUT");
    }

    #[test]
    fn manual_tail_nose_routing_is_stance_invariant() {
        for _stance in [MirrorState::Unmirrored, MirrorState::Mirrored] {
            for (stick_y, expected) in [(-0.6, ManualKind::Tail), (0.6, ManualKind::Nose)] {
                let mut sim = SkateSim::default();
                sim.right_stick = Vec2::new(0.0, stick_y);
                for _ in 0..25 {
                    step_held_manual_control(&mut sim, DT, false);
                }
                assert_eq!(
                    sim.manual.as_ref().map(|manual| manual.runtime.kind),
                    Some(expected)
                );
            }
        }
    }

    #[test]
    fn active_manual_tracks_analog_pitch_then_releases_through_out_timer() {
        let mut sim = SkateSim::default();
        assert!(sim.begin_manual(
            ManualEntryContext {
                manual: -0.5,
                manual_engage_time_seconds: 0.201,
                ..default()
            },
            4.0,
        ));
        sim.right_stick = Vec2::new(0.0, -0.5);
        for _ in 0..36 {
            step_held_manual_control(&mut sim, DT, false);
        }
        let shallow = sim.deck_pitch.abs();
        assert!((sim.action_animation_state().weight - 1.0).abs() < 1.0e-5);
        sim.right_stick = Vec2::new(0.0, -0.85);
        step_held_manual_control(&mut sim, DT, false);
        assert!(sim.deck_pitch.abs() > shallow);
        assert!((sim.action_animation_state().weight - 1.0).abs() < 1.0e-5);
        assert!(!sim.manual_deck_contact.touching);

        sim.right_stick = Vec2::ZERO;
        step_held_manual_control(&mut sim, DT, false);
        assert!(sim.manual.is_some());
        assert!(
            sim.deck_pitch.abs()
                < crate::manual_contact::contact_pitch_limit(ManualKind::Tail).abs()
        );
        for _ in 0..20 {
            step_held_manual_control(&mut sim, DT, false);
        }
        assert!(sim.manual.is_none());
        assert_eq!(sim.deck_pitch, 0.0);
    }

    #[test]
    fn manual_direction_selector_follows_conditioned_board_turn_without_input_jumps() {
        for (kind, manual) in [(ManualKind::Tail, -0.65), (ManualKind::Nose, 0.65)] {
            let mut sim = SkateSim {
                velocity: Vec3::new(0.0, 0.0, 4.0),
                right_stick: Vec2::new(0.0, manual),
                ..default()
            };
            assert!(sim.begin_manual(
                ManualEntryContext {
                    manual,
                    manual_engage_time_seconds: 0.201,
                    ..default()
                },
                4.0,
            ));
            {
                let playback = sim.manual.as_mut().unwrap();
                playback.runtime.kind = kind;
                playback.runtime.phase = ManualPhase::Cycle;
                playback.total_time_seconds = 1.0;
            }

            sim.steer = 1.0;
            step_held_manual_control(&mut sim, DT, false);
            assert_eq!(sim.manual.as_ref().unwrap().runtime.spin, 0.0);

            for _ in 0..2 {
                step_board_lean(&mut sim, DT, false);
                step_retail_animation_signals(&mut sim, DT);
            }
            step_held_manual_control(&mut sim, DT, false);
            let conditioned = sim.manual.as_ref().unwrap().runtime.spin;
            assert!(conditioned > 0.0 && conditioned < 1.0);
            let turning = sim.action_animation_state();
            assert!(
                turning.samples.iter().any(|sample| {
                    sample.clip.contains("TURN_FS") && sample.weight > f32::EPSILON
                })
            );
            assert!(
                turning.samples.iter().any(|sample| {
                    !sample.clip.contains("TURN_") && sample.weight > f32::EPSILON
                })
            );

            sim.steer = -1.0;
            for _ in 0..2 {
                step_board_lean(&mut sim, DT, false);
                step_retail_animation_signals(&mut sim, DT);
            }
            step_held_manual_control(&mut sim, DT, false);
            let after_reversal = sim.manual.as_ref().unwrap().runtime.spin;
            assert!(
                after_reversal > 0.0 && after_reversal < conditioned,
                "the full-body selector must follow the continuous deck response"
            );
            assert!(
                sim.action_animation_state()
                    .samples
                    .iter()
                    .all(|sample| !sample.clip.contains("TURN_BS")),
                "one raw-stick frame must not swap the complete FS pose to BS"
            );
        }
    }

    #[test]
    fn tail_manual_exit_blends_the_advancing_cycle_to_riding_for_point_two_seconds() {
        let mut sim = SkateSim::default();
        assert!(sim.begin_manual(
            ManualEntryContext {
                manual: -0.65,
                manual_engage_time_seconds: 0.201,
                ..default()
            },
            -2.0,
        ));
        sim.manual.as_mut().unwrap().total_time_seconds = 1.0;
        sim.right_stick = Vec2::new(0.0, -0.65);
        step_held_manual_control(&mut sim, DT, false);
        sim.right_stick = Vec2::ZERO;
        step_held_manual_control(&mut sim, DT, false);

        assert_eq!(
            sim.manual.as_ref().map(|manual| manual.runtime.phase),
            Some(ManualPhase::ExitRequested)
        );
        let exit = sim.action_animation_state();
        assert!((exit.weight - 1.0).abs() < 1.0e-6);
        assert!(
            exit.samples
                .iter()
                .any(|sample| sample.clip == "M_IDLE_N_0_CYC")
        );

        for _ in 0..12 {
            step_held_manual_control(&mut sim, DT, false);
        }
        assert!(sim.manual.is_none());
        let midpoint = sim.action_animation_state();
        assert!((midpoint.weight - 0.5).abs() < 1.0e-5);
        assert!(midpoint.samples[0].seek_time_seconds > exit.samples[0].seek_time_seconds);

        for _ in 0..12 {
            step_held_manual_control(&mut sim, DT, false);
        }
        assert!(sim.manual_riding_handoff.is_none());
        assert_eq!(
            sim.action_animation_state(),
            ActionAnimationState::default()
        );
    }

    #[test]
    fn manual_completed_nose_out_blends_to_riding_instead_of_dropping_its_last_pose() {
        let mut sim = SkateSim::default();
        assert!(sim.begin_manual(
            ManualEntryContext {
                manual: 0.65,
                manual_engage_time_seconds: 0.201,
                ..default()
            },
            2.0,
        ));
        {
            let playback = sim.manual.as_mut().unwrap();
            playback.runtime.phase = ManualPhase::NoseOut;
            playback.total_time_seconds = 1.0;
            playback.phase_time_seconds = 0.42;
            playback.out_timer_remaining_seconds = Some(0.0);
        }
        sim.step_manual(
            DT,
            ManualSignals {
                manual: 0.0,
                board_local_speed_z: 2.0,
                physics_wants_manual_exit: true,
                animation_remaining_seconds: Some(0.04),
                ..default()
            },
        )
        .unwrap();

        assert!(sim.manual.is_none());
        let exit = sim.action_animation_state();
        assert!((exit.weight - 1.0).abs() < 1.0e-6);
        assert!(
            exit.samples
                .iter()
                .any(|sample| sample.clip == "M_NOSEIDLE_N_0_OUT")
        );
        for _ in 0..12 {
            step_held_manual_control(&mut sim, DT, false);
        }
        assert!((sim.action_animation_state().weight - 0.5).abs() < 1.0e-5);
    }

    #[test]
    fn full_manual_drag_is_contact_gated_and_preserves_planar_heading() {
        let mut no_contact = SkateSim::default();
        no_contact.velocity = Vec3::new(2.0, 0.0, 5.0);
        no_contact.begin_manual(
            ManualEntryContext {
                manual: -0.99,
                manual_engage_time_seconds: 0.201,
                ..default()
            },
            5.0,
        );
        no_contact.right_stick = Vec2::new(0.0, -0.99);
        for _ in 0..36 {
            step_held_manual_control(&mut no_contact, DT, false);
        }
        step_velocity(&mut no_contact, DT, false, false, false);
        assert!(!no_contact.manual_deck_contact.touching);
        assert_eq!(no_contact.manual_deck_contact.speed_loss, 0.0);
        let heading = Vec2::new(no_contact.velocity.x, no_contact.velocity.z).normalize();

        let mut contact = SkateSim::default();
        contact.velocity = Vec3::new(2.0, 0.0, 5.0);
        contact.begin_manual(
            ManualEntryContext {
                manual: -1.0,
                manual_engage_time_seconds: 0.201,
                ..default()
            },
            5.0,
        );
        contact.right_stick = Vec2::new(0.0, -1.0);
        for _ in 0..36 {
            step_held_manual_control(&mut contact, DT, false);
        }
        step_velocity(&mut contact, DT, false, false, false);
        assert!(contact.manual_deck_contact.touching);
        assert!(contact.manual_deck_contact.speed_loss > 0.0);
        let next_heading = Vec2::new(contact.velocity.x, contact.velocity.z).normalize();
        assert!((heading - next_heading).length() < 1.0e-5);
        assert!(contact.speed() < no_contact.speed());
    }

    #[test]
    fn near_full_manual_brake_keeps_the_authored_clip_visible() {
        for (kind, stick_y, expected_clip) in [
            (ManualKind::Tail, -0.99, "M_BRAKE_N_0_CYC"),
            (ManualKind::Nose, 0.99, "M_NOSEBRAKE_N_0_CYC"),
        ] {
            let mut sim = SkateSim::default();
            sim.velocity = Vec3::new(0.0, 0.0, 3.0);
            assert!(sim.begin_manual(
                ManualEntryContext {
                    manual: stick_y,
                    manual_engage_time_seconds: 0.201,
                    ..default()
                },
                3.0,
            ));
            let playback = sim.manual.as_mut().unwrap();
            playback.runtime.kind = kind;
            playback.runtime.phase = ManualPhase::Cycle;
            playback.total_time_seconds = 1.0;
            sim.right_stick = Vec2::new(0.0, stick_y);
            step_held_manual_control(&mut sim, DT, false);

            let playback = sim.manual.as_ref().unwrap();
            assert_eq!(playback.runtime.phase, ManualPhase::Brake);
            assert_eq!(
                playback.runtime.balance,
                if kind == ManualKind::Tail { -1.0 } else { 1.0 }
            );
            let action = sim.action_animation_state();
            assert!(
                action
                    .samples
                    .iter()
                    .any(|sample| sample.clip == expected_clip)
            );
            assert!(
                action
                    .samples
                    .iter()
                    .all(|sample| sample.clip != "BTREE_RIDING")
            );
            assert!(action.weight > 0.98);

            for _ in 0..12 {
                step_held_manual_control(&mut sim, DT, false);
            }
            let blended = sim.action_animation_state();
            let brake_weight = blended
                .samples
                .iter()
                .find(|sample| sample.clip == expected_clip)
                .map_or(0.0, |sample| sample.weight);
            assert!(brake_weight > 0.0 && brake_weight < 1.0);

            for _ in 0..13 {
                step_held_manual_control(&mut sim, DT, false);
            }
            let settled = sim.action_animation_state();
            assert_eq!(settled.samples.len(), 1);
            assert_eq!(settled.samples[0].clip, expected_clip);
        }
    }

    #[test]
    fn full_vertical_flickit_anticipation_boundary_precedes_manual_entry() {
        let pad = CanonicalPadState {
            right_y: i16::MIN,
            ..default()
        };
        let admission =
            anticipation_admission(pad, MirrorState::Unmirrored).expect("full tail input");
        assert_eq!(admission.side, AnticipationSide::Tail);
        let mut sim = SkateSim::default();
        begin_anticipation(&mut sim, admission.identity);
        sim.right_stick = Vec2::new(0.0, -1.0);
        for _ in 0..40 {
            step_held_manual_control(&mut sim, DT, false);
        }
        assert!(sim.manual.is_none());
        assert!(sim.manual_control.engage_seconds() > 0.2);
    }

    #[test]
    fn proven_landing_route_enters_manual_but_rejects_hard_steep_impact() {
        let mut normal = SkateSim::default();
        normal.begin_basic_trick(BasicTrickKind::Ollie, TrickHeightEndpoint::Low);
        normal.right_stick = Vec2::new(0.0, 0.7);
        for _ in 0..25 {
            step_held_manual_control(&mut normal, DT, false);
        }
        assert!(normal.manual.is_none());
        step_held_manual_control(&mut normal, DT, true);
        assert_eq!(
            normal.manual.as_ref().map(|manual| manual.runtime.kind),
            Some(ManualKind::Nose)
        );
        assert!(normal.basic_trick.is_none());

        let mut rejected = SkateSim::default();
        rejected.begin_basic_trick(BasicTrickKind::Ollie, TrickHeightEndpoint::Low);
        rejected.right_stick = Vec2::new(0.0, -0.7);
        rejected.velocity.y = -8.01;
        rejected.ground_normal = Vec3::new(0.0, 0.7, 0.714_142_86);
        for _ in 0..25 {
            step_held_manual_control(&mut rejected, DT, false);
        }
        step_held_manual_control(&mut rejected, DT, true);
        assert!(rejected.manual.is_none());
        assert!(rejected.basic_trick.is_some());
    }

    #[test]
    fn manual_has_no_speed_gate_but_ground_contact_loss_requests_exit() {
        let mut sim = SkateSim::default();
        sim.velocity = Vec3::ZERO;
        sim.right_stick = Vec2::new(0.0, -0.65);
        for _ in 0..25 {
            step_held_manual_control(&mut sim, DT, false);
        }
        assert_eq!(
            sim.manual.as_ref().map(|manual| manual.runtime.kind),
            Some(ManualKind::Tail)
        );
        sim.ground_contact_valid = false;
        step_held_manual_control(&mut sim, DT, false);
        assert_eq!(
            sim.manual.as_ref().map(|manual| manual.runtime.phase),
            Some(ManualPhase::ExitRequested)
        );
        for _ in 0..20 {
            step_held_manual_control(&mut sim, DT, false);
        }
        assert!(sim.manual.is_none());
    }

    #[test]
    fn live_basic_trick_playback_emits_only_physical_catalog_leaves() {
        let mut sim = SkateSim::default();
        sim.begin_basic_trick(BasicTrickKind::Ollie, TrickHeightEndpoint::High);

        let ground = sim.basic_trick_animation_state().unwrap().unwrap();
        assert_eq!(ground.samples.len(), 1);
        assert_eq!(ground.samples[0].clip, "OLLIE_HIGH_G");
        assert!(!ground.samples[0].clip.starts_with("B_"));
        assert_eq!(sim.board_authority, BoardAuthority::Physics);

        sim.step_basic_trick(
            DT,
            BasicTrickSignals {
                wheel_lifted: true,
                ..default()
            },
            None,
        );
        assert_eq!(sim.board_authority, BoardAuthority::FollowAnimationData);
        sim.step_basic_trick(
            0.2,
            BasicTrickSignals {
                established_airborne: true,
                ..default()
            },
            None,
        );
        let air = sim.basic_trick_animation_state().unwrap().unwrap();
        assert_eq!(air.samples[0].clip, "OLLIE_HIGH_A");
        assert_eq!(sim.board_authority, BoardAuthority::Animation);
    }

    #[test]
    fn straight_landing_requires_recovered_blend_coordinates() {
        let mut sim = SkateSim::default();
        sim.begin_basic_trick(BasicTrickKind::Nollie, TrickHeightEndpoint::Low);
        sim.step_basic_trick(
            0.0,
            BasicTrickSignals {
                landed: Some(LandingAnimationResource::Straight),
                ..default()
            },
            None,
        );
        let unresolved = sim.basic_trick_animation_state().unwrap_err();
        assert_eq!(unresolved.source_resource, "BLEND_LAND");
        assert!(sim.action_animation_state().samples.is_empty());

        let parameters = StraightLandingParameters {
            posture: LandingPosture::Loose,
            variant: LandingVariant::Two,
        };
        sim.basic_trick
            .as_mut()
            .unwrap()
            .straight_landing_parameters = Some(parameters);
        let landing = sim.basic_trick_animation_state().unwrap().unwrap();
        assert_eq!(landing.samples[0].clip, "L_LAND_HIGH_LOOSE_2_N");
    }

    #[test]
    fn recovered_flip_runtime_publishes_the_direct_physical_endpoint() {
        let mut sim = SkateSim::default();
        let trick = AirTrick::new(PopEnd::Tail, AirTrickFamily::Kickflip);
        sim.begin_air_trick(
            trick,
            AirTrickEntry::FromAnticipation,
            AirTrickHeight::LowEndpoint,
        )
        .unwrap();

        let playback = sim.air_trick.as_ref().unwrap();
        assert_eq!(playback.phase_label(), "takeoff_ground");
        assert_eq!(
            playback.requested_resource().as_deref(),
            Some("B_KICKFLIP_IN_G")
        );
        let animation = sim.air_trick_animation_state().unwrap().unwrap();
        assert_eq!(animation.samples.len(), 1);
        assert_eq!(animation.samples[0].clip, "KICKFLIP_IN_LOW_G");
        assert!(!animation.samples[0].clip.starts_with("COMBINED_"));
        assert!(!animation.samples[0].clip.starts_with("B_"));
        assert_eq!(
            sim.action_animation_state().samples[0].clip,
            "KICKFLIP_IN_LOW_G"
        );

        let outcome = sim
            .step_air_trick(
                DT,
                AirTrickSignals {
                    wheel_lifted: true,
                    ..default()
                },
            )
            .unwrap();
        assert_eq!(outcome, AirTrickStepOutcome::NoTransition);
        assert_eq!(sim.board_authority, BoardAuthority::FollowAnimationData);
    }

    #[test]
    fn flip360_uses_physical_full_pose_leaves_and_retail_sequence_timing() {
        let mut sim = SkateSim::default();
        sim.begin_air_trick(
            AirTrick::new(PopEnd::Tail, AirTrickFamily::Flip360),
            AirTrickEntry::FromAnticipation,
            AirTrickHeight::HighEndpoint,
        )
        .unwrap();

        let ground = sim.air_trick_animation_state().unwrap().unwrap();
        assert_eq!(ground.samples[0].clip, "360FLIP_D_HIGH_G");
        assert_eq!(
            sim.air_trick
                .as_ref()
                .unwrap()
                .authored_phase_duration_seconds()
                .unwrap(),
            Some(12.0 / RETAIL_ANIMATION_HZ)
        );

        assert_eq!(
            sim.step_air_trick(
                DT,
                AirTrickSignals {
                    wheel_lifted: true,
                    established_airborne: true,
                    animation_will_expire: true,
                    ..default()
                },
            ),
            Some(AirTrickStepOutcome::Transitioned)
        );
        let sequence_lead = sim.air_trick_animation_state().unwrap().unwrap();
        assert_eq!(sequence_lead.samples[0].clip, "360FLIP_D_HIGH_G");
        assert!(
            (sequence_lead.samples[0].seek_time_seconds
                - (12.0 / RETAIL_ANIMATION_HZ - FLIP_GROUND_SEQUENCE_LEAD_SECONDS))
                .abs()
                < 1.0e-6
        );

        sim.air_trick.as_mut().unwrap().phase_time_seconds = FLIP_GROUND_SEQUENCE_LEAD_SECONDS;
        let air = sim.air_trick_animation_state().unwrap().unwrap();
        assert_eq!(air.samples[0].clip, "360FLIP_D_HIGH_A");
        assert!(air.samples[0].seek_time_seconds.abs() < 1.0e-6);
        assert_eq!(
            sim.air_trick
                .as_ref()
                .unwrap()
                .authored_phase_duration_seconds()
                .unwrap(),
            Some(FLIP_GROUND_SEQUENCE_LEAD_SECONDS + 32.0 / RETAIL_ANIMATION_HZ)
        );
    }

    #[test]
    fn flip360_completion_advances_will_expire_tail_under_air_baseline_blend() {
        let mut sim = SkateSim::default();
        sim.begin_air_trick(
            AirTrick::new(PopEnd::Tail, AirTrickFamily::Flip360),
            AirTrickEntry::FromAnticipation,
            AirTrickHeight::LowEndpoint,
        )
        .unwrap();
        sim.air_trick.as_mut().unwrap().runtime.phase = AirTrickPhase::LeftGroundAir;
        sim.air_trick.as_mut().unwrap().phase_time_seconds =
            FLIP_GROUND_SEQUENCE_LEAD_SECONDS + 27.0 / RETAIL_ANIMATION_HZ;

        let outcome = sim.step_air_trick(
            0.0,
            AirTrickSignals {
                established_airborne: true,
                animation_will_expire: true,
                handoff_target: Some(crate::air_trick_graph::HandoffTarget::InAir),
                ..default()
            },
        );
        assert_eq!(
            outcome,
            Some(AirTrickStepOutcome::Completed(
                crate::air_trick_graph::HandoffTarget::InAir
            ))
        );
        assert!(sim.air_trick.is_some());
        assert_eq!(sim.board_authority, BoardAuthority::Animation);
        let catch = sim.action_animation_state();
        assert_eq!(catch.samples[0].clip, "360FLIP_D_LOW_A");
        assert!((catch.samples[0].seek_time_seconds - 24.0 / RETAIL_ANIMATION_HZ).abs() < 1.0e-6);

        sim.step_air_trick(1.0 / RETAIL_ANIMATION_HZ, AirTrickSignals::default());
        let next_retail_frame = sim.action_animation_state();
        assert_eq!(next_retail_frame.samples.len(), 2);
        assert_eq!(next_retail_frame.samples[0].clip, "360FLIP_D_LOW_A");
        assert!(
            (next_retail_frame.samples[0].seek_time_seconds - 25.0 / RETAIL_ANIMATION_HZ).abs()
                < 1.0e-6
        );
        assert!(
            (next_retail_frame.samples[0].weight
                - (1.0 - (1.0 / RETAIL_ANIMATION_HZ) / SEQUENCE_TO_AIR_BASELINE_BLEND_SECONDS))
                .abs()
                < 1.0e-6
        );

        sim.step_air_trick(2.0 / RETAIL_ANIMATION_HZ, AirTrickSignals::default());
        let tail_complete = sim.action_animation_state();
        assert_eq!(tail_complete.samples[0].clip, "360FLIP_D_LOW_A");
        assert!(
            (tail_complete.samples[0].seek_time_seconds - 27.0 / RETAIL_ANIMATION_HZ).abs()
                < 1.0e-6
        );

        sim.step_air_trick(0.05, AirTrickSignals::default());
        let midpoint = sim.action_animation_state();
        assert_eq!(midpoint.samples.len(), 2);
        assert_eq!(midpoint.samples[0].clip, "360FLIP_D_LOW_A");
        assert_eq!(midpoint.samples[1].clip, AIR_BASELINE_CLIP);
        assert!((midpoint.samples[0].weight - 0.5).abs() < 1.0e-6);
        assert!((midpoint.samples[1].weight - 0.5).abs() < 1.0e-6);

        sim.step_air_trick(0.1, AirTrickSignals::default());
        let settled = sim.action_animation_state();
        assert_eq!(settled.samples.len(), 1);
        assert_eq!(settled.samples[0].clip, AIR_BASELINE_CLIP);
        assert_eq!(settled.samples[0].weight, 1.0);

        assert_eq!(
            sim.arbitrate_and_begin_landing(
                FilteredPhysicsState::Ground,
                Some(false),
                Some(false),
                Some(LandingTypeCode::STRAIGHT),
                Some(StraightLandingParameters {
                    posture: LandingPosture::Aggressive,
                    variant: LandingVariant::One,
                }),
            ),
            LandingAdmission::Enter(LandingQuality::Straight)
        );
        assert!(sim.air_trick.is_none());
        assert_eq!(sim.board_authority, BoardAuthority::Physics);
    }

    #[test]
    fn flip360_endpoint_catch_boundaries_match_retail_will_expire_window() {
        assert!(
            (sequence_tail_seek_time(27.0 / RETAIL_ANIMATION_HZ, 0.0) - 24.0 / RETAIL_ANIMATION_HZ)
                .abs()
                < 1.0e-6
        );
        assert!(
            (sequence_tail_seek_time(32.0 / RETAIL_ANIMATION_HZ, 0.0) - 29.0 / RETAIL_ANIMATION_HZ)
                .abs()
                < 1.0e-6
        );
        assert!(
            (sequence_tail_seek_time(32.0 / RETAIL_ANIMATION_HZ, WILL_EXPIRE_WINDOW_SECONDS,)
                - 32.0 / RETAIL_ANIMATION_HZ)
                .abs()
                < 1.0e-6
        );
    }

    #[test]
    fn live_winner_router_accepts_measured_flip_height_trees() {
        let mut sim = SkateSim::default();
        assert!(begin_verified_endpoint_trick(&mut sim, "Ollie"));
        assert_eq!(
            sim.basic_trick
                .as_ref()
                .map(|playback| playback.runtime.kind),
            Some(BasicTrickKind::Ollie)
        );
        assert_eq!(
            sim.basic_trick
                .as_ref()
                .map(|playback| playback.runtime.height_endpoint),
            Some(TrickHeightEndpoint::Low)
        );
        assert!(!begin_verified_endpoint_trick(&mut sim, "360Flip"));

        sim.basic_trick = None;
        assert!(begin_verified_endpoint_trick(&mut sim, "360Flip"));
        let air = sim.air_trick.as_ref().unwrap();
        assert_eq!(air.runtime.trick.intent_name(), "360Flip");
        assert_eq!(air.runtime.height, AirTrickHeight::LowEndpoint);
        assert_eq!(
            sim.pop_motion.as_ref().map(|motion| motion.launch_speed),
            Some(RETAIL_LANDING_PROJECTION_FIXTURES[0].1)
        );

        sim.air_trick = None;
        sim.pop_motion = None;
        sim.anticipation = Some(AnticipationRuntime::begin(AnticipationSide::Tail));
        sim.anticipation.as_mut().unwrap().charge_seconds = 6.0 / RETAIL_ANIMATION_HZ;
        assert!(begin_verified_endpoint_trick(&mut sim, "Kickflip"));
        let kickflip = sim.air_trick.as_ref().unwrap();
        assert_eq!(kickflip.runtime.trick.intent_name(), "Kickflip");
        assert_eq!(
            kickflip.runtime.height,
            AirTrickHeight::ContinuousUnresolved(RETAIL_FLIP_HEIGHT_WEIGHTS[4])
        );
        let state = sim.air_trick_animation_state().unwrap().unwrap();
        assert_eq!(state.samples.len(), 2);
        assert_eq!(state.samples[0].clip, "KICKFLIP_IN_LOW_G");
        assert_eq!(state.samples[1].clip, "KICKFLIP_IN_HIGH_G");
        assert_eq!(state.samples[1].weight, RETAIL_FLIP_HEIGHT_WEIGHTS[4]);

        sim.air_trick = None;
        sim.pop_motion = None;
        assert!(begin_verified_endpoint_trick(&mut sim, "Heelflip"));
        assert_eq!(
            sim.air_trick.as_ref().unwrap().runtime.trick.intent_name(),
            "Heelflip"
        );

        sim.air_trick = None;
        sim.pop_motion = None;
        sim.anticipation = Some(AnticipationRuntime::begin(AnticipationSide::Nose));
        assert!(begin_verified_endpoint_trick(&mut sim, "N_Kickflip"));
        let nollie_kickflip = sim.air_trick.as_ref().unwrap();
        assert_eq!(nollie_kickflip.runtime.trick.intent_name(), "N_Kickflip");
        assert_eq!(
            sim.air_trick_animation_state().unwrap().unwrap().samples[0].clip,
            "N_KICKFLIP_IN_LOW_G"
        );

        sim.air_trick = None;
        sim.pop_motion = None;
        assert!(begin_verified_endpoint_trick(&mut sim, "N_Heelflip"));
        assert_eq!(
            sim.air_trick.as_ref().unwrap().runtime.trick.intent_name(),
            "N_Heelflip"
        );
        assert_eq!(
            sim.air_trick_animation_state().unwrap().unwrap().samples[0].clip,
            "N_HEELFLIP_IN_LOW_G"
        );

        sim.air_trick = None;
        sim.pop_motion = None;
        let mut anticipation = AnticipationRuntime::begin(AnticipationSide::Tail);
        anticipation.charge_seconds = 30.0 / RETAIL_ANIMATION_HZ;
        sim.anticipation = Some(anticipation);
        assert!(begin_verified_endpoint_trick(&mut sim, "360Flip"));
        assert_eq!(
            sim.air_trick.as_ref().unwrap().runtime.height,
            AirTrickHeight::HighEndpoint
        );
        assert_eq!(
            sim.air_trick_animation_state().unwrap().unwrap().samples[0].clip,
            "360FLIP_D_HIGH_G"
        );
    }

    #[test]
    fn live_goofy_winner_uses_retail_mirrored_trick_identity() {
        let mut sim = SkateSim {
            natural_stance: NaturalStance::Goofy,
            ..default()
        };
        assert_eq!(sim.flickit_mirror_state(), MirrorState::Mirrored);
        assert!(begin_verified_endpoint_trick(&mut sim, "Kickflip"));

        assert_eq!(
            sim.air_trick.as_ref().unwrap().runtime.trick.intent_name(),
            "Heelflip"
        );
        assert_eq!(
            sim.active_trick_context,
            Some(TrickContext {
                name: "Heelflip".to_owned(),
                approach: TrickApproach::Regular,
            })
        );
        let state = sim.air_trick_animation_state().unwrap().unwrap();
        // The trick runtime publishes the resolved retail physical leaf.
        // Final stance mirroring is owned by animation.rs, not duplicated in
        // this lower-level action state.
        assert_eq!(state.samples[0].clip, "HEELFLIP_IN_LOW_G");
    }

    #[test]
    fn fakie_winner_keeps_retail_trick_route_and_publishes_fakie_context() {
        let mut sim = SkateSim {
            velocity: Vec3::Z * 4.0,
            yaw: std::f32::consts::PI,
            ..default()
        };
        sim.fakie.time_since_orientation_reset_seconds =
            crate::fakie::RIDING_FAKIE_FROM_RESET_SECONDS;
        sim.fakie
            .observe_motion(DT, sim.velocity.x, sim.velocity.z, sim.yaw, true);
        for _ in 0..120 {
            sim.fakie.step(DT, true);
        }
        assert_eq!(
            sim.fakie.torso_parameter(),
            crate::fakie::FAKIE_TORSO_PARAMETER_NEUTRAL
        );

        assert!(begin_verified_endpoint_trick(&mut sim, "Ollie"));
        assert_eq!(
            sim.active_trick_context,
            Some(TrickContext {
                name: "Ollie".to_owned(),
                approach: TrickApproach::Fakie,
            })
        );
        // T_Trick.xml uses IsMirrored, not IsRidingFakie, to choose the
        // physical trick family. Fakie remains scoring/presentation metadata.
        assert_eq!(sim.action_animation_state().samples[0].clip, "OLLIE_LOW_G");
    }

    #[test]
    fn maximum_charge_ollie_selects_the_captured_high_pose_endpoint() {
        assert_eq!(
            retail_basic_trick_height_endpoint(0.499_999_85),
            TrickHeightEndpoint::High,
            "the replay clock's thirty-poll f32 accumulation remains the high endpoint"
        );
        let mut sim = SkateSim::default();
        let mut anticipation = AnticipationRuntime::begin(AnticipationSide::Tail);
        anticipation.charge_seconds = 30.0 / RETAIL_ANIMATION_HZ;
        sim.anticipation = Some(anticipation);

        assert!(begin_verified_endpoint_trick(&mut sim, "Ollie"));
        assert_eq!(
            sim.basic_trick
                .as_ref()
                .map(|playback| playback.runtime.height_endpoint),
            Some(TrickHeightEndpoint::High)
        );
        assert_eq!(
            sim.basic_trick
                .as_ref()
                .and_then(|playback| playback.runtime.animation_request())
                .map(|request| request.resource),
            Some("OLLIE_HIGH_G")
        );
    }

    #[test]
    fn measured_flip_height_table_preserves_isolated_retail_captures() {
        let cases = [
            (2.0, 0.003_904_787_4_f32),
            (6.0, 0.192_488_61_f32),
            (15.0, 0.896_082_9_f32),
            (21.0, 0.983_899_83_f32),
            (30.0, 0.999_981_46_f32),
        ];
        for (frames, expected) in cases {
            assert_eq!(
                retail_flip_height_weight(frames / RETAIL_ANIMATION_HZ).to_bits(),
                expected.to_bits()
            );
        }
        let halfway = retail_flip_height_weight(6.5 / RETAIL_ANIMATION_HZ);
        assert_eq!(
            halfway,
            (RETAIL_FLIP_HEIGHT_WEIGHTS[4] + RETAIL_FLIP_HEIGHT_WEIGHTS[5]) * 0.5
        );
    }

    #[test]
    fn recovered_anticipation_admits_every_retail_sector_from_raw_xinput() {
        let cases = [
            (0, i16::MIN, AnticipationIdentity::Ollie),
            (-23_170, -23_170, AnticipationIdentity::PopShuvit),
            (-31_644, -8_801, AnticipationIdentity::ThreeSixtyPopShuvit),
            (
                -31_644,
                8_801,
                AnticipationIdentity::NollieThreeSixtyPopShuvit,
            ),
            (-23_170, 23_170, AnticipationIdentity::NolliePopShuvit),
            (0, i16::MAX, AnticipationIdentity::Nollie),
            (23_170, 23_170, AnticipationIdentity::NollieFsPopShuvit),
            (
                31_644,
                8_801,
                AnticipationIdentity::NollieFsThreeSixtyPopShuvit,
            ),
            (31_644, -8_801, AnticipationIdentity::FsThreeSixtyPopShuvit),
            (23_170, -23_170, AnticipationIdentity::FsPopShuvit),
        ];
        for (right_x, right_y, expected) in cases {
            let admission = anticipation_admission(
                CanonicalPadState {
                    right_x,
                    right_y,
                    ..default()
                },
                MirrorState::Unmirrored,
            )
            .unwrap();
            assert_eq!(admission.identity, expected);
            assert!(admission.magnitude > 0.9);
        }

        assert!(
            anticipation_admission(
                CanonicalPadState {
                    right_y: (0.87 * i16::MAX as f32) as i16,
                    ..default()
                },
                MirrorState::Unmirrored,
            )
            .is_none()
        );
    }

    #[test]
    fn switch_stance_mirrors_shuv_identity_without_changing_pop_end() {
        let regular = anticipation_admission(
            CanonicalPadState {
                right_x: -31_644,
                right_y: -8_801,
                ..default()
            },
            MirrorState::Unmirrored,
        )
        .unwrap();
        let switch = anticipation_admission(
            CanonicalPadState {
                right_x: -31_644,
                right_y: -8_801,
                ..default()
            },
            MirrorState::Mirrored,
        )
        .unwrap();
        assert_eq!(regular.identity, AnticipationIdentity::ThreeSixtyPopShuvit);
        assert_eq!(switch.identity, AnticipationIdentity::FsThreeSixtyPopShuvit);
        assert_eq!(regular.side, AnticipationSide::Tail);
        assert_eq!(switch.side, AnticipationSide::Tail);
    }

    #[test]
    fn isolated_ollie_carriers_preserve_every_recovered_timing_band() {
        let document = retail_ollie_carriers();
        for case in &document.cases {
            assert_eq!(case.first_air_frame - case.flick_frame, 14);
            assert!(matches!(
                case.touchdown_frame - case.first_air_frame,
                43 | 44
            ));
            assert!(case.samples[0].board_height.abs() < 1.0e-4);
            assert!(case.samples.last().unwrap().board_height.abs() < 1.0e-4);
            assert!(case.samples.last().unwrap().skater_height.abs() < 0.01);
        }
    }

    #[test]
    fn anticipation_pose_is_not_applied_twice_as_a_world_root_carrier() {
        let charge_seconds = 30.0 / RETAIL_ANIMATION_HZ;
        let isolated_oracle_channel = retail_anticipation_carrier(charge_seconds);
        assert!(
            isolated_oracle_channel.skater_height < -0.3,
            "the captured pre-flick channel must remain available as evidence"
        );

        let mut sim = SkateSim::default();
        let mut anticipation = AnticipationRuntime::begin(AnticipationSide::Tail);
        anticipation.charge_seconds = charge_seconds;
        sim.anticipation = Some(anticipation);

        assert_eq!(sim.visual_skater_root_offset_y(), 0.0);
        assert_eq!(sim.visual_board_correction_y(), 0.0);
    }

    #[test]
    fn mongo_push_contact_uses_the_authored_leg_return_before_anticipation() {
        let mut sim = SkateSim::default();
        request_push(&mut sim, PushFoot::Regular);
        advance_until_push_phase(&mut sim, PushPhase::Contact, true);

        begin_anticipation(&mut sim, AnticipationIdentity::Ollie);
        assert!(sim.push.is_none());
        assert_eq!(
            sim.push_anticipation_handoff
                .as_ref()
                .and_then(|handoff| handoff.bridge_clip),
            Some(MONGO_PUSH_TO_ANTIC_CLIP)
        );
        let initial = sim.action_animation_state();
        assert_eq!(initial.weight, 1.0);
        assert!(initial.samples.iter().any(|sample| {
            sample.clip == MONGO_PUSH_TO_ANTIC_CLIP
                && sample.weight == 1.0
                && sample.seek_time_seconds == 0.0
        }));

        step_anticipation_and_handoff(&mut sim, PUSH_TO_ANTICIPATION_BLEND_SECONDS * 0.5);
        let midpoint = sim.action_animation_state();
        assert_eq!(midpoint.weight, 1.0);
        let bridge = midpoint
            .samples
            .iter()
            .find(|sample| sample.clip == MONGO_PUSH_TO_ANTIC_CLIP)
            .unwrap();
        assert!((bridge.weight - 0.5).abs() < 1.0e-6);
        assert!(
            (bridge.seek_time_seconds - PUSH_TO_ANTICIPATION_BLEND_SECONDS * 0.5).abs() < 1.0e-6
        );
        let anticipation_weight: f32 = midpoint
            .samples
            .iter()
            .filter(|sample| sample.clip.contains("ANTIC"))
            .filter(|sample| sample.clip != MONGO_PUSH_TO_ANTIC_CLIP)
            .map(|sample| sample.weight)
            .sum();
        assert!((anticipation_weight - 0.5).abs() < 1.0e-5);

        step_anticipation_and_handoff(&mut sim, PUSH_TO_ANTICIPATION_BLEND_SECONDS * 0.5);
        assert!(sim.push_anticipation_handoff.is_none());
        assert!((sim.action_animation_state().weight - 1.0).abs() < 1.0e-6);

        let mut nose_sim = SkateSim::default();
        request_push(&mut nose_sim, PushFoot::Regular);
        advance_until_push_phase(&mut nose_sim, PushPhase::Contact, true);
        begin_anticipation(&mut nose_sim, AnticipationIdentity::Nollie);
        assert_eq!(
            nose_sim
                .push_anticipation_handoff
                .as_ref()
                .and_then(|handoff| handoff.bridge_clip),
            Some(MONGO_PUSH_TO_NANTIC_CLIP)
        );
    }

    #[test]
    fn non_mongo_push_route_keeps_the_current_pose_during_the_point_two_blend() {
        let mut sim = SkateSim::default();
        request_push(&mut sim, PushFoot::Mongo);
        advance_until_push_phase(&mut sim, PushPhase::Contact, true);
        let outgoing = sim.action_animation_state();

        begin_anticipation(&mut sim, AnticipationIdentity::Nollie);
        assert_eq!(
            sim.push_anticipation_handoff
                .as_ref()
                .and_then(|handoff| handoff.bridge_clip),
            None
        );
        step_anticipation_and_handoff(&mut sim, PUSH_TO_ANTICIPATION_BLEND_SECONDS * 0.5);
        let midpoint = sim.action_animation_state();
        assert!((midpoint.weight - 1.0).abs() < 1.0e-6);
        for outgoing_sample in outgoing.samples {
            assert!(midpoint.samples.iter().any(|sample| {
                sample.clip == outgoing_sample.clip
                    && (sample.seek_time_seconds - outgoing_sample.seek_time_seconds).abs()
                        < f32::EPSILON
                    && sample.weight > 0.0
            }));
        }
        assert!(
            midpoint
                .samples
                .iter()
                .any(|sample| { sample.clip.contains("NOLLIE") && sample.weight > 0.0 })
        );
    }

    #[test]
    fn quick_flick_preserves_the_in_progress_push_anticipation_composite() {
        let mut sim = SkateSim::default();
        request_push(&mut sim, PushFoot::Regular);
        advance_until_push_phase(&mut sim, PushPhase::Contact, true);
        begin_anticipation(&mut sim, AnticipationIdentity::Ollie);
        step_anticipation_and_handoff(&mut sim, 0.05);

        assert!(begin_verified_endpoint_trick(&mut sim, "Ollie"));
        assert!(sim.push_anticipation_handoff.is_none());
        let handoff = sim.trick_handoff.as_ref().unwrap();
        assert!(
            handoff
                .source
                .samples
                .iter()
                .any(|sample| { sample.clip == MONGO_PUSH_TO_ANTIC_CLIP && sample.weight > 0.0 })
        );
        assert!(handoff.source.samples.iter().any(|sample| {
            sample.clip.contains("ANTIC") && sample.clip != MONGO_PUSH_TO_ANTIC_CLIP
        }));
    }

    #[test]
    fn released_pop_does_not_apply_observed_pose_motion_as_a_world_root_carrier() {
        let mut sim = SkateSim::default();
        begin_measured_ollie_pop(&mut sim, 30.0 / RETAIL_ANIMATION_HZ);
        let motion = sim.pop_motion.as_ref().unwrap();

        assert!(
            motion.skater_height - motion.board_height < -0.4,
            "the isolated release sample must retain the observed crouched pose"
        );
        assert_eq!(sim.visual_skater_root_offset_y(), 0.0);
        assert_eq!(sim.visual_board_correction_y(), 0.0);
    }

    #[test]
    fn landing_projection_fixture_preserves_all_twenty_nine_runtime_captures() {
        for &(frames, launch, touchdown, updates) in &RETAIL_LANDING_PROJECTION_FIXTURES {
            let fixture = retail_landing_projection_fixture(frames / RETAIL_ANIMATION_HZ);
            assert_eq!(
                fixture.launch_velocity_y.to_bits(),
                launch.to_bits(),
                "launch at hold frame {frames}"
            );
            assert_eq!(
                fixture.touchdown_velocity_y.to_bits(),
                touchdown.to_bits(),
                "touchdown at hold frame {frames}"
            );
            let reconstructed_touchdown =
                -(fixture.launch_velocity_y + fixture.delta_per_frame * (updates as f32 - 1.0));
            assert!(
                (reconstructed_touchdown - touchdown).abs() < 1.0e-5,
                "reconstructed touchdown at hold frame {frames}"
            );
        }
    }

    #[test]
    fn landing_avgvely_resets_on_established_airborne_transition() {
        let mut sim = SkateSim {
            landing_average_velocity_y: 3.75,
            ..default()
        };

        begin_measured_ollie_pop(&mut sim, 6.0 / RETAIL_ANIMATION_HZ);
        assert_eq!(sim.landing_average_velocity_y, 3.75);
        while !sim
            .pop_motion
            .as_ref()
            .is_some_and(|motion| motion.separated_from_ground)
        {
            step_retail_pop_carrier(&mut sim, DT);
        }

        assert!(
            sim.pop_motion
                .as_ref()
                .is_some_and(|motion| motion.separated_from_ground)
        );
        assert_eq!(sim.landing_average_velocity_y, 0.0);
    }

    #[test]
    fn landing_avgvely_updates_at_sixty_hz_from_retail_auxiliary_projection() {
        let projection = retail_landing_projection_fixture(6.0 / RETAIL_ANIMATION_HZ);
        let mut sim = SkateSim::default();
        begin_measured_ollie_pop(&mut sim, 6.0 / RETAIL_ANIMATION_HZ);
        sim.pop_motion.as_mut().unwrap().separated_from_ground = true;

        step_retail_animation_signals(&mut sim, DT);
        assert_eq!(sim.landing_average_velocity_y, 0.0);
        step_retail_animation_signals(&mut sim, DT);
        assert_eq!(sim.landing_average_velocity_y, 0.0);

        for _ in 1..43 {
            step_retail_animation_signals(&mut sim, 1.0 / RETAIL_ANIMATION_HZ);
        }
        assert!((sim.landing_average_velocity_y - projection.touchdown_velocity_y).abs() < 1.0e-5);

        step_retail_animation_signals(&mut sim, 1.0 / RETAIL_ANIMATION_HZ);
        assert!((sim.landing_average_velocity_y - projection.touchdown_velocity_y).abs() < 1.0e-5);
    }

    #[test]
    fn touchdown_preserves_last_airborne_avgvely_sample() {
        let projection = retail_landing_projection_fixture(6.0 / RETAIL_ANIMATION_HZ);
        let mut sim = SkateSim::default();
        begin_measured_ollie_pop(&mut sim, 6.0 / RETAIL_ANIMATION_HZ);
        let touchdown = sim.pop_motion.as_ref().unwrap().touchdown_seconds;
        {
            let motion = sim.pop_motion.as_mut().unwrap();
            motion.fixed_steps_since_flick = ((touchdown - DT) * FIXED_HZ as f32).round() as u16;
            motion.elapsed_since_flick_seconds = touchdown - DT;
            let pose = retail_released_carrier(motion.charge_seconds, touchdown - DT);
            motion.board_height = pose.board_height;
            motion.skater_height = pose.skater_height;
            motion.separated_from_ground = true;
        }
        sim.landing_average_velocity_y = 3.75;
        step_retail_pop_carrier(&mut sim, DT);

        assert!(
            sim.pop_motion
                .as_ref()
                .is_some_and(|motion| motion.touched_down)
        );
        assert!(sim.landed_this_step);
        assert_eq!(
            sim.landing_average_velocity_y,
            projection.touchdown_velocity_y
        );
    }

    #[test]
    fn six_frame_ollie_reproduces_isolated_board_arc_and_post_land_recovery() {
        let ground = SkateGround::default();
        let mut sim = SkateSim::default();
        begin_measured_ollie_pop(&mut sim, 6.0 / RETAIL_ANIMATION_HZ);

        let mut apex = sim.position.y;
        let mut saw_separation = false;
        let mut saw_touchdown = false;
        for _ in 0..360 {
            if sim
                .pop_motion
                .as_ref()
                .is_some_and(|motion| motion.separated_from_ground && !motion.touched_down)
            {
                step_airborne_planar_motion(&mut sim, DT);
            } else {
                step_velocity(&mut sim, DT, false, false, false);
            }
            step_retail_pop_carrier(&mut sim, DT);
            apply_ground_contact(&mut sim, &ground);
            apex = apex.max(sim.position.y);
            saw_separation |= !sim.ground_contact_valid;
            saw_touchdown |= sim.landed_this_step;
            if sim.pop_motion.is_none() {
                break;
            }
        }

        assert!(saw_separation);
        assert!(saw_touchdown);
        assert!(sim.ground_contact_valid);
        assert_eq!(sim.position.y, 0.0);
        assert_eq!(sim.velocity.y, 0.0);
        assert!((apex - 0.861_37).abs() < 0.002, "apex={apex}");
    }

    #[test]
    fn touchdown_preserves_raw_carrier_but_never_drives_board_below_ground() {
        let mut sim = SkateSim::default();
        begin_measured_ollie_pop(&mut sim, 30.0 / RETAIL_ANIMATION_HZ);

        let mut saw_negative_raw_recovery = false;
        while sim.pop_motion.is_some() {
            step_retail_pop_carrier(&mut sim, DT);
            if let Some(motion) = sim.pop_motion.as_ref() {
                if motion.touched_down && motion.board_height < 0.0 {
                    saw_negative_raw_recovery = true;
                }
                assert!(
                    sim.position.y >= motion.ground_height,
                    "collision-resolved board root penetrated by {} m",
                    motion.ground_height - sim.position.y
                );
            }
        }

        assert!(
            saw_negative_raw_recovery,
            "the isolated post-contact channel must remain available as evidence"
        );
        assert_eq!(sim.position.y, 0.0);
        assert_eq!(sim.velocity.y, 0.0);
    }

    #[test]
    fn separated_pop_preserves_planar_momentum_without_ground_drag() {
        let mut sim = SkateSim {
            position: Vec3::new(1.0, 0.1, -2.0),
            velocity: Vec3::new(3.0, 2.0, -4.0),
            ..default()
        };
        begin_measured_ollie_pop(&mut sim, 6.0 / RETAIL_ANIMATION_HZ);
        sim.pop_motion.as_mut().unwrap().separated_from_ground = true;

        step_airborne_planar_motion(&mut sim, DT);
        step_retail_pop_carrier(&mut sim, DT);

        assert_eq!(sim.position.x, 1.0 + 3.0 * DT);
        assert_eq!(sim.position.z, -2.0 - 4.0 * DT);
        assert_eq!(sim.velocity.x, 3.0);
        assert_eq!(sim.velocity.z, -4.0);
    }

    #[test]
    fn anticipation_to_ollie_uses_the_recovered_point_zero_five_handoff() {
        let mut sim = SkateSim::default();
        let mut anticipation = AnticipationRuntime::begin(AnticipationSide::Tail);
        anticipation.step(6.0 / RETAIL_ANIMATION_HZ);
        sim.anticipation = Some(anticipation);

        assert!(begin_verified_endpoint_trick(&mut sim, "Ollie"));
        let handoff = sim.trick_handoff.as_ref().unwrap();
        assert_eq!(
            handoff.duration_seconds.to_bits(),
            ANTICIPATION_TO_TRICK_BLEND_SECONDS.to_bits()
        );
        let initial = sim.action_animation_state();
        assert!(
            initial
                .samples
                .iter()
                .any(|sample| sample.clip.starts_with("R_ANTIC_"))
        );
        assert!(
            initial
                .samples
                .iter()
                .all(|sample| sample.clip != "OLLIE_LOW_G" || sample.weight == 0.0)
        );

        sim.trick_handoff.as_mut().unwrap().elapsed_seconds =
            ANTICIPATION_TO_TRICK_BLEND_SECONDS * 0.5;
        let midpoint = sim.action_animation_state();
        assert!(
            midpoint
                .samples
                .iter()
                .any(|sample| sample.clip.starts_with("R_ANTIC_") && sample.weight > 0.0)
        );
        assert!(
            midpoint
                .samples
                .iter()
                .any(|sample| sample.clip == "OLLIE_LOW_G" && sample.weight > 0.0)
        );
    }

    #[test]
    fn held_tail_intent_hands_landing_directly_to_anticipation() {
        let mut sim = SkateSim::default();
        begin_recovered_flat_ground_landing(&mut sim, None);
        assert!(sim.landing.is_some());
        let mut input = SkateInput {
            canonical_pad: CanonicalPadState {
                right_y: i16::MIN,
                ..default()
            },
            ..default()
        };

        step_recovered_landing(&mut sim, &mut input, DT, false);

        assert!(sim.landing.is_none());
        assert_eq!(
            sim.anticipation.as_ref().map(|runtime| runtime.side),
            Some(AnticipationSide::Tail)
        );
        assert_eq!(
            sim.trick_handoff
                .as_ref()
                .map(|handoff| handoff.duration_seconds.to_bits()),
            Some(0.8_f32.to_bits())
        );
    }

    #[test]
    fn held_push_survives_landing_and_obeys_retail_point_one_gate() {
        let mut sim = SkateSim::default();
        begin_recovered_flat_ground_landing(&mut sim, None);
        assert!(sim.landing.is_some());
        let mut input = SkateInput {
            pending_push: Some(PushFoot::Regular),
            regular_push_held: true,
            ..default()
        };

        for _ in 0..11 {
            step_recovered_landing(&mut sim, &mut input, DT, false);
        }
        assert!(sim.landing.is_some());
        for _ in 0..2 {
            step_recovered_landing(&mut sim, &mut input, DT, false);
            if sim.landing.is_none() {
                break;
            }
        }

        assert!(sim.landing.is_none());
        assert_eq!(
            sim.push.as_ref().map(|push| push.foot),
            Some(PushFoot::Regular)
        );
        assert_eq!(input.pending_push, None);
        assert_eq!(
            sim.trick_handoff
                .as_ref()
                .map(|handoff| handoff.duration_seconds.to_bits()),
            Some(1.0_f32.to_bits())
        );
    }

    #[test]
    fn grounded_lt_enters_and_holds_the_authored_frontside_cycle() {
        let mut sim = SkateSim::default();
        tick_grab(&mut sim, true, false, 90);
        let playback = sim.grab.as_ref().unwrap();
        assert_eq!(playback.domain, GrabDomain::Ground);
        assert_eq!(playback.runtime.identity, GrabIdentity::Fs);
        assert_eq!(playback.runtime.phase, GrabPhase::Cycle);
        assert_eq!(playback.requested_resource(), Some("GR_GROUND_N_FS_0_CYC"));
        assert_eq!(sim.active_grab_hands(), Some(PhysicalGrabHands::Left));
        assert!(sim.basic_trick.is_none());
        assert!(sim.pop_motion.is_none());
        assert_eq!(sim.board_authority, BoardAuthority::Physics);
    }

    #[test]
    fn grounded_rt_enters_and_holds_the_authored_backside_cycle() {
        let mut sim = SkateSim::default();
        tick_grab(&mut sim, false, true, 90);
        let playback = sim.grab.as_ref().unwrap();
        assert_eq!(playback.domain, GrabDomain::Ground);
        assert_eq!(playback.runtime.identity, GrabIdentity::Bs);
        assert_eq!(playback.runtime.phase, GrabPhase::Cycle);
        assert_eq!(playback.requested_resource(), Some("GR_GROUND_N_BS_0_CYC"));
        assert_eq!(sim.active_grab_hands(), Some(PhysicalGrabHands::Right));
    }

    #[test]
    fn grounded_both_enters_the_authored_two_hand_cycle() {
        let mut sim = SkateSim::default();
        tick_grab(&mut sim, true, true, 90);
        let playback = sim.grab.as_ref().unwrap();
        assert_eq!(playback.domain, GrabDomain::Ground);
        assert_eq!(playback.runtime.identity, GrabIdentity::Double);
        assert_eq!(playback.runtime.phase, GrabPhase::Cycle);
        assert_eq!(playback.requested_resource(), Some("GR_GROUND_N_DBL_0_CYC"));
        assert_eq!(sim.active_grab_hands(), Some(PhysicalGrabHands::Both));
    }

    #[test]
    fn airborne_lt_rt_and_both_select_authored_air_cycles() {
        for (left, right, identity, clip, hands) in [
            (
                true,
                false,
                GrabIdentity::Fs,
                "GR_GRAB_N_FS_0_CYC",
                PhysicalGrabHands::Left,
            ),
            (
                false,
                true,
                GrabIdentity::Bs,
                "GR_GRAB_N_BS_0_CYC",
                PhysicalGrabHands::Right,
            ),
            (
                true,
                true,
                GrabIdentity::Double,
                "GR_GRAB_N_DBL_0_CYC",
                PhysicalGrabHands::Both,
            ),
        ] {
            let mut sim = SkateSim {
                ground_contact_valid: false,
                ground_surface_id: None,
                ..default()
            };
            tick_grab(&mut sim, left, right, 90);
            let playback = sim.grab.as_ref().unwrap();
            assert_eq!(playback.domain, GrabDomain::Air);
            assert_eq!(playback.runtime.identity, identity);
            assert_eq!(playback.runtime.phase, GrabPhase::Cycle);
            assert_eq!(playback.requested_resource(), Some(clip));
            assert_eq!(sim.active_grab_hands(), Some(hands));
            assert_eq!(sim.board_authority, BoardAuthority::Animation);
        }
    }

    #[test]
    fn stick_before_trigger_selects_every_directional_grab_family() {
        for (left, right, right_x, right_y, trick, clip) in [
            (
                true,
                false,
                0,
                i16::MAX,
                GrabTrick::Tail,
                "GR_TAILGRAB_N_BS_0_CYC",
            ),
            (
                false,
                true,
                0,
                i16::MAX,
                GrabTrick::Seatbelt,
                "GR_SEATBELTGRAB_N_0_CYC",
            ),
            (
                true,
                false,
                0,
                i16::MIN,
                GrabTrick::Crail,
                "GR_CRAILGRAB_N_0_CYC",
            ),
            (
                false,
                true,
                0,
                i16::MIN,
                GrabTrick::Nose,
                "GR_NOSEGRAB_N_BS_0_CYC",
            ),
            (
                true,
                false,
                i16::MAX,
                0,
                GrabTrick::Stale,
                "GR_STALEGRAB_N_0_CYC",
            ),
            (
                false,
                true,
                i16::MAX,
                0,
                GrabTrick::Mute,
                "GR_MUTEGRAB_N_0_CYC",
            ),
        ] {
            let mut sim = SkateSim {
                ground_contact_valid: false,
                ground_surface_id: None,
                ..default()
            };
            tick_grab_pad(
                &mut sim,
                CanonicalPadState {
                    right_x,
                    right_y,
                    ..default()
                },
                1,
            );
            tick_grab_pad(
                &mut sim,
                CanonicalPadState {
                    left_trigger: if left { u8::MAX } else { 0 },
                    right_trigger: if right { u8::MAX } else { 0 },
                    right_x,
                    right_y,
                    ..default()
                },
                120,
            );
            let playback = sim.grab.as_ref().unwrap();
            assert_eq!(playback.trick, trick);
            assert_eq!(playback.runtime.phase, GrabPhase::Cycle);
            assert_eq!(playback.requested_resource(), Some(clip));
        }
    }

    #[test]
    fn bevy_grab_leaf_clocks_consume_into_actions_once_and_preserve_out_speeds() {
        let mut sim = SkateSim {
            ground_contact_valid: false,
            ground_surface_id: None,
            ..default()
        };
        sim.begin_grab_trick(GrabTrick::Fs, GrabTweakDirection::Neutral, false)
            .unwrap();
        let playback = sim.grab.as_mut().unwrap();

        for (phase, trick, override_clip, expected) in [
            (GrabPhase::Into, GrabTrick::Fs, None, 1.0),
            (GrabPhase::Into, GrabTrick::Double, None, 1.0),
            (GrabPhase::Into, GrabTrick::Mute, None, 1.0),
            (GrabPhase::Into, GrabTrick::Crail, None, 1.0),
            (GrabPhase::Into, GrabTrick::Seatbelt, None, 1.0),
            (GrabPhase::Into, GrabTrick::Nose, None, 1.0),
            (
                GrabPhase::Into,
                GrabTrick::OneFootFs(crate::grab_graph::ReleasedFoot::Right),
                None,
                1.0,
            ),
            (GrabPhase::Out, GrabTrick::Fs, None, 2.0),
            (GrabPhase::Out, GrabTrick::Mute, None, 1.0),
            (GrabPhase::Out, GrabTrick::Nose, None, 1.0),
            (GrabPhase::Out, GrabTrick::NoFoot, None, 1.2),
            (GrabPhase::Out, GrabTrick::Airwalk, None, 1.2),
            (
                GrabPhase::Into,
                GrabTrick::Superman,
                Some("GR_DSMNT_N_NOFOOT_TO_SUPER"),
                1.3,
            ),
            (
                GrabPhase::Into,
                GrabTrick::NoFoot,
                Some("GR_DSMNT_N_SUPER_TO_NOFOOT"),
                1.0,
            ),
        ] {
            playback.runtime.phase = phase;
            playback.trick = trick;
            playback.phase_clip_override = override_clip;
            assert!(
                (playback.playback_speed() - expected).abs() < f32::EPSILON,
                "{phase:?} {trick:?} {override_clip:?}"
            );
        }

        playback.runtime.phase = GrabPhase::Into;
        playback.phase_clip_override = None;
        for (trick, clip) in [
            (GrabTrick::Fs, "GR_GRAB_N_FS_0_INTO"),
            (GrabTrick::Bs, "GR_GRAB_N_BS_0_INTO"),
            (GrabTrick::Double, "GR_GRAB_N_DBL_0_INTO"),
        ] {
            playback.trick = trick;
            assert_eq!(
                playback.phase_duration_seconds().map(f32::to_bits),
                grab_clip_duration_seconds(clip).map(f32::to_bits),
                "{trick:?}"
            );
        }
    }

    #[test]
    fn normal_grab_into_phases_hold_for_the_complete_authored_action() {
        for (grounded, trick, pad, clip) in [
            (
                true,
                GrabTrick::Fs,
                grab_pad(true, false),
                "GR_CROUCH2GRAB_N_FS_0_INTO",
            ),
            (
                false,
                GrabTrick::Fs,
                grab_pad(true, false),
                "GR_GRAB_N_FS_0_INTO",
            ),
            (
                false,
                GrabTrick::Double,
                grab_pad(true, true),
                "GR_GRAB_N_DBL_0_INTO",
            ),
        ] {
            let mut sim = SkateSim {
                ground_contact_valid: grounded,
                ground_surface_id: grounded.then_some(1),
                ..default()
            };
            sim.begin_grab_trick(trick, GrabTweakDirection::Neutral, false)
                .unwrap();

            let authored_duration = grab_clip_duration_seconds(clip).unwrap();
            let ticks = (authored_duration / DT).round() as usize;
            assert_eq!(
                sim.grab
                    .as_ref()
                    .unwrap()
                    .phase_duration_seconds()
                    .unwrap()
                    .to_bits(),
                authored_duration.to_bits(),
                "{trick:?} grounded={grounded}"
            );

            tick_grab_pad(&mut sim, pad, ticks - 1);
            assert_eq!(
                sim.grab.as_ref().unwrap().runtime.phase,
                GrabPhase::Into,
                "{trick:?} grounded={grounded}"
            );
            tick_grab_pad(&mut sim, pad, 1);
            assert_eq!(
                sim.grab.as_ref().unwrap().runtime.phase,
                GrabPhase::Cycle,
                "{trick:?} grounded={grounded}"
            );
        }
    }

    #[test]
    fn tweak_filter_matches_recovered_update_response() {
        let ordinary = grab_tweak_filter_config(GrabTrick::Fs).unwrap();
        assert_eq!(
            ordinary,
            GrabTweakFilterConfig {
                blend: 0.116,
                blend_out: 0.133,
                clamp_acceleration: None,
                clamp_velocity: 0.1,
            }
        );
        let (one_retail_step, first_velocity) = step_grab_tweak_filter(0.0, 0.0, false, ordinary);
        assert!((one_retail_step - 0.1).abs() < 1.0e-6);
        assert!((first_velocity - 0.1).abs() < 1.0e-6);

        let (mut filtered_in, mut velocity_in) = (0.0, 0.0);
        for _ in 0..6 {
            (filtered_in, velocity_in) =
                step_grab_tweak_filter(filtered_in, velocity_in, false, ordinary);
        }
        assert!((filtered_in - 0.511_461_2).abs() < 1.0e-6);

        let (mut filtered_out, mut velocity_out) = (0.0, 0.0);
        for _ in 0..6 {
            (filtered_out, velocity_out) =
                step_grab_tweak_filter(filtered_out, velocity_out, true, ordinary);
        }
        assert!((filtered_out - 0.543_799_94).abs() < 1.0e-6);
        assert!(filtered_out > filtered_in);

        let board_adjust = grab_tweak_filter_config(GrabTrick::Nose).unwrap();
        assert_eq!(
            board_adjust,
            GrabTweakFilterConfig {
                blend: 0.25,
                blend_out: 0.08,
                clamp_acceleration: Some(0.03),
                clamp_velocity: 0.2,
            }
        );
        let (mut board_progress, mut board_velocity) = (0.0, 0.0);
        for _ in 0..6 {
            (board_progress, board_velocity) =
                step_grab_tweak_filter(board_progress, board_velocity, false, board_adjust);
        }
        assert!((board_progress - 0.5875).abs() < 1.0e-6);
    }

    #[test]
    fn tweak_filter_outputs_at_60_hz_without_shortening_the_30_hz_response() {
        for (trick, expected) in [
            (GrabTrick::Fs, [0.05, 0.1, 0.15, 0.2]),
            (GrabTrick::Nose, [0.015, 0.03, 0.06, 0.09]),
        ] {
            let config = grab_tweak_filter_config(trick).unwrap();
            let mut retail_progress = 0.0;
            let mut retail_velocity = 0.0;
            let mut pending = None;
            let outputs: [f32; 4] = std::array::from_fn(|_| {
                step_grab_tweak_filter_output(
                    &mut retail_progress,
                    &mut retail_velocity,
                    &mut pending,
                    false,
                    config,
                )
            });

            for (actual, expected) in outputs.into_iter().zip(expected) {
                assert!((actual - expected).abs() < 1.0e-6, "{trick:?}");
            }

            let (first_retail_step, first_retail_velocity) =
                step_grab_tweak_filter(0.0, 0.0, false, config);
            let (second_retail_step, _) =
                step_grab_tweak_filter(first_retail_step, first_retail_velocity, false, config);
            assert!((retail_progress - second_retail_step).abs() < 1.0e-6);
            assert!(pending.is_none());
        }
    }

    #[test]
    fn post_admission_tweak_keeps_cycle_phase_and_filters_the_pose_change() {
        let mut sim = SkateSim {
            ground_contact_valid: false,
            ground_surface_id: None,
            ..default()
        };
        tick_grab(&mut sim, true, false, 90);
        let playback = sim.grab.as_mut().unwrap();
        playback.phase_time_seconds = 0.4;

        tick_grab_pad(
            &mut sim,
            CanonicalPadState {
                left_trigger: u8::MAX,
                right_x: i16::MAX,
                ..default()
            },
            1,
        );
        let playback = sim.grab.as_ref().unwrap();
        assert_eq!(playback.tweak, GrabTweakDirection::Right);
        assert!((playback.phase_time_seconds - (0.4 + DT)).abs() < 1.0e-6);
        assert_eq!(playback.tweak_filter_progress, Some(0.0));
        let initial = playback.animation_state().unwrap().unwrap();
        assert!(initial.samples.iter().any(|sample| {
            sample.clip == "GR_GRAB_N_FS_0_CYC" && (sample.weight - 1.0).abs() < 1.0e-6
        }));
        assert!(initial.samples.iter().any(|sample| {
            sample.clip == "GR_TKNEE_N_FS_0_CYC" && sample.weight.abs() < 1.0e-6
        }));
        assert!(
            (initial.samples[0].seek_time_seconds - initial.samples[1].seek_time_seconds).abs()
                < 1.0e-6
        );

        tick_grab_pad(
            &mut sim,
            CanonicalPadState {
                left_trigger: u8::MAX,
                right_x: i16::MAX,
                ..default()
            },
            2,
        );
        let before_graph_tick = sim
            .grab
            .as_ref()
            .unwrap()
            .animation_state()
            .unwrap()
            .unwrap();
        assert!(before_graph_tick.samples.iter().any(|sample| {
            sample.clip == "GR_GRAB_N_FS_0_CYC" && (sample.weight - 0.95).abs() < 1.0e-6
        }));
        assert!(before_graph_tick.samples.iter().any(|sample| {
            sample.clip == "GR_TKNEE_N_FS_0_CYC" && (sample.weight - 0.05).abs() < 1.0e-6
        }));

        tick_grab_pad(
            &mut sim,
            CanonicalPadState {
                left_trigger: u8::MAX,
                right_x: i16::MAX,
                ..default()
            },
            2,
        );
        let filtered = sim
            .grab
            .as_ref()
            .unwrap()
            .animation_state()
            .unwrap()
            .unwrap();
        assert!(filtered.samples.iter().any(|sample| {
            sample.clip == "GR_GRAB_N_FS_0_CYC" && (sample.weight - 0.9).abs() < 1.0e-6
        }));
        assert!(filtered.samples.iter().any(|sample| {
            sample.clip == "GR_TKNEE_N_FS_0_CYC" && (sample.weight - 0.1).abs() < 1.0e-6
        }));
        assert!(
            (filtered.samples[0].seek_time_seconds - filtered.samples[1].seek_time_seconds).abs()
                < 1.0e-6
        );

        step_basic_grab_controls(
            &mut sim,
            CanonicalPadState {
                left_trigger: u8::MAX,
                ..default()
            },
            0.0,
        );
        let reverse_start = sim
            .grab
            .as_ref()
            .unwrap()
            .animation_state()
            .unwrap()
            .unwrap();
        for before in &filtered.samples {
            let after = reverse_start
                .samples
                .iter()
                .find(|sample| sample.clip == before.clip)
                .unwrap();
            assert!((after.weight - before.weight).abs() < 1.0e-6);
            assert!((after.seek_time_seconds - before.seek_time_seconds).abs() < 1.0e-6);
        }

        tick_grab_pad(
            &mut sim,
            CanonicalPadState {
                left_trigger: u8::MAX,
                ..default()
            },
            4,
        );
        let filtering_out = sim
            .grab
            .as_ref()
            .unwrap()
            .animation_state()
            .unwrap()
            .unwrap();
        assert!(filtering_out.samples.iter().any(|sample| {
            sample.clip == "GR_TKNEE_N_FS_0_CYC" && (sample.weight - 0.09).abs() < 1.0e-6
        }));
    }

    #[test]
    fn tweaked_release_preserves_the_live_pose_and_fades_hand_ik_with_out_blend() {
        let mut sim = SkateSim {
            ground_contact_valid: false,
            ground_surface_id: None,
            ..default()
        };
        tick_grab(&mut sim, true, false, 90);
        sim.trick_handoff = None;
        tick_grab_pad(
            &mut sim,
            CanonicalPadState {
                left_trigger: u8::MAX,
                right_x: i16::MAX,
                ..default()
            },
            5,
        );
        let held = sim.action_animation_state();
        assert!(held.samples.iter().any(|sample| {
            sample.clip == "GR_GRAB_N_FS_0_CYC" && (sample.weight - 0.9).abs() < 1.0e-6
        }));
        assert!(held.samples.iter().any(|sample| {
            sample.clip == "GR_TKNEE_N_FS_0_CYC" && (sample.weight - 0.1).abs() < 1.0e-6
        }));

        step_basic_grab_controls(&mut sim, CanonicalPadState::default(), 0.0);
        let playback = sim.grab.as_ref().unwrap();
        assert_eq!(playback.runtime.phase, GrabPhase::Out);
        assert_eq!(sim.active_grab_hands(), None);
        assert_eq!(
            sim.active_grab_hand_ik()
                .map(|(hands, weight)| (hands, weight.to_bits())),
            Some((PhysicalGrabHands::Left, 1.0_f32.to_bits()))
        );
        let release = sim.action_animation_state();
        for before in &held.samples {
            let after = release
                .samples
                .iter()
                .find(|sample| sample.clip == before.clip)
                .unwrap();
            assert!((after.weight - before.weight).abs() < 1.0e-6);
            assert!((after.seek_time_seconds - before.seek_time_seconds).abs() < 1.0e-6);
        }
        assert!(
            release.samples.iter().any(|sample| {
                sample.clip == "GR_GRAB_N_FS_0_OUT" && sample.weight.abs() < 1.0e-6
            })
        );

        step_basic_grab_controls(&mut sim, CanonicalPadState::default(), 0.05);
        let (hands, midpoint_weight) = sim.active_grab_hand_ik().unwrap();
        assert_eq!(hands, PhysicalGrabHands::Left);
        assert!((midpoint_weight - 0.5).abs() < 1.0e-6);

        step_basic_grab_controls(&mut sim, CanonicalPadState::default(), 0.05);
        assert_eq!(sim.active_grab_hand_ik(), None);
        assert!(sim.grab.is_some());
    }

    #[test]
    fn trigger_before_stick_selects_authored_tweak_cycles_without_changing_family() {
        let cases = [
            (i16::MIN, 0, "GR_STIFFY_N_FS_0_CYC"),
            (i16::MAX, 0, "GR_TKNEE_N_FS_0_CYC"),
            (0, i16::MAX, "GR_NBONE_N_FS_0_CYC"),
            (0, i16::MIN, "GR_TBONE_N_FS_0_CYC"),
        ];
        for (right_x, right_y, clip) in cases {
            let mut sim = SkateSim {
                ground_contact_valid: false,
                ground_surface_id: None,
                ..default()
            };
            tick_grab(&mut sim, true, false, 90);
            tick_grab_pad(
                &mut sim,
                CanonicalPadState {
                    left_trigger: u8::MAX,
                    right_x,
                    right_y,
                    ..default()
                },
                2,
            );
            let playback = sim.grab.as_ref().unwrap();
            assert_eq!(playback.trick, GrabTrick::Fs);
            assert_eq!(playback.requested_resource(), Some(clip));
            assert!(playback.tweak_filter_progress.is_some());
            assert!(!playback.tweak_filter_sources.is_empty());
        }
    }

    #[test]
    fn face_button_grabs_select_authored_clips_and_release_the_proven_feet() {
        for (left, right, buttons, pre_y, trick, release, clip) in [
            (
                true,
                false,
                crate::grab_graph::XINPUT_GAMEPAD_B,
                0,
                GrabTrick::NoFoot,
                GrabFootRelease::Both,
                "GR_DSMNT_NOFOOT_FS_0_CYC",
            ),
            (
                false,
                true,
                crate::grab_graph::XINPUT_GAMEPAD_B,
                0,
                GrabTrick::Christ,
                GrabFootRelease::Both,
                "GR_DSMNT_CHRIST_BS_0_CYC",
            ),
            (
                true,
                false,
                crate::grab_graph::XINPUT_GAMEPAD_A,
                0,
                GrabTrick::OneFootFs(crate::grab_graph::ReleasedFoot::Right),
                GrabFootRelease::One(crate::grab_graph::ReleasedFoot::Right),
                "1FT_AIR_GRAB_N_FSR_0_CYC",
            ),
            (
                false,
                true,
                crate::grab_graph::XINPUT_GAMEPAD_X,
                i16::MIN,
                GrabTrick::OneFootNose(crate::grab_graph::ReleasedFoot::Left),
                GrabFootRelease::One(crate::grab_graph::ReleasedFoot::Left),
                "1FT_AIR_GRAB_N_NOSEL_0_CYC",
            ),
        ] {
            let mut sim = SkateSim {
                ground_contact_valid: false,
                ground_surface_id: None,
                ..default()
            };
            if pre_y != 0 {
                tick_grab_pad(
                    &mut sim,
                    CanonicalPadState {
                        right_y: pre_y,
                        ..default()
                    },
                    1,
                );
            }
            tick_grab_pad(
                &mut sim,
                CanonicalPadState {
                    left_trigger: if left { u8::MAX } else { 0 },
                    right_trigger: if right { u8::MAX } else { 0 },
                    right_y: pre_y,
                    buttons,
                    ..default()
                },
                120,
            );
            let playback = sim.grab.as_ref().unwrap();
            assert_eq!(playback.trick, trick);
            assert_eq!(sim.active_grab_foot_release(), release);
            assert_eq!(playback.requested_resource(), Some(clip));
        }
    }

    #[test]
    fn rocket_superdude_coffin_airwalk_and_tailwalk_use_their_authored_cycles() {
        for (left, right, buttons, pre_y, domain, trick, clip, authority) in [
            (
                true,
                true,
                0,
                i16::MIN,
                GrabDomain::Air,
                GrabTrick::Rocket,
                "GR_NOSEGRAB_ROCKETAIR_N_0_CYC",
                BoardAuthority::Animation,
            ),
            (
                true,
                true,
                crate::grab_graph::XINPUT_GAMEPAD_B,
                0,
                GrabDomain::Air,
                GrabTrick::Superman,
                "GR_DSMNT_SUPER_DBL_0_CYC",
                BoardAuthority::Physics,
            ),
            (
                false,
                true,
                crate::grab_graph::XINPUT_GAMEPAD_B,
                i16::MIN,
                GrabDomain::Air,
                GrabTrick::Airwalk,
                "2FT_AIR_GRAB_N_NOSE_0_CYC",
                BoardAuthority::Animation,
            ),
            (
                true,
                false,
                crate::grab_graph::XINPUT_GAMEPAD_B,
                i16::MAX,
                GrabDomain::Air,
                GrabTrick::Tailwalk,
                "2FT_AIR_GRAB_N_TAIL_0_CYC",
                BoardAuthority::Animation,
            ),
            (
                true,
                true,
                crate::grab_graph::XINPUT_GAMEPAD_A | crate::grab_graph::XINPUT_GAMEPAD_X,
                0,
                GrabDomain::Ground,
                GrabTrick::Coffin,
                "GR_GROUND_N_COFFIN_0_CYC",
                BoardAuthority::Physics,
            ),
        ] {
            let mut sim = SkateSim {
                ground_contact_valid: domain == GrabDomain::Ground,
                ground_surface_id: (domain == GrabDomain::Ground).then_some(1),
                ..default()
            };
            if pre_y != 0 {
                tick_grab_pad(
                    &mut sim,
                    CanonicalPadState {
                        right_y: pre_y,
                        ..default()
                    },
                    1,
                );
            }
            tick_grab_pad(
                &mut sim,
                CanonicalPadState {
                    left_trigger: if left { u8::MAX } else { 0 },
                    right_trigger: if right { u8::MAX } else { 0 },
                    right_y: pre_y,
                    buttons,
                    ..default()
                },
                150,
            );
            let playback = sim.grab.as_ref().unwrap();
            assert_eq!(playback.trick, trick);
            assert_eq!(playback.requested_resource(), Some(clip));
            assert_eq!(sim.board_authority, authority);
        }
    }

    #[test]
    fn held_face_button_variants_crossfade_without_restarting_the_grab_owner() {
        let mut sim = SkateSim {
            ground_contact_valid: false,
            ground_surface_id: None,
            ..default()
        };
        tick_grab(&mut sim, true, false, 90);
        let fs_cycle_time = sim.grab.as_ref().unwrap().phase_time_seconds;

        tick_grab_pad(
            &mut sim,
            CanonicalPadState {
                left_trigger: u8::MAX,
                buttons: crate::grab_graph::XINPUT_GAMEPAD_A,
                ..default()
            },
            1,
        );
        let one_foot = sim.grab.as_ref().unwrap();
        assert_eq!(
            one_foot.trick,
            GrabTrick::OneFootFs(crate::grab_graph::ReleasedFoot::Right)
        );
        assert_eq!(one_foot.runtime.phase, GrabPhase::Into);
        assert!(one_foot.blend_from.is_some());
        assert!(fs_cycle_time > one_foot.phase_time_seconds);

        tick_grab_pad(
            &mut sim,
            CanonicalPadState {
                left_trigger: u8::MAX,
                buttons: crate::grab_graph::XINPUT_GAMEPAD_A,
                ..default()
            },
            90,
        );
        assert_eq!(sim.grab.as_ref().unwrap().runtime.phase, GrabPhase::Cycle);

        tick_grab_pad(
            &mut sim,
            CanonicalPadState {
                left_trigger: u8::MAX,
                buttons: crate::grab_graph::XINPUT_GAMEPAD_B,
                ..default()
            },
            1,
        );
        let no_foot = sim.grab.as_ref().unwrap();
        assert_eq!(no_foot.trick, GrabTrick::NoFoot);
        assert_eq!(no_foot.runtime.phase, GrabPhase::Into);
        assert!(no_foot.blend_from.is_some());
    }

    #[test]
    fn no_foot_christ_and_superdude_use_authored_transition_leaves() {
        let mut sim = SkateSim {
            ground_contact_valid: false,
            ground_surface_id: None,
            ..default()
        };
        let no_foot_pad = CanonicalPadState {
            left_trigger: u8::MAX,
            buttons: crate::grab_graph::XINPUT_GAMEPAD_B,
            ..default()
        };
        tick_grab_pad(&mut sim, no_foot_pad, 120);
        assert_eq!(sim.grab.as_ref().unwrap().trick, GrabTrick::NoFoot);

        let super_pad = CanonicalPadState {
            left_trigger: u8::MAX,
            right_trigger: u8::MAX,
            buttons: crate::grab_graph::XINPUT_GAMEPAD_B,
            ..default()
        };
        tick_grab_pad(&mut sim, super_pad, 1);
        assert_eq!(
            sim.grab.as_ref().unwrap().requested_resource(),
            Some("GR_DSMNT_N_NOFOOT_TO_SUPER")
        );
        tick_grab_pad(&mut sim, super_pad, 120);
        assert_eq!(sim.grab.as_ref().unwrap().trick, GrabTrick::Superman);

        let christ_pad = CanonicalPadState {
            right_trigger: u8::MAX,
            buttons: crate::grab_graph::XINPUT_GAMEPAD_B,
            ..default()
        };
        tick_grab_pad(&mut sim, christ_pad, 1);
        assert_eq!(
            sim.grab.as_ref().unwrap().requested_resource(),
            Some("GR_DSMNT_N_SUPER_TO_CHRIST")
        );
    }

    #[test]
    fn held_directional_grab_crosses_touchdown_into_ground_cycle_without_pop() {
        let mut sim = SkateSim {
            ground_contact_valid: false,
            ground_surface_id: None,
            velocity: Vec3::new(2.0, -1.0, 3.0),
            ..default()
        };
        tick_grab_pad(
            &mut sim,
            CanonicalPadState {
                right_y: i16::MIN,
                ..default()
            },
            1,
        );
        tick_grab_pad(
            &mut sim,
            CanonicalPadState {
                right_trigger: u8::MAX,
                right_y: i16::MIN,
                ..default()
            },
            90,
        );
        assert_eq!(sim.grab.as_ref().unwrap().trick, GrabTrick::Nose);

        sim.ground_contact_valid = true;
        sim.ground_surface_id = Some(1);
        let velocity = sim.velocity;
        tick_grab_pad(
            &mut sim,
            CanonicalPadState {
                right_trigger: u8::MAX,
                right_y: i16::MIN,
                ..default()
            },
            1,
        );
        let playback = sim.grab.as_ref().unwrap();
        assert_eq!(playback.domain, GrabDomain::Ground);
        assert_eq!(playback.trick, GrabTrick::Bs);
        assert_eq!(playback.runtime.phase, GrabPhase::Cycle);
        assert_eq!(sim.velocity, velocity);
        assert!(sim.pop_motion.is_none());
    }

    #[test]
    fn airborne_grab_crossfades_from_the_live_air_action() {
        let mut sim = SkateSim {
            ground_contact_valid: false,
            ground_surface_id: None,
            ..default()
        };
        sim.begin_basic_trick(BasicTrickKind::Ollie, TrickHeightEndpoint::High);
        sim.step_basic_trick(
            DT,
            BasicTrickSignals {
                wheel_lifted: true,
                ..default()
            },
            None,
        );
        sim.step_basic_trick(
            0.2,
            BasicTrickSignals {
                established_airborne: true,
                ..default()
            },
            None,
        );
        assert_eq!(sim.action_animation_state().samples[0].clip, "OLLIE_HIGH_A");

        step_basic_grab_controls(&mut sim, grab_pad(false, true), DT);
        let initial = sim.action_animation_state();
        assert_eq!(initial.weight, 1.0);
        assert!(initial.samples.iter().any(|sample| {
            sample.clip == "OLLIE_HIGH_A" && (sample.weight - 1.0).abs() < 1.0e-6
        }));
        assert!(initial.samples.iter().any(|sample| {
            sample.clip == "GR_GRAB_N_BS_0_INTO" && sample.weight.abs() < 1.0e-6
        }));

        sim.trick_handoff.as_mut().unwrap().elapsed_seconds = 0.05;
        let midpoint = sim.action_animation_state();
        assert_eq!(midpoint.weight, 1.0);
        assert!(midpoint.samples.iter().any(|sample| {
            sample.clip == "OLLIE_HIGH_A" && (sample.weight - 0.5).abs() < 1.0e-6
        }));
        assert!(midpoint.samples.iter().any(|sample| {
            sample.clip == "GR_GRAB_N_BS_0_INTO" && (sample.weight - 0.5).abs() < 1.0e-6
        }));
    }

    #[test]
    fn grounded_grab_keeps_the_recovered_point_one_entry_blend() {
        let mut sim = SkateSim::default();
        step_basic_grab_controls(&mut sim, grab_pad(true, false), DT);

        let initial = sim.action_animation_state();
        assert!(initial.weight.abs() < 1.0e-6);
        sim.trick_handoff.as_mut().unwrap().elapsed_seconds = 0.05;
        let midpoint = sim.action_animation_state();
        assert!((midpoint.weight - 0.5).abs() < 1.0e-6);
        assert!(midpoint.samples.iter().any(|sample| {
            sample.clip == "GR_CROUCH2GRAB_N_FS_0_INTO" && (sample.weight - 0.5).abs() < 1.0e-6
        }));
    }

    #[test]
    fn single_double_single_transitions_use_authored_leaves_without_restart() {
        let mut sim = SkateSim::default();
        tick_grab(&mut sim, true, false, 90);
        tick_grab(&mut sim, true, true, 1);
        let to_double = sim.grab.as_ref().unwrap();
        assert_eq!(to_double.runtime.phase, GrabPhase::ToDouble);
        assert_eq!(
            to_double.requested_resource(),
            Some("GR_GRAB_N_FS2DBL_0_TR")
        );
        assert!(to_double.blend_from.is_some());
        assert_eq!(sim.active_grab_hands(), Some(PhysicalGrabHands::Both));

        tick_grab(&mut sim, true, true, 60);
        assert_eq!(
            sim.grab.as_ref().map(|grab| grab.runtime.identity),
            Some(GrabIdentity::Double)
        );
        tick_grab(&mut sim, false, true, 1);
        let from_double = sim.grab.as_ref().unwrap();
        assert_eq!(from_double.runtime.phase, GrabPhase::FromDouble);
        assert_eq!(
            from_double.requested_resource(),
            Some("GR_GRAB_N_DBL2BS_0_TR")
        );
        assert_eq!(sim.active_grab_hands(), Some(PhysicalGrabHands::Both));
        tick_grab(&mut sim, false, true, 60);
        assert_eq!(
            sim.grab
                .as_ref()
                .map(|grab| (grab.runtime.identity, grab.runtime.phase)),
            Some((GrabIdentity::Bs, GrabPhase::Cycle))
        );
    }

    #[test]
    fn held_grab_persists_and_release_plays_out_then_clears() {
        let mut sim = SkateSim::default();
        tick_grab(&mut sim, true, false, 360);
        assert_eq!(
            sim.grab.as_ref().map(|grab| grab.runtime.phase),
            Some(GrabPhase::Cycle)
        );
        tick_grab(&mut sim, false, false, 1);
        let out = sim.grab.as_ref().unwrap();
        assert_eq!(out.runtime.phase, GrabPhase::Out);
        assert_eq!(out.requested_resource(), Some("GR_GROUND_N_FS_0_OUT"));
        assert_eq!(sim.active_grab_hands(), None);
        tick_grab(&mut sim, false, false, 90);
        assert!(sim.grab.is_none());
        assert_eq!(sim.board_authority, BoardAuthority::Physics);
    }

    #[test]
    fn held_trigger_crosses_takeoff_and_landing_without_being_eaten() {
        let mut sim = SkateSim::default();
        tick_grab(&mut sim, true, false, 90);
        sim.ground_contact_valid = false;
        sim.ground_surface_id = None;
        tick_grab(&mut sim, true, false, 1);
        assert_eq!(
            sim.grab.as_ref().map(|grab| (
                grab.domain,
                grab.runtime.phase,
                grab.requested_resource()
            )),
            Some((
                GrabDomain::Air,
                GrabPhase::Cycle,
                Some("GR_GRAB_N_FS_0_CYC")
            ))
        );

        sim.ground_contact_valid = true;
        sim.ground_surface_id = Some(1);
        sim.landed_this_step = true;
        tick_grab(&mut sim, true, false, 1);
        assert_eq!(
            sim.grab.as_ref().map(|grab| (
                grab.domain,
                grab.runtime.phase,
                grab.requested_resource()
            )),
            Some((
                GrabDomain::Ground,
                GrabPhase::Cycle,
                Some("GR_GROUND_N_FS_0_CYC")
            ))
        );
        assert!(sim.landing.is_none());
    }

    #[test]
    fn grab_controls_do_not_change_velocity_heading_or_pop_carrier() {
        let mut sim = SkateSim {
            velocity: Vec3::new(2.5, 0.0, -1.25),
            yaw: 0.42,
            ..default()
        };
        let velocity = sim.velocity;
        let yaw = sim.yaw;
        tick_grab(&mut sim, true, true, 90);
        assert_eq!(sim.velocity, velocity);
        assert_eq!(sim.yaw, yaw);
        assert!(sim.pop_motion.is_none());
    }

    #[test]
    fn landing_provider_drives_basic_trick_handoff_and_exact_urgent_exit() {
        let mut sim = SkateSim::default();
        sim.begin_basic_trick(BasicTrickKind::Ollie, TrickHeightEndpoint::Low);
        let parameters = StraightLandingParameters {
            posture: LandingPosture::Aggressive,
            variant: LandingVariant::Three,
        };
        let admission = sim.arbitrate_and_begin_landing(
            FilteredPhysicsState::Ground,
            Some(false),
            Some(false),
            Some(LandingTypeCode::STRAIGHT),
            Some(parameters),
        );
        assert_eq!(admission, LandingAdmission::Enter(LandingQuality::Straight));
        assert_eq!(
            sim.basic_trick.as_ref().unwrap().runtime.phase,
            BasicTrickPhase::Landing {
                resource: LandingAnimationResource::Straight
            }
        );
        assert_eq!(
            sim.landing.as_ref().unwrap().requested_resource(),
            "BLEND_LAND"
        );
        assert_eq!(
            sim.landing_animation_state().unwrap().unwrap().samples[0].clip,
            "L_LAND_HIGH_AGGR_3_N"
        );
        assert!(sim.set_landing_variant(2).unwrap());

        let decision = sim
            .step_landing(
                DT,
                LandingTransitionSignals {
                    physics_wants_runout: Some(true),
                    ..default()
                },
            )
            .unwrap();
        assert!(matches!(
            decision,
            LandingTransitionDecision::Take(crate::landing_graph::LandingTransition {
                target: crate::landing_graph::LandingTarget::Wipeout,
                ..
            })
        ));
        assert!(sim.landing.is_none());
    }

    #[test]
    fn explicit_non_straight_provider_axes_select_decoded_physical_leaves() {
        use crate::landing_animation::{
            LandingCompression, LandingImpact, LandingSide, NonStraightLandingAxes,
        };

        let axes = NonStraightLandingAxes {
            side: LandingSide::Frontside,
            compression: LandingCompression::High,
            impact: Some(LandingImpact::Low),
        };

        let mut nice = SkateSim::default();
        assert_eq!(
            nice.arbitrate_and_begin_landing(
                FilteredPhysicsState::Ground,
                Some(false),
                Some(false),
                Some(LandingTypeCode::SPIN),
                None,
            ),
            LandingAdmission::Enter(LandingQuality::Spin)
        );
        nice.set_non_straight_landing_axes(axes).unwrap();
        assert_eq!(
            nice.landing_animation_state().unwrap().unwrap().samples[0].clip,
            "L_NICE_FS_HCOM_HSP_LIMP"
        );
        assert_eq!(
            nice.landing
                .as_ref()
                .unwrap()
                .authored_duration_seconds()
                .unwrap(),
            47.0 / 60.0
        );
        let mut input = SkateInput::default();
        step_recovered_landing(&mut nice, &mut input, DT, false);
        assert!(
            nice.landing.is_some(),
            "Nice must not expire after one fixed step"
        );

        let mut sketchy = SkateSim::default();
        assert_eq!(
            sketchy.arbitrate_and_begin_landing(
                FilteredPhysicsState::Ground,
                Some(false),
                Some(false),
                Some(LandingTypeCode::SKETCHY),
                None,
            ),
            LandingAdmission::Enter(LandingQuality::Sketchy)
        );
        sketchy.set_non_straight_landing_axes(axes).unwrap();
        sketchy.set_landing_variant(3).unwrap();
        assert_eq!(
            sketchy.landing_animation_state().unwrap().unwrap().samples[0].clip,
            "L_SKETCH_FS_HCOM_LIMP3"
        );
        assert_eq!(
            sketchy
                .landing
                .as_ref()
                .unwrap()
                .authored_duration_seconds()
                .unwrap(),
            135.0 / 60.0
        );
        step_recovered_landing(&mut sketchy, &mut input, DT, false);
        assert!(
            sketchy.landing.is_some(),
            "Sketchy must not expire after one fixed step"
        );
    }

    #[test]
    fn neutral_fixture_is_not_invalidated_by_accumulated_float_noise() {
        let mut sim = SkateSim::default();
        sim.body_spin_angle = f32::EPSILON;
        assert!(!sim.airborne_body_spin_input_observed);

        begin_recovered_flat_ground_landing(&mut sim, None);

        assert_eq!(
            sim.landing.as_ref().map(|landing| landing.runtime.quality),
            Some(LandingQuality::Straight)
        );
    }

    #[test]
    fn automatic_route_uses_retail_classifier_and_never_cycles_ordinary_landings() {
        for _ in 0..4 {
            let mut ordinary = SkateSim {
                velocity: Vec3::new(0.0, 0.0, 4.0),
                ..default()
            };
            begin_recovered_flat_ground_landing(&mut ordinary, None);
            assert_eq!(
                ordinary
                    .landing
                    .as_ref()
                    .map(|landing| landing.runtime.quality),
                Some(LandingQuality::Straight)
            );
            assert_eq!(
                ordinary.last_landing_decision_input.unwrap().provider_code,
                Some(LandingTypeCode::STRAIGHT)
            );
        }

        let mut forced = SkateSim::default();
        begin_recovered_flat_ground_landing(&mut forced, Some(LandingQuality::Sketchy));
        assert_eq!(
            forced
                .landing
                .as_ref()
                .map(|landing| landing.runtime.quality),
            Some(LandingQuality::Sketchy)
        );
        assert!(forced.trick_handoff.is_some());

        let mut off_axis = SkateSim {
            velocity: Vec3::new(0.0, 0.0, 4.0),
            yaw: -0.5,
            ..default()
        };
        begin_recovered_flat_ground_landing(&mut off_axis, None);
        assert_eq!(
            off_axis.last_landing_decision_input.unwrap().provider_code,
            Some(LandingTypeCode::SKETCHY)
        );
        assert_eq!(
            off_axis
                .landing
                .as_ref()
                .map(|landing| landing.runtime.quality),
            Some(LandingQuality::Sketchy)
        );
        assert!(off_axis.trick_handoff.is_some());
    }

    #[test]
    fn measured_pop_landing_always_resolves_authored_tree_clips() {
        for (yaw, rotation, expected) in [
            (0.0, 0.0, LandingQuality::Straight),
            (-0.5, 0.0, LandingQuality::Sketchy),
            (0.5, 0.5, LandingQuality::Spin),
        ] {
            let mut sim = SkateSim {
                velocity: Vec3::new(0.0, 0.0, 4.0),
                yaw,
                body_spin_angle: rotation,
                landing_average_velocity_y: 3.681_793,
                ..default()
            };
            begin_measured_ollie_pop(&mut sim, 6.0 / RETAIL_ANIMATION_HZ);
            // begin_measured_ollie_pop preserves planar velocity and the
            // measured provider charge used for DISTTOCOG.
            begin_recovered_flat_ground_landing(&mut sim, None);

            let playback = sim.landing.as_ref().unwrap();
            assert_eq!(playback.runtime.quality, expected);
            assert!(playback.tree_parameters.is_some());
            let state = playback.animation_state().unwrap();
            assert!(!state.samples.is_empty());
            assert!(state.samples.iter().all(|sample| {
                sample.weight > 0.0
                    && (crate::trick_catalog::physical_clip_by_name(&sample.clip).is_some()
                        || crate::landing_animation::decoded_landing_clip_by_name(&sample.clip)
                            .is_some())
            }));
            assert!(
                (state
                    .samples
                    .iter()
                    .map(|sample| sample.weight)
                    .sum::<f32>()
                    - 1.0)
                    .abs()
                    < 1.0e-5
            );
            assert!(sim.trick_handoff.is_some());
        }
    }

    #[test]
    fn retail_avgvely_multiblend_and_andale_curve_match_write_watch_fixture() {
        let blend = straight_landing_blend(3.797_149_4);
        let expected_raw = (3.797_149_4 - RETAIL_LANDING_AVG_VELOCITY_LOW)
            / (RETAIL_LANDING_AVG_VELOCITY_HIGH - RETAIL_LANDING_AVG_VELOCITY_LOW);
        assert!((expected_raw - 0.336_490_78).abs() < 1.0e-7);
        assert_eq!(blend.compression_weight, 1.0);
        assert!((blend.high_landing_weight - 0.296_057_02).abs() < 1.0e-7);
        assert_eq!(
            straight_landing_blend(RETAIL_LANDING_AVG_VELOCITY_LOW).high_landing_weight,
            0.0
        );
        assert_eq!(
            straight_landing_blend(RETAIL_LANDING_AVG_VELOCITY_HIGH).high_landing_weight,
            1.0
        );
    }

    #[test]
    fn flat_touchdown_crossfades_airborne_pose_into_recovered_landing_leaf() {
        let mut sim = SkateSim::default();
        sim.begin_basic_trick(BasicTrickKind::Ollie, TrickHeightEndpoint::Low);
        // Runtime write-watch fixture: AVGVELY=3.7971494 maps through the
        // 2.68..6.0 MultiBlend and Andale endpoint curve.
        sim.landing_average_velocity_y = 3.797_149_4;
        let expected_blend = straight_landing_blend(sim.landing_average_velocity_y);

        begin_recovered_flat_ground_landing(&mut sim, None);

        let landing = sim.landing.as_ref().unwrap();
        assert_eq!(landing.selected_variant, Some(2));
        assert_eq!(
            landing.straight_landing_parameters,
            Some(StraightLandingParameters {
                posture: LandingPosture::Aggressive,
                variant: LandingVariant::Three,
            })
        );
        assert_eq!(landing.straight_landing_blend, Some(expected_blend));
        let impact = sim.action_animation_state();
        assert_eq!(impact.weight, 1.0);
        assert!(
            impact
                .samples
                .iter()
                .any(|sample| sample.clip == "OLLIE_LOW_G" && sample.weight == 1.0)
        );
        assert!(
            impact
                .samples
                .iter()
                .any(|sample| sample.clip == "L_LAND_HIGH_AGGR_3_N" && sample.weight == 0.0)
        );

        let mut input = SkateInput::default();
        for _ in 0..9 {
            step_anticipation_and_handoff(&mut sim, DT);
            step_recovered_landing(&mut sim, &mut input, DT, false);
        }
        let midpoint = sim.action_animation_state();
        let source_weight = midpoint
            .samples
            .iter()
            .find(|sample| sample.clip == "OLLIE_LOW_G")
            .unwrap()
            .weight;
        let limp_weight = midpoint
            .samples
            .iter()
            .find(|sample| sample.clip == "L_HCOM_LIMP_3")
            .unwrap()
            .weight;
        let high_landing_weight = midpoint
            .samples
            .iter()
            .find(|sample| sample.clip == "L_LAND_HIGH_AGGR_3_N")
            .unwrap()
            .weight;
        let low_com_weight = midpoint
            .samples
            .iter()
            .find(|sample| sample.clip == "L_LCOM_3")
            .unwrap()
            .weight;
        assert!((source_weight - 0.5).abs() < 1.0e-6);
        assert!(low_com_weight.abs() < 1.0e-6);
        assert!((limp_weight - 0.5 * (1.0 - expected_blend.high_landing_weight)).abs() < 1.0e-6);
        assert!((high_landing_weight - 0.5 * expected_blend.high_landing_weight).abs() < 1.0e-6);
        assert!(
            (source_weight + low_com_weight + limp_weight + high_landing_weight - 1.0).abs()
                < 1.0e-6
        );

        for _ in 0..9 {
            step_anticipation_and_handoff(&mut sim, DT);
            step_recovered_landing(&mut sim, &mut input, DT, false);
        }
        let settled = sim.action_animation_state();
        assert!(sim.trick_handoff.is_none());
        assert_eq!(settled.samples.len(), 3);
        assert_eq!(settled.samples[0].clip, "L_LCOM_3");
        assert_eq!(settled.samples[0].weight, 0.0);
        assert_eq!(settled.samples[1].clip, "L_HCOM_LIMP_3");
        assert!(
            (settled.samples[1].weight - (1.0 - expected_blend.high_landing_weight)).abs() < 1.0e-6
        );
        assert_eq!(settled.samples[2].clip, "L_LAND_HIGH_AGGR_3_N");
        assert!((settled.samples[2].weight - expected_blend.high_landing_weight).abs() < 1.0e-6);
    }

    #[test]
    fn landing_recovery_uses_will_expire_window_and_fades_back_to_riding() {
        let mut sim = SkateSim::default();
        sim.begin_basic_trick(BasicTrickKind::Ollie, TrickHeightEndpoint::Low);
        begin_recovered_flat_ground_landing(&mut sim, None);
        sim.trick_handoff = None;
        assert!(
            (sim.landing
                .as_ref()
                .unwrap()
                .authored_duration_seconds()
                .unwrap()
                - 69.0 / 60.0)
                .abs()
                < 1.0e-6
        );

        let mut input = SkateInput::default();
        for _ in 0..180 {
            step_recovered_landing(&mut sim, &mut input, DT, false);
            if sim.landing.is_none() {
                break;
            }
        }

        assert!(
            sim.landing.is_none(),
            "landing remained at {:?}",
            sim.landing
                .as_ref()
                .map(|landing| landing.runtime.elapsed_seconds)
        );
        assert!(sim.basic_trick.is_none());
        assert_eq!(sim.board_authority, BoardAuthority::Physics);
        let exit = sim.action_animation_state();
        assert_eq!(exit.weight, 1.0);
        assert_eq!(exit.samples.len(), 3);
        assert_eq!(exit.samples[0].clip, "L_LCOM_3");
        assert_eq!(exit.samples[1].clip, "L_HCOM_LIMP_3");
        assert_eq!(exit.samples[2].clip, "L_LAND_HIGH_AGGR_3_N");

        for _ in 0..6 {
            step_anticipation_and_handoff(&mut sim, DT);
        }
        let midpoint = sim.action_animation_state();
        assert!((midpoint.weight - 0.5).abs() < 1.0e-6);
        assert!(
            (midpoint
                .samples
                .iter()
                .map(|sample| sample.weight)
                .sum::<f32>()
                - 0.5)
                .abs()
                < 1.0e-6
        );

        for _ in 0..6 {
            step_anticipation_and_handoff(&mut sim, DT);
        }
        assert!(sim.trick_handoff.is_none());
        assert_eq!(
            sim.action_animation_state(),
            ActionAnimationState::default()
        );
    }

    #[test]
    fn recovered_contact_bridge_preserves_channels_and_airborne_timer_without_guesses() {
        let mut sim = SkateSim::default();
        let record = ContactRecord {
            body: BodyId::RightFrontWheel,
            vector_16: SkateboardVector3::new(0.0, 1.0, 0.0),
            vector_32: SkateboardVector3::ZERO,
            vector_48: SkateboardVector3::ZERO,
            packed_classification: 0,
            raw_flag_80: false,
            raw_flag_81: false,
            peer_channel_effect: SolverRequired::supplied(PeerChannelEffect::NoChange),
        };
        let wheels = WheelId::ORDER
            .map(|wheel| WheelBridgeInput::new(wheel, 0.0, SkateboardVector3::new(0.0, 1.0, 0.0)));
        let first = sim
            .apply_recovered_contact_bridge(
                1.0 / 60.0,
                SkateboardVector3::new(0.0, 1.0, 0.0),
                &[record],
                wheels,
                false,
            )
            .unwrap();
        assert_eq!(first.touching_wheel_count, 1);
        assert_eq!(first.airborne_time_seconds, 0.0);
        assert!(!first.contact_normal.is_unresolved());

        let second = sim
            .apply_recovered_contact_bridge(
                1.0 / 60.0,
                SkateboardVector3::new(0.0, 1.0, 0.0),
                &[],
                wheels,
                false,
            )
            .unwrap();
        assert_eq!(second.touching_wheel_count, 0);
        assert_eq!(
            second.airborne_time_seconds.to_bits(),
            (1.0_f32 / 60.0).to_bits()
        );
    }

    #[test]
    fn onboard_foot_placement_preserves_exact_compact_target_channels() {
        let observed = ObservedSkeletonIkPart {
            primary_weight: IkWeight::ONE,
            transition_weight: IkWeight::ZERO,
            mode: RawSkeletonIkMode::State2,
        };
        let targets = FootPair::new(
            Some(CompactTargetSample::new(
                Foot::Left,
                TargetMatrix::IDENTITY,
                observed,
            )),
            Some(CompactTargetSample::new(
                Foot::Right,
                TargetMatrix::IDENTITY,
                observed,
            )),
        );
        let mut sim = SkateSim::default();
        let output = sim
            .apply_foot_placement_frame(FootPlacementFrame::onboard(
                1,
                OnboardMotion::Idle,
                targets,
            ))
            .unwrap();
        assert_eq!(output.feet.left.contact, ContactOwnership::Board);
        assert_eq!(output.feet.right.contact, ContactOwnership::Board);
        assert_eq!(
            output.feet.left.target.unwrap().space,
            crate::foot_placement::TargetSpace::CompactOnboard(
                crate::foot_placement::CompactToeTarget::LeftReparented
            )
        );
        assert_eq!(
            output.feet.right.target.unwrap().space,
            crate::foot_placement::TargetSpace::CompactOnboard(
                crate::foot_placement::CompactToeTarget::RightReparented
            )
        );
    }

    #[test]
    fn controller_actions_select_the_verified_foot_motion_family() {
        let mut push = PushRuntime::new(PushFoot::Regular, 0.0, 0.0);
        force_full_hard_push(&mut push);
        assert_eq!(push.animation_clip(), "R_PUSHLSP_HSTR_MONGO_0_INTO");
        let low_strength = PushRuntime::new(PushFoot::Regular, 0.0, 0.0);
        assert_eq!(low_strength.animation_clip(), "R_PUSHLSP_LSTR_MONGO_0_INTO");

        let mut x_button = PushRuntime::new(PushFoot::Mongo, 0.0, 0.0);
        force_full_hard_push(&mut x_button);
        assert_eq!(x_button.animation_clip(), "R_PUSHLSP_HSTR_N_0_INTO");
    }

    #[test]
    fn directional_and_mongo_clip_names_match_exported_names() {
        let mut left_foot = PushRuntime::new(PushFoot::Mongo, 0.0, -1.0);
        left_foot.turn_coefficient = -1.0;
        force_full_hard_push(&mut left_foot);
        assert_eq!(left_foot.animation_clip(), "R_PUSHLSP_HSTR_LEFT_0_INTO");
        let mut right_foot = PushRuntime::new(PushFoot::Regular, 0.0, 1.0);
        force_full_hard_push(&mut right_foot);
        assert_eq!(right_foot.animation_clip(), "R_PUSHLSP_HSTR_MONGO_0_INTO");
    }

    fn force_full_hard_push(push: &mut PushRuntime) {
        push.hold_time = PUSH_INTO_TRANSITION_SECONDS;
        push.strength = PUSH_STRENGTH_OUTPUT_GRAPH[7].1;
        push.strength_frozen = true;
        push.set_requested_delta(push.contact_start_speed, push.strength);
        push.target_coefficients =
            compute_target_coefficients(push_attributes(push.foot), 0.0, 4.5);
        push.coefficients = push.target_coefficients;
        push.phase_duration = push.retail_phase_duration();
    }

    #[test]
    fn push_speed_is_delivered_across_the_retail_contact_window() {
        let mut sim = SkateSim::default();
        request_push(&mut sim, PushFoot::Mongo);
        for _ in 0..36 {
            step_push_state(&mut sim, DT, true);
            step_retail_animation_signals(&mut sim, DT);
        }
        for _ in 0..240 {
            step_push_state(&mut sim, DT, false);
            step_retail_animation_signals(&mut sim, DT);
            if sim.push.as_ref().map(|push| push.phase) == Some(PushPhase::Cycle) {
                break;
            }
        }
        assert!((4.50..4.60).contains(&sim.speed()));
        assert!(sim.push.is_some());
    }

    fn complete_first_push_after_retail_frames(
        foot: PushFoot,
        initial_speed: f32,
        held_frames: usize,
    ) -> (SkateSim, f32) {
        let mut sim = SkateSim {
            velocity: Vec3::Z * initial_speed,
            ..default()
        };
        request_push(&mut sim, foot);
        for _ in 0..held_frames * 2 {
            step_push_state(&mut sim, DT, true);
            step_retail_animation_signals(&mut sim, DT);
        }
        step_push_state(&mut sim, DT, false);
        step_retail_animation_signals(&mut sim, DT);
        let resolved_strength = sim.push.as_ref().unwrap().strength;

        for _ in 0..300 {
            if sim.push.as_ref().map(|push| push.phase) == Some(PushPhase::Contact) {
                break;
            }
            step_push_state(&mut sim, DT, false);
            step_retail_animation_signals(&mut sim, DT);
        }
        assert_eq!(
            sim.push.as_ref().map(|push| push.phase),
            Some(PushPhase::Contact)
        );
        (sim, resolved_strength)
    }

    #[test]
    fn tap_hold_strength_is_monotonic_and_uses_actual_held_time() {
        let held_frames = [1, 6, 18];
        for initial_speed in [0.0, 3.0] {
            let mut prior_speed = initial_speed;
            for frames in held_frames {
                let expected_strength =
                    push_strength_for_hold_time(frames as f32 / 60.0, initial_speed);
                let (sim, strength) = complete_first_push_after_retail_frames(
                    PushFoot::Regular,
                    initial_speed,
                    frames,
                );
                let expected_speed = (initial_speed + strength).min(PUSH_SPEED_CAP);
                assert!((strength - expected_strength).abs() < 1.0e-6);
                assert!((sim.speed() - expected_speed).abs() < 1.0e-4);
                assert!(sim.speed() > prior_speed);
                prior_speed = sim.speed();
            }
        }
    }

    #[test]
    fn rest_tap_hold_samples_land_on_recovered_native_graph_points() {
        let expected = [
            (1, PUSH_STRENGTH_OUTPUT_GRAPH[3].1),
            (6, PUSH_STRENGTH_OUTPUT_GRAPH[5].1),
            (18, PUSH_STRENGTH_OUTPUT_GRAPH[7].1),
        ];
        for (frames, expected_delta) in expected {
            let delta = push_strength_for_hold_time(frames as f32 / 60.0, 0.0);
            assert!((delta - expected_delta).abs() < 1.0e-6);
        }
    }

    #[test]
    fn moving_push_uses_recovered_speed_dependent_charge_normalizer() {
        let rest_tap = push_strength_for_hold_time(1.0 / 60.0, 0.0);
        let moving_tap = push_strength_for_hold_time(1.0 / 60.0, 3.0);
        let rest_hold = push_strength_for_hold_time(18.0 / 60.0, 0.0);
        let moving_hold = push_strength_for_hold_time(18.0 / 60.0, 3.0);

        assert!(moving_tap < rest_tap);
        assert!(moving_hold < rest_hold);
        assert!((rest_hold - 4.5).abs() < 1.0e-6);
        assert!((moving_hold - 3.699_168).abs() < 1.0e-5);
    }

    #[test]
    fn release_freezes_strength_before_authored_drive_begins() {
        let mut sim = SkateSim::default();
        request_push(&mut sim, PushFoot::Regular);
        for _ in 0..2 {
            step_push_state(&mut sim, DT, true);
            step_retail_animation_signals(&mut sim, DT);
        }
        step_push_state(&mut sim, DT, false);
        let frozen_strength = sim.push.as_ref().unwrap().strength;
        for _ in 0..40 {
            assert_eq!(sim.speed(), 0.0);
            assert!(!sim.push.as_ref().unwrap().contact_propulsion_enabled);
            step_push_state(&mut sim, DT, false);
            step_retail_animation_signals(&mut sim, DT);
            assert_eq!(sim.push.as_ref().unwrap().strength, frozen_strength);
        }
    }

    #[test]
    fn acceleration_starts_and_finishes_inside_the_authored_into_drive_window() {
        let mut sim = SkateSim::default();
        request_push(&mut sim, PushFoot::Regular);
        for _ in 0..36 {
            step_push_state(&mut sim, DT, true);
            step_retail_animation_signals(&mut sim, DT);
        }
        step_push_state(&mut sim, DT, false);
        let drive_start = PUSH_INTO_TRANSITION_SECONDS + PUSH_INTO_PROPULSION_START_SECONDS;
        while sim.push.as_ref().unwrap().phase_time + DT < drive_start {
            assert_eq!(sim.speed(), 0.0);
            step_push_state(&mut sim, DT, false);
            step_retail_animation_signals(&mut sim, DT);
        }
        assert_eq!(sim.speed(), 0.0);

        while sim.push.as_ref().unwrap().drive_progress() < 1.0 {
            step_push_state(&mut sim, DT, false);
            step_retail_animation_signals(&mut sim, DT);
        }
        let push = sim.push.as_ref().unwrap();
        assert_eq!(push.phase, PushPhase::Into);
        assert!(
            (push.phase_time - (PUSH_INTO_TRANSITION_SECONDS + PUSH_INTO_PROPULSION_END_SECONDS))
                .abs()
                <= DT * 1.1
        );
        assert!((sim.speed() - PUSH_STRENGTH_OUTPUT_GRAPH[7].1).abs() < 1.0e-4);
    }

    #[test]
    fn regular_and_mongo_share_strength_but_keep_authored_cadence() {
        let (regular, regular_strength) =
            complete_first_push_after_retail_frames(PushFoot::Regular, 3.0, 6);
        let (mongo, mongo_strength) =
            complete_first_push_after_retail_frames(PushFoot::Mongo, 3.0, 6);
        assert!((regular_strength - mongo_strength).abs() < 1.0e-6);
        assert!((regular.speed() - mongo.speed()).abs() < 1.0e-4);

        let mut regular_phase = PushRuntime::new(PushFoot::Regular, 3.0, 0.0);
        let mut mongo_phase = PushRuntime::new(PushFoot::Mongo, 3.0, 0.0);
        force_full_hard_push(&mut regular_phase);
        force_full_hard_push(&mut mongo_phase);
        regular_phase.set_phase(PushPhase::Contact);
        mongo_phase.set_phase(PushPhase::Contact);
        assert!(regular_phase.phase_duration < mongo_phase.phase_duration);
    }

    #[test]
    fn one_frame_mongo_tap_finishes_its_short_authored_drive() {
        let mut sim = SkateSim::default();
        request_push(&mut sim, PushFoot::Mongo);
        for _ in 0..2 {
            step_push_state(&mut sim, DT, true);
            step_retail_animation_signals(&mut sim, DT);
        }
        step_push_state(&mut sim, DT, false);
        step_retail_animation_signals(&mut sim, DT);

        let push = sim.push.as_ref().unwrap();
        assert_eq!(push.animation_clip(), "R_PUSHLSP_LSTR_N_0_INTO");
        assert!((push.strength - PUSH_STRENGTH_OUTPUT_GRAPH[3].1).abs() < 1.0e-5);

        let mut maximum_drive_progress: f32 = 0.0;
        for _ in 0..300 {
            if sim.push.as_ref().map(|push| push.phase) == Some(PushPhase::Contact) {
                break;
            }
            step_push_state(&mut sim, DT, false);
            step_retail_animation_signals(&mut sim, DT);
            maximum_drive_progress =
                maximum_drive_progress.max(sim.push.as_ref().unwrap().drive_progress());
        }

        assert_eq!(
            sim.push.as_ref().map(|push| push.phase),
            Some(PushPhase::Contact)
        );
        assert!(maximum_drive_progress >= 0.999);
        assert!((sim.speed() - PUSH_STRENGTH_OUTPUT_GRAPH[3].1).abs() < 1.0e-4);
    }

    #[test]
    fn held_repeats_keep_full_animation_effort_at_the_speed_cap() {
        let mut sim = SkateSim::default();
        request_push(&mut sim, PushFoot::Regular);
        for _ in 0..1_500 {
            step_push_state(&mut sim, DT, true);
            step_retail_animation_signals(&mut sim, DT);
        }

        let push = sim.push.as_ref().unwrap();
        assert!(push.repeat_count >= 3);
        assert!((push.strength - PUSH_STRENGTH_OUTPUT_GRAPH[7].1).abs() < 1.0e-5);
        assert!(push.push_delta_velocity < 0.05);
        assert!(push.target_coefficients.velocity_end > 0.99);
        assert!(push.coefficients.velocity_end > 0.99);
        assert!(push.animation_clip().contains("_HSTR_"));
    }

    #[test]
    fn buffered_tap_waits_for_cycle_expiry_and_activates_its_own_strength() {
        let mut sim = SkateSim::default();
        request_push(&mut sim, PushFoot::Regular);
        for _ in 0..12 {
            step_push_state(&mut sim, DT, true);
            step_retail_animation_signals(&mut sim, DT);
        }
        advance_until_push_phase(&mut sim, PushPhase::Cycle, false);
        request_push(&mut sim, PushFoot::Regular);
        for _ in 0..2 {
            step_push_state(&mut sim, DT, true);
            step_retail_animation_signals(&mut sim, DT);
        }
        step_push_state(&mut sim, DT, false);
        step_retail_animation_signals(&mut sim, DT);
        let queued_strength = sim.push.as_ref().unwrap().queued_repush_strength;
        assert!(
            queued_strength > PUSH_STRENGTH_OUTPUT_GRAPH[0].1
                && queued_strength < PUSH_STRENGTH_OUTPUT_GRAPH[7].1
        );
        assert_eq!(sim.push.as_ref().unwrap().phase, PushPhase::Cycle);

        advance_until_push_phase(&mut sim, PushPhase::Contact, false);
        let push = sim.push.as_ref().unwrap();
        assert_eq!(push.repeat_count, 1);
        assert!((push.strength - queued_strength).abs() < 1.0e-6);
        let expected_delta =
            queued_strength.min((PUSH_SPEED_CAP - push.contact_start_speed).max(0.0));
        assert!((push.push_delta_velocity - expected_delta).abs() < 1.0e-5);
    }

    fn advance_until_push_phase(sim: &mut SkateSim, phase: PushPhase, held: bool) {
        for _ in 0..600 {
            if sim.push.as_ref().map(|push| push.phase) == Some(phase) {
                return;
            }
            step_push_state(sim, DT, held);
        }
        panic!("push never entered {phase:?}");
    }

    #[test]
    fn hard_push_uses_authored_clip_speed_and_retail_expiry_windows() {
        let mut push = PushRuntime::new(PushFoot::Mongo, 0.0, 0.0);
        force_full_hard_push(&mut push);
        assert!(
            (push.phase_duration - (PUSH_INTO_TRANSITION_SECONDS + 40.0 / 60.0 - 0.01)).abs()
                < 0.0001
        );
        push.set_phase(PushPhase::Contact);
        assert!((push.phase_duration - (12.0 / 60.0 - 0.01)).abs() < 0.0001);
        push.set_phase(PushPhase::Cycle);
        assert!((push.phase_duration - (54.0 / 60.0 - 0.01)).abs() < 0.0001);
        push.set_phase(PushPhase::Out);
        assert!((push.phase_duration - (20.0 / 60.0 - 0.1)).abs() < 0.0001);
    }

    #[test]
    fn tapped_push_plays_one_complete_sequence_then_exits() {
        let mut sim = SkateSim::default();
        request_push(&mut sim, PushFoot::Regular);
        advance_until_push_phase(&mut sim, PushPhase::Contact, false);
        advance_until_push_phase(&mut sim, PushPhase::Cycle, false);
        advance_until_push_phase(&mut sim, PushPhase::Out, false);
        for _ in 0..120 {
            step_push_state(&mut sim, DT, false);
            if sim.push.is_none() {
                break;
            }
        }
        assert!(sim.push.is_none());
        assert!(sim.animation_clip.is_none());
    }

    #[test]
    fn push_exit_crossfades_to_riding_over_authored_point_two() {
        let mut sim = SkateSim::default();
        request_push(&mut sim, PushFoot::Mongo);
        advance_until_push_phase(&mut sim, PushPhase::Out, false);
        for _ in 0..120 {
            step_push_state(&mut sim, DT, false);
            if sim.push.is_none() {
                break;
            }
        }

        let exit = sim.action_animation_state();
        assert!((exit.weight - 1.0).abs() < 1.0e-6);
        assert!(
            exit.samples
                .iter()
                .any(|sample| sample.clip.ends_with("_OUT_MIDFRONT"))
        );
        assert_eq!(
            sim.trick_handoff
                .as_ref()
                .map(|handoff| handoff.duration_seconds.to_bits()),
            Some(PUSH_TO_RIDING_BLEND_SECONDS.to_bits())
        );

        for _ in 0..12 {
            step_anticipation_and_handoff(&mut sim, DT);
        }
        let handoff = sim.trick_handoff.as_ref().unwrap();
        let expected_weight = 1.0 - handoff.elapsed_seconds / handoff.duration_seconds;
        assert!((sim.action_animation_state().weight - expected_weight).abs() < 1.0e-5);

        for _ in 0..12 {
            step_anticipation_and_handoff(&mut sim, DT);
        }
        assert!(sim.trick_handoff.is_none());
        assert_eq!(
            sim.action_animation_state(),
            ActionAnimationState::default()
        );
    }

    #[test]
    fn held_push_repeats_contact_and_cycle_until_released() {
        let mut sim = SkateSim::default();
        request_push(&mut sim, PushFoot::Regular);
        advance_until_push_phase(&mut sim, PushPhase::Cycle, true);
        advance_until_push_phase(&mut sim, PushPhase::Contact, true);
        advance_until_push_phase(&mut sim, PushPhase::Cycle, true);
        assert!(sim.push.is_some());
        advance_until_push_phase(&mut sim, PushPhase::Out, false);
        assert_eq!(
            sim.push.as_ref().map(|push| push.phase),
            Some(PushPhase::Out)
        );
    }

    #[test]
    fn measured_powerslide_gate_rejects_negative_controls() {
        assert!(!can_enter_powerslide(Vec2::new(1.0, 0.0), 2.0, true));
        assert!(!can_enter_powerslide(Vec2::new(0.707, -0.707), 2.0, true));
        assert!(!can_enter_powerslide(Vec2::new(0.447, -0.86), 2.0, true));
        assert!(!can_enter_powerslide(Vec2::new(0.447, -0.894), 0.84, true));
        assert!(!can_enter_powerslide(Vec2::new(0.447, -0.894), 2.0, false));
        assert!(can_enter_powerslide(Vec2::new(0.447, -0.894), 2.0, true));
    }

    #[test]
    fn established_powerslide_survives_modest_stick_adjustment() {
        let mut sim = SkateSim {
            velocity: Vec3::Z * 2.0,
            left_stick: Vec2::new(0.447, -0.894),
            steer: 0.447,
            ground_contact_valid: true,
            ..default()
        };
        begin_slide(&mut sim);
        let side = sim.slide.as_ref().unwrap().side;
        let revision = sim.animation_revision;

        sim.left_stick = Vec2::new(0.12, -0.82);
        for _ in 0..60 {
            step_slide_state(&mut sim, DT);
        }

        let slide = sim
            .slide
            .as_ref()
            .expect("modest adjustment cancelled slide");
        assert_eq!(slide.side, side);
        assert!(!matches!(slide.phase, SlidePhase::Out(_)));
        assert!(slide.intent > 0.0 && slide.intent < 1.0);
        assert_eq!(sim.animation_revision, revision);
    }

    #[test]
    fn powerslide_control_sweeps_smoothly_without_side_or_animation_restart() {
        let mut sim = SkateSim {
            velocity: Vec3::Z * 3.0,
            left_stick: Vec2::new(-0.45, -0.90),
            steer: -0.45,
            ground_contact_valid: true,
            ..default()
        };
        begin_slide(&mut sim);
        while sim.slide.as_ref().unwrap().phase == SlidePhase::Into {
            step_slide_state(&mut sim, DT);
        }
        let side = sim.slide.as_ref().unwrap().side;
        let revision = sim.animation_revision;
        for _ in 0..90 {
            step_heading(&mut sim, DT, true);
        }
        let initial_yaw_rate = sim.yaw_rate.abs();
        sim.left_stick = Vec2::new(-0.20, -0.72);

        let mut previous = sim.slide.as_ref().unwrap().intent;
        for _ in 0..18 {
            step_slide_state(&mut sim, DT);
            let current = sim.slide.as_ref().unwrap().intent;
            assert!(current <= previous + 1.0e-6);
            previous = current;
            step_heading(&mut sim, DT, true);
            step_retail_animation_signals(&mut sim, DT);
        }

        let slide = sim.slide.as_ref().unwrap();
        assert_eq!(slide.side, side);
        assert_eq!(slide.phase, SlidePhase::Cycle);
        assert!((slide.control.x - sim.left_stick.x).abs() < 0.01);
        assert!((0.0..1.0).contains(&slide.intent));
        assert!(sim.yaw_rate.abs() < initial_yaw_rate);
        let samples = slide.animation_samples();
        assert!(samples.iter().any(|sample| sample.clip.contains("_LSP_")));
        assert!(samples.iter().any(|sample| sample.clip.contains("_HSP_")));
        assert_eq!(sim.animation_revision, revision);
    }

    #[test]
    fn established_powerslide_exits_only_after_crossing_the_continuation_sector() {
        let mut sim = SkateSim {
            velocity: Vec3::Z * 2.0,
            left_stick: Vec2::new(0.447, -0.894),
            steer: 0.447,
            ground_contact_valid: true,
            ..default()
        };
        begin_slide(&mut sim);
        sim.slide.as_mut().unwrap().total_time = 0.31;

        // Crossing lateral sides while still down remains a live adjustment.
        sim.left_stick = Vec2::new(-0.8, -0.82);
        step_slide_state(&mut sim, DT);
        assert!(!matches!(
            sim.slide.as_ref().unwrap().phase,
            SlidePhase::Out(_)
        ));

        // Forward/neutral leaves the measured continuation sector.
        sim.left_stick = Vec2::Y;
        step_slide_state(&mut sim, DT);
        assert!(matches!(
            sim.slide.as_ref().unwrap().phase,
            SlidePhase::Out(_)
        ));
    }

    #[test]
    fn powerslide_release_waits_for_retail_parent_guard_then_enters_out() {
        let mut sim = SkateSim {
            velocity: Vec3::Z * 2.0,
            left_stick: Vec2::new(0.447, -0.894),
            steer: 0.447,
            ground_contact_valid: true,
            ..default()
        };
        begin_slide(&mut sim);
        sim.left_stick = Vec2::ZERO;

        for _ in 0..35 {
            step_slide_state(&mut sim, DT);
        }
        assert!(!matches!(
            sim.slide.as_ref().unwrap().phase,
            SlidePhase::Out(_)
        ));
        step_slide_state(&mut sim, DT);
        assert!(matches!(
            sim.slide.as_ref().unwrap().phase,
            SlidePhase::Out(_)
        ));
    }

    #[test]
    fn powerslide_transient_pre_guard_release_does_not_poison_latch() {
        let held = Vec2::new(0.447, -0.894);
        let mut sim = SkateSim {
            velocity: Vec3::Z * 2.0,
            left_stick: held,
            steer: held.x,
            ground_contact_valid: true,
            ..default()
        };
        begin_slide(&mut sim);
        sim.left_stick = Vec2::ZERO;
        for _ in 0..12 {
            step_slide_state(&mut sim, DT);
        }
        sim.left_stick = Vec2::new(0.32, -0.82);
        for _ in 0..36 {
            step_slide_state(&mut sim, DT);
        }
        assert!(!matches!(
            sim.slide.as_ref().unwrap().phase,
            SlidePhase::Out(_)
        ));
    }

    #[test]
    fn powerslide_speed_and_contact_are_true_leave_gates() {
        for (speed, contact_valid) in [(0.84, true), (2.0, false)] {
            let mut sim = SkateSim {
                velocity: Vec3::Z * speed,
                left_stick: Vec2::new(0.447, -0.894),
                steer: 0.447,
                ground_contact_valid: contact_valid,
                ..default()
            };
            begin_slide(&mut sim);
            sim.slide.as_mut().unwrap().total_time = 0.31;
            step_slide_state(&mut sim, DT);
            assert!(matches!(
                sim.slide.as_ref().unwrap().phase,
                SlidePhase::Out(_)
            ));
        }
    }

    #[test]
    fn powerslide_motion_uses_board_yaw_and_lateral_friction_as_separate_states() {
        let mut sim = SkateSim {
            velocity: Vec3::Z * 2.0,
            left_stick: Vec2::new(0.447, -0.894),
            steer: 0.447,
            ..default()
        };
        begin_slide(&mut sim);
        let start_speed = sim.speed();
        for _ in 0..120 {
            step_heading(&mut sim, DT, true);
            step_velocity(&mut sim, DT, true, false, false);
        }
        assert!(sim.yaw < -1.0);
        assert!(start_speed - sim.speed() > 0.3);
        assert!(sim.powerslide_rotation > 1.0);
        assert!(sim.lateral_friction_rate > 0.0);
    }

    #[test]
    fn low_speed_carve_matches_the_retail_heading_and_grip_fixture() {
        let mut sim = SkateSim {
            velocity: Vec3::Z * 1.158,
            left_stick: Vec2::new(0.75, 0.0),
            steer: 0.75,
            ..default()
        };
        let mut peak_slip = 0.0_f32;
        for _ in 0..240 {
            step_heading(&mut sim, DT, false);
            step_velocity(&mut sim, DT, false, false, false);
            peak_slip = peak_slip.max(slip_angle(&sim).abs());
        }
        let heading_degrees = sim.yaw.to_degrees();
        let final_slip = slip_angle(&sim).abs().to_degrees();
        assert!((-190.0..-155.0).contains(&heading_degrees));
        assert!(
            peak_slip.to_degrees() < 11.0 && final_slip < 6.0,
            "heading={heading_degrees} peak_slip={} final_slip={final_slip}",
            peak_slip.to_degrees(),
        );
    }

    #[test]
    fn brake_cycle_blends_the_authored_speed_zero_and_speed_four_leaves() {
        let mut brake = BrakeRuntime::new(3.0);
        brake.set_phase(BrakePhase::MovingCycle);

        let stopped = brake.animation_samples(0.0);
        assert_eq!(stopped[0].clip, "R_BRAKE_N_N_0_CYC1");
        assert_eq!(stopped[0].weight, 1.0);
        assert_eq!(stopped[1].weight, 0.0);

        let middle = brake.animation_samples(2.0);
        assert_eq!(middle[0].weight, 0.5);
        assert_eq!(middle[1].weight, 0.5);

        let fast = brake.animation_samples(4.0);
        assert_eq!(fast[0].weight, 0.0);
        assert_eq!(fast[1].weight, 1.0);
    }

    #[test]
    fn slide_decel_blends_lsp_and_hsp_endpoints_at_synchronized_progress() {
        let mut slide = SlideRuntime::new(-0.3);
        slide.decel = 0.25;
        slide.phase_time = 0.2;
        let samples = slide.animation_samples();
        assert_eq!(samples.len(), 2);
        assert_eq!(samples[0].clip, "R_SLIDE_BS_LSP_INTO");
        assert_eq!(samples[1].clip, "R_SLIDE_BS_HSP_INTO");
        assert!((samples[0].weight - 0.75).abs() < 0.0001);
        assert!((samples[1].weight - 0.25).abs() < 0.0001);
        assert!((samples[0].seek_time_seconds - samples[1].seek_time_seconds).abs() < 0.0001);
    }

    #[test]
    fn slide_out_freezes_the_outgoing_tree_during_transition_under() {
        let mut slide = SlideRuntime::new(-0.3);
        slide.decel = 0.6;
        slide.phase_time = 0.4;
        let outgoing = slide.animation_samples();
        slide.begin_out(SlideOut::Angle090);
        slide.phase_time = 0.1;

        let samples = slide.transition_samples();
        assert_eq!(samples.len(), 4);
        assert_eq!(samples[0].clip, outgoing[0].clip);
        assert_eq!(samples[0].seek_time_seconds, outgoing[0].seek_time_seconds);
        let total: f32 = samples.iter().map(|sample| sample.weight).sum();
        assert!((total - 1.0).abs() < 0.0001);
    }

    #[test]
    fn slide_into_hands_off_to_cycle_with_authored_point_one_blend() {
        let mut sim = SkateSim {
            velocity: Vec3::Z * 2.0,
            left_stick: Vec2::new(-0.447, -0.894),
            steer: -0.447,
            ground_contact_valid: true,
            ..default()
        };
        begin_slide(&mut sim);
        let into_duration = sim.slide.as_ref().unwrap().phase_duration;
        while sim.slide.as_ref().unwrap().phase == SlidePhase::Into {
            step_slide_state(&mut sim, DT);
        }

        let slide = sim.slide.as_ref().unwrap();
        assert_eq!(slide.phase, SlidePhase::Cycle);
        assert!((slide.total_time - into_duration).abs() <= DT + 1.0e-6);
        assert_eq!(slide.transition_duration.to_bits(), 0.1_f32.to_bits());
        let samples = slide.transition_samples();
        assert!(samples.iter().any(|sample| sample.clip.ends_with("_INTO")));
        assert!(samples.iter().any(|sample| sample.clip.ends_with("_CYC")));
        assert!((samples.iter().map(|sample| sample.weight).sum::<f32>() - 1.0).abs() < 1.0e-5);

        let initial_into_seek = samples
            .iter()
            .find(|sample| sample.clip.ends_with("_INTO"))
            .unwrap()
            .seek_time_seconds;
        step_slide_state(&mut sim, DT);
        let advanced_into_seek = sim
            .slide
            .as_ref()
            .unwrap()
            .transition_samples()
            .into_iter()
            .find(|sample| sample.clip.ends_with("_INTO"))
            .unwrap()
            .seek_time_seconds;
        assert!(advanced_into_seek > initial_into_seek);
    }

    #[test]
    fn slide_exit_crossfades_to_riding_without_default_pose_flash() {
        let mut sim = SkateSim {
            velocity: Vec3::Z * 2.0,
            left_stick: Vec2::new(0.447, -0.894),
            steer: 0.447,
            ground_contact_valid: true,
            ..default()
        };
        begin_slide(&mut sim);
        sim.slide.as_mut().unwrap().total_time = 0.31;
        sim.left_stick = Vec2::ZERO;
        step_slide_state(&mut sim, DT);
        assert!(matches!(
            sim.slide.as_ref().unwrap().phase,
            SlidePhase::Out(_)
        ));

        while sim.slide.is_some() {
            step_slide_state(&mut sim, DT);
        }
        let handoff = sim.trick_handoff.as_ref().expect("missing OUT handoff");
        assert_eq!(handoff.duration_seconds.to_bits(), 0.2_f32.to_bits());
        let immediate = sim.action_animation_state();
        assert!(immediate.weight > 0.95);
        assert!(
            immediate
                .samples
                .iter()
                .any(|sample| sample.clip.contains("_OUT_"))
        );

        for _ in 0..12 {
            step_anticipation_and_handoff(&mut sim, DT);
        }
        let handoff = sim.trick_handoff.as_ref().unwrap();
        let expected_weight = 1.0 - handoff.elapsed_seconds / handoff.duration_seconds;
        assert!((sim.action_animation_state().weight - expected_weight).abs() < 1.0e-5);
        for _ in 0..12 {
            step_anticipation_and_handoff(&mut sim, DT);
        }
        assert!(sim.trick_handoff.is_none());
        assert_eq!(
            sim.action_animation_state(),
            ActionAnimationState::default()
        );
    }

    #[test]
    fn powerslide_conditioning_is_frame_partition_invariant() {
        let build = || SkateSim {
            velocity: Vec3::Z * 2.0,
            left_stick: Vec2::new(0.447, -0.894),
            steer: 0.447,
            ground_contact_valid: true,
            ..default()
        };
        let mut contiguous = build();
        let mut partitioned = build();
        begin_slide(&mut contiguous);
        begin_slide(&mut partitioned);
        contiguous.left_stick = Vec2::new(0.18, -0.74);
        partitioned.left_stick = contiguous.left_stick;

        for _ in 0..48 {
            step_slide_state(&mut contiguous, DT);
        }
        for _ in 0..96 {
            step_slide_state(&mut partitioned, DT * 0.5);
        }

        let a = contiguous.slide.as_ref().unwrap();
        let b = partitioned.slide.as_ref().unwrap();
        assert!((a.intent - b.intent).abs() < 2.0e-6);
        assert!((a.control - b.control).length() < 2.0e-6);
        assert_eq!(a.side, b.side);
        assert_eq!(a.phase, b.phase);
        assert!((a.phase_time - b.phase_time).abs() < 2.0e-6);
        assert!((a.total_time - b.total_time).abs() < 2.0e-6);
        let a_samples = a.transition_samples();
        let b_samples = b.transition_samples();
        assert_eq!(a_samples.len(), b_samples.len());
        for (a_sample, b_sample) in a_samples.iter().zip(&b_samples) {
            assert_eq!(a_sample.clip, b_sample.clip);
            assert!((a_sample.weight - b_sample.weight).abs() < 2.0e-6);
            assert!((a_sample.seek_time_seconds - b_sample.seek_time_seconds).abs() < 2.0e-6);
        }
    }

    #[test]
    fn powerslide_out_handoff_carries_phase_overshoot_across_partitions() {
        let build = || {
            let mut sim = SkateSim {
                velocity: Vec3::Z * 2.0,
                left_stick: Vec2::new(0.447, -0.894),
                steer: 0.447,
                ground_contact_valid: true,
                ..default()
            };
            begin_slide(&mut sim);
            sim.slide.as_mut().unwrap().total_time = 0.31;
            sim.left_stick = Vec2::ZERO;
            step_slide_state(&mut sim, 0.001);
            assert!(matches!(
                sim.slide.as_ref().unwrap().phase,
                SlidePhase::Out(_)
            ));
            sim
        };
        let mut contiguous = build();
        let mut partitioned = build();
        let out_duration = contiguous.slide.as_ref().unwrap().phase_duration;
        let elapsed = out_duration + 0.03;

        step_slide_state(&mut contiguous, elapsed);
        step_slide_state(&mut partitioned, elapsed * 0.5);
        step_slide_state(&mut partitioned, elapsed * 0.5);

        assert!(contiguous.slide.is_none());
        assert!(partitioned.slide.is_none());
        let a = contiguous.trick_handoff.as_ref().unwrap();
        let b = partitioned.trick_handoff.as_ref().unwrap();
        assert!((a.elapsed_seconds - 0.03).abs() < 2.0e-6);
        assert!((a.elapsed_seconds - b.elapsed_seconds).abs() < 2.0e-6);
        assert!(
            (contiguous.action_animation_state().weight
                - partitioned.action_animation_state().weight)
                .abs()
                < 2.0e-6
        );
    }

    #[test]
    fn powerslide_stance_mirror_preserves_strength_and_mirrors_control() {
        let mut regular = SkateSim {
            velocity: Vec3::Z * 2.0,
            left_stick: Vec2::new(0.447, -0.894),
            steer: 0.447,
            ground_contact_valid: true,
            ..default()
        };
        let mut goofy = SkateSim {
            velocity: Vec3::Z * 2.0,
            left_stick: Vec2::new(0.447, -0.894),
            steer: 0.447,
            ground_contact_valid: true,
            ..default()
        };
        goofy.slide_control_mirrored = true;
        begin_slide(&mut regular);
        begin_slide(&mut goofy);
        step_slide_state(&mut regular, DT);
        step_slide_state(&mut goofy, DT);

        let regular_slide = regular.slide.as_ref().unwrap();
        let goofy_slide = goofy.slide.as_ref().unwrap();
        assert_eq!(
            regular_slide.control_target.x.to_bits(),
            (-goofy_slide.control_target.x).to_bits()
        );
        assert_eq!(
            regular_slide.control_target.y.to_bits(),
            goofy_slide.control_target.y.to_bits()
        );
        assert_eq!(
            regular_slide.intent_target.to_bits(),
            goofy_slide.intent_target.to_bits()
        );
        assert_ne!(regular_slide.side, goofy_slide.side);
        assert_ne!(regular_slide.animation_clip(), goofy_slide.animation_clip());
    }

    #[test]
    fn high_speed_carve_uses_the_measured_speed_sensitive_turn_rate() {
        let mut sim = SkateSim {
            velocity: Vec3::Z * 2.7,
            left_stick: Vec2::X,
            steer: 1.0,
            ..default()
        };
        let mut peak_slip = 0.0_f32;
        for _ in 0..120 {
            step_heading(&mut sim, DT, false);
            step_velocity(&mut sim, DT, false, false, false);
            peak_slip = peak_slip.max(slip_angle(&sim).abs());
        }
        assert!((0.54..0.62).contains(&sim.yaw.abs()));
        assert!(peak_slip.to_degrees() < 5.0);
    }

    #[test]
    fn brake_has_measured_lead_in_then_retail_drag() {
        let mut sim = SkateSim {
            velocity: Vec3::Z * 2.0,
            ..default()
        };
        for _ in 0..26 {
            step_brake_state(&mut sim, DT, true);
            step_velocity(&mut sim, DT, false, true, false);
        }
        assert!(!sim.brake_active);
        let before_active = sim.speed();
        for _ in 0..2 {
            step_brake_state(&mut sim, DT, true);
            step_velocity(&mut sim, DT, false, true, false);
        }
        assert!(sim.brake_active);
        for _ in 0..24 {
            step_brake_state(&mut sim, DT, true);
            step_velocity(&mut sim, DT, false, true, false);
        }
        assert!(before_active - sim.speed() > 0.70);
    }

    #[test]
    fn brake_switches_from_moving_to_standing_leaf() {
        let mut sim = SkateSim {
            velocity: Vec3::Z * 0.16,
            ..default()
        };
        step_brake_state(&mut sim, DT, true);
        assert_eq!(
            sim.brake.as_ref().map(|brake| brake.phase),
            Some(BrakePhase::MovingInto)
        );
        for _ in 0..180 {
            step_brake_state(&mut sim, DT, true);
            step_velocity(&mut sim, DT, false, true, false);
            if sim.brake.as_ref().map(|brake| brake.phase) == Some(BrakePhase::StandFromMoving) {
                break;
            }
        }
        assert_eq!(
            sim.brake.as_ref().map(|brake| brake.phase),
            Some(BrakePhase::StandFromMoving)
        );
    }

    #[test]
    fn stationary_no_input_enters_retail_random_idle_after_three_seconds() {
        let mut sim = SkateSim::default();
        for _ in 0..359 {
            step_random_idle(&mut sim, DT, false);
        }
        assert!(sim.random_idle.is_none());
        step_random_idle(&mut sim, DT, false);
        assert_eq!(sim.random_idle.as_ref().map(|idle| idle.variant), Some(1));
        assert_eq!(
            sim.animation_clip.as_deref(),
            Some("R_STAND_STAT_VER1_N_0_CYC")
        );
    }

    #[test]
    fn slide_out_selects_the_authored_rotation_leaf() {
        assert_eq!(slide_out_for_rotation(0.2), SlideOut::Angle000);
        assert_eq!(
            slide_out_for_rotation(90_f32.to_radians()),
            SlideOut::Angle090
        );
        assert_eq!(
            slide_out_for_rotation(175_f32.to_radians()),
            SlideOut::Angle180
        );
    }

    #[test]
    fn live_fixed_step_ground_adapter_uses_provider_height_normal_and_identity() {
        let mut provider = GroundProvider::new();
        provider
            .add_plane(
                GroundVec3::new(0.0, 1.25, 0.0),
                GroundVec3::Y,
                SurfaceId(77),
            )
            .unwrap();
        let ground = SkateGround {
            provider,
            transition_test: false,
        };
        let mut sim = SkateSim {
            position: Vec3::new(2.0, 0.0, -3.0),
            ..SkateSim::default()
        };

        apply_ground_contact(&mut sim, &ground);

        assert!(sim.ground_contact_valid);
        assert_eq!(sim.position.y, 1.25);
        assert_eq!(sim.ground_normal, Vec3::Y);
        assert_eq!(sim.ground_surface_id, Some(77));
    }

    #[test]
    fn live_ground_miss_is_explicit_and_does_not_snap_to_zero() {
        let ground = SkateGround {
            provider: GroundProvider::new(),
            transition_test: false,
        };
        let mut sim = SkateSim {
            position: Vec3::new(0.0, 3.5, 0.0),
            ..SkateSim::default()
        };

        apply_ground_contact(&mut sim, &ground);

        assert!(!sim.ground_contact_valid);
        assert_eq!(sim.position.y, 3.5);
        assert_eq!(sim.ground_surface_id, None);
    }

    #[test]
    fn live_transition_map_fixed_step_coasts_up_reverses_and_returns() {
        let mut sim = SkateSim {
            velocity: Vec3::Z * 6.25,
            ..default()
        };
        sim.ground_surface_id = Some(131);
        let mut app = transition_fixed_step_app(sim);
        let mut maximum_height = 0.0_f32;
        let mut crossed_back = false;
        let mut prior_z = 0.0;
        for _ in 0..900 {
            app.update();
            let sim = app.world().resource::<SkateSim>();
            maximum_height = maximum_height.max(sim.position.y);
            crossed_back |= prior_z > 0.0 && sim.position.z <= 0.0;
            prior_z = sim.position.z;
            assert!(sim.position.is_finite() && sim.velocity.is_finite());
            assert_ne!(sim.transition.phase, TransitionPhase::Disabled);
            if crossed_back {
                break;
            }
        }
        let sim = app.world().resource::<SkateSim>();
        assert!(maximum_height > 1.2);
        assert!(crossed_back);
        assert!(sim.transition.is_physically_grounded());
        assert!(sim.ground_contact_valid);
        assert_eq!(sim.ground_surface_id, Some(131));
    }

    #[test]
    fn transition_ollie_uses_surface_normal_then_relaxes_and_collision_lands() {
        let ground = SkateGround::transition_test();
        let mut sim = SkateSim {
            position: Vec3::new(0.0, 2.0, 14.2),
            ..default()
        };
        assert!(
            sim.transition
                .activate(&ground.provider, &mut sim.position, sim.yaw)
        );
        sim.ground_normal = sim.transition.support_up;
        sim.ground_surface_id = Some(131);
        sim.velocity = sim.transition.support_forward * 4.0;
        let launch_up_y = sim.transition.visual_up.y;
        begin_measured_ollie_pop(&mut sim, 15.0 / RETAIL_ANIMATION_HZ);

        let mut app = App::new();
        app.insert_resource(sim)
            .init_resource::<SkateInput>()
            .insert_resource(ground)
            .add_systems(Update, fixed_step);

        let mut saw_air = false;
        let mut saw_visual_relaxation = false;
        let mut saw_collision_landing = false;
        for _ in 0..720 {
            app.update();
            let sim = app.world().resource::<SkateSim>();
            saw_air |= sim.transition.phase == TransitionPhase::Airborne;
            if saw_air {
                saw_visual_relaxation |= sim.transition.visual_up.y > launch_up_y + 0.15;
            }
            saw_collision_landing |= sim.landed_this_step;
            assert!(sim.position.is_finite() && sim.velocity.is_finite());
            if saw_air
                && saw_collision_landing
                && sim.transition.is_physically_grounded()
                && sim.ground_contact_valid
            {
                break;
            }
        }

        let sim = app.world().resource::<SkateSim>();
        assert!(saw_air);
        assert!(saw_visual_relaxation);
        assert!(saw_collision_landing);
        assert!(sim.transition.is_physically_grounded());
        assert!(sim.ground_contact_valid);
    }

    #[test]
    fn vjoy_is_filtered_when_a_physical_controller_is_available() {
        assert!(is_vjoy_name("vJoy Device"));
        assert!(is_vjoy_name("VJOY virtual controller"));
        assert!(!is_vjoy_name("Xbox Wireless Controller"));
        assert!(!is_vjoy_name("DualSense Wireless Controller"));
    }

    #[test]
    fn xinput_thumb_axes_cover_the_full_signed_range() {
        assert_eq!(normalize_thumb_axis(i16::MIN), -1.0);
        assert_eq!(normalize_thumb_axis(0), 0.0);
        assert_eq!(normalize_thumb_axis(i16::MAX), 1.0);
    }

    #[test]
    fn xinput_button_edges_only_fire_on_the_rising_edge() {
        const BUTTON: u16 = 0x1000;
        assert!(button_just_pressed(0, BUTTON, BUTTON));
        assert!(!button_just_pressed(BUTTON, BUTTON, BUTTON));
        assert!(!button_just_pressed(BUTTON, 0, BUTTON));
    }

    #[test]
    fn airborne_body_spin_matches_the_measured_ramp_cap_and_release_curve() {
        let mut sim = SkateSim {
            left_stick: Vec2::X,
            ..default()
        };
        let mut second_step_speed = 0.0;
        for frame_index in 0..28 {
            step_airborne_body_spin(&mut sim, DT);
            if frame_index == 1 {
                second_step_speed = sim.body_spin_velocity.abs();
            }
        }
        let capped_speed = sim.body_spin_velocity.abs();
        sim.left_stick = Vec2::ZERO;
        for _ in 0..6 {
            step_airborne_body_spin(&mut sim, DT);
        }
        let released_speed = sim.body_spin_velocity.abs();

        assert!((0.84..0.94).contains(&second_step_speed));
        assert!((7.85..=7.94).contains(&capped_speed));
        assert!((7.20..7.40).contains(&released_speed));
    }

    #[test]
    fn airborne_body_spin_matches_the_latest_retail_total_rotation_fixture() {
        let mut sim = SkateSim {
            left_stick: Vec2::X,
            ..default()
        };
        for _ in 0..28 {
            step_airborne_body_spin(&mut sim, DT);
        }
        sim.left_stick = Vec2::ZERO;
        for _ in 0..58 {
            step_airborne_body_spin(&mut sim, DT);
        }

        let rotation_degrees = sim.body_spin_angle.abs().to_degrees();
        assert!(
            (200.0..220.0).contains(&rotation_degrees),
            "rotation_degrees={rotation_degrees}"
        );
    }

    #[test]
    fn ollie_skater_root_has_no_procedural_yaw_carrier() {
        let sim = SkateSim::default();
        assert_eq!(sim.visual_skater_yaw_offset(), 0.0);
    }

    #[test]
    fn held_ollie_body_spin_rate_peaks_then_decays_like_retail() {
        let left_ramp = sample_ollie_held_body_spin_speed(0.139_535, 1.0);
        let right_ramp = sample_ollie_held_body_spin_speed(0.139_535, -1.0);
        let peak = sample_ollie_held_body_spin_speed(0.348_837, 1.0);
        let touchdown = sample_ollie_held_body_spin_speed(1.0, -1.0);

        assert!((left_ramp - 4.921).abs() < 0.001);
        assert!((right_ramp - 5.721).abs() < 0.001);
        assert!((peak - 7.969).abs() < 0.001);
        assert!((touchdown - 6.504).abs() < 0.001);
        assert!(peak > touchdown);
    }

    #[test]
    fn airborne_body_spin_does_not_rotate_the_chase_camera_heading() {
        let takeoff_heading = 0.4;
        let mut sim = SkateSim {
            yaw: takeoff_heading,
            view_yaw: takeoff_heading,
            left_stick: Vec2::X,
            ..default()
        };

        for _ in 0..12 {
            step_airborne_body_spin(&mut sim, DT);
            step_view_heading(&mut sim, true);
        }

        assert_ne!(sim.yaw, takeoff_heading);
        assert_eq!(sim.view_yaw, takeoff_heading);

        let target_heading = takeoff_heading + std::f32::consts::FRAC_PI_2;
        sim.yaw = target_heading;
        begin_measured_ollie_pop(&mut sim, 0.1);
        let motion = sim
            .pop_motion
            .as_mut()
            .expect("measured Ollie owns the low-ollie camera transition");
        motion.touched_down = true;
        motion.elapsed_since_flick_seconds =
            motion.touchdown_seconds + HIGH_CAMERA_LOW_OLLIE_TRANSITION_OUT_SECONDS * 0.5;
        step_view_heading(&mut sim, false);
        assert!(
            (wrap_angle(sim.view_yaw - (takeoff_heading + std::f32::consts::FRAC_PI_4))).abs()
                <= 1.0e-6
        );

        sim.pop_motion
            .as_mut()
            .expect("transition remains active")
            .elapsed_since_flick_seconds += HIGH_CAMERA_LOW_OLLIE_TRANSITION_OUT_SECONDS * 0.5;
        step_view_heading(&mut sim, false);
        assert_eq!(sim.view_yaw, target_heading);
    }

    #[test]
    fn landed_180_keeps_chase_heading_aligned_with_travel_while_fakie() {
        let travel_heading = 0.4_f32;
        let mut sim = SkateSim {
            velocity: Vec3::new(travel_heading.sin() * 4.0, 0.0, travel_heading.cos() * 4.0),
            yaw: travel_heading + std::f32::consts::PI,
            view_yaw: travel_heading,
            ..default()
        };
        begin_measured_ollie_pop(&mut sim, 0.1);
        sim.fakie.phase = crate::fakie::FakiePhase::RidingFakie;
        let motion = sim
            .pop_motion
            .as_mut()
            .expect("measured Ollie owns the high-camera transition");
        motion.touched_down = true;
        let touchdown_seconds = motion.touchdown_seconds;

        for fraction in [0.0, 0.25, 0.5, 1.0, 2.0] {
            sim.pop_motion
                .as_mut()
                .expect("touchdown transition remains represented")
                .elapsed_since_flick_seconds =
                touchdown_seconds + HIGH_CAMERA_LOW_OLLIE_TRANSITION_OUT_SECONDS * fraction;
            step_view_heading(&mut sim, false);
            assert!(
                wrap_angle(sim.view_yaw - travel_heading).abs() < 1.0e-6,
                "fraction={fraction} view={} travel={travel_heading}",
                sim.view_yaw
            );
        }
    }

    #[test]
    fn completed_fakie_shuffle_keeps_camera_on_logical_facing_and_travel() {
        let mut sim = SkateSim {
            velocity: Vec3::Z * 4.0,
            yaw: std::f32::consts::PI,
            view_yaw: 0.0,
            ..default()
        };
        sim.fakie.logical_facing_yaw_offset = std::f32::consts::PI;
        step_view_heading(&mut sim, false);
        assert!(wrap_angle(sim.view_yaw).abs() < 1.0e-6);
    }

    #[test]
    fn completed_fakie_shuffle_changes_stance_without_rotating_board_or_travel() {
        let board_yaw = std::f32::consts::PI;
        let travel = Vec3::Z * 4.0;
        let mut sim = SkateSim {
            velocity: travel,
            yaw: board_yaw,
            ..default()
        };
        sim.fakie.riding_switch = true;
        sim.fakie.logical_facing_yaw_offset = std::f32::consts::PI;

        assert_eq!(sim.flickit_mirror_state(), MirrorState::Mirrored);
        assert_eq!(sim.yaw, board_yaw);
        assert_eq!(sim.velocity, travel);
    }

    #[test]
    fn current_riding_stance_is_natural_goofy_xor_switch() {
        let mut regular = SkateSim::default();
        assert_eq!(regular.riding_stance(), RidingStance::Regular);
        assert_eq!(regular.flickit_mirror_state(), MirrorState::Unmirrored);

        regular.fakie.riding_switch = true;
        assert_eq!(regular.riding_stance(), RidingStance::Goofy);
        assert_eq!(regular.flickit_mirror_state(), MirrorState::Mirrored);

        let mut goofy = SkateSim {
            natural_stance: NaturalStance::Goofy,
            ..default()
        };
        assert_eq!(goofy.riding_stance(), RidingStance::Goofy);
        assert_eq!(goofy.flickit_mirror_state(), MirrorState::Mirrored);

        goofy.fakie.riding_switch = true;
        assert_eq!(goofy.riding_stance(), RidingStance::Regular);
        assert_eq!(goofy.flickit_mirror_state(), MirrorState::Unmirrored);
    }

    #[test]
    fn fakie_approach_and_regular_goofy_trick_mirroring_remain_independent() {
        let kickflip = crate::trick_input::square_identity_for_gesture("Kickflip").unwrap();
        let mut sim = SkateSim::default();
        sim.fakie.phase = crate::fakie::FakiePhase::RidingFakie;

        let fakie_regular =
            crate::trick_input::resolve_trick_identity(kickflip, sim.flickit_mirror_state(), false);
        assert_eq!(sim.fakie.trick_approach(), TrickApproach::Fakie);
        assert_eq!(fakie_regular.selected_name, "Kickflip");

        sim.natural_stance = NaturalStance::Goofy;
        let fakie_goofy =
            crate::trick_input::resolve_trick_identity(kickflip, sim.flickit_mirror_state(), false);
        assert_eq!(sim.fakie.trick_approach(), TrickApproach::Fakie);
        assert_eq!(fakie_goofy.selected_name, "Heelflip");
    }

    #[test]
    fn fakie_and_pose_mirroring_have_independent_turn_signs() {
        let mut sim = SkateSim {
            body_tilt: 0.4,
            ..default()
        };
        assert!((sim.riding_animation_source_tilt() - 0.4).abs() < 1.0e-6);

        sim.fakie.phase = crate::fakie::FakiePhase::RidingFakie;
        assert!((sim.riding_animation_source_tilt() + 0.4).abs() < 1.0e-6);

        sim.fakie.phase = crate::fakie::FakiePhase::Switching;
        assert!((sim.riding_animation_source_tilt() - 0.4).abs() < 1.0e-6);

        sim.fakie.phase = crate::fakie::FakiePhase::Regular;
        sim.fakie.riding_switch = true;
        assert!(sim.should_use_mirrored_character_animation());
        assert!((sim.riding_animation_source_tilt() + 0.4).abs() < 1.0e-6);
    }

    #[test]
    fn transition_under_keeps_b_switch_endpoint_and_base_in_one_stance() {
        let mut regular_to_goofy = SkateSim {
            body_tilt: 0.4,
            ..default()
        };
        regular_to_goofy.fakie.riding_switch = true;
        regular_to_goofy.fakie.switch_out_elapsed_seconds = Some(0.0);
        assert!(regular_to_goofy.stance_source_is_pre_mirrored());
        assert!(!regular_to_goofy.should_use_mirrored_character_animation());
        assert!((regular_to_goofy.riding_animation_source_tilt() + 0.4).abs() < 1.0e-6);

        let mut goofy_to_regular = SkateSim {
            body_tilt: 0.4,
            natural_stance: NaturalStance::Goofy,
            ..default()
        };
        goofy_to_regular.fakie.riding_switch = true;
        goofy_to_regular.fakie.switch_out_elapsed_seconds = Some(0.0);
        assert!(goofy_to_regular.stance_source_is_pre_mirrored());
        assert!(goofy_to_regular.should_use_mirrored_character_animation());
        assert!((goofy_to_regular.riding_animation_source_tilt() - 0.4).abs() < 1.0e-6);
    }

    #[test]
    fn reset_preserves_character_natural_stance() {
        let mut fakie = FakieRuntime::default();
        fakie.riding_switch = true;
        let mut sim = SkateSim {
            natural_stance: NaturalStance::Goofy,
            fakie,
            ..default()
        };
        sim.reset(LevelSpawn::default());
        assert_eq!(sim.natural_stance, NaturalStance::Goofy);
        assert!(!sim.fakie.is_riding_switch());
        assert_eq!(sim.riding_stance(), RidingStance::Goofy);
    }

    #[test]
    fn riding_fakie_filter_accepts_retail_physics_and_established_air_states() {
        assert!(riding_fakie_motion_eligible(BoardAuthority::Physics));
        assert!(riding_fakie_motion_eligible(BoardAuthority::Animation));
        assert!(!riding_fakie_motion_eligible(
            BoardAuthority::FollowAnimationData
        ));

        let mut sim = SkateSim {
            velocity: Vec3::Z * 4.0,
            yaw: std::f32::consts::PI,
            board_authority: BoardAuthority::Animation,
            ..default()
        };
        sim.fakie.time_since_orientation_reset_seconds =
            crate::fakie::RIDING_FAKIE_FROM_RESET_SECONDS;
        sim.fakie.observe_motion(
            DT,
            sim.velocity.x,
            sim.velocity.z,
            sim.yaw,
            riding_fakie_motion_eligible(sim.board_authority),
        );
        assert_eq!(sim.fakie.phase, crate::fakie::FakiePhase::RidingFakie);
        sim.fakie.step(DT, true);
        assert!(sim.fakie.torso_parameter() > 0.0);
        assert!(
            sim.fakie.torso_parameter() < crate::fakie::FAKIE_TORSO_PARAMETER_NEUTRAL,
            "the retail channel slew begins in established air without snapping to its endpoint"
        );
    }

    #[test]
    fn airborne_body_spin_is_mirrored_and_does_not_redirect_planar_velocity() {
        let original_velocity = Vec3::new(3.0, 4.0, -2.0);
        let mut right = SkateSim {
            velocity: original_velocity,
            left_stick: Vec2::X,
            ..default()
        };
        let mut left = SkateSim {
            velocity: original_velocity,
            left_stick: Vec2::NEG_X,
            ..default()
        };

        for _ in 0..12 {
            step_airborne_body_spin(&mut right, DT);
            step_airborne_body_spin(&mut left, DT);
        }

        assert!((right.yaw + left.yaw).abs() <= 1.0e-6);
        assert!((right.body_spin_velocity + left.body_spin_velocity).abs() <= 1.0e-6);
        assert_eq!(right.velocity, original_velocity);
        assert_eq!(left.velocity, original_velocity);
    }

    #[test]
    fn airborne_body_spin_selects_the_authored_directional_upper_body_leaf() {
        let mut sim = SkateSim::default();
        sim.begin_basic_trick(BasicTrickKind::Ollie, TrickHeightEndpoint::High);
        sim.ground_contact_valid = false;
        sim.body_spin_velocity = BODY_SPIN_MAXIMUM_SPEED;
        sim.body_spin_animation_phase_seconds = 0.25;

        let backside = sim.action_animation_state();
        let sample = backside
            .samples
            .iter()
            .find(|sample| sample.clip == BODY_SPIN_BACKSIDE_CLIP)
            .expect("left-stick-left retail body-spin speed selects the BS leaf");
        assert_eq!(sample.weight, 1.0);
        assert_eq!(sample.seek_time_seconds, 0.25);

        sim.body_spin_velocity = -BODY_SPIN_MAXIMUM_SPEED;
        let frontside = sim.action_animation_state();
        assert!(
            frontside
                .samples
                .iter()
                .any(|sample| sample.clip == BODY_SPIN_FRONTSIDE_CLIP)
        );
    }

    #[test]
    fn diagonal_touchdown_loses_side_slip_speed_without_animation_routing() {
        let angle = 45.0_f32.to_radians();
        let initial_speed = 6.0;
        let mut sim = SkateSim {
            velocity: Vec3::new(
                angle.sin() * initial_speed,
                -2.0,
                angle.cos() * initial_speed,
            ),
            yaw: 0.0,
            ground_contact_valid: true,
            ground_surface_id: Some(1),
            ..default()
        };

        step_velocity(&mut sim, DT, false, false, true);

        assert!(sim.landing.is_none());
        assert_eq!(
            sim.last_contact_friction.path,
            crate::contact_friction::ContactFrictionPath::RollingWheelSideSlip
        );
        assert!(sim.last_contact_friction.touchdown_this_step);
        assert_eq!(
            sim.last_contact_friction.one_shot_velocity_delta,
            Vec3::ZERO
        );
        assert!(sim.last_contact_friction.speed_loss > 0.0);
        assert_eq!(sim.velocity.y, -2.0);
    }

    #[test]
    fn continuing_wheel_friction_redirects_and_settles_at_longitudinal_speed() {
        let angle = 30.0_f32.to_radians();
        let initial_speed = 6.0;
        let mut sim = SkateSim {
            velocity: Vec3::new(
                angle.sin() * initial_speed,
                0.0,
                angle.cos() * initial_speed,
            ),
            yaw: 0.0,
            ground_contact_valid: true,
            ground_surface_id: Some(1),
            ..default()
        };

        for _ in 0..120 {
            step_velocity(&mut sim, DT, false, false, false);
        }

        let expected =
            initial_speed * angle.cos() - crate::retail_skateboard::CAPTURED_ROLLING_DECELERATION;
        assert!((sim.speed() - expected).abs() < 0.002);
        assert!(sim.local_lateral_speed().abs() < 1.0e-6);
        assert!(sim.local_longitudinal_speed() > 0.0);
    }

    fn slip_angle(sim: &SkateSim) -> f32 {
        let forward = Vec3::new(sim.yaw.sin(), 0.0, sim.yaw.cos());
        let right = Vec3::new(sim.yaw.cos(), 0.0, -sim.yaw.sin());
        sim.velocity.dot(right).atan2(sim.velocity.dot(forward))
    }
}
