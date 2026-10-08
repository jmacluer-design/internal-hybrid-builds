//! Evidence-backed Skate 3 TU3 Flickit input primitives.
//!
//! This module intentionally separates facts recovered from the TU3 executable and
//! retail data from semantics that are not yet proven. In particular, satisfying a
//! pattern's ordered coordinate/tolerance geometry produces a
//! [`PopRecognition::GeometryCandidates`] result, not a published trick. Static
//! analysis has recovered packed `PatternNode` initialization/advancement, the
//! exact arbitration equation at `0x8269_72B8`, and stable tie behavior. The
//! runtime recognizer-attribute byte controlling maximum gap has now been
//! captured as `10` for both matcher configurations. The recognizer remains
//! driven by upstream input notifications rather than an invented fixed Hertz.
//!
//! The module has no Bevy dependency. A Bevy input system can convert its gamepad
//! values to [`Stick2`] at the boundary, while this file remains independently
//! testable with `rustc --test`.
#![allow(dead_code)]

use std::fmt;

use crate::stance::MirrorState;

pub const TU3_IMAGE_BASE: u32 = 0x8200_0000;
pub const RIGHT_STICK_HISTORY_CAPACITY: usize = 201;
pub const RAW_AXIS_SCALE: f32 = 3.051_757_8e-5;
pub const RADIAL_ZERO_EPSILON: f32 = 0.001;
pub const RADIAL_DEADZONE: f32 = 0.25;
pub const RADIAL_GAIN: f32 = 1.428_571_5;
pub const COMPONENT_FILTER_THRESHOLD: f32 = 0.1;
pub const ANTICIPATION_MAGNITUDE_GATE: f32 = 0.9;
/// Runtime value read from matcher-config offset `+0x21`.
///
/// A headless Frida capture against the TU3 recompilation image with SHA-256
/// `28C3B477B80A94C6E10DB6E1A4174762A1229696C18FC6ABB68DD34433612D4D`
/// observed this value on all seven live matcher objects, spanning both
/// configuration pointers (`0x42062310` and `0x42062340`).
pub const RETAIL_PATTERN_MAXIMUM_GAP_SAMPLES: u8 = 10;
pub const MATCHER_CONFIG_MAXIMUM_GAP_OFFSET: u32 = 0x21;

/// Verified TU3 guest addresses. Subtract [`TU3_IMAGE_BASE`] for module-relative
/// offsets.
pub mod tu3_address {
    pub const RAW_GAMEPAD_DECODE_AND_RADIAL_NORMALIZE: u32 = 0x8296_D5F8;
    pub const GAME_INPUT_MANAGER_UPDATE: u32 = 0x8269_6030;
    pub const SAMPLED_RECOGNIZER_UPDATE: u32 = 0x8269_62D8;
    pub const PATTERN_FILE_LOAD: u32 = 0x8269_61A8;
    pub const KNOWN_PATTERNS_LOAD: u32 = 0x8269_6B18;
    pub const KNOWN_PATTERNS_ADD_PATTERN: u32 = 0x8269_6F40;
    pub const PATTERN_MATCH: u32 = 0x8269_7168;
    pub const CANDIDATE_SCORE_AND_SELECT: u32 = 0x8269_72B8;
    pub const PATTERN_NODE_UPDATE: u32 = 0x8269_74A8;
    pub const HISTORY_PUSH_FRONT: u32 = 0x8269_9738;
    pub const HISTORY_INDEX: u32 = 0x8269_97A8;
    pub const INPUT_PATTERN_LISTENER: u32 = 0x8259_B878;
    pub const HAS_GESTURE_INTENT_CONSTRUCTOR: u32 = 0x82BA_0F78;
    pub const CREATE_TRICK_INTENT_BEGIN: u32 = 0x82BA_1C30;
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Stick2 {
    pub x: f32,
    pub y: f32,
}

impl Stick2 {
    pub const ZERO: Self = Self { x: 0.0, y: 0.0 };

    pub const fn new(x: f32, y: f32) -> Self {
        Self { x, y }
    }

    pub fn length_squared(self) -> f32 {
        self.x.mul_add(self.x, self.y * self.y)
    }

    pub fn length(self) -> f32 {
        self.length_squared().sqrt()
    }

    pub fn distance_squared(self, other: Self) -> f32 {
        let dx = self.x - other.x;
        let dy = self.y - other.y;
        dx.mul_add(dx, dy * dy)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RawStickSample {
    pub x: i16,
    pub y: i16,
}

/// A deterministic fixed-capacity newest-first ring.
///
/// TU3's `PlayerInput` allocates 201 `Vector2` samples per lane and calls
/// `ring_buffer<Vector2>::push_front` at `0x8269_9738`.
#[derive(Clone, Debug)]
pub struct History201<T: Copy + Default> {
    samples: [T; RIGHT_STICK_HISTORY_CAPACITY],
    head: usize,
    len: usize,
}

impl<T: Copy + Default> Default for History201<T> {
    fn default() -> Self {
        Self {
            samples: [T::default(); RIGHT_STICK_HISTORY_CAPACITY],
            head: 0,
            len: 0,
        }
    }
}

impl<T: Copy + Default> History201<T> {
    pub fn push_front(&mut self, sample: T) {
        self.head = if self.len == 0 {
            0
        } else {
            (self.head + RIGHT_STICK_HISTORY_CAPACITY - 1) % RIGHT_STICK_HISTORY_CAPACITY
        };
        self.samples[self.head] = sample;
        self.len = (self.len + 1).min(RIGHT_STICK_HISTORY_CAPACITY);
    }

    pub const fn len(&self) -> usize {
        self.len
    }

    pub const fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Returns a sample by age: zero is newest, one is the preceding sample.
    pub fn get(&self, age: usize) -> Option<T> {
        if age >= self.len {
            return None;
        }
        Some(self.samples[(self.head + age) % RIGHT_STICK_HISTORY_CAPACITY])
    }
}

/// TU3's exact mathematical radial transform at `0x8296_D5F8`.
///
/// The native VMX implementation obtains the reciprocal square root from an
/// estimate plus two Newton refinements. This implementation uses `f32::sqrt`,
/// so its mathematical result is equivalent but bit-identical PPC rounding is
/// explicitly not claimed.
pub fn normalize_raw_axis_pair(x: i16, y: i16) -> Stick2 {
    let input = Stick2::new(x as f32 * RAW_AXIS_SCALE, y as f32 * RAW_AXIS_SCALE);
    let magnitude = input.length();
    if magnitude < RADIAL_ZERO_EPSILON {
        return Stick2::ZERO;
    }

    let gain = ((magnitude - RADIAL_DEADZONE) * RADIAL_GAIN).clamp(0.0, 1.0) / magnitude;
    Stick2::new(input.x * gain, input.y * gain)
}

/// Convert a processed XInput right stick into Skate 3's PatternNode basis.
///
/// XInput, the toolkit injection pipe, and the game's processed input channels
/// retain the hardware Y sign: down is negative and up is positive. The
/// recovered native recognizer caller reflects Y once before constructing its
/// PatternNode sample, while preserving X.
pub fn raw_right_stick_to_pattern_node(x: i16, y: i16) -> Stick2 {
    let normalized = normalize_raw_axis_pair(x, y);
    Stick2::new(normalized.x, -normalized.y)
}

/// Applies the independent component filter used immediately before the
/// recognizer at `0x8269_62D8`. The comparison is strict: exactly `0.1` survives.
pub fn filter_recognizer_components(sample: Stick2) -> Stick2 {
    Stick2::new(
        if sample.x.abs() < COMPONENT_FILTER_THRESHOLD {
            0.0
        } else {
            sample.x
        },
        if sample.y.abs() < COMPONENT_FILTER_THRESHOLD {
            0.0
        } else {
            sample.y
        },
    )
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum InputLane {
    LeftStick,
    RightStick,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum PatternSource {
    Skater,
    Skater90,
    SkaterNegative90,
    SkaterAir,
    SkaterFingerflip,
    SkaterLeftStick,
    SkaterStep,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PatternContext {
    Ground,
    GroundNinety,
    GroundNegativeNinety,
    Air,
    Fingerflip,
}

impl PatternContext {
    pub const fn source(self) -> PatternSource {
        match self {
            Self::Ground => PatternSource::Skater,
            Self::GroundNinety => PatternSource::Skater90,
            Self::GroundNegativeNinety => PatternSource::SkaterNegative90,
            Self::Air => PatternSource::SkaterAir,
            Self::Fingerflip => PatternSource::SkaterFingerflip,
        }
    }
}

impl PatternSource {
    pub const ALL: [Self; 7] = [
        Self::Skater,
        Self::Skater90,
        Self::SkaterNegative90,
        Self::SkaterAir,
        Self::SkaterFingerflip,
        Self::SkaterLeftStick,
        Self::SkaterStep,
    ];

    pub const fn file_name(self) -> &'static str {
        match self {
            Self::Skater => "skater.pat",
            Self::Skater90 => "skater90.pat",
            Self::SkaterNegative90 => "skaterN90.pat",
            Self::SkaterAir => "skater_air.pat",
            Self::SkaterFingerflip => "skater_fingerflip.pat",
            Self::SkaterLeftStick => "skaterls.pat",
            Self::SkaterStep => "skaterstep.pat",
        }
    }

    pub const fn lane(self) -> InputLane {
        match self {
            Self::SkaterLeftStick | Self::SkaterStep => InputLane::LeftStick,
            _ => InputLane::RightStick,
        }
    }

    pub const fn retail_text(self) -> &'static str {
        match self {
            Self::Skater => include_str!(env!("SKATE3_SKATER_PAT")),
            Self::Skater90 => include_str!(env!("SKATE3_SKATER90_PAT")),
            Self::SkaterNegative90 => include_str!(env!("SKATE3_SKATERN90_PAT")),
            Self::SkaterAir => include_str!(env!("SKATE3_SKATER_AIR_PAT")),
            Self::SkaterFingerflip => include_str!(env!("SKATE3_SKATER_FINGERFLIP_PAT")),
            Self::SkaterLeftStick => include_str!(env!("SKATE3_SKATER_LS_PAT")),
            Self::SkaterStep => include_str!(env!("SKATE3_SKATER_STEP_PAT")),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ParsedButUnusedGlobal {
    pub parsed_value: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PatternGlobals {
    pub tolerance_dist: f32,
    /// Parsed by TU3, but no resulting store/use was found in the generated code.
    pub tolerance_time: ParsedButUnusedGlobal,
    /// Parsed by TU3, but no resulting store/use was found in the generated code.
    pub tolerance_speed: ParsedButUnusedGlobal,
    /// Parsed by TU3, but no resulting store/use was found in the generated code.
    pub anticipation_delay: ParsedButUnusedGlobal,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PatternCoordinate {
    pub position: Stick2,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PatternTemplate {
    pub name: String,
    pub tolerance_dist: f32,
    pub tolerance_squared: f32,
    pub coordinates: Vec<PatternCoordinate>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PatternFile {
    pub source: PatternSource,
    pub globals: PatternGlobals,
    pub patterns: Vec<PatternTemplate>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PatternParseError {
    pub source: PatternSource,
    pub line: usize,
    pub detail: String,
}

impl fmt::Display for PatternParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}:{}: {}",
            self.source.file_name(),
            self.line,
            self.detail
        )
    }
}

impl std::error::Error for PatternParseError {}

#[derive(Default)]
struct PatternBuilder {
    name: String,
    tolerance_dist: Option<f32>,
    coordinates: Vec<PatternCoordinate>,
}

fn parse_f32(
    source: PatternSource,
    line: usize,
    token: Option<&str>,
    field: &str,
) -> Result<f32, PatternParseError> {
    token
        .ok_or_else(|| PatternParseError {
            source,
            line,
            detail: format!("missing {field}"),
        })?
        .parse::<f32>()
        .map_err(|error| PatternParseError {
            source,
            line,
            detail: format!("invalid {field}: {error}"),
        })
}

fn finish_pattern(
    source: PatternSource,
    line: usize,
    global_tolerance: Option<f32>,
    current: &mut Option<PatternBuilder>,
    output: &mut Vec<PatternTemplate>,
) -> Result<(), PatternParseError> {
    let Some(builder) = current.take() else {
        return Ok(());
    };
    let tolerance_dist =
        builder
            .tolerance_dist
            .or(global_tolerance)
            .ok_or_else(|| PatternParseError {
                source,
                line,
                detail: format!("pattern {} has no tolerance", builder.name),
            })?;
    if builder.coordinates.is_empty() {
        return Err(PatternParseError {
            source,
            line,
            detail: format!("pattern {} has no coordinates", builder.name),
        });
    }
    output.push(PatternTemplate {
        name: builder.name,
        tolerance_dist,
        tolerance_squared: tolerance_dist * tolerance_dist,
        coordinates: builder.coordinates,
    });
    Ok(())
}

pub fn parse_pattern_file(
    source: PatternSource,
    text: &str,
) -> Result<PatternFile, PatternParseError> {
    let mut global_dist = None;
    let mut global_time = None;
    let mut global_speed = None;
    let mut anticipation_delay = None;
    let mut current = None;
    let mut patterns = Vec::new();
    let mut last_line = 0;

    for (zero_based_line, raw_line) in text.lines().enumerate() {
        let line = zero_based_line + 1;
        last_line = line;
        let trimmed = raw_line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let mut fields = trimmed.split_whitespace();
        let keyword = fields.next().unwrap_or_default();
        match keyword {
            "global_tolerance_dist" => {
                global_dist = Some(parse_f32(
                    source,
                    line,
                    fields.next(),
                    "global_tolerance_dist",
                )?);
            }
            "global_tolerance_time" => {
                global_time = Some(parse_f32(
                    source,
                    line,
                    fields.next(),
                    "global_tolerance_time",
                )?);
            }
            "global_tolerance_speed" => {
                global_speed = Some(parse_f32(
                    source,
                    line,
                    fields.next(),
                    "global_tolerance_speed",
                )?);
            }
            "global_anticipation_delay" => {
                anticipation_delay = Some(parse_f32(
                    source,
                    line,
                    fields.next(),
                    "global_anticipation_delay",
                )?);
            }
            "pattern" => {
                finish_pattern(source, line, global_dist, &mut current, &mut patterns)?;
                let name = fields.next().ok_or_else(|| PatternParseError {
                    source,
                    line,
                    detail: "pattern has no name".to_owned(),
                })?;
                current = Some(PatternBuilder {
                    name: name.to_owned(),
                    ..PatternBuilder::default()
                });
            }
            "tolerance_dist" => {
                let value = parse_f32(source, line, fields.next(), "tolerance_dist")?;
                current
                    .as_mut()
                    .ok_or_else(|| PatternParseError {
                        source,
                        line,
                        detail: "tolerance_dist outside a pattern".to_owned(),
                    })?
                    .tolerance_dist = Some(value);
            }
            "coord" => {
                let x = parse_f32(source, line, fields.next(), "coord x")?;
                let y = parse_f32(source, line, fields.next(), "coord y")?;
                current
                    .as_mut()
                    .ok_or_else(|| PatternParseError {
                        source,
                        line,
                        detail: "coord outside a pattern".to_owned(),
                    })?
                    .coordinates
                    .push(PatternCoordinate {
                        position: Stick2::new(x, y),
                    });
            }
            // The retail parser accepts these keywords, but none of the seven
            // supplied files use them and their runtime semantics have not been
            // recovered sufficiently to implement without guessing.
            "clock" | "min_time" => {
                return Err(PatternParseError {
                    source,
                    line,
                    detail: format!("{keyword} syntax is accepted by TU3 but remains unresolved"),
                });
            }
            _ => {
                return Err(PatternParseError {
                    source,
                    line,
                    detail: format!("unknown keyword {keyword:?}"),
                });
            }
        }
    }

    finish_pattern(
        source,
        last_line.saturating_add(1),
        global_dist,
        &mut current,
        &mut patterns,
    )?;

    let required = |value: Option<f32>, name: &str| {
        value.ok_or_else(|| PatternParseError {
            source,
            line: 0,
            detail: format!("missing {name}"),
        })
    };
    Ok(PatternFile {
        source,
        globals: PatternGlobals {
            tolerance_dist: required(global_dist, "global_tolerance_dist")?,
            tolerance_time: ParsedButUnusedGlobal {
                parsed_value: required(global_time, "global_tolerance_time")?,
            },
            tolerance_speed: ParsedButUnusedGlobal {
                parsed_value: required(global_speed, "global_tolerance_speed")?,
            },
            anticipation_delay: ParsedButUnusedGlobal {
                parsed_value: required(anticipation_delay, "global_anticipation_delay")?,
            },
        },
        patterns,
    })
}

#[derive(Clone, Debug, PartialEq)]
pub struct RetailPatternDatabase {
    pub files: Vec<PatternFile>,
}

impl RetailPatternDatabase {
    pub fn load_embedded() -> Result<Self, PatternParseError> {
        let mut files = Vec::with_capacity(PatternSource::ALL.len());
        for source in PatternSource::ALL {
            files.push(parse_pattern_file(source, source.retail_text())?);
        }
        Ok(Self { files })
    }

    pub fn pattern(&self, id: PatternId) -> Option<&PatternTemplate> {
        self.files
            .iter()
            .find(|file| file.source == id.source)
            .and_then(|file| file.patterns.get(id.index))
    }

    pub fn pattern_count_for_lane(&self, lane: InputLane) -> usize {
        self.files
            .iter()
            .filter(|file| file.source.lane() == lane)
            .map(|file| file.patterns.len())
            .sum()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct PatternId {
    pub source: PatternSource,
    pub index: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GeometryCandidate {
    pub id: PatternId,
    pub name: String,
    /// One age per pattern coordinate. Coordinate zero is the oldest part of the
    /// gesture, and the final coordinate always has age zero.
    pub matched_ages: Vec<usize>,
}

/// A caller-owned snapshot of TU3's 32-byte `PatternNode`.
///
/// The packed word is stored at node offset `+0x04`; accumulated squared
/// distance is stored at `+0x08`. Field names deliberately describe bit
/// locations until all producer-side meanings at `0x8269_74A8` are proven.
#[derive(Clone, Debug, PartialEq)]
pub struct RetailPatternNodeSnapshot {
    pub id: PatternId,
    pub packed_word: u32,
    pub accumulated_distance_squared: f32,
}

impl RetailPatternNodeSnapshot {
    /// Candidate-complete flag consumed by `0x8269_72B8`.
    pub const fn candidate_complete(&self) -> bool {
        self.packed_word & (1 << 30) != 0
    }

    /// Field extracted by `rlwinm ...,26,28,31`.
    pub const fn field_06_09(&self) -> u32 {
        (self.packed_word >> 6) & 0x0f
    }

    /// Field extracted by `rlwinm ...,22,26,31`.
    pub const fn field_10_15(&self) -> u32 {
        (self.packed_word >> 10) & 0x3f
    }

    /// Field extracted by `rlwinm ...,16,22,31`.
    pub const fn field_16_25(&self) -> u32 {
        (self.packed_word >> 16) & 0x03ff
    }

    /// Field extracted by `rlwinm ...,6,28,31`.
    pub const fn field_26_29(&self) -> u32 {
        (self.packed_word >> 26) & 0x0f
    }

    /// Ten-bit value copied to match-result field `+0x0C`.
    ///
    /// TU3 uses big-endian `lhz +0x04`, then masks the loaded high halfword to
    /// ten bits. This is the same packed field as [`Self::field_16_25`].
    pub const fn result_field_16_25(&self) -> u32 {
        self.field_16_25()
    }
}

/// Exact producer-side state for one TU3 PatternNode.
#[derive(Clone, Debug, PartialEq)]
pub struct RetailPatternNodeState {
    pub id: PatternId,
    packed_word: u32,
    accumulated_distance_squared: f32,
}

impl RetailPatternNodeState {
    pub fn new(id: PatternId, pattern: &PatternTemplate) -> Self {
        let coordinate_count = pattern.coordinates.len() as u32;
        Self {
            id,
            packed_word: ((coordinate_count.wrapping_sub(1) & 0x0f) << 26)
                | ((coordinate_count & 0x0f) << 6),
            accumulated_distance_squared: 0.0,
        }
    }

    pub const fn snapshot(&self) -> RetailPatternNodeSnapshot {
        RetailPatternNodeSnapshot {
            id: self.id,
            packed_word: self.packed_word,
            accumulated_distance_squared: self.accumulated_distance_squared,
        }
    }

    pub fn reset(&mut self, pattern: &PatternTemplate) {
        *self = Self::new(self.id, pattern);
    }

    pub const fn active(&self) -> bool {
        self.packed_word & (1 << 31) != 0
    }

    pub const fn complete(&self) -> bool {
        self.packed_word & (1 << 30) != 0
    }

    pub const fn coordinate_count(&self) -> u32 {
        (self.packed_word >> 6) & 0x0f
    }

    pub const fn consecutive_gap_samples(&self) -> u32 {
        (self.packed_word >> 10) & 0x3f
    }

    pub const fn sampled_span(&self) -> u32 {
        (self.packed_word >> 16) & 0x03ff
    }

    pub const fn coordinate_index(&self) -> u32 {
        (self.packed_word >> 26) & 0x0f
    }

    fn set_coordinate_index(&mut self, value: u32) {
        self.packed_word = (self.packed_word & !(0x0f << 26)) | ((value & 0x0f) << 26);
    }

    fn set_consecutive_gap_samples(&mut self, value: u32) {
        self.packed_word = (self.packed_word & !(0x3f << 10)) | ((value & 0x3f) << 10);
    }

    fn set_sampled_span(&mut self, value: u32) {
        self.packed_word = (self.packed_word & !(0x03ff << 16)) | ((value & 0x03ff) << 16);
    }

    fn increment_span(&mut self) {
        self.set_sampled_span(self.sampled_span().wrapping_add(1));
    }

    fn reset_after_gap(&mut self) {
        // Exact mask at 0x8269_75B0: preserve coordinate index/count and
        // low six bits, clear active/complete/span/gap.
        self.packed_word &= 0x3c00_03ff;
        self.accumulated_distance_squared = 0.0;
    }

    /// Advances one node exactly as `0x8269_74A8`.
    ///
    /// `maximum_gap_samples` is the byte read from the recognizer attribute
    /// object at matcher-config offset `+0x21`. Retail callers should pass
    /// [`RETAIL_PATTERN_MAXIMUM_GAP_SAMPLES`]; keeping this argument explicit
    /// permits deterministic comparison against instrumented captures.
    pub fn advance(&mut self, pattern: &PatternTemplate, sample: Stick2, maximum_gap_samples: u8) {
        if self.complete() {
            return;
        }

        let tolerance = pattern.tolerance_squared;
        if !self.active() {
            // The loader pushes every file-order coordinate to the front of
            // the ring. The ring's last element is therefore file coordinate
            // zero, which PatternNode initialization copies to +0x10.
            let Some(first_file_coordinate) = pattern.coordinates.first() else {
                return;
            };
            let distance = first_file_coordinate.position.distance_squared(sample);
            if distance > tolerance {
                return;
            }
            self.accumulated_distance_squared = distance;
            self.packed_word &= 0x3c00_03ff;
            self.packed_word |= 1 << 31;
            self.set_coordinate_index(self.coordinate_count().wrapping_sub(2));
            self.set_sampled_span(1);
            return;
        }

        let index = self.coordinate_index() as usize;
        let ring_coordinate = |ring_index: usize| {
            pattern
                .coordinates
                .len()
                .checked_sub(ring_index + 1)
                .and_then(|file_index| pattern.coordinates.get(file_index))
        };
        let Some(current) = ring_coordinate(index) else {
            return;
        };
        let current_distance = current.position.distance_squared(sample);
        if current_distance <= tolerance {
            self.accumulated_distance_squared += current_distance;
            self.increment_span();
            if index == 0 {
                self.packed_word |= 1 << 30;
            } else {
                self.set_coordinate_index((index - 1) as u32);
                self.set_consecutive_gap_samples(0);
            }
            return;
        }

        let count = self.coordinate_count() as usize;
        let remains_near_previously_matched_coordinate = count.wrapping_sub(index) == 2
            && ring_coordinate(index + 1)
                .is_some_and(|previous| previous.position.distance_squared(sample) <= tolerance);
        if !remains_near_previously_matched_coordinate {
            self.increment_span();
            self.set_consecutive_gap_samples(self.consecutive_gap_samples().wrapping_add(1));
        }
        if self.consecutive_gap_samples() > u32::from(maximum_gap_samples) {
            self.reset_after_gap();
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RetailPatternWinner {
    pub id: PatternId,
    /// Internal score used only to select the winner. TU3 does not publish it.
    pub arbitration_score: f32,
    /// Match-result field `+0x04`.
    pub quality: f32,
    /// Match-result field `+0x08`.
    pub accumulated_distance_squared: f32,
    /// Match-result field `+0x0C`.
    pub result_field_16_25: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnresolvedSemantic {
    /// Meanings of the three numeric match-result fields delivered with a name.
    MatchResultMetrics,
    /// The mapping between SK8 Oracle/render/simulation steps and upstream TU3
    /// input notifications is coalesced and has not been reduced to a fixed
    /// ratio. The recognizer-side cadence itself is exact and caller-driven:
    /// one sample is pushed per `0x82859E70 -> 0x82696030 -> 0x826962D8`
    /// notification path.
    RecognizerSampleCadence,
    /// PPC reciprocal-square-root estimate/refinement may differ in final bits.
    ExactPpcVectorRounding,
    /// Retail files do not exercise parser `clock` or `min_time` directives.
    ClockAndMinimumTimeDirectives,
    /// Projection from the sampled stick vector into AG `AnticMag`/`AnticAngle`.
    AnticipationIntentProjection,
}

#[derive(Clone, Debug, PartialEq)]
pub enum PopRecognition {
    NoGeometryCandidate,
    GeometryCandidates {
        candidates: Vec<GeometryCandidate>,
        publication_blocked_by: UnresolvedSemantic,
    },
}

fn ordered_geometry_match(
    history: &History201<Stick2>,
    pattern: &PatternTemplate,
) -> Option<Vec<usize>> {
    let final_coordinate = pattern.coordinates.last()?.position;
    let newest = history.get(0)?;
    if newest.distance_squared(final_coordinate) > pattern.tolerance_squared {
        return None;
    }

    let mut reverse_ages = Vec::with_capacity(pattern.coordinates.len());
    reverse_ages.push(0);
    let mut minimum_age = 1;
    for coordinate in pattern.coordinates[..pattern.coordinates.len() - 1]
        .iter()
        .rev()
    {
        let mut found = None;
        for age in minimum_age..history.len() {
            let sample = history.get(age).expect("age is inside history length");
            if sample.distance_squared(coordinate.position) <= pattern.tolerance_squared {
                found = Some(age);
                break;
            }
        }
        let age = found?;
        reverse_ages.push(age);
        minimum_age = age + 1;
    }
    reverse_ages.reverse();
    Some(reverse_ages)
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AnticipationSignal {
    pub magnitude: f32,
    pub angle_radians: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnticipationIdentity {
    Ollie,
    PopShuvit,
    FsPopShuvit,
    ThreeSixtyPopShuvit,
    FsThreeSixtyPopShuvit,
    Nollie,
    NolliePopShuvit,
    NollieFsPopShuvit,
    NollieThreeSixtyPopShuvit,
    NollieFsThreeSixtyPopShuvit,
}

impl AnticipationIdentity {
    fn mirrored(self, mirror_state: MirrorState) -> Self {
        if !mirror_state.is_mirrored() {
            return self;
        }
        match self {
            Self::PopShuvit => Self::FsPopShuvit,
            Self::FsPopShuvit => Self::PopShuvit,
            Self::ThreeSixtyPopShuvit => Self::FsThreeSixtyPopShuvit,
            Self::FsThreeSixtyPopShuvit => Self::ThreeSixtyPopShuvit,
            Self::NolliePopShuvit => Self::NollieFsPopShuvit,
            Self::NollieFsPopShuvit => Self::NolliePopShuvit,
            Self::NollieThreeSixtyPopShuvit => Self::NollieFsThreeSixtyPopShuvit,
            Self::NollieFsThreeSixtyPopShuvit => Self::NollieThreeSixtyPopShuvit,
            Self::Ollie | Self::Nollie => self,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum AnticipationClassification {
    Inactive {
        magnitude: f32,
    },
    Classified {
        identity: AnticipationIdentity,
        magnitude: f32,
        angle_radians: f32,
    },
    /// Inclusive XML comparisons make exact shared sector boundaries satisfy two
    /// states. ActionGraph state arbitration has not been assumed here.
    AmbiguousBoundary {
        candidates: Vec<AnticipationIdentity>,
        magnitude: f32,
        angle_radians: f32,
    },
    InvalidSignal,
    MissingRecoveredProjection {
        unresolved: UnresolvedSemantic,
    },
}

/// Classifies the already-published AG `AnticMag` and `AnticAngle` values using
/// `onground.xml`. The `> 0.9` magnitude gate and all angular comparisons match
/// the XML. Exact shared boundaries are reported as ambiguous because the
/// comparisons on both adjoining states are inclusive.
pub fn classify_anticipation(
    signal: AnticipationSignal,
    mirror_state: MirrorState,
) -> AnticipationClassification {
    if !signal.magnitude.is_finite() || !signal.angle_radians.is_finite() {
        return AnticipationClassification::InvalidSignal;
    }
    if signal.magnitude <= ANTICIPATION_MAGNITUDE_GATE {
        return AnticipationClassification::Inactive {
            magnitude: signal.magnitude,
        };
    }

    let angle = signal.angle_radians;
    let mut candidates = Vec::with_capacity(2);
    if angle.abs() <= 0.52 {
        candidates.push(AnticipationIdentity::Ollie);
    }
    if (-1.05..=-0.52).contains(&angle) {
        candidates.push(AnticipationIdentity::PopShuvit);
    }
    if (0.52..=1.05).contains(&angle) {
        candidates.push(AnticipationIdentity::FsPopShuvit);
    }
    if (-1.57..=-1.05).contains(&angle) {
        candidates.push(AnticipationIdentity::ThreeSixtyPopShuvit);
    }
    if (1.05..=1.57).contains(&angle) {
        candidates.push(AnticipationIdentity::FsThreeSixtyPopShuvit);
    }
    if angle.abs() >= 2.62 {
        candidates.push(AnticipationIdentity::Nollie);
    }
    if (-2.62..=-2.09).contains(&angle) {
        candidates.push(AnticipationIdentity::NolliePopShuvit);
    }
    if (2.09..=2.62).contains(&angle) {
        candidates.push(AnticipationIdentity::NollieFsPopShuvit);
    }
    if (-2.09..=-1.57).contains(&angle) {
        candidates.push(AnticipationIdentity::NollieThreeSixtyPopShuvit);
    }
    if (1.57..=2.09).contains(&angle) {
        candidates.push(AnticipationIdentity::NollieFsThreeSixtyPopShuvit);
    }

    for candidate in &mut candidates {
        *candidate = candidate.mirrored(mirror_state);
    }
    candidates.dedup();

    match candidates.as_slice() {
        [identity] => AnticipationClassification::Classified {
            identity: *identity,
            magnitude: signal.magnitude,
            angle_radians: angle,
        },
        [] => AnticipationClassification::InvalidSignal,
        _ => AnticipationClassification::AmbiguousBoundary {
            candidates,
            magnitude: signal.magnitude,
            angle_radians: angle,
        },
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GestureGroup {
    Square,
    Nose,
    Tail,
    NinetyNose,
    NinetyTail,
    NegativeNinetyNose,
    NegativeNinetyTail,
}

impl GestureGroup {
    /// Exact enum-to-physical-table remap recovered from `GetGestureIntents`.
    pub const fn physical_table(self) -> usize {
        match self {
            Self::Square => 6,
            Self::Nose => 0,
            Self::Tail => 1,
            Self::NinetyNose => 2,
            Self::NinetyTail => 3,
            Self::NegativeNinetyNose => 4,
            Self::NegativeNinetyTail => 5,
        }
    }

    pub const fn record_count(self) -> usize {
        match self {
            Self::Square | Self::Nose | Self::Tail => 30,
            Self::NinetyNose
            | Self::NinetyTail
            | Self::NegativeNinetyNose
            | Self::NegativeNinetyTail => 45,
        }
    }
}

/// Exact recovered source for all 270 gesture-to-trick mapping records.
///
/// The typed loader below deliberately reads the evidence artifact rather than
/// duplicating thousands of string bytes by hand.
pub const GESTURE_TRICK_MAPPING_RECORDS_JSON: &str =
    include_str!(env!("SKATE3_GESTURE_TRICK_MAPPING_JSON"));

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecoveredTrickIdentityDescriptor {
    pub record_index: usize,
    pub group: GestureGroup,
    pub physical_table: usize,
    pub gesture_key: String,
    pub primary: String,
    pub secondary: String,
    /// The recovered trailing word is deliberately kept opaque.
    pub selector_code: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct IdentityTableParseError {
    pub detail: String,
}

impl fmt::Display for IdentityTableParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.detail)
    }
}

impl std::error::Error for IdentityTableParseError {}

fn json_unsigned(chunk: &str, key: &str) -> Result<usize, IdentityTableParseError> {
    let start = chunk
        .find(key)
        .map(|offset| offset + key.len())
        .ok_or_else(|| IdentityTableParseError {
            detail: format!("mapping record is missing {key}"),
        })?;
    let digits = chunk[start..].trim_start();
    let end = digits
        .find(|character: char| !character.is_ascii_digit())
        .unwrap_or(digits.len());
    digits[..end]
        .parse::<usize>()
        .map_err(|error| IdentityTableParseError {
            detail: format!("invalid integer after {key}: {error}"),
        })
}

fn json_object_text(chunk: &str, object_key: &str) -> Result<String, IdentityTableParseError> {
    let object_start = chunk
        .find(object_key)
        .map(|offset| offset + object_key.len())
        .ok_or_else(|| IdentityTableParseError {
            detail: format!("mapping record is missing {object_key}"),
        })?;
    let object = &chunk[object_start..];
    let text_key = "\"text\": \"";
    let text_start = object
        .find(text_key)
        .map(|offset| offset + text_key.len())
        .ok_or_else(|| IdentityTableParseError {
            detail: format!("mapping record {object_key} has no text"),
        })?;
    let encoded = &object[text_start..];
    let text_end = encoded.find('"').ok_or_else(|| IdentityTableParseError {
        detail: format!("mapping record {object_key} text is unterminated"),
    })?;
    if encoded[..text_end].contains('\\') {
        return Err(IdentityTableParseError {
            detail: format!("mapping record {object_key} contains an unimplemented JSON escape"),
        });
    }
    Ok(encoded[..text_end].to_owned())
}

fn gesture_group_from_recovered_enum(
    value: usize,
) -> Result<GestureGroup, IdentityTableParseError> {
    match value {
        0 => Ok(GestureGroup::Square),
        1 => Ok(GestureGroup::Nose),
        2 => Ok(GestureGroup::Tail),
        3 => Ok(GestureGroup::NinetyNose),
        4 => Ok(GestureGroup::NinetyTail),
        5 => Ok(GestureGroup::NegativeNinetyNose),
        6 => Ok(GestureGroup::NegativeNinetyTail),
        _ => Err(IdentityTableParseError {
            detail: format!("unknown recovered gesture enum {value}"),
        }),
    }
}

/// Loads all 270 exact mapping records recovered from
/// `GestureTrickMapping::Init` (`0x82B9_8F70`).
pub fn load_recovered_identity_table()
-> Result<Vec<RecoveredTrickIdentityDescriptor>, IdentityTableParseError> {
    let records_marker = "\"records\": [";
    let records = GESTURE_TRICK_MAPPING_RECORDS_JSON
        .split_once(records_marker)
        .map(|(_, records)| records)
        .ok_or_else(|| IdentityTableParseError {
            detail: "mapping evidence has no records array".to_owned(),
        })?;
    let record_marker = "\"record_index\":";
    let mut output = Vec::with_capacity(270);
    let mut remaining = records;

    while let Some(start) = remaining.find(record_marker) {
        let record_and_rest = &remaining[start..];
        let next = record_and_rest[record_marker.len()..]
            .find(record_marker)
            .map(|offset| offset + record_marker.len())
            .unwrap_or(record_and_rest.len());
        let chunk = &record_and_rest[..next];
        let group = gesture_group_from_recovered_enum(json_unsigned(chunk, "\"enum_group\":")?)?;
        let physical_table = json_unsigned(chunk, "\"physical_table\":")?;
        if physical_table != group.physical_table() {
            return Err(IdentityTableParseError {
                detail: format!(
                    "enum/physical table mismatch: {:?} maps to {}, record says {}",
                    group,
                    group.physical_table(),
                    physical_table
                ),
            });
        }
        output.push(RecoveredTrickIdentityDescriptor {
            record_index: json_unsigned(chunk, record_marker)?,
            group,
            physical_table,
            gesture_key: json_object_text(chunk, "\"gesture_key\":")?,
            primary: json_object_text(chunk, "\"primary\":")?,
            secondary: json_object_text(chunk, "\"secondary\":")?,
            selector_code: json_unsigned(chunk, "\"trailing_word\":")? as u32,
        });
        remaining = &record_and_rest[next..];
    }

    if output.len() != 270 {
        return Err(IdentityTableParseError {
            detail: format!("expected 270 mapping records, found {}", output.len()),
        });
    }
    for (expected, record) in output.iter().enumerate() {
        if record.record_index != expected {
            return Err(IdentityTableParseError {
                detail: format!(
                    "mapping record order discontinuity: expected {expected}, found {}",
                    record.record_index
                ),
            });
        }
    }
    Ok(output)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PopFoot {
    Tail,
    Nose,
}

/// A typed form of the 52-byte gesture mapping record: two 24-byte game-string
/// descriptors followed by an opaque word. `selector_code` is intentionally not
/// assigned a stronger semantic name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TrickIdentityDescriptor {
    pub gesture_key: &'static str,
    pub primary: &'static str,
    pub secondary: &'static str,
    pub selector_code: u32,
    pub pop_foot: PopFoot,
}

const fn identity(
    gesture_key: &'static str,
    primary: &'static str,
    secondary: &'static str,
    selector_code: u32,
    pop_foot: PopFoot,
) -> TrickIdentityDescriptor {
    TrickIdentityDescriptor {
        gesture_key,
        primary,
        secondary,
        selector_code,
        pop_foot,
    }
}

/// Exact 30-record Square gesture table. Tail/nose identity is encoded here and
/// remains independent of regular/switch mirroring.
pub const SQUARE_TRICK_IDENTITIES: [TrickIdentityDescriptor; 30] = [
    identity("Ollie", "Ollie", "Ollie", 1, PopFoot::Tail),
    identity("PopShuvit", "PopShuvit", "FSPopShuvit", 1, PopFoot::Tail),
    identity("FSPopShuvit", "FSPopShuvit", "PopShuvit", 2, PopFoot::Tail),
    identity(
        "VarialKickflip",
        "VarialKickflip",
        "VarialHeelflip",
        1,
        PopFoot::Tail,
    ),
    identity(
        "VarialHeelflip",
        "VarialHeelflip",
        "VarialKickflip",
        2,
        PopFoot::Tail,
    ),
    identity("Hardflip", "Hardflip", "InwardHeelflip", 1, PopFoot::Tail),
    identity(
        "InwardHeelflip",
        "InwardHeelflip",
        "Hardflip",
        2,
        PopFoot::Tail,
    ),
    identity(
        "360PopShuvit",
        "360PopShuvit",
        "FS360PopShuvit",
        1,
        PopFoot::Tail,
    ),
    identity(
        "FS360PopShuvit",
        "FS360PopShuvit",
        "360PopShuvit",
        2,
        PopFoot::Tail,
    ),
    identity("360Flip", "360Flip", "Laserflip", 0, PopFoot::Tail),
    identity("Laserflip", "Laserflip", "360Flip", 0, PopFoot::Tail),
    identity(
        "360Hardflip",
        "360Hardflip",
        "360InwardHeelflip",
        0,
        PopFoot::Tail,
    ),
    identity(
        "360InwardHeelflip",
        "360InwardHeelflip",
        "360Hardflip",
        0,
        PopFoot::Tail,
    ),
    identity("Kickflip", "Kickflip", "Heelflip", 0, PopFoot::Tail),
    identity("Heelflip", "Heelflip", "Kickflip", 0, PopFoot::Tail),
    identity("Nollie", "Nollie", "Nollie", 3, PopFoot::Nose),
    identity(
        "N_PopShuvit",
        "N_PopShuvit",
        "N_FSPopShuvit",
        3,
        PopFoot::Nose,
    ),
    identity(
        "N_FSPopShuvit",
        "N_FSPopShuvit",
        "N_PopShuvit",
        4,
        PopFoot::Nose,
    ),
    identity(
        "N_VarialKickflip",
        "N_VarialKickflip",
        "N_VarialHeelflip",
        3,
        PopFoot::Nose,
    ),
    identity(
        "N_VarialHeelflip",
        "N_VarialHeelflip",
        "N_VarialKickflip",
        4,
        PopFoot::Nose,
    ),
    identity(
        "N_Hardflip",
        "N_Hardflip",
        "N_InwardHeelflip",
        3,
        PopFoot::Nose,
    ),
    identity(
        "N_InwardHeelflip",
        "N_InwardHeelflip",
        "N_Hardflip",
        4,
        PopFoot::Nose,
    ),
    identity(
        "N_360PopShuvit",
        "N_360PopShuvit",
        "N_FS360PopShuvit",
        3,
        PopFoot::Nose,
    ),
    identity(
        "N_FS360PopShuvit",
        "N_FS360PopShuvit",
        "N_360PopShuvit",
        4,
        PopFoot::Nose,
    ),
    identity("N_360Flip", "N_360Flip", "N_Laserflip", 0, PopFoot::Nose),
    identity("N_Laserflip", "N_Laserflip", "N_360Flip", 0, PopFoot::Nose),
    identity(
        "N_360Hardflip",
        "N_360Hardflip",
        "N_360InwardHeelflip",
        0,
        PopFoot::Nose,
    ),
    identity(
        "N_360InwardHeelflip",
        "N_360InwardHeelflip",
        "N_360Hardflip",
        0,
        PopFoot::Nose,
    ),
    identity("N_Kickflip", "N_Kickflip", "N_Heelflip", 0, PopFoot::Nose),
    identity("N_Heelflip", "N_Heelflip", "N_Kickflip", 0, PopFoot::Nose),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ResolvedTrickIdentity {
    pub gesture_key: &'static str,
    pub selected_name: &'static str,
    pub selector_code: u32,
    pub pop_foot: PopFoot,
    pub mirror_state: MirrorState,
}

/// Reproduces the recovered `IsMirrored && !DontMirrorTrick` choice in
/// `CreateTrickIntentFromGesture::Begin`.
pub fn resolve_trick_identity(
    descriptor: TrickIdentityDescriptor,
    mirror_state: MirrorState,
    dont_mirror_trick: bool,
) -> ResolvedTrickIdentity {
    let selected_name = if mirror_state.is_mirrored() && !dont_mirror_trick {
        descriptor.secondary
    } else {
        descriptor.primary
    };
    ResolvedTrickIdentity {
        gesture_key: descriptor.gesture_key,
        selected_name,
        selector_code: descriptor.selector_code,
        pop_foot: descriptor.pop_foot,
        mirror_state,
    }
}

pub fn square_identity_for_gesture(gesture_key: &str) -> Option<TrickIdentityDescriptor> {
    SQUARE_TRICK_IDENTITIES
        .iter()
        .copied()
        .find(|descriptor| descriptor.gesture_key == gesture_key)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MatcherMode {
    Default,
    ModeTwo,
}

/// Exact match-quality curve consumed after arbitration at `0x8269_72B8`.
pub fn score_ratio(mode: MatcherMode, ratio: f32) -> f32 {
    let (low, high) = match mode {
        MatcherMode::Default => (1.75, 4.4),
        MatcherMode::ModeTwo => (1.5, 3.0),
    };
    if ratio <= low {
        1.0
    } else if ratio >= high {
        0.0
    } else {
        (high - ratio) / (high - low)
    }
}

/// Exact internal winner score at `0x8269_72B8`.
///
/// Eligible nodes use:
///
/// `field_06_09^4 / (min(max(0.15, error) / field_06_09, 0.15) * field_16_25)`
///
/// TU3's data guarantees non-zero divisor fields for completed candidates.
/// This function intentionally preserves IEEE infinity/NaN behavior for raw
/// telemetry snapshots instead of substituting invented validation policy.
pub fn retail_candidate_arbitration_score(node: &RetailPatternNodeSnapshot) -> f32 {
    let coordinate_field = node.field_06_09() as f32;
    let span_field = node.field_16_25() as f32;
    let error_or_floor = if 0.15_f32 - node.accumulated_distance_squared >= 0.0 {
        0.15_f32
    } else {
        node.accumulated_distance_squared
    };
    let divided = error_or_floor / coordinate_field;
    let bounded_error = if 0.15_f32 - divided >= 0.0 {
        divided
    } else {
        0.15_f32
    };
    let squared = coordinate_field * coordinate_field;
    let cubed = squared * coordinate_field;
    let fourth = cubed * coordinate_field;
    fourth / (bounded_error * span_field)
}

/// Replays TU3's strict, stable winner scan over already-advanced node state.
///
/// Only bit-30-complete nodes participate. The first complete node wins ties;
/// a later node replaces it only when its score is strictly greater.
pub fn select_retail_pattern_winner(
    nodes: &[RetailPatternNodeSnapshot],
    mode: MatcherMode,
) -> Option<RetailPatternWinner> {
    let mut selected: Option<(&RetailPatternNodeSnapshot, f32)> = None;
    for node in nodes {
        if !node.candidate_complete() {
            continue;
        }
        let score = retail_candidate_arbitration_score(node);
        if selected
            .as_ref()
            .is_none_or(|(_, selected_score)| score > *selected_score)
        {
            selected = Some((node, score));
        }
    }

    selected.map(|(node, arbitration_score)| {
        let result_field_16_25 = node.result_field_16_25() as f32;
        let ratio = result_field_16_25 / node.field_06_09() as f32;
        RetailPatternWinner {
            id: node.id,
            arbitration_score,
            quality: score_ratio(mode, ratio),
            accumulated_distance_squared: node.accumulated_distance_squared,
            result_field_16_25,
        }
    })
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SelectedPatternContact {
    NoSelectedPattern,
    Held { id: PatternId, name: String },
    Released { id: PatternId, name: String },
}

#[derive(Clone, Debug, PartialEq)]
pub struct RecognitionFrame {
    pub processed_sample: Stick2,
    pub anticipation: AnticipationClassification,
    pub pop: PopRecognition,
    pub selected_pattern_contact: SelectedPatternContact,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RetailConfiguredRecognitionFrame {
    pub processed_sample: Stick2,
    pub anticipation: AnticipationClassification,
    pub winner: Option<(RetailPatternWinner, String)>,
    pub selected_pattern_contact: SelectedPatternContact,
}

/// Stateful standalone input boundary. The raw history is additional port
/// telemetry; TU3's proven 201-entry recognizer ring is [`Self::right_history`].
#[derive(Clone, Debug)]
pub struct TrickInputRecognizer {
    patterns: RetailPatternDatabase,
    context: PatternContext,
    pub raw_right_history: History201<RawStickSample>,
    pub right_history: History201<Stick2>,
    right_nodes: Vec<RetailPatternNodeState>,
    selected_pattern: Option<PatternId>,
}

impl TrickInputRecognizer {
    /// Construct the normal on-ground recognizer.
    ///
    /// Retail keeps the normal, +/-90-degree, airborne, and fingerflip pattern
    /// files in separate gesture contexts. Ground Flickit must not arbitrate
    /// candidates from those sibling contexts.
    pub fn new() -> Result<Self, PatternParseError> {
        Self::for_context(PatternContext::Ground)
    }

    pub fn for_context(context: PatternContext) -> Result<Self, PatternParseError> {
        let patterns = RetailPatternDatabase::load_embedded()?;
        let active_source = context.source();
        let mut right_nodes =
            Vec::with_capacity(patterns.pattern_count_for_lane(InputLane::RightStick));
        for file in &patterns.files {
            if file.source != active_source {
                continue;
            }
            for (index, pattern) in file.patterns.iter().enumerate() {
                let id = PatternId {
                    source: file.source,
                    index,
                };
                right_nodes.push(RetailPatternNodeState::new(id, pattern));
            }
        }
        Ok(Self {
            patterns,
            context,
            raw_right_history: History201::default(),
            right_history: History201::default(),
            right_nodes,
            selected_pattern: None,
        })
    }

    pub const fn patterns(&self) -> &RetailPatternDatabase {
        &self.patterns
    }

    /// Cancel any gesture that was only partially observed before an external
    /// action took ownership of the skater.
    ///
    /// PatternNodes are notification-driven, so a neutral stick followed by
    /// button-only activity does not otherwise age an incomplete sequence.
    /// The next right-stick direction could then finish that stale gesture.
    pub fn reset_gesture_state(&mut self) {
        self.selected_pattern = None;
        for node in &mut self.right_nodes {
            let pattern = self
                .patterns
                .pattern(node.id)
                .expect("node id came from this database");
            node.reset(pattern);
        }
    }

    pub const fn context(&self) -> PatternContext {
        self.context
    }

    /// Return the selected winner while the newest processed sample remains
    /// inside its authored final-coordinate radius.
    ///
    /// Retail exposes this sustained final contact as the trick's `*Hold`
    /// intent. This accessor deliberately reads the selected PatternNode and
    /// its exact tolerance instead of applying a second stick threshold.
    pub fn selected_pattern_held_name(&self) -> Option<&str> {
        let id = self.selected_pattern?;
        let processed = self.right_history.get(0)?;
        let pattern = self.patterns.pattern(id)?;
        let final_coordinate = pattern.coordinates.last()?.position;
        (processed.distance_squared(final_coordinate) <= pattern.tolerance_squared)
            .then_some(pattern.name.as_str())
    }

    fn update_selected_pattern_contact(&mut self, processed: Stick2) -> SelectedPatternContact {
        match self.selected_pattern {
            None => SelectedPatternContact::NoSelectedPattern,
            Some(id) => {
                let pattern = self
                    .patterns
                    .pattern(id)
                    .expect("selected pattern id came from this database");
                let final_coordinate = pattern
                    .coordinates
                    .last()
                    .expect("retail patterns have coordinates")
                    .position;
                if processed.distance_squared(final_coordinate) <= pattern.tolerance_squared {
                    SelectedPatternContact::Held {
                        id,
                        name: pattern.name.clone(),
                    }
                } else {
                    self.selected_pattern = None;
                    SelectedPatternContact::Released {
                        id,
                        name: pattern.name.clone(),
                    }
                }
            }
        }
    }

    pub fn observe_raw(
        &mut self,
        raw: RawStickSample,
        anticipation_signal: Option<AnticipationSignal>,
        mirror_state: MirrorState,
    ) -> RecognitionFrame {
        self.raw_right_history.push_front(raw);
        let normalized = raw_right_stick_to_pattern_node(raw.x, raw.y);
        self.observe_normalized(normalized, anticipation_signal, mirror_state)
    }

    pub fn observe_normalized(
        &mut self,
        normalized: Stick2,
        anticipation_signal: Option<AnticipationSignal>,
        mirror_state: MirrorState,
    ) -> RecognitionFrame {
        let processed = filter_recognizer_components(normalized);
        self.observe_processed(processed, anticipation_signal, mirror_state)
    }

    /// Accepts an already-filtered sample. This is useful for deterministic
    /// telemetry replay and unit tests.
    pub fn observe_processed(
        &mut self,
        processed: Stick2,
        anticipation_signal: Option<AnticipationSignal>,
        mirror_state: MirrorState,
    ) -> RecognitionFrame {
        self.right_history.push_front(processed);

        let selected_pattern_contact = self.update_selected_pattern_contact(processed);

        let mut candidates = Vec::new();
        for file in &self.patterns.files {
            if file.source != self.context.source() {
                continue;
            }
            for (index, pattern) in file.patterns.iter().enumerate() {
                if let Some(matched_ages) = ordered_geometry_match(&self.right_history, pattern) {
                    candidates.push(GeometryCandidate {
                        id: PatternId {
                            source: file.source,
                            index,
                        },
                        name: pattern.name.clone(),
                        matched_ages,
                    });
                }
            }
        }
        let pop = if candidates.is_empty() {
            PopRecognition::NoGeometryCandidate
        } else {
            PopRecognition::GeometryCandidates {
                candidates,
                publication_blocked_by: UnresolvedSemantic::RecognizerSampleCadence,
            }
        };
        let anticipation = anticipation_signal.map_or(
            AnticipationClassification::MissingRecoveredProjection {
                unresolved: UnresolvedSemantic::AnticipationIntentProjection,
            },
            |signal| classify_anticipation(signal, mirror_state),
        );

        RecognitionFrame {
            processed_sample: processed,
            anticipation,
            pop,
            selected_pattern_contact,
        }
    }

    /// Runs the recovered live PatternNode producer and exact winner scan using
    /// the captured TU3 retail matcher configuration.
    ///
    /// Call this exactly once for each upstream input notification. Static and
    /// runtime evidence proves that `0x8269_62D8` pushes one sample per call;
    /// it does not prove a universal rendered-frame Hertz.
    pub fn observe_processed_retail(
        &mut self,
        processed: Stick2,
        anticipation_signal: Option<AnticipationSignal>,
        mirror_state: MirrorState,
        mode: MatcherMode,
    ) -> RetailConfiguredRecognitionFrame {
        self.observe_processed_with_retail_pattern_config(
            processed,
            anticipation_signal,
            mirror_state,
            RETAIL_PATTERN_MAXIMUM_GAP_SAMPLES,
            mode,
        )
    }

    /// Runs the recovered live PatternNode producer and exact winner scan with
    /// an explicitly supplied configuration byte.
    ///
    /// This override exists for deterministic tests and comparison captures.
    /// Normal retail playback should use [`Self::observe_processed_retail`].
    pub fn observe_processed_with_retail_pattern_config(
        &mut self,
        processed: Stick2,
        anticipation_signal: Option<AnticipationSignal>,
        mirror_state: MirrorState,
        maximum_gap_samples: u8,
        mode: MatcherMode,
    ) -> RetailConfiguredRecognitionFrame {
        self.right_history.push_front(processed);
        let had_selected_pattern = self.selected_pattern.is_some();
        let selected_pattern_contact = self.update_selected_pattern_contact(processed);

        let winner = if had_selected_pattern {
            None
        } else {
            let patterns = &self.patterns;
            for node in &mut self.right_nodes {
                let pattern = patterns
                    .pattern(node.id)
                    .expect("node id came from this database");
                node.advance(pattern, processed, maximum_gap_samples);
            }
            let snapshots: Vec<_> = self
                .right_nodes
                .iter()
                .map(RetailPatternNodeState::snapshot)
                .collect();
            match select_retail_pattern_winner(&snapshots, mode) {
                None => None,
                Some(winner) => {
                    let name = self
                        .patterns
                        .pattern(winner.id)
                        .expect("winner id came from this database")
                        .name
                        .clone();
                    self.selected_pattern = Some(winner.id);
                    for node in &mut self.right_nodes {
                        let pattern = self
                            .patterns
                            .pattern(node.id)
                            .expect("node id came from this database");
                        node.reset(pattern);
                    }
                    Some((winner, name))
                }
            }
        };
        let anticipation = anticipation_signal.map_or(
            AnticipationClassification::MissingRecoveredProjection {
                unresolved: UnresolvedSemantic::AnticipationIntentProjection,
            },
            |signal| classify_anticipation(signal, mirror_state),
        );

        RetailConfiguredRecognitionFrame {
            processed_sample: processed,
            anticipation,
            winner,
            selected_pattern_contact,
        }
    }

    /// Allows a later exact arbitration implementation (or a recorded retail
    /// winner) to activate TU3's proven final-coordinate held/released behavior.
    pub fn accept_resolved_candidate(&mut self, id: PatternId) -> bool {
        if id.source != self.context.source() || self.patterns.pattern(id).is_none() {
            return false;
        }
        self.selected_pattern = Some(id);
        true
    }

    /// Applies exact TU3 arbitration to externally captured/advanced nodes and
    /// activates the proven held/released contact behavior for the winner.
    pub fn accept_retail_node_snapshots(
        &mut self,
        nodes: &[RetailPatternNodeSnapshot],
        mode: MatcherMode,
    ) -> Option<RetailPatternWinner> {
        let winner = select_retail_pattern_winner(nodes, mode)?;
        if !self.accept_resolved_candidate(winner.id) {
            return None;
        }
        Some(winner)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_approx(actual: f32, expected: f32, epsilon: f32) {
        assert!(
            (actual - expected).abs() <= epsilon,
            "actual={actual:?}, expected={expected:?}, epsilon={epsilon:?}"
        );
    }

    #[test]
    fn radial_normalization_uses_retail_deadzone_and_outer_saturation() {
        assert_eq!(normalize_raw_axis_pair(0, 0), Stick2::ZERO);
        assert_eq!(normalize_raw_axis_pair(8192, 0), Stick2::ZERO);

        let just_outside = normalize_raw_axis_pair(9000, 0);
        assert!(just_outside.x > 0.0);
        assert_eq!(just_outside.y, 0.0);

        let positive = normalize_raw_axis_pair(i16::MAX, 0);
        assert_approx(positive.x, 1.0, 1.0e-6);
        assert_eq!(positive.y, 0.0);

        let negative = normalize_raw_axis_pair(i16::MIN, 0);
        assert_approx(negative.x, -1.0, 1.0e-6);
    }

    #[test]
    fn raw_xinput_y_is_reflected_once_at_the_pattern_node_boundary() {
        let tail_antic = raw_right_stick_to_pattern_node(0, i16::MIN);
        assert_eq!(tail_antic.x, 0.0);
        assert_approx(tail_antic.y, 1.0, 1.0e-6);

        let ollie_release = raw_right_stick_to_pattern_node(0, i16::MAX);
        assert_eq!(ollie_release.x, 0.0);
        assert_approx(ollie_release.y, -1.0, 1.0e-6);
    }

    #[test]
    fn component_filter_is_strictly_less_than_point_one() {
        let retained = filter_recognizer_components(Stick2::new(0.1, -0.1));
        assert_eq!(retained, Stick2::new(0.1, -0.1));

        let removed = filter_recognizer_components(Stick2::new(0.099_999, -0.099_999));
        assert_eq!(removed, Stick2::ZERO);
    }

    #[test]
    fn history_is_newest_first_and_caps_at_201_samples() {
        let mut history = History201::<RawStickSample>::default();
        for x in 0..250_i16 {
            history.push_front(RawStickSample { x, y: -x });
        }
        assert_eq!(history.len(), RIGHT_STICK_HISTORY_CAPACITY);
        assert_eq!(history.get(0).unwrap().x, 249);
        assert_eq!(history.get(200).unwrap().x, 49);
        assert!(history.get(201).is_none());
    }

    #[test]
    fn all_retail_pattern_files_parse_with_exact_counts() {
        let database = RetailPatternDatabase::load_embedded().unwrap();
        let expected = [
            (PatternSource::Skater, 78),
            (PatternSource::Skater90, 78),
            (PatternSource::SkaterNegative90, 78),
            (PatternSource::SkaterAir, 21),
            (PatternSource::SkaterFingerflip, 14),
            (PatternSource::SkaterLeftStick, 10),
            (PatternSource::SkaterStep, 6),
        ];
        for (source, count) in expected {
            let file = database
                .files
                .iter()
                .find(|file| file.source == source)
                .unwrap();
            assert_eq!(file.patterns.len(), count, "{}", source.file_name());
            assert_eq!(file.globals.tolerance_dist, 0.4);
            assert_eq!(file.globals.tolerance_time.parsed_value, 10.0);
            assert_eq!(file.globals.tolerance_speed.parsed_value, 10.0);
            assert_eq!(file.globals.anticipation_delay.parsed_value, 15.0);
        }
        assert_eq!(database.pattern_count_for_lane(InputLane::RightStick), 269);
        assert_eq!(database.pattern_count_for_lane(InputLane::LeftStick), 16);
    }

    #[test]
    fn recognizer_contexts_keep_ground_and_rotated_pattern_files_separate() {
        let ground = TrickInputRecognizer::new().unwrap();
        assert_eq!(ground.context(), PatternContext::Ground);
        assert_eq!(ground.right_nodes.len(), 78);
        assert!(
            ground
                .right_nodes
                .iter()
                .all(|node| node.id.source == PatternSource::Skater)
        );

        let ninety = TrickInputRecognizer::for_context(PatternContext::GroundNinety).unwrap();
        assert_eq!(ninety.context(), PatternContext::GroundNinety);
        assert_eq!(ninety.right_nodes.len(), 78);
        assert!(
            ninety
                .right_nodes
                .iter()
                .all(|node| node.id.source == PatternSource::Skater90)
        );
    }

    #[test]
    fn normal_ground_recognizer_rejects_sibling_context_winners() {
        let mut recognizer = TrickInputRecognizer::new().unwrap();
        let sibling_id = PatternId {
            source: PatternSource::Skater90,
            index: 0,
        };
        assert!(recognizer.patterns().pattern(sibling_id).is_some());
        assert!(!recognizer.accept_resolved_candidate(sibling_id));
        assert_eq!(
            recognizer
                .observe_processed(Stick2::ZERO, None, MirrorState::Unmirrored)
                .selected_pattern_contact,
            SelectedPatternContact::NoSelectedPattern
        );
    }

    #[test]
    fn rotated_ground_patterns_require_the_explicit_rotated_context() {
        let mut recognizer =
            TrickInputRecognizer::for_context(PatternContext::GroundNinety).unwrap();
        let (id, pattern) = recognizer
            .patterns()
            .files
            .iter()
            .find(|file| file.source == PatternSource::Skater90)
            .and_then(|file| {
                file.patterns
                    .iter()
                    .enumerate()
                    .find(|(_, pattern)| pattern.name == "90_Ollie")
                    .map(|(index, pattern)| {
                        (
                            PatternId {
                                source: PatternSource::Skater90,
                                index,
                            },
                            pattern.clone(),
                        )
                    })
            })
            .expect("skater90.pat contains 90_Ollie");

        let mut winner = None;
        for coordinate in pattern.coordinates {
            winner = recognizer
                .observe_processed_retail(
                    coordinate.position,
                    None,
                    MirrorState::Unmirrored,
                    MatcherMode::Default,
                )
                .winner
                .clone();
        }
        let (winner, name) = winner.expect("90_Ollie completes in the +90 ground context");
        assert_eq!(winner.id, id);
        assert_eq!(name, "90_Ollie");
    }

    #[test]
    fn ollie_geometry_is_detected_but_publication_remains_unresolved() {
        let mut recognizer = TrickInputRecognizer::new().unwrap();
        recognizer.observe_processed(
            Stick2::new(-0.245_714, 0.942_857),
            None,
            MirrorState::Unmirrored,
        );
        let frame = recognizer.observe_processed(
            Stick2::new(0.371_429, -0.908_571),
            None,
            MirrorState::Unmirrored,
        );
        let PopRecognition::GeometryCandidates {
            candidates,
            publication_blocked_by,
        } = frame.pop
        else {
            panic!("expected at least the retail Ollie geometry");
        };
        let ollie = candidates
            .iter()
            .find(|candidate| {
                candidate.id.source == PatternSource::Skater && candidate.name == "Ollie"
            })
            .expect("skater.pat Ollie candidate");
        assert_eq!(ollie.matched_ages, vec![1, 0]);
        assert_eq!(
            publication_blocked_by,
            UnresolvedSemantic::RecognizerSampleCadence
        );
    }

    #[test]
    fn captured_retail_gap_configuration_is_used_by_live_entry_point() {
        assert_eq!(RETAIL_PATTERN_MAXIMUM_GAP_SAMPLES, 10);
        assert_eq!(MATCHER_CONFIG_MAXIMUM_GAP_OFFSET, 0x21);

        let mut recognizer = TrickInputRecognizer::new().unwrap();
        let id = PatternId {
            source: PatternSource::Skater,
            index: 0,
        };
        let pattern = recognizer.patterns().pattern(id).unwrap().clone();

        let antic = recognizer.observe_processed_retail(
            pattern.coordinates[0].position,
            None,
            MirrorState::Unmirrored,
            MatcherMode::Default,
        );
        assert!(antic.winner.is_none());

        let pop = recognizer.observe_processed_retail(
            pattern.coordinates[1].position,
            None,
            MirrorState::Unmirrored,
            MatcherMode::Default,
        );
        assert_eq!(pop.winner.unwrap().0.id, id);
    }

    fn packed_node(
        id: PatternId,
        complete: bool,
        field_06_09: u32,
        field_10_15: u32,
        field_16_25: u32,
        field_26_29: u32,
        error: f32,
    ) -> RetailPatternNodeSnapshot {
        RetailPatternNodeSnapshot {
            id,
            packed_word: (u32::from(complete) << 30)
                | ((field_26_29 & 0x0f) << 26)
                | ((field_16_25 & 0x03ff) << 16)
                | ((field_10_15 & 0x3f) << 10)
                | ((field_06_09 & 0x0f) << 6),
            accumulated_distance_squared: error,
        }
    }

    #[test]
    fn packed_node_fields_follow_tu3_extractions() {
        let node = packed_node(
            PatternId {
                source: PatternSource::Skater,
                index: 0,
            },
            true,
            4,
            17,
            321,
            9,
            0.2,
        );
        assert!(node.candidate_complete());
        assert_eq!(node.field_06_09(), 4);
        assert_eq!(node.field_10_15(), 17);
        assert_eq!(node.field_16_25(), 321);
        assert_eq!(node.field_26_29(), 9);
        assert_eq!(node.result_field_16_25(), 321);
    }

    #[test]
    fn retail_pattern_node_advances_file_order_ollie_to_completion() {
        let database = RetailPatternDatabase::load_embedded().unwrap();
        let id = PatternId {
            source: PatternSource::Skater,
            index: 0,
        };
        let pattern = database.pattern(id).unwrap();
        let mut node = RetailPatternNodeState::new(id, pattern);
        assert_eq!(node.coordinate_count(), 2);
        assert_eq!(node.coordinate_index(), 1);

        let antic = pattern.coordinates[0].position;
        node.advance(pattern, antic, 10);
        assert!(node.active());
        assert!(!node.complete());
        assert_eq!(node.coordinate_index(), 0);
        assert_eq!(node.sampled_span(), 1);

        // Lingering on the coordinate that activated the node is the exact
        // count-index==2 special case and does not age the gap.
        node.advance(pattern, antic, 10);
        assert_eq!(node.sampled_span(), 1);
        assert_eq!(node.consecutive_gap_samples(), 0);

        let pop = pattern.coordinates[1].position;
        node.advance(pattern, pop, 10);
        assert!(node.complete());
        assert_eq!(node.sampled_span(), 2);
        assert_eq!(node.snapshot().result_field_16_25(), 2);
    }

    #[test]
    fn every_retail_right_pattern_completes_on_its_exact_file_order_coordinates() {
        let database = RetailPatternDatabase::load_embedded().unwrap();
        let mut checked = 0;
        for file in &database.files {
            if file.source.lane() != InputLane::RightStick {
                continue;
            }
            for (index, pattern) in file.patterns.iter().enumerate() {
                let id = PatternId {
                    source: file.source,
                    index,
                };
                let mut node = RetailPatternNodeState::new(id, pattern);
                for coordinate in &pattern.coordinates {
                    node.advance(pattern, coordinate.position, 10);
                }
                assert!(
                    node.complete(),
                    "{} pattern {} did not complete",
                    file.source.file_name(),
                    pattern.name
                );
                assert_eq!(
                    node.sampled_span(),
                    pattern.coordinates.len() as u32,
                    "{} pattern {} span",
                    file.source.file_name(),
                    pattern.name
                );
                checked += 1;
            }
        }
        assert_eq!(checked, 269);
    }

    #[test]
    fn retail_pattern_node_resets_only_after_strict_maximum_gap() {
        let database = RetailPatternDatabase::load_embedded().unwrap();
        let id = PatternId {
            source: PatternSource::Skater,
            index: 0,
        };
        let pattern = database.pattern(id).unwrap();
        let mut node = RetailPatternNodeState::new(id, pattern);
        node.advance(pattern, pattern.coordinates[0].position, 2);

        for expected_gap in 1..=2 {
            node.advance(pattern, Stick2::ZERO, 2);
            assert!(node.active());
            assert_eq!(node.consecutive_gap_samples(), expected_gap);
        }
        node.advance(pattern, Stick2::ZERO, 2);
        assert!(!node.active());
        assert!(!node.complete());
        assert_eq!(node.consecutive_gap_samples(), 0);
        assert_eq!(node.sampled_span(), 0);
        assert_eq!(node.accumulated_distance_squared, 0.0);
    }

    #[test]
    fn live_retail_config_path_publishes_exact_ollie_winner() {
        let mut recognizer = TrickInputRecognizer::new().unwrap();
        let id = PatternId {
            source: PatternSource::Skater,
            index: 0,
        };
        let pattern = recognizer.patterns().pattern(id).unwrap().clone();
        let antic = recognizer.observe_processed_with_retail_pattern_config(
            pattern.coordinates[0].position,
            None,
            MirrorState::Unmirrored,
            10,
            MatcherMode::Default,
        );
        assert!(antic.winner.is_none());

        let pop = recognizer.observe_processed_with_retail_pattern_config(
            pattern.coordinates[1].position,
            None,
            MirrorState::Unmirrored,
            10,
            MatcherMode::Default,
        );
        let (winner, name) = pop
            .winner
            .expect("retail PatternNode path should publish a winner");
        assert_eq!(winner.id, id);
        assert_eq!(name, "Ollie");
        assert_eq!(winner.quality, 1.0);
        assert_eq!(winner.result_field_16_25, 2.0);
    }

    #[test]
    fn retail_arbitration_score_and_quality_match_tu3_equations() {
        let node = packed_node(
            PatternId {
                source: PatternSource::Skater,
                index: 0,
            },
            true,
            4,
            0,
            8,
            0,
            0.1,
        );
        assert_approx(retail_candidate_arbitration_score(&node), 853.333_3, 0.001);
        let winner = select_retail_pattern_winner(&[node], MatcherMode::Default).unwrap();
        assert_approx(winner.quality, (4.4 - 2.0) / (4.4 - 1.75), 1.0e-6);
        assert_eq!(winner.result_field_16_25, 8.0);
        assert_eq!(winner.accumulated_distance_squared, 0.1);
    }

    #[test]
    fn retail_winner_scan_ignores_incomplete_and_is_stable_on_ties() {
        let first_id = PatternId {
            source: PatternSource::Skater,
            index: 0,
        };
        let second_id = PatternId {
            source: PatternSource::Skater,
            index: 1,
        };
        let incomplete = packed_node(first_id, false, 8, 0, 1, 0, 0.0);
        let first = packed_node(first_id, true, 4, 0, 8, 0, 0.1);
        let tied = packed_node(second_id, true, 4, 0, 8, 0, 0.1);
        let winner =
            select_retail_pattern_winner(&[incomplete, first, tied], MatcherMode::ModeTwo).unwrap();
        assert_eq!(winner.id, first_id);
        assert_approx(winner.quality, 2.0 / 3.0, 1.0e-6);
    }

    #[test]
    fn externally_advanced_nodes_can_activate_proven_hold_release_path() {
        let mut recognizer = TrickInputRecognizer::new().unwrap();
        let id = PatternId {
            source: PatternSource::Skater,
            index: 0,
        };
        let node = packed_node(id, true, 2, 0, 4, 0, 0.1);
        let winner = recognizer
            .accept_retail_node_snapshots(&[node], MatcherMode::Default)
            .unwrap();
        assert_eq!(winner.id, id);

        let held = recognizer.observe_processed(
            Stick2::new(0.371_429, -0.908_571),
            None,
            MirrorState::Unmirrored,
        );
        assert!(matches!(
            held.selected_pattern_contact,
            SelectedPatternContact::Held { id: held_id, .. } if held_id == id
        ));
    }

    #[test]
    fn selected_pattern_uses_final_coordinate_for_hold_and_release() {
        let mut recognizer = TrickInputRecognizer::new().unwrap();
        let id = PatternId {
            source: PatternSource::Skater,
            index: 0,
        };
        assert!(recognizer.accept_resolved_candidate(id));

        let held = recognizer.observe_processed(
            Stick2::new(0.371_429, -0.908_571),
            None,
            MirrorState::Unmirrored,
        );
        assert_eq!(
            held.selected_pattern_contact,
            SelectedPatternContact::Held {
                id,
                name: "Ollie".to_owned()
            }
        );
        assert_eq!(recognizer.selected_pattern_held_name(), Some("Ollie"));

        let continued_hold =
            recognizer.observe_processed(Stick2::new(0.2, -0.8), None, MirrorState::Unmirrored);
        assert_eq!(
            continued_hold.selected_pattern_contact,
            SelectedPatternContact::Held {
                id,
                name: "Ollie".to_owned()
            }
        );
        assert_eq!(recognizer.selected_pattern_held_name(), Some("Ollie"));

        let released = recognizer.observe_processed(Stick2::ZERO, None, MirrorState::Unmirrored);
        assert_eq!(
            released.selected_pattern_contact,
            SelectedPatternContact::Released {
                id,
                name: "Ollie".to_owned()
            }
        );
        assert_eq!(recognizer.selected_pattern_held_name(), None);
        let next = recognizer.observe_processed(Stick2::ZERO, None, MirrorState::Unmirrored);
        assert_eq!(
            next.selected_pattern_contact,
            SelectedPatternContact::NoSelectedPattern
        );
    }

    #[test]
    fn all_four_multi_flip_winners_use_their_authored_final_hold_target() {
        for expected_name in ["Kickflip", "Heelflip", "N_Kickflip", "N_Heelflip"] {
            let mut recognizer = TrickInputRecognizer::new().unwrap();
            let skater = recognizer
                .patterns
                .files
                .iter()
                .find(|file| file.source == PatternSource::Skater)
                .unwrap();
            let (index, pattern) = skater
                .patterns
                .iter()
                .enumerate()
                .find(|(_, pattern)| pattern.name == expected_name)
                .unwrap();
            let final_coordinate = pattern.coordinates.last().unwrap().position;
            let id = PatternId {
                source: PatternSource::Skater,
                index,
            };

            assert!(recognizer.accept_resolved_candidate(id));
            recognizer.observe_processed(final_coordinate, None, MirrorState::Unmirrored);
            assert_eq!(recognizer.selected_pattern_held_name(), Some(expected_name));

            recognizer.observe_processed(Stick2::ZERO, None, MirrorState::Unmirrored);
            assert_eq!(recognizer.selected_pattern_held_name(), None);
        }
    }

    #[test]
    fn anticipation_gate_sectors_mirroring_and_boundaries_are_explicit() {
        assert_eq!(
            classify_anticipation(
                AnticipationSignal {
                    magnitude: 0.9,
                    angle_radians: 0.0,
                },
                MirrorState::Unmirrored,
            ),
            AnticipationClassification::Inactive { magnitude: 0.9 }
        );

        let regular = classify_anticipation(
            AnticipationSignal {
                magnitude: 0.91,
                angle_radians: -0.8,
            },
            MirrorState::Unmirrored,
        );
        assert!(matches!(
            regular,
            AnticipationClassification::Classified {
                identity: AnticipationIdentity::PopShuvit,
                ..
            }
        ));

        let switch = classify_anticipation(
            AnticipationSignal {
                magnitude: 0.91,
                angle_radians: -0.8,
            },
            MirrorState::Mirrored,
        );
        assert!(matches!(
            switch,
            AnticipationClassification::Classified {
                identity: AnticipationIdentity::FsPopShuvit,
                ..
            }
        ));

        let boundary = classify_anticipation(
            AnticipationSignal {
                magnitude: 1.0,
                angle_radians: 1.57,
            },
            MirrorState::Unmirrored,
        );
        let AnticipationClassification::AmbiguousBoundary { candidates, .. } = boundary else {
            panic!("inclusive XML boundary must not be guessed");
        };
        assert_eq!(
            candidates,
            vec![
                AnticipationIdentity::FsThreeSixtyPopShuvit,
                AnticipationIdentity::NollieFsThreeSixtyPopShuvit
            ]
        );
    }

    #[test]
    fn mirror_state_routing_does_not_change_tail_or_nose_pop_foot() {
        let kickflip = square_identity_for_gesture("Kickflip").unwrap();
        let switch = resolve_trick_identity(kickflip, MirrorState::Mirrored, false);
        assert_eq!(switch.selected_name, "Heelflip");
        assert_eq!(switch.pop_foot, PopFoot::Tail);

        let nollie_kickflip = square_identity_for_gesture("N_Kickflip").unwrap();
        let switch_nollie = resolve_trick_identity(nollie_kickflip, MirrorState::Mirrored, false);
        assert_eq!(switch_nollie.selected_name, "N_Heelflip");
        assert_eq!(switch_nollie.pop_foot, PopFoot::Nose);

        let dont_mirror = resolve_trick_identity(kickflip, MirrorState::Mirrored, true);
        assert_eq!(dont_mirror.selected_name, "Kickflip");
    }

    #[test]
    fn gesture_group_table_remap_and_counts_match_recovered_layout() {
        let groups = [
            GestureGroup::Square,
            GestureGroup::Nose,
            GestureGroup::Tail,
            GestureGroup::NinetyNose,
            GestureGroup::NinetyTail,
            GestureGroup::NegativeNinetyNose,
            GestureGroup::NegativeNinetyTail,
        ];
        let physical: Vec<_> = groups.iter().map(|group| group.physical_table()).collect();
        let counts: Vec<_> = groups.iter().map(|group| group.record_count()).collect();
        assert_eq!(physical, vec![6, 0, 1, 2, 3, 4, 5]);
        assert_eq!(counts, vec![30, 30, 30, 45, 45, 45, 45]);
    }

    #[test]
    fn complete_270_record_identity_table_is_typed_and_validated() {
        let records = load_recovered_identity_table().unwrap();
        assert_eq!(records.len(), 270);
        assert_eq!(records[0].gesture_key, "Ollie");
        assert_eq!(records[0].primary, "Ollie");
        assert_eq!(records[0].secondary, "Ollie");
        assert_eq!(records[0].selector_code, 1);

        let groups = [
            GestureGroup::Square,
            GestureGroup::Nose,
            GestureGroup::Tail,
            GestureGroup::NinetyNose,
            GestureGroup::NinetyTail,
            GestureGroup::NegativeNinetyNose,
            GestureGroup::NegativeNinetyTail,
        ];
        for group in groups {
            assert_eq!(
                records
                    .iter()
                    .filter(|record| record.group == group)
                    .count(),
                group.record_count(),
                "{group:?}"
            );
        }
    }

    #[test]
    fn matcher_score_piecewise_constants_are_exact() {
        assert_eq!(score_ratio(MatcherMode::Default, 1.75), 1.0);
        assert_eq!(score_ratio(MatcherMode::Default, 4.4), 0.0);
        assert_approx(score_ratio(MatcherMode::Default, 3.075), 0.5, 1.0e-6);
        assert_eq!(score_ratio(MatcherMode::ModeTwo, 1.5), 1.0);
        assert_eq!(score_ratio(MatcherMode::ModeTwo, 3.0), 0.0);
        assert_approx(score_ratio(MatcherMode::ModeTwo, 2.25), 0.5, 1.0e-6);
    }
}
