//! Semantic port of Skate 3 TU3's six-degree joint iteration.
//!
//! Skate 3 builds one 384-byte `JointJacobian` for each of the six skateboard
//! assembly joints. `rw::physics::Simulation::Solve` visits contacts, joints,
//! and drives in that order on each of its 25 outer iterations. The joint loop
//! starts near `0x82AE2BC8`; the loop near `0x82AE2E78` is the drive family.
//!
//! The xyz lanes below are recovered from the retail joint branch and checked
//! against a static TU3 oracle. Fourth-word VMX carry lanes are preserved but
//! not synthesized because no downstream joint or rigid-body operation reads
//! them as physical values.

#![allow(dead_code)]

use crate::skateboard_body::retail_rigid_body::RetailReactionCorrections;

pub mod tu3 {
    pub const SIMULATION_SOLVE: u32 = 0x82AE_27D0;
    pub const JOINT_SOLVE_LOOP: u32 = 0x82AE_2BC8;
    pub const DRIVE_SOLVE_LOOP: u32 = 0x82AE_2E78;
    pub const JOINT_BATCH_BUILD: u32 = 0x82AE_39D0;
    pub const JOINT_JACOBIAN_BUILD: u32 = 0x82AE_3BC8;
    pub const JACOBIAN_BYTES: usize = 384;
    pub const REACTION_BYTES: usize = 64;
}

const JACOBIAN_VECTOR_COUNT: usize = tu3::JACOBIAN_BYTES / 16;
const REACTION_VECTOR_COUNT: usize = tu3::REACTION_BYTES / 16;

/// Raw guest word order of TU3's 384-byte `JointJacobian`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct RetailJointJacobian {
    pub words: [u32; JACOBIAN_VECTOR_COUNT * 4],
}

/// Four raw vectors indexed by a rigid body's solver id.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(C)]
pub struct RetailJointReactionBlock {
    pub words: [u32; REACTION_VECTOR_COUNT * 4],
}

impl RetailJointReactionBlock {
    /// Packs the two reaction vectors consumed by the joint-family branch.
    ///
    /// TU3 leaves reaction vectors one and three to the contact family's
    /// position/orientation correction.
    pub fn from_reactions(reactions: RetailReactionCorrections) -> Self {
        let mut words = [0; REACTION_VECTOR_COUNT * 4];
        words[0] = reactions.linear_displacement.x.to_bits();
        words[1] = reactions.linear_displacement.y.to_bits();
        words[2] = reactions.linear_displacement.z.to_bits();
        words[8] = reactions.angular_displacement.x.to_bits();
        words[9] = reactions.angular_displacement.y.to_bits();
        words[10] = reactions.angular_displacement.z.to_bits();
        Self { words }
    }

    /// Writes back only the two joint-owned velocity correction vectors.
    pub fn write_velocity_reactions(self, reactions: &mut RetailReactionCorrections) {
        reactions.linear_displacement.x = f32::from_bits(self.words[0]);
        reactions.linear_displacement.y = f32::from_bits(self.words[1]);
        reactions.linear_displacement.z = f32::from_bits(self.words[2]);
        reactions.angular_displacement.x = f32::from_bits(self.words[8]);
        reactions.angular_displacement.y = f32::from_bits(self.words[9]);
        reactions.angular_displacement.z = f32::from_bits(self.words[10]);
    }
}

type V3 = [f32; 3];

fn read_xyz(words: &[u32], vector: usize) -> V3 {
    let start = vector * 4;
    [
        f32::from_bits(words[start]),
        f32::from_bits(words[start + 1]),
        f32::from_bits(words[start + 2]),
    ]
}

fn read_w(words: &[u32], vector: usize) -> f32 {
    f32::from_bits(words[vector * 4 + 3])
}

fn write_xyz(words: &mut [u32], vector: usize, value: V3) {
    let start = vector * 4;
    words[start] = value[0].to_bits();
    words[start + 1] = value[1].to_bits();
    words[start + 2] = value[2].to_bits();
}

fn add(a: V3, b: V3) -> V3 {
    [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
}

fn sub(a: V3, b: V3) -> V3 {
    [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
}

fn scale(value: V3, scalar: f32) -> V3 {
    [value[0] * scalar, value[1] * scalar, value[2] * scalar]
}

fn cross(a: V3, b: V3) -> V3 {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

/// VMX evaluation order used where the joint branch forms `cross(a, b) + c`.
fn cross_add(a: V3, b: V3, c: V3) -> V3 {
    [
        (a[1] * b[2] + c[0]) - a[2] * b[1],
        (a[2] * b[0] + c[1]) - a[0] * b[2],
        (a[0] * b[1] + c[2]) - a[1] * b[0],
    ]
}

/// Multiplies a vector by a matrix stored as three columns.
fn multiply_columns(columns: [V3; 3], value: V3) -> V3 {
    [
        (columns[0][0] * value[0] + columns[1][0] * value[1]) + columns[2][0] * value[2],
        (columns[0][1] * value[0] + columns[1][1] * value[1]) + columns[2][1] * value[2],
        (columns[0][2] * value[0] + columns[1][2] * value[1]) + columns[2][2] * value[2],
    ]
}

fn projected_accumulator(candidate: V3, low: V3, high: V3) -> V3 {
    core::array::from_fn(|lane| {
        // Observed VMX projector:
        //   max(candidate + low, 0) + min(candidate + high, 0)
        let lower = candidate[lane] + low[lane];
        let upper = candidate[lane] + high[lane];
        let positive = if lower > 0.0 { lower } else { 0.0 };
        let negative = if upper < 0.0 { upper } else { 0.0 };
        positive + negative
    })
}

fn reaction_xyz(reaction: &RetailJointReactionBlock, vector: usize) -> V3 {
    read_xyz(&reaction.words, vector)
}

fn write_reaction_xyz(reaction: &mut RetailJointReactionBlock, vector: usize, value: V3) {
    write_xyz(&mut reaction.words, vector, value);
}

/// Runs one joint-family iteration from the shared TU3 constraint solver.
///
/// The raw record layout is:
///
/// - vectors 0..1: body-space arms and reaction-pointer metadata;
/// - vectors 2..3: accumulated linear and angular impulses;
/// - vectors 4..9: linear/angular inverse-effective-mass projection columns;
/// - vectors 10..11 plus w lanes in 6..9: projected limits/biases;
/// - vectors 12..17: three linear and three angular constraint axes;
/// - vectors 18..23: body A/B world inverse-inertia columns, with inverse
///   mass in the fourth word of each body's first column.
pub fn solve_joint_iteration(
    jacobian: &mut RetailJointJacobian,
    reaction_a: &mut RetailJointReactionBlock,
    reaction_b: &mut RetailJointReactionBlock,
) {
    let arm_a = read_xyz(&jacobian.words, 0);
    let arm_b = read_xyz(&jacobian.words, 1);
    let old_linear_impulse = read_xyz(&jacobian.words, 2);
    let old_angular_impulse = read_xyz(&jacobian.words, 3);

    let old_linear_a = reaction_xyz(reaction_a, 0);
    let old_angular_a = reaction_xyz(reaction_a, 2);
    let old_linear_b = reaction_xyz(reaction_b, 0);
    let old_angular_b = reaction_xyz(reaction_b, 2);

    let point_reaction_a = add(old_linear_a, cross(old_angular_a, arm_a));
    let point_reaction_b = add(old_linear_b, cross(old_angular_b, arm_b));
    let relative_point_reaction = sub(point_reaction_b, point_reaction_a);
    let relative_angular_reaction = sub(old_angular_b, old_angular_a);

    let linear_projection = [
        read_xyz(&jacobian.words, 4),
        read_xyz(&jacobian.words, 6),
        read_xyz(&jacobian.words, 8),
    ];
    let angular_projection = [
        read_xyz(&jacobian.words, 5),
        read_xyz(&jacobian.words, 7),
        read_xyz(&jacobian.words, 9),
    ];

    let linear_candidate = add(
        old_linear_impulse,
        multiply_columns(linear_projection, relative_point_reaction),
    );
    let angular_candidate = add(
        old_angular_impulse,
        multiply_columns(angular_projection, relative_angular_reaction),
    );

    let linear_low = read_xyz(&jacobian.words, 10);
    let linear_high = read_xyz(&jacobian.words, 11);
    let angular_low = [
        read_w(&jacobian.words, 6),
        read_w(&jacobian.words, 7),
        read_w(&jacobian.words, 10),
    ];
    let angular_high = [
        read_w(&jacobian.words, 8),
        read_w(&jacobian.words, 9),
        read_w(&jacobian.words, 11),
    ];

    let new_linear_impulse = projected_accumulator(linear_candidate, linear_low, linear_high);
    let new_angular_impulse = projected_accumulator(angular_candidate, angular_low, angular_high);
    let linear_delta = sub(new_linear_impulse, old_linear_impulse);
    let angular_delta = sub(new_angular_impulse, old_angular_impulse);
    write_xyz(&mut jacobian.words, 2, new_linear_impulse);
    write_xyz(&mut jacobian.words, 3, new_angular_impulse);

    let linear_axes = [
        read_xyz(&jacobian.words, 12),
        read_xyz(&jacobian.words, 13),
        read_xyz(&jacobian.words, 14),
    ];
    let angular_axes = [
        read_xyz(&jacobian.words, 15),
        read_xyz(&jacobian.words, 16),
        read_xyz(&jacobian.words, 17),
    ];
    let linear_impulse = multiply_columns(linear_axes, linear_delta);
    let angular_impulse = multiply_columns(angular_axes, angular_delta);

    let inertia_a = [
        read_xyz(&jacobian.words, 18),
        read_xyz(&jacobian.words, 19),
        read_xyz(&jacobian.words, 20),
    ];
    let inertia_b = [
        read_xyz(&jacobian.words, 21),
        read_xyz(&jacobian.words, 22),
        read_xyz(&jacobian.words, 23),
    ];
    let inverse_mass_a = read_w(&jacobian.words, 18);
    let inverse_mass_b = read_w(&jacobian.words, 21);
    let torque_a = cross_add(arm_a, linear_impulse, angular_impulse);
    let torque_b = cross_add(arm_b, linear_impulse, angular_impulse);

    write_reaction_xyz(
        reaction_a,
        0,
        add(old_linear_a, scale(linear_impulse, inverse_mass_a)),
    );
    write_reaction_xyz(
        reaction_b,
        0,
        sub(old_linear_b, scale(linear_impulse, inverse_mass_b)),
    );
    write_reaction_xyz(
        reaction_a,
        2,
        add(old_angular_a, multiply_columns(inertia_a, torque_a)),
    );
    write_reaction_xyz(
        reaction_b,
        2,
        sub(old_angular_b, multiply_columns(inertia_b, torque_b)),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    const TRUCK_BUILT: [u32; 96] = [
        0x00000000, 0x00000000, 0x00000000, 0x90007000, 0xBE78D4FC, 0xBD465E7D, 0x3CEE625E,
        0x90007100, 0, 0, 0, 0, 0, 0, 0, 0, 0xBED82D8E, 0x3E81C42F, 0x32F8460A, 0xBE80A5F7,
        0x3E800000, 0xBEEF5284, 0xBE7E9A00, 0x3D133F84, 0x3E5EAE02, 0x3EB91ECC, 0xBE7FBD9B,
        0x3F6315DA, 0x00000000, 0xBE04BD6D, 0x3D8D36EA, 0xC057BDFF, 0xBE05CCAA, 0xBE5E7681,
        0xBED4CFDF, 0x3F6315DA, 0x00000000, 0xBEEF5286, 0xBC9CA625, 0xC057BDFF, 0x3D3528DF,
        0xBE2272A6, 0xBDB1F45F, 0x3E0D36E9, 0x3D3528DF, 0xBE2272A6, 0xBDB1F45F, 0x3E0D36E9,
        0xBF5B6F50, 0x3EE208D8, 0xBE87D0B4, 0x90001000, 0x3F03D988, 0x3F3C17A6, 0xBEE208D6,
        0x3F03D988, 0x33800000, 0xBF03D987, 0xBF5B6F51, 0x3EE208D8, 0x3F800000, 0, 0, 0x3F800000,
        0xBE83D987, 0xBD9242BC, 0xBE83D988, 0xBE83D987, 0xBF6DB7A9, 0x3E83D988, 0xBD9242BC,
        0xBF6DB7A9, 0x3F800000, 0, 0, 0x3F800000, 0, 0x3F800000, 0, 0x3F800000, 0, 0, 0x3F800000,
        0x3F800000, 0x3F800000, 0, 0, 0x3F800000, 0, 0x3F800000, 0, 0x3F800000, 0, 0, 0x3F800000,
        0x3F800000,
    ];

    const WHEEL_BUILT: [u32; 96] = [
        0x00000000, 0x00000000, 0x00000000, 0x90007000, 0x00000000, 0x00000000, 0x3DC28F5C,
        0x90007100, 0, 0, 0, 0, 0, 0, 0, 0, 0x3EFED998, 0x00000000, 0x00000000, 0xBEFDB5D2,
        0x3E34E52B, 0x00000000, 0x3DB49A6E, 0xBEA2CEFF, 0x00000000, 0x33800000, 0xBEFED996,
        0x3DC8AAAE, 0x3D48AAAC, 0x33000002, 0xBEA2CEFF, 0xC5885A98, 0x00000000, 0x3EFFFFFE,
        0x337ED998, 0x3DC8AAAE, 0x3E34E52C, 0x3E800001, 0x3DB49A70, 0x45885A98, 0x3D41AF9C,
        0x3D428F5C, 0x31C1AF9E, 0xBF22CF00, 0x3D41AF9C, 0x3D428F5C, 0x31C1AF9E, 0xBF22CF00,
        0x3F800000, 0x00000000, 0x00000000, 0x90001000, 0x00000000, 0x34000000, 0x3F7FFFFE,
        0x00000000, 0x00000000, 0xBF7FFFFE, 0x34000000, 0x00000000, 0x3F2E6F8C, 0x3E418050,
        0x3F2E6F8D, 0x3F2E6F8C, 0x00000000, 0x34000000, 0x3F7FFFFE, 0x00000000, 0x3E418050,
        0xBF2E6F8C, 0x3E418052, 0x3E418050, 0x3F800000, 0, 0, 0x3F800000, 0, 0x3F800000, 0,
        0x3F800000, 0, 0, 0x3F800000, 0x3F800000, 0x3F800000, 0, 0, 0x3F800000, 0, 0x3F800000, 0,
        0x3F800000, 0, 0, 0x3F800000, 0x3F800000,
    ];

    const TRUCK_LINEAR: [u32; 3] = [0x3D3528DF, 0xBE2272A6, 0xBDB1F45F];
    const TRUCK_ANGULAR: [u32; 3] = [0x3F6315DA, 0xC057BDFF, 0x3E0D36E9];
    const TRUCK_REACTION_A_0: [u32; 3] = [0xBDF4F9C8, 0xBD56241D, 0x3E07F899];
    const TRUCK_REACTION_A_2: [u32; 3] = [0x3FD04453, 0x3E8D715F, 0x3F5BB5A7];
    const TRUCK_REACTION_B_0: [u32; 3] = [0x3DF4F9C8, 0x3D56241D, 0xBE07F899];
    const TRUCK_REACTION_B_2: [u32; 3] = [0xBFCFA374, 0xBE9C2E60, 0xBF5D7A95];

    const WHEEL_LINEAR: [u32; 3] = [0x3D41AF9C, 0x3D428F5C, 0x31C1AF9E];
    const WHEEL_ANGULAR: [u32; 3] = [0x3DC8AAAE, 0x00000000, 0xBF22CF00];
    const WHEEL_REACTION_A_0: [u32; 3] = [0x3D41AF9C, 0x2DDFC000, 0x3D428F5A];
    const WHEEL_REACTION_A_2: [u32; 3] = [0xBD5AC7C2, 0x3EE75A1A, 0xBD5AC7C4];
    const WHEEL_REACTION_B_0: [u32; 3] = [0xBD41AF9C, 0xADDFC000, 0xBD428F5A];
    const WHEEL_REACTION_B_2: [u32; 3] = [0x3D5AC7C2, 0xBEE9A6E8, 0x3D5AC7C4];

    #[test]
    fn raw_layout_matches_tu3_strides() {
        assert_eq!(core::mem::size_of::<RetailJointJacobian>(), 384);
        assert_eq!(core::mem::size_of::<RetailJointReactionBlock>(), 64);
    }

    #[test]
    fn reaction_bridge_preserves_contact_only_position_corrections() {
        let mut reactions = RetailReactionCorrections {
            linear_displacement: crate::skateboard_body::Vector3::new(1.0, 2.0, 3.0),
            position_displacement: crate::skateboard_body::Vector3::new(4.0, 5.0, 6.0),
            angular_displacement: crate::skateboard_body::Vector3::new(7.0, 8.0, 9.0),
            orientation_displacement: crate::skateboard_body::Vector3::new(10.0, 11.0, 12.0),
        };
        let mut block = RetailJointReactionBlock::from_reactions(reactions);
        block.words[0] = 13.0f32.to_bits();
        block.words[9] = 14.0f32.to_bits();
        block.write_velocity_reactions(&mut reactions);

        assert_eq!(
            reactions.linear_displacement,
            crate::skateboard_body::Vector3::new(13.0, 2.0, 3.0)
        );
        assert_eq!(
            reactions.angular_displacement,
            crate::skateboard_body::Vector3::new(7.0, 14.0, 9.0)
        );
        assert_eq!(
            reactions.position_displacement,
            crate::skateboard_body::Vector3::new(4.0, 5.0, 6.0)
        );
        assert_eq!(
            reactions.orientation_displacement,
            crate::skateboard_body::Vector3::new(10.0, 11.0, 12.0)
        );
    }

    fn assert_oracle(
        built: [u32; 96],
        linear: [u32; 3],
        angular: [u32; 3],
        reaction_a_0: [u32; 3],
        reaction_a_2: [u32; 3],
        reaction_b_0: [u32; 3],
        reaction_b_2: [u32; 3],
    ) {
        let mut jacobian = RetailJointJacobian { words: built };
        let mut reaction_a = RetailJointReactionBlock::default();
        let mut reaction_b = RetailJointReactionBlock::default();
        solve_joint_iteration(&mut jacobian, &mut reaction_a, &mut reaction_b);

        assert_eq!(&jacobian.words[8..11], &linear);
        assert_eq!(&jacobian.words[12..15], &angular);
        assert_eq!(&reaction_a.words[0..3], &reaction_a_0);
        assert_eq!(&reaction_a.words[8..11], &reaction_a_2);
        assert_eq!(&reaction_b.words[0..3], &reaction_b_0);
        assert_eq!(&reaction_b.words[8..11], &reaction_b_2);
    }

    fn assert_words_within_ulp(actual: &[u32], expected: &[u32], maximum_ulp: u32) {
        assert_eq!(actual.len(), expected.len());
        for (lane, (&actual, &expected)) in actual.iter().zip(expected).enumerate() {
            let actual_value = f32::from_bits(actual);
            let expected_value = f32::from_bits(expected);
            let ulp = actual.abs_diff(expected);
            assert!(
                actual_value.is_finite()
                    && expected_value.is_finite()
                    && (actual == expected || ulp <= maximum_ulp),
                "lane {lane}: actual=0x{actual:08X} ({actual_value}) expected=0x{expected:08X} ({expected_value}) ulp={ulp}",
            );
        }
    }

    #[test]
    fn truck_iteration_matches_true_joint_slot_oracle_xyz() {
        assert_oracle(
            TRUCK_BUILT,
            TRUCK_LINEAR,
            TRUCK_ANGULAR,
            TRUCK_REACTION_A_0,
            TRUCK_REACTION_A_2,
            TRUCK_REACTION_B_0,
            TRUCK_REACTION_B_2,
        );
    }

    #[test]
    fn wheel_iteration_matches_true_joint_slot_oracle_xyz() {
        assert_oracle(
            WHEEL_BUILT,
            WHEEL_LINEAR,
            WHEEL_ANGULAR,
            WHEEL_REACTION_A_0,
            WHEEL_REACTION_A_2,
            WHEEL_REACTION_B_0,
            WHEEL_REACTION_B_2,
        );
    }

    #[test]
    fn second_iteration_matches_true_joint_slot_feedback_oracle_xyz() {
        let fixtures = [
            (
                TRUCK_BUILT,
                [0x3DF94B94, 0xBDA7BB8A, 0xBE1F6360],
                [0x3F7637D0, 0xC08AF3A2, 0x3F89CCBD],
                [0xBE1609C7, 0x3D970006, 0x3E0C9523],
                [0x3F8A47FB, 0x3F165C08, 0x3F854A26],
                [0x3E1609C7, 0xBD970006, 0xBE0C9523],
                [0xBF8927CE, 0xBF1DCEF1, 0xBF82168A],
            ),
            (
                WHEEL_BUILT,
                [0x3CD45598, 0x3D428F60, 0x3B2586C4],
                [0x3E41C0E8, 0x00000000, 0xBF76DC94],
                [0x3CD45598, 0xBB2586AB, 0x3D428F5E],
                [0xBD5A49F4, 0x3F315CB6, 0xBD5A49F6],
                [0xBCD45598, 0x3B2586AB, 0xBD428F5E],
                [0x3D594E5A, 0xBF31FE16, 0x3D5A49F6],
            ),
        ];
        for (built, linear, angular, reaction_a_0, reaction_a_2, reaction_b_0, reaction_b_2) in
            fixtures
        {
            let mut jacobian = RetailJointJacobian { words: built };
            let mut reaction_a = RetailJointReactionBlock::default();
            let mut reaction_b = RetailJointReactionBlock::default();
            solve_joint_iteration(&mut jacobian, &mut reaction_a, &mut reaction_b);
            solve_joint_iteration(&mut jacobian, &mut reaction_a, &mut reaction_b);

            assert_eq!(&jacobian.words[8..11], &linear);
            assert_eq!(&jacobian.words[12..15], &angular);
            assert_eq!(&reaction_a.words[0..3], &reaction_a_0);
            assert_eq!(&reaction_a.words[8..11], &reaction_a_2);
            assert_eq!(&reaction_b.words[0..3], &reaction_b_0);
            assert_eq!(&reaction_b.words[8..11], &reaction_b_2);
        }
    }

    #[test]
    fn nonidentity_inertia_feedback_matches_true_joint_slot_oracle_xyz() {
        let mut built = TRUCK_BUILT;
        let replacement_vectors = [
            (4, [0xBF627B09, 0x3F061821, 0x33683E42, 0xBF015288]),
            (5, [0x3D924925, 0xBDBE8B49, 0xBD921361, 0x3C2A5180]),
            (6, [0x3EE94AD0, 0x3F3F4B59, 0xBEEF3A66, 0x3E81C358]),
            (7, [0x00000000, 0xBCD35EC9, 0x3CA20A9E, 0xBF2BC51E]),
            (8, [0xBE8C2D15, 0xBEE5E1E3, 0xBF47123F, 0x3E81C358]),
            (9, [0x00000000, 0xBDBE8B4A, 0xBBB3C099, 0xBF2BC51E]),
            (10, [0x3DBDCB1C, 0xBEA7DDA0, 0xBE2676E9, 0x3D220A9D]),
            (11, [0x3DBDCB1C, 0xBEA7DDA0, 0xBE2676E9, 0x3D220A9D]),
            (18, [0x40000000, 0x3DCCCCCD, 0x3E4CCCCD, 0x3F000000]),
            (19, [0x3DCCCCCD, 0x40400000, 0x3E99999A, 0x3F000000]),
            (20, [0x3E4CCCCD, 0x3E99999A, 0x40800000, 0x3F000000]),
            (21, [0x40A00000, 0x3ECCCCCD, 0x3F000000, 0x3E800000]),
            (22, [0x3ECCCCCD, 0x40C00000, 0x3F19999A, 0x3E800000]),
            (23, [0x3F000000, 0x3F19999A, 0x40E00000, 0x3E800000]),
        ];
        for (vector, words) in replacement_vectors {
            built[vector * 4..vector * 4 + 4].copy_from_slice(&words);
        }

        let mut jacobian = RetailJointJacobian { words: built };
        let mut reaction_a = RetailJointReactionBlock::default();
        let mut reaction_b = RetailJointReactionBlock::default();
        solve_joint_iteration(&mut jacobian, &mut reaction_a, &mut reaction_b);
        solve_joint_iteration(&mut jacobian, &mut reaction_a, &mut reaction_b);

        // TU3's VMX fused evaluation and host scalar f32 differ by at most
        // eight measured ULPs on this non-diagonal inertia fixture.
        assert_words_within_ulp(
            &jacobian.words[8..11],
            &[0x3EE1BBA8, 0xBD94F458, 0xBEA28090],
            8,
        );
        assert_words_within_ulp(
            &jacobian.words[12..15],
            &[0x3E9AF7A3, 0xBF53C6BD, 0x3E8B35FD],
            8,
        );
        assert_words_within_ulp(
            &reaction_a.words[0..3],
            &[0xBE54AB98, 0x3E1BFD4C, 0x3DBFB484],
            8,
        );
        assert_words_within_ulp(
            &reaction_a.words[8..11],
            &[0x3F13FD3C, 0x3EF182B0, 0x3F5DA756],
            8,
        );
        assert_words_within_ulp(
            &reaction_b.words[0..3],
            &[0x3DD4AB98, 0xBD9BFD4C, 0xBD3FB484],
            8,
        );
        assert_words_within_ulp(
            &reaction_b.words[8..11],
            &[0xBFABAC56, 0xBF91000E, 0xBF6A9939],
            8,
        );
    }
}
