//! Decoded physical leaves and authored Andale trees behind Skate 3 TU3
//! landing resources.
//!
//! OnBoard.abin type-7 blocks recover the SPIN -> DISTTOCOG -> AVGVELY tree.
//! Type-8 blocks recover the RANDOM selectors. Physical clip records provide
//! the exact coordinate values used to sort and blend every child.
#![allow(dead_code)]

use crate::anticipation_graph::andale_endpoint_weight;
use crate::landing_graph::LandingQuality;
use crate::trick_catalog::LandingPosture;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LandingSide {
    Backside,
    Frontside,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LandingCompression {
    Low,
    High,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum LandingImpact {
    Low,
    High,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct NonStraightLandingAxes {
    pub side: LandingSide,
    pub compression: LandingCompression,
    /// Required only for the HCOM branch. LCOM clips do not encode impact.
    pub impact: Option<LandingImpact>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DecodedLandingClip {
    pub name: &'static str,
    pub catalog_index: u16,
    pub frame_count: u16,
    pub native_fps: u16,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LandingTreeParameters {
    /// SetLandingData's SPIN attribute after the regular/reversed orientation
    /// sign adjustment.
    pub spin: f32,
    /// PhysOut_Animation `+72`, copied to DISTTOCOG by SetLandingData.
    pub distance_to_cog: f32,
    /// Maximum downward auxiliary projection copied to AVGVELY.
    pub average_velocity_y: f32,
    /// Current integer RANDOM attribute. Type-8 selectors use their first
    /// child when no authored selector value matches.
    pub random_attribute: u8,
    pub straight_posture: LandingPosture,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WeightedLandingClip {
    pub name: &'static str,
    pub weight: f32,
}

#[derive(Clone, Debug)]
struct EvaluatedLandingNode {
    samples: Vec<WeightedLandingClip>,
    distance_to_cog: f32,
    average_velocity_y: Option<f32>,
    spin: f32,
}

const AVG_VELOCITY_LOW: f32 = 2.680_000_066_757_202;
const AVG_VELOCITY_HIGH: f32 = 6.0;
const STRAIGHT_LOW_DISTANCE: [f32; 3] = [0.517_209_65, 0.517_209_65, 0.518_136_9];
const STRAIGHT_LIMP_DISTANCE: [f32; 3] = [0.762_490_15, 0.760_173_26, 0.762_490_2];
const STRAIGHT_AGGRESSIVE_HIMP_DISTANCE: [f32; 3] = [1.051_670_9, 0.872_329_4, 0.872_329_4];
const STRAIGHT_LOOSE_HIMP_DISTANCE: [f32; 3] = [1.022_435_5, 0.734_986_25, 0.787_333_67];

const NICE_LOW_DISTANCE: [f32; 2] = [0.517_419_16, 0.515_369_2];
const NICE_HIGH_DISTANCE: [f32; 2] = [1.072_772_5, 1.078_362_8];

const SKETCH_BS_LOW_DISTANCE: [f32; 5] = [
    0.515_463_65,
    0.539_526_7,
    0.515_463_65,
    0.517_365_1,
    0.517_365_2,
];
const SKETCH_BS_LIMP_DISTANCE: [f32; 5] = [
    1.072_866_7,
    1.073_290_1,
    1.072_866_7,
    1.072_866_6,
    1.072_866_6,
];
const SKETCH_BS_HIMP_DISTANCE: [f32; 5] = [
    1.073_977_7,
    1.073_290_1,
    1.073_977_7,
    1.072_866_6,
    1.072_866_6,
];
const SKETCH_FS_LOW_DISTANCE: [f32; 5] = [
    0.515_698_5,
    0.517_365_2,
    0.517_494_3,
    0.517_625_8,
    0.517_365_1,
];
const SKETCH_FS_LIMP_DISTANCE: [f32; 5] = [
    1.072_866_3,
    1.071_680_5,
    1.072_584,
    1.072_583_7,
    1.072_866_6,
];
const SKETCH_FS_HIMP_DISTANCE: [f32; 5] = [
    1.072_866_3,
    1.071_680_5,
    1.072_584,
    1.072_713_6,
    1.072_866_8,
];

impl DecodedLandingClip {
    pub fn authored_duration_seconds(self) -> f32 {
        self.frame_count.saturating_sub(1) as f32 / self.native_fps as f32
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LandingLeafUnresolved {
    StraightUsesBlendLand,
    AxesRequired,
    ImpactRequiredForHighCompression,
    ImpactNotAuthoredForLowCompression,
    VariantRequired,
    VariantOutOfRange { variant: u8, variant_count: u8 },
    CatalogInvariantViolation,
}

macro_rules! decoded {
    ($name:literal, $index:literal, $frames:literal) => {
        DecodedLandingClip {
            name: $name,
            catalog_index: $index,
            frame_count: $frames,
            native_fps: 60,
        }
    };
}

/// Exact contiguous OnBoard catalog slice for `B_LAND_NICE` and
/// `B_LAND_SKETCH`. Straight `BLEND_LAND` lives in `trick_catalog`.
pub const NON_STRAIGHT_LANDING_CLIPS: [DecodedLandingClip; 36] = [
    decoded!("L_NICE_BS_HCOM_HSP_HIMP", 1315, 65),
    decoded!("L_NICE_BS_HCOM_HSP_LIMP", 1316, 65),
    decoded!("L_NICE_BS_LCOM_HSP", 1317, 48),
    decoded!("L_NICE_FS_HCOM_HSP_HIMP", 1318, 48),
    decoded!("L_NICE_FS_HCOM_HSP_LIMP", 1319, 48),
    decoded!("L_NICE_FS_LCOM_HSP", 1320, 48),
    decoded!("L_SKETCH_BS_HCOM_HIMP", 1327, 90),
    decoded!("L_SKETCH_BS_HCOM_HIMP1", 1328, 81),
    decoded!("L_SKETCH_BS_HCOM_HIMP2", 1329, 90),
    decoded!("L_SKETCH_BS_HCOM_HIMP3", 1330, 76),
    decoded!("L_SKETCH_BS_HCOM_HIMP4", 1331, 73),
    decoded!("L_SKETCH_BS_HCOM_LIMP", 1332, 103),
    decoded!("L_SKETCH_BS_HCOM_LIMP1", 1333, 81),
    decoded!("L_SKETCH_BS_HCOM_LIMP2", 1334, 103),
    decoded!("L_SKETCH_BS_HCOM_LIMP3", 1335, 76),
    decoded!("L_SKETCH_BS_HCOM_LIMP4", 1336, 73),
    decoded!("L_SKETCH_BS_LCOM", 1337, 103),
    decoded!("L_SKETCH_BS_LCOM1", 1338, 81),
    decoded!("L_SKETCH_BS_LCOM2", 1339, 103),
    decoded!("L_SKETCH_BS_LCOM3", 1340, 76),
    decoded!("L_SKETCH_BS_LCOM4", 1341, 73),
    decoded!("L_SKETCH_FS_HCOM_HIMP", 1342, 81),
    decoded!("L_SKETCH_FS_HCOM_HIMP1", 1343, 91),
    decoded!("L_SKETCH_FS_HCOM_HIMP2", 1344, 89),
    decoded!("L_SKETCH_FS_HCOM_HIMP3", 1345, 136),
    decoded!("L_SKETCH_FS_HCOM_HIMP4", 1346, 97),
    decoded!("L_SKETCH_FS_HCOM_LIMP", 1347, 81),
    decoded!("L_SKETCH_FS_HCOM_LIMP1", 1348, 91),
    decoded!("L_SKETCH_FS_HCOM_LIMP2", 1349, 89),
    decoded!("L_SKETCH_FS_HCOM_LIMP3", 1350, 136),
    decoded!("L_SKETCH_FS_HCOM_LIMP4", 1351, 97),
    decoded!("L_SKETCH_FS_LCOM", 1352, 81),
    decoded!("L_SKETCH_FS_LCOM1", 1353, 91),
    decoded!("L_SKETCH_FS_LCOM2", 1354, 89),
    decoded!("L_SKETCH_FS_LCOM3", 1355, 136),
    decoded!("L_SKETCH_FS_LCOM4", 1356, 97),
];

pub fn decoded_landing_clip_by_name(name: &str) -> Option<&'static DecodedLandingClip> {
    NON_STRAIGHT_LANDING_CLIPS
        .iter()
        .find(|clip| clip.name == name)
}

fn selected_sequence_index(random_attribute: u8, child_count: usize) -> usize {
    let index = usize::from(random_attribute);
    // Type-8 loading at 0x82D1B9B4 searches authored selector records and
    // recursively loads the first/default child when no record matches.
    (index < child_count).then_some(index).unwrap_or(0)
}

fn straight_leaf_names(
    random_attribute: u8,
    posture: LandingPosture,
) -> (&'static str, &'static str, &'static str, usize) {
    let index = selected_sequence_index(random_attribute, 3);
    let low = ["L_LCOM_1", "L_LCOM_2", "L_LCOM_3"][index];
    let limp = ["L_HCOM_LIMP_1", "L_HCOM_LIMP_2", "L_HCOM_LIMP_3"][index];
    let high = match posture {
        LandingPosture::Aggressive => [
            "L_LAND_HIGH_AGGR_1_N",
            "L_LAND_HIGH_AGGR_2_N",
            "L_LAND_HIGH_AGGR_3_N",
        ][index],
        LandingPosture::Loose => [
            "L_LAND_HIGH_LOOSE_1_N",
            "L_LAND_HIGH_LOOSE_2_N",
            "L_LAND_HIGH_LOOSE_3_N",
        ][index],
    };
    (low, limp, high, index)
}

fn leaf(
    name: &'static str,
    distance_to_cog: f32,
    average_velocity_y: Option<f32>,
    spin: f32,
) -> EvaluatedLandingNode {
    EvaluatedLandingNode {
        samples: vec![WeightedLandingClip { name, weight: 1.0 }],
        distance_to_cog,
        average_velocity_y,
        spin,
    }
}

fn blend_nodes(
    mut low: EvaluatedLandingNode,
    mut high: EvaluatedLandingNode,
    input: f32,
    low_coordinate: f32,
    high_coordinate: f32,
) -> EvaluatedLandingNode {
    let raw = if high_coordinate > low_coordinate {
        ((input - low_coordinate) / (high_coordinate - low_coordinate)).clamp(0.0, 1.0)
    } else {
        1.0
    };
    let high_weight = andale_endpoint_weight(raw);
    let low_weight = 1.0 - high_weight;
    for sample in &mut low.samples {
        sample.weight *= low_weight;
    }
    for sample in &mut high.samples {
        sample.weight *= high_weight;
    }
    low.samples.extend(high.samples);
    low.samples.retain(|sample| sample.weight > f32::EPSILON);

    let blend_scalar =
        |low_value: f32, high_value: f32| (high_value - low_value).mul_add(high_weight, low_value);
    EvaluatedLandingNode {
        samples: low.samples,
        distance_to_cog: blend_scalar(low.distance_to_cog, high.distance_to_cog),
        average_velocity_y: match (low.average_velocity_y, high.average_velocity_y) {
            (Some(low), Some(high)) => Some(blend_scalar(low, high)),
            _ => None,
        },
        spin: blend_scalar(low.spin, high.spin),
    }
}

fn straight_tree(parameters: LandingTreeParameters) -> EvaluatedLandingNode {
    let (low_name, limp_name, high_name, index) =
        straight_leaf_names(parameters.random_attribute, parameters.straight_posture);
    let high_distance = match parameters.straight_posture {
        LandingPosture::Aggressive => STRAIGHT_AGGRESSIVE_HIMP_DISTANCE[index],
        LandingPosture::Loose => STRAIGHT_LOOSE_HIMP_DISTANCE[index],
    };
    let limp = leaf(
        limp_name,
        STRAIGHT_LIMP_DISTANCE[index],
        Some(AVG_VELOCITY_LOW),
        0.0,
    );
    let high = leaf(high_name, high_distance, Some(AVG_VELOCITY_HIGH), 0.0);
    let impact = blend_nodes(
        limp,
        high,
        parameters.average_velocity_y,
        AVG_VELOCITY_LOW,
        AVG_VELOCITY_HIGH,
    );
    let impact_distance = impact.distance_to_cog;
    blend_nodes(
        leaf(low_name, STRAIGHT_LOW_DISTANCE[index], None, 0.0),
        impact,
        parameters.distance_to_cog,
        STRAIGHT_LOW_DISTANCE[index],
        impact_distance,
    )
}

fn nice_side_tree(side: LandingSide, parameters: LandingTreeParameters) -> EvaluatedLandingNode {
    let (index, side_name, spin) = match side {
        LandingSide::Backside => (0, "BS", 1.0),
        LandingSide::Frontside => (1, "FS", -1.0),
    };
    let low_name = match side {
        LandingSide::Backside => "L_NICE_BS_LCOM_HSP",
        LandingSide::Frontside => "L_NICE_FS_LCOM_HSP",
    };
    let limp_name = match side {
        LandingSide::Backside => "L_NICE_BS_HCOM_HSP_LIMP",
        LandingSide::Frontside => "L_NICE_FS_HCOM_HSP_LIMP",
    };
    let high_name = match side {
        LandingSide::Backside => "L_NICE_BS_HCOM_HSP_HIMP",
        LandingSide::Frontside => "L_NICE_FS_HCOM_HSP_HIMP",
    };
    debug_assert!(side_name == "BS" || side_name == "FS");
    let impact = blend_nodes(
        leaf(
            limp_name,
            NICE_HIGH_DISTANCE[index],
            Some(AVG_VELOCITY_LOW),
            spin,
        ),
        leaf(
            high_name,
            NICE_HIGH_DISTANCE[index],
            Some(AVG_VELOCITY_HIGH),
            spin,
        ),
        parameters.average_velocity_y,
        AVG_VELOCITY_LOW,
        AVG_VELOCITY_HIGH,
    );
    let impact_distance = impact.distance_to_cog;
    blend_nodes(
        leaf(low_name, NICE_LOW_DISTANCE[index], None, spin),
        impact,
        parameters.distance_to_cog,
        NICE_LOW_DISTANCE[index],
        impact_distance,
    )
}

fn sketch_side_tree(side: LandingSide, parameters: LandingTreeParameters) -> EvaluatedLandingNode {
    let variant = selected_sequence_index(parameters.random_attribute, 5);
    let suffix = ["", "1", "2", "3", "4"][variant];
    let (side_name, spin, low_distance, limp_distance, high_distance) = match side {
        LandingSide::Backside => (
            "BS",
            1.0,
            SKETCH_BS_LOW_DISTANCE[variant],
            SKETCH_BS_LIMP_DISTANCE[variant],
            SKETCH_BS_HIMP_DISTANCE[variant],
        ),
        LandingSide::Frontside => (
            "FS",
            -1.0,
            SKETCH_FS_LOW_DISTANCE[variant],
            SKETCH_FS_LIMP_DISTANCE[variant],
            SKETCH_FS_HIMP_DISTANCE[variant],
        ),
    };
    let low_name = decoded_landing_clip_by_name(&format!("L_SKETCH_{side_name}_LCOM{suffix}"))
        .expect("decoded Sketch LCOM catalog is complete")
        .name;
    let limp_name =
        decoded_landing_clip_by_name(&format!("L_SKETCH_{side_name}_HCOM_LIMP{suffix}"))
            .expect("decoded Sketch LIMP catalog is complete")
            .name;
    let high_name =
        decoded_landing_clip_by_name(&format!("L_SKETCH_{side_name}_HCOM_HIMP{suffix}"))
            .expect("decoded Sketch HIMP catalog is complete")
            .name;
    let impact = blend_nodes(
        leaf(limp_name, limp_distance, Some(AVG_VELOCITY_LOW), spin),
        leaf(high_name, high_distance, Some(AVG_VELOCITY_HIGH), spin),
        parameters.average_velocity_y,
        AVG_VELOCITY_LOW,
        AVG_VELOCITY_HIGH,
    );
    let impact_distance = impact.distance_to_cog;
    blend_nodes(
        leaf(low_name, low_distance, None, spin),
        impact,
        parameters.distance_to_cog,
        low_distance,
        impact_distance,
    )
}

/// Evaluate the complete authored landing tree into physical Bevy clips.
///
/// `B_LAND_NICE` and `B_LAND_SKETCH` both sort their SPIN children as
/// Frontside=-1, BLEND_LAND=0, Backside=+1 before choosing adjacent nodes.
pub fn resolve_landing_tree(
    quality: LandingQuality,
    parameters: LandingTreeParameters,
) -> Vec<WeightedLandingClip> {
    let straight = straight_tree(parameters);
    let root = match quality {
        LandingQuality::Straight => straight,
        LandingQuality::Spin | LandingQuality::Sketchy => {
            let side = |landing_side| match quality {
                LandingQuality::Spin => nice_side_tree(landing_side, parameters),
                LandingQuality::Sketchy => sketch_side_tree(landing_side, parameters),
                LandingQuality::Straight => unreachable!("matched above"),
            };
            if parameters.spin <= 0.0 {
                blend_nodes(
                    side(LandingSide::Frontside),
                    straight,
                    parameters.spin,
                    -1.0,
                    0.0,
                )
            } else {
                blend_nodes(
                    straight,
                    side(LandingSide::Backside),
                    parameters.spin,
                    0.0,
                    1.0,
                )
            }
        }
    };
    debug_assert!(!root.samples.is_empty());
    debug_assert!(
        (root.samples.iter().map(|sample| sample.weight).sum::<f32>() - 1.0).abs() < 1.0e-5
    );
    root.samples
}

/// Resolve an already-selected retail endpoint without inventing its provider.
pub fn resolve_non_straight_landing(
    quality: LandingQuality,
    axes: Option<NonStraightLandingAxes>,
    variant: Option<u8>,
) -> Result<&'static DecodedLandingClip, LandingLeafUnresolved> {
    if quality == LandingQuality::Straight {
        return Err(LandingLeafUnresolved::StraightUsesBlendLand);
    }
    let axes = axes.ok_or(LandingLeafUnresolved::AxesRequired)?;
    let side = match axes.side {
        LandingSide::Backside => "BS",
        LandingSide::Frontside => "FS",
    };
    let branch = match (axes.compression, axes.impact) {
        (LandingCompression::Low, None) => "LCOM",
        (LandingCompression::Low, Some(_)) => {
            return Err(LandingLeafUnresolved::ImpactNotAuthoredForLowCompression);
        }
        (LandingCompression::High, Some(LandingImpact::High)) => "HCOM_HIMP",
        (LandingCompression::High, Some(LandingImpact::Low)) => "HCOM_LIMP",
        (LandingCompression::High, None) => {
            return Err(LandingLeafUnresolved::ImpactRequiredForHighCompression);
        }
    };

    let name = match quality {
        LandingQuality::Spin => {
            if variant.is_some() {
                return Err(LandingLeafUnresolved::VariantOutOfRange {
                    variant: variant.unwrap_or_default(),
                    variant_count: 1,
                });
            }
            match (side, branch) {
                ("BS", "LCOM") => "L_NICE_BS_LCOM_HSP",
                ("BS", "HCOM_HIMP") => "L_NICE_BS_HCOM_HSP_HIMP",
                ("BS", "HCOM_LIMP") => "L_NICE_BS_HCOM_HSP_LIMP",
                ("FS", "LCOM") => "L_NICE_FS_LCOM_HSP",
                ("FS", "HCOM_HIMP") => "L_NICE_FS_HCOM_HSP_HIMP",
                ("FS", "HCOM_LIMP") => "L_NICE_FS_HCOM_HSP_LIMP",
                _ => return Err(LandingLeafUnresolved::CatalogInvariantViolation),
            }
        }
        LandingQuality::Sketchy => {
            let variant = variant.ok_or(LandingLeafUnresolved::VariantRequired)?;
            if variant >= 5 {
                return Err(LandingLeafUnresolved::VariantOutOfRange {
                    variant,
                    variant_count: 5,
                });
            }
            let suffix = match variant {
                0 => "",
                1 => "1",
                2 => "2",
                3 => "3",
                4 => "4",
                _ => unreachable!("range checked above"),
            };
            let name = format!("L_SKETCH_{side}_{branch}{suffix}");
            return decoded_landing_clip_by_name(&name)
                .ok_or(LandingLeafUnresolved::CatalogInvariantViolation);
        }
        LandingQuality::Straight => unreachable!("returned above"),
    };

    decoded_landing_clip_by_name(name).ok_or(LandingLeafUnresolved::CatalogInvariantViolation)
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn decoded_catalog_is_the_exact_unique_abin_slice() {
        assert_eq!(NON_STRAIGHT_LANDING_CLIPS.len(), 36);
        assert_eq!(NON_STRAIGHT_LANDING_CLIPS[0].catalog_index, 1315);
        assert_eq!(NON_STRAIGHT_LANDING_CLIPS[5].catalog_index, 1320);
        assert_eq!(NON_STRAIGHT_LANDING_CLIPS[6].catalog_index, 1327);
        assert_eq!(NON_STRAIGHT_LANDING_CLIPS[35].catalog_index, 1356);
        assert!(
            NON_STRAIGHT_LANDING_CLIPS
                .iter()
                .all(|clip| clip.native_fps == 60)
        );
        assert_eq!(
            NON_STRAIGHT_LANDING_CLIPS
                .iter()
                .map(|clip| clip.name)
                .collect::<HashSet<_>>()
                .len(),
            36
        );
    }

    #[test]
    fn every_explicit_nice_axis_combination_resolves() {
        for side in [LandingSide::Backside, LandingSide::Frontside] {
            let low = resolve_non_straight_landing(
                LandingQuality::Spin,
                Some(NonStraightLandingAxes {
                    side,
                    compression: LandingCompression::Low,
                    impact: None,
                }),
                None,
            )
            .unwrap();
            assert!(low.name.starts_with("L_NICE_"));
            for impact in [LandingImpact::Low, LandingImpact::High] {
                let high = resolve_non_straight_landing(
                    LandingQuality::Spin,
                    Some(NonStraightLandingAxes {
                        side,
                        compression: LandingCompression::High,
                        impact: Some(impact),
                    }),
                    None,
                )
                .unwrap();
                assert!(high.name.starts_with("L_NICE_"));
            }
        }
    }

    #[test]
    fn sketch_variants_are_zero_based_and_cover_all_thirty_leaves() {
        let mut names = HashSet::new();
        for side in [LandingSide::Backside, LandingSide::Frontside] {
            for (compression, impacts) in [
                (LandingCompression::Low, [None, None]),
                (
                    LandingCompression::High,
                    [Some(LandingImpact::Low), Some(LandingImpact::High)],
                ),
            ] {
                for impact in impacts.into_iter().collect::<HashSet<_>>() {
                    for variant in 0..5 {
                        names.insert(
                            resolve_non_straight_landing(
                                LandingQuality::Sketchy,
                                Some(NonStraightLandingAxes {
                                    side,
                                    compression,
                                    impact,
                                }),
                                Some(variant),
                            )
                            .unwrap()
                            .name,
                        );
                    }
                }
            }
        }
        assert_eq!(names.len(), 30);
    }

    #[test]
    fn unknown_provider_axes_never_fall_back_to_a_plausible_clip() {
        assert_eq!(
            resolve_non_straight_landing(LandingQuality::Sketchy, None, Some(0)),
            Err(LandingLeafUnresolved::AxesRequired)
        );
        assert_eq!(
            resolve_non_straight_landing(
                LandingQuality::Spin,
                Some(NonStraightLandingAxes {
                    side: LandingSide::Backside,
                    compression: LandingCompression::High,
                    impact: None,
                }),
                None,
            ),
            Err(LandingLeafUnresolved::ImpactRequiredForHighCompression)
        );
    }

    fn tree_parameters() -> LandingTreeParameters {
        LandingTreeParameters {
            spin: 0.0,
            distance_to_cog: 0.793_520_987,
            average_velocity_y: 3.667_144_5,
            random_attribute: 2,
            straight_posture: LandingPosture::Aggressive,
        }
    }

    fn assert_normalized(samples: &[WeightedLandingClip]) {
        assert!(!samples.is_empty());
        assert!((samples.iter().map(|sample| sample.weight).sum::<f32>() - 1.0).abs() < 1.0e-5);
        assert!(samples.iter().all(|sample| sample.weight > 0.0));
    }

    #[test]
    fn straight_tree_uses_disttocog_then_avgvely_with_authored_coordinates() {
        let samples = resolve_landing_tree(LandingQuality::Straight, tree_parameters());
        assert_normalized(&samples);
        assert!(samples.iter().any(|sample| sample.name == "L_HCOM_LIMP_3"));
        assert!(
            samples
                .iter()
                .any(|sample| sample.name == "L_LAND_HIGH_AGGR_3_N")
        );
    }

    #[test]
    fn nice_root_blends_frontside_straight_and_backside_by_spin() {
        let backside = resolve_landing_tree(
            LandingQuality::Spin,
            LandingTreeParameters {
                spin: 1.0,
                ..tree_parameters()
            },
        );
        assert_normalized(&backside);
        assert!(
            backside
                .iter()
                .all(|sample| sample.name.starts_with("L_NICE_BS_"))
        );

        let frontside = resolve_landing_tree(
            LandingQuality::Spin,
            LandingTreeParameters {
                spin: -1.0,
                ..tree_parameters()
            },
        );
        assert_normalized(&frontside);
        assert!(
            frontside
                .iter()
                .all(|sample| sample.name.starts_with("L_NICE_FS_"))
        );

        let partial = resolve_landing_tree(
            LandingQuality::Spin,
            LandingTreeParameters {
                spin: 0.5,
                ..tree_parameters()
            },
        );
        assert_normalized(&partial);
        assert!(
            partial
                .iter()
                .any(|sample| sample.name.starts_with("L_NICE_BS_"))
        );
        assert!(
            partial
                .iter()
                .any(|sample| sample.name.starts_with("L_") && !sample.name.starts_with("L_NICE_"))
        );
    }

    #[test]
    fn sketch_sequences_use_random_selector_and_default_first_child() {
        let sketch = resolve_landing_tree(
            LandingQuality::Sketchy,
            LandingTreeParameters {
                spin: -1.0,
                random_attribute: 3,
                ..tree_parameters()
            },
        );
        assert_normalized(&sketch);
        assert!(
            sketch
                .iter()
                .all(|sample| sample.name.starts_with("L_SKETCH_FS_") && sample.name.ends_with('3'))
        );

        let straight_default = resolve_landing_tree(
            LandingQuality::Straight,
            LandingTreeParameters {
                random_attribute: 4,
                ..tree_parameters()
            },
        );
        assert_normalized(&straight_default);
        assert!(straight_default.iter().all(|sample| {
            sample.name.ends_with("_1") || sample.name == "L_LAND_HIGH_AGGR_1_N"
        }));
    }
}
