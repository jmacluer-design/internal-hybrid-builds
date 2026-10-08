//! Evidence-gated TU3 skateboard contact and post-physics bridge.
//!
//! This module ports the deterministic portions of
//! `Sk8::Physics::SkateboardBody::UpdatePostPhysics` and the final
//! `SkateboardBody::SetTransform` write topology.  It deliberately does not
//! assign meanings to the raw queued force types, invent contact-manifold
//! fields, or substitute a generic rigid-body backend.
#![allow(dead_code)] // Central integration is owned by the main agent.

use crate::riding_forces::{SkateboardForce, SkateboardForceQueue};
use crate::skateboard_body::{
    BODY_COUNT, BodyId, RETAIL_DECK_FORCE_Y_OFFSET, RETAIL_DECK_MASS, Vector3, WHEEL_COUNT, WheelId,
};

pub mod tu3 {
    pub const SKATEBOARD_UPDATE_POST_PHYSICS: u32 = 0x82C0_2138;
    pub const APPLY_QUEUED_SKATEBOARD_FORCES: u32 = 0x82C0_3718;
    pub const ADD_SKATEBOARD_FORCE: u32 = 0x82C0_3EF0;
    pub const BODY_UPDATE_POST_PHYSICS: u32 = 0x82C0_7D20;
    pub const DOMINANT_SURFACE_HELPER: u32 = 0x82C0_8818;
    pub const CALCULATE_AVERAGE_WHEEL_COMPRESSIONS: u32 = 0x82C0_8968;
    pub const SET_TRANSFORM: u32 = 0x82C0_B2C8;

    pub const CONTACT_RECORD_SIZE: usize = 96;
    pub const CONTACT_VECTOR_16_OFFSET: usize = 16;
    pub const CONTACT_VECTOR_32_OFFSET: usize = 32;
    pub const CONTACT_VECTOR_48_OFFSET: usize = 48;
    pub const CONTACT_BODY_INDEX_OFFSET: usize = 64;
    pub const CONTACT_CLASSIFICATION_OFFSET: usize = 68;
    pub const CONTACT_RAW_80_OFFSET: usize = 80;
    pub const CONTACT_RAW_81_OFFSET: usize = 81;

    pub const BODY_SELECTED_VECTOR_16_OFFSET: usize = 0x60;
    pub const BODY_SELECTED_VECTOR_32_OFFSET: usize = 0xD0;
    pub const BODY_SELECTED_VECTOR_48_OFFSET: usize = 0x220;
    pub const WHEEL_CHANNEL_ACTIVE_OFFSET: usize = 0x2F0;
    pub const WHEEL_SURFACE_CLASS_OFFSET: usize = 0x2F4;
    pub const WHEEL_COMPRESSION_METRIC_OFFSET: usize = 0x2E0;
    pub const DOMINANT_SURFACE_CLASS_OFFSET: usize = 0x348;
    pub const BODY_TOUCHING_OFFSET: usize = 0x34C;
    pub const TOUCHING_BODY_COUNT_OFFSET: usize = 0x364;
    pub const TOUCHING_WHEEL_COUNT_OFFSET: usize = 0x365;
    pub const DECK_NORMAL_SPAN_OFFSET: usize = 0x35C;
    pub const AIRBORNE_TIME_OFFSET: usize = 0x1E0C;

    pub const NO_CONTACT_FALLBACK_THRESHOLD_ADDRESS: u32 = 0x821B_CD64;
    pub const CONTACT_WHEEL_SCALAR_ADDRESS: u32 = 0x8221_6FEC;
    pub const NO_CONTACT_WHEEL_SCALAR_ADDRESS: u32 = 0x8211_6288;
    pub const WHEEL_SCALAR_RATE_ADDRESS: u32 = 0x822F_860C;
    pub const WHEEL_SUM_LENGTH_SQUARED_EPSILON_ADDRESS: u32 = 0x8209_8D0C;
    pub const FALLBACK_NORMAL_LENGTH_THRESHOLD_ADDRESS: u32 = 0x820D_71E8;
    pub const WHEEL_TO_REFERENCE_ANGLE_LIMIT_ADDRESS: u32 = 0x821A_9C28;
    pub const UP_VECTOR_ADDRESS: u32 = 0x8213_9A20;
    pub const DEGREES_TO_RADIANS_ADDRESS: u32 = 0x8206_D110;
    pub const MAX_ALLOWED_GROUND_NORMAL_LOOKUP: u32 = 0x82C0_84BC;
    pub const MAX_ALLOWED_GROUND_NORMAL_COSINE: u32 = 0x82C0_8504;
    pub const XM_VECTOR_COS: u32 = 0x8247_3930;
}

pub const NO_CONTACT_FALLBACK_THRESHOLD: f32 = 0.07;
pub const CONTACT_WHEEL_SCALAR: f32 = 0.04;
pub const NO_CONTACT_WHEEL_SCALAR: f32 = 0.006;
pub const WHEEL_SCALAR_RATE: f32 = 59.999_996;
pub const WHEEL_SUM_LENGTH_SQUARED_EPSILON: f32 = 1.525_878_9e-5;
pub const FALLBACK_NORMAL_LENGTH_THRESHOLD: f32 = 0.01;
pub const WHEEL_TO_REFERENCE_ANGLE_LIMIT_RADIANS: f32 = core::f32::consts::FRAC_PI_4;
pub const RETAIL_UP_VECTOR: Vector3 = Vector3::new(0.0, 1.0, 0.0);
pub const MAX_ALLOWED_GROUND_NORMAL_FROM_UP_DEGREES: f32 = 80.0;
pub const RETAIL_DEGREES_TO_RADIANS: f32 = f32::from_bits(0x3C8E_FA35);
/// Exact scalar result of the TU3 `XMVectorCos` polynomial at
/// `80.0 * RETAIL_DEGREES_TO_RADIANS`.
///
/// `SkateboardBody::UpdatePostPhysics` resolves the 80-degree attribute at
/// `0x82C084BC`, converts it at `0x82C08504`, and calls the retail polynomial
/// at `0x82473930`. The operation order and coefficients are present in the
/// generated TU3 recompiler source; evaluating those binary32 operations
/// yields this bit pattern.
pub const RETAIL_WHEEL_NORMAL_COSINE_THRESHOLD: f32 = f32::from_bits(0x3E31_D0D9);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SolverRequirement {
    ContactPeerAbi,
    ContactVectorRoles,
    PpcVectorMathRounding,
    AffineMatrixConvention,
    DeckForceYOffsetAttribute,
    PartForceScaleField,
    ForceApplicationBackend,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Required<T> {
    Supplied(T),
    Unresolved(SolverRequirement),
}

impl<T> Required<T> {
    pub const fn supplied(value: T) -> Self {
        Self::Supplied(value)
    }

    pub const fn unresolved(requirement: SolverRequirement) -> Self {
        Self::Unresolved(requirement)
    }

    pub const fn is_unresolved(&self) -> bool {
        matches!(self, Self::Unresolved(_))
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PackedContactClassification {
    pub low_7: u8,
    pub next_5: u8,
    pub next_4: u8,
}

impl PackedContactClassification {
    /// Exact bit extraction at `0x82C081B4..0x82C081E4`.
    pub const fn decode(raw: u32) -> Self {
        Self {
            low_7: (raw & 0x7F) as u8,
            next_5: ((raw >> 7) & 0x1F) as u8,
            next_4: ((raw >> 12) & 0x0F) as u8,
        }
    }
}

/// Typed representation of the fields directly read from each 96-byte retail
/// result.  Vector names intentionally retain their byte offsets because their
/// complete ABI roles are not proven.  `vector_16` is used as a normal by the
/// recovered arithmetic, but that does not establish every producer's ABI.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ContactRecord {
    pub body: BodyId,
    pub vector_16: Vector3,
    pub vector_32: Vector3,
    pub vector_48: Vector3,
    pub packed_classification: u32,
    pub raw_flag_80: bool,
    pub raw_flag_81: bool,
    /// The pointer/shape branch at `0x82C07F30..0x82C080D4` can clear a body
    /// channel for two raw peer kinds. Its pointer ABI remains external.
    pub peer_channel_effect: Required<PeerChannelEffect>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PeerChannelEffect {
    NoChange,
    Clear,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BodyContactChannel {
    /// Per-frame byte array at owner offset `0x34C`.
    pub touching_this_frame: bool,
    /// Persistent channel byte.  For wheels this begins at owner `0x2F0`.
    pub channel_active: bool,
    pub selected_vector_16: Vector3,
    pub selected_vector_32: Vector3,
    pub selected_vector_48: Vector3,
    /// Raw class used by the weighted wheel vote.
    pub surface_class: u8,
    /// Written only for truck/deck contact records by the recovered path.
    pub packed: PackedContactClassification,
}

impl Default for BodyContactChannel {
    fn default() -> Self {
        Self {
            touching_this_frame: false,
            channel_active: false,
            selected_vector_16: Vector3::ZERO,
            selected_vector_32: Vector3::ZERO,
            selected_vector_48: Vector3::ZERO,
            surface_class: 0,
            packed: PackedContactClassification::default(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WheelBridgeInput {
    pub wheel: WheelId,
    /// Scalar read from owner offsets `0x2E0..0x2EC`.
    pub compression_metric: f32,
    /// Vector copied into the selected-vector channel when no contact was
    /// observed and `compression_metric < 0.07`.
    pub no_contact_fallback_vector: Vector3,
}

impl WheelBridgeInput {
    pub const fn new(
        wheel: WheelId,
        compression_metric: f32,
        no_contact_fallback_vector: Vector3,
    ) -> Self {
        Self {
            wheel,
            compression_metric,
            no_contact_fallback_vector,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ContactBridgeInput<'a> {
    pub fixed_delta_seconds: f32,
    /// `Vector3 const&` passed to `UpdatePostPhysics`.
    pub reference_direction: Vector3,
    pub records: &'a [ContactRecord],
    pub previous_channels: [BodyContactChannel; BODY_COUNT],
    pub wheels: [WheelBridgeInput; WHEEL_COUNT],
    /// Retail flag bit `0x02000000` forces dominant class 12.
    pub force_dominant_surface_12: bool,
    pub previous_airborne_time_seconds: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContactNormalSource {
    EligibleWheelSum,
    TouchingDeckTruckSum,
    RetailUpFallback,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ContactNormalOutput {
    pub value: Vector3,
    pub source: ContactNormalSource,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PerWheelPostPhysics {
    pub wheel: WheelId,
    pub touching_this_frame: bool,
    pub channel_active: bool,
    pub selected_vector_16: Vector3,
    /// Exact `0.04/0.006 * 59.999996` write made to the wheel's downstream
    /// physics record at field `+36`.
    pub downstream_scalar: f32,
    pub surface_vote_weight: u8,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ContactBridgeOutput {
    pub channels: [BodyContactChannel; BODY_COUNT],
    pub wheels: [PerWheelPostPhysics; WHEEL_COUNT],
    pub touching_body_count: u8,
    pub touching_wheel_count: u8,
    pub dominant_surface_class: u8,
    pub deck_reference_span: f32,
    pub airborne_time_seconds: f32,
    pub contact_normal: Required<ContactNormalOutput>,
    /// Unresolved peer records do not silently mutate persistent channels.
    pub unresolved_peer_records: Vec<usize>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum SolverError {
    NonFiniteInput(&'static str),
    WheelOrderMismatch { slot: usize, supplied: WheelId },
    SurfaceClassOutsideRetailHistogram { wheel: WheelId, class: u8 },
}

/// Applies the contact-result reduction and per-wheel bridge recovered from
/// `0x82C07D20..0x82C08968`.
pub fn bridge_post_physics(
    input: ContactBridgeInput<'_>,
) -> Result<ContactBridgeOutput, SolverError> {
    validate_bridge_input(&input)?;

    let mut channels = input.previous_channels;
    for channel in &mut channels {
        channel.touching_this_frame = false;
    }

    let mut deck_min_dot = 1.0_f32;
    let mut deck_max_dot = -1.0_f32;
    let mut reference_body_index = None;
    let mut reference_body_component_1 = -2.0_f32;
    let mut unresolved_peer_records = Vec::new();

    for (record_index, record) in input.records.iter().enumerate() {
        let index = record.body.index();
        let channel = &mut channels[index];
        let replace_selected =
            !channel.touching_this_frame || record.vector_16.y > channel.selected_vector_16.y;
        if replace_selected {
            channel.selected_vector_16 = record.vector_16;
            channel.selected_vector_32 = record.vector_32;
            channel.selected_vector_48 = record.vector_48;
        }
        channel.touching_this_frame = true;
        if channel.selected_vector_16.y > reference_body_component_1 {
            reference_body_component_1 = channel.selected_vector_16.y;
            reference_body_index = Some(index);
        }

        match record.peer_channel_effect {
            Required::Supplied(PeerChannelEffect::NoChange) => {}
            Required::Supplied(PeerChannelEffect::Clear) => {
                channel.channel_active = false;
            }
            Required::Unresolved(SolverRequirement::ContactPeerAbi) => {
                unresolved_peer_records.push(record_index);
            }
            Required::Unresolved(_) => {
                unresolved_peer_records.push(record_index);
            }
        }

        if matches!(
            record.body,
            BodyId::FrontTruck | BodyId::BackTruck | BodyId::Deck
        ) {
            channel.packed = PackedContactClassification::decode(record.packed_classification);
        }

        if record.body == BodyId::Deck {
            let projection = dot(record.vector_16, input.reference_direction);
            deck_min_dot = deck_min_dot.min(projection);
            deck_max_dot = deck_max_dot.max(projection);
        }
    }

    let mut wheels = [PerWheelPostPhysics {
        wheel: WheelId::RightFront,
        touching_this_frame: false,
        channel_active: false,
        selected_vector_16: Vector3::ZERO,
        downstream_scalar: 0.0,
        surface_vote_weight: 0,
    }; WHEEL_COUNT];

    for (slot, wheel_input) in input.wheels.into_iter().enumerate() {
        if wheel_input.wheel.index() != slot {
            return Err(SolverError::WheelOrderMismatch {
                slot,
                supplied: wheel_input.wheel,
            });
        }
        let channel = &mut channels[slot];
        if !channel.touching_this_frame {
            if wheel_input.compression_metric < NO_CONTACT_FALLBACK_THRESHOLD {
                channel.selected_vector_16 = wheel_input.no_contact_fallback_vector;
            } else {
                channel.channel_active = false;
            }
        }

        let base_scalar = if channel.touching_this_frame {
            CONTACT_WHEEL_SCALAR
        } else {
            NO_CONTACT_WHEEL_SCALAR
        };
        wheels[slot] = PerWheelPostPhysics {
            wheel: wheel_input.wheel,
            touching_this_frame: channel.touching_this_frame,
            channel_active: channel.channel_active,
            selected_vector_16: channel.selected_vector_16,
            downstream_scalar: base_scalar * WHEEL_SCALAR_RATE,
            surface_vote_weight: if channel.surface_class == 0 {
                0
            } else if channel.touching_this_frame {
                4
            } else {
                1
            },
        };
    }

    let dominant_surface_class =
        dominant_surface_class(&wheels, &channels, input.force_dominant_surface_12)?;
    let touching_body_count = channels
        .iter()
        .filter(|channel| channel.touching_this_frame)
        .count() as u8;
    let touching_wheel_count = wheels
        .iter()
        .filter(|wheel| wheel.touching_this_frame)
        .count() as u8;
    let airborne_time_seconds = if touching_wheel_count == 0 {
        input.previous_airborne_time_seconds + input.fixed_delta_seconds
    } else {
        0.0
    };

    let contact_normal = Required::Supplied(select_contact_normal(
        &channels,
        input.reference_direction,
        RETAIL_WHEEL_NORMAL_COSINE_THRESHOLD,
        reference_body_index,
    ));

    Ok(ContactBridgeOutput {
        channels,
        wheels,
        touching_body_count,
        touching_wheel_count,
        dominant_surface_class,
        deck_reference_span: (deck_max_dot - deck_min_dot).max(0.0),
        airborne_time_seconds,
        contact_normal,
        unresolved_peer_records,
    })
}

fn validate_bridge_input(input: &ContactBridgeInput<'_>) -> Result<(), SolverError> {
    if !input.fixed_delta_seconds.is_finite() || input.fixed_delta_seconds < 0.0 {
        return Err(SolverError::NonFiniteInput("fixed_delta_seconds"));
    }
    if !input.previous_airborne_time_seconds.is_finite()
        || input.previous_airborne_time_seconds < 0.0
    {
        return Err(SolverError::NonFiniteInput(
            "previous_airborne_time_seconds",
        ));
    }
    if !finite(input.reference_direction) {
        return Err(SolverError::NonFiniteInput("reference_direction"));
    }
    for record in input.records {
        if !finite(record.vector_16) || !finite(record.vector_32) || !finite(record.vector_48) {
            return Err(SolverError::NonFiniteInput("contact_record_vector"));
        }
    }
    for wheel in input.wheels {
        if !wheel.compression_metric.is_finite() {
            return Err(SolverError::NonFiniteInput("wheel_compression_metric"));
        }
        if !finite(wheel.no_contact_fallback_vector) {
            return Err(SolverError::NonFiniteInput(
                "wheel_no_contact_fallback_vector",
            ));
        }
    }
    Ok(())
}

fn dominant_surface_class(
    wheels: &[PerWheelPostPhysics; WHEEL_COUNT],
    channels: &[BodyContactChannel; BODY_COUNT],
    force_12: bool,
) -> Result<u8, SolverError> {
    let mut histogram = [0_u32; 16];
    for wheel in wheels {
        let class = channels[wheel.wheel.index()].surface_class;
        if class as usize >= histogram.len() {
            return Err(SolverError::SurfaceClassOutsideRetailHistogram {
                wheel: wheel.wheel,
                class,
            });
        }
        if class != 0 {
            histogram[class as usize] += wheel.surface_vote_weight as u32;
        }
    }

    // The helper scans bins 1 through 13 and updates only on a strict greater
    // comparison, preserving the lower class on ties.
    let mut best_class = 1_u8;
    let mut best_weight = 0_u32;
    for class in 1_u8..=13 {
        let weight = histogram[class as usize];
        if weight > best_weight {
            best_weight = weight;
            best_class = class;
        }
    }
    if force_12 {
        best_class = 12;
    }
    Ok(best_class)
}

fn select_contact_normal(
    channels: &[BodyContactChannel; BODY_COUNT],
    reference_direction: Vector3,
    cosine_threshold: f32,
    reference_body: Option<usize>,
) -> ContactNormalOutput {
    let mut wheel_sum = Vector3::ZERO;
    if let Some(reference_index) = reference_body {
        let reference_normal = channels[reference_index].selected_vector_16;
        for wheel in WheelId::ORDER {
            let channel = &channels[wheel.index()];
            if !channel.touching_this_frame {
                continue;
            }
            let normal = channel.selected_vector_16;
            if dot(normal, reference_direction) > cosine_threshold
                && angle_between(reference_normal, normal) < WHEEL_TO_REFERENCE_ANGLE_LIMIT_RADIANS
            {
                wheel_sum = add(wheel_sum, normal);
            }
        }
    }
    if length_squared(wheel_sum) > WHEEL_SUM_LENGTH_SQUARED_EPSILON {
        return ContactNormalOutput {
            value: normalize(wheel_sum),
            source: ContactNormalSource::EligibleWheelSum,
        };
    }

    let mut fallback = Vector3::ZERO;
    for body in [BodyId::Deck, BodyId::FrontTruck, BodyId::BackTruck] {
        let channel = &channels[body.index()];
        if channel.touching_this_frame {
            fallback = add(fallback, channel.selected_vector_16);
        }
    }
    if length(fallback) > FALLBACK_NORMAL_LENGTH_THRESHOLD {
        ContactNormalOutput {
            value: normalize(fallback),
            source: ContactNormalSource::TouchingDeckTruckSum,
        }
    } else {
        ContactNormalOutput {
            value: RETAIL_UP_VECTOR,
            source: ContactNormalSource::RetailUpFallback,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct QueuedForceApplication {
    pub ordinal: usize,
    pub raw: SkateboardForce,
    /// Observed at `0x82C037DC..0x82C03908`: every 48-byte queue record is
    /// consumed by the same arithmetic. The raw type stored at byte zero is
    /// not read by this physical consumer.
    pub raw_type_is_physically_ignored: bool,
    pub deck_force_y_offset: Required<f32>,
    /// TU3 reads `RigidBody + 0x7c`, the exact inverse-mass field, and
    /// multiplies payload zero by it before accumulation.
    pub part_force_scale: Required<f32>,
    pub backend: Required<()>,
}

/// Produces the ordered input stream consumed by TU3's force accumulator at
/// `0x82C03718`.
///
/// The producer-side type still documents where a record came from (for
/// example, Ground queues Pumping as raw type 8), but the physical consumer
/// advances through the vector by 48 bytes and never branches on byte zero.
/// Payload zero is the force vector. Payload one is combined with the deck
/// force-Y-offset attribute and the rigid-part basis to form the torque arm.
///
/// The body-space point transform is the deck's `Ri/Up/At` basis, and
/// `RigidBody + 0x7c` is inverse mass. The matching point-force accumulator is
/// ported in `skateboard_body::retail_rigid_body`.
pub fn plan_queued_force_application(queue: &SkateboardForceQueue) -> Vec<QueuedForceApplication> {
    queue
        .iter()
        .enumerate()
        .map(|(ordinal, raw)| QueuedForceApplication {
            ordinal,
            raw: *raw,
            raw_type_is_physically_ignored: true,
            deck_force_y_offset: Required::supplied(RETAIL_DECK_FORCE_Y_OFFSET),
            part_force_scale: Required::supplied(1.0 / RETAIL_DECK_MASS),
            backend: Required::supplied(()),
        })
        .collect()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransformTarget {
    Body(BodyId),
    AuxiliaryBody,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransformSource {
    DesiredDeckTransform,
    ExistingBodyPostMultipliedByDeckDelta,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TransformWrite {
    pub order: u8,
    pub target: TransformTarget,
    pub source: TransformSource,
    pub matrix_convention: SolverRequirement,
}

/// Exact write topology of `SkateboardBody::SetTransform` at `0x82C0B2C8`.
///
/// The function writes the requested deck transform first, applies one common
/// deck delta to bodies 0..5 in body-index order, then writes the same requested
/// transform to the auxiliary body at owner offset `+996`.  The PPC affine
/// storage convention is intentionally still a required integration input.
pub const fn set_transform_write_plan() -> [TransformWrite; 8] {
    [
        TransformWrite {
            order: 0,
            target: TransformTarget::Body(BodyId::Deck),
            source: TransformSource::DesiredDeckTransform,
            matrix_convention: SolverRequirement::AffineMatrixConvention,
        },
        TransformWrite {
            order: 1,
            target: TransformTarget::Body(BodyId::RightFrontWheel),
            source: TransformSource::ExistingBodyPostMultipliedByDeckDelta,
            matrix_convention: SolverRequirement::AffineMatrixConvention,
        },
        TransformWrite {
            order: 2,
            target: TransformTarget::Body(BodyId::LeftFrontWheel),
            source: TransformSource::ExistingBodyPostMultipliedByDeckDelta,
            matrix_convention: SolverRequirement::AffineMatrixConvention,
        },
        TransformWrite {
            order: 3,
            target: TransformTarget::Body(BodyId::RightBackWheel),
            source: TransformSource::ExistingBodyPostMultipliedByDeckDelta,
            matrix_convention: SolverRequirement::AffineMatrixConvention,
        },
        TransformWrite {
            order: 4,
            target: TransformTarget::Body(BodyId::LeftBackWheel),
            source: TransformSource::ExistingBodyPostMultipliedByDeckDelta,
            matrix_convention: SolverRequirement::AffineMatrixConvention,
        },
        TransformWrite {
            order: 5,
            target: TransformTarget::Body(BodyId::FrontTruck),
            source: TransformSource::ExistingBodyPostMultipliedByDeckDelta,
            matrix_convention: SolverRequirement::AffineMatrixConvention,
        },
        TransformWrite {
            order: 6,
            target: TransformTarget::Body(BodyId::BackTruck),
            source: TransformSource::ExistingBodyPostMultipliedByDeckDelta,
            matrix_convention: SolverRequirement::AffineMatrixConvention,
        },
        TransformWrite {
            order: 7,
            target: TransformTarget::AuxiliaryBody,
            source: TransformSource::DesiredDeckTransform,
            matrix_convention: SolverRequirement::AffineMatrixConvention,
        },
    ]
}

fn finite(value: Vector3) -> bool {
    value.x.is_finite() && value.y.is_finite() && value.z.is_finite()
}

fn add(left: Vector3, right: Vector3) -> Vector3 {
    Vector3::new(left.x + right.x, left.y + right.y, left.z + right.z)
}

fn dot(left: Vector3, right: Vector3) -> f32 {
    left.x * right.x + left.y * right.y + left.z * right.z
}

fn length_squared(value: Vector3) -> f32 {
    dot(value, value)
}

fn length(value: Vector3) -> f32 {
    length_squared(value).sqrt()
}

fn normalize(value: Vector3) -> Vector3 {
    let reciprocal = 1.0 / length(value);
    Vector3::new(
        value.x * reciprocal,
        value.y * reciprocal,
        value.z * reciprocal,
    )
}

fn angle_between(left: Vector3, right: Vector3) -> f32 {
    let denominator = length(left) * length(right);
    if denominator == 0.0 {
        return core::f32::consts::PI;
    }
    (dot(left, right) / denominator).clamp(-1.0, 1.0).acos()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::riding_forces::{RetailVec4, SkateboardForceType};

    fn wheel_inputs(metric: f32) -> [WheelBridgeInput; WHEEL_COUNT] {
        WheelId::ORDER
            .map(|wheel| WheelBridgeInput::new(wheel, metric, Vector3::new(0.0, 1.0, 0.0)))
    }

    fn base_input<'a>(
        records: &'a [ContactRecord],
        previous_channels: [BodyContactChannel; BODY_COUNT],
    ) -> ContactBridgeInput<'a> {
        ContactBridgeInput {
            fixed_delta_seconds: 1.0 / 60.0,
            reference_direction: Vector3::new(0.0, 1.0, 0.0),
            records,
            previous_channels,
            wheels: wheel_inputs(0.0),
            force_dominant_surface_12: false,
            previous_airborne_time_seconds: 0.0,
        }
    }

    fn record(body: BodyId, normal: Vector3, packed: u32) -> ContactRecord {
        ContactRecord {
            body,
            vector_16: normal,
            vector_32: Vector3::new(body.index() as f32, 2.0, 3.0),
            vector_48: Vector3::new(4.0, 5.0, body.index() as f32),
            packed_classification: packed,
            raw_flag_80: false,
            raw_flag_81: false,
            peer_channel_effect: Required::supplied(PeerChannelEffect::NoChange),
        }
    }

    #[test]
    fn packed_fields_use_exact_7_5_4_bit_slices() {
        assert_eq!(
            PackedContactClassification::decode(0xABCD),
            PackedContactClassification {
                low_7: 0x4D,
                next_5: 0x17,
                next_4: 0xA,
            }
        );
    }

    #[test]
    fn highest_component_one_contact_wins_per_body() {
        let records = [
            record(BodyId::RightFrontWheel, Vector3::new(1.0, 0.25, 0.0), 0),
            record(BodyId::RightFrontWheel, Vector3::new(0.0, 0.75, 1.0), 0),
            record(BodyId::RightFrontWheel, Vector3::new(9.0, 0.5, 9.0), 0),
        ];
        let output = bridge_post_physics(base_input(
            &records,
            [BodyContactChannel::default(); BODY_COUNT],
        ))
        .unwrap();
        assert_eq!(
            output.channels[BodyId::RightFrontWheel.index()].selected_vector_16,
            Vector3::new(0.0, 0.75, 1.0)
        );
        assert_eq!(output.touching_body_count, 1);
        assert_eq!(output.touching_wheel_count, 1);
    }

    #[test]
    fn deck_projection_span_preserves_one_and_minus_one_initial_bounds() {
        let records = [
            record(BodyId::Deck, Vector3::new(0.0, 0.8, 0.0), 0),
            record(BodyId::Deck, Vector3::new(0.0, 0.2, 0.0), 0),
        ];
        let output = bridge_post_physics(base_input(
            &records,
            [BodyContactChannel::default(); BODY_COUNT],
        ))
        .unwrap();
        assert!((output.deck_reference_span - 0.6).abs() < 1.0e-6);

        let no_records =
            bridge_post_physics(base_input(&[], [BodyContactChannel::default(); BODY_COUNT]))
                .unwrap();
        assert_eq!(no_records.deck_reference_span, 0.0);
    }

    #[test]
    fn no_contact_threshold_is_strict_and_wheel_scalars_are_exact() {
        let mut channels = [BodyContactChannel::default(); BODY_COUNT];
        channels[0].channel_active = true;
        channels[1].channel_active = true;
        let mut input = base_input(&[], channels);
        input.wheels[0].compression_metric = NO_CONTACT_FALLBACK_THRESHOLD - 0.0001;
        input.wheels[1].compression_metric = NO_CONTACT_FALLBACK_THRESHOLD;
        let output = bridge_post_physics(input).unwrap();

        assert!(output.wheels[0].channel_active);
        assert!(!output.wheels[1].channel_active);
        assert_eq!(
            output.wheels[0].downstream_scalar,
            NO_CONTACT_WHEEL_SCALAR * WHEEL_SCALAR_RATE
        );

        let contact = [record(
            BodyId::RightFrontWheel,
            Vector3::new(0.0, 1.0, 0.0),
            0,
        )];
        let output = bridge_post_physics(base_input(
            &contact,
            [BodyContactChannel::default(); BODY_COUNT],
        ))
        .unwrap();
        assert_eq!(
            output.wheels[0].downstream_scalar,
            CONTACT_WHEEL_SCALAR * WHEEL_SCALAR_RATE
        );
    }

    #[test]
    fn touching_wheels_have_four_to_one_surface_vote_and_ties_keep_low_class() {
        let mut channels = [BodyContactChannel::default(); BODY_COUNT];
        channels[0].surface_class = 5;
        channels[1].surface_class = 3;
        channels[2].surface_class = 3;
        let records = [
            record(BodyId::RightFrontWheel, Vector3::new(0.0, 1.0, 0.0), 0),
            record(BodyId::LeftFrontWheel, Vector3::new(0.0, 1.0, 0.0), 0),
        ];
        let output = bridge_post_physics(base_input(&records, channels)).unwrap();
        // Class 5 has weight 4; class 3 has 4 from a touching wheel plus 1
        // from a non-touching wheel.
        assert_eq!(output.dominant_surface_class, 3);

        let mut channels = [BodyContactChannel::default(); BODY_COUNT];
        channels[0].surface_class = 5;
        channels[1].surface_class = 3;
        let output = bridge_post_physics(base_input(&records, channels)).unwrap();
        assert_eq!(output.dominant_surface_class, 3);
    }

    #[test]
    fn dominant_surface_override_is_exact_class_12() {
        let mut input = base_input(&[], [BodyContactChannel::default(); BODY_COUNT]);
        input.force_dominant_surface_12 = true;
        assert_eq!(
            bridge_post_physics(input).unwrap().dominant_surface_class,
            12
        );
    }

    #[test]
    fn airborne_clock_advances_only_with_zero_touching_wheels() {
        let mut input = base_input(&[], [BodyContactChannel::default(); BODY_COUNT]);
        input.fixed_delta_seconds = 0.25;
        input.previous_airborne_time_seconds = 1.0;
        assert_eq!(
            bridge_post_physics(input).unwrap().airborne_time_seconds,
            1.25
        );

        let contact = [record(
            BodyId::RightBackWheel,
            Vector3::new(0.0, 1.0, 0.0),
            0,
        )];
        let mut input = base_input(&contact, [BodyContactChannel::default(); BODY_COUNT]);
        input.previous_airborne_time_seconds = 1.0;
        assert_eq!(
            bridge_post_physics(input).unwrap().airborne_time_seconds,
            0.0
        );
    }

    #[test]
    fn contact_normal_uses_wheels_then_deck_trucks_then_retail_up() {
        let records = [
            record(BodyId::RightFrontWheel, Vector3::new(0.0, 1.0, 0.0), 0),
            record(BodyId::LeftFrontWheel, Vector3::new(0.0, 1.0, 0.0), 0),
        ];
        let output = bridge_post_physics(base_input(
            &records,
            [BodyContactChannel::default(); BODY_COUNT],
        ))
        .unwrap();
        assert_eq!(
            output.contact_normal,
            Required::supplied(ContactNormalOutput {
                value: RETAIL_UP_VECTOR,
                source: ContactNormalSource::EligibleWheelSum,
            })
        );

        let records = [record(BodyId::Deck, Vector3::new(0.0, 0.5, 0.5), 0)];
        let output = bridge_post_physics(base_input(
            &records,
            [BodyContactChannel::default(); BODY_COUNT],
        ))
        .unwrap();
        assert_eq!(
            output.contact_normal,
            Required::supplied(ContactNormalOutput {
                value: normalize(Vector3::new(0.0, 0.5, 0.5)),
                source: ContactNormalSource::TouchingDeckTruckSum,
            })
        );

        let output =
            bridge_post_physics(base_input(&[], [BodyContactChannel::default(); BODY_COUNT]))
                .unwrap();
        assert_eq!(
            output.contact_normal,
            Required::supplied(ContactNormalOutput {
                value: RETAIL_UP_VECTOR,
                source: ContactNormalSource::RetailUpFallback,
            })
        );
    }

    #[test]
    fn wheel_normal_threshold_is_the_recovered_retail_cosine_result() {
        assert_eq!(
            RETAIL_DEGREES_TO_RADIANS.to_bits(),
            0.017_453_292_384_743_69_f32.to_bits()
        );
        assert_eq!(RETAIL_WHEEL_NORMAL_COSINE_THRESHOLD.to_bits(), 0x3E31_D0D9);
        assert!((RETAIL_WHEEL_NORMAL_COSINE_THRESHOLD - 0.173_648_25).abs() < f32::EPSILON);
    }

    #[test]
    fn queued_force_application_preserves_order_and_does_not_dispatch_on_type() {
        let mut queue = SkateboardForceQueue::default();
        for force_type in [7, 3, 9] {
            assert!(queue.add(SkateboardForce::new(
                SkateboardForceType(force_type),
                RetailVec4::new(force_type as f32, 0.0, 0.0, 0.0),
                RetailVec4::ZERO,
            )));
        }
        let plan = plan_queued_force_application(&queue);
        assert_eq!(
            plan.iter().map(|entry| entry.ordinal).collect::<Vec<_>>(),
            vec![0, 1, 2]
        );
        assert_eq!(
            plan.iter()
                .map(|entry| entry.raw.force_type.0)
                .collect::<Vec<_>>(),
            vec![7, 3, 9]
        );
        assert!(
            plan.iter()
                .all(|entry| entry.raw_type_is_physically_ignored)
        );
        assert!(plan.iter().all(|entry| {
            entry.deck_force_y_offset == Required::supplied(RETAIL_DECK_FORCE_Y_OFFSET)
        }));
        assert!(
            plan.iter().all(|entry| {
                entry.part_force_scale == Required::supplied(1.0 / RETAIL_DECK_MASS)
            })
        );
        assert!(
            plan.iter()
                .all(|entry| entry.backend == Required::supplied(()))
        );
    }

    #[test]
    fn set_transform_plan_preserves_retail_write_order() {
        let plan = set_transform_write_plan();
        assert_eq!(
            plan.map(|write| write.target),
            [
                TransformTarget::Body(BodyId::Deck),
                TransformTarget::Body(BodyId::RightFrontWheel),
                TransformTarget::Body(BodyId::LeftFrontWheel),
                TransformTarget::Body(BodyId::RightBackWheel),
                TransformTarget::Body(BodyId::LeftBackWheel),
                TransformTarget::Body(BodyId::FrontTruck),
                TransformTarget::Body(BodyId::BackTruck),
                TransformTarget::AuxiliaryBody,
            ]
        );
        assert_eq!(plan.map(|write| write.order), [0, 1, 2, 3, 4, 5, 6, 7]);
        assert_eq!(plan[0].source, TransformSource::DesiredDeckTransform);
        assert_eq!(plan[7].source, TransformSource::DesiredDeckTransform);
    }
}
