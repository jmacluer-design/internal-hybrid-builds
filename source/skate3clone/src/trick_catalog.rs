//! Evidence-backed catalog for the Wave 2F physical trick-animation leaves.
//!
//! The recovered motion graph requests virtual resources. Those resource names
//! are not ABIN/GLB clips and must never be sent to the animation player. This
//! module resolves only endpoint mappings established by the recovered XML,
//! `tools/build_private_assets.ps1`, and the authoritative OnBoard clip CSV.
//! Unknown continuous blend policies and random selectors remain explicitly
//! unresolved.
#![allow(dead_code)]

/// SHA-256 of the generated default-skater animation manifest.
pub const MANIFEST_SHA256: &str =
    "6891B82FBB12020B14B1EAECC3E3BF6CE6B0CFF2159AC5D66BFEABC8A68D310D";
/// SHA-256 of `work/private-assets/skater_push_source.evidence.json`.
pub const EVIDENCE_JSON_SHA256: &str =
    "456718B09FAA403836E6B2696295909D2F4E1353CB149245222AAE7BD829ADB9";
/// SHA-256 recorded for the authoritative `skate3_onboard_clips.csv`.
pub const ONBOARD_CATALOG_SHA256: &str =
    "7B2041D3E8FC305D589A05B65B72B5181319197B4CF4FC6C410C8BDDAA131D10";
/// SHA-256 recorded for the source `OnBoard.abin`.
pub const ONBOARD_ABIN_SHA256: &str =
    "30AA324D6D7C51C325D53E9268C1AD91783B0154D21BBEF5DC5A61EAE8333BD7";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AnticipationSide {
    Tail,
    Nose,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AnticipationStrength {
    Normal,
    High,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AnticipationPhase {
    Into,
    Cycle,
    Out,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DirectionCoordinate {
    Left,
    Neutral,
    Right,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct AnticipationLeaf {
    pub side: AnticipationSide,
    pub strength: AnticipationStrength,
    pub phase: AnticipationPhase,
    pub direction: DirectionCoordinate,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ShuvAnticipationFamily {
    TailBackside,
    TailFrontside,
    NoseBackside,
    NoseFrontside,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ShuvAnticipationLeaf {
    pub family: ShuvAnticipationFamily,
    pub strength: AnticipationStrength,
    pub direction: DirectionCoordinate,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BasicTrick {
    Ollie,
    Nollie,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TrickHeight {
    Low,
    High,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TrickLeafPhase {
    Ground,
    Air,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct BasicTrickLeaf {
    pub trick: BasicTrick,
    pub height: TrickHeight,
    pub phase: TrickLeafPhase,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum BodySpinSide {
    Backside,
    Frontside,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LandingPosture {
    Aggressive,
    Loose,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LandingVariant {
    One,
    Two,
    Three,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct HighLandingLeaf {
    pub posture: LandingPosture,
    pub variant: LandingVariant,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LandingSupportPosture {
    LowCom,
    HighComLimp,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct LandingSupportLeaf {
    pub posture: LandingSupportPosture,
    pub variant: LandingVariant,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PhysicalLeaf {
    Anticipation(AnticipationLeaf),
    ShuvAnticipation(ShuvAnticipationLeaf),
    BasicTrick(BasicTrickLeaf),
    BodySpin(BodySpinSide),
    AirIdle,
    HighLanding(HighLandingLeaf),
    LandingSupport(LandingSupportLeaf),
}

/// One physical ABIN leaf and its authoritative catalog metadata.
///
/// `frame_count` and `native_fps` are copied from
/// `skate3_onboard_clips.csv` (SHA-256 above). The exporter treats the CSV
/// frame count as authored samples, including the sample at time zero.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CatalogEntry {
    pub leaf: PhysicalLeaf,
    pub name: &'static str,
    pub catalog_index: u16,
    pub frame_count: u16,
    pub native_fps: u16,
}

impl CatalogEntry {
    /// Duration from the first authored sample to the final authored sample.
    pub fn authored_duration_seconds(self) -> f32 {
        self.frame_count.saturating_sub(1) as f32 / self.native_fps as f32
    }
}

const fn antic(
    side: AnticipationSide,
    strength: AnticipationStrength,
    phase: AnticipationPhase,
    direction: DirectionCoordinate,
) -> PhysicalLeaf {
    PhysicalLeaf::Anticipation(AnticipationLeaf {
        side,
        strength,
        phase,
        direction,
    })
}

const fn shuv_antic(
    family: ShuvAnticipationFamily,
    strength: AnticipationStrength,
    direction: DirectionCoordinate,
) -> PhysicalLeaf {
    PhysicalLeaf::ShuvAnticipation(ShuvAnticipationLeaf {
        family,
        strength,
        direction,
    })
}

const fn basic(trick: BasicTrick, height: TrickHeight, phase: TrickLeafPhase) -> PhysicalLeaf {
    PhysicalLeaf::BasicTrick(BasicTrickLeaf {
        trick,
        height,
        phase,
    })
}

const fn landing(posture: LandingPosture, variant: LandingVariant) -> PhysicalLeaf {
    PhysicalLeaf::HighLanding(HighLandingLeaf { posture, variant })
}

const fn landing_support(posture: LandingSupportPosture, variant: LandingVariant) -> PhysicalLeaf {
    PhysicalLeaf::LandingSupport(LandingSupportLeaf { posture, variant })
}

macro_rules! clip {
    ($leaf:expr, $name:literal, $index:literal, $frames:literal, $fps:literal) => {
        CatalogEntry {
            leaf: $leaf,
            name: $name,
            catalog_index: $index,
            frame_count: $frames,
            native_fps: $fps,
        }
    };
}

/// The 83 physical leaves supported by this catalog, ordered by authoritative
/// OnBoard catalog index.
pub const PHYSICAL_CATALOG: [CatalogEntry; 83] = [
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::TailBackside,
            AnticipationStrength::Normal,
            DirectionCoordinate::Left
        ),
        "R_ANTIC_360SHUVIT_L_0_CYC",
        1,
        45,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::TailBackside,
            AnticipationStrength::Normal,
            DirectionCoordinate::Neutral
        ),
        "R_ANTIC_360SHUVIT_N_0_CYC",
        2,
        45,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::TailBackside,
            AnticipationStrength::Normal,
            DirectionCoordinate::Right
        ),
        "R_ANTIC_360SHUVIT_R_0_CYC",
        3,
        45,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::TailFrontside,
            AnticipationStrength::Normal,
            DirectionCoordinate::Left
        ),
        "R_ANTIC_FS360SHUVIT_L_0_CYC",
        4,
        45,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::TailFrontside,
            AnticipationStrength::Normal,
            DirectionCoordinate::Neutral
        ),
        "R_ANTIC_FS360SHUVIT_N_0_CYC",
        5,
        55,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::TailFrontside,
            AnticipationStrength::Normal,
            DirectionCoordinate::Right
        ),
        "R_ANTIC_FS360SHUVIT_R_0_CYC",
        6,
        45,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::NoseBackside,
            AnticipationStrength::Normal,
            DirectionCoordinate::Left
        ),
        "R_ANTIC_N360SHUVIT_L_0_CYC",
        7,
        55,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::NoseBackside,
            AnticipationStrength::Normal,
            DirectionCoordinate::Neutral
        ),
        "R_ANTIC_N360SHUVIT_N_0_CYC",
        8,
        55,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::NoseBackside,
            AnticipationStrength::Normal,
            DirectionCoordinate::Right
        ),
        "R_ANTIC_N360SHUVIT_R_0_CYC",
        9,
        55,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::NoseFrontside,
            AnticipationStrength::Normal,
            DirectionCoordinate::Left
        ),
        "R_ANTIC_NFS360SHUVIT_L_0_CYC",
        10,
        55,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::NoseFrontside,
            AnticipationStrength::Normal,
            DirectionCoordinate::Neutral
        ),
        "R_ANTIC_NFS360SHUVIT_N_0_CYC",
        11,
        55,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::NoseFrontside,
            AnticipationStrength::Normal,
            DirectionCoordinate::Right
        ),
        "R_ANTIC_NFS360SHUVIT_R_0_CYC",
        12,
        55,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::Normal,
            AnticipationPhase::Cycle,
            DirectionCoordinate::Left
        ),
        "R_ANTIC_NOLLIE_L_0_CYC",
        13,
        55,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::Normal,
            AnticipationPhase::Cycle,
            DirectionCoordinate::Neutral
        ),
        "R_ANTIC_NOLLIE_N_0_CYC",
        14,
        55,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::Normal,
            AnticipationPhase::Cycle,
            DirectionCoordinate::Right
        ),
        "R_ANTIC_NOLLIE_R_0_CYC",
        15,
        55,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::Normal,
            AnticipationPhase::Cycle,
            DirectionCoordinate::Left
        ),
        "R_ANTIC_OLLIE_L_0_CYC",
        16,
        55,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::Normal,
            AnticipationPhase::Cycle,
            DirectionCoordinate::Neutral
        ),
        "R_ANTIC_OLLIE_N_0_CYC",
        17,
        55,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::Normal,
            AnticipationPhase::Cycle,
            DirectionCoordinate::Right
        ),
        "R_ANTIC_OLLIE_R_0_CYC",
        18,
        55,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::TailBackside,
            AnticipationStrength::High,
            DirectionCoordinate::Left
        ),
        "R_HIGHANTIC_360SHUVIT_L_0_CYC",
        19,
        50,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::TailBackside,
            AnticipationStrength::High,
            DirectionCoordinate::Neutral
        ),
        "R_HIGHANTIC_360SHUVIT_N_0_CYC",
        20,
        50,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::TailBackside,
            AnticipationStrength::High,
            DirectionCoordinate::Right
        ),
        "R_HIGHANTIC_360SHUVIT_R_0_CYC",
        21,
        50,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::TailFrontside,
            AnticipationStrength::High,
            DirectionCoordinate::Left
        ),
        "R_HIGHANTIC_FS360SHUVIT_L_0_CYC",
        22,
        50,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::TailFrontside,
            AnticipationStrength::High,
            DirectionCoordinate::Neutral
        ),
        "R_HIGHANTIC_FS360SHUVIT_N_0_CYC",
        23,
        50,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::TailFrontside,
            AnticipationStrength::High,
            DirectionCoordinate::Right
        ),
        "R_HIGHANTIC_FS360SHUVIT_R_0_CYC",
        24,
        50,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::NoseBackside,
            AnticipationStrength::High,
            DirectionCoordinate::Left
        ),
        "R_HIGHANTIC_N360SHUVIT_L_0_CYC",
        25,
        50,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::NoseBackside,
            AnticipationStrength::High,
            DirectionCoordinate::Neutral
        ),
        "R_HIGHANTIC_N360SHUVIT_N_0_CYC",
        26,
        50,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::NoseBackside,
            AnticipationStrength::High,
            DirectionCoordinate::Right
        ),
        "R_HIGHANTIC_N360SHUVIT_R_0_CYC",
        27,
        50,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::NoseFrontside,
            AnticipationStrength::High,
            DirectionCoordinate::Left
        ),
        "R_HIGHANTIC_NFS360SHUVIT_L_0_CYC",
        28,
        50,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::NoseFrontside,
            AnticipationStrength::High,
            DirectionCoordinate::Neutral
        ),
        "R_HIGHANTIC_NFS360SHUVIT_N_0_CYC",
        29,
        50,
        30
    ),
    clip!(
        shuv_antic(
            ShuvAnticipationFamily::NoseFrontside,
            AnticipationStrength::High,
            DirectionCoordinate::Right
        ),
        "R_HIGHANTIC_NFS360SHUVIT_R_0_CYC",
        30,
        50,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::High,
            AnticipationPhase::Cycle,
            DirectionCoordinate::Left
        ),
        "R_HIGHANTIC_NOLLIE_L_0_CYC",
        31,
        50,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::High,
            AnticipationPhase::Cycle,
            DirectionCoordinate::Neutral
        ),
        "R_HIGHANTIC_NOLLIE_N_0_CYC",
        32,
        50,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::High,
            AnticipationPhase::Cycle,
            DirectionCoordinate::Right
        ),
        "R_HIGHANTIC_NOLLIE_R_0_CYC",
        33,
        50,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::High,
            AnticipationPhase::Cycle,
            DirectionCoordinate::Left
        ),
        "R_HIGHANTIC_OLLIE_L_0_CYC",
        34,
        50,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::High,
            AnticipationPhase::Cycle,
            DirectionCoordinate::Neutral
        ),
        "R_HIGHANTIC_OLLIE_N_0_CYC",
        35,
        50,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::High,
            AnticipationPhase::Cycle,
            DirectionCoordinate::Right
        ),
        "R_HIGHANTIC_OLLIE_R_0_CYC",
        36,
        50,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::Normal,
            AnticipationPhase::Into,
            DirectionCoordinate::Left
        ),
        "R_ANTIC_NOLLIE_L_0_INTO",
        49,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::Normal,
            AnticipationPhase::Into,
            DirectionCoordinate::Neutral
        ),
        "R_ANTIC_NOLLIE_N_0_INTO",
        50,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::Normal,
            AnticipationPhase::Into,
            DirectionCoordinate::Right
        ),
        "R_ANTIC_NOLLIE_R_0_INTO",
        51,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::Normal,
            AnticipationPhase::Into,
            DirectionCoordinate::Left
        ),
        "R_ANTIC_OLLIE_L_0_INTO",
        52,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::Normal,
            AnticipationPhase::Into,
            DirectionCoordinate::Neutral
        ),
        "R_ANTIC_OLLIE_N_0_INTO",
        53,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::Normal,
            AnticipationPhase::Into,
            DirectionCoordinate::Right
        ),
        "R_ANTIC_OLLIE_R_0_INTO",
        54,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::High,
            AnticipationPhase::Into,
            DirectionCoordinate::Left
        ),
        "R_HIGHANTIC_NOLLIE_L_0_INTO",
        55,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::High,
            AnticipationPhase::Into,
            DirectionCoordinate::Neutral
        ),
        "R_HIGHANTIC_NOLLIE_N_0_INTO",
        56,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::High,
            AnticipationPhase::Into,
            DirectionCoordinate::Right
        ),
        "R_HIGHANTIC_NOLLIE_R_0_INTO",
        57,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::High,
            AnticipationPhase::Into,
            DirectionCoordinate::Left
        ),
        "R_HIGHANTIC_OLLIE_L_0_INTO",
        58,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::High,
            AnticipationPhase::Into,
            DirectionCoordinate::Neutral
        ),
        "R_HIGHANTIC_OLLIE_N_0_INTO",
        59,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::High,
            AnticipationPhase::Into,
            DirectionCoordinate::Right
        ),
        "R_HIGHANTIC_OLLIE_R_0_INTO",
        60,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::Normal,
            AnticipationPhase::Out,
            DirectionCoordinate::Left
        ),
        "R_ANTIC_NOLLIE_L_0_OUT",
        73,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::Normal,
            AnticipationPhase::Out,
            DirectionCoordinate::Neutral
        ),
        "R_ANTIC_NOLLIE_N_0_OUT",
        74,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::Normal,
            AnticipationPhase::Out,
            DirectionCoordinate::Right
        ),
        "R_ANTIC_NOLLIE_R_0_OUT",
        75,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::Normal,
            AnticipationPhase::Out,
            DirectionCoordinate::Left
        ),
        "R_ANTIC_OLLIE_L_0_OUT",
        76,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::Normal,
            AnticipationPhase::Out,
            DirectionCoordinate::Neutral
        ),
        "R_ANTIC_OLLIE_N_0_OUT",
        77,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::Normal,
            AnticipationPhase::Out,
            DirectionCoordinate::Right
        ),
        "R_ANTIC_OLLIE_R_0_OUT",
        78,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::High,
            AnticipationPhase::Out,
            DirectionCoordinate::Left
        ),
        "R_HIGHANTIC_NOLLIE_L_0_OUT",
        79,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::High,
            AnticipationPhase::Out,
            DirectionCoordinate::Neutral
        ),
        "R_HIGHANTIC_NOLLIE_N_0_OUT",
        80,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Nose,
            AnticipationStrength::High,
            AnticipationPhase::Out,
            DirectionCoordinate::Right
        ),
        "R_HIGHANTIC_NOLLIE_R_0_OUT",
        81,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::High,
            AnticipationPhase::Out,
            DirectionCoordinate::Left
        ),
        "R_HIGHANTIC_OLLIE_L_0_OUT",
        82,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::High,
            AnticipationPhase::Out,
            DirectionCoordinate::Neutral
        ),
        "R_HIGHANTIC_OLLIE_N_0_OUT",
        83,
        15,
        30
    ),
    clip!(
        antic(
            AnticipationSide::Tail,
            AnticipationStrength::High,
            AnticipationPhase::Out,
            DirectionCoordinate::Right
        ),
        "R_HIGHANTIC_OLLIE_R_0_OUT",
        84,
        15,
        30
    ),
    clip!(PhysicalLeaf::AirIdle, "IA_IDLE_N_N_0_CYC", 1299, 60, 30),
    clip!(
        landing(LandingPosture::Aggressive, LandingVariant::One),
        "L_LAND_HIGH_AGGR_1_N",
        1321,
        39,
        60
    ),
    clip!(
        landing(LandingPosture::Aggressive, LandingVariant::Two),
        "L_LAND_HIGH_AGGR_2_N",
        1322,
        71,
        60
    ),
    clip!(
        landing(LandingPosture::Aggressive, LandingVariant::Three),
        "L_LAND_HIGH_AGGR_3_N",
        1323,
        70,
        60
    ),
    clip!(
        landing(LandingPosture::Loose, LandingVariant::One),
        "L_LAND_HIGH_LOOSE_1_N",
        1324,
        66,
        60
    ),
    clip!(
        landing(LandingPosture::Loose, LandingVariant::Two),
        "L_LAND_HIGH_LOOSE_2_N",
        1325,
        71,
        60
    ),
    clip!(
        landing(LandingPosture::Loose, LandingVariant::Three),
        "L_LAND_HIGH_LOOSE_3_N",
        1326,
        62,
        60
    ),
    clip!(
        landing_support(LandingSupportPosture::HighComLimp, LandingVariant::One),
        "L_HCOM_LIMP_1",
        1362,
        36,
        60
    ),
    clip!(
        landing_support(LandingSupportPosture::HighComLimp, LandingVariant::Two),
        "L_HCOM_LIMP_2",
        1363,
        36,
        60
    ),
    clip!(
        landing_support(LandingSupportPosture::HighComLimp, LandingVariant::Three),
        "L_HCOM_LIMP_3",
        1364,
        42,
        60
    ),
    clip!(
        landing_support(LandingSupportPosture::LowCom, LandingVariant::One),
        "L_LCOM_1",
        1366,
        33,
        60
    ),
    clip!(
        landing_support(LandingSupportPosture::LowCom, LandingVariant::Two),
        "L_LCOM_2",
        1367,
        41,
        60
    ),
    clip!(
        landing_support(LandingSupportPosture::LowCom, LandingVariant::Three),
        "L_LCOM_3",
        1368,
        48,
        60
    ),
    clip!(
        PhysicalLeaf::BodySpin(BodySpinSide::Backside),
        "IA_BODYSPIN_OLLIE_BS_0_N",
        2170,
        56,
        60
    ),
    clip!(
        PhysicalLeaf::BodySpin(BodySpinSide::Frontside),
        "IA_BODYSPIN_OLLIE_FS_0_N",
        2171,
        56,
        60
    ),
    clip!(
        basic(BasicTrick::Ollie, TrickHeight::High, TrickLeafPhase::Ground),
        "OLLIE_HIGH_G",
        2396,
        13,
        60
    ),
    clip!(
        basic(BasicTrick::Ollie, TrickHeight::High, TrickLeafPhase::Air),
        "OLLIE_HIGH_A",
        2397,
        19,
        60
    ),
    clip!(
        basic(BasicTrick::Ollie, TrickHeight::Low, TrickLeafPhase::Ground),
        "OLLIE_LOW_G",
        2398,
        13,
        60
    ),
    clip!(
        basic(BasicTrick::Ollie, TrickHeight::Low, TrickLeafPhase::Air),
        "OLLIE_LOW_A",
        2399,
        29,
        60
    ),
    clip!(
        basic(
            BasicTrick::Nollie,
            TrickHeight::High,
            TrickLeafPhase::Ground
        ),
        "NOLLIE_HIGH_G",
        2472,
        13,
        60
    ),
    clip!(
        basic(BasicTrick::Nollie, TrickHeight::High, TrickLeafPhase::Air),
        "NOLLIE_HIGH_A",
        2473,
        24,
        60
    ),
    clip!(
        basic(BasicTrick::Nollie, TrickHeight::Low, TrickLeafPhase::Ground),
        "NOLLIE_LOW_G",
        2474,
        13,
        60
    ),
    clip!(
        basic(BasicTrick::Nollie, TrickHeight::Low, TrickLeafPhase::Air),
        "NOLLIE_LOW_A",
        2475,
        29,
        60
    ),
];

pub fn catalog_entry(leaf: PhysicalLeaf) -> Option<&'static CatalogEntry> {
    PHYSICAL_CATALOG.iter().find(|entry| entry.leaf == leaf)
}

pub fn physical_clip_by_name(name: &str) -> Option<&'static CatalogEntry> {
    PHYSICAL_CATALOG.iter().find(|entry| entry.name == name)
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DirectionalWeights {
    pub left: f32,
    pub neutral: f32,
    pub right: f32,
}

impl DirectionalWeights {
    pub fn sum(self) -> f32 {
        self.left + self.neutral + self.right
    }

    pub fn for_coordinate(self, coordinate: DirectionCoordinate) -> f32 {
        match coordinate {
            DirectionCoordinate::Left => self.left,
            DirectionCoordinate::Neutral => self.neutral,
            DirectionCoordinate::Right => self.right,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InvalidDirectionCoordinate;

/// Piecewise-linear L/N/R weights for a signed directional coordinate.
///
/// Finite inputs are saturated to `[-1, 1]`: `-1` is left, `0` is neutral,
/// and `1` is right. Non-finite inputs are rejected instead of silently
/// selecting a physical leaf.
pub fn directional_weights(
    direction: f32,
) -> Result<DirectionalWeights, InvalidDirectionCoordinate> {
    if !direction.is_finite() {
        return Err(InvalidDirectionCoordinate);
    }
    let direction = direction.clamp(-1.0, 1.0);
    let weights = if direction <= 0.0 {
        DirectionalWeights {
            left: -direction,
            neutral: 1.0 + direction,
            right: 0.0,
        }
    } else {
        DirectionalWeights {
            left: 0.0,
            neutral: 1.0 - direction,
            right: direction,
        }
    };
    Ok(weights)
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WeightedPhysicalLeaf {
    pub clip: &'static CatalogEntry,
    pub weight: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DirectionalPhysicalBlend {
    pub left: WeightedPhysicalLeaf,
    pub neutral: WeightedPhysicalLeaf,
    pub right: WeightedPhysicalLeaf,
}

impl DirectionalPhysicalBlend {
    pub fn weight_sum(self) -> f32 {
        self.left.weight + self.neutral.weight + self.right.weight
    }

    pub fn clips(self) -> [&'static CatalogEntry; 3] {
        [self.left.clip, self.neutral.clip, self.right.clip]
    }
}

/// Physical `_G` and `_A` endpoint leaves produced by `T_Ollie.xml`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BasicTrickPair {
    pub ground: &'static CatalogEntry,
    pub air: &'static CatalogEntry,
}

pub fn resolve_basic_trick(trick: BasicTrick, height: TrickHeight) -> BasicTrickPair {
    BasicTrickPair {
        ground: catalog_entry(basic(trick, height, TrickLeafPhase::Ground))
            .expect("basic trick ground leaf must be present in PHYSICAL_CATALOG"),
        air: catalog_entry(basic(trick, height, TrickLeafPhase::Air))
            .expect("basic trick air leaf must be present in PHYSICAL_CATALOG"),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum VirtualResource {
    AnticIntoTail,
    AnticIntoNose,
    AnticCycleTail,
    AnticCycleNose,
    AnticOutTail,
    AnticOutNose,
    Antic360ShuvitCycle,
    AnticFs360ShuvitCycle,
    AnticNose360ShuvitCycle,
    AnticNoseFs360ShuvitCycle,
    AirCycle,
    StraightLanding,
    NiceLanding,
    SketchLanding,
}

impl VirtualResource {
    pub const fn name(self) -> &'static str {
        match self {
            Self::AnticIntoTail => "B_ANTIC_INTO",
            Self::AnticIntoNose => "B_N_ANTIC_INTO",
            Self::AnticCycleTail => "B_ANTIC_CYC",
            Self::AnticCycleNose => "B_N_ANTIC_CYC",
            Self::AnticOutTail => "B_ANTIC_OUT",
            Self::AnticOutNose => "B_N_ANTIC_OUT",
            Self::Antic360ShuvitCycle => "B_ANTIC_360SHUVIT_CYC",
            Self::AnticFs360ShuvitCycle => "B_ANTIC_FS360SHUVIT_CYC",
            Self::AnticNose360ShuvitCycle => "B_ANTIC_N360SHUVIT_CYC",
            Self::AnticNoseFs360ShuvitCycle => "B_ANTIC_NFS360SHUVIT_CYC",
            Self::AirCycle => "B_AIR_CYC",
            Self::StraightLanding => "BLEND_LAND",
            Self::NiceLanding => "B_LAND_NICE",
            Self::SketchLanding => "B_LAND_SKETCH",
        }
    }

    fn generic_anticipation_axes(self) -> Option<(AnticipationSide, AnticipationPhase)> {
        match self {
            Self::AnticIntoTail => Some((AnticipationSide::Tail, AnticipationPhase::Into)),
            Self::AnticIntoNose => Some((AnticipationSide::Nose, AnticipationPhase::Into)),
            Self::AnticCycleTail => Some((AnticipationSide::Tail, AnticipationPhase::Cycle)),
            Self::AnticCycleNose => Some((AnticipationSide::Nose, AnticipationPhase::Cycle)),
            Self::AnticOutTail => Some((AnticipationSide::Tail, AnticipationPhase::Out)),
            Self::AnticOutNose => Some((AnticipationSide::Nose, AnticipationPhase::Out)),
            _ => None,
        }
    }

    fn shuv_anticipation_family(self) -> Option<ShuvAnticipationFamily> {
        match self {
            Self::Antic360ShuvitCycle => Some(ShuvAnticipationFamily::TailBackside),
            Self::AnticFs360ShuvitCycle => Some(ShuvAnticipationFamily::TailFrontside),
            Self::AnticNose360ShuvitCycle => Some(ShuvAnticipationFamily::NoseBackside),
            Self::AnticNoseFs360ShuvitCycle => Some(ShuvAnticipationFamily::NoseFrontside),
            _ => None,
        }
    }
}

pub const VIRTUAL_RESOURCES: [VirtualResource; 14] = [
    VirtualResource::AnticIntoTail,
    VirtualResource::AnticIntoNose,
    VirtualResource::AnticCycleTail,
    VirtualResource::AnticCycleNose,
    VirtualResource::AnticOutTail,
    VirtualResource::AnticOutNose,
    VirtualResource::Antic360ShuvitCycle,
    VirtualResource::AnticFs360ShuvitCycle,
    VirtualResource::AnticNose360ShuvitCycle,
    VirtualResource::AnticNoseFs360ShuvitCycle,
    VirtualResource::AirCycle,
    VirtualResource::StraightLanding,
    VirtualResource::NiceLanding,
    VirtualResource::SketchLanding,
];

pub fn virtual_resource_by_name(name: &str) -> Option<VirtualResource> {
    VIRTUAL_RESOURCES
        .iter()
        .copied()
        .find(|resource| resource.name() == name)
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ResourceClass {
    Physical(&'static CatalogEntry),
    Virtual(VirtualResource),
    Unknown,
}

pub fn classify_resource(name: &str) -> ResourceClass {
    if let Some(clip) = physical_clip_by_name(name) {
        ResourceClass::Physical(clip)
    } else if let Some(resource) = virtual_resource_by_name(name) {
        ResourceClass::Virtual(resource)
    } else {
        ResourceClass::Unknown
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum VirtualParameters {
    None,
    AnticipationEndpoint {
        strength: AnticipationStrength,
        direction: f32,
    },
    StraightLandingEndpoint {
        posture: LandingPosture,
        variant: LandingVariant,
    },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VirtualRequest {
    pub resource: VirtualResource,
    pub parameters: VirtualParameters,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnresolvedReason {
    AnticipationParametersRequired,
    StraightLandingParametersRequired,
    UnexpectedParameters,
    InvalidDirectionCoordinate,
    /// The exported evidence does not identify concrete leaves for this
    /// virtual resource.
    NoPhysicalMappingInEvidence,
    /// The evidence bundle exports this family, but it is outside the
    /// tail/nose ollie anticipation catalog requested here.
    OutsideSupportedCatalog,
    CatalogInvariantViolation,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct UnresolvedVirtual {
    pub resource: VirtualResource,
    pub reason: UnresolvedReason,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum VirtualResolution {
    Physical(&'static CatalogEntry),
    DirectionalBlend(DirectionalPhysicalBlend),
    Unresolved(UnresolvedVirtual),
}

fn unresolved(resource: VirtualResource, reason: UnresolvedReason) -> VirtualResolution {
    VirtualResolution::Unresolved(UnresolvedVirtual { resource, reason })
}

/// Resolve a virtual graph request only when all evidence-backed endpoint
/// parameters are explicit.
///
/// This function intentionally does not invent:
///
/// - the continuous normal/high (or crouch) anticipation blend policy;
/// - the random `BLEND_LAND` variant selector;
/// - the aggressive/loose landing blend coordinate;
/// - physical leaves behind `B_LAND_NICE` or `B_LAND_SKETCH`.
pub fn resolve_virtual(request: VirtualRequest) -> VirtualResolution {
    let resource = request.resource;

    if let Some((side, phase)) = resource.generic_anticipation_axes() {
        let VirtualParameters::AnticipationEndpoint {
            strength,
            direction,
        } = request.parameters
        else {
            return unresolved(resource, UnresolvedReason::AnticipationParametersRequired);
        };
        let Ok(weights) = directional_weights(direction) else {
            return unresolved(resource, UnresolvedReason::InvalidDirectionCoordinate);
        };
        let leaf_for = |direction| catalog_entry(antic(side, strength, phase, direction));
        let (Some(left), Some(neutral), Some(right)) = (
            leaf_for(DirectionCoordinate::Left),
            leaf_for(DirectionCoordinate::Neutral),
            leaf_for(DirectionCoordinate::Right),
        ) else {
            return unresolved(resource, UnresolvedReason::CatalogInvariantViolation);
        };
        return VirtualResolution::DirectionalBlend(DirectionalPhysicalBlend {
            left: WeightedPhysicalLeaf {
                clip: left,
                weight: weights.left,
            },
            neutral: WeightedPhysicalLeaf {
                clip: neutral,
                weight: weights.neutral,
            },
            right: WeightedPhysicalLeaf {
                clip: right,
                weight: weights.right,
            },
        });
    }

    if let Some(family) = resource.shuv_anticipation_family() {
        let VirtualParameters::AnticipationEndpoint {
            strength,
            direction,
        } = request.parameters
        else {
            return unresolved(resource, UnresolvedReason::AnticipationParametersRequired);
        };
        let Ok(weights) = directional_weights(direction) else {
            return unresolved(resource, UnresolvedReason::InvalidDirectionCoordinate);
        };
        let leaf_for = |direction| catalog_entry(shuv_antic(family, strength, direction));
        let (Some(left), Some(neutral), Some(right)) = (
            leaf_for(DirectionCoordinate::Left),
            leaf_for(DirectionCoordinate::Neutral),
            leaf_for(DirectionCoordinate::Right),
        ) else {
            return unresolved(resource, UnresolvedReason::CatalogInvariantViolation);
        };
        return VirtualResolution::DirectionalBlend(DirectionalPhysicalBlend {
            left: WeightedPhysicalLeaf {
                clip: left,
                weight: weights.left,
            },
            neutral: WeightedPhysicalLeaf {
                clip: neutral,
                weight: weights.neutral,
            },
            right: WeightedPhysicalLeaf {
                clip: right,
                weight: weights.right,
            },
        });
    }

    match resource {
        VirtualResource::Antic360ShuvitCycle
        | VirtualResource::AnticFs360ShuvitCycle
        | VirtualResource::AnticNose360ShuvitCycle
        | VirtualResource::AnticNoseFs360ShuvitCycle => {
            unreachable!("shuv anticipation resources are handled above")
        }
        VirtualResource::AirCycle => {
            if request.parameters != VirtualParameters::None {
                return unresolved(resource, UnresolvedReason::UnexpectedParameters);
            }
            match catalog_entry(PhysicalLeaf::AirIdle) {
                Some(clip) => VirtualResolution::Physical(clip),
                None => unresolved(resource, UnresolvedReason::CatalogInvariantViolation),
            }
        }
        VirtualResource::StraightLanding => {
            let VirtualParameters::StraightLandingEndpoint { posture, variant } =
                request.parameters
            else {
                return unresolved(
                    resource,
                    UnresolvedReason::StraightLandingParametersRequired,
                );
            };
            match catalog_entry(landing(posture, variant)) {
                Some(clip) => VirtualResolution::Physical(clip),
                None => unresolved(resource, UnresolvedReason::CatalogInvariantViolation),
            }
        }
        VirtualResource::NiceLanding | VirtualResource::SketchLanding => {
            unresolved(resource, UnresolvedReason::NoPhysicalMappingInEvidence)
        }
        VirtualResource::AnticIntoTail
        | VirtualResource::AnticIntoNose
        | VirtualResource::AnticCycleTail
        | VirtualResource::AnticCycleNose
        | VirtualResource::AnticOutTail
        | VirtualResource::AnticOutNose => {
            unreachable!("generic anticipation resources returned above")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    const MANIFEST: &str =
        include_str!("../assets/private/default_skate3_skater.manifest.txt");

    fn physical_names(resolution: VirtualResolution) -> Vec<&'static str> {
        match resolution {
            VirtualResolution::Physical(clip) => vec![clip.name],
            VirtualResolution::DirectionalBlend(blend) => {
                blend.clips().into_iter().map(|clip| clip.name).collect()
            }
            VirtualResolution::Unresolved(_) => Vec::new(),
        }
    }

    #[test]
    fn every_catalog_leaf_appears_in_the_export_manifest() {
        let manifest_actions: HashSet<_> = MANIFEST
            .lines()
            .filter_map(|line| line.strip_prefix("action="))
            .collect();
        assert_eq!(PHYSICAL_CATALOG.len(), 83);
        for entry in PHYSICAL_CATALOG {
            assert!(
                manifest_actions.contains(entry.name),
                "{} is missing from default_skate3_skater.manifest.txt",
                entry.name
            );
        }
    }

    #[test]
    fn newly_supported_catalog_entries_are_unique() {
        let names: HashSet<_> = PHYSICAL_CATALOG.iter().map(|entry| entry.name).collect();
        let leaves: HashSet<_> = PHYSICAL_CATALOG.iter().map(|entry| entry.leaf).collect();
        let indices: HashSet<_> = PHYSICAL_CATALOG
            .iter()
            .map(|entry| entry.catalog_index)
            .collect();
        assert_eq!(names.len(), PHYSICAL_CATALOG.len());
        assert_eq!(leaves.len(), PHYSICAL_CATALOG.len());
        assert_eq!(indices.len(), PHYSICAL_CATALOG.len());
    }

    #[test]
    fn directional_weights_are_normalized_and_saturate_at_endpoints() {
        for direction in [-4.0, -1.0, -0.75, -0.25, 0.0, 0.25, 0.75, 1.0, 4.0] {
            let weights = directional_weights(direction).unwrap();
            assert!((weights.sum() - 1.0).abs() <= f32::EPSILON);
            assert!(weights.left >= 0.0);
            assert!(weights.neutral >= 0.0);
            assert!(weights.right >= 0.0);
        }
        assert_eq!(
            directional_weights(-1.0).unwrap(),
            DirectionalWeights {
                left: 1.0,
                neutral: 0.0,
                right: 0.0
            }
        );
        assert_eq!(
            directional_weights(0.0).unwrap(),
            DirectionalWeights {
                left: 0.0,
                neutral: 1.0,
                right: 0.0
            }
        );
        assert_eq!(
            directional_weights(1.0).unwrap(),
            DirectionalWeights {
                left: 0.0,
                neutral: 0.0,
                right: 1.0
            }
        );
        assert!(directional_weights(f32::NAN).is_err());
        assert!(directional_weights(f32::INFINITY).is_err());
    }

    #[test]
    fn all_anticipation_endpoint_mappings_are_exact() {
        let resources = [
            (
                VirtualResource::AnticIntoTail,
                AnticipationSide::Tail,
                AnticipationPhase::Into,
                "OLLIE",
                "INTO",
            ),
            (
                VirtualResource::AnticIntoNose,
                AnticipationSide::Nose,
                AnticipationPhase::Into,
                "NOLLIE",
                "INTO",
            ),
            (
                VirtualResource::AnticCycleTail,
                AnticipationSide::Tail,
                AnticipationPhase::Cycle,
                "OLLIE",
                "CYC",
            ),
            (
                VirtualResource::AnticCycleNose,
                AnticipationSide::Nose,
                AnticipationPhase::Cycle,
                "NOLLIE",
                "CYC",
            ),
            (
                VirtualResource::AnticOutTail,
                AnticipationSide::Tail,
                AnticipationPhase::Out,
                "OLLIE",
                "OUT",
            ),
            (
                VirtualResource::AnticOutNose,
                AnticipationSide::Nose,
                AnticipationPhase::Out,
                "NOLLIE",
                "OUT",
            ),
        ];
        for (resource, side, phase, trick_name, phase_name) in resources {
            for (strength, strength_name) in [
                (AnticipationStrength::Normal, "ANTIC"),
                (AnticipationStrength::High, "HIGHANTIC"),
            ] {
                let resolution = resolve_virtual(VirtualRequest {
                    resource,
                    parameters: VirtualParameters::AnticipationEndpoint {
                        strength,
                        direction: 0.0,
                    },
                });
                let VirtualResolution::DirectionalBlend(blend) = resolution else {
                    panic!("expected directional anticipation blend");
                };
                for (coordinate, coordinate_name, weighted) in [
                    (DirectionCoordinate::Left, "L", blend.left),
                    (DirectionCoordinate::Neutral, "N", blend.neutral),
                    (DirectionCoordinate::Right, "R", blend.right),
                ] {
                    assert_eq!(weighted.clip.leaf, antic(side, strength, phase, coordinate));
                    assert_eq!(
                        weighted.clip.name,
                        format!("R_{strength_name}_{trick_name}_{coordinate_name}_0_{phase_name}")
                    );
                    assert_eq!(weighted.clip.native_fps, 30);
                }
                assert!((blend.weight_sum() - 1.0).abs() <= f32::EPSILON);
            }
        }
    }

    #[test]
    fn all_shuv_anticipation_endpoint_mappings_are_exact() {
        let resources = [
            (
                VirtualResource::Antic360ShuvitCycle,
                ShuvAnticipationFamily::TailBackside,
                "360SHUVIT",
            ),
            (
                VirtualResource::AnticFs360ShuvitCycle,
                ShuvAnticipationFamily::TailFrontside,
                "FS360SHUVIT",
            ),
            (
                VirtualResource::AnticNose360ShuvitCycle,
                ShuvAnticipationFamily::NoseBackside,
                "N360SHUVIT",
            ),
            (
                VirtualResource::AnticNoseFs360ShuvitCycle,
                ShuvAnticipationFamily::NoseFrontside,
                "NFS360SHUVIT",
            ),
        ];
        for (resource, family, family_name) in resources {
            for (strength, strength_name) in [
                (AnticipationStrength::Normal, "ANTIC"),
                (AnticipationStrength::High, "HIGHANTIC"),
            ] {
                let resolution = resolve_virtual(VirtualRequest {
                    resource,
                    parameters: VirtualParameters::AnticipationEndpoint {
                        strength,
                        direction: 0.0,
                    },
                });
                let VirtualResolution::DirectionalBlend(blend) = resolution else {
                    panic!("expected directional shuv anticipation blend");
                };
                for (coordinate, coordinate_name, weighted) in [
                    (DirectionCoordinate::Left, "L", blend.left),
                    (DirectionCoordinate::Neutral, "N", blend.neutral),
                    (DirectionCoordinate::Right, "R", blend.right),
                ] {
                    assert_eq!(weighted.clip.leaf, shuv_antic(family, strength, coordinate));
                    assert_eq!(
                        weighted.clip.name,
                        format!("R_{strength_name}_{family_name}_{coordinate_name}_0_CYC")
                    );
                    assert_eq!(weighted.clip.native_fps, 30);
                }
                assert!((blend.weight_sum() - 1.0).abs() <= f32::EPSILON);
            }
        }
    }

    #[test]
    fn ollie_and_nollie_ground_air_endpoints_are_exact() {
        let cases = [
            (
                BasicTrick::Ollie,
                TrickHeight::Low,
                "OLLIE_LOW_G",
                13,
                "OLLIE_LOW_A",
                29,
            ),
            (
                BasicTrick::Ollie,
                TrickHeight::High,
                "OLLIE_HIGH_G",
                13,
                "OLLIE_HIGH_A",
                19,
            ),
            (
                BasicTrick::Nollie,
                TrickHeight::Low,
                "NOLLIE_LOW_G",
                13,
                "NOLLIE_LOW_A",
                29,
            ),
            (
                BasicTrick::Nollie,
                TrickHeight::High,
                "NOLLIE_HIGH_G",
                13,
                "NOLLIE_HIGH_A",
                24,
            ),
        ];
        for (trick, height, ground_name, ground_frames, air_name, air_frames) in cases {
            let pair = resolve_basic_trick(trick, height);
            assert_eq!(
                (pair.ground.name, pair.ground.frame_count),
                (ground_name, ground_frames)
            );
            assert_eq!(
                (pair.air.name, pair.air.frame_count),
                (air_name, air_frames)
            );
            assert_eq!(pair.ground.native_fps, 60);
            assert_eq!(pair.air.native_fps, 60);
        }
    }

    #[test]
    fn air_and_straight_landing_endpoint_mappings_are_exact() {
        let air = resolve_virtual(VirtualRequest {
            resource: VirtualResource::AirCycle,
            parameters: VirtualParameters::None,
        });
        let VirtualResolution::Physical(air) = air else {
            panic!("B_AIR_CYC baseline should resolve");
        };
        assert_eq!(
            (air.name, air.frame_count, air.native_fps),
            ("IA_IDLE_N_N_0_CYC", 60, 30)
        );

        let expected = [
            (
                LandingPosture::Aggressive,
                LandingVariant::One,
                "L_LAND_HIGH_AGGR_1_N",
                39,
            ),
            (
                LandingPosture::Aggressive,
                LandingVariant::Two,
                "L_LAND_HIGH_AGGR_2_N",
                71,
            ),
            (
                LandingPosture::Aggressive,
                LandingVariant::Three,
                "L_LAND_HIGH_AGGR_3_N",
                70,
            ),
            (
                LandingPosture::Loose,
                LandingVariant::One,
                "L_LAND_HIGH_LOOSE_1_N",
                66,
            ),
            (
                LandingPosture::Loose,
                LandingVariant::Two,
                "L_LAND_HIGH_LOOSE_2_N",
                71,
            ),
            (
                LandingPosture::Loose,
                LandingVariant::Three,
                "L_LAND_HIGH_LOOSE_3_N",
                62,
            ),
        ];
        for (posture, variant, name, frames) in expected {
            let resolution = resolve_virtual(VirtualRequest {
                resource: VirtualResource::StraightLanding,
                parameters: VirtualParameters::StraightLandingEndpoint { posture, variant },
            });
            let VirtualResolution::Physical(clip) = resolution else {
                panic!("fully specified BLEND_LAND endpoint should resolve");
            };
            assert_eq!(
                (clip.name, clip.frame_count, clip.native_fps),
                (name, frames, 60)
            );
        }
    }

    #[test]
    fn unresolved_virtual_resources_remain_typed() {
        for resource in [VirtualResource::NiceLanding, VirtualResource::SketchLanding] {
            assert_eq!(
                resolve_virtual(VirtualRequest {
                    resource,
                    parameters: VirtualParameters::None,
                }),
                VirtualResolution::Unresolved(UnresolvedVirtual {
                    resource,
                    reason: UnresolvedReason::NoPhysicalMappingInEvidence,
                })
            );
        }
        assert_eq!(
            resolve_virtual(VirtualRequest {
                resource: VirtualResource::StraightLanding,
                parameters: VirtualParameters::None,
            }),
            VirtualResolution::Unresolved(UnresolvedVirtual {
                resource: VirtualResource::StraightLanding,
                reason: UnresolvedReason::StraightLandingParametersRequired,
            })
        );
    }

    #[test]
    fn no_virtual_resource_name_is_returned_as_physical() {
        for entry in PHYSICAL_CATALOG {
            assert!(virtual_resource_by_name(entry.name).is_none());
            assert!(matches!(
                classify_resource(entry.name),
                ResourceClass::Physical(_)
            ));
        }
        for resource in VIRTUAL_RESOURCES {
            assert!(physical_clip_by_name(resource.name()).is_none());
            assert!(matches!(
                classify_resource(resource.name()),
                ResourceClass::Virtual(found) if found == resource
            ));
        }

        let requests = [
            VirtualRequest {
                resource: VirtualResource::AnticCycleTail,
                parameters: VirtualParameters::AnticipationEndpoint {
                    strength: AnticipationStrength::High,
                    direction: 0.4,
                },
            },
            VirtualRequest {
                resource: VirtualResource::AirCycle,
                parameters: VirtualParameters::None,
            },
            VirtualRequest {
                resource: VirtualResource::StraightLanding,
                parameters: VirtualParameters::StraightLandingEndpoint {
                    posture: LandingPosture::Loose,
                    variant: LandingVariant::Two,
                },
            },
        ];
        for request in requests {
            for name in physical_names(resolve_virtual(request)) {
                assert!(virtual_resource_by_name(name).is_none());
                assert!(physical_clip_by_name(name).is_some());
            }
        }
    }
}
