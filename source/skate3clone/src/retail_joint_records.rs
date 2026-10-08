//! Exact default records emitted by Skate 3 TU3 `SkateboardBody::CreateJoints`.
//!
//! `Assembly::Initialize` materializes these records as six embedded retail
//! joints. This module preserves the complete 64-byte parameter payload,
//! 80-byte frame payload, definition-body order, and unrolled record order
//! observed in the executable; it does not map them to a Bevy or third-party
//! joint.

#![allow(dead_code)]

use crate::skateboard_body::BodyId;

pub mod tu3 {
    pub const CREATE_JOINTS: u32 = 0x82C0_C268;
    pub const ASSEMBLY_INITIALIZE: u32 = 0x82AD_FAF8;
    pub const ASSEMBLY_POPULATE: u32 = 0x82AD_FBB8;
    pub const FRAME_PACK_0: u32 = 0x82C0_0940;
    pub const FRAME_PACK_1: u32 = 0x82C0_0AF0;
    pub const FRAME_PACK_2: u32 = 0x82BD_3858;
}

pub const JOINT_COUNT: usize = 6;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct RetailJointParametersRaw {
    pub words: [u32; 16],
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct RetailJointFramesRaw {
    pub words: [u32; 20],
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RetailJointRecord {
    pub definition_body_0: BodyId,
    pub definition_body_1: BodyId,
    pub parameters: RetailJointParametersRaw,
    pub frames: RetailJointFramesRaw,
}

impl RetailJointRecord {
    /// Body written to live `Joint+0x10` by assembly activation.
    pub const fn live_body_a(self) -> BodyId {
        self.definition_body_1
    }

    /// Body written to live `Joint+0x14` by assembly activation.
    pub const fn live_body_b(self) -> BodyId {
        self.definition_body_0
    }
}

const TRUCK_PARAMETERS: RetailJointParametersRaw = RetailJointParametersRaw {
    words: [
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0x42B4_53D1,
        0,
        0,
        0x3E7A_35DD,
        0x3F80_0000,
        0x3F78_654D,
        0,
        1,
    ],
};

const WHEEL_PARAMETERS: RetailJointParametersRaw = RetailJointParametersRaw {
    words: [
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0x497F_A9D8,
        0,
        0,
        0x3F80_0000,
        0x3F80_0000,
        3,
        0,
    ],
};

const TRUCK_4_FRAMES: RetailJointFramesRaw = RetailJointFramesRaw {
    words: [
        0,
        0,
        0,
        0x3F80_0000,
        0,
        0,
        0,
        0,
        0xBE41_8051,
        0xBF2E_6F8D,
        0x3E41_804F,
        0x3F2E_6F8D,
        0,
        0xBD67_6C8B,
        0x3E78_D4FD,
        0,
        0xBE41_8051,
        0xBF2E_6F8D,
        0x3E41_804F,
        0x3F2E_6F8D,
    ],
};

const TRUCK_5_FRAMES: RetailJointFramesRaw = RetailJointFramesRaw {
    words: [
        0,
        0,
        0,
        0x3F80_0000,
        0,
        0,
        0,
        0,
        0x3E41_8051,
        0x3F2E_6F8D,
        0x3E41_804F,
        0x3F2E_6F8D,
        0,
        0xBD67_6C8B,
        0xBE78_D4FD,
        0,
        0x3E41_8051,
        0x3F2E_6F8D,
        0x3E41_804F,
        0x3F2E_6F8D,
    ],
};

const WHEEL_POSITIVE_FRAMES: RetailJointFramesRaw = RetailJointFramesRaw {
    words: [
        0x3F35_04F3,
        0,
        0,
        0x3F35_04F3,
        0,
        0,
        0,
        0,
        0x3F35_04F3,
        0,
        0,
        0x3F35_04F3,
        0,
        0,
        0x3DC2_8F5C,
        0,
        0x3F35_04F3,
        0,
        0,
        0x3F35_04F3,
    ],
};

const WHEEL_NEGATIVE_FRAMES: RetailJointFramesRaw = RetailJointFramesRaw {
    words: [
        0x3F35_04F3,
        0,
        0,
        0x3F35_04F3,
        0,
        0,
        0,
        0,
        0x3F35_04F3,
        0,
        0,
        0x3F35_04F3,
        0,
        0,
        0xBDC2_8F5C,
        0,
        0x3F35_04F3,
        0,
        0,
        0x3F35_04F3,
    ],
};

/// Complete default record set in TU3's explicit write order.
pub const RETAIL_DEFAULT_JOINTS: [RetailJointRecord; JOINT_COUNT] = [
    RetailJointRecord {
        definition_body_0: BodyId::Deck,
        definition_body_1: BodyId::FrontTruck,
        parameters: TRUCK_PARAMETERS,
        frames: TRUCK_4_FRAMES,
    },
    RetailJointRecord {
        definition_body_0: BodyId::Deck,
        definition_body_1: BodyId::BackTruck,
        parameters: TRUCK_PARAMETERS,
        frames: TRUCK_5_FRAMES,
    },
    RetailJointRecord {
        definition_body_0: BodyId::FrontTruck,
        definition_body_1: BodyId::RightFrontWheel,
        parameters: WHEEL_PARAMETERS,
        frames: WHEEL_POSITIVE_FRAMES,
    },
    RetailJointRecord {
        definition_body_0: BodyId::FrontTruck,
        definition_body_1: BodyId::LeftFrontWheel,
        parameters: WHEEL_PARAMETERS,
        frames: WHEEL_NEGATIVE_FRAMES,
    },
    RetailJointRecord {
        definition_body_0: BodyId::BackTruck,
        definition_body_1: BodyId::RightBackWheel,
        parameters: WHEEL_PARAMETERS,
        frames: WHEEL_POSITIVE_FRAMES,
    },
    RetailJointRecord {
        definition_body_0: BodyId::BackTruck,
        definition_body_1: BodyId::LeftBackWheel,
        parameters: WHEEL_PARAMETERS,
        frames: WHEEL_NEGATIVE_FRAMES,
    },
];

#[cfg(test)]
mod tests {
    use core::mem::size_of;

    use super::*;

    #[test]
    fn raw_record_sizes_match_tu3_owner_strides() {
        assert_eq!(size_of::<RetailJointParametersRaw>(), 64);
        assert_eq!(size_of::<RetailJointFramesRaw>(), 80);
    }

    #[test]
    fn default_records_preserve_unrolled_pair_order() {
        assert_eq!(
            RETAIL_DEFAULT_JOINTS.map(|joint| (joint.definition_body_0, joint.definition_body_1)),
            [
                (BodyId::Deck, BodyId::FrontTruck),
                (BodyId::Deck, BodyId::BackTruck),
                (BodyId::FrontTruck, BodyId::RightFrontWheel),
                (BodyId::FrontTruck, BodyId::LeftFrontWheel),
                (BodyId::BackTruck, BodyId::RightBackWheel),
                (BodyId::BackTruck, BodyId::LeftBackWheel),
            ]
        );
    }

    #[test]
    fn assembly_activation_reverses_definition_pairs_into_live_joint_fields() {
        assert_eq!(
            RETAIL_DEFAULT_JOINTS.map(|joint| (joint.live_body_a(), joint.live_body_b())),
            [
                (BodyId::FrontTruck, BodyId::Deck),
                (BodyId::BackTruck, BodyId::Deck),
                (BodyId::RightFrontWheel, BodyId::FrontTruck),
                (BodyId::LeftFrontWheel, BodyId::FrontTruck),
                (BodyId::RightBackWheel, BodyId::BackTruck),
                (BodyId::LeftBackWheel, BodyId::BackTruck),
            ]
        );
    }

    #[test]
    fn static_oracle_payloads_retain_default_signs_and_profiles() {
        assert_eq!(
            RETAIL_DEFAULT_JOINTS[0].parameters.words,
            TRUCK_PARAMETERS.words
        );
        assert_eq!(
            RETAIL_DEFAULT_JOINTS[2].parameters.words,
            WHEEL_PARAMETERS.words
        );
        assert_eq!(RETAIL_DEFAULT_JOINTS[0].frames.words[14], 0x3E78_D4FD);
        assert_eq!(RETAIL_DEFAULT_JOINTS[1].frames.words[14], 0xBE78_D4FD);
        assert_eq!(RETAIL_DEFAULT_JOINTS[2].frames.words[14], 0x3DC2_8F5C);
        assert_eq!(RETAIL_DEFAULT_JOINTS[3].frames.words[14], 0xBDC2_8F5C);
    }
}
