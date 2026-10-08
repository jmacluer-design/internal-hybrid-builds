//! Evidence-gated Skate 3 TU3 grind acquisition boundary.
//!
//! This module ports the deterministic record topology and arbitration pieces
//! recovered from TU3. It does not invent rail-query thresholds, the primary
//! candidate comparator, trajectory-adjust gates, chromosome producers, or
//! graph-route decisions. Those values must arrive as typed retail evidence.
#![allow(dead_code)] // Central integration is owned by the orchestrating agent.

use std::fmt;

pub mod tu3 {
    pub const DUMP_SHA256: &str =
        "F4AA113EB541BFBA03DBC108CF5AB43F58C965B20FA3B82F9C40938A0AD841C4";

    pub const CALCULATE_GRIND_TRAJ_DATA: u32 = 0x82D6_9F80;
    pub const CALCULATE_GRIND_TRAJ_DATA_END: u32 = 0x82D6_A168;
    pub const CALCULATE_GRIND_TRAJ_DATA_SHA256: &str =
        "E191CA3C864ED0D874705D9801F687F531731E3655242BA0023BFCA1D3D21A22";

    pub const FIND_BEST_GRIND: u32 = 0x82D6_A168;
    pub const FIND_BEST_GRIND_END: u32 = 0x82D6_A398;
    pub const FIND_BEST_GRIND_SHA256: &str =
        "84EE2BECEC6790A7CF51898AD60C23F8AB4021E993675B08C6B93CEC190F1B5C";

    pub const CONSIDER_GRIND_PRIMITIVE: u32 = 0x82D6_A398;
    pub const CONSIDER_GRIND_PRIMITIVE_END: u32 = 0x82D6_A840;
    pub const CONSIDER_GRIND_PRIMITIVE_SHA256: &str =
        "AA1A9F4A827D4B9C03BAA2389DBB401BD68B6F971C568F1F1239906936D2B153";

    pub const ANALYZE_AND_ADJUST_TRAJECTORY: u32 = 0x82D6_A840;
    pub const ANALYZE_AND_ADJUST_TRAJECTORY_END: u32 = 0x82D6_AF58;
    pub const ANALYZE_AND_ADJUST_TRAJECTORY_SHA256: &str =
        "A6B4359508C32E17642B0C1EC958B86165C3A8E944115A2284C45BE86787E37A";

    pub const UPDATE_GRIND_ADJUST: u32 = 0x82D7_12E0;
    pub const PROJECT_POINTS: u32 = 0x82D7_1430;
    pub const CALCULATE_DECK_Z_GRIND_ANGLE: u32 = 0x82D7_1F40;
    pub const INIT_TARGETS: u32 = 0x82D7_2B40;

    pub const GRIND_QUERY_HEADER_SIZE: usize = 16;
    pub const GRIND_PRIMITIVE_SIZE: usize = 48;
    pub const GRIND_TRAJECTORY_RESULT_SIZE: usize = 85;

    pub const PRIMITIVE_FIELD_00_OFFSET: usize = 0;
    pub const PRIMITIVE_FIELD_10_OFFSET: usize = 16;
    pub const PRIMITIVE_FIELD_20_OFFSET: usize = 32;

    pub const RESULT_VECTOR_00_OFFSET: usize = 0;
    pub const RESULT_VECTOR_10_OFFSET: usize = 16;
    pub const RESULT_VECTOR_20_OFFSET: usize = 32;
    pub const RESULT_VECTOR_30_OFFSET: usize = 48;
    pub const RESULT_SCALAR_40_OFFSET: usize = 64;
    pub const RESULT_SCALAR_44_OFFSET: usize = 68;
    pub const RESULT_SCALAR_48_OFFSET: usize = 72;
    pub const RESULT_WORD_4C_OFFSET: usize = 76;
    pub const RESULT_PRIMITIVE_INDEX_OFFSET: usize = 80;
    pub const RESULT_VALID_OFFSET: usize = 84;

    pub const SELECTOR_CANDIDATE_LIST_OFFSET: usize = 2992;
    pub const SELECTOR_LAST_QUERY_COUNT_OFFSET: usize = 9556;
    pub const SELECTOR_SELECTED_PRIMITIVE_FIELD_00_OFFSET: usize = 2944;
    pub const SELECTOR_SELECTED_PRIMITIVE_FIELD_10_OFFSET: usize = 2960;
    pub const SELECTOR_HAS_ADJUSTED_TRAJECTORY_OFFSET: usize = 9656;

    /// Literal loaded by `FindBestGrind` before fallback-score comparisons.
    pub const FALLBACK_SCORE_CEILING: f32 = 1000.0;

    pub const SPLINE_HEADER_SIZE: usize = 16;
    pub const SPLINE_RAIL_SIZE: usize = 32;
    pub const SPLINE_SEGMENT_SIZE: usize = 144;
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct GrindVec4 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub w: f32,
}

impl GrindVec4 {
    pub const ZERO: Self = Self::new(0.0, 0.0, 0.0, 0.0);

    pub const fn new(x: f32, y: f32, z: f32, w: f32) -> Self {
        Self { x, y, z, w }
    }

    pub const fn xyz(self) -> [f32; 3] {
        [self.x, self.y, self.z]
    }

    pub fn is_finite(self) -> bool {
        self.x.is_finite() && self.y.is_finite() && self.z.is_finite() && self.w.is_finite()
    }

    fn sub_xyz(self, other: Self) -> [f32; 3] {
        [self.x - other.x, self.y - other.y, self.z - other.z]
    }
}

fn read_be_u32(bytes: &[u8], offset: usize) -> u32 {
    u32::from_be_bytes(
        bytes[offset..offset + 4]
            .try_into()
            .expect("fixed field width"),
    )
}

fn read_be_u64(bytes: &[u8], offset: usize) -> u64 {
    u64::from_be_bytes(
        bytes[offset..offset + 8]
            .try_into()
            .expect("fixed field width"),
    )
}

fn read_be_f32(bytes: &[u8], offset: usize) -> f32 {
    f32::from_bits(read_be_u32(bytes, offset))
}

fn read_be_vec4(bytes: &[u8], offset: usize) -> GrindVec4 {
    GrindVec4::new(
        read_be_f32(bytes, offset),
        read_be_f32(bytes, offset + 4),
        read_be_f32(bytes, offset + 8),
        read_be_f32(bytes, offset + 12),
    )
}

fn write_be_u32(bytes: &mut [u8], offset: usize, value: u32) {
    bytes[offset..offset + 4].copy_from_slice(&value.to_be_bytes());
}

fn write_be_f32(bytes: &mut [u8], offset: usize, value: f32) {
    write_be_u32(bytes, offset, value.to_bits());
}

fn write_be_vec4(bytes: &mut [u8], offset: usize, value: GrindVec4) {
    write_be_f32(bytes, offset, value.x);
    write_be_f32(bytes, offset + 4, value.y);
    write_be_f32(bytes, offset + 8, value.z);
    write_be_f32(bytes, offset + 12, value.w);
}

/// One 48-byte primitive consumed by `ConsiderGrindPrimitive`.
///
/// TU3 directly subtracts `field_00` from `field_10` at function entry. The
/// complete semantic role of `field_20` remains unresolved, so byte-offset
/// names are retained.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct GrindPrimitive {
    pub field_00: GrindVec4,
    pub field_10: GrindVec4,
    pub field_20: GrindVec4,
}

impl GrindPrimitive {
    pub fn decode_be(bytes: &[u8; tu3::GRIND_PRIMITIVE_SIZE]) -> Self {
        Self {
            field_00: read_be_vec4(bytes, tu3::PRIMITIVE_FIELD_00_OFFSET),
            field_10: read_be_vec4(bytes, tu3::PRIMITIVE_FIELD_10_OFFSET),
            field_20: read_be_vec4(bytes, tu3::PRIMITIVE_FIELD_20_OFFSET),
        }
    }

    /// Exact first vector operation observed in `ConsiderGrindPrimitive`.
    pub fn endpoint_delta_xyz(self) -> [f32; 3] {
        self.field_10.sub_xyz(self.field_00)
    }

    pub fn fields_are_finite(self) -> bool {
        self.field_00.is_finite() && self.field_10.is_finite() && self.field_20.is_finite()
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct GrindDataQueryResult {
    pub primitives: Vec<GrindPrimitive>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QueryDecodeError {
    ByteLengthMismatch { expected: usize, actual: usize },
    CountOverflow,
}

impl GrindDataQueryResult {
    /// Decodes the primitive array behind the retail 16-byte query header.
    ///
    /// The header's pointer fields are intentionally not accepted as host
    /// pointers. The caller supplies the already-bounded primitive bytes.
    pub fn decode_primitive_bytes(count: u32, bytes: &[u8]) -> Result<Self, QueryDecodeError> {
        let count = usize::try_from(count).map_err(|_| QueryDecodeError::CountOverflow)?;
        let expected = count
            .checked_mul(tu3::GRIND_PRIMITIVE_SIZE)
            .ok_or(QueryDecodeError::CountOverflow)?;
        if bytes.len() != expected {
            return Err(QueryDecodeError::ByteLengthMismatch {
                expected,
                actual: bytes.len(),
            });
        }

        let primitives = bytes
            .chunks_exact(tu3::GRIND_PRIMITIVE_SIZE)
            .map(|chunk| {
                GrindPrimitive::decode_be(
                    chunk
                        .try_into()
                        .expect("chunks_exact guarantees the primitive width"),
                )
            })
            .collect();
        Ok(Self { primitives })
    }
}

/// Corroborating 144-byte Pegasus spline segment layout used by the local
/// native map adapter. Fields without proven selector semantics retain their
/// offsets or neutral names.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RetailSplineSegment {
    pub delta_00: GrindVec4,
    pub field_10: GrindVec4,
    pub field_20: GrindVec4,
    pub start_30: GrindVec4,
    pub reciprocal_length_40: GrindVec4,
    pub bounds_min_50: GrindVec4,
    pub bounds_max_60: GrindVec4,
    pub length_70: f32,
    pub cumulative_length_74: f32,
    pub rail_guest_address_78: u32,
    pub previous_guest_address_7c: u32,
    pub next_guest_address_80: u32,
    pub trailing_84: [u32; 3],
}

impl RetailSplineSegment {
    pub fn decode_be(bytes: &[u8; tu3::SPLINE_SEGMENT_SIZE]) -> Self {
        Self {
            delta_00: read_be_vec4(bytes, 0x00),
            field_10: read_be_vec4(bytes, 0x10),
            field_20: read_be_vec4(bytes, 0x20),
            start_30: read_be_vec4(bytes, 0x30),
            reciprocal_length_40: read_be_vec4(bytes, 0x40),
            bounds_min_50: read_be_vec4(bytes, 0x50),
            bounds_max_60: read_be_vec4(bytes, 0x60),
            length_70: read_be_f32(bytes, 0x70),
            cumulative_length_74: read_be_f32(bytes, 0x74),
            rail_guest_address_78: read_be_u32(bytes, 0x78),
            previous_guest_address_7c: read_be_u32(bytes, 0x7C),
            next_guest_address_80: read_be_u32(bytes, 0x80),
            trailing_84: [
                read_be_u32(bytes, 0x84),
                read_be_u32(bytes, 0x88),
                read_be_u32(bytes, 0x8C),
            ],
        }
    }

    /// Evaluates the stored affine segment without clamping or selecting the
    /// parameter. Parameter production remains a retail-provider input.
    pub fn evaluate_unclamped(self, parameter: f32) -> GrindVec4 {
        GrindVec4::new(
            self.start_30.x + self.delta_00.x * parameter,
            self.start_30.y + self.delta_00.y * parameter,
            self.start_30.z + self.delta_00.z * parameter,
            self.start_30.w + self.delta_00.w * parameter,
        )
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CandidateFields {
    pub vector_00: GrindVec4,
    pub vector_10: GrindVec4,
    pub vector_20: GrindVec4,
    pub vector_30: GrindVec4,
    /// Candidate value compared at `FindBestGrind + 0xC0`.
    pub scalar_40: f32,
    pub scalar_44: f32,
    pub scalar_48: f32,
    pub word_4c: u32,
}

impl CandidateFields {
    pub fn fields_are_finite(self) -> bool {
        self.vector_00.is_finite()
            && self.vector_10.is_finite()
            && self.vector_20.is_finite()
            && self.vector_30.is_finite()
            && self.scalar_40.is_finite()
            && self.scalar_44.is_finite()
            && self.scalar_48.is_finite()
    }
}

/// Typed form of TU3's 85-byte `GrindTrajectoryResults` payload.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct GrindTrajectoryCandidate {
    pub fields: CandidateFields,
    pub primitive_index: u32,
    pub valid_flag: u8,
}

impl GrindTrajectoryCandidate {
    pub fn decode_be(bytes: &[u8; tu3::GRIND_TRAJECTORY_RESULT_SIZE]) -> Self {
        Self {
            fields: CandidateFields {
                vector_00: read_be_vec4(bytes, tu3::RESULT_VECTOR_00_OFFSET),
                vector_10: read_be_vec4(bytes, tu3::RESULT_VECTOR_10_OFFSET),
                vector_20: read_be_vec4(bytes, tu3::RESULT_VECTOR_20_OFFSET),
                vector_30: read_be_vec4(bytes, tu3::RESULT_VECTOR_30_OFFSET),
                scalar_40: read_be_f32(bytes, tu3::RESULT_SCALAR_40_OFFSET),
                scalar_44: read_be_f32(bytes, tu3::RESULT_SCALAR_44_OFFSET),
                scalar_48: read_be_f32(bytes, tu3::RESULT_SCALAR_48_OFFSET),
                word_4c: read_be_u32(bytes, tu3::RESULT_WORD_4C_OFFSET),
            },
            primitive_index: read_be_u32(bytes, tu3::RESULT_PRIMITIVE_INDEX_OFFSET),
            valid_flag: bytes[tu3::RESULT_VALID_OFFSET],
        }
    }

    pub fn encode_be(self) -> [u8; tu3::GRIND_TRAJECTORY_RESULT_SIZE] {
        let mut bytes = [0; tu3::GRIND_TRAJECTORY_RESULT_SIZE];
        write_be_vec4(
            &mut bytes,
            tu3::RESULT_VECTOR_00_OFFSET,
            self.fields.vector_00,
        );
        write_be_vec4(
            &mut bytes,
            tu3::RESULT_VECTOR_10_OFFSET,
            self.fields.vector_10,
        );
        write_be_vec4(
            &mut bytes,
            tu3::RESULT_VECTOR_20_OFFSET,
            self.fields.vector_20,
        );
        write_be_vec4(
            &mut bytes,
            tu3::RESULT_VECTOR_30_OFFSET,
            self.fields.vector_30,
        );
        write_be_f32(
            &mut bytes,
            tu3::RESULT_SCALAR_40_OFFSET,
            self.fields.scalar_40,
        );
        write_be_f32(
            &mut bytes,
            tu3::RESULT_SCALAR_44_OFFSET,
            self.fields.scalar_44,
        );
        write_be_f32(
            &mut bytes,
            tu3::RESULT_SCALAR_48_OFFSET,
            self.fields.scalar_48,
        );
        write_be_u32(&mut bytes, tu3::RESULT_WORD_4C_OFFSET, self.fields.word_4c);
        write_be_u32(
            &mut bytes,
            tu3::RESULT_PRIMITIVE_INDEX_OFFSET,
            self.primitive_index,
        );
        bytes[tu3::RESULT_VALID_OFFSET] = self.valid_flag;
        bytes
    }

    pub const fn is_valid(self) -> bool {
        self.valid_flag != 0
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum GrindRequirement {
    PrimitiveConsideration { primitive_index: u32 },
    RuntimePrimaryScoreLimit,
    PrimaryCandidateArbitration,
    TrajectoryGate { attempt: usize },
    AdditionalRetryEvidence,
    PpcVectorRounding,
    RailQueryAbi,
    RailThresholdAttributes,
    ContactPositionProvider,
    GroundNormalProvider,
    LockTransform,
    ApproachChromosomeProvider,
    BoardEndChromosomeProvider,
    AlignmentChromosomeProvider,
    HeightChromosomeProvider,
    TravelChromosomeProvider,
    ContactChromosomeProvider,
    BluntGraphRoute,
    DarkApproachGraphRoute,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Required<T> {
    Supplied(T),
    Unresolved(GrindRequirement),
}

impl<T> Required<T> {
    pub const fn supplied(value: T) -> Self {
        Self::Supplied(value)
    }

    pub const fn unresolved(requirement: GrindRequirement) -> Self {
        Self::Unresolved(requirement)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum PrimitiveEvaluation {
    Rejected,
    Accepted(CandidateFields),
    Unresolved(GrindRequirement),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct CandidatePool {
    candidates: Vec<GrindTrajectoryCandidate>,
}

impl CandidatePool {
    pub fn as_slice(&self) -> &[GrindTrajectoryCandidate] {
        &self.candidates
    }

    pub fn is_empty(&self) -> bool {
        self.candidates.is_empty()
    }

    pub fn len(&self) -> usize {
        self.candidates.len()
    }

    pub fn from_candidates(candidates: Vec<GrindTrajectoryCandidate>) -> Self {
        Self { candidates }
    }

    /// Ports `CalculateGrindTrajData`'s deterministic collection topology.
    ///
    /// Primitive consideration itself remains external. Accepted records are
    /// retained in primitive order and stamped with the exact source index.
    pub fn calculate<F>(
        query: &GrindDataQueryResult,
        mut evaluate: F,
    ) -> Result<Self, AcquisitionError>
    where
        F: FnMut(u32, &GrindPrimitive) -> PrimitiveEvaluation,
    {
        let mut candidates = Vec::new();
        for (index, primitive) in query.primitives.iter().enumerate() {
            let index =
                u32::try_from(index).map_err(|_| AcquisitionError::PrimitiveCountOverflow)?;
            match evaluate(index, primitive) {
                PrimitiveEvaluation::Rejected => {}
                PrimitiveEvaluation::Accepted(fields) => {
                    candidates.push(GrindTrajectoryCandidate {
                        fields,
                        primitive_index: index,
                        valid_flag: 1,
                    });
                }
                PrimitiveEvaluation::Unresolved(requirement) => {
                    return Err(AcquisitionError::Unresolved(requirement));
                }
            }
        }
        Ok(Self { candidates })
    }

    /// Ports the proven portions of `FindBestGrind` and removes the winner,
    /// matching TU3's destructive candidate-list traversal.
    pub fn find_best_remove(
        &mut self,
        evidence: FindBestEvidence,
    ) -> Result<Option<GrindTrajectoryCandidate>, AcquisitionError> {
        let primary_score_limit = match evidence.primary_score_limit {
            Required::Supplied(value) if value.is_finite() => value,
            Required::Supplied(_) => return Err(AcquisitionError::NonFiniteEvidence),
            Required::Unresolved(requirement) => {
                return Err(AcquisitionError::Unresolved(requirement));
            }
        };

        let primary_positions: Vec<_> = self
            .candidates
            .iter()
            .enumerate()
            .filter_map(|(position, candidate)| {
                (candidate.fields.scalar_40 < primary_score_limit).then_some(position)
            })
            .collect();

        let primary_position = if primary_positions.is_empty() {
            None
        } else {
            match evidence.primary_branch {
                Required::Unresolved(requirement) => {
                    return Err(AcquisitionError::Unresolved(requirement));
                }
                Required::Supplied(PrimaryBranchResolution::NoWinner) => None,
                Required::Supplied(PrimaryBranchResolution::WinnerPrimitiveIndex(index)) => {
                    let position = self
                        .candidates
                        .iter()
                        .position(|candidate| candidate.primitive_index == index)
                        .ok_or(AcquisitionError::PrimaryWinnerMissing {
                            primitive_index: index,
                        })?;
                    if !primary_positions.contains(&position) {
                        return Err(AcquisitionError::PrimaryWinnerNotEligible {
                            primitive_index: index,
                        });
                    }
                    Some(position)
                }
            }
        };

        let selected_position = primary_position.or_else(|| {
            let mut best_score = tu3::FALLBACK_SCORE_CEILING;
            let mut best_position = None;
            for (position, candidate) in self.candidates.iter().enumerate() {
                let score = candidate.fields.scalar_40;
                if score >= primary_score_limit && score < best_score {
                    best_score = score;
                    best_position = Some(position);
                }
            }
            best_position
        });

        Ok(selected_position.map(|position| self.candidates.remove(position)))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PrimaryBranchResolution {
    NoWinner,
    WinnerPrimitiveIndex(u32),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FindBestEvidence {
    pub primary_score_limit: Required<f32>,
    pub primary_branch: Required<PrimaryBranchResolution>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrajectoryGateDecision {
    Reject,
    Accept,
    Unresolved(GrindRequirement),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailSelectionAttempt {
    pub find_best: FindBestEvidence,
    pub trajectory_gate: TrajectoryGateDecision,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GrindLockOn {
    pub candidate: GrindTrajectoryCandidate,
    pub primitive: GrindPrimitive,
}

/// Reproduces the observed select-remove-test-retry topology in
/// `AnalyzeAndAdjustTrajectory`.
pub fn analyze_and_adjust(
    query: &GrindDataQueryResult,
    pool: &mut CandidatePool,
    attempts: &[RetailSelectionAttempt],
) -> Result<Option<GrindLockOn>, AcquisitionError> {
    for (attempt_index, attempt) in attempts.iter().copied().enumerate() {
        let Some(candidate) = pool.find_best_remove(attempt.find_best)? else {
            return Ok(None);
        };

        match attempt.trajectory_gate {
            TrajectoryGateDecision::Reject => {
                if attempt_index + 1 == attempts.len() && !pool.is_empty() {
                    return Err(AcquisitionError::Unresolved(
                        GrindRequirement::AdditionalRetryEvidence,
                    ));
                }
                continue;
            }
            TrajectoryGateDecision::Unresolved(requirement) => {
                return Err(AcquisitionError::Unresolved(requirement));
            }
            TrajectoryGateDecision::Accept => {
                let primitive = query
                    .primitives
                    .get(candidate.primitive_index as usize)
                    .copied()
                    .ok_or(AcquisitionError::PrimitiveIndexOutOfRange {
                        primitive_index: candidate.primitive_index,
                        primitive_count: query.primitives.len(),
                    })?;
                return Ok(Some(GrindLockOn {
                    candidate,
                    primitive,
                }));
            }
        }
    }

    if pool.is_empty() {
        Ok(None)
    } else {
        Err(AcquisitionError::Unresolved(
            GrindRequirement::AdditionalRetryEvidence,
        ))
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum AcquisitionError {
    Unresolved(GrindRequirement),
    PrimitiveCountOverflow,
    NonFiniteEvidence,
    PrimaryWinnerMissing {
        primitive_index: u32,
    },
    PrimaryWinnerNotEligible {
        primitive_index: u32,
    },
    PrimitiveIndexOutOfRange {
        primitive_index: u32,
        primitive_count: usize,
    },
}

impl fmt::Display for AcquisitionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for AcquisitionError {}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ChromosomeProviderValues {
    pub approach: Required<u8>,
    pub board_end: Required<u8>,
    pub alignment: Required<u8>,
    pub height: Required<u8>,
    pub travel: Required<u8>,
    pub contact: Required<u8>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct RawGrindChromosome {
    pub approach: u8,
    pub board_end: u8,
    pub alignment: u8,
    pub height: u8,
    pub travel: u8,
    pub contact: u8,
}

impl RawGrindChromosome {
    pub const fn as_array(self) -> [u8; 6] {
        [
            self.approach,
            self.board_end,
            self.alignment,
            self.height,
            self.travel,
            self.contact,
        ]
    }

    /// TU3 formats travel code four as `UNK`, but the 384-entry classifier
    /// has radix four. The downstream chromosome classifier must reject it.
    pub const fn is_table_classifiable(self) -> bool {
        self.travel < 4
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChromosomeField {
    Approach,
    BoardEnd,
    Alignment,
    Height,
    Travel,
    Contact,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChromosomeAssemblyError {
    Unresolved(GrindRequirement),
    ValueOutsideObservedEnum {
        field: ChromosomeField,
        value: u8,
        maximum: u8,
    },
}

fn supplied_digit(
    required: Required<u8>,
    field: ChromosomeField,
    maximum: u8,
) -> Result<u8, ChromosomeAssemblyError> {
    let value = match required {
        Required::Supplied(value) => value,
        Required::Unresolved(requirement) => {
            return Err(ChromosomeAssemblyError::Unresolved(requirement));
        }
    };
    if value > maximum {
        return Err(ChromosomeAssemblyError::ValueOutsideObservedEnum {
            field,
            value,
            maximum,
        });
    }
    Ok(value)
}

/// Assembles only provider-supplied chromosome digits. No geometric heuristic
/// is allowed to manufacture a field.
pub fn assemble_raw_chromosome(
    values: ChromosomeProviderValues,
) -> Result<RawGrindChromosome, ChromosomeAssemblyError> {
    Ok(RawGrindChromosome {
        approach: supplied_digit(values.approach, ChromosomeField::Approach, 1)?,
        board_end: supplied_digit(values.board_end, ChromosomeField::BoardEnd, 1)?,
        alignment: supplied_digit(values.alignment, ChromosomeField::Alignment, 1)?,
        height: supplied_digit(values.height, ChromosomeField::Height, 1)?,
        travel: supplied_digit(values.travel, ChromosomeField::Travel, 4)?,
        contact: supplied_digit(values.contact, ChromosomeField::Contact, 5)?,
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BluntGraphRoute {
    Rail,
    Backslash,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DarkApproachGraphRoute {
    Frontside,
    Backside,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GrindGraphRouteFields {
    pub blunt: Required<Option<BluntGraphRoute>>,
    pub dark_approach: Required<Option<DarkApproachGraphRoute>>,
}

impl GrindGraphRouteFields {
    pub fn require_blunt(self) -> Result<BluntGraphRoute, GrindRequirement> {
        match self.blunt {
            Required::Supplied(Some(route)) => Ok(route),
            Required::Supplied(None) | Required::Unresolved(_) => {
                Err(GrindRequirement::BluntGraphRoute)
            }
        }
    }

    pub fn require_dark_approach(self) -> Result<DarkApproachGraphRoute, GrindRequirement> {
        match self.dark_approach {
            Required::Supplied(Some(route)) => Ok(route),
            Required::Supplied(None) | Required::Unresolved(_) => {
                Err(GrindRequirement::DarkApproachGraphRoute)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn primitive(x: f32) -> GrindPrimitive {
        GrindPrimitive {
            field_00: GrindVec4::new(x, 1.0, 2.0, 1.0),
            field_10: GrindVec4::new(x + 3.0, 5.0, 7.0, 1.0),
            field_20: GrindVec4::new(8.0, 9.0, 10.0, 0.0),
        }
    }

    fn fields(score: f32) -> CandidateFields {
        CandidateFields {
            vector_00: GrindVec4::new(1.0, 2.0, 3.0, 4.0),
            vector_10: GrindVec4::new(5.0, 6.0, 7.0, 8.0),
            vector_20: GrindVec4::new(9.0, 10.0, 11.0, 12.0),
            vector_30: GrindVec4::new(13.0, 14.0, 15.0, 16.0),
            scalar_40: score,
            scalar_44: 18.0,
            scalar_48: 19.0,
            word_4c: 0x1234_5678,
        }
    }

    fn fallback_evidence(limit: f32) -> FindBestEvidence {
        FindBestEvidence {
            primary_score_limit: Required::Supplied(limit),
            primary_branch: Required::Supplied(PrimaryBranchResolution::NoWinner),
        }
    }

    #[test]
    fn primitive_decoder_and_first_observed_delta_are_exact() {
        let mut bytes = [0_u8; tu3::GRIND_PRIMITIVE_SIZE];
        write_be_vec4(&mut bytes, 0, GrindVec4::new(1.0, 2.0, 3.0, 4.0));
        write_be_vec4(&mut bytes, 16, GrindVec4::new(6.0, 8.0, 10.0, 12.0));
        write_be_vec4(&mut bytes, 32, GrindVec4::new(13.0, 14.0, 15.0, 16.0));
        let decoded = GrindPrimitive::decode_be(&bytes);
        assert_eq!(decoded.endpoint_delta_xyz(), [5.0, 6.0, 7.0]);
        assert!(decoded.fields_are_finite());
    }

    #[test]
    fn query_decoder_enforces_the_observed_48_byte_stride() {
        let bytes = [0_u8; tu3::GRIND_PRIMITIVE_SIZE * 2];
        assert_eq!(
            GrindDataQueryResult::decode_primitive_bytes(2, &bytes)
                .unwrap()
                .primitives
                .len(),
            2
        );
        assert_eq!(
            GrindDataQueryResult::decode_primitive_bytes(2, &bytes[..95]),
            Err(QueryDecodeError::ByteLengthMismatch {
                expected: 96,
                actual: 95,
            })
        );
    }

    #[test]
    fn candidate_record_round_trips_all_85_observed_bytes() {
        let candidate = GrindTrajectoryCandidate {
            fields: fields(4.25),
            primitive_index: 0x1020_3040,
            valid_flag: 0x7F,
        };
        let bytes = candidate.encode_be();
        assert_eq!(bytes.len(), 85);
        assert_eq!(GrindTrajectoryCandidate::decode_be(&bytes), candidate);
        assert!(candidate.is_valid());
    }

    #[test]
    fn calculation_preserves_order_and_stamps_primitive_indices() {
        let query = GrindDataQueryResult {
            primitives: vec![primitive(0.0), primitive(10.0), primitive(20.0)],
        };
        let pool = CandidatePool::calculate(&query, |index, _| match index {
            0 => PrimitiveEvaluation::Accepted(fields(3.0)),
            1 => PrimitiveEvaluation::Rejected,
            2 => PrimitiveEvaluation::Accepted(fields(1.0)),
            _ => unreachable!(),
        })
        .unwrap();
        assert_eq!(
            pool.as_slice()
                .iter()
                .map(|candidate| candidate.primitive_index)
                .collect::<Vec<_>>(),
            vec![0, 2]
        );
    }

    #[test]
    fn unresolved_primitive_consideration_stops_collection() {
        let query = GrindDataQueryResult {
            primitives: vec![primitive(0.0)],
        };
        assert_eq!(
            CandidatePool::calculate(&query, |index, _| PrimitiveEvaluation::Unresolved(
                GrindRequirement::PrimitiveConsideration {
                    primitive_index: index
                }
            )),
            Err(AcquisitionError::Unresolved(
                GrindRequirement::PrimitiveConsideration { primitive_index: 0 }
            ))
        );
    }

    #[test]
    fn fallback_selection_uses_strict_score_and_first_tie() {
        let mut pool = CandidatePool::from_candidates(vec![
            GrindTrajectoryCandidate {
                fields: fields(10.0),
                primitive_index: 0,
                valid_flag: 1,
            },
            GrindTrajectoryCandidate {
                fields: fields(5.0),
                primitive_index: 1,
                valid_flag: 1,
            },
            GrindTrajectoryCandidate {
                fields: fields(5.0),
                primitive_index: 2,
                valid_flag: 1,
            },
        ]);
        let selected = pool
            .find_best_remove(fallback_evidence(0.0))
            .unwrap()
            .unwrap();
        assert_eq!(selected.primitive_index, 1);
        assert_eq!(pool.len(), 2);
    }

    #[test]
    fn fallback_ceiling_is_the_observed_literal_1000() {
        let mut pool = CandidatePool::from_candidates(vec![GrindTrajectoryCandidate {
            fields: fields(1000.0),
            primitive_index: 0,
            valid_flag: 1,
        }]);
        assert_eq!(pool.find_best_remove(fallback_evidence(0.0)), Ok(None));
    }

    #[test]
    fn primary_candidates_cannot_be_arbitrated_without_retail_evidence() {
        let mut pool = CandidatePool::from_candidates(vec![GrindTrajectoryCandidate {
            fields: fields(1.0),
            primitive_index: 7,
            valid_flag: 1,
        }]);
        assert_eq!(
            pool.find_best_remove(FindBestEvidence {
                primary_score_limit: Required::Supplied(2.0),
                primary_branch: Required::Unresolved(GrindRequirement::PrimaryCandidateArbitration),
            }),
            Err(AcquisitionError::Unresolved(
                GrindRequirement::PrimaryCandidateArbitration
            ))
        );
    }

    #[test]
    fn selected_candidate_is_removed_before_a_rejected_gate_retries() {
        let query = GrindDataQueryResult {
            primitives: vec![primitive(0.0), primitive(10.0)],
        };
        let mut pool = CandidatePool::from_candidates(vec![
            GrindTrajectoryCandidate {
                fields: fields(1.0),
                primitive_index: 0,
                valid_flag: 1,
            },
            GrindTrajectoryCandidate {
                fields: fields(2.0),
                primitive_index: 1,
                valid_flag: 1,
            },
        ]);
        let attempts = [
            RetailSelectionAttempt {
                find_best: fallback_evidence(0.0),
                trajectory_gate: TrajectoryGateDecision::Reject,
            },
            RetailSelectionAttempt {
                find_best: fallback_evidence(0.0),
                trajectory_gate: TrajectoryGateDecision::Accept,
            },
        ];
        let lock = analyze_and_adjust(&query, &mut pool, &attempts)
            .unwrap()
            .unwrap();
        assert_eq!(lock.candidate.primitive_index, 1);
        assert_eq!(lock.primitive, query.primitives[1]);
        assert!(pool.is_empty());
    }

    #[test]
    fn missing_retry_evidence_is_typed_unresolved() {
        let query = GrindDataQueryResult {
            primitives: vec![primitive(0.0), primitive(10.0)],
        };
        let mut pool = CandidatePool::from_candidates(vec![
            GrindTrajectoryCandidate {
                fields: fields(1.0),
                primitive_index: 0,
                valid_flag: 1,
            },
            GrindTrajectoryCandidate {
                fields: fields(2.0),
                primitive_index: 1,
                valid_flag: 1,
            },
        ]);
        assert_eq!(
            analyze_and_adjust(
                &query,
                &mut pool,
                &[RetailSelectionAttempt {
                    find_best: fallback_evidence(0.0),
                    trajectory_gate: TrajectoryGateDecision::Reject,
                }],
            ),
            Err(AcquisitionError::Unresolved(
                GrindRequirement::AdditionalRetryEvidence
            ))
        );
    }

    #[test]
    fn spline_evaluation_does_not_invent_parameter_clamping() {
        let segment = RetailSplineSegment {
            delta_00: GrindVec4::new(10.0, 0.0, 0.0, 0.0),
            start_30: GrindVec4::new(2.0, 3.0, 4.0, 1.0),
            ..Default::default()
        };
        assert_eq!(
            segment.evaluate_unclamped(1.5),
            GrindVec4::new(17.0, 3.0, 4.0, 1.0)
        );
    }

    #[test]
    fn chromosome_assembly_requires_every_provider_and_validates_ranges() {
        let values = ChromosomeProviderValues {
            approach: Required::Supplied(1),
            board_end: Required::Supplied(0),
            alignment: Required::Supplied(1),
            height: Required::Supplied(0),
            travel: Required::Supplied(3),
            contact: Required::Supplied(5),
        };
        assert_eq!(
            assemble_raw_chromosome(values).unwrap().as_array(),
            [1, 0, 1, 0, 3, 5]
        );
        assert_eq!(
            assemble_raw_chromosome(ChromosomeProviderValues {
                travel: Required::Supplied(5),
                ..values
            }),
            Err(ChromosomeAssemblyError::ValueOutsideObservedEnum {
                field: ChromosomeField::Travel,
                value: 5,
                maximum: 4,
            })
        );
        assert_eq!(
            assemble_raw_chromosome(ChromosomeProviderValues {
                approach: Required::Unresolved(GrindRequirement::ApproachChromosomeProvider),
                ..values
            }),
            Err(ChromosomeAssemblyError::Unresolved(
                GrindRequirement::ApproachChromosomeProvider
            ))
        );
    }

    #[test]
    fn unknown_travel_is_preserved_but_not_claimed_classifiable() {
        let chromosome = assemble_raw_chromosome(ChromosomeProviderValues {
            approach: Required::Supplied(0),
            board_end: Required::Supplied(0),
            alignment: Required::Supplied(0),
            height: Required::Supplied(0),
            travel: Required::Supplied(4),
            contact: Required::Supplied(0),
        })
        .unwrap();
        assert!(!chromosome.is_table_classifiable());
    }

    #[test]
    fn graph_route_fields_never_default() {
        let routes = GrindGraphRouteFields {
            blunt: Required::Supplied(None),
            dark_approach: Required::Unresolved(GrindRequirement::DarkApproachGraphRoute),
        };
        assert_eq!(
            routes.require_blunt(),
            Err(GrindRequirement::BluntGraphRoute)
        );
        assert_eq!(
            routes.require_dark_approach(),
            Err(GrindRequirement::DarkApproachGraphRoute)
        );
    }
}
