//! Scalar port of Skate 3 TU3's skateboard drive-frame construction.
//!
//! `SkateboardBody::SetDriveFrames2` (`0x82C0C088`) builds an identity frame
//! for body A and expresses body B relative to body A. The retail matrices are
//! affine column-basis matrices (`Ri`, `Up`, `At`, translation). This module
//! keeps that convention explicit and does not substitute a Bevy joint.

#![allow(dead_code)]

use crate::skateboard_body::{
    BODY_COUNT, Basis3, RETAIL_DECK_MID_LENGTH, RETAIL_TRUCK_ROTATION_AXIS_ANGLE_DEGREES,
    RETAIL_TRUCK_Y_POSITION, RETAIL_TRUCK_Z_POSITION_BACK, RETAIL_TRUCK_Z_POSITION_FRONT,
    RETAIL_WHEEL_RADIUS, RetailDriveFrameRaw, RetailDriveFramesRaw, Vector3,
    retail_rigid_body::RetailQuaternion,
};

pub mod tu3 {
    pub const SET_DRIVE_FRAMES_2: u32 = 0x82C0_C088;
    pub const MATRIX_TO_FRAME_A: u32 = 0x82BD_3A10;
    pub const MATRIX_TO_FRAME_B: u32 = 0x82BD_3BD0;
    pub const PART_SET_TRANSFORM: u32 = 0x82BD_4318;
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailAffineTransform {
    /// Column vectors in retail `Ri`, `Up`, `At` order.
    pub basis: Basis3,
    pub translation: Vector3,
}

impl RetailAffineTransform {
    pub const IDENTITY: Self = Self {
        basis: Basis3 {
            columns: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
        },
        translation: Vector3::ZERO,
    };
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailDriveFrame {
    pub orientation: RetailQuaternion,
    pub translation: Vector3,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailDriveFrames {
    pub body_a: RetailDriveFrame,
    pub body_b: RetailDriveFrame,
}

/// Inputs read by TU3 `SkateboardBody::CalculateTruckTransforms`.
///
/// The two longitudinal fields retain the decoded retail attribute names.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailTruckTransformInputs {
    pub deck_mid_length: f32,
    pub truck_z_position_front: f32,
    pub truck_z_position_back: f32,
    pub truck_y_position: f32,
    pub truck_rotation_axis_angle_degrees: f32,
}

pub const RETAIL_DEFAULT_TRUCK_TRANSFORM_INPUTS: RetailTruckTransformInputs =
    RetailTruckTransformInputs {
        deck_mid_length: RETAIL_DECK_MID_LENGTH,
        truck_z_position_front: RETAIL_TRUCK_Z_POSITION_FRONT,
        truck_z_position_back: RETAIL_TRUCK_Z_POSITION_BACK,
        truck_y_position: RETAIL_TRUCK_Y_POSITION,
        truck_rotation_axis_angle_degrees: RETAIL_TRUCK_ROTATION_AXIS_ANGLE_DEGREES,
    };

/// Exact default outputs of `SkateboardBody::CalculateTruckTransforms`
/// (`0x82C0BC90`) at body offsets `0x1e20` and `0x1e60`.
///
/// These values come from static execution of the complete TU3 function with
/// the decoded default attribute records. Keeping the oracle outputs directly
/// avoids replacing `XMVectorSinCos` and the VMX fused operation order with
/// host trigonometry. The returned order is the physical object layout, not an
/// inferred front/back label.
pub const fn default_truck_transforms() -> [RetailAffineTransform; 2] {
    [
        RetailAffineTransform {
            basis: Basis3 {
                columns: [
                    [
                        f32::from_bits(0xB314_1028),
                        f32::from_bits(0x3F03_D987),
                        f32::from_bits(0xBF5B_6F50),
                    ],
                    [
                        0.0,
                        f32::from_bits(0x3F5B_6F51),
                        f32::from_bits(0x3F03_D988),
                    ],
                    [
                        f32::from_bits(0x3F7F_FFFF),
                        f32::from_bits(0x3298_842A),
                        f32::from_bits(0xB2FD_D468),
                    ],
                ],
            },
            translation: Vector3::new(
                0.0,
                f32::from_bits(0xBD67_6C8B),
                f32::from_bits(0xBE78_D4FD),
            ),
        },
        RetailAffineTransform {
            basis: Basis3 {
                columns: [
                    [
                        f32::from_bits(0xB314_1028),
                        f32::from_bits(0x3F03_D987),
                        f32::from_bits(0x3F5B_6F50),
                    ],
                    [
                        0.0,
                        f32::from_bits(0x3F5B_6F51),
                        f32::from_bits(0xBF03_D988),
                    ],
                    [
                        f32::from_bits(0xBF7F_FFFF),
                        f32::from_bits(0xB298_842A),
                        f32::from_bits(0xB2FD_D468),
                    ],
                ],
            },
            translation: Vector3::new(
                0.0,
                f32::from_bits(0xBD67_6C8B),
                f32::from_bits(0x3E78_D4FD),
            ),
        },
    ]
}

/// Exact seven part transforms passed by `SkateboardBody::InitializeTransforms`
/// (`0x82C0ADF0`) to `Part::SetTransform` before the external deck transform.
///
/// These are authored part transforms, not a claim about the resulting live
/// rigid-body center-of-mass frames. Static execution of the complete TU3
/// function shows that front truck part 4 is identity-oriented, while rear
/// truck part 5 receives the quarter-turn basis below. The conversion through
/// each part's local mass frame remains a separate boundary.
pub const fn default_body_transforms() -> [RetailAffineTransform; BODY_COUNT] {
    const IDENTITY_BASIS: Basis3 = RetailAffineTransform::IDENTITY.basis;
    const LATERAL: f32 = f32::from_bits(0x3DC2_8F5C);
    const VERTICAL: f32 = f32::from_bits(0xBD67_6C8B);
    const POSITIVE_LONGITUDINAL: f32 = f32::from_bits(0x3E78_D4FD);
    const NEGATIVE_LONGITUDINAL: f32 = f32::from_bits(0xBE78_D4FD);
    const REAR_TRUCK_BASIS: Basis3 = Basis3 {
        columns: [
            [
                f32::from_bits(0xB314_1028),
                0.0,
                f32::from_bits(0xBF7F_FFFF),
            ],
            [0.0, 1.0, 0.0],
            [
                f32::from_bits(0x3F7F_FFFF),
                0.0,
                f32::from_bits(0xB314_1028),
            ],
        ],
    };

    [
        RetailAffineTransform {
            basis: IDENTITY_BASIS,
            translation: Vector3::new(-LATERAL, VERTICAL, POSITIVE_LONGITUDINAL),
        },
        RetailAffineTransform {
            basis: IDENTITY_BASIS,
            translation: Vector3::new(LATERAL, VERTICAL, POSITIVE_LONGITUDINAL),
        },
        RetailAffineTransform {
            basis: IDENTITY_BASIS,
            translation: Vector3::new(-LATERAL, VERTICAL, NEGATIVE_LONGITUDINAL),
        },
        RetailAffineTransform {
            basis: IDENTITY_BASIS,
            translation: Vector3::new(LATERAL, VERTICAL, NEGATIVE_LONGITUDINAL),
        },
        RetailAffineTransform {
            basis: IDENTITY_BASIS,
            translation: Vector3::new(0.0, VERTICAL, POSITIVE_LONGITUDINAL),
        },
        RetailAffineTransform {
            basis: REAR_TRUCK_BASIS,
            translation: Vector3::new(0.0, VERTICAL, NEGATIVE_LONGITUDINAL),
        },
        RetailAffineTransform::IDENTITY,
    ]
}

/// Exact live rigid-body center-of-mass frames after the seven authored
/// transforms pass through TU3 `Part::SetTransform` (`0x82BD4318`).
///
/// Wheels and trucks have identity local mass frames, so their live frames
/// equal the authored part frames. The aggregate deck's non-identity local
/// mass frame is inverted by `Part::SetTransform`; the resulting basis and
/// center are retained here from static execution of the complete routine.
pub const fn default_live_body_transforms() -> [RetailAffineTransform; BODY_COUNT] {
    let authored = default_body_transforms();
    [
        authored[0],
        authored[1],
        authored[2],
        authored[3],
        authored[4],
        authored[5],
        RetailAffineTransform {
            basis: Basis3 {
                columns: [
                    [
                        f32::from_bits(0x3F80_0000),
                        f32::from_bits(0x315E_BAFD),
                        f32::from_bits(0x3164_DA5E),
                    ],
                    [
                        f32::from_bits(0xB15E_88DF),
                        f32::from_bits(0x3F7F_FFFA),
                        f32::from_bits(0xBA60_264B),
                    ],
                    [
                        f32::from_bits(0xB165_0B19),
                        f32::from_bits(0x3A60_264B),
                        f32::from_bits(0x3F7F_FFFA),
                    ],
                ],
            },
            translation: Vector3::new(
                f32::from_bits(0x3109_59B6),
                f32::from_bits(0x3BF4_361F),
                f32::from_bits(0x3B16_51B4),
            ),
        },
    ]
}

/// Exact quaternions written to the seven live rigid bodies by
/// `Part::SetTransform`.
///
/// Keeping the deck oracle value separately avoids a one-ULP host arithmetic
/// difference in the scalar matrix-to-quaternion helper.
pub const fn default_live_body_orientations() -> [RetailQuaternion; BODY_COUNT] {
    const IDENTITY: RetailQuaternion = RetailQuaternion::IDENTITY;
    [
        IDENTITY,
        IDENTITY,
        IDENTITY,
        IDENTITY,
        IDENTITY,
        RetailQuaternion {
            x: 0.0,
            y: f32::from_bits(0x3F35_04F3),
            z: 0.0,
            w: f32::from_bits(0x3F35_04F3),
        },
        RetailQuaternion {
            x: f32::from_bits(0xB9E0_264C),
            y: f32::from_bits(0xB0E4_F2BD),
            z: f32::from_bits(0x30DE_A1EF),
            w: f32::from_bits(0x3F7F_FFFE),
        },
    ]
}

/// Deck-center height that places the initialized wheel spheres exactly on a
/// level Y=0 riding surface.
///
/// This is a geometry-derived fixture placement, not a tuned suspension or
/// contact constant.
pub const RETAIL_LEVEL_GROUND_DECK_CENTER_HEIGHT: f32 =
    RETAIL_WHEEL_RADIUS - RETAIL_TRUCK_Y_POSITION;

/// Exact zero-runtime-angle truck/deck frames emitted at `this+0x1a70` and
/// `this+0x1ab0` by `SetTruckDriveFrames`.
///
/// Frame A belongs to internal `Drive::m_bodyA` (truck 4 or 5) and frame B
/// belongs to internal `Drive::m_bodyB` (deck 6). `Simulation::AddDrive`
/// receives deck/truck but stores its second body argument at `Drive+0x10`
/// (`m_bodyA`) and its first at `Drive+0x14` (`m_bodyB`). The raw frame values
/// were captured by static execution of the complete TU3 matrix and quaternion
/// helpers after `CalculateTruckTransforms`.
pub const fn default_truck_drive_frames() -> [RetailDriveFrames; 2] {
    [
        RetailDriveFrames {
            body_a: RetailDriveFrame {
                orientation: RetailQuaternion::IDENTITY,
                translation: Vector3::ZERO,
            },
            body_b: RetailDriveFrame {
                orientation: RetailQuaternion {
                    x: f32::from_bits(0xBE41_8051),
                    y: f32::from_bits(0xBF2E_6F8D),
                    z: f32::from_bits(0x3E41_804F),
                    w: f32::from_bits(0x3F2E_6F8D),
                },
                translation: Vector3::new(
                    0.0,
                    f32::from_bits(0xBD67_6C8B),
                    f32::from_bits(0x3E78_D4FD),
                ),
            },
        },
        RetailDriveFrames {
            body_a: RetailDriveFrame {
                orientation: RetailQuaternion::IDENTITY,
                translation: Vector3::ZERO,
            },
            body_b: RetailDriveFrame {
                orientation: RetailQuaternion {
                    x: f32::from_bits(0x3E41_8051),
                    y: f32::from_bits(0x3F2E_6F8D),
                    z: f32::from_bits(0x3E41_804F),
                    w: f32::from_bits(0x3F2E_6F8D),
                },
                translation: Vector3::new(
                    0.0,
                    f32::from_bits(0xBD67_6C8B),
                    f32::from_bits(0xBE78_D4FD),
                ),
            },
        },
    ]
}

/// Exact frames emitted by `CreateWheelDrives`.
///
/// The four `AddDrive` API calls pass `(truck4,wheel0)`, `(truck4,wheel1)`,
/// `(truck5,wheel2)`, and `(truck5,wheel3)`. Internally that makes each wheel
/// `m_bodyA` and its truck `m_bodyB`. TU3 passes alternating translation
/// matrices into `SetDriveFrames2`, which stores identity for internal body A
/// and the signed `WheelXDist` offset for internal body B.
pub const fn default_wheel_drive_frames() -> [RetailDriveFrames; 4] {
    const FRAME_A: RetailDriveFrame = RetailDriveFrame {
        orientation: RetailQuaternion::IDENTITY,
        translation: Vector3::ZERO,
    };
    const POSITIVE: RetailDriveFrame = RetailDriveFrame {
        orientation: RetailQuaternion::IDENTITY,
        translation: Vector3::new(0.0, 0.0, f32::from_bits(0x3DC2_8F5C)),
    };
    const NEGATIVE: RetailDriveFrame = RetailDriveFrame {
        orientation: RetailQuaternion::IDENTITY,
        translation: Vector3::new(0.0, 0.0, f32::from_bits(0xBDC2_8F5C)),
    };

    [
        RetailDriveFrames {
            body_a: FRAME_A,
            body_b: POSITIVE,
        },
        RetailDriveFrames {
            body_a: FRAME_A,
            body_b: NEGATIVE,
        },
        RetailDriveFrames {
            body_a: FRAME_A,
            body_b: POSITIVE,
        },
        RetailDriveFrames {
            body_a: FRAME_A,
            body_b: NEGATIVE,
        },
    ]
}

/// Port of `SkateboardBody::SetDriveFrames2`.
///
/// Static execution of the recovered TU3 function proves that body A's drive
/// frame is identity and body B's frame is:
///
/// - orientation: `transpose(A.basis) * B.basis`;
/// - translation: `transpose(A.basis) * (B.translation - A.translation)`.
///
/// The helper's quaternion lane order is `(x, y, z, w)`.
pub fn set_drive_frames_2(
    body_a_world: RetailAffineTransform,
    body_b_world: RetailAffineTransform,
) -> RetailDriveFrames {
    let relative_basis = transpose_multiply_basis(body_a_world.basis, body_b_world.basis);
    let world_delta = sub(body_b_world.translation, body_a_world.translation);
    let relative_translation = transpose_multiply_vector(body_a_world.basis, world_delta);

    RetailDriveFrames {
        body_a: RetailDriveFrame {
            orientation: RetailQuaternion::IDENTITY,
            translation: Vector3::ZERO,
        },
        body_b: RetailDriveFrame {
            orientation: retail_quaternion_from_basis(relative_basis),
            translation: relative_translation,
        },
    }
}

/// Quaternion conversion used by helpers `0x82BD3A10`/`0x82BD3BD0`.
///
/// The recovered helper uses the trace form directly. It does not switch to a
/// largest-diagonal branch at a 180-degree relative rotation; the retail
/// function consequently produces non-finite lanes for that singular input.
/// Preserving this behavior is important evidence that this is not a generic
/// matrix-to-quaternion replacement.
pub fn retail_quaternion_from_basis(basis: Basis3) -> RetailQuaternion {
    let m00 = basis.columns[0][0];
    let m11 = basis.columns[1][1];
    let m22 = basis.columns[2][2];
    let w = 0.5 * (1.0 + m00 + m11 + m22).sqrt();
    let inverse_four_w = (4.0 * w).recip();

    RetailQuaternion {
        x: (basis.columns[1][2] - basis.columns[2][1]) * inverse_four_w,
        y: (basis.columns[2][0] - basis.columns[0][2]) * inverse_four_w,
        z: (basis.columns[0][1] - basis.columns[1][0]) * inverse_four_w,
        w,
    }
}

impl From<RetailDriveFrames> for RetailDriveFramesRaw {
    fn from(frames: RetailDriveFrames) -> Self {
        Self {
            body_a: raw_frame(frames.body_a),
            body_b: raw_frame(frames.body_b),
        }
    }
}

fn raw_frame(frame: RetailDriveFrame) -> RetailDriveFrameRaw {
    RetailDriveFrameRaw {
        quaternion_lanes: [
            frame.orientation.x.to_bits(),
            frame.orientation.y.to_bits(),
            frame.orientation.z.to_bits(),
            frame.orientation.w.to_bits(),
        ],
        translation_lanes: [
            frame.translation.x.to_bits(),
            frame.translation.y.to_bits(),
            frame.translation.z.to_bits(),
            0,
        ],
    }
}

fn transpose_multiply_basis(a: Basis3, b: Basis3) -> Basis3 {
    Basis3 {
        columns: core::array::from_fn(|column| {
            let b_column = vector_from_column(b.columns[column]);
            [
                dot(vector_from_column(a.columns[0]), b_column),
                dot(vector_from_column(a.columns[1]), b_column),
                dot(vector_from_column(a.columns[2]), b_column),
            ]
        }),
    }
}

fn transpose_multiply_vector(basis: Basis3, vector: Vector3) -> Vector3 {
    Vector3::new(
        dot(vector_from_column(basis.columns[0]), vector),
        dot(vector_from_column(basis.columns[1]), vector),
        dot(vector_from_column(basis.columns[2]), vector),
    )
}

const fn vector_from_column(column: [f32; 3]) -> Vector3 {
    Vector3::new(column[0], column[1], column[2])
}

const fn sub(a: Vector3, b: Vector3) -> Vector3 {
    Vector3::new(a.x - b.x, a.y - b.y, a.z - b.z)
}

const fn dot(a: Vector3, b: Vector3) -> f32 {
    a.x * b.x + a.y * b.y + a.z * b.z
}

#[cfg(test)]
mod tests {
    use super::*;

    fn quarter_turn_y() -> Basis3 {
        Basis3 {
            columns: [[0.0, 0.0, -1.0], [0.0, 1.0, 0.0], [1.0, 0.0, 0.0]],
        }
    }

    #[test]
    fn identity_pair_matches_tu3_static_oracle() {
        let frames = set_drive_frames_2(
            RetailAffineTransform::IDENTITY,
            RetailAffineTransform::IDENTITY,
        );

        assert_eq!(frames.body_a.orientation, RetailQuaternion::IDENTITY);
        assert_eq!(frames.body_a.translation, Vector3::ZERO);
        assert_eq!(frames.body_b.orientation, RetailQuaternion::IDENTITY);
        assert_eq!(frames.body_b.translation, Vector3::ZERO);
    }

    #[test]
    fn relative_translation_matches_tu3_static_oracle() {
        let frames = set_drive_frames_2(
            RetailAffineTransform {
                basis: quarter_turn_y(),
                translation: Vector3::new(1.0, 2.0, 3.0),
            },
            RetailAffineTransform {
                basis: RetailAffineTransform::IDENTITY.basis,
                translation: Vector3::new(4.0, 6.0, 8.0),
            },
        );

        assert_eq!(frames.body_b.translation, Vector3::new(-5.0, 4.0, 3.0));
        assert_eq!(frames.body_b.orientation.x.to_bits(), 0);
        assert_eq!(frames.body_b.orientation.y.to_bits(), 0xBF35_04F3);
        assert_eq!(frames.body_b.orientation.z.to_bits(), 0);
        assert_eq!(frames.body_b.orientation.w.to_bits(), 0x3F35_04F3);
    }

    #[test]
    fn body_b_quarter_turn_matches_tu3_lane_order() {
        let frames = set_drive_frames_2(
            RetailAffineTransform::IDENTITY,
            RetailAffineTransform {
                basis: quarter_turn_y(),
                translation: Vector3::ZERO,
            },
        );

        assert_eq!(frames.body_b.orientation.x.to_bits(), 0);
        assert_eq!(frames.body_b.orientation.y.to_bits(), 0x3F35_04F3);
        assert_eq!(frames.body_b.orientation.z.to_bits(), 0);
        assert_eq!(frames.body_b.orientation.w.to_bits(), 0x3F35_04F3);
    }

    #[test]
    fn retail_trace_path_retains_180_degree_singularity() {
        let quaternion = retail_quaternion_from_basis(Basis3 {
            columns: [[1.0, 0.0, 0.0], [0.0, -1.0, 0.0], [0.0, 0.0, -1.0]],
        });

        assert!(!quaternion.x.is_finite());
        assert!(!quaternion.y.is_finite());
        assert!(!quaternion.z.is_finite());
        assert_eq!(quaternion.w.to_bits(), 0);
    }

    #[test]
    fn raw_layout_is_xyzw_then_xyz_zero() {
        let raw = RetailDriveFramesRaw::from(set_drive_frames_2(
            RetailAffineTransform::IDENTITY,
            RetailAffineTransform {
                basis: quarter_turn_y(),
                translation: Vector3::new(4.0, 6.0, 8.0),
            },
        ));

        assert_eq!(
            raw.body_b.quaternion_lanes,
            [0, 0x3F35_04F3, 0, 0x3F35_04F3]
        );
        assert_eq!(
            raw.body_b.translation_lanes,
            [4.0f32.to_bits(), 6.0f32.to_bits(), 8.0f32.to_bits(), 0]
        );
    }

    #[test]
    fn default_truck_transforms_match_static_tu3_oracle_bit_for_bit() {
        assert_eq!(
            RETAIL_DEFAULT_TRUCK_TRANSFORM_INPUTS,
            RetailTruckTransformInputs {
                deck_mid_length: f32::from_bits(0x3F17_0A3D),
                truck_z_position_front: f32::from_bits(0xBD54_FDF4),
                truck_z_position_back: f32::from_bits(0xBD54_FDF4),
                truck_y_position: f32::from_bits(0xBD67_6C8B),
                truck_rotation_axis_angle_degrees: f32::from_bits(0x41F8_0000),
            }
        );
        let [offset_1e20, offset_1e60] = default_truck_transforms();

        assert_eq!(
            offset_1e20
                .basis
                .columns
                .map(|column| column.map(f32::to_bits)),
            [
                [0xB314_1028, 0x3F03_D987, 0xBF5B_6F50],
                [0, 0x3F5B_6F51, 0x3F03_D988],
                [0x3F7F_FFFF, 0x3298_842A, 0xB2FD_D468],
            ]
        );
        assert_eq!(
            offset_1e60
                .basis
                .columns
                .map(|column| column.map(f32::to_bits)),
            [
                [0xB314_1028, 0x3F03_D987, 0x3F5B_6F50],
                [0, 0x3F5B_6F51, 0xBF03_D988],
                [0xBF7F_FFFF, 0xB298_842A, 0xB2FD_D468],
            ]
        );
        assert_eq!(
            [
                offset_1e20.translation.x.to_bits(),
                offset_1e20.translation.y.to_bits(),
                offset_1e20.translation.z.to_bits(),
            ],
            [0, 0xBD67_6C8B, 0xBE78_D4FD]
        );
        assert_eq!(
            [
                offset_1e60.translation.x.to_bits(),
                offset_1e60.translation.y.to_bits(),
                offset_1e60.translation.z.to_bits(),
            ],
            [0, 0xBD67_6C8B, 0x3E78_D4FD]
        );
    }

    #[test]
    fn initialized_part_transforms_match_tu3_static_oracle_bits() {
        let bodies = default_body_transforms();

        let expected_positions = [
            [0xBDC2_8F5C, 0xBD67_6C8B, 0x3E78_D4FD],
            [0x3DC2_8F5C, 0xBD67_6C8B, 0x3E78_D4FD],
            [0xBDC2_8F5C, 0xBD67_6C8B, 0xBE78_D4FD],
            [0x3DC2_8F5C, 0xBD67_6C8B, 0xBE78_D4FD],
            [0x0000_0000, 0xBD67_6C8B, 0x3E78_D4FD],
            [0x0000_0000, 0xBD67_6C8B, 0xBE78_D4FD],
            [0x0000_0000, 0x0000_0000, 0x0000_0000],
        ];
        for (body, expected) in bodies.iter().zip(expected_positions) {
            assert_eq!(
                [
                    body.translation.x.to_bits(),
                    body.translation.y.to_bits(),
                    body.translation.z.to_bits(),
                ],
                expected
            );
        }

        assert_eq!(bodies[0].basis, RetailAffineTransform::IDENTITY.basis);
        assert_eq!(bodies[1].basis, RetailAffineTransform::IDENTITY.basis);
        assert_eq!(bodies[2].basis, RetailAffineTransform::IDENTITY.basis);
        assert_eq!(bodies[3].basis, RetailAffineTransform::IDENTITY.basis);
        assert_eq!(bodies[4].basis, RetailAffineTransform::IDENTITY.basis);
        assert_eq!(
            bodies[5]
                .basis
                .columns
                .map(|column| column.map(f32::to_bits)),
            [
                [0xB314_1028, 0, 0xBF7F_FFFF],
                [0, 0x3F80_0000, 0],
                [0x3F7F_FFFF, 0, 0xB314_1028],
            ]
        );
        assert_eq!(bodies[6], RetailAffineTransform::IDENTITY);
    }

    #[test]
    fn live_body_transforms_include_the_retail_deck_mass_frame_conversion() {
        let bodies = default_live_body_transforms();
        assert_eq!(&bodies[..6], &default_body_transforms()[..6]);
        assert_eq!(
            bodies[6]
                .basis
                .columns
                .map(|column| column.map(f32::to_bits)),
            [
                [0x3F80_0000, 0x315E_BAFD, 0x3164_DA5E],
                [0xB15E_88DF, 0x3F7F_FFFA, 0xBA60_264B],
                [0xB165_0B19, 0x3A60_264B, 0x3F7F_FFFA],
            ]
        );
        assert_eq!(
            [
                bodies[6].translation.x.to_bits(),
                bodies[6].translation.y.to_bits(),
                bodies[6].translation.z.to_bits(),
            ],
            [0x3109_59B6, 0x3BF4_361F, 0x3B16_51B4]
        );
        let deck_orientation = default_live_body_orientations()[6];
        assert_eq!(
            [
                deck_orientation.x.to_bits(),
                deck_orientation.y.to_bits(),
                deck_orientation.z.to_bits(),
                deck_orientation.w.to_bits(),
            ],
            [0xB9E0_264C, 0xB0E4_F2BD, 0x30DE_A1EF, 0x3F7F_FFFE]
        );
    }

    #[test]
    fn derived_level_spawn_places_all_four_wheel_spheres_on_y_zero() {
        let bodies = default_body_transforms();

        assert_eq!(
            RETAIL_LEVEL_GROUND_DECK_CENTER_HEIGHT.to_bits(),
            f32::from_bits(0x3DB3_3333).to_bits()
        );
        for wheel in &bodies[..4] {
            let wheel_bottom =
                RETAIL_LEVEL_GROUND_DECK_CENTER_HEIGHT + wheel.translation.y - RETAIL_WHEEL_RADIUS;
            assert!(wheel_bottom.abs() <= f32::EPSILON);
        }
    }

    #[test]
    fn default_truck_drive_frames_match_static_tu3_oracle_bit_for_bit() {
        let raw = default_truck_drive_frames().map(RetailDriveFramesRaw::from);

        assert_eq!(
            raw[0],
            RetailDriveFramesRaw {
                body_a: RetailDriveFrameRaw {
                    quaternion_lanes: [0, 0, 0, 0x3F80_0000],
                    translation_lanes: [0; 4],
                },
                body_b: RetailDriveFrameRaw {
                    quaternion_lanes: [0xBE41_8051, 0xBF2E_6F8D, 0x3E41_804F, 0x3F2E_6F8D],
                    translation_lanes: [0, 0xBD67_6C8B, 0x3E78_D4FD, 0],
                },
            }
        );
        assert_eq!(
            raw[1],
            RetailDriveFramesRaw {
                body_a: RetailDriveFrameRaw {
                    quaternion_lanes: [0, 0, 0, 0x3F80_0000],
                    translation_lanes: [0; 4],
                },
                body_b: RetailDriveFrameRaw {
                    quaternion_lanes: [0x3E41_8051, 0x3F2E_6F8D, 0x3E41_804F, 0x3F2E_6F8D],
                    translation_lanes: [0, 0xBD67_6C8B, 0xBE78_D4FD, 0],
                },
            }
        );
    }

    #[test]
    fn default_wheel_drive_frames_preserve_retail_pair_order_and_signs() {
        let raw = default_wheel_drive_frames().map(RetailDriveFramesRaw::from);
        let expected = [0x3DC2_8F5C, 0xBDC2_8F5C, 0x3DC2_8F5C, 0xBDC2_8F5C];

        for (frames, expected_z) in raw.into_iter().zip(expected) {
            assert_eq!(frames.body_a.quaternion_lanes, [0, 0, 0, 0x3F80_0000]);
            assert_eq!(frames.body_a.translation_lanes, [0; 4]);
            assert_eq!(frames.body_b.quaternion_lanes, [0, 0, 0, 0x3F80_0000]);
            assert_eq!(frames.body_b.translation_lanes, [0, 0, expected_z, 0]);
        }
    }
}
