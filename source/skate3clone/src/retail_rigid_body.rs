//! TU3 RenderWare rigid-body accumulation and integration primitives.
//!
//! These routines are ports of the arithmetic in the Skate 3 TU3 executable,
//! not a wrapper around Bevy or a generic rigid-body engine. They intentionally
//! stop before the still-unported contact/drive Jacobian solve.

#![allow(dead_code)]

use crate::skateboard_body::{Basis3, Vector3};

pub mod tu3 {
    /// Per-active-body integration routine called by
    /// `rw::physics::Simulation::BatchIntegrator`.
    pub const BATCH_INTEGRATOR_BODY: u32 = 0x82AE_6590;
    /// `Sk8::Physics::Skateboard::ApplyQueuedSkateboardForces`.
    pub const APPLY_QUEUED_SKATEBOARD_FORCES: u32 = 0x82C0_3718;
}

/// Exact scalar fields read from TU3's `rw::physics::Simulation` by
/// `0x82AE6590`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailSimulationStep {
    pub time_step: f32,
    pub frequency: f32,
    pub cool_down: u32,
    pub minimum_energy: f32,
    pub gravity_acceleration: Vector3,
}

impl RetailSimulationStep {
    pub fn fixed_60_hz(cool_down: u32, minimum_energy: f32, gravity_acceleration: Vector3) -> Self {
        let time_step = f32::from_bits(0x3C88_8889);
        Self {
            time_step,
            frequency: time_step.recip(),
            cool_down,
            minimum_energy,
            gravity_acceleration,
        }
    }
}

/// Exact scalar layout of `rw::physics::Inertia` after its inverse-tensor
/// vector.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailInertiaDynamics {
    pub inverse_tensor: Vector3,
    pub inverse_mass: f32,
    pub spherical: f32,
    pub maximum_linear_velocity: f32,
    pub maximum_angular_velocity: f32,
    pub linear_drag: f32,
    pub angular_drag: f32,
}

/// Local principal-axis frame stored by TU3 `ComputeMassProperties`
/// (`0x82AE7770`) at `PartDefinition + 64`.
///
/// The frame is identity for the rotationally symmetric wheel and truck
/// shapes. The aggregate deck has a small recovered center-of-mass offset and
/// principal-axis rotation that must not be replaced with its visual origin.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailLocalMassFrame {
    /// Column vectors in RenderWare `Ri`, `Up`, `At` order.
    pub basis: Basis3,
    pub translation: Vector3,
}

impl RetailLocalMassFrame {
    pub const IDENTITY: Self = Self {
        basis: Basis3 {
            columns: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
        },
        translation: Vector3::ZERO,
    };
}

/// Complete per-part mass data needed by the TU3 rigid-body integrator.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailBodyMassProperties {
    pub local_mass_frame: RetailLocalMassFrame,
    pub dynamics: RetailInertiaDynamics,
}

pub const RETAIL_UNBOUNDED_VELOCITY: f32 = f32::from_bits(0x7F7F_FFFF);
pub const RETAIL_WHEEL_MAXIMUM_ANGULAR_VELOCITY: f32 = f32::from_bits(0x476A_5FFF);

/// Exact wheel mass properties emitted by TU3 `ComputeSimpleInertia`
/// (`0x82AE7228`) and `ComputeMassProperties` (`0x82AE7770`) for the decoded
/// retail wheel mass/radius.
pub const fn retail_wheel_mass_properties() -> RetailBodyMassProperties {
    RetailBodyMassProperties {
        local_mass_frame: RetailLocalMassFrame::IDENTITY,
        dynamics: RetailInertiaDynamics {
            inverse_tensor: Vector3::new(
                f32::from_bits(0x45C3_E491),
                f32::from_bits(0x45C3_E491),
                f32::from_bits(0x45C3_E491),
            ),
            inverse_mass: f32::from_bits(0x401A_3785),
            spherical: f32::from_bits(0x3927_466F),
            maximum_linear_velocity: RETAIL_UNBOUNDED_VELOCITY,
            maximum_angular_velocity: RETAIL_WHEEL_MAXIMUM_ANGULAR_VELOCITY,
            linear_drag: 0.0,
            angular_drag: 0.0,
        },
    }
}

/// Exact truck mass properties emitted by TU3 for the decoded capsule and
/// truck mass.
pub const fn retail_truck_mass_properties() -> RetailBodyMassProperties {
    RetailBodyMassProperties {
        local_mass_frame: RetailLocalMassFrame::IDENTITY,
        dynamics: RetailInertiaDynamics {
            inverse_tensor: Vector3::new(
                f32::from_bits(0x438E_E68E),
                f32::from_bits(0x438E_E68E),
                f32::from_bits(0x4690_4D8B),
            ),
            inverse_mass: f32::from_bits(0x3F03_4835),
            spherical: f32::from_bits(0x3B65_4E66),
            maximum_linear_velocity: RETAIL_UNBOUNDED_VELOCITY,
            maximum_angular_velocity: RETAIL_UNBOUNDED_VELOCITY,
            linear_drag: 0.0,
            angular_drag: 0.0,
        },
    }
}

/// Exact aggregate-deck mass properties after TU3's runtime VMX permutation
/// table initializer (`0x82F83480`) and principal-axis solver (`0x82AE8388`).
///
/// `angular_drag` is the retail `DeckAngularDrag` (`0.45`) multiplied in
/// binary32 by the retail simulation-frequency scalar (`~60`), producing the
/// exact stored value `0x41D7FFFF`.
pub const fn retail_deck_mass_properties() -> RetailBodyMassProperties {
    RetailBodyMassProperties {
        local_mass_frame: RetailLocalMassFrame {
            basis: Basis3 {
                columns: [
                    [
                        f32::from_bits(0x3F80_0000),
                        f32::from_bits(0xB15E_88DE),
                        f32::from_bits(0xB165_0B19),
                    ],
                    [
                        f32::from_bits(0x315E_BAFC),
                        f32::from_bits(0x3F7F_FFFA),
                        f32::from_bits(0x3A60_264B),
                    ],
                    [
                        f32::from_bits(0x3164_DA5D),
                        f32::from_bits(0xBA60_264B),
                        f32::from_bits(0x3F7F_FFFA),
                    ],
                ],
            },
            translation: Vector3::new(
                f32::from_bits(0xB10B_890A),
                f32::from_bits(0xBBF4_25A6),
                f32::from_bits(0xBB16_BC9B),
            ),
        },
        dynamics: RetailInertiaDynamics {
            inverse_tensor: Vector3::new(
                f32::from_bits(0x3FF6_9849),
                f32::from_bits(0x3FEB_B01D),
                f32::from_bits(0x4217_02D7),
            ),
            inverse_mass: f32::from_bits(0x3E2A_AAAB),
            spherical: f32::from_bits(0x3F0B_0803),
            maximum_linear_velocity: RETAIL_UNBOUNDED_VELOCITY,
            maximum_angular_velocity: RETAIL_UNBOUNDED_VELOCITY,
            linear_drag: 0.0,
            angular_drag: f32::from_bits(0x41D7_FFFF),
        },
    }
}

/// Body order used by `SkateboardBody`: wheels 0..3, trucks 4..5, deck 6.
pub const fn default_skateboard_mass_properties() -> [RetailBodyMassProperties; 7] {
    [
        retail_wheel_mass_properties(),
        retail_wheel_mass_properties(),
        retail_wheel_mass_properties(),
        retail_wheel_mass_properties(),
        retail_truck_mass_properties(),
        retail_truck_mass_properties(),
        retail_deck_mass_properties(),
    ]
}

/// The four 16-byte correction vectors indexed by `RigidBody::mId`.
///
/// The first and third vectors participate in the velocity-producing frame
/// displacement. The second and fourth vectors correct position and
/// orientation only. This separation is directly visible in `0x82AE6590`.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RetailReactionCorrections {
    pub linear_displacement: Vector3,
    pub position_displacement: Vector3,
    pub angular_displacement: Vector3,
    pub orientation_displacement: Vector3,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailBodyRates {
    pub orientation: RetailQuaternion,
    pub basis: Basis3,
    pub world_inverse_inertia: Basis3,
    pub position: Vector3,
    pub linear_velocity: Vector3,
    pub angular_velocity: Vector3,
    /// Acceleration accumulator. `RigidBody::AddForce` has already multiplied
    /// physical force by inverse mass before this field reaches the integrator.
    pub force_acceleration: Vector3,
    /// Angular-acceleration accumulator. Point-force torque has already passed
    /// through the body's world inverse inertia.
    pub torque_acceleration: Vector3,
    pub kinetic_energy: f32,
    pub cool_down: u32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailBodyRateStep {
    pub state: RetailBodyRates,
    /// Rotation increment consumed by the quaternion branch in the same retail
    /// function. Keeping this explicit prevents a presentation system from
    /// replacing it with a surface-normal snap.
    pub orientation_displacement: Vector3,
    pub linear_speed_squared: f32,
    pub angular_speed_squared: f32,
}

/// Skate-era RenderWare's six-value packed symmetric world inverse-inertia
/// tensor.
///
/// The lane mapping is:
///
/// - `mIfull = (Ixx, Ixy, Ixz)`;
/// - `mIsplt = (Izz, Iyy, Iyz)`.
///
/// This mapping is observed in the preserved SDK's inlined
/// `RigidBody::InertiaDynamicUpdate` and independently confirmed by one-hot
/// inputs to TU3 `ContactBatchBuild` (`0x82AE10C8`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailPackedWorldInverseInertia {
    pub full: Vector3,
    pub split: Vector3,
}

/// RenderWare quaternion lane order is `(x, y, z, w)`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailQuaternion {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub w: f32,
}

impl RetailQuaternion {
    pub const IDENTITY: Self = Self {
        x: 0.0,
        y: 0.0,
        z: 0.0,
        w: 1.0,
    };
}

/// Port of the translational/rate/cool-down portion of TU3
/// `rw::physics::Simulation::BatchIntegrator` (`0x82AE6590`).
///
/// The order matters:
///
/// 1. acceleration is integrated to a candidate velocity;
/// 2. candidate velocity is converted to a frame displacement;
/// 3. solver correction displacements are added;
/// 4. position is advanced;
/// 5. velocity is reconstructed from displacement with retail drag;
/// 6. linear and angular speed caps are applied;
/// 7. energy/cool-down is updated;
/// 8. force/torque accumulators are reset for the next step.
///
/// This is deliberately not wired to gameplay until contact and drive
/// Jacobians produce the four correction vectors.
pub fn integrate_body_rates(
    mut body: RetailBodyRates,
    inertia: RetailInertiaDynamics,
    simulation: RetailSimulationStep,
    reactions: RetailReactionCorrections,
) -> RetailBodyRateStep {
    debug_assert!(simulation.time_step.is_finite() && simulation.time_step > 0.0);
    debug_assert!(simulation.frequency.is_finite() && simulation.frequency >= 0.0);

    let dt = simulation.time_step;
    let candidate_linear_velocity = add(body.linear_velocity, scale(body.force_acceleration, dt));
    let linear_displacement = add(
        scale(candidate_linear_velocity, dt),
        reactions.linear_displacement,
    );
    body.position = add(
        add(body.position, reactions.position_displacement),
        linear_displacement,
    );

    let candidate_angular_velocity =
        add(body.angular_velocity, scale(body.torque_acceleration, dt));
    let angular_displacement = add(
        scale(candidate_angular_velocity, dt),
        reactions.angular_displacement,
    );
    let orientation_displacement = add(angular_displacement, reactions.orientation_displacement);
    body.orientation = integrate_orientation(body.orientation, orientation_displacement);
    body.basis = basis_from_quaternion(body.orientation);
    body.world_inverse_inertia = world_inverse_inertia(body.basis, inertia.inverse_tensor);

    let angular_frequency = (simulation.frequency - inertia.angular_drag).max(0.0);
    let linear_frequency = (simulation.frequency - inertia.linear_drag).max(0.0);
    body.angular_velocity = clamp_length(
        scale(angular_displacement, angular_frequency),
        inertia.maximum_angular_velocity,
    );
    body.linear_velocity = clamp_length(
        scale(linear_displacement, linear_frequency),
        inertia.maximum_linear_velocity,
    );

    let angular_speed_squared = length_squared(body.angular_velocity);
    let linear_speed_squared = length_squared(body.linear_velocity);
    let kinetic_energy =
        inertia.spherical * inertia.inverse_mass * angular_speed_squared + linear_speed_squared;
    body.cool_down = if kinetic_energy >= simulation.minimum_energy {
        0
    } else {
        let increased = if kinetic_energy <= body.kinetic_energy {
            body.cool_down.saturating_add(1)
        } else {
            body.cool_down
        };
        increased.min(simulation.cool_down)
    };
    body.kinetic_energy = kinetic_energy;

    body.force_acceleration = simulation.gravity_acceleration;
    body.torque_acceleration = Vector3::ZERO;

    RetailBodyRateStep {
        state: body,
        orientation_displacement,
        linear_speed_squared,
        angular_speed_squared,
    }
}

/// Quaternion branch from TU3 `0x82AE66A8..0x82AE67B8`.
///
/// Mapping the VMX128 word permutations back to RenderWare's public
/// `(x,y,z,w)` lane order gives:
///
/// `q += 0.5 * Quaternion(angular_displacement, 0) * q`
///
/// followed by normalization. This pre-multiplication order is important:
/// swapping it changes the board's world-space angular response.
pub fn integrate_orientation(
    orientation: RetailQuaternion,
    angular_displacement: Vector3,
) -> RetailQuaternion {
    let vector = Vector3::new(orientation.x, orientation.y, orientation.z);
    let derivative_vector = add(
        scale(angular_displacement, orientation.w),
        cross(angular_displacement, vector),
    );
    let derivative_w = -dot(angular_displacement, vector);
    normalize_quaternion(RetailQuaternion {
        x: orientation.x + derivative_vector.x * 0.5,
        y: orientation.y + derivative_vector.y * 0.5,
        z: orientation.z + derivative_vector.z * 0.5,
        w: orientation.w + derivative_w * 0.5,
    })
}

/// `Ri`, `Up`, and `At` columns rebuilt immediately after TU3 normalizes the
/// quaternion in `0x82AE6590`.
pub fn basis_from_quaternion(q: RetailQuaternion) -> Basis3 {
    let xx = q.x * q.x;
    let yy = q.y * q.y;
    let zz = q.z * q.z;
    let xy = q.x * q.y;
    let xz = q.x * q.z;
    let yz = q.y * q.z;
    let xw = q.x * q.w;
    let yw = q.y * q.w;
    let zw = q.z * q.w;
    Basis3 {
        columns: [
            [1.0 - 2.0 * (yy + zz), 2.0 * (xy + zw), 2.0 * (xz - yw)],
            [2.0 * (xy - zw), 1.0 - 2.0 * (xx + zz), 2.0 * (yz + xw)],
            [2.0 * (xz + yw), 2.0 * (yz - xw), 1.0 - 2.0 * (xx + yy)],
        ],
    }
}

/// World inverse inertia rebuilt from the normalized body basis and the three
/// body-space inverse-tensor components read from `rw::physics::Inertia`.
pub fn world_inverse_inertia(basis: Basis3, inverse_tensor: Vector3) -> Basis3 {
    let scaled = [
        scale(column(basis, 0), inverse_tensor.x),
        scale(column(basis, 1), inverse_tensor.y),
        scale(column(basis, 2), inverse_tensor.z),
    ];
    let mut columns = [[0.0_f32; 3]; 3];
    for column_index in 0..3 {
        let weight_x = basis.columns[0][column_index];
        let weight_y = basis.columns[1][column_index];
        let weight_z = basis.columns[2][column_index];
        columns[column_index] = [
            scaled[0].x * weight_x + scaled[1].x * weight_y + scaled[2].x * weight_z,
            scaled[0].y * weight_x + scaled[1].y * weight_y + scaled[2].y * weight_z,
            scaled[0].z * weight_x + scaled[1].z * weight_y + scaled[2].z * weight_z,
        ];
    }
    Basis3 { columns }
}

/// Packs a symmetric world inverse-inertia tensor in RenderWare's `mIfull` /
/// `mIsplt` lane order.
pub fn pack_world_inverse_inertia(tensor: Basis3) -> RetailPackedWorldInverseInertia {
    RetailPackedWorldInverseInertia {
        full: Vector3::new(
            tensor.columns[0][0],
            tensor.columns[1][0],
            tensor.columns[2][0],
        ),
        split: Vector3::new(
            tensor.columns[2][2],
            tensor.columns[1][1],
            tensor.columns[2][1],
        ),
    }
}

/// Multiplies a vector by the exact symmetric tensor represented by retail
/// `mIfull` and `mIsplt`.
pub fn multiply_packed_world_inverse_inertia(
    tensor: RetailPackedWorldInverseInertia,
    vector: Vector3,
) -> Vector3 {
    Vector3::new(
        tensor.full.x * vector.x + tensor.full.y * vector.y + tensor.full.z * vector.z,
        tensor.full.y * vector.x + tensor.split.y * vector.y + tensor.split.z * vector.z,
        tensor.full.z * vector.x + tensor.split.z * vector.y + tensor.split.x * vector.z,
    )
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailForceAccumulator {
    pub force_acceleration: Vector3,
    pub torque_acceleration: Vector3,
    pub cool_down: u32,
}

/// Exact point-force accumulation used for every 48-byte skateboard force
/// queue record at `0x82C037DC..0x82C03908`.
///
/// `force_world` is payload 0. `application_point_body` is payload 1 after the
/// retail deck-force Y offset has been added. The deck basis converts that
/// local point to a world-space torque arm. The body inverse mass and world
/// inverse inertia are applied before the integrator sees the accumulators.
pub fn accumulate_point_force(
    mut accumulator: RetailForceAccumulator,
    force_world: Vector3,
    application_point_body: Vector3,
    deck_basis: Basis3,
    inverse_mass: f32,
    world_inverse_inertia: Basis3,
) -> RetailForceAccumulator {
    accumulator.force_acceleration = add(
        accumulator.force_acceleration,
        scale(force_world, inverse_mass),
    );
    let world_arm = multiply_basis(deck_basis, application_point_body);
    let angular_acceleration = multiply_basis(world_inverse_inertia, cross(world_arm, force_world));
    accumulator.torque_acceleration = add(accumulator.torque_acceleration, angular_acceleration);
    accumulator.cool_down = 0;
    accumulator
}

fn multiply_basis(basis: Basis3, vector: Vector3) -> Vector3 {
    Vector3::new(
        basis.columns[0][0] * vector.x
            + basis.columns[1][0] * vector.y
            + basis.columns[2][0] * vector.z,
        basis.columns[0][1] * vector.x
            + basis.columns[1][1] * vector.y
            + basis.columns[2][1] * vector.z,
        basis.columns[0][2] * vector.x
            + basis.columns[1][2] * vector.y
            + basis.columns[2][2] * vector.z,
    )
}

fn column(basis: Basis3, index: usize) -> Vector3 {
    Vector3::new(
        basis.columns[index][0],
        basis.columns[index][1],
        basis.columns[index][2],
    )
}

fn cross(left: Vector3, right: Vector3) -> Vector3 {
    Vector3::new(
        left.y * right.z - left.z * right.y,
        left.z * right.x - left.x * right.z,
        left.x * right.y - left.y * right.x,
    )
}

fn add(left: Vector3, right: Vector3) -> Vector3 {
    Vector3::new(left.x + right.x, left.y + right.y, left.z + right.z)
}

fn scale(value: Vector3, scalar: f32) -> Vector3 {
    Vector3::new(value.x * scalar, value.y * scalar, value.z * scalar)
}

fn length_squared(value: Vector3) -> f32 {
    value.x * value.x + value.y * value.y + value.z * value.z
}

fn dot(left: Vector3, right: Vector3) -> f32 {
    left.x * right.x + left.y * right.y + left.z * right.z
}

fn normalize_quaternion(value: RetailQuaternion) -> RetailQuaternion {
    let squared = value.x * value.x + value.y * value.y + value.z * value.z + value.w * value.w;
    let reciprocal_length = squared.sqrt().recip();
    RetailQuaternion {
        x: value.x * reciprocal_length,
        y: value.y * reciprocal_length,
        z: value.z * reciprocal_length,
        w: value.w * reciprocal_length,
    }
}

fn clamp_length(value: Vector3, maximum: f32) -> Vector3 {
    let squared = length_squared(value);
    let maximum_squared = maximum * maximum;
    if squared > maximum_squared {
        scale(value, (maximum_squared / squared).sqrt())
    } else {
        value
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const IDENTITY: Basis3 = Basis3 {
        columns: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
    };

    fn assert_close(actual: f32, expected: f32) {
        assert!(
            (actual - expected).abs() <= 1.0e-6,
            "actual {actual}, expected {expected}"
        );
    }

    fn assert_vec_close(actual: Vector3, expected: Vector3) {
        assert_close(actual.x, expected.x);
        assert_close(actual.y, expected.y);
        assert_close(actual.z, expected.z);
    }

    fn vector_bits(value: Vector3) -> [u32; 3] {
        [value.x.to_bits(), value.y.to_bits(), value.z.to_bits()]
    }

    #[test]
    fn recovered_skateboard_mass_properties_match_tu3_static_oracle_bits() {
        let bodies = default_skateboard_mass_properties();
        assert_eq!(bodies.len(), 7);
        assert!(bodies[..4].iter().all(|body| *body == bodies[0]));
        assert!(bodies[4..6].iter().all(|body| *body == bodies[4]));

        assert_eq!(
            vector_bits(bodies[0].dynamics.inverse_tensor),
            [0x45C3_E491; 3]
        );
        assert_eq!(bodies[0].dynamics.inverse_mass.to_bits(), 0x401A_3785);
        assert_eq!(bodies[0].dynamics.spherical.to_bits(), 0x3927_466F);
        assert_eq!(
            bodies[0].dynamics.maximum_linear_velocity.to_bits(),
            0x7F7F_FFFF
        );
        assert_eq!(
            bodies[0].dynamics.maximum_angular_velocity.to_bits(),
            0x476A_5FFF
        );

        assert_eq!(
            vector_bits(bodies[4].dynamics.inverse_tensor),
            [0x438E_E68E, 0x438E_E68E, 0x4690_4D8B]
        );
        assert_eq!(bodies[4].dynamics.inverse_mass.to_bits(), 0x3F03_4835);
        assert_eq!(bodies[4].dynamics.spherical.to_bits(), 0x3B65_4E66);

        let deck = bodies[6];
        assert_eq!(
            vector_bits(deck.dynamics.inverse_tensor),
            [0x3FF6_9849, 0x3FEB_B01D, 0x4217_02D7]
        );
        assert_eq!(deck.dynamics.inverse_mass.to_bits(), 0x3E2A_AAAB);
        assert_eq!(deck.dynamics.spherical.to_bits(), 0x3F0B_0803);
        assert_eq!(deck.dynamics.angular_drag.to_bits(), 0x41D7_FFFF);
        assert_eq!(
            vector_bits(deck.local_mass_frame.translation),
            [0xB10B_890A, 0xBBF4_25A6, 0xBB16_BC9B]
        );
        assert_eq!(
            deck.local_mass_frame.basis.columns.map(|column| {
                [
                    column[0].to_bits(),
                    column[1].to_bits(),
                    column[2].to_bits(),
                ]
            }),
            [
                [0x3F80_0000, 0xB15E_88DE, 0xB165_0B19],
                [0x315E_BAFC, 0x3F7F_FFFA, 0x3A60_264B],
                [0x3164_DA5D, 0xBA60_264B, 0x3F7F_FFFA],
            ]
        );
    }

    #[test]
    fn recovered_deck_mass_frame_is_finite_right_handed_and_orthonormal() {
        let frame = retail_deck_mass_properties().local_mass_frame;
        let right = column(frame.basis, 0);
        let up = column(frame.basis, 1);
        let at = column(frame.basis, 2);
        for value in [
            right.x,
            right.y,
            right.z,
            up.x,
            up.y,
            up.z,
            at.x,
            at.y,
            at.z,
            frame.translation.x,
            frame.translation.y,
            frame.translation.z,
        ] {
            assert!(value.is_finite());
        }
        assert!((length_squared(right) - 1.0).abs() < 2.0e-5);
        assert!((length_squared(up) - 1.0).abs() < 2.0e-5);
        assert!((length_squared(at) - 1.0).abs() < 2.0e-5);
        assert!(dot(right, up).abs() < 2.0e-5);
        assert!(dot(right, at).abs() < 2.0e-5);
        assert!(dot(up, at).abs() < 2.0e-5);
        assert!(dot(cross(right, up), at) > 0.99998);
    }

    #[test]
    fn force_accumulator_applies_inverse_mass_and_point_torque() {
        let output = accumulate_point_force(
            RetailForceAccumulator {
                force_acceleration: Vector3::new(1.0, 2.0, 3.0),
                torque_acceleration: Vector3::ZERO,
                cool_down: 7,
            },
            Vector3::new(0.0, 12.0, 0.0),
            Vector3::new(0.0, 0.0, 2.0),
            IDENTITY,
            0.5,
            IDENTITY,
        );
        assert_vec_close(output.force_acceleration, Vector3::new(1.0, 8.0, 3.0));
        assert_vec_close(output.torque_acceleration, Vector3::new(-24.0, 0.0, 0.0));
        assert_eq!(output.cool_down, 0);
    }

    #[test]
    fn body_step_uses_solver_displacements_without_tangent_projection() {
        let simulation = RetailSimulationStep {
            time_step: 0.25,
            frequency: 4.0,
            cool_down: 8,
            minimum_energy: 0.0,
            gravity_acceleration: Vector3::new(0.0, -9.8, 0.0),
        };
        let output = integrate_body_rates(
            RetailBodyRates {
                orientation: RetailQuaternion::IDENTITY,
                basis: IDENTITY,
                world_inverse_inertia: IDENTITY,
                position: Vector3::new(1.0, 2.0, 3.0),
                linear_velocity: Vector3::new(4.0, 0.0, 0.0),
                angular_velocity: Vector3::new(0.0, 2.0, 0.0),
                force_acceleration: Vector3::new(0.0, -4.0, 0.0),
                torque_acceleration: Vector3::ZERO,
                kinetic_energy: 0.0,
                cool_down: 0,
            },
            RetailInertiaDynamics {
                inverse_tensor: Vector3::new(1.0, 1.0, 1.0),
                inverse_mass: 0.5,
                spherical: 1.0,
                maximum_linear_velocity: 100.0,
                maximum_angular_velocity: 100.0,
                linear_drag: 0.0,
                angular_drag: 0.0,
            },
            simulation,
            RetailReactionCorrections {
                linear_displacement: Vector3::new(0.0, 0.25, 0.0),
                position_displacement: Vector3::new(0.0, 0.0, 0.5),
                angular_displacement: Vector3::new(0.0, 0.0, 0.25),
                orientation_displacement: Vector3::new(0.125, 0.0, 0.0),
            },
        );

        assert_vec_close(output.state.position, Vector3::new(2.0, 2.0, 3.5));
        assert_vec_close(output.state.linear_velocity, Vector3::new(4.0, 0.0, 0.0));
        assert_vec_close(output.state.angular_velocity, Vector3::new(0.0, 2.0, 1.0));
        assert_vec_close(
            output.orientation_displacement,
            Vector3::new(0.125, 0.5, 0.25),
        );
        assert_vec_close(
            output.state.force_acceleration,
            simulation.gravity_acceleration,
        );
        assert_vec_close(output.state.torque_acceleration, Vector3::ZERO);
        assert_eq!(
            output.state.orientation,
            integrate_orientation(RetailQuaternion::IDENTITY, output.orientation_displacement)
        );
    }

    #[test]
    fn drag_is_frequency_minus_drag_on_frame_displacement() {
        let output = integrate_body_rates(
            RetailBodyRates {
                orientation: RetailQuaternion::IDENTITY,
                basis: IDENTITY,
                world_inverse_inertia: IDENTITY,
                position: Vector3::ZERO,
                linear_velocity: Vector3::new(8.0, 0.0, 0.0),
                angular_velocity: Vector3::new(0.0, 6.0, 0.0),
                force_acceleration: Vector3::ZERO,
                torque_acceleration: Vector3::ZERO,
                kinetic_energy: 100.0,
                cool_down: 0,
            },
            RetailInertiaDynamics {
                inverse_tensor: Vector3::new(1.0, 1.0, 1.0),
                inverse_mass: 1.0,
                spherical: 1.0,
                maximum_linear_velocity: 100.0,
                maximum_angular_velocity: 100.0,
                linear_drag: 2.0,
                angular_drag: 3.0,
            },
            RetailSimulationStep {
                time_step: 0.25,
                frequency: 4.0,
                cool_down: 8,
                minimum_energy: 0.0,
                gravity_acceleration: Vector3::ZERO,
            },
            RetailReactionCorrections::default(),
        );
        assert_vec_close(output.state.linear_velocity, Vector3::new(4.0, 0.0, 0.0));
        assert_vec_close(output.state.angular_velocity, Vector3::new(0.0, 1.5, 0.0));
    }

    #[test]
    fn speed_caps_and_retail_cool_down_branch_are_separate() {
        let mut body = RetailBodyRates {
            orientation: RetailQuaternion::IDENTITY,
            basis: IDENTITY,
            world_inverse_inertia: IDENTITY,
            position: Vector3::ZERO,
            linear_velocity: Vector3::new(10.0, 0.0, 0.0),
            angular_velocity: Vector3::new(0.0, 8.0, 0.0),
            force_acceleration: Vector3::ZERO,
            torque_acceleration: Vector3::ZERO,
            kinetic_energy: 200.0,
            cool_down: 2,
        };
        let inertia = RetailInertiaDynamics {
            inverse_tensor: Vector3::new(1.0, 1.0, 1.0),
            inverse_mass: 0.5,
            spherical: 2.0,
            maximum_linear_velocity: 3.0,
            maximum_angular_velocity: 2.0,
            linear_drag: 0.0,
            angular_drag: 0.0,
        };
        let simulation = RetailSimulationStep {
            time_step: 0.25,
            frequency: 4.0,
            cool_down: 4,
            minimum_energy: 20.0,
            gravity_acceleration: Vector3::ZERO,
        };
        let first = integrate_body_rates(
            body,
            inertia,
            simulation,
            RetailReactionCorrections::default(),
        );
        assert_close(first.state.linear_velocity.x, 3.0);
        assert_close(first.state.angular_velocity.y, 2.0);
        assert_close(first.state.kinetic_energy, 13.0);
        assert_eq!(first.state.cool_down, 3);

        body = first.state;
        let second = integrate_body_rates(
            body,
            inertia,
            simulation,
            RetailReactionCorrections::default(),
        );
        assert_eq!(second.state.cool_down, 4);
    }

    #[test]
    fn quaternion_branch_uses_retail_left_multiplication_and_normalizes() {
        let quarter_turn_y = RetailQuaternion {
            x: 0.0,
            y: core::f32::consts::FRAC_1_SQRT_2,
            z: 0.0,
            w: core::f32::consts::FRAC_1_SQRT_2,
        };
        let angular = Vector3::new(0.2, 0.3, 0.4);
        let actual = integrate_orientation(quarter_turn_y, angular);

        let old_vector = Vector3::new(quarter_turn_y.x, quarter_turn_y.y, quarter_turn_y.z);
        let left_product_vector = add(scale(angular, quarter_turn_y.w), cross(angular, old_vector));
        let expected = normalize_quaternion(RetailQuaternion {
            x: quarter_turn_y.x + 0.5 * left_product_vector.x,
            y: quarter_turn_y.y + 0.5 * left_product_vector.y,
            z: quarter_turn_y.z + 0.5 * left_product_vector.z,
            w: quarter_turn_y.w - 0.5 * dot(angular, old_vector),
        });
        assert_eq!(actual, expected);
        assert_close(
            actual.x * actual.x + actual.y * actual.y + actual.z * actual.z + actual.w * actual.w,
            1.0,
        );
    }

    #[test]
    fn quaternion_basis_and_world_inverse_inertia_preserve_body_axes() {
        let quarter_turn_y = RetailQuaternion {
            x: 0.0,
            y: core::f32::consts::FRAC_1_SQRT_2,
            z: 0.0,
            w: core::f32::consts::FRAC_1_SQRT_2,
        };
        let basis = basis_from_quaternion(quarter_turn_y);
        assert_vec_close(column(basis, 0), Vector3::new(0.0, 0.0, -1.0));
        assert_vec_close(column(basis, 1), Vector3::new(0.0, 1.0, 0.0));
        assert_vec_close(column(basis, 2), Vector3::new(1.0, 0.0, 0.0));

        let world = world_inverse_inertia(basis, Vector3::new(2.0, 3.0, 5.0));
        assert_vec_close(column(world, 0), Vector3::new(5.0, 0.0, 0.0));
        assert_vec_close(column(world, 1), Vector3::new(0.0, 3.0, 0.0));
        assert_vec_close(column(world, 2), Vector3::new(0.0, 0.0, 2.0));
    }

    #[test]
    fn packed_world_inverse_inertia_uses_retail_lane_order() {
        let symmetric = Basis3 {
            columns: [[2.0, 3.0, 5.0], [3.0, 7.0, 11.0], [5.0, 11.0, 13.0]],
        };
        let packed = pack_world_inverse_inertia(symmetric);
        assert_eq!(packed.full, Vector3::new(2.0, 3.0, 5.0));
        assert_eq!(packed.split, Vector3::new(13.0, 7.0, 11.0));
        assert_vec_close(
            multiply_packed_world_inverse_inertia(packed, Vector3::new(17.0, 19.0, 23.0)),
            multiply_basis(symmetric, Vector3::new(17.0, 19.0, 23.0)),
        );
    }

    #[test]
    fn packed_tensor_one_hot_responses_match_tu3_contact_batch_oracle() {
        let directions = [
            Vector3::new(3.0, 0.0, -1.0),
            Vector3::new(0.0, 3.0, -2.0),
            Vector3::new(2.0, -1.0, 0.0),
        ];
        let cases = [
            (
                RetailPackedWorldInverseInertia {
                    full: Vector3::new(1.0, 0.0, 0.0),
                    split: Vector3::ZERO,
                },
                [
                    Vector3::new(3.0, 0.0, 0.0),
                    Vector3::ZERO,
                    Vector3::new(2.0, 0.0, 0.0),
                ],
            ),
            (
                RetailPackedWorldInverseInertia {
                    full: Vector3::new(0.0, 1.0, 0.0),
                    split: Vector3::ZERO,
                },
                [
                    Vector3::new(0.0, 3.0, 0.0),
                    Vector3::new(3.0, 0.0, 0.0),
                    Vector3::new(-1.0, 2.0, 0.0),
                ],
            ),
            (
                RetailPackedWorldInverseInertia {
                    full: Vector3::new(0.0, 0.0, 1.0),
                    split: Vector3::ZERO,
                },
                [
                    Vector3::new(-1.0, 0.0, 3.0),
                    Vector3::new(-2.0, 0.0, 0.0),
                    Vector3::new(0.0, 0.0, 2.0),
                ],
            ),
            (
                RetailPackedWorldInverseInertia {
                    full: Vector3::ZERO,
                    split: Vector3::new(1.0, 0.0, 0.0),
                },
                [
                    Vector3::new(0.0, 0.0, -1.0),
                    Vector3::new(0.0, 0.0, -2.0),
                    Vector3::ZERO,
                ],
            ),
            (
                RetailPackedWorldInverseInertia {
                    full: Vector3::ZERO,
                    split: Vector3::new(0.0, 1.0, 0.0),
                },
                [
                    Vector3::ZERO,
                    Vector3::new(0.0, 3.0, 0.0),
                    Vector3::new(0.0, -1.0, 0.0),
                ],
            ),
            (
                RetailPackedWorldInverseInertia {
                    full: Vector3::ZERO,
                    split: Vector3::new(0.0, 0.0, 1.0),
                },
                [
                    Vector3::new(0.0, -1.0, 0.0),
                    Vector3::new(0.0, -2.0, 3.0),
                    Vector3::new(0.0, 0.0, -1.0),
                ],
            ),
        ];

        for (tensor, expected) in cases {
            for (direction, expected_response) in directions.into_iter().zip(expected) {
                assert_vec_close(
                    multiply_packed_world_inverse_inertia(tensor, direction),
                    expected_response,
                );
            }
        }
    }
}
