//! TU3's data-driven grind chromosome name classifier.
//!
//! This module is intentionally independent of Bevy and the central game
//! integration. The table and mixed-radix arithmetic were recovered from the
//! Xbox 360 TU3 executable; see `research/porting/GRIND_CHROMOSOME_SPEC.md`.
#![allow(dead_code)]

use std::fmt;

pub const TU3_DUMP_SHA256: &str =
    "F4AA113EB541BFBA03DBC108CF5AB43F58C965B20FA3B82F9C40938A0AD841C4";
pub const TU3_NAME_GRIND_ADDRESS: u32 = 0x82DE_F1C8;
pub const TU3_NAME_GRIND_END: u32 = 0x82DE_F514;
pub const TU3_NAME_GRIND_SHA256: &str =
    "75A31CEDD743D42AB131A1ED39FF9AA61D58AAEF220F9A18D69F2E961B645B43";
pub const TU3_INDEX_BLOCK_START: u32 = 0x82DE_F47C;
pub const TU3_INDEX_BLOCK_END: u32 = 0x82DE_F4D4;
pub const TU3_INDEX_BLOCK_SHA256: &str =
    "E58FEE82D53376B865AA1F64C5B6FB6D375B44D67C5CE0C4A05A9F43364C98CB";
pub const TU3_CANONICAL_STRING_TABLE_START: u32 = 0x8206_FCE4;
pub const TU3_CANONICAL_STRING_TABLE_END: u32 = 0x8207_268C;
pub const TU3_CANONICAL_STRING_TABLE_SHA256: &str =
    "05CDB5C5313F63A567CD84AE34ACD869BBD65099787A3BCA847F64434D2B1646";
pub const TU3_CANONICAL_SEQUENCE_FNV1A64: u64 = 0x2CA8_5C95_7DD2_E53D;
pub const TU3_RUNTIME_POINTER_TABLE_ADDRESS: u32 = 0x8307_E090;
pub const TU3_GRINDS_XML_SHA256: &str =
    "89042598DC9BCAC397E7CF43DFEBE37E1C452EE42062029E53BE5A6459B5029E";

pub const CANONICAL_TABLE_LEN: usize = 2 * 2 * 2 * 2 * 4 * 6;
pub const XML_CANONICAL_NAME_COUNT: usize = 54;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum Approach {
    Frontside = 0,
    Backside = 1,
}

impl Approach {
    pub const ALL: [Self; 2] = [Self::Frontside, Self::Backside];

    pub const fn label(self) -> &'static str {
        match self {
            Self::Frontside => "A-FS",
            Self::Backside => "A-BS",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum BoardEnd {
    Nose = 0,
    Tail = 1,
}

impl BoardEnd {
    pub const ALL: [Self; 2] = [Self::Nose, Self::Tail];

    pub const fn label(self) -> &'static str {
        match self {
            Self::Nose => "NOSE",
            Self::Tail => "TAIL",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum Alignment {
    Twisted = 0,
    Straight = 1,
}

impl Alignment {
    pub const ALL: [Self; 2] = [Self::Twisted, Self::Straight];

    pub const fn label(self) -> &'static str {
        match self {
            Self::Twisted => "TWST",
            Self::Straight => "STRT",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum Height {
    High = 0,
    Low = 1,
}

impl Height {
    pub const ALL: [Self; 2] = [Self::High, Self::Low];

    pub const fn label(self) -> &'static str {
        match self {
            Self::High => "HI",
            Self::Low => "LO",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum Travel {
    Forward = 0,
    Backward = 1,
    Front180 = 2,
    Back180 = 3,
    /// Observed TU3 diagnostic sentinel. It is not a fifth table digit.
    Unknown = 4,
}

impl Travel {
    pub const CLASSIFIABLE: [Self; 4] =
        [Self::Forward, Self::Backward, Self::Front180, Self::Back180];

    pub const fn label(self) -> &'static str {
        match self {
            Self::Forward => "FOR",
            Self::Backward => "BAK",
            Self::Front180 => "F180",
            Self::Back180 => "B180",
            Self::Unknown => "UNK",
        }
    }

    pub const fn is_classifiable(self) -> bool {
        !matches!(self, Self::Unknown)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum ContactFamily {
    FiftyFifty = 0,
    Board = 1,
    Tip = 2,
    FiveO = 3,
    Backslash = 4,
    NotApplicable = 5,
}

impl ContactFamily {
    pub const ALL: [Self; 6] = [
        Self::FiftyFifty,
        Self::Board,
        Self::Tip,
        Self::FiveO,
        Self::Backslash,
        Self::NotApplicable,
    ];

    pub const fn label(self) -> &'static str {
        match self {
            Self::FiftyFifty => "5050",
            Self::Board => "BOARD",
            Self::Tip => "TIP",
            Self::FiveO => "5_O",
            Self::Backslash => "BACKSLASH",
            Self::NotApplicable => "NA",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EnumValueError {
    pub field: &'static str,
    pub value: u8,
}

impl fmt::Display for EnumValueError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "{} chromosome value {} is outside the observed TU3 enum",
            self.field, self.value
        )
    }
}

impl std::error::Error for EnumValueError {}

macro_rules! impl_try_from_u8 {
    ($type:ty, $field:literal, {$($value:literal => $variant:path),+ $(,)?}) => {
        impl TryFrom<u8> for $type {
            type Error = EnumValueError;

            fn try_from(value: u8) -> Result<Self, Self::Error> {
                match value {
                    $($value => Ok($variant),)+
                    _ => Err(EnumValueError {
                        field: $field,
                        value,
                    }),
                }
            }
        }
    };
}

impl_try_from_u8!(Approach, "approach", {
    0 => Approach::Frontside,
    1 => Approach::Backside,
});
impl_try_from_u8!(BoardEnd, "board_end", {
    0 => BoardEnd::Nose,
    1 => BoardEnd::Tail,
});
impl_try_from_u8!(Alignment, "alignment", {
    0 => Alignment::Twisted,
    1 => Alignment::Straight,
});
impl_try_from_u8!(Height, "height", {
    0 => Height::High,
    1 => Height::Low,
});
impl_try_from_u8!(Travel, "travel", {
    0 => Travel::Forward,
    1 => Travel::Backward,
    2 => Travel::Front180,
    3 => Travel::Back180,
    4 => Travel::Unknown,
});
impl_try_from_u8!(ContactFamily, "contact", {
    0 => ContactFamily::FiftyFifty,
    1 => ContactFamily::Board,
    2 => ContactFamily::Tip,
    3 => ContactFamily::FiveO,
    4 => ContactFamily::Backslash,
    5 => ContactFamily::NotApplicable,
});

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct GrindChromosome {
    pub approach: Approach,
    pub board_end: BoardEnd,
    pub alignment: Alignment,
    pub height: Height,
    pub travel: Travel,
    pub contact: ContactFamily,
}

impl GrindChromosome {
    pub const fn new(
        approach: Approach,
        board_end: BoardEnd,
        alignment: Alignment,
        height: Height,
        travel: Travel,
        contact: ContactFamily,
    ) -> Self {
        Self {
            approach,
            board_end,
            alignment,
            height,
            travel,
            contact,
        }
    }

    pub fn try_from_raw(raw: [u8; 6]) -> Result<Self, EnumValueError> {
        Ok(Self {
            approach: raw[0].try_into()?,
            board_end: raw[1].try_into()?,
            alignment: raw[2].try_into()?,
            height: raw[3].try_into()?,
            travel: raw[4].try_into()?,
            contact: raw[5].try_into()?,
        })
    }

    /// Returns TU3's exact mixed-radix table index.
    ///
    /// The radices, in field order, are `2, 2, 2, 2, 4, 6`.
    pub fn table_index(self) -> Result<usize, ClassificationError> {
        if self.travel == Travel::Unknown {
            return Err(ClassificationError::UnknownTravelSentinel);
        }

        Ok(
            (((((self.approach as usize * 2 + self.board_end as usize) * 2
                + self.alignment as usize)
                * 2
                + self.height as usize)
                * 4
                + self.travel as usize)
                * 6)
                + self.contact as usize,
        )
    }
}

impl TryFrom<[u8; 6]> for GrindChromosome {
    type Error = EnumValueError;

    fn try_from(raw: [u8; 6]) -> Result<Self, Self::Error> {
        Self::try_from_raw(raw)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClassificationError {
    /// TU3 prints `UNK`, but its lookup still uses radix four. Treating value
    /// four as a valid digit would alias another tuple or exceed the table.
    UnknownTravelSentinel,
}

impl fmt::Display for ClassificationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownTravelSentinel => formatter.write_str(
                "TU3 travel value UNK is a diagnostic sentinel, not a canonical-table digit",
            ),
        }
    }
}

impl std::error::Error for ClassificationError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClassificationResult {
    pub chromosome: GrindChromosome,
    pub table_index: usize,
    pub canonical_name: &'static str,
}

pub fn classify(chromosome: GrindChromosome) -> Result<ClassificationResult, ClassificationError> {
    let table_index = chromosome.table_index()?;
    Ok(ClassificationResult {
        chromosome,
        table_index,
        canonical_name: TU3_CANONICAL_NAMES[table_index],
    })
}

const TU3_CANONICAL_NAME_BLOCKS: [[&str; 24]; 16] = [
    // FS / NOSE / TWST / HI
    [
        "FS_50_50",
        "FS_LIP",
        "FS_NOSEBLUNT",
        "FS_OVERCROOK",
        "FS_NOSEBLUNT",
        "FS_DARKSLIDE",
        "FS_50_50",
        "FS_BOARD",
        "FS_NOSESLIDE",
        "FS_CROOK",
        "BS_NOSEBLUNT",
        "BS_DARKSLIDE",
        "BF_FS_50_50",
        "FS_LIP",
        "FS_NOSEBLUNT",
        "BF_FS_OVERCROOK",
        "FS_NOSEBLUNT",
        "FS_DARKSLIDE",
        "BF_FS_50_50",
        "FS_BOARD",
        "FS_NOSESLIDE",
        "BF_FS_CROOK",
        "BS_NOSEBLUNT",
        "BS_DARKSLIDE",
    ],
    // FS / NOSE / TWST / LO
    [
        "FS_50_50",
        "FS_LIP",
        "FS_NOSEBLUNT",
        "FS_OVERWILLY",
        "FS_NOSEBLUNT",
        "FS_DARKSLIDE",
        "FS_50_50",
        "FS_BOARD",
        "FS_NOSESLIDE",
        "FS_WILLY",
        "BS_NOSEBLUNT",
        "BS_DARKSLIDE",
        "BF_FS_50_50",
        "FS_LIP",
        "FS_NOSEBLUNT",
        "BF_FS_OVERWILLY",
        "FS_NOSEBLUNT",
        "FS_DARKSLIDE",
        "BF_FS_50_50",
        "FS_BOARD",
        "FS_NOSESLIDE",
        "BF_FS_WILLY",
        "BS_NOSEBLUNT",
        "BS_DARKSLIDE",
    ],
    // FS / NOSE / STRT / HI
    [
        "FS_50_50",
        "FS_LIP",
        "FS_NOSEBLUNT",
        "FS_NOSEGRIND",
        "FS_NOSEBLUNT",
        "FS_DARKSLIDE",
        "FS_50_50",
        "FS_BOARD",
        "FS_NOSESLIDE",
        "FS_NOSEGRIND",
        "BS_NOSEBLUNT",
        "BS_DARKSLIDE",
        "BF_FS_50_50",
        "FS_LIP",
        "FS_NOSEBLUNT",
        "BF_FS_NOSEGRIND",
        "FS_NOSEBLUNT",
        "FS_DARKSLIDE",
        "BF_FS_50_50",
        "FS_BOARD",
        "FS_NOSESLIDE",
        "BF_FS_NOSEGRIND",
        "BS_NOSEBLUNT",
        "BS_DARKSLIDE",
    ],
    // FS / NOSE / STRT / LO
    [
        "FS_50_50",
        "FS_LIP",
        "FS_NOSEBLUNT",
        "FS_OVERWILLY",
        "FS_NOSEBLUNT",
        "FS_DARKSLIDE",
        "FS_50_50",
        "FS_BOARD",
        "FS_NOSESLIDE",
        "FS_WILLY",
        "BS_NOSEBLUNT",
        "BS_DARKSLIDE",
        "BF_FS_50_50",
        "FS_LIP",
        "FS_NOSEBLUNT",
        "BF_FS_OVERWILLY",
        "FS_NOSEBLUNT",
        "FS_DARKSLIDE",
        "BF_FS_50_50",
        "FS_BOARD",
        "FS_NOSESLIDE",
        "BF_FS_WILLY",
        "BS_NOSEBLUNT",
        "BS_DARKSLIDE",
    ],
    // FS / TAIL / TWST / HI
    [
        "FS_50_50",
        "FS_LIP",
        "FS_TAILSLIDE",
        "FS_5_O",
        "BS_BLUNT",
        "BS_DARKSLIDE",
        "FS_50_50",
        "FS_BOARD",
        "FS_BLUNT",
        "FS_SALAD",
        "FS_BLUNT",
        "FS_DARKSLIDE",
        "BF_FS_50_50",
        "FS_LIP",
        "FS_TAILSLIDE",
        "BF_FS_5_O",
        "BS_BLUNT",
        "BS_DARKSLIDE",
        "BF_FS_50_50",
        "FS_BOARD",
        "FS_BLUNT",
        "BF_FS_SALAD",
        "FS_BLUNT",
        "FS_DARKSLIDE",
    ],
    // FS / TAIL / TWST / LO
    [
        "FS_50_50",
        "FS_LIP",
        "FS_TAILSLIDE",
        "FS_SMITH",
        "BS_BLUNT",
        "BS_DARKSLIDE",
        "FS_50_50",
        "FS_BOARD",
        "FS_BLUNT",
        "FS_FEEBLE",
        "FS_BLUNT",
        "FS_DARKSLIDE",
        "BF_FS_50_50",
        "FS_LIP",
        "FS_TAILSLIDE",
        "BF_FS_SMITH",
        "BS_BLUNT",
        "BS_DARKSLIDE",
        "BF_FS_50_50",
        "FS_BOARD",
        "FS_BLUNT",
        "BF_FS_FEEBLE",
        "FS_BLUNT",
        "FS_DARKSLIDE",
    ],
    // FS / TAIL / STRT / HI
    [
        "FS_50_50",
        "FS_LIP",
        "FS_TAILSLIDE",
        "FS_5_O",
        "BS_BLUNT",
        "BS_DARKSLIDE",
        "FS_50_50",
        "FS_BOARD",
        "FS_BLUNT",
        "FS_5_O",
        "FS_BLUNT",
        "FS_DARKSLIDE",
        "BF_FS_50_50",
        "FS_LIP",
        "FS_TAILSLIDE",
        "BF_FS_5_O",
        "BS_BLUNT",
        "BS_DARKSLIDE",
        "BF_FS_50_50",
        "FS_BOARD",
        "FS_BLUNT",
        "BF_FS_5_O",
        "FS_BLUNT",
        "FS_DARKSLIDE",
    ],
    // FS / TAIL / STRT / LO
    [
        "FS_50_50",
        "FS_LIP",
        "FS_TAILSLIDE",
        "FS_SMITH",
        "BS_BLUNT",
        "BS_DARKSLIDE",
        "FS_50_50",
        "FS_BOARD",
        "FS_BLUNT",
        "FS_FEEBLE",
        "FS_BLUNT",
        "FS_DARKSLIDE",
        "BF_FS_50_50",
        "FS_LIP",
        "FS_TAILSLIDE",
        "BF_FS_SMITH",
        "BS_BLUNT",
        "BS_DARKSLIDE",
        "BF_FS_50_50",
        "FS_BOARD",
        "FS_BLUNT",
        "BF_FS_FEEBLE",
        "FS_BLUNT",
        "FS_DARKSLIDE",
    ],
    // BS / NOSE / TWST / HI
    [
        "BS_50_50",
        "BS_BOARD",
        "BS_NOSESLIDE",
        "BS_CROOK",
        "FS_NOSEBLUNT",
        "FS_DARKSLIDE",
        "BS_50_50",
        "BS_LIP",
        "BS_NOSEBLUNT",
        "BS_OVERCROOK",
        "BS_NOSEBLUNT",
        "BS_DARKSLIDE",
        "BF_BS_50_50",
        "BS_BOARD",
        "BS_NOSESLIDE",
        "BF_BS_CROOK",
        "FS_NOSEBLUNT",
        "FS_DARKSLIDE",
        "BF_BS_50_50",
        "BS_LIP",
        "BS_NOSEBLUNT",
        "BF_BS_OVERCROOK",
        "BS_NOSEBLUNT",
        "BS_DARKSLIDE",
    ],
    // BS / NOSE / TWST / LO
    [
        "BS_50_50",
        "BS_BOARD",
        "BS_NOSESLIDE",
        "BS_WILLY",
        "FS_NOSEBLUNT",
        "FS_DARKSLIDE",
        "BS_50_50",
        "BS_LIP",
        "BS_NOSEBLUNT",
        "BS_OVERWILLY",
        "BS_NOSEBLUNT",
        "BS_DARKSLIDE",
        "BF_BS_50_50",
        "BS_BOARD",
        "BS_NOSESLIDE",
        "BF_BS_WILLY",
        "FS_NOSEBLUNT",
        "FS_DARKSLIDE",
        "BF_BS_50_50",
        "BS_LIP",
        "BS_NOSEBLUNT",
        "BF_BS_OVERWILLY",
        "BS_NOSEBLUNT",
        "BS_DARKSLIDE",
    ],
    // BS / NOSE / STRT / HI
    [
        "BS_50_50",
        "BS_BOARD",
        "BS_NOSESLIDE",
        "BS_NOSEGRIND",
        "FS_NOSEBLUNT",
        "FS_DARKSLIDE",
        "BS_50_50",
        "BS_LIP",
        "BS_NOSEBLUNT",
        "BS_NOSEGRIND",
        "BS_NOSEBLUNT",
        "BS_DARKSLIDE",
        "BF_BS_50_50",
        "BS_BOARD",
        "BS_NOSESLIDE",
        "BF_BS_NOSEGRIND",
        "FS_NOSEBLUNT",
        "FS_DARKSLIDE",
        "BF_BS_50_50",
        "BS_LIP",
        "BS_NOSEBLUNT",
        "BF_BS_NOSEGRIND",
        "BS_NOSEBLUNT",
        "BS_DARKSLIDE",
    ],
    // BS / NOSE / STRT / LO
    [
        "BS_50_50",
        "BS_BOARD",
        "BS_NOSESLIDE",
        "BS_WILLY",
        "FS_NOSEBLUNT",
        "FS_DARKSLIDE",
        "BS_50_50",
        "BS_LIP",
        "BS_NOSEBLUNT",
        "BS_OVERWILLY",
        "BS_NOSEBLUNT",
        "BS_DARKSLIDE",
        "BF_BS_50_50",
        "BS_BOARD",
        "BS_NOSESLIDE",
        "BF_BS_WILLY",
        "FS_NOSEBLUNT",
        "FS_DARKSLIDE",
        "BF_BS_50_50",
        "BS_LIP",
        "BS_NOSEBLUNT",
        "BF_BS_OVERWILLY",
        "BS_NOSEBLUNT",
        "BS_DARKSLIDE",
    ],
    // BS / TAIL / TWST / HI
    [
        "BS_50_50",
        "BS_BOARD",
        "BS_BLUNT",
        "BS_SALAD",
        "BS_BLUNT",
        "BS_DARKSLIDE",
        "BS_50_50",
        "BS_LIP",
        "BS_TAILSLIDE",
        "BS_5_O",
        "FS_BLUNT",
        "FS_DARKSLIDE",
        "BF_BS_50_50",
        "BS_BOARD",
        "BS_BLUNT",
        "BF_BS_SALAD",
        "BS_BLUNT",
        "BS_DARKSLIDE",
        "BF_BS_50_50",
        "BS_LIP",
        "BS_TAILSLIDE",
        "BF_BS_5_O",
        "FS_BLUNT",
        "FS_DARKSLIDE",
    ],
    // BS / TAIL / TWST / LO
    [
        "BS_50_50",
        "BS_BOARD",
        "BS_BLUNT",
        "BS_FEEBLE",
        "BS_BLUNT",
        "BS_DARKSLIDE",
        "BS_50_50",
        "BS_LIP",
        "BS_TAILSLIDE",
        "BS_SMITH",
        "FS_BLUNT",
        "FS_DARKSLIDE",
        "BF_BS_50_50",
        "BS_BOARD",
        "BS_BLUNT",
        "BF_BS_FEEBLE",
        "BS_BLUNT",
        "BS_DARKSLIDE",
        "BF_BS_50_50",
        "BS_LIP",
        "BS_TAILSLIDE",
        "BF_BS_SMITH",
        "FS_BLUNT",
        "FS_DARKSLIDE",
    ],
    // BS / TAIL / STRT / HI
    [
        "BS_50_50",
        "BS_BOARD",
        "BS_BLUNT",
        "BS_5_O",
        "BS_BLUNT",
        "BS_DARKSLIDE",
        "BS_50_50",
        "BS_LIP",
        "BS_TAILSLIDE",
        "BS_5_O",
        "FS_BLUNT",
        "FS_DARKSLIDE",
        "BF_BS_50_50",
        "BS_BOARD",
        "BS_BLUNT",
        "BF_BS_5_O",
        "BS_BLUNT",
        "BS_DARKSLIDE",
        "BF_BS_50_50",
        "BS_LIP",
        "BS_TAILSLIDE",
        "BF_BS_5_O",
        "FS_BLUNT",
        "FS_DARKSLIDE",
    ],
    // BS / TAIL / STRT / LO
    [
        "BS_50_50",
        "BS_BOARD",
        "BS_BLUNT",
        "BS_FEEBLE",
        "BS_BLUNT",
        "BS_DARKSLIDE",
        "BS_50_50",
        "BS_LIP",
        "BS_TAILSLIDE",
        "BS_SMITH",
        "FS_BLUNT",
        "FS_DARKSLIDE",
        "BF_BS_50_50",
        "BS_BOARD",
        "BS_BLUNT",
        "BF_BS_FEEBLE",
        "BS_BLUNT",
        "BS_DARKSLIDE",
        "BF_BS_50_50",
        "BS_LIP",
        "BS_TAILSLIDE",
        "BF_BS_SMITH",
        "FS_BLUNT",
        "FS_DARKSLIDE",
    ],
];

const fn flatten_name_blocks() -> [&'static str; CANONICAL_TABLE_LEN] {
    let mut names = [""; CANONICAL_TABLE_LEN];
    let mut block = 0;
    while block < TU3_CANONICAL_NAME_BLOCKS.len() {
        let mut offset = 0;
        while offset < TU3_CANONICAL_NAME_BLOCKS[block].len() {
            names[block * 24 + offset] = TU3_CANONICAL_NAME_BLOCKS[block][offset];
            offset += 1;
        }
        block += 1;
    }
    names
}

pub const TU3_CANONICAL_NAMES: [&str; CANONICAL_TABLE_LEN] = flatten_name_blocks();

pub const GRINDS_XML_CANONICAL_NAMES: [&str; XML_CANONICAL_NAME_COUNT] = [
    "BF_BS_50_50",
    "BF_BS_5_O",
    "BF_BS_CROOK",
    "BF_BS_FEEBLE",
    "BF_BS_NOSEGRIND",
    "BF_BS_OVERCROOK",
    "BF_BS_OVERWILLY",
    "BF_BS_SALAD",
    "BF_BS_SMITH",
    "BF_BS_WILLY",
    "BF_FS_50_50",
    "BF_FS_5_O",
    "BF_FS_CROOK",
    "BF_FS_FEEBLE",
    "BF_FS_NOSEGRIND",
    "BF_FS_OVERCROOK",
    "BF_FS_OVERWILLY",
    "BF_FS_SALAD",
    "BF_FS_SMITH",
    "BF_FS_WILLY",
    "BS_50_50",
    "BS_5_O",
    "BS_BLUNT",
    "BS_BOARD",
    "BS_CROOK",
    "BS_DARKSLIDE",
    "BS_FEEBLE",
    "BS_LIP",
    "BS_NOSEBLUNT",
    "BS_NOSEGRIND",
    "BS_NOSESLIDE",
    "BS_OVERCROOK",
    "BS_OVERWILLY",
    "BS_SALAD",
    "BS_SMITH",
    "BS_TAILSLIDE",
    "BS_WILLY",
    "FS_50_50",
    "FS_5_O",
    "FS_BLUNT",
    "FS_BOARD",
    "FS_CROOK",
    "FS_DARKSLIDE",
    "FS_FEEBLE",
    "FS_LIP",
    "FS_NOSEBLUNT",
    "FS_NOSEGRIND",
    "FS_NOSESLIDE",
    "FS_OVERCROOK",
    "FS_OVERWILLY",
    "FS_SALAD",
    "FS_SMITH",
    "FS_TAILSLIDE",
    "FS_WILLY",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TableValidation {
    pub mapped_tuple_count: usize,
    pub unique_name_count: usize,
    pub xml_name_count: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TableValidationError {
    EmptyCanonicalName { index: usize },
    MissingXmlCanonicalName { name: &'static str },
    CanonicalNameAbsentFromXml { name: &'static str },
}

impl fmt::Display for TableValidationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyCanonicalName { index } => {
                write!(formatter, "canonical grind table entry {index} is empty")
            }
            Self::MissingXmlCanonicalName { name } => {
                write!(formatter, "Grinds.xml canonical name {name} is unreachable")
            }
            Self::CanonicalNameAbsentFromXml { name } => {
                write!(
                    formatter,
                    "TU3 canonical name {name} is absent from Grinds.xml"
                )
            }
        }
    }
}

impl std::error::Error for TableValidationError {}

pub fn validate_table() -> Result<TableValidation, TableValidationError> {
    let mut unique_name_count = 0;

    for (index, name) in TU3_CANONICAL_NAMES.iter().copied().enumerate() {
        if name.is_empty() {
            return Err(TableValidationError::EmptyCanonicalName { index });
        }
        if !GRINDS_XML_CANONICAL_NAMES.contains(&name) {
            return Err(TableValidationError::CanonicalNameAbsentFromXml { name });
        }
        if !TU3_CANONICAL_NAMES[..index].contains(&name) {
            unique_name_count += 1;
        }
    }

    for name in GRINDS_XML_CANONICAL_NAMES {
        if !TU3_CANONICAL_NAMES.contains(&name) {
            return Err(TableValidationError::MissingXmlCanonicalName { name });
        }
    }

    Ok(TableValidation {
        mapped_tuple_count: TU3_CANONICAL_NAMES.len(),
        unique_name_count,
        xml_name_count: GRINDS_XML_CANONICAL_NAMES.len(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{BTreeSet, HashSet};

    fn raw_tu3_index(chromosome: GrindChromosome) -> usize {
        (((((chromosome.approach as usize * 2 + chromosome.board_end as usize) * 2
            + chromosome.alignment as usize)
            * 2
            + chromosome.height as usize)
            * 4
            + chromosome.travel as usize)
            * 6)
            + chromosome.contact as usize
    }

    fn all_valid_chromosomes() -> Vec<GrindChromosome> {
        let mut chromosomes = Vec::with_capacity(CANONICAL_TABLE_LEN);
        for approach in Approach::ALL {
            for board_end in BoardEnd::ALL {
                for alignment in Alignment::ALL {
                    for height in Height::ALL {
                        for travel in Travel::CLASSIFIABLE {
                            for contact in ContactFamily::ALL {
                                chromosomes.push(GrindChromosome::new(
                                    approach, board_end, alignment, height, travel, contact,
                                ));
                            }
                        }
                    }
                }
            }
        }
        chromosomes
    }

    #[test]
    fn boundary_enums_and_observed_labels_are_exact() {
        assert_eq!(Approach::try_from(0), Ok(Approach::Frontside));
        assert_eq!(Approach::try_from(1), Ok(Approach::Backside));
        assert!(Approach::try_from(2).is_err());
        assert_eq!(BoardEnd::try_from(0), Ok(BoardEnd::Nose));
        assert_eq!(BoardEnd::try_from(1), Ok(BoardEnd::Tail));
        assert!(BoardEnd::try_from(2).is_err());
        assert_eq!(Alignment::try_from(0), Ok(Alignment::Twisted));
        assert_eq!(Alignment::try_from(1), Ok(Alignment::Straight));
        assert!(Alignment::try_from(2).is_err());
        assert_eq!(Height::try_from(0), Ok(Height::High));
        assert_eq!(Height::try_from(1), Ok(Height::Low));
        assert!(Height::try_from(2).is_err());
        assert_eq!(Travel::try_from(0), Ok(Travel::Forward));
        assert_eq!(Travel::try_from(3), Ok(Travel::Back180));
        assert_eq!(Travel::try_from(4), Ok(Travel::Unknown));
        assert!(Travel::try_from(5).is_err());
        assert_eq!(ContactFamily::try_from(0), Ok(ContactFamily::FiftyFifty));
        assert_eq!(ContactFamily::try_from(5), Ok(ContactFamily::NotApplicable));
        assert!(ContactFamily::try_from(6).is_err());

        assert_eq!(
            [
                Approach::Frontside.label(),
                Approach::Backside.label(),
                BoardEnd::Nose.label(),
                BoardEnd::Tail.label(),
                Alignment::Twisted.label(),
                Alignment::Straight.label(),
                Height::High.label(),
                Height::Low.label(),
                Travel::Forward.label(),
                Travel::Backward.label(),
                Travel::Front180.label(),
                Travel::Back180.label(),
                Travel::Unknown.label(),
                ContactFamily::FiftyFifty.label(),
                ContactFamily::Board.label(),
                ContactFamily::Tip.label(),
                ContactFamily::FiveO.label(),
                ContactFamily::Backslash.label(),
                ContactFamily::NotApplicable.label(),
            ],
            [
                "A-FS",
                "A-BS",
                "NOSE",
                "TAIL",
                "TWST",
                "STRT",
                "HI",
                "LO",
                "FOR",
                "BAK",
                "F180",
                "B180",
                "UNK",
                "5050",
                "BOARD",
                "TIP",
                "5_O",
                "BACKSLASH",
                "NA",
            ]
        );
    }

    #[test]
    fn every_valid_tuple_has_one_collision_free_index() {
        let chromosomes = all_valid_chromosomes();
        assert_eq!(chromosomes.len(), CANONICAL_TABLE_LEN);

        let mut indices = HashSet::with_capacity(CANONICAL_TABLE_LEN);
        for (expected_index, chromosome) in chromosomes.into_iter().enumerate() {
            let index = chromosome.table_index().unwrap();
            assert_eq!(index, expected_index);
            assert!(indices.insert(index), "duplicate table index {index}");
            assert!(!TU3_CANONICAL_NAMES[index].is_empty());
        }

        assert_eq!(indices.len(), CANONICAL_TABLE_LEN);
        assert_eq!(indices.iter().copied().min(), Some(0));
        assert_eq!(indices.iter().copied().max(), Some(CANONICAL_TABLE_LEN - 1));
    }

    #[test]
    fn unknown_travel_is_rejected_instead_of_using_observed_aliases() {
        let unknown_high = GrindChromosome::new(
            Approach::Frontside,
            BoardEnd::Nose,
            Alignment::Twisted,
            Height::High,
            Travel::Unknown,
            ContactFamily::FiftyFifty,
        );
        let low_forward = GrindChromosome {
            height: Height::Low,
            travel: Travel::Forward,
            ..unknown_high
        };
        assert_eq!(raw_tu3_index(unknown_high), raw_tu3_index(low_forward));

        let unknown_low = GrindChromosome {
            height: Height::Low,
            ..unknown_high
        };
        let straight_high_forward = GrindChromosome {
            alignment: Alignment::Straight,
            height: Height::High,
            travel: Travel::Forward,
            ..unknown_high
        };
        assert_eq!(
            raw_tu3_index(unknown_low),
            raw_tu3_index(straight_high_forward)
        );

        let upper_boundary_unknown = GrindChromosome::new(
            Approach::Backside,
            BoardEnd::Tail,
            Alignment::Straight,
            Height::Low,
            Travel::Unknown,
            ContactFamily::NotApplicable,
        );
        assert!(raw_tu3_index(upper_boundary_unknown) >= CANONICAL_TABLE_LEN);

        for chromosome in [unknown_high, unknown_low, upper_boundary_unknown] {
            assert_eq!(
                chromosome.table_index(),
                Err(ClassificationError::UnknownTravelSentinel)
            );
            assert_eq!(
                classify(chromosome),
                Err(ClassificationError::UnknownTravelSentinel)
            );
        }
    }

    #[test]
    fn raw_invalid_sentinels_do_not_construct_typed_chromosomes() {
        for (field, raw) in [
            (0, [2, 0, 0, 0, 0, 0]),
            (1, [0, 2, 0, 0, 0, 0]),
            (2, [0, 0, 2, 0, 0, 0]),
            (3, [0, 0, 0, 2, 0, 0]),
            (4, [0, 0, 0, 0, 5, 0]),
            (5, [0, 0, 0, 0, 0, 6]),
        ] {
            let error = GrindChromosome::try_from_raw(raw).unwrap_err();
            assert_eq!(error.value, raw[field]);
        }
    }

    #[test]
    fn table_has_exactly_the_54_xml_names_and_all_are_reachable() {
        let table_names: BTreeSet<_> = TU3_CANONICAL_NAMES.iter().copied().collect();
        let xml_names: BTreeSet<_> = GRINDS_XML_CANONICAL_NAMES.iter().copied().collect();

        assert_eq!(table_names.len(), XML_CANONICAL_NAME_COUNT);
        assert_eq!(xml_names.len(), XML_CANONICAL_NAME_COUNT);
        assert_eq!(table_names, xml_names);

        for xml_name in GRINDS_XML_CANONICAL_NAMES {
            assert!(
                all_valid_chromosomes()
                    .into_iter()
                    .any(|chromosome| classify(chromosome).unwrap().canonical_name == xml_name),
                "{xml_name} is unreachable"
            );
        }
    }

    #[test]
    fn validation_reports_complete_observed_table() {
        assert_eq!(
            validate_table(),
            Ok(TableValidation {
                mapped_tuple_count: 384,
                unique_name_count: 54,
                xml_name_count: 54,
            })
        );
    }

    #[test]
    fn classification_is_deterministic_for_every_valid_tuple() {
        for chromosome in all_valid_chromosomes() {
            let first = classify(chromosome).unwrap();
            for _ in 0..32 {
                assert_eq!(classify(chromosome), Ok(first));
            }
        }
    }

    #[test]
    fn recovered_boundary_rows_match_tu3_table() {
        let first = GrindChromosome::new(
            Approach::Frontside,
            BoardEnd::Nose,
            Alignment::Twisted,
            Height::High,
            Travel::Forward,
            ContactFamily::FiftyFifty,
        );
        assert_eq!(classify(first).unwrap().table_index, 0);
        assert_eq!(classify(first).unwrap().canonical_name, "FS_50_50");

        let last = GrindChromosome::new(
            Approach::Backside,
            BoardEnd::Tail,
            Alignment::Straight,
            Height::Low,
            Travel::Back180,
            ContactFamily::NotApplicable,
        );
        assert_eq!(classify(last).unwrap().table_index, 383);
        assert_eq!(classify(last).unwrap().canonical_name, "FS_DARKSLIDE");
    }

    #[test]
    fn all_384_names_match_the_recovered_sequence_fingerprint() {
        let mut fingerprint = 0xCBF2_9CE4_8422_2325_u64;
        for name in TU3_CANONICAL_NAMES {
            for byte in name.bytes().chain(std::iter::once(0)) {
                fingerprint ^= u64::from(byte);
                fingerprint = fingerprint.wrapping_mul(0x0000_0100_0000_01B3);
            }
        }
        assert_eq!(fingerprint, TU3_CANONICAL_SEQUENCE_FNV1A64);
    }
}
