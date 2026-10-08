//! Deterministic adapter from motion-graph animation requests to physical leaves.
//!
//! The basic trick graph is allowed to request both concrete ABIN resources and
//! virtual `B_*`/`BLEND_*` resources.  This module is the boundary that prevents
//! virtual names from reaching a Bevy animation player.  It delegates all
//! evidence-backed leaf selection to `trick_catalog` and transports graph timing
//! without advancing, wrapping, or otherwise deriving a second clock.
#![allow(dead_code)]

use crate::basic_trick_graph::BasicTrickAnimationRequest;
use crate::landing_animation::LandingLeafUnresolved;
use crate::trick_catalog::{
    AnticipationStrength, CatalogEntry, LandingPosture, LandingVariant, ResourceClass,
    UnresolvedReason, VirtualParameters, VirtualRequest, VirtualResolution, VirtualResource,
    classify_resource,
};

/// Typed parameters for virtual animation resources.
///
/// `None` is correct for concrete resources and `B_AIR_CYC`.  Generic
/// anticipation and `BLEND_LAND` requests resolve only with their corresponding
/// typed parameter payload.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub enum TrickAnimationParameters {
    #[default]
    None,
    Anticipation(AnticipationParameters),
    StraightLanding(StraightLandingParameters),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AnticipationParameters {
    pub strength: AnticipationStrength,
    /// Signed L/N/R coordinate: `-1` is left, `0` neutral, and `1` right.
    /// Finite values outside that interval are saturated by the catalog.
    pub direction: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StraightLandingParameters {
    pub posture: LandingPosture,
    pub variant: LandingVariant,
}

impl From<AnticipationParameters> for TrickAnimationParameters {
    fn from(parameters: AnticipationParameters) -> Self {
        Self::Anticipation(parameters)
    }
}

impl From<StraightLandingParameters> for TrickAnimationParameters {
    fn from(parameters: StraightLandingParameters) -> Self {
        Self::StraightLanding(parameters)
    }
}

/// Classification of the graph resource that produced a physical sample.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SourceResourceKind {
    Physical,
    Virtual(VirtualResource),
}

/// Exact graph-resource provenance retained after virtual-resource resolution.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SourceResourceProvenance {
    pub resource: &'static str,
    pub kind: SourceResourceKind,
}

/// A physical weighted catalog leaf, ready for a later mechanical conversion
/// into `sim::AnimationSample`.
///
/// `seek_time_seconds` remains on the graph's fixed clock.  The adapter does not
/// clamp it to clip duration or modulo it for repeating resources.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicalLeafSample {
    pub clip: &'static CatalogEntry,
    pub weight: f32,
    pub seek_time_seconds: f32,
    pub source: SourceResourceProvenance,
}

impl PhysicalLeafSample {
    pub fn clip_name(self) -> &'static str {
        self.clip.name
    }
}

/// Fully physical animation request with graph transition and repeat semantics.
#[derive(Clone, Debug, PartialEq)]
pub struct AdaptedTrickAnimation {
    pub samples: Vec<PhysicalLeafSample>,
    pub transition_seconds: f32,
    pub repeats: bool,
    pub source: SourceResourceProvenance,
}

impl AdaptedTrickAnimation {
    pub fn total_weight(&self) -> f32 {
        self.samples.iter().map(|sample| sample.weight).sum()
    }
}

/// Typed failure classification.  No failure path substitutes a plausible clip.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct UnresolvedTrickAnimation {
    pub source_resource: &'static str,
    pub reason: AdapterUnresolvedReason,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AdapterUnresolvedReason {
    UnknownResource,
    UnexpectedParametersForPhysicalResource,
    Virtual {
        resource: VirtualResource,
        reason: UnresolvedReason,
    },
    /// A decoded Nice/Sketch physical family exists, but the unrecovered
    /// virtual-tree endpoint provider has not supplied all selection axes.
    NonStraightLandingEndpoint(LandingLeafUnresolved),
}

/// Resolve one graph request into physical catalog leaves.
///
/// On success, sample weights are non-negative and total one.  Directional
/// anticipation always retains its stable `[left, neutral, right]` topology,
/// including zero-weight leaves at interpolation endpoints.
pub fn adapt_basic_trick_request(
    request: BasicTrickAnimationRequest,
    parameters: TrickAnimationParameters,
) -> Result<AdaptedTrickAnimation, UnresolvedTrickAnimation> {
    match classify_resource(request.resource) {
        ResourceClass::Physical(clip) => {
            if parameters != TrickAnimationParameters::None {
                return Err(unresolved(
                    request.resource,
                    AdapterUnresolvedReason::UnexpectedParametersForPhysicalResource,
                ));
            }
            let source = SourceResourceProvenance {
                resource: request.resource,
                kind: SourceResourceKind::Physical,
            };
            Ok(adapt_physical(request, source, [(clip, 1.0)]))
        }
        ResourceClass::Virtual(resource) => {
            let source = SourceResourceProvenance {
                resource: request.resource,
                kind: SourceResourceKind::Virtual(resource),
            };
            let parameters = match parameters {
                TrickAnimationParameters::None => VirtualParameters::None,
                TrickAnimationParameters::Anticipation(parameters) => {
                    VirtualParameters::AnticipationEndpoint {
                        strength: parameters.strength,
                        direction: parameters.direction,
                    }
                }
                TrickAnimationParameters::StraightLanding(parameters) => {
                    VirtualParameters::StraightLandingEndpoint {
                        posture: parameters.posture,
                        variant: parameters.variant,
                    }
                }
            };
            match crate::trick_catalog::resolve_virtual(VirtualRequest {
                resource,
                parameters,
            }) {
                VirtualResolution::Physical(clip) => {
                    Ok(adapt_physical(request, source, [(clip, 1.0)]))
                }
                VirtualResolution::DirectionalBlend(blend) => Ok(adapt_physical(
                    request,
                    source,
                    [
                        (blend.left.clip, blend.left.weight),
                        (blend.neutral.clip, blend.neutral.weight),
                        (blend.right.clip, blend.right.weight),
                    ],
                )),
                VirtualResolution::Unresolved(failure) => Err(unresolved(
                    request.resource,
                    AdapterUnresolvedReason::Virtual {
                        resource: failure.resource,
                        reason: failure.reason,
                    },
                )),
            }
        }
        ResourceClass::Unknown => Err(unresolved(
            request.resource,
            AdapterUnresolvedReason::UnknownResource,
        )),
    }
}

fn unresolved(
    source_resource: &'static str,
    reason: AdapterUnresolvedReason,
) -> UnresolvedTrickAnimation {
    UnresolvedTrickAnimation {
        source_resource,
        reason,
    }
}

fn adapt_physical<const N: usize>(
    request: BasicTrickAnimationRequest,
    source: SourceResourceProvenance,
    leaves: [(&'static CatalogEntry, f32); N],
) -> AdaptedTrickAnimation {
    let total_weight: f32 = leaves.iter().map(|(_, weight)| *weight).sum();
    debug_assert!(total_weight.is_finite() && total_weight > 0.0);

    let samples = leaves
        .into_iter()
        .map(|(clip, weight)| PhysicalLeafSample {
            clip,
            // Catalog resolutions are normalized already. Dividing here also
            // protects the adapter invariant if their representation changes.
            weight: weight / total_weight,
            seek_time_seconds: request.local_time_seconds,
            source,
        })
        .collect();

    AdaptedTrickAnimation {
        samples,
        transition_seconds: request.transition_seconds,
        repeats: request.repeats,
        source,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::trick_catalog::{
        AnticipationPhase, AnticipationSide, DirectionCoordinate, PhysicalLeaf, VIRTUAL_RESOURCES,
        virtual_resource_by_name,
    };

    const SEEK: f32 = 37.0 / 120.0;

    fn request(
        resource: &'static str,
        transition_seconds: f32,
        repeats: bool,
    ) -> BasicTrickAnimationRequest {
        BasicTrickAnimationRequest {
            resource,
            local_time_seconds: SEEK,
            transition_seconds,
            repeats,
        }
    }

    fn adapt(
        resource: &'static str,
        parameters: TrickAnimationParameters,
    ) -> Result<AdaptedTrickAnimation, UnresolvedTrickAnimation> {
        adapt_basic_trick_request(request(resource, 0.15, false), parameters)
    }

    fn assert_normalized(adapted: &AdaptedTrickAnimation) {
        assert!(
            (adapted.total_weight() - 1.0).abs() <= 4.0 * f32::EPSILON,
            "{} weights totaled {}",
            adapted.source.resource,
            adapted.total_weight()
        );
        assert!(adapted.samples.iter().all(|sample| sample.weight >= 0.0));
    }

    #[test]
    fn every_concrete_basic_trick_ground_and_air_phase_resolves_directly() {
        let expected = [
            ("OLLIE_LOW_G", 13),
            ("OLLIE_LOW_A", 29),
            ("OLLIE_HIGH_G", 13),
            ("OLLIE_HIGH_A", 19),
            ("NOLLIE_LOW_G", 13),
            ("NOLLIE_LOW_A", 29),
            ("NOLLIE_HIGH_G", 13),
            ("NOLLIE_HIGH_A", 24),
        ];

        for (resource, frames) in expected {
            let adapted = adapt(resource, TrickAnimationParameters::None).unwrap();
            assert_eq!(adapted.samples.len(), 1);
            assert_eq!(adapted.samples[0].clip_name(), resource);
            assert_eq!(adapted.samples[0].clip.frame_count, frames);
            assert_eq!(
                adapted.source,
                SourceResourceProvenance {
                    resource,
                    kind: SourceResourceKind::Physical,
                }
            );
            assert_normalized(&adapted);
        }
    }

    #[test]
    fn air_baseline_resolves_to_idle_without_losing_graph_semantics() {
        let graph_request = request("B_AIR_CYC", 0.2, true);
        let adapted =
            adapt_basic_trick_request(graph_request, TrickAnimationParameters::None).unwrap();

        assert_eq!(adapted.samples.len(), 1);
        assert_eq!(adapted.samples[0].clip_name(), "IA_IDLE_N_N_0_CYC");
        assert_eq!(adapted.samples[0].seek_time_seconds, SEEK);
        assert_eq!(adapted.transition_seconds, 0.2);
        assert!(adapted.repeats);
        assert_eq!(
            adapted.source,
            SourceResourceProvenance {
                resource: "B_AIR_CYC",
                kind: SourceResourceKind::Virtual(VirtualResource::AirCycle),
            }
        );
        assert_eq!(adapted.samples[0].source, adapted.source);
        assert_normalized(&adapted);
    }

    #[test]
    fn anticipation_interpolates_stable_left_neutral_right_leaves() {
        let resources = [
            (
                "B_ANTIC_INTO",
                AnticipationSide::Tail,
                AnticipationPhase::Into,
            ),
            (
                "B_N_ANTIC_INTO",
                AnticipationSide::Nose,
                AnticipationPhase::Into,
            ),
            (
                "B_ANTIC_CYC",
                AnticipationSide::Tail,
                AnticipationPhase::Cycle,
            ),
            (
                "B_N_ANTIC_CYC",
                AnticipationSide::Nose,
                AnticipationPhase::Cycle,
            ),
            (
                "B_ANTIC_OUT",
                AnticipationSide::Tail,
                AnticipationPhase::Out,
            ),
            (
                "B_N_ANTIC_OUT",
                AnticipationSide::Nose,
                AnticipationPhase::Out,
            ),
        ];

        for (resource, side, phase) in resources {
            for strength in [AnticipationStrength::Normal, AnticipationStrength::High] {
                for (direction, expected_weights) in [
                    (-1.0, [1.0, 0.0, 0.0]),
                    (-0.25, [0.25, 0.75, 0.0]),
                    (0.0, [0.0, 1.0, 0.0]),
                    (0.25, [0.0, 0.75, 0.25]),
                    (1.0, [0.0, 0.0, 1.0]),
                ] {
                    let adapted = adapt(
                        resource,
                        AnticipationParameters {
                            strength,
                            direction,
                        }
                        .into(),
                    )
                    .unwrap();
                    assert_eq!(adapted.samples.len(), 3);
                    assert_eq!(
                        adapted
                            .samples
                            .iter()
                            .map(|sample| sample.weight)
                            .collect::<Vec<_>>(),
                        expected_weights
                    );
                    for (sample, coordinate) in adapted.samples.iter().zip([
                        DirectionCoordinate::Left,
                        DirectionCoordinate::Neutral,
                        DirectionCoordinate::Right,
                    ]) {
                        assert_eq!(
                            sample.clip.leaf,
                            PhysicalLeaf::Anticipation(crate::trick_catalog::AnticipationLeaf {
                                side,
                                strength,
                                phase,
                                direction: coordinate,
                            })
                        );
                        assert_eq!(sample.seek_time_seconds, SEEK);
                        assert_eq!(sample.source.resource, resource);
                    }
                    assert_normalized(&adapted);
                }
            }
        }
    }

    #[test]
    fn all_six_straight_landing_leaves_resolve_only_with_typed_parameters() {
        let cases = [
            (
                LandingPosture::Aggressive,
                LandingVariant::One,
                "L_LAND_HIGH_AGGR_1_N",
            ),
            (
                LandingPosture::Aggressive,
                LandingVariant::Two,
                "L_LAND_HIGH_AGGR_2_N",
            ),
            (
                LandingPosture::Aggressive,
                LandingVariant::Three,
                "L_LAND_HIGH_AGGR_3_N",
            ),
            (
                LandingPosture::Loose,
                LandingVariant::One,
                "L_LAND_HIGH_LOOSE_1_N",
            ),
            (
                LandingPosture::Loose,
                LandingVariant::Two,
                "L_LAND_HIGH_LOOSE_2_N",
            ),
            (
                LandingPosture::Loose,
                LandingVariant::Three,
                "L_LAND_HIGH_LOOSE_3_N",
            ),
        ];

        for (posture, variant, expected_name) in cases {
            let adapted = adapt(
                "BLEND_LAND",
                StraightLandingParameters { posture, variant }.into(),
            )
            .unwrap();
            assert_eq!(adapted.samples.len(), 1);
            assert_eq!(adapted.samples[0].clip_name(), expected_name);
            assert_eq!(adapted.samples[0].seek_time_seconds, SEEK);
            assert_eq!(adapted.transition_seconds, 0.15);
            assert!(!adapted.repeats);
            assert_normalized(&adapted);
        }
    }

    #[test]
    fn unresolved_resources_and_parameter_failures_remain_classified() {
        let failures = [
            (
                adapt("NOT_A_RETAIL_RESOURCE", TrickAnimationParameters::None).unwrap_err(),
                AdapterUnresolvedReason::UnknownResource,
            ),
            (
                adapt(
                    "OLLIE_LOW_G",
                    AnticipationParameters {
                        strength: AnticipationStrength::Normal,
                        direction: 0.0,
                    }
                    .into(),
                )
                .unwrap_err(),
                AdapterUnresolvedReason::UnexpectedParametersForPhysicalResource,
            ),
            (
                adapt("B_ANTIC_CYC", TrickAnimationParameters::None).unwrap_err(),
                AdapterUnresolvedReason::Virtual {
                    resource: VirtualResource::AnticCycleTail,
                    reason: UnresolvedReason::AnticipationParametersRequired,
                },
            ),
            (
                adapt(
                    "B_ANTIC_CYC",
                    AnticipationParameters {
                        strength: AnticipationStrength::Normal,
                        direction: f32::NAN,
                    }
                    .into(),
                )
                .unwrap_err(),
                AdapterUnresolvedReason::Virtual {
                    resource: VirtualResource::AnticCycleTail,
                    reason: UnresolvedReason::InvalidDirectionCoordinate,
                },
            ),
            (
                adapt("BLEND_LAND", TrickAnimationParameters::None).unwrap_err(),
                AdapterUnresolvedReason::Virtual {
                    resource: VirtualResource::StraightLanding,
                    reason: UnresolvedReason::StraightLandingParametersRequired,
                },
            ),
            (
                adapt("B_LAND_NICE", TrickAnimationParameters::None).unwrap_err(),
                AdapterUnresolvedReason::Virtual {
                    resource: VirtualResource::NiceLanding,
                    reason: UnresolvedReason::NoPhysicalMappingInEvidence,
                },
            ),
            (
                adapt("B_LAND_SKETCH", TrickAnimationParameters::None).unwrap_err(),
                AdapterUnresolvedReason::Virtual {
                    resource: VirtualResource::SketchLanding,
                    reason: UnresolvedReason::NoPhysicalMappingInEvidence,
                },
            ),
            (
                adapt(
                    "B_AIR_CYC",
                    StraightLandingParameters {
                        posture: LandingPosture::Loose,
                        variant: LandingVariant::One,
                    }
                    .into(),
                )
                .unwrap_err(),
                AdapterUnresolvedReason::Virtual {
                    resource: VirtualResource::AirCycle,
                    reason: UnresolvedReason::UnexpectedParameters,
                },
            ),
            (
                adapt("B_ANTIC_360SHUVIT_CYC", TrickAnimationParameters::None).unwrap_err(),
                AdapterUnresolvedReason::Virtual {
                    resource: VirtualResource::Antic360ShuvitCycle,
                    reason: UnresolvedReason::AnticipationParametersRequired,
                },
            ),
        ];

        for (failure, expected_reason) in failures {
            assert_eq!(failure.reason, expected_reason);
            assert!(!failure.source_resource.is_empty());
        }
    }

    #[test]
    fn every_successful_sample_name_is_physical_and_weights_total_one() {
        let mut successes = Vec::new();
        for resource in [
            "OLLIE_LOW_G",
            "OLLIE_LOW_A",
            "OLLIE_HIGH_G",
            "OLLIE_HIGH_A",
            "NOLLIE_LOW_G",
            "NOLLIE_LOW_A",
            "NOLLIE_HIGH_G",
            "NOLLIE_HIGH_A",
            "B_AIR_CYC",
        ] {
            successes.push(adapt(resource, TrickAnimationParameters::None).unwrap());
        }
        for resource in [
            "B_ANTIC_INTO",
            "B_N_ANTIC_INTO",
            "B_ANTIC_CYC",
            "B_N_ANTIC_CYC",
            "B_ANTIC_OUT",
            "B_N_ANTIC_OUT",
            "B_ANTIC_360SHUVIT_CYC",
            "B_ANTIC_FS360SHUVIT_CYC",
            "B_ANTIC_N360SHUVIT_CYC",
            "B_ANTIC_NFS360SHUVIT_CYC",
        ] {
            successes.push(
                adapt(
                    resource,
                    AnticipationParameters {
                        strength: AnticipationStrength::High,
                        direction: 0.37,
                    }
                    .into(),
                )
                .unwrap(),
            );
        }
        for posture in [LandingPosture::Aggressive, LandingPosture::Loose] {
            for variant in [
                LandingVariant::One,
                LandingVariant::Two,
                LandingVariant::Three,
            ] {
                successes.push(
                    adapt(
                        "BLEND_LAND",
                        StraightLandingParameters { posture, variant }.into(),
                    )
                    .unwrap(),
                );
            }
        }

        for adapted in successes {
            assert_normalized(&adapted);
            for sample in adapted.samples {
                assert!(
                    virtual_resource_by_name(sample.clip.name).is_none(),
                    "virtual resource leaked as a physical clip: {}",
                    sample.clip.name
                );
                assert!(matches!(
                    classify_resource(sample.clip.name),
                    ResourceClass::Physical(found) if found == sample.clip
                ));
            }
        }
    }

    #[test]
    fn all_current_missing_virtual_mappings_fail_instead_of_selecting_a_clip() {
        for resource in VIRTUAL_RESOURCES {
            let parameters = match resource {
                VirtualResource::AnticIntoTail
                | VirtualResource::AnticIntoNose
                | VirtualResource::AnticCycleTail
                | VirtualResource::AnticCycleNose
                | VirtualResource::AnticOutTail
                | VirtualResource::AnticOutNose
                | VirtualResource::Antic360ShuvitCycle
                | VirtualResource::AnticFs360ShuvitCycle
                | VirtualResource::AnticNose360ShuvitCycle
                | VirtualResource::AnticNoseFs360ShuvitCycle => {
                    TrickAnimationParameters::Anticipation(AnticipationParameters {
                        strength: AnticipationStrength::Normal,
                        direction: 0.0,
                    })
                }
                VirtualResource::StraightLanding => {
                    TrickAnimationParameters::StraightLanding(StraightLandingParameters {
                        posture: LandingPosture::Aggressive,
                        variant: LandingVariant::One,
                    })
                }
                _ => TrickAnimationParameters::None,
            };
            let result = adapt(resource.name(), parameters);
            match resource {
                VirtualResource::NiceLanding | VirtualResource::SketchLanding => {
                    assert_eq!(
                        result.unwrap_err().reason,
                        AdapterUnresolvedReason::Virtual {
                            resource,
                            reason: UnresolvedReason::NoPhysicalMappingInEvidence,
                        }
                    );
                }
                _ => assert!(result.is_ok(), "{} should resolve", resource.name()),
            }
        }
    }
}
