//! Evidence-gated adapter from TU3 air-trick graph requests to physical ABIN leaves.
//!
//! `air_trick_graph` emits retail MotionGraph resource names. Most are virtual
//! blend trees, not clips. This module resolves only physical leaves whose tree
//! membership and endpoint are supported by local runtime evidence. Unknown,
//! unresolved, continuously blended, and currently unexported resources fail
//! explicitly instead of selecting a similarly named animation.
#![allow(dead_code)]

use crate::air_trick_graph::{AnimationRequest, AnimationTransition, TrickHeight};

pub const ONBOARD_ABIN_SHA256: &str =
    "30AA324D6D7C51C325D53E9268C1AD91783B0154D21BBEF5DC5A61EAE8333BD7";
pub const ONBOARD_CATALOG_SHA256: &str =
    "7B2041D3E8FC305D589A05B65B72B5181319197B4CF4FC6C410C8BDDAA131D10";
pub const MOTION_GRAPH_ONBOARD_SHA256: &str =
    "484189731E7651539E532056662835C5492D11EC3BF56668E1B589E013AAA68D";
pub const AIR_TRICK_GRAPH_SHA256: &str =
    "265A627AD152F8EE6AEF68CB491D109AAC8ED34FC3B44733DB08A6832BA9CBCE";
pub const CURRENT_BEVY_MANIFEST_SHA256: &str =
    "6891B82FBB12020B14B1EAECC3E3BF6CE6B0CFF2159AC5D66BFEABC8A68D310D";
pub const CURRENT_BEVY_GLB_SHA256: &str =
    "961E23D9F96D273C141BB06AF3E7CFE6D812B42F86C90CA4BB06311817A50378";
pub const FLIP360_FIXTURE_SHA256: &str =
    "F5C4BD956AB69BD77FE8ADA6E3EEFB7F0DC1733C175A0A79AF288E543A407BC3";
pub const FLIP360_RESULT_SHA256: &str =
    "A02795128054B6638587B7F3AA8152B598B67A352FCEF9C370724D7F1ED71A78";
pub const FLIP360_TELEMETRY_SHA256: &str =
    "1AB0E3D0CCD8B0B5F91E2A11041D5FD75F5E8F8D9CDD96D0257589D7C0748660";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PhysicalAirTrickLeafKind {
    GrindOutNose,
    GrindOutTail,
    KickflipInLowGround,
    KickflipInLowAir,
    Flip360LowGround,
    Flip360LowAir,
    Flip360HighGround,
    Flip360HighAir,
}

/// A physical leaf with exact metadata observed in the pinned TU3 OnBoard ABIN
/// catalog. Inclusion here also means the virtual-to-physical relationship is
/// proven to the evidence level described in `AIR_TRICK_ANIMATION_SPEC.md`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PhysicalAirTrickLeaf {
    pub kind: PhysicalAirTrickLeafKind,
    pub name: &'static str,
    pub catalog_index: u16,
    pub codec: &'static str,
    pub native_fps: u16,
    pub frame_count: u16,
    pub part_count: u8,
    pub block_offset: u32,
    pub block_size: u32,
    /// Whether this exact action exists in the pinned Bevy GLB manifest.
    pub exported_in_current_bevy_asset: bool,
}

impl PhysicalAirTrickLeaf {
    /// Duration between the first and final authored samples.
    pub fn authored_duration_seconds(self) -> f32 {
        self.frame_count.saturating_sub(1) as f32 / self.native_fps as f32
    }
}

const fn leaf(
    kind: PhysicalAirTrickLeafKind,
    name: &'static str,
    catalog_index: u16,
    frame_count: u16,
    block_offset: u32,
    block_size: u32,
) -> PhysicalAirTrickLeaf {
    PhysicalAirTrickLeaf {
        kind,
        name,
        catalog_index,
        codec: "VBR",
        native_fps: 60,
        frame_count,
        part_count: 8,
        block_offset,
        block_size,
        // Wave 3 exports this complete runtime-verified catalog into the
        // pinned 251-action Bevy asset.
        exported_in_current_bevy_asset: true,
    }
}

/// Physical leaves for which both ABIN identity and use by an emitted graph
/// resource have evidence. Ordered by ABIN catalog index.
pub const PROVEN_PHYSICAL_AIR_TRICK_CATALOG: [PhysicalAirTrickLeaf; 8] = [
    leaf(
        PhysicalAirTrickLeafKind::GrindOutNose,
        "GRIND_OUT_NOSE",
        2168,
        13,
        8_921_840,
        2_896,
    ),
    leaf(
        PhysicalAirTrickLeafKind::GrindOutTail,
        "GRIND_OUT_TAIL",
        2169,
        11,
        8_924_736,
        2_864,
    ),
    leaf(
        PhysicalAirTrickLeafKind::KickflipInLowGround,
        "KICKFLIP_IN_LOW_G",
        2400,
        13,
        9_790_640,
        3_104,
    ),
    leaf(
        PhysicalAirTrickLeafKind::KickflipInLowAir,
        "KICKFLIP_IN_LOW_A",
        2401,
        11,
        9_793_744,
        3_312,
    ),
    leaf(
        PhysicalAirTrickLeafKind::Flip360LowGround,
        "360FLIP_D_LOW_G",
        2448,
        13,
        9_961_744,
        3_088,
    ),
    leaf(
        PhysicalAirTrickLeafKind::Flip360LowAir,
        "360FLIP_D_LOW_A",
        2449,
        28,
        9_964_832,
        4_288,
    ),
    leaf(
        PhysicalAirTrickLeafKind::Flip360HighGround,
        "360FLIP_D_HIGH_G",
        2450,
        13,
        9_969_120,
        3_088,
    ),
    leaf(
        PhysicalAirTrickLeafKind::Flip360HighAir,
        "360FLIP_D_HIGH_A",
        2451,
        33,
        9_972_208,
        4_448,
    ),
];

const GRIND_OUT_NOSE: &PhysicalAirTrickLeaf = &PROVEN_PHYSICAL_AIR_TRICK_CATALOG[0];
const GRIND_OUT_TAIL: &PhysicalAirTrickLeaf = &PROVEN_PHYSICAL_AIR_TRICK_CATALOG[1];
const KICKFLIP_IN_LOW_G: &PhysicalAirTrickLeaf = &PROVEN_PHYSICAL_AIR_TRICK_CATALOG[2];
const KICKFLIP_IN_LOW_A: &PhysicalAirTrickLeaf = &PROVEN_PHYSICAL_AIR_TRICK_CATALOG[3];
const FLIP360_LOW_G: &PhysicalAirTrickLeaf = &PROVEN_PHYSICAL_AIR_TRICK_CATALOG[4];
const FLIP360_LOW_A: &PhysicalAirTrickLeaf = &PROVEN_PHYSICAL_AIR_TRICK_CATALOG[5];
const FLIP360_HIGH_G: &PhysicalAirTrickLeaf = &PROVEN_PHYSICAL_AIR_TRICK_CATALOG[6];
const FLIP360_HIGH_A: &PhysicalAirTrickLeaf = &PROVEN_PHYSICAL_AIR_TRICK_CATALOG[7];

/// Exact unique resource-name surface emitted by `air_trick_graph`.
pub const AIR_TRICK_GRAPH_RESOURCES: [&str; 86] = [
    "GRIND_OUT_NOSE",
    "GRIND_OUT_TAIL",
    "B_KICKFLIP_IN_G",
    "B_KICKFLIP_IN_A",
    "B_HEELFLIP_IN_G",
    "B_HEELFLIP_IN_A",
    "B_POPSHUVIT_G",
    "B_POPSHUVIT_A",
    "B_FSPOPSHUVIT_G",
    "B_FSPOPSHUVIT_A",
    "B_VARIALKICKFLIP_G",
    "B_VARIALKICKFLIP_A",
    "B_VARIALHEELFLIP_G",
    "B_VARIALHEELFLIP_A",
    "B_HARDFLIP_G",
    "B_HARDFLIP_A",
    "B_INWARDHEELFLIP_G",
    "B_INWARDHEELFLIP_A",
    "B_360POPSHUVIT_G",
    "B_360POPSHUVIT_A",
    "B_FS360POPSHUVIT_G",
    "B_FS360POPSHUVIT_A",
    "B_360FLIP_G",
    "B_360FLIP_A",
    "B_LASERFLIP_G",
    "B_LASERFLIP_A",
    "B_360HARDFLIP_G",
    "B_360HARDFLIP_A",
    "B_360INWARDHEELFLIP_G",
    "B_360INWARDHEELFLIP_A",
    "B_N_KICKFLIP_IN_G",
    "B_N_KICKFLIP_IN_A",
    "B_N_HEELFLIP_IN_G",
    "B_N_HEELFLIP_IN_A",
    "B_N_POPSHUVIT_G",
    "B_N_POPSHUVIT_A",
    "B_N_FSPOPSHUVIT_G",
    "B_N_FSPOPSHUVIT_A",
    "B_N_VARIALKICKFLIP_G",
    "B_N_VARIALKICKFLIP_A",
    "B_N_VARIALHEELFLIP_G",
    "B_N_VARIALHEELFLIP_A",
    "B_N_HARDFLIP_G",
    "B_N_HARDFLIP_A",
    "B_N_INWARDHEELFLIP_G",
    "B_N_INWARDHEELFLIP_A",
    "B_N_360POPSHUVIT_G",
    "B_N_360POPSHUVIT_A",
    "B_N_FS360POPSHUVIT_G",
    "B_N_FS360POPSHUVIT_A",
    "B_N_360FLIP_G",
    "B_N_360FLIP_A",
    "B_N_LASERFLIP_G",
    "B_N_LASERFLIP_A",
    "B_N_360HARDFLIP_G",
    "B_N_360HARDFLIP_A",
    "B_N_360INWARDHEELFLIP_G",
    "B_N_360INWARDHEELFLIP_A",
    "B_KICKFLIP_CYC1",
    "B_KICKFLIP_CYC2",
    "B_KICKFLIP_CYC3",
    "B_HEELFLIP_CYC1",
    "B_HEELFLIP_CYC2",
    "B_HEELFLIP_CYC3",
    "B_N_KICKFLIP_CYC1",
    "B_N_KICKFLIP_CYC2",
    "B_N_KICKFLIP_CYC3",
    "B_N_HEELFLIP_CYC1",
    "B_N_HEELFLIP_CYC2",
    "B_N_HEELFLIP_CYC3",
    "B_KICKFLIP_OUT1",
    "B_KICKFLIP_OUT2",
    "B_KICKFLIP_OUT3",
    "B_KICKFLIP_OUT4",
    "B_HEELFLIP_OUT1",
    "B_HEELFLIP_OUT2",
    "B_HEELFLIP_OUT3",
    "B_HEELFLIP_OUT4",
    "B_N_KICKFLIP_OUT1",
    "B_N_KICKFLIP_OUT2",
    "B_N_KICKFLIP_OUT3",
    "B_N_KICKFLIP_OUT4",
    "B_N_HEELFLIP_OUT1",
    "B_N_HEELFLIP_OUT2",
    "B_N_HEELFLIP_OUT3",
    "B_N_HEELFLIP_OUT4",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MissingAirTrickEvidence {
    /// The virtual resource exists, but selected-leaf telemetry or recovered
    /// blend-tree topology does not prove its physical children.
    PhysicalLeafTopology,
    /// Multiple authored ABIN families plausibly match this virtual resource
    /// (for example D/CARR or D/DILL), and the retail selector is unobserved.
    AuthoredVariantSelector,
    /// Cycle/out candidates exist, but their low/high virtual tree membership
    /// has not been observed.
    FlipLoopLeafTopology,
    /// One endpoint is observed, but this requested endpoint is not.
    EndpointLeafSelection,
    /// Physical low/high children are known, but the exact SetBlend curve and
    /// weights for an interior TrickHeight are not.
    ContinuousBlendCurveAndWeights,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AirTrickResourceClass {
    DirectPhysical(&'static PhysicalAirTrickLeaf),
    ProvenLowEndpoint {
        low: &'static PhysicalAirTrickLeaf,
    },
    ProvenTwoEndpointBlend {
        low: &'static PhysicalAirTrickLeaf,
        high: &'static PhysicalAirTrickLeaf,
    },
    UnresolvedVirtual(MissingAirTrickEvidence),
    Unknown,
}

/// Classify an emitted resource without guessing from ABIN naming similarity.
pub fn classify_air_trick_resource(resource: &str) -> AirTrickResourceClass {
    match resource {
        "GRIND_OUT_NOSE" => AirTrickResourceClass::DirectPhysical(GRIND_OUT_NOSE),
        "GRIND_OUT_TAIL" => AirTrickResourceClass::DirectPhysical(GRIND_OUT_TAIL),
        "B_KICKFLIP_IN_G" => AirTrickResourceClass::ProvenLowEndpoint {
            low: KICKFLIP_IN_LOW_G,
        },
        "B_KICKFLIP_IN_A" => AirTrickResourceClass::ProvenLowEndpoint {
            low: KICKFLIP_IN_LOW_A,
        },
        "B_360FLIP_G" => AirTrickResourceClass::ProvenTwoEndpointBlend {
            low: FLIP360_LOW_G,
            high: FLIP360_HIGH_G,
        },
        "B_360FLIP_A" => AirTrickResourceClass::ProvenTwoEndpointBlend {
            low: FLIP360_LOW_A,
            high: FLIP360_HIGH_A,
        },
        resource if !AIR_TRICK_GRAPH_RESOURCES.contains(&resource) => {
            AirTrickResourceClass::Unknown
        }
        resource if is_flip_loop_resource(resource) => {
            AirTrickResourceClass::UnresolvedVirtual(MissingAirTrickEvidence::FlipLoopLeafTopology)
        }
        resource if has_ambiguous_authored_variant(resource) => {
            AirTrickResourceClass::UnresolvedVirtual(
                MissingAirTrickEvidence::AuthoredVariantSelector,
            )
        }
        _ => {
            AirTrickResourceClass::UnresolvedVirtual(MissingAirTrickEvidence::PhysicalLeafTopology)
        }
    }
}

fn is_flip_loop_resource(resource: &str) -> bool {
    resource.contains("_CYC") || resource.contains("_OUT")
}

fn has_ambiguous_authored_variant(resource: &str) -> bool {
    resource.starts_with("B_FSPOPSHUVIT_")
        || resource.starts_with("B_VARIALHEELFLIP_")
        || resource.starts_with("B_360FLIP_")
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AirTrickAnimationAdapterRequest {
    pub graph: AnimationRequest,
    /// Graph-owned local animation time. The adapter does not advance a second
    /// clock or infer segment synchronization.
    pub local_time_seconds: f32,
    pub playback_speed: f32,
    pub repeats: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResolvedAirTrickSample {
    pub clip: &'static PhysicalAirTrickLeaf,
    /// Endpoint resolutions are exact unit-weight samples. Interior blend
    /// weights are never manufactured by this module.
    pub weight: f32,
    pub seek_time_seconds: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ResolvedAbinAirTrickAnimation {
    pub source_resource: String,
    pub sample: ResolvedAirTrickSample,
    pub transition: AnimationTransition,
    pub transition_under: bool,
    pub playback_speed: f32,
    pub repeats: bool,
}

/// A plan safe to hand to Bevy: its sample is physical and present in the
/// pinned GLB manifest. Construction is deliberately private.
#[derive(Clone, Debug, PartialEq)]
pub struct BevyAirTrickAnimation {
    resolved: ResolvedAbinAirTrickAnimation,
}

impl BevyAirTrickAnimation {
    pub fn resolved(&self) -> &ResolvedAbinAirTrickAnimation {
        &self.resolved
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InvalidAirTrickTimingField {
    LocalTime,
    PlaybackSpeed,
    TransitionSeconds,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AirTrickAnimationFailureReason {
    UnknownGraphResource,
    InvalidTiming(InvalidAirTrickTimingField),
    InvalidContinuousTrickHeight,
    MissingEvidence(MissingAirTrickEvidence),
    PhysicalLeafNotExported {
        leaf: &'static PhysicalAirTrickLeaf,
        manifest_sha256: &'static str,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AirTrickAnimationFailure {
    pub source_resource: String,
    pub reason: AirTrickAnimationFailureReason,
}

/// Resolve only evidence-backed physical endpoints. A successful result cannot
/// contain a virtual `B_*` name as its playable sample.
pub fn resolve_air_trick_request(
    request: AirTrickAnimationAdapterRequest,
) -> Result<ResolvedAbinAirTrickAnimation, AirTrickAnimationFailure> {
    let resource = request.graph.virtual_resource_name();
    validate_request_timing(&resource, request)?;

    let clip = match classify_air_trick_resource(&resource) {
        AirTrickResourceClass::DirectPhysical(clip) => clip,
        AirTrickResourceClass::ProvenLowEndpoint { low } => match request.graph.height {
            TrickHeight::LowEndpoint => low,
            TrickHeight::HighEndpoint => {
                return Err(failure(
                    resource,
                    AirTrickAnimationFailureReason::MissingEvidence(
                        MissingAirTrickEvidence::EndpointLeafSelection,
                    ),
                ));
            }
            TrickHeight::ContinuousUnresolved(value) => {
                return continuous_blend_failure(resource, value);
            }
        },
        AirTrickResourceClass::ProvenTwoEndpointBlend { low, high } => match request.graph.height {
            TrickHeight::LowEndpoint => low,
            TrickHeight::HighEndpoint => high,
            TrickHeight::ContinuousUnresolved(value) => {
                return continuous_blend_failure(resource, value);
            }
        },
        AirTrickResourceClass::UnresolvedVirtual(reason) => {
            return Err(failure(
                resource,
                AirTrickAnimationFailureReason::MissingEvidence(reason),
            ));
        }
        AirTrickResourceClass::Unknown => {
            return Err(failure(
                resource,
                AirTrickAnimationFailureReason::UnknownGraphResource,
            ));
        }
    };

    Ok(ResolvedAbinAirTrickAnimation {
        source_resource: resource,
        sample: ResolvedAirTrickSample {
            clip,
            weight: 1.0,
            seek_time_seconds: request.local_time_seconds,
        },
        transition: request.graph.transition,
        transition_under: request.graph.transition_under,
        playback_speed: request.playback_speed,
        repeats: request.repeats,
    })
}

/// Resolve and enforce availability in the current Bevy animation asset.
pub fn adapt_air_trick_for_bevy(
    request: AirTrickAnimationAdapterRequest,
) -> Result<BevyAirTrickAnimation, AirTrickAnimationFailure> {
    let resolved = resolve_air_trick_request(request)?;
    if !resolved.sample.clip.exported_in_current_bevy_asset {
        return Err(failure(
            resolved.source_resource,
            AirTrickAnimationFailureReason::PhysicalLeafNotExported {
                leaf: resolved.sample.clip,
                manifest_sha256: CURRENT_BEVY_MANIFEST_SHA256,
            },
        ));
    }
    Ok(BevyAirTrickAnimation { resolved })
}

fn validate_request_timing(
    resource: &str,
    request: AirTrickAnimationAdapterRequest,
) -> Result<(), AirTrickAnimationFailure> {
    let invalid = if !request.local_time_seconds.is_finite() || request.local_time_seconds < 0.0 {
        Some(InvalidAirTrickTimingField::LocalTime)
    } else if !request.playback_speed.is_finite() || request.playback_speed <= 0.0 {
        Some(InvalidAirTrickTimingField::PlaybackSpeed)
    } else {
        transition_seconds(request.graph.transition)
            .filter(|seconds| !seconds.is_finite() || *seconds < 0.0)
            .map(|_| InvalidAirTrickTimingField::TransitionSeconds)
    };

    match invalid {
        Some(field) => Err(failure(
            resource.to_owned(),
            AirTrickAnimationFailureReason::InvalidTiming(field),
        )),
        None => Ok(()),
    }
}

fn transition_seconds(transition: AnimationTransition) -> Option<f32> {
    match transition {
        AnimationTransition::Play { seconds }
        | AnimationTransition::Blend { seconds }
        | AnimationTransition::ChannelBlend { seconds } => Some(seconds),
        AnimationTransition::Sequence => None,
    }
}

fn continuous_blend_failure(
    resource: String,
    value: f32,
) -> Result<ResolvedAbinAirTrickAnimation, AirTrickAnimationFailure> {
    let reason = if value.is_finite() {
        AirTrickAnimationFailureReason::MissingEvidence(
            MissingAirTrickEvidence::ContinuousBlendCurveAndWeights,
        )
    } else {
        AirTrickAnimationFailureReason::InvalidContinuousTrickHeight
    };
    Err(failure(resource, reason))
}

fn failure(
    source_resource: String,
    reason: AirTrickAnimationFailureReason,
) -> AirTrickAnimationFailure {
    AirTrickAnimationFailure {
        source_resource,
        reason,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::air_trick_graph::{ClipSegment, TrickHeight};
    use std::collections::HashSet;

    fn graph_request(
        virtual_base: &'static str,
        segment: ClipSegment,
        height: TrickHeight,
        transition: AnimationTransition,
        transition_under: bool,
    ) -> AnimationRequest {
        AnimationRequest {
            virtual_base,
            segment,
            height,
            transition,
            transition_under,
        }
    }

    fn adapter_request(graph: AnimationRequest) -> AirTrickAnimationAdapterRequest {
        AirTrickAnimationAdapterRequest {
            graph,
            local_time_seconds: 7.0 / 60.0,
            playback_speed: 1.0,
            repeats: false,
        }
    }

    fn graph_request_for_resource(resource: &str) -> AnimationRequest {
        let (base, segment) = if let Some(base) = resource.strip_suffix("_G") {
            (base, ClipSegment::Ground)
        } else if let Some(base) = resource.strip_suffix("_A") {
            (base, ClipSegment::Air)
        } else if let Some(base) = resource.strip_suffix("_CYC1") {
            (base, ClipSegment::FlipCycle(1))
        } else if let Some(base) = resource.strip_suffix("_CYC2") {
            (base, ClipSegment::FlipCycle(2))
        } else if let Some(base) = resource.strip_suffix("_CYC3") {
            (base, ClipSegment::FlipCycle(3))
        } else if let Some(base) = resource.strip_suffix("_OUT1") {
            (base, ClipSegment::FlipOut(1))
        } else if let Some(base) = resource.strip_suffix("_OUT2") {
            (base, ClipSegment::FlipOut(2))
        } else if let Some(base) = resource.strip_suffix("_OUT3") {
            (base, ClipSegment::FlipOut(3))
        } else if let Some(base) = resource.strip_suffix("_OUT4") {
            (base, ClipSegment::FlipOut(4))
        } else {
            (resource, ClipSegment::GrindOut)
        };
        graph_request(
            Box::leak(base.to_owned().into_boxed_str()),
            segment,
            TrickHeight::LowEndpoint,
            AnimationTransition::Sequence,
            true,
        )
    }

    #[test]
    fn every_emitted_resource_is_unique_and_classified() {
        assert_eq!(AIR_TRICK_GRAPH_RESOURCES.len(), 86);
        let unique = AIR_TRICK_GRAPH_RESOURCES
            .iter()
            .copied()
            .collect::<HashSet<_>>();
        assert_eq!(unique.len(), AIR_TRICK_GRAPH_RESOURCES.len());
        for resource in AIR_TRICK_GRAPH_RESOURCES {
            assert_ne!(
                classify_air_trick_resource(resource),
                AirTrickResourceClass::Unknown,
                "unclassified graph resource: {resource}"
            );
        }
    }

    #[test]
    fn proven_catalog_has_exact_order_and_timing() {
        assert!(
            PROVEN_PHYSICAL_AIR_TRICK_CATALOG
                .windows(2)
                .all(|pair| pair[0].catalog_index < pair[1].catalog_index)
        );
        let names = PROVEN_PHYSICAL_AIR_TRICK_CATALOG
            .iter()
            .map(|leaf| leaf.name)
            .collect::<HashSet<_>>();
        assert_eq!(names.len(), PROVEN_PHYSICAL_AIR_TRICK_CATALOG.len());
        assert_eq!(GRIND_OUT_NOSE.authored_duration_seconds(), 12.0 / 60.0);
        assert_eq!(GRIND_OUT_TAIL.authored_duration_seconds(), 10.0 / 60.0);
        assert_eq!(FLIP360_HIGH_A.authored_duration_seconds(), 32.0 / 60.0);
    }

    #[test]
    fn direct_grind_out_preserves_graph_transition() {
        let request = adapter_request(graph_request(
            "GRIND_OUT_TAIL",
            ClipSegment::GrindOut,
            TrickHeight::ContinuousUnresolved(1.0),
            AnimationTransition::ChannelBlend { seconds: 0.75 },
            false,
        ));
        let resolved = resolve_air_trick_request(request).unwrap();
        assert_eq!(resolved.sample.clip, GRIND_OUT_TAIL);
        assert_eq!(resolved.sample.weight, 1.0);
        assert_eq!(resolved.sample.seek_time_seconds, 7.0 / 60.0);
        assert_eq!(
            resolved.transition,
            AnimationTransition::ChannelBlend { seconds: 0.75 }
        );
        assert!(!resolved.transition_under);
    }

    #[test]
    fn flip360_exact_endpoints_resolve_without_invented_blend_weights() {
        let cases = [
            (ClipSegment::Ground, TrickHeight::LowEndpoint, FLIP360_LOW_G),
            (
                ClipSegment::Ground,
                TrickHeight::HighEndpoint,
                FLIP360_HIGH_G,
            ),
            (ClipSegment::Air, TrickHeight::LowEndpoint, FLIP360_LOW_A),
            (ClipSegment::Air, TrickHeight::HighEndpoint, FLIP360_HIGH_A),
        ];
        for (segment, height, expected) in cases {
            let resolved = resolve_air_trick_request(adapter_request(graph_request(
                "B_360FLIP",
                segment,
                height,
                AnimationTransition::Sequence,
                true,
            )))
            .unwrap();
            assert_eq!(resolved.sample.clip, expected);
            assert_eq!(resolved.sample.weight, 1.0);
        }
    }

    #[test]
    fn continuous_flip360_height_is_an_explicit_error() {
        let error = resolve_air_trick_request(adapter_request(graph_request(
            "B_360FLIP",
            ClipSegment::Air,
            TrickHeight::ContinuousUnresolved(0.5),
            AnimationTransition::Sequence,
            true,
        )))
        .unwrap_err();
        assert_eq!(
            error.reason,
            AirTrickAnimationFailureReason::MissingEvidence(
                MissingAirTrickEvidence::ContinuousBlendCurveAndWeights
            )
        );
    }

    #[test]
    fn kickflip_only_resolves_the_observed_low_endpoint() {
        let low = resolve_air_trick_request(adapter_request(graph_request(
            "B_KICKFLIP_IN",
            ClipSegment::Ground,
            TrickHeight::LowEndpoint,
            AnimationTransition::Play { seconds: 0.05 },
            false,
        )))
        .unwrap();
        assert_eq!(low.sample.clip, KICKFLIP_IN_LOW_G);

        let high = resolve_air_trick_request(adapter_request(graph_request(
            "B_KICKFLIP_IN",
            ClipSegment::Ground,
            TrickHeight::HighEndpoint,
            AnimationTransition::Play { seconds: 0.05 },
            false,
        )))
        .unwrap_err();
        assert_eq!(
            high.reason,
            AirTrickAnimationFailureReason::MissingEvidence(
                MissingAirTrickEvidence::EndpointLeafSelection
            )
        );
    }

    #[test]
    fn every_other_virtual_resource_fails_instead_of_substituting() {
        for resource in AIR_TRICK_GRAPH_RESOURCES {
            if matches!(
                classify_air_trick_resource(resource),
                AirTrickResourceClass::UnresolvedVirtual(_)
            ) {
                let graph = graph_request_for_resource(resource);
                assert_eq!(graph.virtual_resource_name(), resource);
                let error = resolve_air_trick_request(adapter_request(graph)).unwrap_err();
                assert!(matches!(
                    error.reason,
                    AirTrickAnimationFailureReason::MissingEvidence(_)
                ));
            }
        }
    }

    #[test]
    fn current_bevy_asset_accepts_every_resolvable_physical_leaf() {
        assert!(
            PROVEN_PHYSICAL_AIR_TRICK_CATALOG
                .iter()
                .all(|leaf| leaf.exported_in_current_bevy_asset)
        );
        let cases = [
            graph_request(
                "GRIND_OUT_NOSE",
                ClipSegment::GrindOut,
                TrickHeight::LowEndpoint,
                AnimationTransition::ChannelBlend { seconds: 0.75 },
                false,
            ),
            graph_request(
                "B_KICKFLIP_IN",
                ClipSegment::Air,
                TrickHeight::LowEndpoint,
                AnimationTransition::Sequence,
                true,
            ),
            graph_request(
                "B_360FLIP",
                ClipSegment::Air,
                TrickHeight::HighEndpoint,
                AnimationTransition::Sequence,
                true,
            ),
        ];
        for graph in cases {
            let adapted = adapt_air_trick_for_bevy(adapter_request(graph)).unwrap();
            assert!(
                adapted
                    .resolved()
                    .sample
                    .clip
                    .exported_in_current_bevy_asset
            );
        }
    }

    #[test]
    fn invalid_timing_fails_before_resource_resolution() {
        let mut request = adapter_request(graph_request(
            "B_DOES_NOT_EXIST",
            ClipSegment::Ground,
            TrickHeight::LowEndpoint,
            AnimationTransition::Play { seconds: 0.05 },
            false,
        ));
        request.local_time_seconds = f32::NAN;
        assert_eq!(
            resolve_air_trick_request(request).unwrap_err().reason,
            AirTrickAnimationFailureReason::InvalidTiming(InvalidAirTrickTimingField::LocalTime)
        );

        request.local_time_seconds = 0.0;
        request.graph.transition = AnimationTransition::Blend { seconds: -0.1 };
        assert_eq!(
            resolve_air_trick_request(request).unwrap_err().reason,
            AirTrickAnimationFailureReason::InvalidTiming(
                InvalidAirTrickTimingField::TransitionSeconds
            )
        );
    }
}
