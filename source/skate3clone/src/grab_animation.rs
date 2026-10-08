//! Evidence-backed adapter from TU3 grab graph resources to physical ABIN leaves.
//!
//! `grab_graph` may request physical `GR_*` leaves or virtual `B_*`/`BLEND_*`
//! resources. This module inventories every resource currently emitted by that
//! graph and prevents a virtual name, or a physical leaf absent from the current
//! Bevy GLB, from reaching an animation player.
#![allow(dead_code)]

pub const ONBOARD_ABIN_SHA256: &str =
    "30AA324D6D7C51C325D53E9268C1AD91783B0154D21BBEF5DC5A61EAE8333BD7";
pub const ONBOARD_CATALOG_SHA256: &str =
    "7B2041D3E8FC305D589A05B65B72B5181319197B4CF4FC6C410C8BDDAA131D10";
pub const CURRENT_BEVY_MANIFEST_SHA256: &str =
    "6891B82FBB12020B14B1EAECC3E3BF6CE6B0CFF2159AC5D66BFEABC8A68D310D";
pub const CURRENT_BEVY_GLB_SHA256: &str =
    "961E23D9F96D273C141BB06AF3E7CFE6D812B42F86C90CA4BB06311817A50378";
pub const GRAB_GRAPH_SHA256: &str =
    "7F73448393595C5A50756933CCED343ABF33ACA6A812C7D7F2BB0DA21B7879BC";
pub const RETAIL_GRAB_ANIMATION_HZ: u16 = 30;

/// Direct physical leaves used by the first held-grab slice.
///
/// Air leaves are named directly by the recovered graph except for the
/// neutral cycle leaves, which are the zero-tweak members adjacent to the
/// named into/out families in the authoritative catalog. Ground resources are
/// virtual blends in XML; their neutral physical leaves are the zero-body-tilt
/// members of the catalog's left/neutral/right families.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BasicGrabClip {
    pub name: &'static str,
    pub catalog_index: u16,
    pub frame_count: u16,
}

impl BasicGrabClip {
    pub const fn authored_duration_seconds(self) -> f32 {
        self.frame_count.saturating_sub(1) as f32 / RETAIL_GRAB_ANIMATION_HZ as f32
    }
}

const fn basic_clip(name: &'static str, catalog_index: u16, frame_count: u16) -> BasicGrabClip {
    BasicGrabClip {
        name,
        catalog_index,
        frame_count,
    }
}

pub const BASIC_GRAB_CLIPS: [BasicGrabClip; 26] = [
    basic_clip("GR_GRAB_N_BS_0_CYC", 478, 30),
    basic_clip("GR_GRAB_N_BS_0_INTO", 479, 15),
    basic_clip("GR_GRAB_N_BS_0_OUT", 480, 15),
    basic_clip("GR_BS2DBL_0_TR", 502, 10),
    basic_clip("GR_DBL2BS_0_TR", 503, 11),
    basic_clip("GR_DBL2FS_0_TR", 504, 10),
    basic_clip("GR_FS2DBL_0_TR", 505, 11),
    basic_clip("GR_GRAB_N_DBL_0_CYC", 506, 30),
    basic_clip("GR_GRAB_N_DBL_0_INTO", 507, 15),
    basic_clip("GR_GRAB_N_DBL_0_OUT", 508, 15),
    basic_clip("GR_GRAB_N_FS_0_CYC", 552, 30),
    basic_clip("GR_GRAB_N_FS_0_INTO", 553, 15),
    basic_clip("GR_GRAB_N_FS_0_OUT", 554, 15),
    basic_clip("GR_GROUND_N_BS_0_CYC", 693, 30),
    basic_clip("GR_CROUCH2GRAB_N_BS_0_INTO", 706, 12),
    basic_clip("GR_GROUND_N_BS_0_OUT", 710, 12),
    basic_clip("GR_CROUCH2GRAB_N_DBL_0_INTO", 715, 12),
    basic_clip("GR_GROUND_N_DBL_0_OUT", 719, 12),
    basic_clip("GR_CROUCH2GRAB_N_FS_0_INTO", 724, 12),
    basic_clip("GR_GROUND_N_FS_0_OUT", 728, 12),
    basic_clip("GR_GRAB_N_BS2DBL_0_TR", 741, 10),
    basic_clip("GR_GRAB_N_DBL2BS_0_TR", 743, 10),
    basic_clip("GR_GRAB_N_DBL2FS_0_TR", 744, 10),
    basic_clip("GR_GRAB_N_FS2DBL_0_TR", 746, 11),
    basic_clip("GR_GROUND_N_DBL_0_CYC", 747, 30),
    basic_clip("GR_GROUND_N_FS_0_CYC", 752, 30),
];

pub fn basic_grab_clip_by_name(name: &str) -> Option<&'static BasicGrabClip> {
    BASIC_GRAB_CLIPS.iter().find(|clip| clip.name == name)
}

/// Authored duration for every physical grab leaf selected by the complete
/// controller slice. Frame counts come from the pinned OnBoard ABIN catalog;
/// this intentionally does not substitute a generic Bevy transition length.
pub fn grab_clip_duration_seconds(name: &str) -> Option<f32> {
    if let Some(clip) = basic_grab_clip_by_name(name) {
        return Some(clip.authored_duration_seconds());
    }
    let frames: u16 = match name {
        "2FT_AIR_GRAB_N_TAIL_0_INTO" => 7,
        "2FT_AIR_GRAB_N_NOSE_0_INTO"
        | "GR_TAILGRAB_NBONE_N_0_INTO"
        | "GR_TAILGRAB_N_BS_0_INTO"
        | "GR_TAILGRAB_N_BS_0_OUT" => 8,
        "GR_BS2DBL_0_TR"
        | "GR_DBL2FS_0_TR"
        | "GR_DSMNT_NOFOOT_FS_MED_OUT"
        | "GR_NOSEGRAB_N_BS_0_INTO"
        | "GR_NOSEGRAB_N_BS_0_OUT"
        | "GR_NOSEGRAB_SHIFTY_BS_0_INTO"
        | "GR_NOSEGRAB_SHIFTY_BS_0_OUT"
        | "GR_NOSEGRAB_SHIFTY_FS_0_INTO"
        | "GR_NOSEGRAB_SHIFTY_FS_0_OUT"
        | "GR_NOSEGRAB_TBONE_N_0_INTO"
        | "GR_NOSEGRAB_TBONE_N_0_OUT"
        | "1FT_AIR_GRAB_N_FSR_0_INTO"
        | "1FT_AIR_GRAB_N_FSR_0_OUT"
        | "1FT_AIR_GRAB_N_TAILL_0_INTO"
        | "1FT_AIR_GRAB_N_TAILL_0_OUT"
        | "1FT_AIR_GRAB_N_TAILR_0_INTO"
        | "1FT_AIR_GRAB_N_TAILR_0_OUT"
        | "1FT_AIR_GRAB_N_TAILR_MED_OUT"
        | "GR_STALEGRAB_N_0_INTO"
        | "GR_STALEGRAB_N_0_OUT"
        | "GR_TAILGRAB_NBONE_N_0_OUT"
        | "GR_TAILGRAB_SHIFTY_BS_0_INTO"
        | "GR_TAILGRAB_SHIFTY_BS_0_OUT"
        | "GR_TAILGRAB_SHIFTY_FS_0_INTO"
        | "GR_TAILGRAB_SHIFTY_FS_0_OUT" => 10,
        "GR_DBL2BS_0_TR"
        | "GR_FS2DBL_0_TR"
        | "GR_MUTEGRAB_N_0_INTO"
        | "GR_MUTEGRAB_N_0_OUT"
        | "1FT_AIR_GRAB_N_BSL_MED_OUT"
        | "1FT_AIR_GRAB_N_NOSEL_MED_OUT" => 11,
        "GR_DSMNT_CHRIST_BS_MED_OUT"
        | "1FT_AIR_GRAB_N_NOSER_0_OUT"
        | "1FT_AIR_GRAB_N_NOSER_MED_OUT" => 12,
        "1FT_AIR_GRAB_N_BSL_0_INTO"
        | "1FT_AIR_GRAB_N_BSL_0_OUT"
        | "1FT_AIR_GRAB_N_FSL_0_INTO"
        | "1FT_AIR_GRAB_N_FSL_0_OUT"
        | "1FT_AIR_GRAB_N_FSL_MED_OUT"
        | "1FT_AIR_GRAB_N_NOSEL_0_INTO"
        | "1FT_AIR_GRAB_N_TAILL_MED_OUT"
        | "2FT_AIR_GRAB_N_NOSE_0_OUT"
        | "2FT_AIR_GRAB_N_TAIL_0_OUT"
        | "GR_DSMNT_SUPER_DBL_0_INTO" => 13,
        "1FT_AIR_GRAB_N_BSR_0_INTO"
        | "1FT_AIR_GRAB_N_BSR_0_OUT"
        | "1FT_AIR_GRAB_N_BSR_MED_OUT"
        | "1FT_AIR_GRAB_N_NOSER_0_INTO" => 14,
        "GR_DSMNT_NOFOOT_FS_0_INTO"
        | "GR_CRAILGRAB_N_0_INTO"
        | "GR_CRAILGRAB_N_0_OUT"
        | "GR_CRAILGRAB_SHIFTY_BS_0_OUT"
        | "GR_CRAILGRAB_SHIFTY_FS_0_INTO"
        | "GR_CRAILGRAB_SHIFTY_FS_0_OUT"
        | "GR_MUTEGRAB_N_0_OUT_IDLE"
        | "1FT_AIR_GRAB_N_BSL_TO_BSR"
        | "1FT_AIR_GRAB_N_NOSEL_0_OUT"
        | "GR_SEATBELTGRAB_N_0_INTO"
        | "GR_SEATBELTGRAB_N_0_OUT"
        | "GR_SEATBELTGRAB_SHIFTY_FS_0_INTO"
        | "GR_SEATBELTGRAB_SHIFTY_FS_0_OUT" => 15,
        "GR_CRAILGRAB_SHIFTY_BS_0_INTO"
        | "GR_SEATBELTGRAB_SHIFTY_BS_0_INTO"
        | "GR_SEATBELTGRAB_SHIFTY_BS_0_OUT"
        | "GR_STALEGRAB_N_0_OUT_IDLE" => 16,
        "GR_DSMNT_NOFOOT_FS_0_OUT" => 17,
        "GR_NOSEGRAB_ROCKETAIR_N_0_INTO" | "GR_NOSEGRAB_ROCKETAIR_N_0_OUT" => 18,
        "GR_DSMNT_CHRIST_BS_0_INTO"
        | "GR_DSMNT_CHRIST_BS_0_OUT"
        | "GR_DSMNT_N_CHRIST_TO_SUPER"
        | "GR_DSMNT_N_NOFOOT_TO_SUPER"
        | "GR_DSMNT_N_SUPER_TO_CHRIST"
        | "GR_DSMNT_N_SUPER_TO_NOFOOT"
        | "GR_DSMNT_SUPER_DBL_0_OUT" => 20,
        "1FT_AIR_GRAB_N_TAILL_0_CYC" => 23,
        "GR_GROUND_N_COFFIN_0_INTO" => 25,
        "GR_CBONE_N_BS_0_CYC"
        | "GR_GRAB_N_BS_METHOD_CYC"
        | "GR_MELON_N_BS_0_CYC"
        | "GR_METHOD_N_BS_0_CYC"
        | "GR_DSMNT_NOFOOT_FS_0_CYC"
        | "GR_CRAILGRAB_N_0_CYC"
        | "GR_CRAILGRAB_SHIFTY_BS_0_CYC"
        | "GR_GRAB_N_DBL_LEFTTW_CYC"
        | "GR_GRAB_N_DBL_RIGHTTW_CYC"
        | "GR_NBONE_N_FS_0_CYC"
        | "GR_STIFFY_N_FS_0_CYC"
        | "GR_TBONE_N_FS_0_CYC"
        | "GR_TKNEE_N_FS_0_CYC"
        | "GR_MUTEGRAB_JAPAN_N_0_CYC"
        | "GR_MUTEGRAB_N_0_CYC"
        | "GR_MUTEGRAB_N_1_CYC"
        | "GR_MUTEGRAB_N_NOSE_CYC"
        | "GR_MUTEGRAB_TAIL_N_0_CYC"
        | "GR_NOSEGRAB_N_BS_0_CYC"
        | "GR_NOSEGRAB_ROCKETAIR_N_0_CYC"
        | "GR_NOSEGRAB_SHIFTY_BS_0_CYC"
        | "GR_NOSEGRAB_SHIFTY_FS_0_CYC"
        | "GR_NOSEGRAB_TBONE_N_0_CYC"
        | "1FT_AIR_GRAB_N_BSL_0_CYC"
        | "1FT_AIR_GRAB_N_BSR_0_CYC"
        | "1FT_AIR_GRAB_N_FSL_0_CYC"
        | "1FT_AIR_GRAB_N_FSR_0_CYC"
        | "1FT_AIR_GRAB_N_NOSEL_0_CYC"
        | "1FT_AIR_GRAB_N_NOSER_0_CYC"
        | "1FT_AIR_GRAB_N_TAILR_0_CYC"
        | "2FT_AIR_GRAB_N_NOSE_0_CYC"
        | "2FT_AIR_GRAB_N_TAIL_0_CYC"
        | "GR_SEATBELTGRAB_N_0_CYC"
        | "GR_SEATBELTGRAB_SHIFTY_BS_0_CYC"
        | "GR_SEATBELTGRAB_SHIFTY_FS_0_CYC"
        | "GR_STALEGRAB_NOSE_N_0_CYC"
        | "GR_STALEGRAB_N_0_CYC"
        | "GR_STALEGRAB_N_1_CYC"
        | "GR_DSMNT_SUPER_DBL_0_CYC"
        | "GR_TAILGRAB_NBONE_N_0_CYC"
        | "GR_TAILGRAB_N_BS_0_CYC"
        | "GR_TAILGRAB_SHIFTY_BS_0_CYC"
        | "GR_TAILGRAB_SHIFTY_FS_0_CYC"
        | "GR_GROUND_N_COFFIN_0_CYC"
        | "GR_GROUND_N_COFFIN_0_OUT" => 30,
        "GR_CRAILGRAB_SHIFTY_FS_0_CYC"
        | "GR_GRAB_N_DBL_BACKTW_CYC"
        | "GR_GRAB_N_DBL_FRONTTW_CYC"
        | "GR_STALEGRAB_TAIL_N_0_CYC"
        | "GR_STALEGRAB_TUCKKNEE_N_0_CYC" => 31,
        "GR_DSMNT_CHRIST_BS_0_CYC" => 45,
        _ => return None,
    };
    Some(frames.saturating_sub(1) as f32 / RETAIL_GRAB_ANIMATION_HZ as f32)
}

/// Native ABIN sample rate for every physical grab leaf selected by the live
/// grab controller. The private GLB is exported on a 60 Hz Blender timeline,
/// so rendering must convert this source clock instead of treating a retail
/// second as an exported-timeline second.
pub fn grab_clip_native_fps(name: &str) -> Option<u16> {
    grab_clip_duration_seconds(name).map(|_| RETAIL_GRAB_ANIMATION_HZ)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PhysicalGrabLeafKind {
    FsInto,
    FsOut,
    FsToDouble,
    DoubleToFs,
    BsInto,
    BsOut,
    BsToDouble,
    DoubleToBs,
    DoubleInto,
    DoubleOut,
    MuteInto,
    StaleInto,
    CoffinInto,
    SupermanInto,
    SupermanCycle,
    SupermanOut,
}

/// One physical leaf proven to exist in the authoritative TU3 OnBoard ABIN.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PhysicalGrabLeaf {
    pub kind: PhysicalGrabLeafKind,
    pub name: &'static str,
    pub catalog_index: u16,
    pub native_fps: u16,
    pub frame_count: u16,
    pub part_count: u8,
    pub block_offset: u32,
    pub block_size: u32,
    /// Whether this exact action exists in the manifest pinned above.
    pub exported_in_current_bevy_asset: bool,
}

impl PhysicalGrabLeaf {
    /// Duration between the first and final authored sample.
    pub fn authored_duration_seconds(self) -> f32 {
        self.frame_count.saturating_sub(1) as f32 / self.native_fps as f32
    }
}

const fn leaf(
    kind: PhysicalGrabLeafKind,
    name: &'static str,
    catalog_index: u16,
    frame_count: u16,
    block_offset: u32,
    block_size: u32,
) -> PhysicalGrabLeaf {
    PhysicalGrabLeaf {
        kind,
        name,
        catalog_index,
        native_fps: RETAIL_GRAB_ANIMATION_HZ,
        frame_count,
        part_count: 8,
        block_offset,
        block_size,
        exported_in_current_bevy_asset: true,
    }
}

/// All physical leaves directly named by `grab_graph`, ordered by ABIN index.
pub const PHYSICAL_GRAB_CATALOG: [PhysicalGrabLeaf; 16] = [
    leaf(
        PhysicalGrabLeafKind::BsInto,
        "GR_GRAB_N_BS_0_INTO",
        479,
        15,
        1_576_640,
        2_720,
    ),
    leaf(
        PhysicalGrabLeafKind::BsOut,
        "GR_GRAB_N_BS_0_OUT",
        480,
        15,
        1_579_360,
        2_736,
    ),
    leaf(
        PhysicalGrabLeafKind::BsToDouble,
        "GR_BS2DBL_0_TR",
        502,
        10,
        1_646_480,
        2_752,
    ),
    leaf(
        PhysicalGrabLeafKind::DoubleToBs,
        "GR_DBL2BS_0_TR",
        503,
        11,
        1_649_232,
        2_736,
    ),
    leaf(
        PhysicalGrabLeafKind::DoubleToFs,
        "GR_DBL2FS_0_TR",
        504,
        10,
        1_651_968,
        2_800,
    ),
    leaf(
        PhysicalGrabLeafKind::FsToDouble,
        "GR_FS2DBL_0_TR",
        505,
        11,
        1_654_768,
        2_768,
    ),
    leaf(
        PhysicalGrabLeafKind::DoubleInto,
        "GR_GRAB_N_DBL_0_INTO",
        507,
        15,
        1_660_272,
        2_928,
    ),
    leaf(
        PhysicalGrabLeafKind::DoubleOut,
        "GR_GRAB_N_DBL_0_OUT",
        508,
        15,
        1_663_200,
        2_896,
    ),
    leaf(
        PhysicalGrabLeafKind::FsInto,
        "GR_GRAB_N_FS_0_INTO",
        553,
        15,
        1_803_360,
        2_880,
    ),
    leaf(
        PhysicalGrabLeafKind::FsOut,
        "GR_GRAB_N_FS_0_OUT",
        554,
        15,
        1_806_240,
        2_784,
    ),
    leaf(
        PhysicalGrabLeafKind::MuteInto,
        "GR_MUTEGRAB_N_0_INTO",
        564,
        11,
        1_836_464,
        2_880,
    ),
    leaf(
        PhysicalGrabLeafKind::StaleInto,
        "GR_STALEGRAB_N_0_INTO",
        656,
        10,
        2_105_984,
        2_912,
    ),
    leaf(
        PhysicalGrabLeafKind::SupermanCycle,
        "GR_DSMNT_SUPER_DBL_0_CYC",
        666,
        30,
        2_136_304,
        2_672,
    ),
    leaf(
        PhysicalGrabLeafKind::SupermanInto,
        "GR_DSMNT_SUPER_DBL_0_INTO",
        667,
        13,
        2_138_976,
        3_024,
    ),
    leaf(
        PhysicalGrabLeafKind::SupermanOut,
        "GR_DSMNT_SUPER_DBL_0_OUT",
        668,
        20,
        2_142_000,
        3_344,
    ),
    leaf(
        PhysicalGrabLeafKind::CoffinInto,
        "GR_GROUND_N_COFFIN_0_INTO",
        695,
        25,
        2_236_288,
        5_104,
    ),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum VirtualGrabResource {
    FsTweak,
    BsTweak,
    DoubleTweak,
    MuteTweak,
    StaleTweak,
    MuteOut,
    StaleOut,
    CoffinCycle,
}

impl VirtualGrabResource {
    pub const fn name(self) -> &'static str {
        match self {
            Self::FsTweak => "BLEND_FS_TWEAK2",
            Self::BsTweak => "BLEND_BS_TWEAK",
            Self::DoubleTweak => "BLEND_DBL_TWEAK",
            Self::MuteTweak => "BLEND_MUTE_TWEAK",
            Self::StaleTweak => "BLEND_STALE_TWEAK",
            Self::MuteOut => "B_MUTE_OUT",
            Self::StaleOut => "B_STALE_OUT",
            Self::CoffinCycle => "B_COFFIN",
        }
    }

    pub const fn parameter_contract(self) -> VirtualParameterContract {
        match self {
            Self::FsTweak
            | Self::BsTweak
            | Self::DoubleTweak
            | Self::MuteTweak
            | Self::StaleTweak => VirtualParameterContract::FilteredTweak2d,
            Self::MuteOut | Self::StaleOut | Self::CoffinCycle => VirtualParameterContract::None,
        }
    }

    pub const fn missing_evidence(self) -> MissingVirtualEvidence {
        match self {
            Self::FsTweak
            | Self::BsTweak
            | Self::DoubleTweak
            | Self::MuteTweak
            | Self::StaleTweak => MissingVirtualEvidence::BlendLeafSelection,
            Self::MuteOut | Self::StaleOut => MissingVirtualEvidence::ExitLeafSelection,
            Self::CoffinCycle => MissingVirtualEvidence::CoffinLeafSelection,
        }
    }
}

pub const VIRTUAL_GRAB_RESOURCES: [VirtualGrabResource; 8] = [
    VirtualGrabResource::FsTweak,
    VirtualGrabResource::BsTweak,
    VirtualGrabResource::DoubleTweak,
    VirtualGrabResource::MuteTweak,
    VirtualGrabResource::StaleTweak,
    VirtualGrabResource::MuteOut,
    VirtualGrabResource::StaleOut,
    VirtualGrabResource::CoffinCycle,
];

/// Exact set of resources currently emitted by `GrabRuntime::animation_request`.
pub const GRAB_GRAPH_RESOURCES: [&str; 24] = [
    "GR_GRAB_N_FS_0_INTO",
    "BLEND_FS_TWEAK2",
    "GR_GRAB_N_FS_0_OUT",
    "GR_FS2DBL_0_TR",
    "GR_DBL2FS_0_TR",
    "GR_GRAB_N_BS_0_INTO",
    "BLEND_BS_TWEAK",
    "GR_GRAB_N_BS_0_OUT",
    "GR_BS2DBL_0_TR",
    "GR_DBL2BS_0_TR",
    "GR_GRAB_N_DBL_0_INTO",
    "BLEND_DBL_TWEAK",
    "GR_GRAB_N_DBL_0_OUT",
    "GR_MUTEGRAB_N_0_INTO",
    "BLEND_MUTE_TWEAK",
    "B_MUTE_OUT",
    "GR_STALEGRAB_N_0_INTO",
    "BLEND_STALE_TWEAK",
    "B_STALE_OUT",
    "GR_GROUND_N_COFFIN_0_INTO",
    "B_COFFIN",
    "GR_DSMNT_SUPER_DBL_0_INTO",
    "GR_DSMNT_SUPER_DBL_0_CYC",
    "GR_DSMNT_SUPER_DBL_0_OUT",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GraphResourceClass {
    Physical(&'static PhysicalGrabLeaf),
    Virtual(VirtualGrabResource),
    Unknown,
}

pub fn classify_grab_resource(resource: &str) -> GraphResourceClass {
    if let Some(leaf) = PHYSICAL_GRAB_CATALOG
        .iter()
        .find(|leaf| leaf.name == resource)
    {
        return GraphResourceClass::Physical(leaf);
    }
    if let Some(resource) = VIRTUAL_GRAB_RESOURCES
        .iter()
        .copied()
        .find(|candidate| candidate.name() == resource)
    {
        return GraphResourceClass::Virtual(resource);
    }
    GraphResourceClass::Unknown
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VirtualParameterContract {
    None,
    FilteredTweak2d,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub enum GrabAnimationParameters {
    #[default]
    None,
    /// Values after retail's `FilterMotionGraphIntent` behaviours.
    FilteredTweak2d { x: f32, y: f32 },
}

/// Adapter input. The graph owns these timing values; this module transports
/// them without advancing, wrapping, or multiplying a second animation clock.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GrabAnimationAdapterRequest {
    pub resource: &'static str,
    pub local_time_seconds: f32,
    pub transition_seconds: f32,
    pub playback_speed: f32,
    pub repeats: bool,
    pub apply_posture: bool,
    pub parameters: GrabAnimationParameters,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WeightedGrabLeafSample {
    pub clip: &'static PhysicalGrabLeaf,
    pub weight: f32,
    pub seek_time_seconds: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ResolvedAbinGrabAnimation {
    pub source_resource: &'static str,
    pub samples: Vec<WeightedGrabLeafSample>,
    pub transition_seconds: f32,
    pub playback_speed: f32,
    pub repeats: bool,
    pub apply_posture: bool,
}

impl ResolvedAbinGrabAnimation {
    pub fn total_weight(&self) -> f32 {
        self.samples.iter().map(|sample| sample.weight).sum()
    }
}

/// A plan safe to hand to Bevy: every sample is physical and present in the
/// pinned GLB manifest.
#[derive(Clone, Debug, PartialEq)]
pub struct BevyGrabAnimation {
    resolved: ResolvedAbinGrabAnimation,
}

impl BevyGrabAnimation {
    pub fn resolved(&self) -> &ResolvedAbinGrabAnimation {
        &self.resolved
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InvalidTimingField {
    LocalTime,
    Transition,
    PlaybackSpeed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MissingVirtualEvidence {
    /// The blend resource receives filtered `tweak_x`/`tweak_y`, but neither a
    /// blend-resource definition nor selected-leaf telemetry is present.
    BlendLeafSelection,
    /// `B_MUTE_OUT`/`B_STALE_OUT` have more than one plausible ABIN family
    /// member; the selector has not been observed.
    ExitLeafSelection,
    /// The ABIN contains Coffin cycle variants, but no current artifact proves
    /// which leaf or weights `B_COFFIN` selects.
    CoffinLeafSelection,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VirtualFailureReason {
    ParametersRequired(VirtualParameterContract),
    UnexpectedParameters,
    InvalidFilteredTweak,
    MissingEvidence(MissingVirtualEvidence),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrabAnimationFailureReason {
    UnknownResource,
    InvalidTiming(InvalidTimingField),
    UnexpectedParametersForPhysicalLeaf,
    Virtual {
        resource: VirtualGrabResource,
        reason: VirtualFailureReason,
    },
    PhysicalLeafNotExported {
        leaf: &'static PhysicalGrabLeaf,
        manifest_sha256: &'static str,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GrabAnimationFailure {
    pub source_resource: &'static str,
    pub reason: GrabAnimationFailureReason,
}

/// Resolve direct TU3 ABIN leaves while leaving every unproven virtual selector
/// as a typed failure. A successful result contains no `B_*`/`BLEND_*` name.
pub fn resolve_grab_request(
    request: GrabAnimationAdapterRequest,
) -> Result<ResolvedAbinGrabAnimation, GrabAnimationFailure> {
    validate_timing(request)?;

    match classify_grab_resource(request.resource) {
        GraphResourceClass::Physical(clip) => {
            if request.parameters != GrabAnimationParameters::None {
                return Err(failure(
                    request.resource,
                    GrabAnimationFailureReason::UnexpectedParametersForPhysicalLeaf,
                ));
            }
            Ok(ResolvedAbinGrabAnimation {
                source_resource: request.resource,
                samples: vec![WeightedGrabLeafSample {
                    clip,
                    weight: 1.0,
                    seek_time_seconds: request.local_time_seconds,
                }],
                transition_seconds: request.transition_seconds,
                playback_speed: request.playback_speed,
                repeats: request.repeats,
                apply_posture: request.apply_posture,
            })
        }
        GraphResourceClass::Virtual(resource) => {
            validate_virtual_parameters(resource, request.parameters)?;
            Err(failure(
                request.resource,
                GrabAnimationFailureReason::Virtual {
                    resource,
                    reason: VirtualFailureReason::MissingEvidence(resource.missing_evidence()),
                },
            ))
        }
        GraphResourceClass::Unknown => Err(failure(
            request.resource,
            GrabAnimationFailureReason::UnknownResource,
        )),
    }
}

/// Resolve and enforce current Bevy asset availability.
pub fn adapt_grab_for_bevy(
    request: GrabAnimationAdapterRequest,
) -> Result<BevyGrabAnimation, GrabAnimationFailure> {
    let resolved = resolve_grab_request(request)?;
    if let Some(sample) = resolved
        .samples
        .iter()
        .find(|sample| !sample.clip.exported_in_current_bevy_asset)
    {
        return Err(failure(
            request.resource,
            GrabAnimationFailureReason::PhysicalLeafNotExported {
                leaf: sample.clip,
                manifest_sha256: CURRENT_BEVY_MANIFEST_SHA256,
            },
        ));
    }
    Ok(BevyGrabAnimation { resolved })
}

fn validate_timing(request: GrabAnimationAdapterRequest) -> Result<(), GrabAnimationFailure> {
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
            request.resource,
            GrabAnimationFailureReason::InvalidTiming(field),
        )),
        None => Ok(()),
    }
}

fn validate_virtual_parameters(
    resource: VirtualGrabResource,
    parameters: GrabAnimationParameters,
) -> Result<(), GrabAnimationFailure> {
    let reason = match (resource.parameter_contract(), parameters) {
        (VirtualParameterContract::None, GrabAnimationParameters::None) => return Ok(()),
        (VirtualParameterContract::None, GrabAnimationParameters::FilteredTweak2d { .. }) => {
            VirtualFailureReason::UnexpectedParameters
        }
        (
            VirtualParameterContract::FilteredTweak2d,
            GrabAnimationParameters::FilteredTweak2d { x, y },
        ) if x.is_finite() && y.is_finite() => return Ok(()),
        (
            VirtualParameterContract::FilteredTweak2d,
            GrabAnimationParameters::FilteredTweak2d { .. },
        ) => VirtualFailureReason::InvalidFilteredTweak,
        (VirtualParameterContract::FilteredTweak2d, GrabAnimationParameters::None) => {
            VirtualFailureReason::ParametersRequired(VirtualParameterContract::FilteredTweak2d)
        }
    };

    Err(failure(
        resource.name(),
        GrabAnimationFailureReason::Virtual { resource, reason },
    ))
}

const fn failure(
    source_resource: &'static str,
    reason: GrabAnimationFailureReason,
) -> GrabAnimationFailure {
    GrabAnimationFailure {
        source_resource,
        reason,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    const SEEK: f32 = 17.0 / 120.0;

    #[test]
    fn held_grab_catalog_is_unique_and_pins_all_ground_air_phase_leaves() {
        let names = BASIC_GRAB_CLIPS
            .iter()
            .map(|clip| clip.name)
            .collect::<HashSet<_>>();
        let indices = BASIC_GRAB_CLIPS
            .iter()
            .map(|clip| clip.catalog_index)
            .collect::<HashSet<_>>();
        assert_eq!(names.len(), BASIC_GRAB_CLIPS.len());
        assert_eq!(indices.len(), BASIC_GRAB_CLIPS.len());
        assert_eq!(BASIC_GRAB_CLIPS.first().unwrap().catalog_index, 478);
        assert_eq!(BASIC_GRAB_CLIPS.last().unwrap().catalog_index, 752);
        assert!(names.contains("GR_GRAB_N_DBL_0_CYC"));
        assert!(names.contains("GR_GROUND_N_DBL_0_CYC"));
        assert!(names.contains("GR_GRAB_N_FS2DBL_0_TR"));
        assert!(names.contains("GR_DBL2FS_0_TR"));
    }

    fn request(
        resource: &'static str,
        parameters: GrabAnimationParameters,
    ) -> GrabAnimationAdapterRequest {
        GrabAnimationAdapterRequest {
            resource,
            local_time_seconds: SEEK,
            transition_seconds: 0.1,
            playback_speed: 1.25,
            repeats: false,
            apply_posture: false,
            parameters,
        }
    }

    #[test]
    fn every_graph_resource_is_classified_once() {
        assert_eq!(GRAB_GRAPH_RESOURCES.len(), 24);
        let unique = GRAB_GRAPH_RESOURCES.iter().copied().collect::<HashSet<_>>();
        assert_eq!(unique.len(), GRAB_GRAPH_RESOURCES.len());

        let mut physical = 0;
        let mut virtual_count = 0;
        for resource in GRAB_GRAPH_RESOURCES {
            match classify_grab_resource(resource) {
                GraphResourceClass::Physical(_) => physical += 1,
                GraphResourceClass::Virtual(_) => virtual_count += 1,
                GraphResourceClass::Unknown => panic!("unclassified graph resource: {resource}"),
            }
        }
        assert_eq!(physical, 16);
        assert_eq!(virtual_count, 8);
    }

    #[test]
    fn physical_catalog_is_unique_and_matches_authoritative_boundaries() {
        let names = PHYSICAL_GRAB_CATALOG
            .iter()
            .map(|leaf| leaf.name)
            .collect::<HashSet<_>>();
        let indices = PHYSICAL_GRAB_CATALOG
            .iter()
            .map(|leaf| leaf.catalog_index)
            .collect::<HashSet<_>>();
        assert_eq!(names.len(), PHYSICAL_GRAB_CATALOG.len());
        assert_eq!(indices.len(), PHYSICAL_GRAB_CATALOG.len());
        assert_eq!(PHYSICAL_GRAB_CATALOG.first().unwrap().catalog_index, 479);
        assert_eq!(PHYSICAL_GRAB_CATALOG.last().unwrap().catalog_index, 695);
        assert!(
            PHYSICAL_GRAB_CATALOG
                .windows(2)
                .all(|pair| pair[0].catalog_index < pair[1].catalog_index)
        );
    }

    #[test]
    fn every_direct_leaf_resolves_with_unit_weight_and_preserved_timing() {
        for clip in PHYSICAL_GRAB_CATALOG {
            let resolved =
                resolve_grab_request(request(clip.name, GrabAnimationParameters::None)).unwrap();
            assert_eq!(resolved.source_resource, clip.name);
            assert_eq!(resolved.samples.len(), 1);
            assert_eq!(resolved.samples[0].clip, &clip);
            assert_eq!(resolved.samples[0].weight, 1.0);
            assert_eq!(resolved.samples[0].seek_time_seconds, SEEK);
            assert_eq!(resolved.transition_seconds, 0.1);
            assert_eq!(resolved.playback_speed, 1.25);
            assert!(!resolved.repeats);
            assert!(!resolved.apply_posture);
            assert_eq!(resolved.total_weight(), 1.0);
        }
    }

    #[test]
    fn virtual_names_never_become_physical_samples() {
        for resource in VIRTUAL_GRAB_RESOURCES {
            let parameters = match resource.parameter_contract() {
                VirtualParameterContract::None => GrabAnimationParameters::None,
                VirtualParameterContract::FilteredTweak2d => {
                    GrabAnimationParameters::FilteredTweak2d { x: 0.25, y: -0.5 }
                }
            };
            let error = resolve_grab_request(request(resource.name(), parameters)).unwrap_err();
            assert_eq!(
                error.reason,
                GrabAnimationFailureReason::Virtual {
                    resource,
                    reason: VirtualFailureReason::MissingEvidence(resource.missing_evidence()),
                }
            );
        }
    }

    #[test]
    fn tweak_blends_require_finite_filtered_parameters() {
        for resource in [
            VirtualGrabResource::FsTweak,
            VirtualGrabResource::BsTweak,
            VirtualGrabResource::DoubleTweak,
            VirtualGrabResource::MuteTweak,
            VirtualGrabResource::StaleTweak,
        ] {
            let missing =
                resolve_grab_request(request(resource.name(), GrabAnimationParameters::None))
                    .unwrap_err();
            assert_eq!(
                missing.reason,
                GrabAnimationFailureReason::Virtual {
                    resource,
                    reason: VirtualFailureReason::ParametersRequired(
                        VirtualParameterContract::FilteredTweak2d
                    ),
                }
            );

            let invalid = resolve_grab_request(request(
                resource.name(),
                GrabAnimationParameters::FilteredTweak2d {
                    x: f32::NAN,
                    y: 0.0,
                },
            ))
            .unwrap_err();
            assert_eq!(
                invalid.reason,
                GrabAnimationFailureReason::Virtual {
                    resource,
                    reason: VirtualFailureReason::InvalidFilteredTweak,
                }
            );
        }
    }

    #[test]
    fn scalar_virtual_resources_reject_tweak_parameters() {
        for resource in [
            VirtualGrabResource::MuteOut,
            VirtualGrabResource::StaleOut,
            VirtualGrabResource::CoffinCycle,
        ] {
            let error = resolve_grab_request(request(
                resource.name(),
                GrabAnimationParameters::FilteredTweak2d { x: 0.0, y: 0.0 },
            ))
            .unwrap_err();
            assert_eq!(
                error.reason,
                GrabAnimationFailureReason::Virtual {
                    resource,
                    reason: VirtualFailureReason::UnexpectedParameters,
                }
            );
        }
    }

    #[test]
    fn current_bevy_asset_accepts_every_direct_grab_leaf() {
        let exported = PHYSICAL_GRAB_CATALOG
            .iter()
            .filter(|leaf| leaf.exported_in_current_bevy_asset)
            .count();
        assert_eq!(exported, PHYSICAL_GRAB_CATALOG.len());
        for clip in &PHYSICAL_GRAB_CATALOG {
            let animation =
                adapt_grab_for_bevy(request(clip.name, GrabAnimationParameters::None)).unwrap();
            assert_eq!(animation.resolved().samples[0].clip, clip);
        }
    }

    #[test]
    fn invalid_timing_is_rejected_before_resource_resolution() {
        let cases = [
            (
                GrabAnimationAdapterRequest {
                    local_time_seconds: -0.01,
                    ..request("B_COFFIN", GrabAnimationParameters::None)
                },
                InvalidTimingField::LocalTime,
            ),
            (
                GrabAnimationAdapterRequest {
                    transition_seconds: f32::INFINITY,
                    ..request("B_COFFIN", GrabAnimationParameters::None)
                },
                InvalidTimingField::Transition,
            ),
            (
                GrabAnimationAdapterRequest {
                    playback_speed: 0.0,
                    ..request("B_COFFIN", GrabAnimationParameters::None)
                },
                InvalidTimingField::PlaybackSpeed,
            ),
        ];
        for (request, field) in cases {
            assert_eq!(
                resolve_grab_request(request).unwrap_err().reason,
                GrabAnimationFailureReason::InvalidTiming(field)
            );
        }
    }

    #[test]
    fn unknown_resources_are_typed_failures() {
        let error = resolve_grab_request(request(
            "NOT_A_RETAIL_GRAB_RESOURCE",
            GrabAnimationParameters::None,
        ))
        .unwrap_err();
        assert_eq!(
            error,
            GrabAnimationFailure {
                source_resource: "NOT_A_RETAIL_GRAB_RESOURCE",
                reason: GrabAnimationFailureReason::UnknownResource,
            }
        );
    }

    #[test]
    fn authored_durations_use_sample_intervals_not_frame_count() {
        let superman_cycle = PHYSICAL_GRAB_CATALOG
            .iter()
            .find(|leaf| leaf.kind == PhysicalGrabLeafKind::SupermanCycle)
            .copied()
            .unwrap();
        assert_eq!(superman_cycle.frame_count, 30);
        assert!((superman_cycle.authored_duration_seconds() - 29.0 / 30.0).abs() < f32::EPSILON);
    }
}
