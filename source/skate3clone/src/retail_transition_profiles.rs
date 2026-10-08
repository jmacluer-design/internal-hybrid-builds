//! Exact TU3 transition-adjacent graph and scalar records.
//!
//! Evidence classification:
//! - Observed: names, byte sizes, offsets, and big-endian payloads come from
//!   the decoded `physics_reckoning/default` and `physics_airstates/default`
//!   ABIN collections.
//! - Derived: `PointGraphData8` is represented as 16 raw words and
//!   `PointNegGraphData8` as 20 raw words because their decoded schema sizes
//!   are 64 and 80 bytes.
//! - Unresolved: the four-word `PointNegGraphData8` header, graph evaluation,
//!   state ownership, and physical-versus-visual consumers. This module does
//!   not evaluate or apply any graph.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RetailRawGraph<const WORDS: usize> {
    pub key: &'static str,
    pub words: [u32; WORDS],
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RetailRawRecord<const WORDS: usize> {
    pub key: &'static str,
    pub words: [u32; WORDS],
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RetailRawAttributeValue {
    Word(u32),
    Byte(u8),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RetailRawAttribute {
    pub key: &'static str,
    pub value: RetailRawAttributeValue,
}

const fn hex_nibble(byte: u8) -> u32 {
    match byte {
        b'0'..=b'9' => (byte - b'0') as u32,
        b'A'..=b'F' => (byte - b'A' + 10) as u32,
        _ => panic!("retail profile payload is not uppercase hexadecimal"),
    }
}

const fn big_endian_words<const WORDS: usize>(hex: &[u8]) -> [u32; WORDS] {
    assert!(hex.len() == WORDS * 8);
    let mut words = [0; WORDS];
    let mut word_index = 0;
    while word_index < WORDS {
        let mut value = 0;
        let mut nibble_index = 0;
        while nibble_index < 8 {
            value = (value << 4) | hex_nibble(hex[word_index * 8 + nibble_index]);
            nibble_index += 1;
        }
        words[word_index] = value;
        word_index += 1;
    }
    words
}

pub const RECKONING_POINT_NEG_GRAPHS: [RetailRawGraph<20>; 5] = [
    RetailRawGraph {
        key: "TiltVsDistToTarget",
        words: big_endian_words(b"00000000000000003F00000040000000000000003D2370933E1042B73E5EA51B3E88C1763EB0C8223ECD222E3F00000000000000000000003F43A83C3F97C57A3FB5F1633FD7C57A3FE9248D40000000"),
    },
    RetailRawGraph {
        key: "TiltBlendVsDistTowards",
        words: big_endian_words(b"000000003F19999A3F8000003F800000000000003DE97C3D3E856B913ED3CDF83F0140353F196EE73F369E713F8000003F8000003F683A843F5075073F3EE7223F35C28F3F2DB6DD3F277F453F19999A"),
    },
    RetailRawGraph {
        key: "SpinSpeedMaxDelta",
        words: big_endian_words(b"0000000000000000400000003F800000000000003E856B913EB373CE3F149BE63F70940C3FB87FDC3FDDCAB8400000003F8000003F8000003F0DB6DB3E6A0E9F3DAF8AF93D8AF8B13D83A83B3D83A83B"),
    },
    RetailRawGraph {
        key: "DeckAngleUsageVsSpeed",
        words: big_endian_words(b"0000000000000000414000003F800000000000003FC0000040400000408A281140C2EBF840F9999A411B4502414000000000000000000000000000003D3E2BE23E3333333E97C57D3ED5F15E3F0CCCCD"),
    },
    RetailRawGraph {
        key: "Air_MaxUpVectAngleDelta",
        words: big_endian_words(b"3F000000000000003F7D70A43E4CCCCD3F0000003F0726863F0E81593F24FA6F3F3C10693F6039A43F73399A3F7D080A3E2260913E19999A3E118DE93DFA260F3DD880BD3DA9B1023D98231A3D93BFA1"),
    },
];

pub const RECKONING_POINT_GRAPHS: [RetailRawGraph<16>; 12] = [
    RetailRawGraph {
        key: "UpVectorSmoothingVsSpeed",
        words: big_endian_words(b"000000003E0000003E86410B3EBFCAA13F18996F3F3DB4F33F5078133F80000000000000000000003D260DD13E2298383ED67C8A3F3E45303F8000003F800000"),
    },
    RetailRawGraph {
        key: "UpVectorMaxDeltaVsSpeed",
        words: big_endian_words(b"000000003DE2D07A3E6B27323EBC74BF3F0AD7243F3488C13F66FBD63F8000003F106EB43F1E45303F2EB3E43F46EB3E3F6000003F7306EB3F8000003F800000"),
    },
    RetailRawGraph {
        key: "TrajectoryDispVsSpeed",
        words: big_endian_words(b"000000003D48215C3E5723DA3EE47B6B3F1619043F39F4523F5A0F043F800000000000003E98375A3ED306ED3F07C8A63F1BACF93F3229843F41BAD03F498376"),
    },
    RetailRawGraph {
        key: "TrajectoryDispVsGroundNorm",
        words: big_endian_words(b"000000003D48215C3DDF7A923E26C6733E697C3D3EAF1D313EE550E23F80000000000000000000003F2B3E453F5F22983F7759F23F8000003F8000003F800000"),
    },
    RetailRawGraph {
        key: "TiltVsSlopeGround",
        words: big_endian_words(b"000000003E0716823E9619043F03C0A03F40355E3F58CECD3F723DB53F80000000000000000000003DCF91533E9F22983F2DD67C3F58375A3F78375A3F800000"),
    },
    RetailRawGraph {
        key: "TiltVsSlopeAir",
        words: big_endian_words(b"000000003DD608653E82192F3EE53EF33F264B893F56D1D53F71D6083F800000000000003E0DD67C3EBE45303F20DD683F54C1BB3F6F914C3F7ACF913F800000"),
    },
    RetailRawGraph {
        key: "TiltVsRotGround",
        words: big_endian_words(b"000000003E19999A3E99999A3EE666663F19999A3F4000003F6666663F800000000000003E19999A3E99999A3EE666663F19999A3F4000003F6666663F800000"),
    },
    RetailRawGraph {
        key: "TiltVsRotAir",
        words: big_endian_words(b"000000003E19999A3E99999A3EE666663F19999A3F4000003F6666663F800000000000003E19999A3E99999A3EE666663F19999A3F4000003F6666663F800000"),
    },
    RetailRawGraph {
        key: "GroundVectorBlendVsSpeed",
        words: big_endian_words(b"000000003E7028083EA871673EC320863EECD2223F17C3F63F5AE47A3F800000000000003B5D67FF3D4F91503DE453093EB3E4553F14C1BB3F460DD63F522984"),
    },
    RetailRawGraph {
        key: "GroundVectorBlendGraph",
        words: big_endian_words(b"3AD578E53E0A6C643E84961B3EBD4A363EF954393F0F6D3D3F1FAFF33F8000003B5D67FF000000003EC6EB3E3F2983763F5C8A613F6B3E453F7229833F800000"),
    },
    RetailRawGraph {
        key: "DynamicUpVsGroundY",
        words: big_endian_words(b"000000003E67D1503EC4CB773EF028083F0996EF3F182EB23F279BEF3F80000000000000000000003E114C1C3E9D67C83F0453073F5E45303F8000003F800000"),
    },
    RetailRawGraph {
        key: "DynamicSpeedMaxDeltaGraphZ",
        words: big_endian_words(b"000000003E3273133EA6C6763EE7D14D3F03C0A03F1D9A453F4175933F8000003D914C183E7229843EFACF923F6A60DD3F8000003F514C1C3E759F253D7914BF"),
    },
];

pub const RECKONING_FIXED_RECORDS: [RetailRawRecord<4>; 4] = [
    RetailRawRecord {
        key: "FlipAxisAdjustment",
        words: big_endian_words(b"3F8000003F8000003F19999A00000000"),
    },
    RetailRawRecord {
        key: "UpVectorSmoothingSlow",
        words: big_endian_words(b"3D23D70A3D23D70A3E4CCCCD3E4CCCCD"),
    },
    RetailRawRecord {
        key: "UpVectorSmoothingFast",
        words: big_endian_words(b"3E4CCCCD3ECCCCCD3E4CCCCD3E4CCCCD"),
    },
    RetailRawRecord {
        key: "GroundNormalSmoothing",
        words: big_endian_words(b"3E4CCCCD3E4CCCCD3D4CCCCD3DCCCCCD"),
    },
];

pub const RECKONING_ATTRIBUTES: [RetailRawAttribute; 32] = [
    word("DynamicSpeedDamping", 0x3F00_0000),
    word("DynamicSpeedMaxDelta", 0x3E19_999A),
    word("DynamicSpeedMaxDeltaXScale", 0x41C0_0000),
    word("DynamicUpVectorDamping", 0x3E4C_CCCD),
    word("ExtraSideDamping", 0x3F19_999A),
    word("FlipBodySpinScalar", 0x3F00_0000),
    word("FlipMaxSpeed", 0x40A0_0000),
    word("FlipScalar", 0x3FA0_0000),
    word("FlipSpeedSmoothingFactor", 0x3DA3_D70A),
    word("GroundTorqueMinSpeed", 0x4040_0000),
    word("GroundVMaxBlendDelta", 0x3DCC_CCCD),
    word("MaxAllowedGroundNormalFromUp", 0x42A0_0000),
    word("MinAngleToUseGroundVector", 0x3DF5_C28F),
    word("MinTrajectorySize", 0x0000_0000),
    word("MinWheelsToUseGroundVector", 0x0000_0000),
    word("SpinSpeedSmoothingFactor", 0x3DCC_CCCD),
    word("TiltMaxVelDelta", 0x3BA3_D70A),
    word("TiltProportianalBlend", 0x3E38_51EC),
    word("TiltUseUpVectDist", 0x0000_0000),
    word("TiltUseUpVectSpeed", 0x0100_0000),
    word("TrajectoryDisplacement", 0x3F59_999A),
    word("TrajectoryRadius", 0x3E4C_CCCD),
    word("UpVectAntiWobbleDamping", 0x3F00_0000),
    word("UpVectorMaxAcceleration", 0x4000_0000),
    word("UpVectorSmoothingAir", 0x3F00_0000),
    word("UpVectorSpeedDamping", 0x3F40_0000),
    word("UpVectorSpeedFactor", 0x3DCC_CCCD),
    word("UpVectorSpeedMax", 0x3DCC_CCCD),
    word("VertJumpAlignFactor", 0x3F80_0000),
    word("VertJumpAlignMaxAngle", 0x3DA3_D70A),
    word("VertJumpAlignMaxGroundNormalY", 0x3E4C_CCCD),
    word("VertJumpAlignMinJumpDirY", 0x3F4C_CCCD),
];

pub const AIR_STATES_POINT_NEG_GRAPHS: [RetailRawGraph<20>; 5] = [
    RetailRawGraph {
        key: "PhysToAnimSlow",
        words: big_endian_words(b"00000000000000003E99999A3F800000000000003BD022B13D3C1F5B3DB51E2F3E0315D73E309D723E60255B3E99999A3F8000003F5333333E97C57D3E20EA123DE2BE2E3DB6DB6E3D9249243D23D70A"),
    },
    RetailRawGraph {
        key: "PhysToAnimFast",
        words: big_endian_words(b"00000000000000003E99999A3F800000000000003C98195C3D3C1F5E3DB11D863DF6290F3E271BDB3E5223043E9919843F8000003F8000003F6BE2BF3F42BE2C3F1E2BE43EF5074F3ECCCCCD3E892491"),
    },
    RetailRawGraph {
        key: "MaxHeadingAdjustVsUpY",
        words: big_endian_words(b"0000000042B400003F80000043070000000000003F3633B43F474BE13F59A4473F647B693F69E6FC3F6FBD4A3F80000043070000430700004303A00042ED36D642CC6DB942BC092542B4000042B40000"),
    },
    RetailRawGraph {
        key: "LandingSpeedScalarVsGroundNormalY",
        words: big_endian_words(b"000000003F8000003F8000003FC000003ED70A3D3EE666663EFAE1483F07AE143F147AE13F1EB8523F28F5C33F30A3D73F8000003F89999A3F90A3D73F9333333F9333333F90A3D73F89999A3F800000"),
    },
    RetailRawGraph {
        key: "Hash_AA79C93673533C5B",
        words: big_endian_words(b"000000003F4CCCCD3F8000003FB33333000000003E006ABF3E9F45363EFE550F3F11EDA83F3208583F5D64E53F8000003F99999A3F99999A3F99999A3F8E147B3F8147AE3F5C86963F4CCCCD3F4CCCCD"),
    },
];

pub const AIR_STATES_POINT_GRAPHS: [RetailRawGraph<16>; 1] = [RetailRawGraph {
    key: "BodySpinInputFilter",
    words: big_endian_words(b"000000003C8FA58F3D196EE73DDC24B73E2A1C5C3E8E97C33EF37DE93F800000000000003E6B3E433F8000003F7ACF913F6C1BAD3F3759F23F0B3E453ED4C1B9"),
}];

pub const AIR_STATES_ATTRIBUTES: [RetailRawAttribute; 19] = [
    word("TrajErrorBlendAwayTime", 0x3E99_999A),
    word("SpeedToAlignToGround_PhysAir", 0x3DCC_CCCD),
    word("NaturalAirTime", 0x3E4C_CCCD),
    word("NaturalAirMinDist", 0x3D75_C28F),
    word("NaturalAirMaxDist", 0x3DF5_C28F),
    word("MountSprintLaunchZ", 0x40E0_0000),
    word("MountSprintLaunchY", 0x3FE6_6666),
    word("MountRunLaunchZ", 0x40A0_0000),
    word("MountRunLaunchY", 0x3FCC_CCCD),
    word("MinTargetHeadingVel", 0x3F80_0000),
    word("MinAutoBodySpeed", 0x3DCC_CCCD),
    word("MaxSpinSpeed", 0x4416_0000),
    word("MaxHeadingAdjustAngle", 0x42B4_0000),
    word("FramesForGrindAirAssist", 0x4180_0000),
    byte("DrawHeadingTarget", 0x00),
    word("DontAlignAnglePhysicsAir", 0x3FCE_147B),
    word("DontAlignAngle", 0x0000_0000),
    byte("DisplayPhysToAnimDebug", 0x00),
    word("BodyFlipMinGrabTimeFraction", 0x3E99_999A),
];

const fn word(key: &'static str, bits: u32) -> RetailRawAttribute {
    RetailRawAttribute {
        key,
        value: RetailRawAttributeValue::Word(bits),
    }
}

const fn byte(key: &'static str, value: u8) -> RetailRawAttribute {
    RetailRawAttribute {
        key,
        value: RetailRawAttributeValue::Byte(value),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    fn all_graph_keys() -> impl Iterator<Item = &'static str> {
        RECKONING_POINT_NEG_GRAPHS
            .iter()
            .map(|graph| graph.key)
            .chain(RECKONING_POINT_GRAPHS.iter().map(|graph| graph.key))
            .chain(AIR_STATES_POINT_NEG_GRAPHS.iter().map(|graph| graph.key))
            .chain(AIR_STATES_POINT_GRAPHS.iter().map(|graph| graph.key))
    }

    #[test]
    fn decoded_transition_graph_inventory_is_complete_and_unique() {
        assert_eq!(RECKONING_POINT_NEG_GRAPHS.len(), 5);
        assert_eq!(RECKONING_POINT_GRAPHS.len(), 12);
        assert_eq!(AIR_STATES_POINT_NEG_GRAPHS.len(), 5);
        assert_eq!(AIR_STATES_POINT_GRAPHS.len(), 1);
        assert_eq!(
            RECKONING_POINT_NEG_GRAPHS.len() * 80
                + RECKONING_POINT_GRAPHS.len() * 64
                + RECKONING_FIXED_RECORDS.len() * 16,
            1232,
            "the complete fixed-layout Reckoning payload is preserved"
        );
        assert_eq!(RECKONING_ATTRIBUTES.len(), 32);
        assert_eq!(AIR_STATES_ATTRIBUTES.len(), 19);

        let keys: Vec<_> = all_graph_keys().collect();
        let unique: BTreeSet<_> = keys.iter().copied().collect();
        assert_eq!(unique.len(), keys.len());
    }

    #[test]
    fn representative_graph_payloads_preserve_exact_abin_words() {
        let ground_tilt = RECKONING_POINT_GRAPHS
            .iter()
            .find(|graph| graph.key == "TiltVsSlopeGround")
            .unwrap();
        assert_eq!(ground_tilt.words[0], 0x0000_0000);
        assert_eq!(ground_tilt.words[7], 0x3F80_0000);
        assert_eq!(ground_tilt.words[10], 0x3DCF_9153);
        assert_eq!(ground_tilt.words[15], 0x3F80_0000);

        let air_delta = RECKONING_POINT_NEG_GRAPHS
            .iter()
            .find(|graph| graph.key == "Air_MaxUpVectAngleDelta")
            .unwrap();
        assert_eq!(
            &air_delta.words[..4],
            &[0x3F00_0000, 0, 0x3F7D_70A4, 0x3E4C_CCCD]
        );
        assert_eq!(air_delta.words[19], 0x3D93_BFA1);
    }

    #[test]
    fn target_named_air_data_remains_raw_and_does_not_imply_position_lock() {
        let target_heading = AIR_STATES_ATTRIBUTES
            .iter()
            .find(|attribute| attribute.key == "MinTargetHeadingVel")
            .unwrap();
        assert_eq!(
            target_heading.value,
            RetailRawAttributeValue::Word(0x3F80_0000)
        );

        let heading_graph = AIR_STATES_POINT_NEG_GRAPHS
            .iter()
            .find(|graph| graph.key == "MaxHeadingAdjustVsUpY")
            .unwrap();
        assert_eq!(heading_graph.words[1], 0x42B4_0000);
        assert_eq!(heading_graph.words[3], 0x4307_0000);
    }
}
