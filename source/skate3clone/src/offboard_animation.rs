//! Evidence-gated adapter from the offboard graph's animation resources to
//! physical Skate 3 TU3 `OffBoard.abin` leaves.
//!
//! The retail ground graph does not select left/right/back locomotion clips.
//! It keeps the forward `BR_*_FWD` family and attaches `OB_BipedWorldX/Z`,
//! `OB_Steer`, and `OB_SteerMagnitude` to the trajectory controller.  This
//! module therefore transports those values without inventing directional
//! animation leaves.
#![allow(dead_code)]

pub const OFFBOARD_ABIN_SHA256: &str =
    "4C7E33FD054B621F24CA9394D29B82EE40108700A7B8CC6CE1DC9AA4F5A5E00D";
pub const OFFBOARD_CATALOG_SHA256: &str =
    "4FD04CDC17209D4DFC15415D7280FF121CC64E07093A11AB451812CDB3677906";
pub const CURRENT_BEVY_MANIFEST_SHA256: &str =
    "6891B82FBB12020B14B1EAECC3E3BF6CE6B0CFF2159AC5D66BFEABC8A68D310D";
pub const CURRENT_BEVY_GLB_SHA256: &str =
    "961E23D9F96D273C141BB06AF3E7CFE6D812B42F86C90CA4BB06311817A50378";
pub const CURRENT_ROOT_MOTION_SHA256: &str =
    "FCC29BC151FC0422B7739A76A560862EB034F419C41E5B7F6F6EEC0BCF795A32";
pub const AUDITED_OFFBOARD_RS_SHA256: &str =
    "27DCAF5726C6F53C29578C44E0032132E6094BFCD402732D0D6FE9E041D911C8";

pub const STAND_EXIT_STEER_MAGNITUDE: f32 = 0.01;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum OffboardGait {
    Walk,
    Run,
    Sprint,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CadenceQuarter {
    Zero,
    TwentyFive,
    Fifty,
    SeventyFive,
}

impl CadenceQuarter {
    pub const fn percent(self) -> u8 {
        match self {
            Self::Zero => 0,
            Self::TwentyFive => 25,
            Self::Fifty => 50,
            Self::SeventyFive => 75,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DismountKind {
    Stand,
    Run,
    FastRun,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MountKind {
    Stand,
    Step,
    Cadence {
        gait: OffboardGait,
        quarter: CadenceQuarter,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PhysicalOffboardLeafKind {
    Dismount(DismountKind),
    Stand,
    Start(OffboardGait),
    Locomotion(OffboardGait),
    Stop {
        gait: OffboardGait,
        quarter: CadenceQuarter,
    },
    Mount(MountKind),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SelectionContract {
    Direct,
    /// A physical endpoint of a virtual `disttocog` selector.  The endpoint is
    /// real, but selecting it alone does not reproduce the retail blend.
    DismountHighEndpoint,
    MatchCadence,
    BlendMatchFrame,
}

/// A physical leaf observed in the TU3 `OffBoard.abin` catalog.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicalOffboardLeaf {
    pub kind: PhysicalOffboardLeafKind,
    pub name: &'static str,
    pub abin_index: u16,
    pub current_glb_index: u16,
    pub native_fps: u16,
    pub frame_count: u16,
    pub part_count: u8,
    pub block_offset: u32,
    pub block_size: u32,
    pub transition_seconds: f32,
    pub repeats: bool,
    pub selection: SelectionContract,
    pub exported_in_current_bevy_asset: bool,
}

impl PhysicalOffboardLeaf {
    /// Time from the first authored sample to the final authored sample.
    pub fn authored_duration_seconds(self) -> f32 {
        self.frame_count.saturating_sub(1) as f32 / self.native_fps as f32
    }
}

const fn leaf(
    kind: PhysicalOffboardLeafKind,
    name: &'static str,
    abin_index: u16,
    current_glb_index: u16,
    frame_count: u16,
    block_offset: u32,
    block_size: u32,
    transition_seconds: f32,
    repeats: bool,
    selection: SelectionContract,
) -> PhysicalOffboardLeaf {
    PhysicalOffboardLeaf {
        kind,
        name,
        abin_index,
        current_glb_index,
        native_fps: 60,
        frame_count,
        part_count: 8,
        block_offset,
        block_size,
        transition_seconds,
        repeats,
        selection,
        exported_in_current_bevy_asset: true,
    }
}

const fn stop(
    gait: OffboardGait,
    quarter: CadenceQuarter,
    name: &'static str,
    abin_index: u16,
    current_glb_index: u16,
    frame_count: u16,
    block_offset: u32,
    block_size: u32,
) -> PhysicalOffboardLeaf {
    leaf(
        PhysicalOffboardLeafKind::Stop { gait, quarter },
        name,
        abin_index,
        current_glb_index,
        frame_count,
        block_offset,
        block_size,
        0.1,
        false,
        SelectionContract::MatchCadence,
    )
}

const fn cadence_mount(
    gait: OffboardGait,
    quarter: CadenceQuarter,
    name: &'static str,
    abin_index: u16,
    current_glb_index: u16,
    frame_count: u16,
    block_offset: u32,
    block_size: u32,
) -> PhysicalOffboardLeaf {
    leaf(
        PhysicalOffboardLeafKind::Mount(MountKind::Cadence { gait, quarter }),
        name,
        abin_index,
        current_glb_index,
        frame_count,
        block_offset,
        block_size,
        0.1,
        false,
        SelectionContract::MatchCadence,
    )
}

/// Exact set of physical resources emitted by the audited `src/offboard.rs`.
///
/// Ordering follows the current GLB animation index, not ABIN storage order.
pub const PHYSICAL_OFFBOARD_CATALOG: [PhysicalOffboardLeaf; 36] = [
    leaf(
        PhysicalOffboardLeafKind::Dismount(DismountKind::FastRun),
        "BR_DISMOUNT_FAST_HI_INTO_RUN_FWD",
        331,
        0,
        79,
        2_157_040,
        9_776,
        0.1,
        false,
        SelectionContract::DismountHighEndpoint,
    ),
    leaf(
        PhysicalOffboardLeafKind::Dismount(DismountKind::Run),
        "BR_DISMOUNT_HI_INTO_RUN_FWD",
        333,
        2,
        72,
        2_176_656,
        8_800,
        0.1,
        false,
        SelectionContract::DismountHighEndpoint,
    ),
    leaf(
        PhysicalOffboardLeafKind::Dismount(DismountKind::Stand),
        "BR_DISMOUNT_HI_INTO_STAND_0",
        334,
        3,
        96,
        2_185_456,
        9_440,
        0.2,
        false,
        SelectionContract::DismountHighEndpoint,
    ),
    cadence_mount(
        OffboardGait::Run,
        CadenceQuarter::Zero,
        "BR_RUN_FWD_0_INTO_MOUNT",
        382,
        6,
        54,
        2_704_384,
        7_376,
    ),
    stop(
        OffboardGait::Run,
        CadenceQuarter::Zero,
        "BR_RUN_FWD_0_INTO_STAND_0",
        225,
        7,
        67,
        1_560_160,
        7_104,
    ),
    cadence_mount(
        OffboardGait::Run,
        CadenceQuarter::TwentyFive,
        "BR_RUN_FWD_25_INTO_MOUNT",
        383,
        8,
        54,
        2_711_760,
        7_328,
    ),
    stop(
        OffboardGait::Run,
        CadenceQuarter::TwentyFive,
        "BR_RUN_FWD_25_INTO_STAND_0",
        228,
        9,
        58,
        1_579_760,
        6_480,
    ),
    cadence_mount(
        OffboardGait::Run,
        CadenceQuarter::Fifty,
        "BR_RUN_FWD_50_INTO_MOUNT",
        384,
        10,
        45,
        2_719_088,
        6_976,
    ),
    stop(
        OffboardGait::Run,
        CadenceQuarter::Fifty,
        "BR_RUN_FWD_50_INTO_STAND_0",
        231,
        11,
        67,
        1_598_848,
        7_040,
    ),
    cadence_mount(
        OffboardGait::Run,
        CadenceQuarter::SeventyFive,
        "BR_RUN_FWD_75_INTO_MOUNT",
        385,
        12,
        48,
        2_726_064,
        7_216,
    ),
    stop(
        OffboardGait::Run,
        CadenceQuarter::SeventyFive,
        "BR_RUN_FWD_75_INTO_STAND_0",
        234,
        13,
        58,
        1_618_224,
        6_496,
    ),
    leaf(
        PhysicalOffboardLeafKind::Locomotion(OffboardGait::Run),
        "BR_RUN_FWD_CYC",
        169,
        14,
        39,
        973_104,
        5_776,
        0.2,
        true,
        SelectionContract::Direct,
    ),
    cadence_mount(
        OffboardGait::Sprint,
        CadenceQuarter::Zero,
        "BR_SPRINT_FWD_0_INTO_MOUNT",
        386,
        15,
        45,
        2_733_280,
        7_184,
    ),
    stop(
        OffboardGait::Sprint,
        CadenceQuarter::Zero,
        "BR_SPRINT_FWD_0_INTO_STAND_0",
        248,
        16,
        62,
        1_715_136,
        5_840,
    ),
    cadence_mount(
        OffboardGait::Sprint,
        CadenceQuarter::TwentyFive,
        "BR_SPRINT_FWD_25_INTO_MOUNT",
        387,
        17,
        49,
        2_740_464,
        7_472,
    ),
    stop(
        OffboardGait::Sprint,
        CadenceQuarter::TwentyFive,
        "BR_SPRINT_FWD_25_INTO_STAND_0",
        249,
        18,
        54,
        1_720_976,
        4_928,
    ),
    cadence_mount(
        OffboardGait::Sprint,
        CadenceQuarter::Fifty,
        "BR_SPRINT_FWD_50_INTO_MOUNT",
        388,
        19,
        55,
        2_747_936,
        7_632,
    ),
    stop(
        OffboardGait::Sprint,
        CadenceQuarter::Fifty,
        "BR_SPRINT_FWD_50_INTO_STAND_0",
        250,
        20,
        62,
        1_725_904,
        5_808,
    ),
    cadence_mount(
        OffboardGait::Sprint,
        CadenceQuarter::SeventyFive,
        "BR_SPRINT_FWD_75_INTO_MOUNT",
        389,
        21,
        57,
        2_755_568,
        8_160,
    ),
    stop(
        OffboardGait::Sprint,
        CadenceQuarter::SeventyFive,
        "BR_SPRINT_FWD_75_INTO_STAND_0",
        251,
        22,
        54,
        1_731_712,
        5_120,
    ),
    leaf(
        PhysicalOffboardLeafKind::Locomotion(OffboardGait::Sprint),
        "BR_SPRINT_FWD_CYC",
        187,
        23,
        31,
        1_086_016,
        4_608,
        0.2,
        true,
        SelectionContract::Direct,
    ),
    leaf(
        PhysicalOffboardLeafKind::Stand,
        "BR_STAND_0_CYC",
        197,
        24,
        781,
        1_138_608,
        51_120,
        0.2,
        true,
        SelectionContract::Direct,
    ),
    leaf(
        PhysicalOffboardLeafKind::Mount(MountKind::Stand),
        "BR_STAND_0_INTO_MOUNT",
        390,
        25,
        52,
        2_763_728,
        7_984,
        0.1,
        false,
        SelectionContract::Direct,
    ),
    leaf(
        PhysicalOffboardLeafKind::Start(OffboardGait::Run),
        "BR_STAND_0_INTO_RUN_FWD",
        256,
        26,
        32,
        1_764_144,
        4_752,
        0.1,
        false,
        SelectionContract::Direct,
    ),
    leaf(
        PhysicalOffboardLeafKind::Start(OffboardGait::Sprint),
        "BR_STAND_0_INTO_SPRINT_FWD",
        257,
        27,
        37,
        1_768_896,
        5_760,
        0.1,
        false,
        SelectionContract::Direct,
    ),
    leaf(
        PhysicalOffboardLeafKind::Start(OffboardGait::Walk),
        "BR_STAND_0_INTO_WALK_FWD",
        258,
        28,
        52,
        1_774_656,
        5_744,
        0.1,
        false,
        SelectionContract::Direct,
    ),
    leaf(
        PhysicalOffboardLeafKind::Mount(MountKind::Step),
        "BR_STEP_INTO_MOUNT",
        391,
        29,
        99,
        2_771_712,
        12_240,
        0.1,
        false,
        SelectionContract::BlendMatchFrame,
    ),
    cadence_mount(
        OffboardGait::Walk,
        CadenceQuarter::Zero,
        "BR_WALK_FWD_0_INTO_MOUNT",
        392,
        30,
        43,
        2_783_952,
        6_848,
    ),
    stop(
        OffboardGait::Walk,
        CadenceQuarter::Zero,
        "BR_WALK_FWD_0_INTO_STAND_0",
        271,
        31,
        67,
        1_859_504,
        5_968,
    ),
    cadence_mount(
        OffboardGait::Walk,
        CadenceQuarter::TwentyFive,
        "BR_WALK_FWD_25_INTO_MOUNT",
        393,
        32,
        37,
        2_790_800,
        6_256,
    ),
    stop(
        OffboardGait::Walk,
        CadenceQuarter::TwentyFive,
        "BR_WALK_FWD_25_INTO_STAND_0",
        274,
        33,
        60,
        1_877_584,
        6_048,
    ),
    cadence_mount(
        OffboardGait::Walk,
        CadenceQuarter::Fifty,
        "BR_WALK_FWD_50_INTO_MOUNT",
        394,
        34,
        39,
        2_797_056,
        6_192,
    ),
    stop(
        OffboardGait::Walk,
        CadenceQuarter::Fifty,
        "BR_WALK_FWD_50_INTO_STAND_0",
        277,
        35,
        67,
        1_894_512,
        6_064,
    ),
    cadence_mount(
        OffboardGait::Walk,
        CadenceQuarter::SeventyFive,
        "BR_WALK_FWD_75_INTO_MOUNT",
        395,
        36,
        47,
        2_803_248,
        6_752,
    ),
    stop(
        OffboardGait::Walk,
        CadenceQuarter::SeventyFive,
        "BR_WALK_FWD_75_INTO_STAND_0",
        280,
        37,
        60,
        1_912_240,
        5_824,
    ),
    leaf(
        PhysicalOffboardLeafKind::Locomotion(OffboardGait::Walk),
        "BR_WALK_FWD_CYC",
        208,
        38,
        57,
        1_434_176,
        6_400,
        0.2,
        true,
        SelectionContract::Direct,
    ),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum VirtualOffboardResource {
    DismountIntoStand,
    DismountIntoRun,
    FastDismountIntoRun,
    WalkIntoStand,
    RunIntoStand,
    SprintIntoStand,
    WalkIntoMount,
    RunIntoMount,
    SprintIntoMount,
}

impl VirtualOffboardResource {
    pub const fn name(self) -> &'static str {
        match self {
            Self::DismountIntoStand => "BR_DISMOUNT_INTO_STAND_0",
            Self::DismountIntoRun => "BR_DISMOUNT_INTO_RUN_FWD",
            Self::FastDismountIntoRun => "BR_DISMOUNT_FAST_INTO_RUN_FWD",
            Self::WalkIntoStand => "BR_WALK_FWD_INTO_STAND_0",
            Self::RunIntoStand => "BR_RUN_FWD_INTO_STAND_0",
            Self::SprintIntoStand => "BR_SPRINT_FWD_INTO_STAND_0",
            Self::WalkIntoMount => "BR_WALK_FWD_INTO_MOUNT",
            Self::RunIntoMount => "BR_RUN_FWD_INTO_MOUNT",
            Self::SprintIntoMount => "BR_SPRINT_FWD_INTO_MOUNT",
        }
    }

    pub const fn parameter_contract(self) -> VirtualParameterContract {
        match self {
            Self::DismountIntoStand | Self::DismountIntoRun | Self::FastDismountIntoRun => {
                VirtualParameterContract::DistanceToCog
            }
            Self::WalkIntoStand
            | Self::RunIntoStand
            | Self::SprintIntoStand
            | Self::WalkIntoMount
            | Self::RunIntoMount
            | Self::SprintIntoMount => VirtualParameterContract::CadencePhase,
        }
    }

    pub const fn missing_evidence(self) -> MissingVirtualEvidence {
        match self.parameter_contract() {
            VirtualParameterContract::DistanceToCog => {
                MissingVirtualEvidence::DismountBlendWeightsAndThresholds
            }
            VirtualParameterContract::CadencePhase => {
                MissingVirtualEvidence::MatchCadenceBoundaryAndClock
            }
        }
    }
}

pub const VIRTUAL_OFFBOARD_RESOURCES: [VirtualOffboardResource; 9] = [
    VirtualOffboardResource::DismountIntoStand,
    VirtualOffboardResource::DismountIntoRun,
    VirtualOffboardResource::FastDismountIntoRun,
    VirtualOffboardResource::WalkIntoStand,
    VirtualOffboardResource::RunIntoStand,
    VirtualOffboardResource::SprintIntoStand,
    VirtualOffboardResource::WalkIntoMount,
    VirtualOffboardResource::RunIntoMount,
    VirtualOffboardResource::SprintIntoMount,
];

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum OffboardResourceClass {
    Physical(&'static PhysicalOffboardLeaf),
    Virtual(VirtualOffboardResource),
    Unknown,
}

pub fn classify_offboard_resource(resource: &str) -> OffboardResourceClass {
    if let Some(leaf) = PHYSICAL_OFFBOARD_CATALOG
        .iter()
        .find(|leaf| leaf.name == resource)
    {
        return OffboardResourceClass::Physical(leaf);
    }
    if let Some(resource) = VIRTUAL_OFFBOARD_RESOURCES
        .iter()
        .copied()
        .find(|candidate| candidate.name() == resource)
    {
        return OffboardResourceClass::Virtual(resource);
    }
    OffboardResourceClass::Unknown
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OffboardTrajectoryParameters {
    pub biped_world_x: f32,
    pub biped_world_z: f32,
    pub steer: f32,
    pub steer_magnitude: f32,
}

impl OffboardTrajectoryParameters {
    pub fn is_turn_or_move_requested(self) -> bool {
        self.steer_magnitude > STAND_EXIT_STEER_MAGNITUDE
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VirtualParameterContract {
    DistanceToCog,
    CadencePhase,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub enum OffboardAnimationParameters {
    #[default]
    None,
    /// Exact attributes attached by the TU3 ground and mount graph.  They are
    /// passed through; this module does not invent the trajectory solver.
    Trajectory(OffboardTrajectoryParameters),
    DistanceToCog(f32),
    /// Normalized cadence phase.  The exact retail quarter-boundary behavior
    /// remains unresolved, so this never selects a leaf in this adapter.
    CadencePhase(f32),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OffboardAnimationAdapterRequest<'a> {
    pub resource: &'a str,
    pub local_time_seconds: f32,
    pub parameters: OffboardAnimationParameters,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResolvedAbinOffboardAnimation<'a> {
    pub source_resource: &'a str,
    pub clip: &'static PhysicalOffboardLeaf,
    pub seek_time_seconds: f32,
    pub transition_seconds: f32,
    pub playback_speed: f32,
    pub repeats: bool,
    pub trajectory: Option<OffboardTrajectoryParameters>,
}

/// A result safe to hand to Bevy: its clip is physical and present in the
/// pinned GLB.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BevyOffboardAnimation<'a> {
    resolved: ResolvedAbinOffboardAnimation<'a>,
}

impl<'a> BevyOffboardAnimation<'a> {
    pub fn resolved(self) -> ResolvedAbinOffboardAnimation<'a> {
        self.resolved
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MissingVirtualEvidence {
    DismountBlendWeightsAndThresholds,
    MatchCadenceBoundaryAndClock,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InvalidParameter {
    NonFiniteTrajectory,
    NegativeSteerMagnitude,
    NonFiniteDistanceToCog,
    NonFiniteCadencePhase,
    CadencePhaseOutsideUnitInterval,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VirtualFailureReason {
    ParametersRequired(VirtualParameterContract),
    UnexpectedParameters,
    InvalidParameter(InvalidParameter),
    MissingEvidence(MissingVirtualEvidence),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum OffboardAnimationFailureReason {
    UnknownResource,
    InvalidLocalTime,
    UnexpectedParametersForPhysicalLeaf,
    InvalidTrajectory(InvalidParameter),
    Virtual {
        resource: VirtualOffboardResource,
        reason: VirtualFailureReason,
    },
    PhysicalLeafNotExported {
        leaf: &'static PhysicalOffboardLeaf,
        manifest_sha256: &'static str,
    },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OffboardAnimationFailure<'a> {
    pub source_resource: &'a str,
    pub reason: OffboardAnimationFailureReason,
}

/// Resolve direct physical leaves.  Virtual aliases are deliberately blocked
/// until their selector behavior is recovered.
pub fn resolve_offboard_request(
    request: OffboardAnimationAdapterRequest<'_>,
) -> Result<ResolvedAbinOffboardAnimation<'_>, OffboardAnimationFailure<'_>> {
    if !request.local_time_seconds.is_finite() || request.local_time_seconds < 0.0 {
        return Err(failure(
            request.resource,
            OffboardAnimationFailureReason::InvalidLocalTime,
        ));
    }

    match classify_offboard_resource(request.resource) {
        OffboardResourceClass::Physical(clip) => {
            let trajectory = match request.parameters {
                OffboardAnimationParameters::None => None,
                OffboardAnimationParameters::Trajectory(parameters) => {
                    validate_trajectory(parameters).map_err(|reason| {
                        failure(
                            request.resource,
                            OffboardAnimationFailureReason::InvalidTrajectory(reason),
                        )
                    })?;
                    Some(parameters)
                }
                OffboardAnimationParameters::DistanceToCog(_)
                | OffboardAnimationParameters::CadencePhase(_) => {
                    return Err(failure(
                        request.resource,
                        OffboardAnimationFailureReason::UnexpectedParametersForPhysicalLeaf,
                    ));
                }
            };
            Ok(ResolvedAbinOffboardAnimation {
                source_resource: request.resource,
                clip,
                seek_time_seconds: request.local_time_seconds,
                transition_seconds: clip.transition_seconds,
                playback_speed: 1.0,
                repeats: clip.repeats,
                trajectory,
            })
        }
        OffboardResourceClass::Virtual(resource) => {
            validate_virtual_parameters(resource, request.parameters)?;
            Err(failure(
                request.resource,
                OffboardAnimationFailureReason::Virtual {
                    resource,
                    reason: VirtualFailureReason::MissingEvidence(resource.missing_evidence()),
                },
            ))
        }
        OffboardResourceClass::Unknown => Err(failure(
            request.resource,
            OffboardAnimationFailureReason::UnknownResource,
        )),
    }
}

pub fn adapt_offboard_for_bevy(
    request: OffboardAnimationAdapterRequest<'_>,
) -> Result<BevyOffboardAnimation<'_>, OffboardAnimationFailure<'_>> {
    let resolved = resolve_offboard_request(request)?;
    if !resolved.clip.exported_in_current_bevy_asset {
        return Err(failure(
            request.resource,
            OffboardAnimationFailureReason::PhysicalLeafNotExported {
                leaf: resolved.clip,
                manifest_sha256: CURRENT_BEVY_MANIFEST_SHA256,
            },
        ));
    }
    Ok(BevyOffboardAnimation { resolved })
}

fn validate_trajectory(parameters: OffboardTrajectoryParameters) -> Result<(), InvalidParameter> {
    if !parameters.biped_world_x.is_finite()
        || !parameters.biped_world_z.is_finite()
        || !parameters.steer.is_finite()
        || !parameters.steer_magnitude.is_finite()
    {
        return Err(InvalidParameter::NonFiniteTrajectory);
    }
    if parameters.steer_magnitude < 0.0 {
        return Err(InvalidParameter::NegativeSteerMagnitude);
    }
    Ok(())
}

fn validate_virtual_parameters(
    resource: VirtualOffboardResource,
    parameters: OffboardAnimationParameters,
) -> Result<(), OffboardAnimationFailure<'static>> {
    let reason = match (resource.parameter_contract(), parameters) {
        (
            VirtualParameterContract::DistanceToCog,
            OffboardAnimationParameters::DistanceToCog(v),
        ) if v.is_finite() => {
            return Ok(());
        }
        (
            VirtualParameterContract::DistanceToCog,
            OffboardAnimationParameters::DistanceToCog(_),
        ) => VirtualFailureReason::InvalidParameter(InvalidParameter::NonFiniteDistanceToCog),
        (VirtualParameterContract::DistanceToCog, OffboardAnimationParameters::None) => {
            VirtualFailureReason::ParametersRequired(VirtualParameterContract::DistanceToCog)
        }
        (VirtualParameterContract::CadencePhase, OffboardAnimationParameters::CadencePhase(v))
            if !v.is_finite() =>
        {
            VirtualFailureReason::InvalidParameter(InvalidParameter::NonFiniteCadencePhase)
        }
        (VirtualParameterContract::CadencePhase, OffboardAnimationParameters::CadencePhase(v))
            if !(0.0..1.0).contains(&v) =>
        {
            VirtualFailureReason::InvalidParameter(
                InvalidParameter::CadencePhaseOutsideUnitInterval,
            )
        }
        (VirtualParameterContract::CadencePhase, OffboardAnimationParameters::CadencePhase(_)) => {
            return Ok(());
        }
        (VirtualParameterContract::CadencePhase, OffboardAnimationParameters::None) => {
            VirtualFailureReason::ParametersRequired(VirtualParameterContract::CadencePhase)
        }
        (_, OffboardAnimationParameters::Trajectory(_))
        | (VirtualParameterContract::DistanceToCog, OffboardAnimationParameters::CadencePhase(_))
        | (VirtualParameterContract::CadencePhase, OffboardAnimationParameters::DistanceToCog(_)) => {
            VirtualFailureReason::UnexpectedParameters
        }
    };

    Err(failure(
        resource.name(),
        OffboardAnimationFailureReason::Virtual { resource, reason },
    ))
}

const fn failure(
    source_resource: &str,
    reason: OffboardAnimationFailureReason,
) -> OffboardAnimationFailure<'_> {
    OffboardAnimationFailure {
        source_resource,
        reason,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn request(
        resource: &str,
        parameters: OffboardAnimationParameters,
    ) -> OffboardAnimationAdapterRequest<'_> {
        OffboardAnimationAdapterRequest {
            resource,
            local_time_seconds: 17.0 / 60.0,
            parameters,
        }
    }

    fn trajectory(x: f32, z: f32) -> OffboardAnimationParameters {
        OffboardAnimationParameters::Trajectory(OffboardTrajectoryParameters {
            biped_world_x: x,
            biped_world_z: z,
            steer: x.atan2(z),
            steer_magnitude: x.hypot(z),
        })
    }

    #[test]
    fn audited_resource_set_has_36_unique_physical_leaves() {
        assert_eq!(PHYSICAL_OFFBOARD_CATALOG.len(), 36);
        let names = PHYSICAL_OFFBOARD_CATALOG
            .iter()
            .map(|leaf| leaf.name)
            .collect::<HashSet<_>>();
        let indices = PHYSICAL_OFFBOARD_CATALOG
            .iter()
            .map(|leaf| leaf.abin_index)
            .collect::<HashSet<_>>();
        assert_eq!(names.len(), 36);
        assert_eq!(indices.len(), 36);
        assert!(PHYSICAL_OFFBOARD_CATALOG.iter().all(|leaf| {
            matches!(
                classify_offboard_resource(leaf.name),
                OffboardResourceClass::Physical(found) if found == leaf
            )
        }));
    }

    #[test]
    fn every_emitted_leaf_is_present_in_the_pinned_glb() {
        let glb_indices = PHYSICAL_OFFBOARD_CATALOG
            .iter()
            .map(|leaf| leaf.current_glb_index)
            .collect::<HashSet<_>>();
        assert_eq!(glb_indices.len(), 36);
        assert!(
            PHYSICAL_OFFBOARD_CATALOG
                .iter()
                .all(|leaf| leaf.exported_in_current_bevy_asset)
        );
        assert_eq!(
            PHYSICAL_OFFBOARD_CATALOG
                .iter()
                .map(|leaf| leaf.current_glb_index)
                .min(),
            Some(0)
        );
        assert_eq!(
            PHYSICAL_OFFBOARD_CATALOG
                .iter()
                .map(|leaf| leaf.current_glb_index)
                .max(),
            Some(38)
        );
    }

    #[test]
    fn gait_cycles_and_stand_repeat_at_their_proven_transitions() {
        for name in [
            "BR_STAND_0_CYC",
            "BR_WALK_FWD_CYC",
            "BR_RUN_FWD_CYC",
            "BR_SPRINT_FWD_CYC",
        ] {
            let resolved =
                resolve_offboard_request(request(name, OffboardAnimationParameters::None)).unwrap();
            assert!(resolved.repeats);
            assert_eq!(resolved.transition_seconds, 0.2);
            assert_eq!(resolved.playback_speed, 1.0);
        }
    }

    #[test]
    fn starts_stops_and_mounts_use_proven_point_one_blends() {
        for leaf in PHYSICAL_OFFBOARD_CATALOG {
            if matches!(
                leaf.kind,
                PhysicalOffboardLeafKind::Start(_)
                    | PhysicalOffboardLeafKind::Stop { .. }
                    | PhysicalOffboardLeafKind::Mount(_)
            ) {
                assert_eq!(leaf.transition_seconds, 0.1, "{}", leaf.name);
                assert!(!leaf.repeats, "{}", leaf.name);
            }
        }
    }

    #[test]
    fn dismount_transitions_differ_between_stand_and_run() {
        let stand = match classify_offboard_resource("BR_DISMOUNT_HI_INTO_STAND_0") {
            OffboardResourceClass::Physical(leaf) => leaf,
            other => panic!("unexpected class: {other:?}"),
        };
        let run = match classify_offboard_resource("BR_DISMOUNT_HI_INTO_RUN_FWD") {
            OffboardResourceClass::Physical(leaf) => leaf,
            other => panic!("unexpected class: {other:?}"),
        };
        assert_eq!(stand.transition_seconds, 0.2);
        assert_eq!(run.transition_seconds, 0.1);
        assert_eq!(stand.selection, SelectionContract::DismountHighEndpoint);
        assert_eq!(run.selection, SelectionContract::DismountHighEndpoint);
    }

    #[test]
    fn all_cadence_quarters_exist_for_each_gait_and_destination() {
        for gait in [OffboardGait::Walk, OffboardGait::Run, OffboardGait::Sprint] {
            for quarter in [
                CadenceQuarter::Zero,
                CadenceQuarter::TwentyFive,
                CadenceQuarter::Fifty,
                CadenceQuarter::SeventyFive,
            ] {
                assert!(
                    PHYSICAL_OFFBOARD_CATALOG.iter().any(|leaf| {
                        leaf.kind == PhysicalOffboardLeafKind::Stop { gait, quarter }
                    })
                );
                assert!(PHYSICAL_OFFBOARD_CATALOG.iter().any(|leaf| {
                    leaf.kind
                        == PhysicalOffboardLeafKind::Mount(MountKind::Cadence { gait, quarter })
                }));
            }
        }
    }

    #[test]
    fn multidirectional_intent_keeps_the_same_forward_physical_leaf() {
        for parameters in [
            trajectory(-1.0, 0.0),
            trajectory(1.0, 0.0),
            trajectory(0.0, -1.0),
            trajectory(0.707, 0.707),
        ] {
            let resolved = resolve_offboard_request(request("BR_RUN_FWD_CYC", parameters)).unwrap();
            assert_eq!(resolved.clip.name, "BR_RUN_FWD_CYC");
            assert_eq!(
                resolved.trajectory,
                Some(match parameters {
                    OffboardAnimationParameters::Trajectory(value) => value,
                    _ => unreachable!(),
                })
            );
        }
    }

    #[test]
    fn turn_request_threshold_is_preserved_without_selecting_a_turn_clip() {
        let idle = OffboardTrajectoryParameters {
            biped_world_x: 0.0,
            biped_world_z: 0.0,
            steer: 0.0,
            steer_magnitude: STAND_EXIT_STEER_MAGNITUDE,
        };
        let turn = OffboardTrajectoryParameters {
            steer_magnitude: STAND_EXIT_STEER_MAGNITUDE + f32::EPSILON,
            ..idle
        };
        assert!(!idle.is_turn_or_move_requested());
        assert!(turn.is_turn_or_move_requested());
        let resolved = resolve_offboard_request(request(
            "BR_STAND_0_INTO_RUN_FWD",
            OffboardAnimationParameters::Trajectory(turn),
        ))
        .unwrap();
        assert_eq!(resolved.clip.name, "BR_STAND_0_INTO_RUN_FWD");
    }

    #[test]
    fn virtual_selectors_are_typed_and_never_leak_to_bevy() {
        for resource in VIRTUAL_OFFBOARD_RESOURCES {
            let parameters = match resource.parameter_contract() {
                VirtualParameterContract::DistanceToCog => {
                    OffboardAnimationParameters::DistanceToCog(0.25)
                }
                VirtualParameterContract::CadencePhase => {
                    OffboardAnimationParameters::CadencePhase(0.5)
                }
            };
            let error = adapt_offboard_for_bevy(request(resource.name(), parameters)).unwrap_err();
            assert_eq!(
                error.reason,
                OffboardAnimationFailureReason::Virtual {
                    resource,
                    reason: VirtualFailureReason::MissingEvidence(resource.missing_evidence()),
                }
            );
        }
    }

    #[test]
    fn malformed_timing_and_parameters_fail_closed() {
        let bad_time = OffboardAnimationAdapterRequest {
            resource: "BR_RUN_FWD_CYC",
            local_time_seconds: f32::NAN,
            parameters: OffboardAnimationParameters::None,
        };
        assert_eq!(
            resolve_offboard_request(bad_time).unwrap_err().reason,
            OffboardAnimationFailureReason::InvalidLocalTime
        );

        let bad_trajectory =
            OffboardAnimationParameters::Trajectory(OffboardTrajectoryParameters {
                biped_world_x: f32::INFINITY,
                biped_world_z: 0.0,
                steer: 0.0,
                steer_magnitude: 1.0,
            });
        assert_eq!(
            resolve_offboard_request(request("BR_RUN_FWD_CYC", bad_trajectory))
                .unwrap_err()
                .reason,
            OffboardAnimationFailureReason::InvalidTrajectory(
                InvalidParameter::NonFiniteTrajectory
            )
        );

        assert_eq!(
            resolve_offboard_request(request(
                "BR_RUN_FWD_CYC",
                OffboardAnimationParameters::CadencePhase(0.25),
            ))
            .unwrap_err()
            .reason,
            OffboardAnimationFailureReason::UnexpectedParametersForPhysicalLeaf
        );
    }

    #[test]
    fn successful_bevy_adaptation_contains_only_a_physical_glb_leaf() {
        for leaf in PHYSICAL_OFFBOARD_CATALOG {
            let adapted =
                adapt_offboard_for_bevy(request(leaf.name, OffboardAnimationParameters::None))
                    .unwrap()
                    .resolved();
            assert_eq!(adapted.clip, &leaf);
            assert!(adapted.clip.exported_in_current_bevy_asset);
            assert!(matches!(
                classify_offboard_resource(adapted.clip.name),
                OffboardResourceClass::Physical(_)
            ));
        }
    }
}
