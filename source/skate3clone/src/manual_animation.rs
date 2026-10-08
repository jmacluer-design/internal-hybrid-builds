//! Evidence-gated TU3 manual animation adapter.
//!
//! `manual_graph` emits physical ABIN names and virtual MotionGraph resources.
//! This module classifies every emitted resource, validates the graph context
//! observed at its call site, and allows only an exact, exported physical leaf
//! to reach Bevy. A similar ABIN name is never treated as a selector mapping.
#![allow(dead_code)]

pub const ONBOARD_ABIN_SHA256: &str =
    "30AA324D6D7C51C325D53E9268C1AD91783B0154D21BBEF5DC5A61EAE8333BD7";
pub const ONBOARD_CATALOG_SHA256: &str =
    "7B2041D3E8FC305D589A05B65B72B5181319197B4CF4FC6C410C8BDDAA131D10";
pub const TAIL_MANUAL_XML_SHA256: &str =
    "39BFAAD4FA388C1898FE1CCB0E284084EA58FED427D38C21923D69A6A24001A8";
pub const NOSE_MANUAL_XML_SHA256: &str =
    "6CAD7008AC169B7B1A93F29EF822B09D9CD25D48F0DB68312410BE0100DE6EA3";
pub const MANUAL_REVERT_XML_SHA256: &str =
    "D4FDE35A59964B4A7B04486B344484B18B962A5A8E3BF1280B7663F372D3677F";
pub const MANUAL_GRAPH_SHA256: &str =
    "87B88A24503E1D22B00F9B8FFC6B618E4C49735D7A0E52ABE97FBB823D610112";
pub const CURRENT_BEVY_MANIFEST_SHA256: &str =
    "6891B82FBB12020B14B1EAECC3E3BF6CE6B0CFF2159AC5D66BFEABC8A68D310D";
pub const CURRENT_BEVY_GLB_SHA256: &str =
    "961E23D9F96D273C141BB06AF3E7CFE6D812B42F86C90CA4BB06311817A50378";
/// Separate decoded manual bank loaded by the Bevy animation graph.
pub const MANUAL_VISUAL_MANIFEST_SHA256: &str =
    "A597A7D707ECF785A4BBD937AB99B079C4DE24DA561B0058BE59511DE2AD1683";
pub const MANUAL_VISUAL_GLB_SHA256: &str =
    "7325355BC9DBC28AD94A04B306325FB3F5DBDDDD737725E0FA738741416E444A";
/// `R_IDLE_HCOM_000 / DISTTOCOG`, the non-crouched riding value inherited by
/// the parent Riding state when a manual begins.
pub const RETAIL_NEUTRAL_RIDING_DIST_TO_COG: f32 = f32::from_bits(0x3F77_04F6);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PhysicalManualLeafKind {
    TailBrakeMoving,
    TailBrakeStationary,
    NoseBrakeStationary,
}

/// One exact leaf directly named by the current manual graph and present in
/// the authoritative TU3 OnBoard ABIN catalog.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PhysicalManualLeaf {
    pub kind: PhysicalManualLeafKind,
    pub name: &'static str,
    pub catalog_index: u16,
    pub native_fps: u16,
    pub frame_count: u16,
    pub part_count: u8,
    pub block_offset: u32,
    pub block_size: u32,
    pub exported_in_current_bevy_asset: bool,
}

impl PhysicalManualLeaf {
    /// Duration between first and final authored samples.
    pub fn authored_duration_seconds(self) -> f32 {
        self.frame_count.saturating_sub(1) as f32 / self.native_fps as f32
    }
}

pub const PHYSICAL_MANUAL_CATALOG: [PhysicalManualLeaf; 3] = [
    PhysicalManualLeaf {
        kind: PhysicalManualLeafKind::NoseBrakeStationary,
        name: "M_NOSEBRAKE_STAT_0_CYC",
        catalog_index: 1370,
        native_fps: 30,
        frame_count: 60,
        part_count: 8,
        block_offset: 5_290_672,
        block_size: 3_696,
        exported_in_current_bevy_asset: false,
    },
    PhysicalManualLeaf {
        kind: PhysicalManualLeafKind::TailBrakeMoving,
        name: "M_BRAKE_N_0_CYC",
        catalog_index: 1400,
        native_fps: 30,
        frame_count: 45,
        part_count: 8,
        block_offset: 5_461_552,
        block_size: 4_496,
        exported_in_current_bevy_asset: false,
    },
    PhysicalManualLeaf {
        kind: PhysicalManualLeafKind::TailBrakeStationary,
        name: "M_BRAKE_STAT_0_CYC",
        catalog_index: 1401,
        native_fps: 30,
        frame_count: 45,
        part_count: 8,
        block_offset: 5_466_048,
        block_size: 3_216,
        exported_in_current_bevy_asset: false,
    },
];

/// Exact physical leaves reachable from the recovered TU3 manual selectors.
///
/// Frame counts come from the authoritative OnBoard ABIN blocks. Keeping this
/// inventory in one place also makes the visual-bank completeness check cover
/// every authored low/high, crouch/normal and FS/BS branch.
pub const MANUAL_VISUAL_CLIPS: [(&str, u16); 32] = [
    ("M_NOSEBRAKE_N_0_CYC", 45),
    ("M_NOSEBRAKE_STAT_0_CYC", 60),
    ("M_NOSEIDLE_CROUCH_0_CYC", 102),
    ("M_NOSEIDLE_CROUCH_0_INTO", 15),
    ("M_NOSEIDLE_CROUCH_0_OUT", 15),
    ("M_NOSEIDLE_CROUCH_0_TURN_BS_0_CYC", 30),
    ("M_NOSEIDLE_CROUCH_0_TURN_FS_0_CYC", 30),
    ("M_NOSEIDLE_N_0_CYC", 102),
    ("M_NOSEIDLE_N_0_INTO", 15),
    ("M_NOSEIDLE_N_0_OUT", 15),
    ("M_NOSEIDLE_N_0_TURN_BS_0_CYC", 115),
    ("M_NOSEIDLE_N_0_TURN_FS_0_CYC", 115),
    ("M_NOSELEAN_CROUCH_0_CYC", 30),
    ("M_NOSELEAN_CROUCH_0_TURN_BS_0_CYC", 30),
    ("M_NOSELEAN_CROUCH_0_TURN_FS_0_CYC", 30),
    ("M_NOSELEAN_N_0_CYC", 30),
    ("M_NOSELEAN_TURN_BS_0_CYC", 30),
    ("M_NOSELEAN_TURN_FS_0_CYC", 30),
    ("M_BRAKE_N_0_CYC", 45),
    ("M_BRAKE_STAT_0_CYC", 45),
    ("M_IDLE_CROUCH_0_CYC", 100),
    ("M_IDLE_CROUCH_0_TURN_BS_0_CYC", 115),
    ("M_IDLE_CROUCH_0_TURN_FS_0_CYC", 115),
    ("M_IDLE_N_0_CYC", 100),
    ("M_IDLE_N_0_TURN_BS_0_CYC", 115),
    ("M_IDLE_N_0_TURN_FS_0_CYC", 115),
    ("M_LEAN_CROUCH_0_CYC", 30),
    ("M_LEAN_CROUCH_0_TURN_BS_0_CYC", 30),
    ("M_LEAN_CROUCH_0_TURN_FS_0_CYC", 30),
    ("M_LEAN_N_0_CYC", 115),
    ("M_LEAN_TURN_BS_0_CYC", 30),
    ("M_LEAN_TURN_FS_0_CYC", 30),
];

/// The separate decoded manual GLB contains these exact 30 Hz OnBoard leaves.
///
/// Its Blender/glTF exporter writes source sample `n` at scene sample
/// `(n + 1) / 60`, so Bevy must convert retail time through the native rate
/// instead of seeking the exported clip with retail seconds directly.
pub fn manual_visual_native_fps(name: &str) -> Option<u16> {
    MANUAL_VISUAL_CLIPS
        .iter()
        .any(|(clip, _)| *clip == name)
        .then_some(30)
}

/// Source sample count for each decoded manual leaf in the pinned visual bank.
///
/// These counts come from the same authoritative OnBoard ABIN inventory used
/// by the adapter. They let an outgoing non-looping PlayAnimation advance to
/// its final authored sample without wrapping while a later state blends in.
pub fn manual_visual_frame_count(name: &str) -> Option<u16> {
    MANUAL_VISUAL_CLIPS
        .iter()
        .find_map(|(clip, frames)| (*clip == name).then_some(*frames))
}

pub fn manual_visual_duration_seconds(name: &str) -> Option<f32> {
    let frame_count = manual_visual_frame_count(name)?;
    let native_fps = manual_visual_native_fps(name)?;
    Some(frame_count.saturating_sub(1) as f32 / native_fps as f32)
}

/// INTO and OUT are the only decoded manual leaves requested as non-looping
/// resources by the retail manual XML.
pub fn manual_visual_repeats(name: &str) -> Option<bool> {
    manual_visual_frame_count(name).map(|_| !name.ends_with("_INTO") && !name.ends_with("_OUT"))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ManualSide {
    Tail,
    Nose,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum RevertDirection {
    Fs,
    Bs,
}

impl RevertDirection {
    pub const fn graph_attribute(self) -> f32 {
        match self {
            Self::Fs => -1.0,
            Self::Bs => 1.0,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum VirtualManualResource {
    NoseInto,
    TailRollingBackward,
    TailForwardOrStationary,
    NoseRollingForward,
    NoseBackwardOrStationary,
    NoseBrakeMovingAlias,
    NoseOut,
    TailFsRevert,
    TailBsRevert,
    NoseFsRevert,
    NoseBsRevert,
}

impl VirtualManualResource {
    pub const fn name(self) -> &'static str {
        match self {
            Self::NoseInto => "B_NOSE_MANUAL_INTO",
            Self::TailRollingBackward => "B_TAIL_MANUAL",
            Self::TailForwardOrStationary => "B_TAIL_MANUAL_LOW",
            Self::NoseRollingForward => "B_NOSE_MANUAL",
            Self::NoseBackwardOrStationary => "B_NOSE_MANUAL_LOW",
            Self::NoseBrakeMovingAlias => "S_M_NOSEBRAKE_N_0_CYC",
            Self::NoseOut => "B_NOSE_MANUAL_OUT",
            Self::TailFsRevert => "B_TAIL_MANUAL_FS_REVERT",
            Self::TailBsRevert => "B_TAIL_MANUAL_BS_REVERT",
            Self::NoseFsRevert => "B_NOSE_MANUAL_FS_REVERT",
            Self::NoseBsRevert => "B_NOSE_MANUAL_BS_REVERT",
        }
    }

    pub const fn parameter_contract(self) -> ManualParameterContract {
        match self {
            Self::NoseInto => ManualParameterContract::Into {
                side: ManualSide::Nose,
            },
            Self::TailRollingBackward => ManualParameterContract::Cycle {
                side: ManualSide::Tail,
                manual_angle_published: true,
            },
            Self::TailForwardOrStationary => ManualParameterContract::Cycle {
                side: ManualSide::Tail,
                manual_angle_published: false,
            },
            Self::NoseRollingForward => ManualParameterContract::Cycle {
                side: ManualSide::Nose,
                manual_angle_published: true,
            },
            Self::NoseBackwardOrStationary => ManualParameterContract::Cycle {
                side: ManualSide::Nose,
                manual_angle_published: false,
            },
            Self::NoseBrakeMovingAlias => ManualParameterContract::Brake {
                side: ManualSide::Nose,
                moving: true,
            },
            Self::NoseOut => ManualParameterContract::NoneObserved,
            Self::TailFsRevert => ManualParameterContract::Revert {
                side: ManualSide::Tail,
                direction: RevertDirection::Fs,
            },
            Self::TailBsRevert => ManualParameterContract::Revert {
                side: ManualSide::Tail,
                direction: RevertDirection::Bs,
            },
            Self::NoseFsRevert => ManualParameterContract::Revert {
                side: ManualSide::Nose,
                direction: RevertDirection::Fs,
            },
            Self::NoseBsRevert => ManualParameterContract::Revert {
                side: ManualSide::Nose,
                direction: RevertDirection::Bs,
            },
        }
    }

    pub const fn missing_evidence(self) -> MissingVirtualEvidence {
        match self {
            Self::NoseBrakeMovingAlias => MissingVirtualEvidence::AliasTargetAndTiming,
            Self::TailFsRevert | Self::TailBsRevert | Self::NoseFsRevert | Self::NoseBsRevert => {
                MissingVirtualEvidence::RevertLeafMirrorWeightsAndDuration
            }
            Self::NoseInto
            | Self::TailRollingBackward
            | Self::TailForwardOrStationary
            | Self::NoseRollingForward
            | Self::NoseBackwardOrStationary
            | Self::NoseOut => MissingVirtualEvidence::SelectedLeavesWeightsAndDuration,
        }
    }
}

pub const VIRTUAL_MANUAL_RESOURCES: [VirtualManualResource; 11] = [
    VirtualManualResource::NoseInto,
    VirtualManualResource::TailRollingBackward,
    VirtualManualResource::TailForwardOrStationary,
    VirtualManualResource::NoseRollingForward,
    VirtualManualResource::NoseBackwardOrStationary,
    VirtualManualResource::NoseBrakeMovingAlias,
    VirtualManualResource::NoseOut,
    VirtualManualResource::TailFsRevert,
    VirtualManualResource::TailBsRevert,
    VirtualManualResource::NoseFsRevert,
    VirtualManualResource::NoseBsRevert,
];

/// Exact unique resource set emitted by `ManualRuntime::animation_request`.
pub const MANUAL_GRAPH_RESOURCES: [&str; 14] = [
    "B_NOSE_MANUAL_INTO",
    "B_TAIL_MANUAL",
    "B_TAIL_MANUAL_LOW",
    "B_NOSE_MANUAL",
    "B_NOSE_MANUAL_LOW",
    "M_BRAKE_N_0_CYC",
    "M_BRAKE_STAT_0_CYC",
    "S_M_NOSEBRAKE_N_0_CYC",
    "M_NOSEBRAKE_STAT_0_CYC",
    "B_NOSE_MANUAL_OUT",
    "B_TAIL_MANUAL_FS_REVERT",
    "B_TAIL_MANUAL_BS_REVERT",
    "B_NOSE_MANUAL_FS_REVERT",
    "B_NOSE_MANUAL_BS_REVERT",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ManualParameterContract {
    NoneObserved,
    Into {
        side: ManualSide,
    },
    Cycle {
        side: ManualSide,
        manual_angle_published: bool,
    },
    Brake {
        side: ManualSide,
        moving: bool,
    },
    Revert {
        side: ManualSide,
        direction: RevertDirection,
    },
}

/// Values observed in the MotionGraph state owning a `PlayAnimation` request.
///
/// These are capture-context requirements. Static XML does not prove that
/// every value is consumed inside the virtual resource selector.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ManualAnimationParameters {
    pub balance: Option<f32>,
    pub spin: Option<f32>,
    pub manual_angle: Option<f32>,
    pub distance_to_cog: Option<f32>,
    pub manual_brake: Option<f32>,
    pub revert_dir: Option<f32>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GraphResourceClass {
    Physical(&'static PhysicalManualLeaf),
    Virtual(VirtualManualResource),
    Unknown,
}

pub fn classify_manual_resource(resource: &str) -> GraphResourceClass {
    if let Some(leaf) = PHYSICAL_MANUAL_CATALOG
        .iter()
        .find(|leaf| leaf.name == resource)
    {
        return GraphResourceClass::Physical(leaf);
    }
    if let Some(resource) = VIRTUAL_MANUAL_RESOURCES
        .iter()
        .copied()
        .find(|candidate| candidate.name() == resource)
    {
        return GraphResourceClass::Virtual(resource);
    }
    GraphResourceClass::Unknown
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ManualAnimationAdapterRequest {
    pub source_resource: &'static str,
    pub local_time_seconds: f32,
    pub transition_seconds: f32,
    pub playback_speed: f32,
    pub repeats: bool,
    pub apply_posture: bool,
    pub parameters: ManualAnimationParameters,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WeightedManualLeafSample {
    pub leaf: &'static PhysicalManualLeaf,
    pub weight: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResolvedAbinManualAnimation {
    pub source_resource: &'static str,
    pub sample: WeightedManualLeafSample,
    pub local_time_seconds: f32,
    pub transition_seconds: f32,
    pub playback_speed: f32,
    pub repeats: bool,
    pub apply_posture: bool,
}

/// Bevy-ready data. It can only be constructed through
/// `adapt_manual_for_bevy`, after exact leaf and manifest validation.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BevyManualAnimation {
    leaf: &'static PhysicalManualLeaf,
    pub local_time_seconds: f32,
    pub transition_seconds: f32,
    pub playback_speed: f32,
    pub repeats: bool,
    pub apply_posture: bool,
}

/// A bounded presentation mapping backed by decoded physical clips.
///
/// The ABIN inventory, clip data and state-tree timing are observed. The
/// virtual-selector-to-leaf links remain inferred from the synchronized manual
/// fixture inventory and are kept separate from `resolve_manual_request`,
/// which continues to reject unproven selector claims.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ManualVisualCandidate {
    pub source_resource: &'static str,
    pub physical_leaf: &'static str,
    pub authored_duration_seconds: f32,
    pub local_time_seconds: f32,
    pub transition_seconds: f32,
    pub repeats: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ManualVisualTreeSample {
    pub physical_leaf: &'static str,
    pub weight: f32,
    pub local_time_seconds: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ResolvedManualVisualTree {
    pub source_resource: &'static str,
    pub samples: Vec<ManualVisualTreeSample>,
    pub transition_seconds: f32,
    pub repeats: bool,
}

impl BevyManualAnimation {
    pub const fn leaf(self) -> &'static PhysicalManualLeaf {
        self.leaf
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InvalidTimingField {
    LocalTime,
    Transition,
    PlaybackSpeed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ManualParameterField {
    Balance,
    Spin,
    ManualAngle,
    DistanceToCog,
    ManualBrake,
    RevertDir,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ParameterFailureReason {
    Missing,
    NotFinite,
    TailBalanceMustBeNegative,
    NoseBalanceMustBePositive,
    ExpectedExactGraphValue,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ParameterFailure {
    pub field: ManualParameterField,
    pub reason: ParameterFailureReason,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MissingVirtualEvidence {
    SelectedLeavesWeightsAndDuration,
    AliasTargetAndTiming,
    RevertLeafMirrorWeightsAndDuration,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ManualAnimationFailureReason {
    InvalidTiming(InvalidTimingField),
    InvalidParameters(ParameterFailure),
    Virtual {
        resource: VirtualManualResource,
        missing: MissingVirtualEvidence,
    },
    PhysicalLeafNotExported {
        leaf: &'static PhysicalManualLeaf,
        manifest_sha256: &'static str,
    },
    UnknownResource,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ManualAnimationFailure {
    pub source_resource: &'static str,
    pub reason: ManualAnimationFailureReason,
}

/// Resolves only names proven to be exact physical OnBoard ABIN leaves.
pub fn resolve_manual_request(
    request: ManualAnimationAdapterRequest,
) -> Result<ResolvedAbinManualAnimation, ManualAnimationFailure> {
    validate_timing(request)?;
    match classify_manual_resource(request.source_resource) {
        GraphResourceClass::Physical(leaf) => {
            let contract = match leaf.kind {
                PhysicalManualLeafKind::TailBrakeMoving => ManualParameterContract::Brake {
                    side: ManualSide::Tail,
                    moving: true,
                },
                PhysicalManualLeafKind::TailBrakeStationary => ManualParameterContract::Brake {
                    side: ManualSide::Tail,
                    moving: false,
                },
                PhysicalManualLeafKind::NoseBrakeStationary => ManualParameterContract::Brake {
                    side: ManualSide::Nose,
                    moving: false,
                },
            };
            validate_parameters(request.source_resource, contract, request.parameters)?;
            Ok(ResolvedAbinManualAnimation {
                source_resource: request.source_resource,
                sample: WeightedManualLeafSample { leaf, weight: 1.0 },
                local_time_seconds: request.local_time_seconds,
                transition_seconds: request.transition_seconds,
                playback_speed: request.playback_speed,
                repeats: request.repeats,
                apply_posture: request.apply_posture,
            })
        }
        GraphResourceClass::Virtual(resource) => {
            validate_parameters(
                request.source_resource,
                resource.parameter_contract(),
                request.parameters,
            )?;
            Err(failure(
                request.source_resource,
                ManualAnimationFailureReason::Virtual {
                    resource,
                    missing: resource.missing_evidence(),
                },
            ))
        }
        GraphResourceClass::Unknown => Err(failure(
            request.source_resource,
            ManualAnimationFailureReason::UnknownResource,
        )),
    }
}

pub fn adapt_manual_for_bevy(
    request: ManualAnimationAdapterRequest,
) -> Result<BevyManualAnimation, ManualAnimationFailure> {
    let resolved = resolve_manual_request(request)?;
    if !resolved.sample.leaf.exported_in_current_bevy_asset {
        return Err(failure(
            request.source_resource,
            ManualAnimationFailureReason::PhysicalLeafNotExported {
                leaf: resolved.sample.leaf,
                manifest_sha256: CURRENT_BEVY_MANIFEST_SHA256,
            },
        ));
    }
    Ok(BevyManualAnimation {
        leaf: resolved.sample.leaf,
        local_time_seconds: resolved.local_time_seconds,
        transition_seconds: resolved.transition_seconds,
        playback_speed: resolved.playback_speed,
        repeats: resolved.repeats,
        apply_posture: resolved.apply_posture,
    })
}

/// Legacy single-leaf compatibility resolver.
///
/// The live manual path uses `resolve_manual_visual_tree`; this helper remains
/// only for the older evidence-boundary tests and must not flatten a retail
/// selector into the runtime presentation.
pub fn resolve_manual_visual_candidate(
    request: ManualAnimationAdapterRequest,
) -> Result<ManualVisualCandidate, ManualAnimationFailure> {
    validate_timing(request)?;
    let (physical_leaf, frames, contract) = match classify_manual_resource(request.source_resource)
    {
        GraphResourceClass::Physical(leaf) => {
            let contract = match leaf.kind {
                PhysicalManualLeafKind::TailBrakeMoving => ManualParameterContract::Brake {
                    side: ManualSide::Tail,
                    moving: true,
                },
                PhysicalManualLeafKind::TailBrakeStationary => ManualParameterContract::Brake {
                    side: ManualSide::Tail,
                    moving: false,
                },
                PhysicalManualLeafKind::NoseBrakeStationary => ManualParameterContract::Brake {
                    side: ManualSide::Nose,
                    moving: false,
                },
            };
            (leaf.name, leaf.frame_count, contract)
        }
        GraphResourceClass::Virtual(resource) => {
            let mapped = match resource {
                VirtualManualResource::NoseInto => ("M_NOSEIDLE_N_0_INTO", 15),
                VirtualManualResource::TailRollingBackward
                | VirtualManualResource::TailForwardOrStationary => ("M_IDLE_N_0_CYC", 100),
                VirtualManualResource::NoseRollingForward
                | VirtualManualResource::NoseBackwardOrStationary => ("M_NOSEIDLE_N_0_CYC", 102),
                VirtualManualResource::NoseBrakeMovingAlias => ("M_NOSEBRAKE_N_0_CYC", 45),
                VirtualManualResource::NoseOut => ("M_NOSEIDLE_N_0_OUT", 15),
                VirtualManualResource::TailFsRevert
                | VirtualManualResource::TailBsRevert
                | VirtualManualResource::NoseFsRevert
                | VirtualManualResource::NoseBsRevert => {
                    return Err(failure(
                        request.source_resource,
                        ManualAnimationFailureReason::Virtual {
                            resource,
                            missing: resource.missing_evidence(),
                        },
                    ));
                }
            };
            (mapped.0, mapped.1, resource.parameter_contract())
        }
        GraphResourceClass::Unknown => {
            return Err(failure(
                request.source_resource,
                ManualAnimationFailureReason::UnknownResource,
            ));
        }
    };
    validate_parameters(request.source_resource, contract, request.parameters)?;
    let authored_duration_seconds = frames.saturating_sub(1) as f32 / 30.0;
    let local_time_seconds = if request.repeats {
        request
            .local_time_seconds
            .rem_euclid(authored_duration_seconds)
    } else {
        request.local_time_seconds.min(authored_duration_seconds)
    };
    Ok(ManualVisualCandidate {
        source_resource: request.source_resource,
        physical_leaf,
        authored_duration_seconds,
        local_time_seconds,
        transition_seconds: request.transition_seconds,
        repeats: request.repeats,
    })
}

/// Resolve the physical leaf blend encoded by the retail type-7/type-8 ABIN
/// manual tree.
///
/// The cycle hierarchy is `MANUAL_ANGLE -> DISTTOCOG -> ANGLE`. TU3
/// `sub_82D25378` sorts the authored child coordinates, selects the two
/// neighboring endpoints, and linearly clamps/interpolates between them.
/// The coordinates come from physical clip attributes; they are not generic
/// 0/1 weights. Straight input selects only the neutral ANGLE leaf.
pub fn resolve_manual_visual_tree(
    request: ManualAnimationAdapterRequest,
) -> Result<ResolvedManualVisualTree, ManualAnimationFailure> {
    validate_timing(request)?;
    let class = classify_manual_resource(request.source_resource);
    let contract = match class {
        GraphResourceClass::Physical(leaf) => match leaf.kind {
            PhysicalManualLeafKind::TailBrakeMoving => ManualParameterContract::Brake {
                side: ManualSide::Tail,
                moving: true,
            },
            PhysicalManualLeafKind::TailBrakeStationary => ManualParameterContract::Brake {
                side: ManualSide::Tail,
                moving: false,
            },
            PhysicalManualLeafKind::NoseBrakeStationary => ManualParameterContract::Brake {
                side: ManualSide::Nose,
                moving: false,
            },
        },
        GraphResourceClass::Virtual(resource) => resource.parameter_contract(),
        GraphResourceClass::Unknown => {
            return Err(failure(
                request.source_resource,
                ManualAnimationFailureReason::UnknownResource,
            ));
        }
    };
    validate_parameters(request.source_resource, contract, request.parameters)?;

    let single = |physical_leaf: &'static str| {
        let duration = manual_visual_duration_seconds(physical_leaf)
            .expect("every recovered manual tree leaf is inventoried");
        let local_time_seconds = if request.repeats {
            request.local_time_seconds.rem_euclid(duration)
        } else {
            request.local_time_seconds.min(duration)
        };
        Ok(ResolvedManualVisualTree {
            source_resource: request.source_resource,
            samples: vec![ManualVisualTreeSample {
                physical_leaf,
                weight: 1.0,
                local_time_seconds,
            }],
            transition_seconds: request.transition_seconds,
            repeats: request.repeats,
        })
    };

    match class {
        GraphResourceClass::Physical(leaf) => single(leaf.name),
        GraphResourceClass::Virtual(VirtualManualResource::NoseInto) => {
            resolve_nose_dist_tree(request, true)
        }
        GraphResourceClass::Virtual(VirtualManualResource::NoseOut) => {
            resolve_nose_dist_tree(request, false)
        }
        GraphResourceClass::Virtual(VirtualManualResource::NoseBrakeMovingAlias) => {
            single("M_NOSEBRAKE_N_0_CYC")
        }
        GraphResourceClass::Virtual(
            resource @ (VirtualManualResource::TailRollingBackward
            | VirtualManualResource::TailForwardOrStationary
            | VirtualManualResource::NoseRollingForward
            | VirtualManualResource::NoseBackwardOrStationary),
        ) => {
            let side = match resource {
                VirtualManualResource::TailRollingBackward
                | VirtualManualResource::TailForwardOrStationary => ManualSide::Tail,
                _ => ManualSide::Nose,
            };
            let high_available = matches!(
                resource,
                VirtualManualResource::TailRollingBackward
                    | VirtualManualResource::NoseRollingForward
            );
            resolve_cycle_tree(request, side, high_available)
        }
        GraphResourceClass::Virtual(resource) => Err(failure(
            request.source_resource,
            ManualAnimationFailureReason::Virtual {
                resource,
                missing: resource.missing_evidence(),
            },
        )),
        GraphResourceClass::Unknown => unreachable!("unknown resource returned above"),
    }
}

fn resolve_cycle_tree(
    request: ManualAnimationAdapterRequest,
    side: ManualSide,
    high_available: bool,
) -> Result<ResolvedManualVisualTree, ManualAnimationFailure> {
    let spin = request.parameters.spin.unwrap_or_default().clamp(-1.0, 1.0);
    let distance_to_cog = request
        .parameters
        .distance_to_cog
        .unwrap_or(RETAIL_NEUTRAL_RIDING_DIST_TO_COG);
    let (low_weight, high_weight) = if high_available {
        two_endpoint_weights(
            0.0,
            match side {
                ManualSide::Tail => -0.9,
                ManualSide::Nose => 0.9,
            },
            request.parameters.manual_angle.unwrap_or_default(),
        )
    } else {
        (1.0, 0.0)
    };
    let base_duration = match side {
        ManualSide::Tail => 99.0 / 30.0,
        ManualSide::Nose => 101.0 / 30.0,
    };
    let normalized_phase = request.local_time_seconds.rem_euclid(base_duration) / base_duration;
    let mut samples = Vec::with_capacity(8);
    for (high, outer_weight) in [(false, low_weight), (true, high_weight)] {
        if outer_weight <= f32::EPSILON {
            continue;
        }
        for (physical_leaf, inner_weight) in
            resolve_posture_and_direction(side, high, spin, distance_to_cog)
        {
            let weight = outer_weight * inner_weight;
            if weight <= f32::EPSILON {
                continue;
            }
            let duration = manual_visual_duration_seconds(physical_leaf)
                .expect("every recovered manual selector leaf is inventoried");
            samples.push(ManualVisualTreeSample {
                physical_leaf,
                weight,
                local_time_seconds: normalized_phase * duration,
            });
        }
    }
    Ok(ResolvedManualVisualTree {
        source_resource: request.source_resource,
        samples,
        transition_seconds: request.transition_seconds,
        repeats: request.repeats,
    })
}

fn resolve_nose_dist_tree(
    request: ManualAnimationAdapterRequest,
    into: bool,
) -> Result<ResolvedManualVisualTree, ManualAnimationFailure> {
    let distance_to_cog = request
        .parameters
        .distance_to_cog
        .unwrap_or(RETAIL_NEUTRAL_RIDING_DIST_TO_COG);
    let (crouch_weight, normal_weight) = if into {
        two_endpoint_weights(
            f32::from_bits(0x3F19_3133),
            f32::from_bits(0x3F65_78FC),
            distance_to_cog,
        )
    } else {
        two_endpoint_weights(
            f32::from_bits(0x3F19_37C8),
            f32::from_bits(0x3F64_62DB),
            distance_to_cog,
        )
    };
    let names = if into {
        [
            ("M_NOSEIDLE_CROUCH_0_INTO", crouch_weight),
            ("M_NOSEIDLE_N_0_INTO", normal_weight),
        ]
    } else {
        [
            ("M_NOSEIDLE_CROUCH_0_OUT", crouch_weight),
            ("M_NOSEIDLE_N_0_OUT", normal_weight),
        ]
    };
    let samples = names
        .into_iter()
        .filter(|(_, weight)| *weight > f32::EPSILON)
        .map(|(physical_leaf, weight)| {
            let duration = manual_visual_duration_seconds(physical_leaf)
                .expect("every recovered manual selector leaf is inventoried");
            ManualVisualTreeSample {
                physical_leaf,
                weight,
                local_time_seconds: request.local_time_seconds.min(duration),
            }
        })
        .collect();
    Ok(ResolvedManualVisualTree {
        source_resource: request.source_resource,
        samples,
        transition_seconds: request.transition_seconds,
        repeats: request.repeats,
    })
}

fn resolve_posture_and_direction(
    side: ManualSide,
    high: bool,
    spin: f32,
    distance_to_cog: f32,
) -> Vec<(&'static str, f32)> {
    let normal = resolve_direction_row(spin);
    let crouch = resolve_direction_row(spin);
    let normal_coordinate: f32 = normal
        .iter()
        .map(|(direction, weight)| cycle_dist_to_cog(side, high, false, *direction) * weight)
        .sum();
    let crouch_coordinate: f32 = crouch
        .iter()
        .map(|(direction, weight)| cycle_dist_to_cog(side, high, true, *direction) * weight)
        .sum();
    let (normal_weight, crouch_weight) =
        two_endpoint_weights(normal_coordinate, crouch_coordinate, distance_to_cog);
    normal
        .into_iter()
        .map(|(direction, weight)| {
            (
                cycle_leaf(side, high, false, direction),
                weight * normal_weight,
            )
        })
        .chain(crouch.into_iter().map(|(direction, weight)| {
            (
                cycle_leaf(side, high, true, direction),
                weight * crouch_weight,
            )
        }))
        .filter(|(_, weight)| *weight > f32::EPSILON)
        .collect()
}

fn resolve_direction_row(spin: f32) -> Vec<(i32, f32)> {
    // Authored ANGLE coordinates are BS=-1, neutral=0, FS=+1.
    if spin < 0.0 {
        vec![(2, -spin), (0, 1.0 + spin)]
    } else if spin > 0.0 {
        vec![(0, 1.0 - spin), (1, spin)]
    } else {
        vec![(0, 1.0)]
    }
}

fn two_endpoint_weights(first_coordinate: f32, second_coordinate: f32, value: f32) -> (f32, f32) {
    let range = second_coordinate - first_coordinate;
    if range.abs() <= f32::EPSILON {
        return (1.0, 0.0);
    }
    let second_weight = ((value - first_coordinate) / range).clamp(0.0, 1.0);
    (1.0 - second_weight, second_weight)
}

fn cycle_dist_to_cog(side: ManualSide, high: bool, crouch: bool, direction: i32) -> f32 {
    match (side, high, crouch, direction) {
        (ManualSide::Nose, false, false, 1) => f32::from_bits(0x3F5F_2CF4),
        (ManualSide::Nose, false, false, 2) => f32::from_bits(0x3F65_1C5F),
        (ManualSide::Nose, false, false, 0) => f32::from_bits(0x3F53_6664),
        (ManualSide::Nose, false, true, 1) => f32::from_bits(0x3F1B_425C),
        (ManualSide::Nose, false, true, 2) => f32::from_bits(0x3F1C_0FB0),
        (ManualSide::Nose, false, true, 0) => f32::from_bits(0x3F0E_F82D),
        (ManualSide::Nose, true, false, 1) => f32::from_bits(0x3F6A_2CE5),
        (ManualSide::Nose, true, false, 2) => f32::from_bits(0x3F62_6B56),
        (ManualSide::Nose, true, false, 0) => f32::from_bits(0x3F55_00A1),
        (ManualSide::Nose, true, true, 1) => f32::from_bits(0x3F1B_2CC4),
        (ManualSide::Nose, true, true, 2) => f32::from_bits(0x3F1B_E714),
        (ManualSide::Nose, true, true, 0) => f32::from_bits(0x3F1C_E4AD),
        (ManualSide::Tail, false, false, 1) => f32::from_bits(0x3F68_CA7F),
        (ManualSide::Tail, false, false, 2) => f32::from_bits(0x3F64_2AE0),
        (ManualSide::Tail, false, false, 0) => f32::from_bits(0x3F5C_97C0),
        (ManualSide::Tail, false, true, 1) => f32::from_bits(0x3F36_5A92),
        (ManualSide::Tail, false, true, 2) => f32::from_bits(0x3F31_7607),
        (ManualSide::Tail, false, true, 0) => f32::from_bits(0x3F2F_6AD2),
        (ManualSide::Tail, true, false, 1) => f32::from_bits(0x3F65_2103),
        (ManualSide::Tail, true, false, 2) => f32::from_bits(0x3F5B_584D),
        (ManualSide::Tail, true, false, 0) => f32::from_bits(0x3F3B_C124),
        (ManualSide::Tail, true, true, 1) => f32::from_bits(0x3F1B_8D2A),
        (ManualSide::Tail, true, true, 2) => f32::from_bits(0x3F0B_5C55),
        (ManualSide::Tail, true, true, 0) => f32::from_bits(0x3F11_E91D),
        _ => unreachable!("manual selector direction is neutral, FS or BS"),
    }
}

fn cycle_leaf(side: ManualSide, high: bool, crouch: bool, direction: i32) -> &'static str {
    match (side, high, crouch, direction) {
        (ManualSide::Tail, false, false, 0) => "M_IDLE_N_0_CYC",
        (ManualSide::Tail, false, false, 1) => "M_IDLE_N_0_TURN_FS_0_CYC",
        (ManualSide::Tail, false, false, 2) => "M_IDLE_N_0_TURN_BS_0_CYC",
        (ManualSide::Tail, false, true, 0) => "M_IDLE_CROUCH_0_CYC",
        (ManualSide::Tail, false, true, 1) => "M_IDLE_CROUCH_0_TURN_FS_0_CYC",
        (ManualSide::Tail, false, true, 2) => "M_IDLE_CROUCH_0_TURN_BS_0_CYC",
        (ManualSide::Tail, true, false, 0) => "M_LEAN_N_0_CYC",
        (ManualSide::Tail, true, false, 1) => "M_LEAN_TURN_FS_0_CYC",
        (ManualSide::Tail, true, false, 2) => "M_LEAN_TURN_BS_0_CYC",
        (ManualSide::Tail, true, true, 0) => "M_LEAN_CROUCH_0_CYC",
        (ManualSide::Tail, true, true, 1) => "M_LEAN_CROUCH_0_TURN_FS_0_CYC",
        (ManualSide::Tail, true, true, 2) => "M_LEAN_CROUCH_0_TURN_BS_0_CYC",
        (ManualSide::Nose, false, false, 0) => "M_NOSEIDLE_N_0_CYC",
        (ManualSide::Nose, false, false, 1) => "M_NOSEIDLE_N_0_TURN_FS_0_CYC",
        (ManualSide::Nose, false, false, 2) => "M_NOSEIDLE_N_0_TURN_BS_0_CYC",
        (ManualSide::Nose, false, true, 0) => "M_NOSEIDLE_CROUCH_0_CYC",
        (ManualSide::Nose, false, true, 1) => "M_NOSEIDLE_CROUCH_0_TURN_FS_0_CYC",
        (ManualSide::Nose, false, true, 2) => "M_NOSEIDLE_CROUCH_0_TURN_BS_0_CYC",
        (ManualSide::Nose, true, false, 0) => "M_NOSELEAN_N_0_CYC",
        (ManualSide::Nose, true, false, 1) => "M_NOSELEAN_TURN_FS_0_CYC",
        (ManualSide::Nose, true, false, 2) => "M_NOSELEAN_TURN_BS_0_CYC",
        (ManualSide::Nose, true, true, 0) => "M_NOSELEAN_CROUCH_0_CYC",
        (ManualSide::Nose, true, true, 1) => "M_NOSELEAN_CROUCH_0_TURN_FS_0_CYC",
        (ManualSide::Nose, true, true, 2) => "M_NOSELEAN_CROUCH_0_TURN_BS_0_CYC",
        _ => unreachable!("manual selector direction is neutral, FS or BS"),
    }
}

fn validate_timing(request: ManualAnimationAdapterRequest) -> Result<(), ManualAnimationFailure> {
    let invalid = if !request.local_time_seconds.is_finite() || request.local_time_seconds < 0.0 {
        Some(InvalidTimingField::LocalTime)
    } else if !request.transition_seconds.is_finite() || request.transition_seconds < 0.0 {
        Some(InvalidTimingField::Transition)
    } else if !request.playback_speed.is_finite() || request.playback_speed <= 0.0 {
        Some(InvalidTimingField::PlaybackSpeed)
    } else {
        None
    };
    match invalid {
        Some(field) => Err(failure(
            request.source_resource,
            ManualAnimationFailureReason::InvalidTiming(field),
        )),
        None => Ok(()),
    }
}

fn validate_parameters(
    source_resource: &'static str,
    contract: ManualParameterContract,
    parameters: ManualAnimationParameters,
) -> Result<(), ManualAnimationFailure> {
    for (field, value) in [
        (ManualParameterField::Balance, parameters.balance),
        (ManualParameterField::Spin, parameters.spin),
        (ManualParameterField::ManualAngle, parameters.manual_angle),
        (
            ManualParameterField::DistanceToCog,
            parameters.distance_to_cog,
        ),
        (ManualParameterField::ManualBrake, parameters.manual_brake),
        (ManualParameterField::RevertDir, parameters.revert_dir),
    ] {
        if value.is_some_and(|value| !value.is_finite()) {
            return Err(parameter_failure(
                source_resource,
                field,
                ParameterFailureReason::NotFinite,
            ));
        }
    }

    match contract {
        ManualParameterContract::NoneObserved => Ok(()),
        ManualParameterContract::Into { .. } => {
            require(source_resource, ManualParameterField::Spin, parameters.spin)?;
            Ok(())
        }
        ManualParameterContract::Cycle {
            side,
            manual_angle_published,
        } => {
            let balance = require(
                source_resource,
                ManualParameterField::Balance,
                parameters.balance,
            )?;
            validate_balance_sign(source_resource, side, balance)?;
            require(source_resource, ManualParameterField::Spin, parameters.spin)?;
            if manual_angle_published {
                require(
                    source_resource,
                    ManualParameterField::ManualAngle,
                    parameters.manual_angle,
                )?;
            }
            Ok(())
        }
        ManualParameterContract::Brake { side, moving } => {
            let balance = require(
                source_resource,
                ManualParameterField::Balance,
                parameters.balance,
            )?;
            let expected = match side {
                ManualSide::Tail => -1.0,
                ManualSide::Nose => 1.0,
            };
            if balance != expected {
                return Err(parameter_failure(
                    source_resource,
                    ManualParameterField::Balance,
                    ParameterFailureReason::ExpectedExactGraphValue,
                ));
            }
            require(
                source_resource,
                ManualParameterField::ManualBrake,
                parameters.manual_brake,
            )?;
            if moving {
                require(source_resource, ManualParameterField::Spin, parameters.spin)?;
            }
            Ok(())
        }
        ManualParameterContract::Revert { side, direction } => {
            let balance = require(
                source_resource,
                ManualParameterField::Balance,
                parameters.balance,
            )?;
            validate_balance_sign(source_resource, side, balance)?;
            let revert_dir = require(
                source_resource,
                ManualParameterField::RevertDir,
                parameters.revert_dir,
            )?;
            if revert_dir != direction.graph_attribute() {
                return Err(parameter_failure(
                    source_resource,
                    ManualParameterField::RevertDir,
                    ParameterFailureReason::ExpectedExactGraphValue,
                ));
            }
            Ok(())
        }
    }
}

fn validate_balance_sign(
    source_resource: &'static str,
    side: ManualSide,
    balance: f32,
) -> Result<(), ManualAnimationFailure> {
    let reason = match side {
        ManualSide::Tail if balance >= 0.0 => {
            Some(ParameterFailureReason::TailBalanceMustBeNegative)
        }
        ManualSide::Nose if balance <= 0.0 => {
            Some(ParameterFailureReason::NoseBalanceMustBePositive)
        }
        _ => None,
    };
    match reason {
        Some(reason) => Err(parameter_failure(
            source_resource,
            ManualParameterField::Balance,
            reason,
        )),
        None => Ok(()),
    }
}

fn require(
    source_resource: &'static str,
    field: ManualParameterField,
    value: Option<f32>,
) -> Result<f32, ManualAnimationFailure> {
    value.ok_or_else(|| parameter_failure(source_resource, field, ParameterFailureReason::Missing))
}

const fn failure(
    source_resource: &'static str,
    reason: ManualAnimationFailureReason,
) -> ManualAnimationFailure {
    ManualAnimationFailure {
        source_resource,
        reason,
    }
}

const fn parameter_failure(
    source_resource: &'static str,
    field: ManualParameterField,
    reason: ParameterFailureReason,
) -> ManualAnimationFailure {
    failure(
        source_resource,
        ManualAnimationFailureReason::InvalidParameters(ParameterFailure { field, reason }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    fn request(
        resource: &'static str,
        parameters: ManualAnimationParameters,
    ) -> ManualAnimationAdapterRequest {
        ManualAnimationAdapterRequest {
            source_resource: resource,
            local_time_seconds: 0.25,
            transition_seconds: 0.2,
            playback_speed: 1.0,
            repeats: true,
            apply_posture: false,
            parameters,
        }
    }

    fn parameters_for(resource: VirtualManualResource) -> ManualAnimationParameters {
        match resource.parameter_contract() {
            ManualParameterContract::NoneObserved => ManualAnimationParameters::default(),
            ManualParameterContract::Into { .. } => ManualAnimationParameters {
                spin: Some(0.25),
                ..ManualAnimationParameters::default()
            },
            ManualParameterContract::Cycle {
                side,
                manual_angle_published,
            } => ManualAnimationParameters {
                balance: Some(if side == ManualSide::Tail { -0.7 } else { 0.7 }),
                spin: Some(-0.25),
                manual_angle: manual_angle_published.then_some(0.1),
                ..ManualAnimationParameters::default()
            },
            ManualParameterContract::Brake { side, moving } => ManualAnimationParameters {
                balance: Some(if side == ManualSide::Tail { -1.0 } else { 1.0 }),
                spin: moving.then_some(0.2),
                manual_brake: Some(1.0),
                ..ManualAnimationParameters::default()
            },
            ManualParameterContract::Revert { side, direction } => ManualAnimationParameters {
                balance: Some(if side == ManualSide::Tail { -0.8 } else { 0.8 }),
                revert_dir: Some(direction.graph_attribute()),
                ..ManualAnimationParameters::default()
            },
        }
    }

    #[test]
    fn graph_resource_inventory_is_unique_and_fully_classified() {
        assert_eq!(MANUAL_GRAPH_RESOURCES.len(), 14);
        let unique = MANUAL_GRAPH_RESOURCES
            .iter()
            .copied()
            .collect::<HashSet<_>>();
        assert_eq!(unique.len(), MANUAL_GRAPH_RESOURCES.len());
        for resource in MANUAL_GRAPH_RESOURCES {
            assert_ne!(
                classify_manual_resource(resource),
                GraphResourceClass::Unknown
            );
        }
    }

    #[test]
    fn exact_physical_catalog_metadata_matches_authoritative_inventory() {
        assert_eq!(
            PHYSICAL_MANUAL_CATALOG,
            [
                PhysicalManualLeaf {
                    kind: PhysicalManualLeafKind::NoseBrakeStationary,
                    name: "M_NOSEBRAKE_STAT_0_CYC",
                    catalog_index: 1370,
                    native_fps: 30,
                    frame_count: 60,
                    part_count: 8,
                    block_offset: 5_290_672,
                    block_size: 3_696,
                    exported_in_current_bevy_asset: false,
                },
                PhysicalManualLeaf {
                    kind: PhysicalManualLeafKind::TailBrakeMoving,
                    name: "M_BRAKE_N_0_CYC",
                    catalog_index: 1400,
                    native_fps: 30,
                    frame_count: 45,
                    part_count: 8,
                    block_offset: 5_461_552,
                    block_size: 4_496,
                    exported_in_current_bevy_asset: false,
                },
                PhysicalManualLeaf {
                    kind: PhysicalManualLeafKind::TailBrakeStationary,
                    name: "M_BRAKE_STAT_0_CYC",
                    catalog_index: 1401,
                    native_fps: 30,
                    frame_count: 45,
                    part_count: 8,
                    block_offset: 5_466_048,
                    block_size: 3_216,
                    exported_in_current_bevy_asset: false,
                },
            ]
        );
    }

    #[test]
    fn exact_physical_leaves_resolve_and_transport_graph_timing() {
        let tail = resolve_manual_request(request(
            "M_BRAKE_N_0_CYC",
            ManualAnimationParameters {
                balance: Some(-1.0),
                spin: Some(0.3),
                manual_brake: Some(1.0),
                ..ManualAnimationParameters::default()
            },
        ))
        .unwrap();
        assert_eq!(
            tail.sample.leaf.kind,
            PhysicalManualLeafKind::TailBrakeMoving
        );
        assert_eq!(tail.sample.weight, 1.0);
        assert_eq!(tail.local_time_seconds, 0.25);
        assert_eq!(tail.transition_seconds, 0.2);

        let stationary_tail = resolve_manual_request(request(
            "M_BRAKE_STAT_0_CYC",
            ManualAnimationParameters {
                balance: Some(-1.0),
                manual_brake: Some(1.0),
                ..ManualAnimationParameters::default()
            },
        ))
        .unwrap();
        assert_eq!(
            stationary_tail.sample.leaf.kind,
            PhysicalManualLeafKind::TailBrakeStationary
        );

        let nose = resolve_manual_request(request(
            "M_NOSEBRAKE_STAT_0_CYC",
            ManualAnimationParameters {
                balance: Some(1.0),
                manual_brake: Some(1.0),
                ..ManualAnimationParameters::default()
            },
        ))
        .unwrap();
        assert_eq!(
            nose.sample.leaf.kind,
            PhysicalManualLeafKind::NoseBrakeStationary
        );
    }

    #[test]
    fn every_virtual_resource_returns_its_typed_missing_evidence() {
        for resource in VIRTUAL_MANUAL_RESOURCES {
            let error = resolve_manual_request(request(resource.name(), parameters_for(resource)))
                .unwrap_err();
            assert_eq!(
                error.reason,
                ManualAnimationFailureReason::Virtual {
                    resource,
                    missing: resource.missing_evidence(),
                }
            );
        }
    }

    #[test]
    fn required_cycle_capture_context_is_enforced() {
        let missing = resolve_manual_request(request(
            VirtualManualResource::TailRollingBackward.name(),
            ManualAnimationParameters {
                balance: Some(-0.5),
                spin: Some(0.0),
                ..ManualAnimationParameters::default()
            },
        ))
        .unwrap_err();
        assert_eq!(
            missing.reason,
            ManualAnimationFailureReason::InvalidParameters(ParameterFailure {
                field: ManualParameterField::ManualAngle,
                reason: ParameterFailureReason::Missing,
            })
        );
    }

    #[test]
    fn side_signs_and_exact_revert_attributes_are_enforced() {
        let wrong_side = resolve_manual_request(request(
            VirtualManualResource::NoseRollingForward.name(),
            ManualAnimationParameters {
                balance: Some(-0.5),
                spin: Some(0.0),
                manual_angle: Some(0.1),
                ..ManualAnimationParameters::default()
            },
        ))
        .unwrap_err();
        assert_eq!(
            wrong_side.reason,
            ManualAnimationFailureReason::InvalidParameters(ParameterFailure {
                field: ManualParameterField::Balance,
                reason: ParameterFailureReason::NoseBalanceMustBePositive,
            })
        );

        let wrong_revert = resolve_manual_request(request(
            VirtualManualResource::TailFsRevert.name(),
            ManualAnimationParameters {
                balance: Some(-0.5),
                revert_dir: Some(1.0),
                ..ManualAnimationParameters::default()
            },
        ))
        .unwrap_err();
        assert_eq!(
            wrong_revert.reason,
            ManualAnimationFailureReason::InvalidParameters(ParameterFailure {
                field: ManualParameterField::RevertDir,
                reason: ParameterFailureReason::ExpectedExactGraphValue,
            })
        );
    }

    #[test]
    fn all_present_parameter_values_must_be_finite() {
        let error = resolve_manual_request(request(
            VirtualManualResource::NoseOut.name(),
            ManualAnimationParameters {
                spin: Some(f32::NAN),
                ..ManualAnimationParameters::default()
            },
        ))
        .unwrap_err();
        assert_eq!(
            error.reason,
            ManualAnimationFailureReason::InvalidParameters(ParameterFailure {
                field: ManualParameterField::Spin,
                reason: ParameterFailureReason::NotFinite,
            })
        );
    }

    #[test]
    fn invalid_timing_is_rejected_before_resource_resolution() {
        let error = resolve_manual_request(ManualAnimationAdapterRequest {
            playback_speed: 0.0,
            ..request(
                VirtualManualResource::NoseOut.name(),
                ManualAnimationParameters::default(),
            )
        })
        .unwrap_err();
        assert_eq!(
            error.reason,
            ManualAnimationFailureReason::InvalidTiming(InvalidTimingField::PlaybackSpeed)
        );
    }

    #[test]
    fn current_bevy_asset_blocks_all_unexported_physical_leaves() {
        let cases = [
            (
                "M_BRAKE_N_0_CYC",
                ManualAnimationParameters {
                    balance: Some(-1.0),
                    spin: Some(0.0),
                    manual_brake: Some(1.0),
                    ..ManualAnimationParameters::default()
                },
            ),
            (
                "M_BRAKE_STAT_0_CYC",
                ManualAnimationParameters {
                    balance: Some(-1.0),
                    manual_brake: Some(1.0),
                    ..ManualAnimationParameters::default()
                },
            ),
            (
                "M_NOSEBRAKE_STAT_0_CYC",
                ManualAnimationParameters {
                    balance: Some(1.0),
                    manual_brake: Some(1.0),
                    ..ManualAnimationParameters::default()
                },
            ),
        ];
        for (name, parameters) in cases {
            let error = adapt_manual_for_bevy(request(name, parameters)).unwrap_err();
            assert!(matches!(
                error.reason,
                ManualAnimationFailureReason::PhysicalLeafNotExported { .. }
            ));
        }
    }

    #[test]
    fn unknown_resources_are_typed_failures() {
        let error = resolve_manual_request(request(
            "NOT_A_RETAIL_MANUAL_RESOURCE",
            ManualAnimationParameters::default(),
        ))
        .unwrap_err();
        assert_eq!(
            error,
            ManualAnimationFailure {
                source_resource: "NOT_A_RETAIL_MANUAL_RESOURCE",
                reason: ManualAnimationFailureReason::UnknownResource,
            }
        );
    }

    #[test]
    fn authored_durations_use_sample_intervals() {
        let nose = PHYSICAL_MANUAL_CATALOG[0];
        let tail = PHYSICAL_MANUAL_CATALOG[1];
        let stationary_tail = PHYSICAL_MANUAL_CATALOG[2];
        assert!((nose.authored_duration_seconds() - 59.0 / 30.0).abs() < f32::EPSILON);
        assert!((tail.authored_duration_seconds() - 44.0 / 30.0).abs() < f32::EPSILON);
        assert!((stationary_tail.authored_duration_seconds() - 44.0 / 30.0).abs() < f32::EPSILON);
    }

    #[test]
    fn decoded_manual_visual_bank_uses_the_recovered_thirty_hz_source_clock() {
        for name in [
            "M_NOSEBRAKE_N_0_CYC",
            "M_NOSEBRAKE_STAT_0_CYC",
            "M_NOSEIDLE_N_0_CYC",
            "M_NOSEIDLE_N_0_INTO",
            "M_NOSEIDLE_N_0_OUT",
            "M_BRAKE_N_0_CYC",
            "M_BRAKE_STAT_0_CYC",
            "M_IDLE_N_0_CYC",
        ] {
            assert_eq!(manual_visual_native_fps(name), Some(30));
        }
        assert_eq!(manual_visual_native_fps("R_IDLE_HCOM_000"), None);
    }

    #[test]
    fn decoded_manual_visual_durations_and_loop_flags_match_xml_requests() {
        assert_eq!(manual_visual_frame_count("M_NOSEIDLE_N_0_INTO"), Some(15));
        assert_eq!(manual_visual_frame_count("M_NOSEIDLE_N_0_CYC"), Some(102));
        assert_eq!(manual_visual_frame_count("M_IDLE_N_0_CYC"), Some(100));
        assert_eq!(manual_visual_repeats("M_NOSEIDLE_N_0_INTO"), Some(false));
        assert_eq!(manual_visual_repeats("M_NOSEIDLE_N_0_OUT"), Some(false));
        assert_eq!(manual_visual_repeats("M_NOSEIDLE_N_0_CYC"), Some(true));
        assert!(
            (manual_visual_duration_seconds("M_NOSEIDLE_N_0_INTO").unwrap() - 14.0 / 30.0).abs()
                < f32::EPSILON
        );
    }

    #[test]
    fn bounded_visual_candidate_uses_decoded_manual_bank_without_proving_selectors() {
        let tail = resolve_manual_visual_candidate(request(
            "B_TAIL_MANUAL_LOW",
            ManualAnimationParameters {
                balance: Some(-0.6),
                spin: Some(0.0),
                ..ManualAnimationParameters::default()
            },
        ))
        .unwrap();
        assert_eq!(tail.physical_leaf, "M_IDLE_N_0_CYC");
        assert!((tail.authored_duration_seconds - 99.0 / 30.0).abs() < f32::EPSILON);

        let nose = resolve_manual_visual_candidate(request(
            "S_M_NOSEBRAKE_N_0_CYC",
            ManualAnimationParameters {
                balance: Some(1.0),
                spin: Some(0.0),
                manual_brake: Some(1.0),
                ..ManualAnimationParameters::default()
            },
        ))
        .unwrap();
        assert_eq!(nose.physical_leaf, "M_NOSEBRAKE_N_0_CYC");

        let still_unresolved = resolve_manual_visual_candidate(request(
            "B_TAIL_MANUAL_FS_REVERT",
            parameters_for(VirtualManualResource::TailFsRevert),
        ))
        .unwrap_err();
        assert!(matches!(
            still_unresolved.reason,
            ManualAnimationFailureReason::Virtual { .. }
        ));
    }

    #[test]
    fn straight_manual_uses_only_neutral_authored_leaves() {
        for (resource, balance, angle, expected_prefix) in [
            ("B_TAIL_MANUAL", -0.5, -0.4, "M_"),
            ("B_NOSE_MANUAL", 0.5, 0.4, "M_NOSE"),
        ] {
            let resolved = resolve_manual_visual_tree(request(
                resource,
                ManualAnimationParameters {
                    balance: Some(balance),
                    spin: Some(0.0),
                    manual_angle: Some(angle),
                    ..ManualAnimationParameters::default()
                },
            ))
            .unwrap();
            assert!(
                resolved
                    .samples
                    .iter()
                    .all(|sample| sample.physical_leaf.starts_with(expected_prefix)
                        && !sample.physical_leaf.contains("_TURN_"))
            );
            let total: f32 = resolved.samples.iter().map(|sample| sample.weight).sum();
            assert!((total - 1.0).abs() < 1.0e-6);
        }
    }

    #[test]
    fn turn_axis_routes_exclusively_to_retail_fs_or_bs_leaves() {
        for (spin, expected, rejected) in [
            (-1.0, "_TURN_BS_", "_TURN_FS_"),
            (1.0, "_TURN_FS_", "_TURN_BS_"),
        ] {
            let resolved = resolve_manual_visual_tree(request(
                "B_NOSE_MANUAL",
                ManualAnimationParameters {
                    balance: Some(0.5),
                    spin: Some(spin),
                    manual_angle: Some(0.0),
                    ..ManualAnimationParameters::default()
                },
            ))
            .unwrap();
            assert!(
                resolved
                    .samples
                    .iter()
                    .all(|sample| sample.physical_leaf.contains(expected)
                        && !sample.physical_leaf.contains(rejected))
            );
        }
    }

    #[test]
    fn cycle_leaves_share_normalized_phase_across_authored_durations() {
        let mut request = request(
            "B_TAIL_MANUAL",
            ManualAnimationParameters {
                balance: Some(-0.5),
                spin: Some(-0.5),
                manual_angle: Some(-0.5),
                ..ManualAnimationParameters::default()
            },
        );
        request.local_time_seconds = 1.65;
        let resolved = resolve_manual_visual_tree(request).unwrap();
        for sample in resolved.samples {
            let duration = manual_visual_duration_seconds(sample.physical_leaf).unwrap();
            assert!((sample.local_time_seconds / duration - 0.5).abs() < 1.0e-5);
        }
    }

    #[test]
    fn neutral_riding_disttocog_selects_non_crouched_manual_rows() {
        for (resource, balance, angle) in
            [("B_TAIL_MANUAL", -0.5, 0.0), ("B_NOSE_MANUAL", 0.5, 0.0)]
        {
            let resolved = resolve_manual_visual_tree(request(
                resource,
                ManualAnimationParameters {
                    balance: Some(balance),
                    spin: Some(0.0),
                    manual_angle: Some(angle),
                    distance_to_cog: Some(RETAIL_NEUTRAL_RIDING_DIST_TO_COG),
                    ..ManualAnimationParameters::default()
                },
            ))
            .unwrap();
            assert!(
                resolved
                    .samples
                    .iter()
                    .all(|sample| !sample.physical_leaf.contains("CROUCH"))
            );
        }
    }

    #[test]
    fn authored_manual_angle_coordinates_clamp_at_signed_point_nine() {
        for (resource, balance, angle, expected) in [
            ("B_TAIL_MANUAL", -1.0, -0.9, "M_LEAN_N_0_CYC"),
            ("B_NOSE_MANUAL", 1.0, 0.9, "M_NOSELEAN_N_0_CYC"),
        ] {
            let resolved = resolve_manual_visual_tree(request(
                resource,
                ManualAnimationParameters {
                    balance: Some(balance),
                    spin: Some(0.0),
                    manual_angle: Some(angle),
                    distance_to_cog: Some(RETAIL_NEUTRAL_RIDING_DIST_TO_COG),
                    ..ManualAnimationParameters::default()
                },
            ))
            .unwrap();
            assert_eq!(resolved.samples.len(), 1);
            assert_eq!(resolved.samples[0].physical_leaf, expected);
            assert_eq!(resolved.samples[0].weight, 1.0);
        }
    }
}
