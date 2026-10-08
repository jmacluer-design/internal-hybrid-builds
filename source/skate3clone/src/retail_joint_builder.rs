//! Semantic port of TU3 `rw::physics::JointJacobian::Build`.
//!
//! This module is intentionally separate from generic engine joints.  It
//! accepts the exact 64-byte parameter and 80-byte frame records emitted by
//! `SkateboardBody::CreateJoints`, plus the rigid-body fields read by
//! `0x82AE3BC8`, and emits the 384-byte workspace consumed by the joint branch
//! of `0x82AE27D0`.
//!
//! Evidence labels used below:
//! - **Observed**: direct field loads, stores, constants, or branches in TU3.
//! - **Derived**: scalar algebra preserving the observed VMX data flow.
//! - **Inferred**: source-level naming where the executable has no type name.

#![allow(dead_code)]

use crate::skateboard_body::{
    Basis3, Vector3,
    retail_joint_records::{RetailJointFramesRaw, RetailJointParametersRaw},
    retail_joint_solver::RetailJointJacobian,
    retail_rigid_body::{
        RetailPackedWorldInverseInertia, RetailQuaternion, multiply_packed_world_inverse_inertia,
    },
};

pub mod tu3 {
    pub const JOINT_BATCH_BUILD: u32 = 0x82AE_39D0;
    pub const JOINT_JACOBIAN_BUILD: u32 = 0x82AE_3BC8;
    pub const JACOBIAN_RQD_CREATE: u32 = 0x82AE_0DB0;
    pub const ITERATIVE_CONSTRAINT_SOLVER: u32 = 0x82AE_27D0;

    pub const ACTIVE_BODY: u32 = 4;
    pub const JACOBIAN_BYTES: usize = 0x180;
    pub const JACOBIAN_WORDS: usize = JACOBIAN_BYTES / 4;

    /// Observed TU3 vector constant used as the finite "unbounded" value.
    pub const FINITE_INFINITY: f32 = f32::from_bits(0x7F7F_FFFF);
    /// Observed singularity guard initialized at `0x830BDE50`.
    pub const NEAR_PARALLEL: f32 = f32::from_bits(0x3F7F_FF58);
}

/// Explicit body snapshot consumed by `JointJacobian::Build`.
///
/// All fields are **Observed** inputs.  `basis` is kept separate from
/// `orientation` because TU3 reads both rather than rebuilding one from the
/// other.  Likewise the reaction address is metadata copied into the raw
/// Jacobian; this port never dereferences it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailJointBodyInput {
    pub reaction_guest_address: u32,
    pub state: u32,
    pub orientation: RetailQuaternion,
    pub center_of_mass: Vector3,
    pub basis: Basis3,
    pub linear_velocity: Vector3,
    pub angular_velocity: Vector3,
    pub force_acceleration: Vector3,
    pub torque_acceleration: Vector3,
    pub inverse_mass: f32,
    pub world_inverse_inertia: RetailPackedWorldInverseInertia,
}

/// Complete explicit call state for TU3 `JointJacobian::Build`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailJointBuildInput {
    /// **Observed** 64-byte record at `Joint+4`.
    pub parameters: RetailJointParametersRaw,
    /// **Observed** 80-byte record at `Joint+0`.
    pub frames: RetailJointFramesRaw,
    /// **Observed** body at `Joint+0x10`.
    pub body_a: RetailJointBodyInput,
    /// **Observed** body at `Joint+0x14`.
    pub body_b: RetailJointBodyInput,
    /// **Observed** `Simulation+0xA0`.
    pub time_step: f32,
    /// **Observed** source `Joint*`, retained in vector 12's fourth word.
    pub joint_guest_address: u32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct JointParameters {
    linear_position_allowance: Vector3,
    linear_velocity_allowance: Vector3,
    twist_velocity_allowance: f32,
    swing_velocity_allowance: f32,
    swing_threshold: f32,
    twist_threshold: f32,
    swing_mode: u32,
    twist_mode: u32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct JointFrames {
    orientation_a: RetailQuaternion,
    anchor_a: Vector3,
    orientation_b: RetailQuaternion,
    anchor_b: Vector3,
    linear_orientation_b: RetailQuaternion,
}

#[derive(Clone, Copy, Debug)]
struct Rqd {
    relative: RetailQuaternion,
    axes: [Vector3; 3],
}

/// Builds TU3's fixed six-lane, 384-byte joint workspace.
///
/// The three linear and three angular accumulators begin at zero because the
/// retail builder clears all three 128-byte cache lines on every batch build.
pub fn build_retail_joint_jacobian(input: RetailJointBuildInput) -> RetailJointJacobian {
    debug_assert!(input.time_step.is_finite() && input.time_step > 0.0);

    let parameters = decode_parameters(input.parameters);
    let frames = decode_frames(input.frames);
    let active_a = input.body_a.state & tu3::ACTIVE_BODY != 0;
    let active_b = input.body_b.state & tu3::ACTIVE_BODY != 0;

    // Observed composition order: body orientation followed by local frame.
    let world_orientation_a = quaternion_multiply(input.body_a.orientation, frames.orientation_a);
    let world_orientation_b = quaternion_multiply(input.body_b.orientation, frames.orientation_b);
    let world_linear_orientation =
        quaternion_multiply(input.body_b.orientation, frames.linear_orientation_b);
    let angular_basis_a = basis_from_quaternion_retail(world_orientation_a);
    let angular_basis_b = basis_from_quaternion_retail(world_orientation_b);
    let linear_basis = basis_from_quaternion_retail(world_linear_orientation);

    let arm_a = multiply_basis(input.body_a.basis, frames.anchor_a);
    let arm_b = multiply_basis(input.body_b.basis, frames.anchor_b);
    let linear_axes = basis_columns(linear_basis);
    let relative_matrix = relative_basis(angular_basis_a, angular_basis_b);
    let rqd = create_rqd(world_orientation_a, world_orientation_b);
    let (angular_axes, angular_raw_low, angular_raw_high) = angular_rows(
        parameters,
        angular_basis_a,
        angular_basis_b,
        relative_matrix,
        rqd,
    );

    let inverse_mass_a = if active_a {
        input.body_a.inverse_mass
    } else {
        0.0
    };
    let inverse_mass_b = if active_b {
        input.body_b.inverse_mass
    } else {
        0.0
    };
    let inertia_a = if active_a {
        input.body_a.world_inverse_inertia
    } else {
        zero_inertia()
    };
    let inertia_b = if active_b {
        input.body_b.world_inverse_inertia
    } else {
        zero_inertia()
    };

    let linear_inverse_effective_mass = core::array::from_fn(|index| {
        let angular_jacobian_a = cross(arm_a, linear_axes[index]);
        let angular_jacobian_b = cross(arm_b, linear_axes[index]);
        let denominator = add_ordered(
            add_ordered(inverse_mass_a, inverse_mass_b),
            add_ordered(
                dot3(
                    angular_jacobian_a,
                    multiply_packed_world_inverse_inertia(inertia_a, angular_jacobian_a),
                ),
                dot3(
                    angular_jacobian_b,
                    multiply_packed_world_inverse_inertia(inertia_b, angular_jacobian_b),
                ),
            ),
        );
        denominator.recip()
    });
    let angular_inverse_effective_mass = core::array::from_fn(|index| {
        let axis = angular_axes[index];
        let denominator = add_ordered(
            dot3(axis, multiply_packed_world_inverse_inertia(inertia_a, axis)),
            dot3(axis, multiply_packed_world_inverse_inertia(inertia_b, axis)),
        );
        // Observed factor: the RQD component derivative contributes 1/2.
        0.5 * denominator.recip()
    });

    let point_velocity_a = point_rate(
        input.body_a.linear_velocity,
        input.body_a.angular_velocity,
        arm_a,
    );
    let point_velocity_b = point_rate(
        input.body_b.linear_velocity,
        input.body_b.angular_velocity,
        arm_b,
    );
    let point_acceleration_a = if active_a {
        point_rate(
            input.body_a.force_acceleration,
            input.body_a.torque_acceleration,
            arm_a,
        )
    } else {
        Vector3::ZERO
    };
    let point_acceleration_b = if active_b {
        point_rate(
            input.body_b.force_acceleration,
            input.body_b.torque_acceleration,
            arm_b,
        )
    } else {
        Vector3::ZERO
    };
    let relative_point_rate = add(
        sub(point_velocity_b, point_velocity_a),
        scale(
            sub(point_acceleration_b, point_acceleration_a),
            input.time_step,
        ),
    );
    let predicted_separation = add(
        sub(
            add(input.body_b.center_of_mass, arm_b),
            add(input.body_a.center_of_mass, arm_a),
        ),
        scale(relative_point_rate, input.time_step),
    );
    let local_point_rate = project(relative_point_rate, linear_axes);
    let local_separation = project(predicted_separation, linear_axes);

    let mut linear_low = [0.0; 3];
    let mut linear_high = [0.0; 3];
    let position_allowance = vector_to_array(parameters.linear_position_allowance);
    let velocity_allowance = vector_to_array(parameters.linear_velocity_allowance);
    for lane in 0..3 {
        let displacement_low = local_separation[lane] - position_allowance[lane];
        let displacement_high = local_separation[lane] + position_allowance[lane];
        let velocity_low = input.time_step * (local_point_rate[lane] - velocity_allowance[lane]);
        let velocity_high = input.time_step * (local_point_rate[lane] + velocity_allowance[lane]);
        let raw_low = vmx_max(displacement_low, vmx_min(velocity_low, displacement_high));
        let raw_high = vmx_min(displacement_high, vmx_max(velocity_high, displacement_low));
        linear_low[lane] = raw_low * linear_inverse_effective_mass[lane];
        linear_high[lane] = raw_high * linear_inverse_effective_mass[lane];
    }

    let relative_angular_rate = add(
        sub(input.body_b.angular_velocity, input.body_a.angular_velocity),
        scale(
            sub(
                input.body_b.torque_acceleration,
                input.body_a.torque_acceleration,
            ),
            input.time_step,
        ),
    );
    let local_angular_rate = project(relative_angular_rate, angular_axes);
    let angular_velocity_allowance = [
        parameters.twist_velocity_allowance,
        parameters.swing_velocity_allowance,
        parameters.swing_velocity_allowance,
    ];
    let mut angular_low = [0.0; 3];
    let mut angular_high = [0.0; 3];
    for lane in 0..3 {
        let predicted_low = angular_raw_low[lane] + input.time_step * local_angular_rate[lane];
        let predicted_high = angular_raw_high[lane] + input.time_step * local_angular_rate[lane];
        let velocity_low =
            input.time_step * (local_angular_rate[lane] - angular_velocity_allowance[lane]);
        let velocity_high =
            input.time_step * (local_angular_rate[lane] + angular_velocity_allowance[lane]);
        let raw_low = vmx_max(predicted_low, vmx_min(velocity_low, predicted_high));
        let raw_high = vmx_min(predicted_high, vmx_max(velocity_high, predicted_low));
        angular_low[lane] = raw_low * angular_inverse_effective_mass[lane];
        angular_high[lane] = raw_high * angular_inverse_effective_mass[lane];
    }

    let linear_projection = scaled_projection_columns(linear_axes, linear_inverse_effective_mass);
    let angular_projection =
        scaled_projection_columns(angular_axes, angular_inverse_effective_mass);
    let inertia_columns_a = packed_inertia_columns(inertia_a, inverse_mass_a);
    let inertia_columns_b = packed_inertia_columns(inertia_b, inverse_mass_b);

    let mut output = RetailJointJacobian {
        words: [0; tu3::JACOBIAN_WORDS],
    };
    write_vector(
        &mut output,
        0,
        [
            arm_a.x,
            arm_a.y,
            arm_a.z,
            f32::from_bits(input.body_a.reaction_guest_address),
        ],
    );
    write_vector(
        &mut output,
        1,
        [
            arm_b.x,
            arm_b.y,
            arm_b.z,
            f32::from_bits(input.body_b.reaction_guest_address),
        ],
    );
    // Vectors 2 and 3 are the cleared linear/angular accumulators.
    write_vector(
        &mut output,
        4,
        [
            linear_projection[0][0],
            linear_projection[0][1],
            linear_projection[0][2],
            0.0,
        ],
    );
    write_vector(
        &mut output,
        5,
        [
            angular_projection[0][0],
            angular_projection[0][1],
            angular_projection[0][2],
            0.0,
        ],
    );
    write_vector(
        &mut output,
        6,
        [
            linear_projection[1][0],
            linear_projection[1][1],
            linear_projection[1][2],
            angular_low[0],
        ],
    );
    write_vector(
        &mut output,
        7,
        [
            angular_projection[1][0],
            angular_projection[1][1],
            angular_projection[1][2],
            angular_low[1],
        ],
    );
    write_vector(
        &mut output,
        8,
        [
            linear_projection[2][0],
            linear_projection[2][1],
            linear_projection[2][2],
            angular_high[0],
        ],
    );
    write_vector(
        &mut output,
        9,
        [
            angular_projection[2][0],
            angular_projection[2][1],
            angular_projection[2][2],
            angular_high[1],
        ],
    );
    write_vector(
        &mut output,
        10,
        [linear_low[0], linear_low[1], linear_low[2], angular_low[2]],
    );
    write_vector(
        &mut output,
        11,
        [
            linear_high[0],
            linear_high[1],
            linear_high[2],
            angular_high[2],
        ],
    );
    write_vector(
        &mut output,
        12,
        [
            linear_axes[0].x,
            linear_axes[0].y,
            linear_axes[0].z,
            f32::from_bits(input.joint_guest_address),
        ],
    );
    // The non-xyz axis lanes below are observed VMX carry lanes.  They are
    // retained because the static oracle records them even though the solver
    // consumes only xyz.
    write_vector(
        &mut output,
        13,
        [
            linear_axes[1].x,
            linear_axes[1].y,
            linear_axes[1].z,
            linear_axes[1].x,
        ],
    );
    write_vector(
        &mut output,
        14,
        [
            linear_axes[2].x,
            linear_axes[2].y,
            linear_axes[2].z,
            linear_axes[0].y,
        ],
    );
    for lane in 0..3 {
        write_vector(
            &mut output,
            15 + lane,
            [
                angular_axes[lane].x,
                angular_axes[lane].y,
                angular_axes[lane].z,
                angular_axes[lane].x,
            ],
        );
    }
    for lane in 0..3 {
        write_vector(&mut output, 18 + lane, inertia_columns_a[lane]);
        write_vector(&mut output, 21 + lane, inertia_columns_b[lane]);
    }
    output
}

fn decode_parameters(raw: RetailJointParametersRaw) -> JointParameters {
    JointParameters {
        linear_position_allowance: vector_from_words(&raw.words, 0),
        linear_velocity_allowance: vector_from_words(&raw.words, 4),
        twist_velocity_allowance: f32::from_bits(raw.words[8]),
        swing_velocity_allowance: f32::from_bits(raw.words[9]),
        swing_threshold: f32::from_bits(raw.words[12]),
        twist_threshold: f32::from_bits(raw.words[13]),
        swing_mode: raw.words[14],
        twist_mode: raw.words[15],
    }
}

fn decode_frames(raw: RetailJointFramesRaw) -> JointFrames {
    JointFrames {
        orientation_a: quaternion_from_words(&raw.words, 0),
        anchor_a: vector_from_words(&raw.words, 4),
        orientation_b: quaternion_from_words(&raw.words, 8),
        anchor_b: vector_from_words(&raw.words, 12),
        linear_orientation_b: quaternion_from_words(&raw.words, 16),
    }
}

fn angular_rows(
    parameters: JointParameters,
    basis_a: Basis3,
    basis_b: Basis3,
    relative: [[f32; 3]; 3],
    rqd: Rqd,
) -> ([Vector3; 3], [f32; 3], [f32; 3]) {
    let finite_infinity = tu3::FINITE_INFINITY;
    let mut axes = [Vector3::ZERO; 3];
    let mut low = [-finite_infinity; 3];
    let mut high = [finite_infinity; 3];

    match parameters.swing_mode {
        0 => {
            axes[1] = rqd.axes[1];
            axes[2] = rqd.axes[2];
            low[1] = 2.0 * rqd.relative.y;
            high[1] = low[1];
            low[2] = 2.0 * rqd.relative.z;
            high[2] = low[2];
        }
        1 => {
            let first_a = basis_column(basis_a, 0);
            let first_b = basis_column(basis_b, 0);
            let cross_axis = cross(first_a, first_b);
            let squared = dot3(cross_axis, cross_axis);
            let inverse_length = if squared > 0.0 {
                ppc_vrsqrtefp(squared)
            } else {
                0.0
            };
            axes[1] = scale(cross_axis, inverse_length);
            axes[2] = cross(axes[1], first_a);
            if relative[0][0] < parameters.swing_threshold {
                let correction = (parameters.swing_threshold - relative[0][0]) * inverse_length;
                low[1] = correction;
            }
        }
        2 | 3 => {
            axes[1] = basis_column(basis_b, 1);
            if parameters.twist_mode == 0 {
                axes[2] = rqd.axes[2];
                low[2] = 2.0 * rqd.relative.z;
                high[2] = low[2];
            } else {
                axes[2] = cross(basis_column(basis_a, 0), axes[1]);
                low[2] = -relative[1][0];
                high[2] = low[2];
            }
            if parameters.swing_mode == 2 {
                let denominator = relative[2][0];
                let correction = (parameters.swing_threshold - relative[0][0]) / denominator;
                if denominator >= 0.0 {
                    low[1] = correction;
                } else {
                    high[1] = correction;
                }
            }
        }
        _ => {
            axes[1] = basis_column(basis_b, 1);
            axes[2] = basis_column(basis_b, 2);
        }
    }

    match parameters.twist_mode {
        0 => {
            axes[0] = rqd.axes[0];
            low[0] = 2.0 * rqd.relative.x;
            high[0] = low[0];
        }
        1 => {
            axes[0] = basis_column(basis_a, 0);
            // Derived matrix-index form matching the emitted TU3 subtraction.
            let denominator = relative[2][1] - relative[1][2];
            let correction = ((relative[0][0] + 1.0) * parameters.twist_threshold
                - (relative[1][1] + relative[2][2]))
                / denominator;
            if denominator >= 0.0 {
                low[0] = correction;
            } else {
                high[0] = correction;
            }
        }
        _ => {
            axes[0] = basis_column(basis_b, 0);
        }
    }

    (axes, low, high)
}

fn create_rqd(world_a: RetailQuaternion, world_b: RetailQuaternion) -> Rqd {
    let relative = quaternion_multiply(quaternion_conjugate(world_a), world_b);
    let local_axes = [
        Vector3::new(relative.w, relative.z, -relative.y),
        Vector3::new(-relative.z, relative.w, relative.x),
        Vector3::new(relative.y, -relative.x, relative.w),
    ];
    Rqd {
        relative,
        axes: local_axes.map(|axis| rotate(world_a, axis)),
    }
}

fn relative_basis(a: Basis3, b: Basis3) -> [[f32; 3]; 3] {
    core::array::from_fn(|row| {
        core::array::from_fn(|column| dot3(basis_column(a, row), basis_column(b, column)))
    })
}

fn scaled_projection_columns(
    axes: [Vector3; 3],
    inverse_effective_mass: [f32; 3],
) -> [[f32; 3]; 3] {
    core::array::from_fn(|component| {
        core::array::from_fn(|row| {
            vector_to_array(axes[row])[component] * inverse_effective_mass[row]
        })
    })
}

fn packed_inertia_columns(
    packed: RetailPackedWorldInverseInertia,
    inverse_mass: f32,
) -> [[f32; 4]; 3] {
    [
        [packed.full.x, packed.full.y, packed.full.z, inverse_mass],
        [packed.full.y, packed.split.y, packed.split.z, inverse_mass],
        [packed.full.z, packed.split.z, packed.split.x, inverse_mass],
    ]
}

fn zero_inertia() -> RetailPackedWorldInverseInertia {
    RetailPackedWorldInverseInertia {
        full: Vector3::ZERO,
        split: Vector3::ZERO,
    }
}

fn basis_from_quaternion_retail(q: RetailQuaternion) -> Basis3 {
    // Observed VMX order doubles each quaternion component before the
    // products.  `(x+x)*x` is measurably different from `2*(x*x)` for the
    // retail 45-degree fixture and preserves its `0x3F7FFFFE` residual.
    let doubled_x = q.x + q.x;
    let doubled_y = q.y + q.y;
    let doubled_z = q.z + q.z;
    Basis3 {
        columns: [
            [
                1.0 - (q.y * doubled_y + q.z * doubled_z),
                q.x * doubled_y + q.w * doubled_z,
                q.x * doubled_z - q.w * doubled_y,
            ],
            [
                q.x * doubled_y - q.w * doubled_z,
                1.0 - (q.x * doubled_x + q.z * doubled_z),
                q.y * doubled_z + q.w * doubled_x,
            ],
            [
                q.x * doubled_z + q.w * doubled_y,
                q.y * doubled_z - q.w * doubled_x,
                1.0 - (q.x * doubled_x + q.y * doubled_y),
            ],
        ],
    }
}

fn quaternion_multiply(left: RetailQuaternion, right: RetailQuaternion) -> RetailQuaternion {
    RetailQuaternion {
        x: (left.w * right.x + right.w * left.x) + (left.y * right.z - left.z * right.y),
        y: (left.w * right.y + right.w * left.y) + (left.z * right.x - left.x * right.z),
        z: (left.w * right.z + right.w * left.z) + (left.x * right.y - left.y * right.x),
        w: (left.w * right.w - left.x * right.x) - (left.y * right.y + left.z * right.z),
    }
}

fn quaternion_conjugate(value: RetailQuaternion) -> RetailQuaternion {
    RetailQuaternion {
        x: -value.x,
        y: -value.y,
        z: -value.z,
        w: value.w,
    }
}

fn rotate(orientation: RetailQuaternion, vector: Vector3) -> Vector3 {
    multiply_basis(basis_from_quaternion_retail(orientation), vector)
}

fn point_rate(linear: Vector3, angular: Vector3, arm: Vector3) -> Vector3 {
    add(linear, cross(angular, arm))
}

fn project(vector: Vector3, axes: [Vector3; 3]) -> [f32; 3] {
    axes.map(|axis| dot3(vector, axis))
}

fn multiply_basis(basis: Basis3, vector: Vector3) -> Vector3 {
    Vector3::new(
        (basis.columns[0][0] * vector.x + basis.columns[1][0] * vector.y)
            + basis.columns[2][0] * vector.z,
        (basis.columns[0][1] * vector.x + basis.columns[1][1] * vector.y)
            + basis.columns[2][1] * vector.z,
        (basis.columns[0][2] * vector.x + basis.columns[1][2] * vector.y)
            + basis.columns[2][2] * vector.z,
    )
}

fn basis_columns(basis: Basis3) -> [Vector3; 3] {
    core::array::from_fn(|index| basis_column(basis, index))
}

fn basis_column(basis: Basis3, index: usize) -> Vector3 {
    Vector3::new(
        basis.columns[index][0],
        basis.columns[index][1],
        basis.columns[index][2],
    )
}

fn vector_from_words<const N: usize>(words: &[u32; N], offset: usize) -> Vector3 {
    Vector3::new(
        f32::from_bits(words[offset]),
        f32::from_bits(words[offset + 1]),
        f32::from_bits(words[offset + 2]),
    )
}

fn quaternion_from_words<const N: usize>(words: &[u32; N], offset: usize) -> RetailQuaternion {
    RetailQuaternion {
        x: f32::from_bits(words[offset]),
        y: f32::from_bits(words[offset + 1]),
        z: f32::from_bits(words[offset + 2]),
        w: f32::from_bits(words[offset + 3]),
    }
}

fn vector_to_array(value: Vector3) -> [f32; 3] {
    [value.x, value.y, value.z]
}

fn cross(left: Vector3, right: Vector3) -> Vector3 {
    Vector3::new(
        left.y * right.z - left.z * right.y,
        left.z * right.x - left.x * right.z,
        left.x * right.y - left.y * right.x,
    )
}

fn dot3(left: Vector3, right: Vector3) -> f32 {
    (left.x * right.x + left.y * right.y) + left.z * right.z
}

fn add(left: Vector3, right: Vector3) -> Vector3 {
    Vector3::new(left.x + right.x, left.y + right.y, left.z + right.z)
}

fn sub(left: Vector3, right: Vector3) -> Vector3 {
    Vector3::new(left.x - right.x, left.y - right.y, left.z - right.z)
}

fn scale(value: Vector3, scalar: f32) -> Vector3 {
    Vector3::new(value.x * scalar, value.y * scalar, value.z * scalar)
}

fn add_ordered(left: f32, right: f32) -> f32 {
    left + right
}

/// SSE/VMX lowering selects the second operand for equal or unordered lanes.
fn vmx_min(left: f32, right: f32) -> f32 {
    if left < right { left } else { right }
}

/// SSE/VMX lowering selects the second operand for equal or unordered lanes.
fn vmx_max(left: f32, right: f32) -> f32 {
    if left > right { left } else { right }
}

/// Exact Xenon reciprocal-square-root estimate table used by the static
/// recompilation.  Only the cone branch consumes this approximation.
fn ppc_vrsqrtefp(value: f32) -> f32 {
    const TABLE: [u32; 32] = [
        0x0568_B4FD,
        0x04F3_AF97,
        0x048D_AAA5,
        0x0435_A618,
        0x03E7_A1E4,
        0x03A2_9DFE,
        0x0365_9A5C,
        0x032E_96F8,
        0x02FC_93CA,
        0x02D0_90CE,
        0x02A8_8DFE,
        0x0283_8B57,
        0x0261_88D4,
        0x0243_8673,
        0x0226_8431,
        0x020B_820B,
        0x03D2_7FFA,
        0x0380_7C29,
        0x0338_78AA,
        0x02F9_7572,
        0x02C2_7279,
        0x0292_6FB7,
        0x0266_6D26,
        0x023F_6AC0,
        0x021D_6881,
        0x01FD_6665,
        0x01E1_6468,
        0x01C7_6287,
        0x01AF_60C1,
        0x0199_5F12,
        0x0185_5D79,
        0x0173_5BF4,
    ];

    let bits = value.to_bits();
    let sign = bits >> 31;
    let biased_exp = (bits >> 23) & 0xFF;
    let mantissa = bits & 0x007F_FFFF;
    let result = if bits == 0xFF80_0000 {
        0x7FC0_0000
    } else if biased_exp == 0 {
        if sign != 0 { 0xFF80_0000 } else { 0x7F80_0000 }
    } else if biased_exp == 0xFF {
        if mantissa == 0 { 0 } else { bits | 0x0040_0000 }
    } else if sign != 0 {
        0x7FC0_0000
    } else {
        let unbiased_exp = biased_exp as i32 - 127;
        let index = ((((unbiased_exp as u32) << 4) & 16) | (mantissa >> 19)) ^ 16;
        let interpolation = (mantissa >> 9) & 1023;
        let entry = TABLE[index as usize];
        let slope = entry >> 16;
        let base = (entry << 10) & 0x03FF_FC00;
        let mut raw = base as i32 - (interpolation * slope) as i32;
        let mut result_exp = (127 - biased_exp as i32) >> 1;
        if raw & (1 << 25) == 0 {
            let value = (raw as u32) & 0x01FF_FFFF;
            let leading = value.leading_zeros() as i32;
            let shift = leading - 6;
            result_exp += 6 - leading;
            raw <<= shift;
        }
        if raw & 5 != 0 && raw & 2 != 0 {
            raw += 4;
        }
        let mut result = ((result_exp << 23) as u32).wrapping_add(0x3F80_0000)
            | (((raw as u32) >> 2) & 0x007F_FFFF);
        if ((result >> 23) & 0xFF) == 0 && result & 0x007F_FFFF != 0 {
            result = 0;
        }
        result
    };
    f32::from_bits(result)
}

fn write_vector(output: &mut RetailJointJacobian, vector: usize, value: [f32; 4]) {
    let start = vector * 4;
    for lane in 0..4 {
        output.words[start + lane] = value[lane].to_bits();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const IDENTITY_BASIS: Basis3 = Basis3 {
        columns: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
    };
    const IDENTITY_INERTIA: RetailPackedWorldInverseInertia = RetailPackedWorldInverseInertia {
        full: Vector3::new(1.0, 0.0, 0.0),
        split: Vector3::new(1.0, 1.0, 0.0),
    };
    const TRUCK_ORIENTATION: RetailQuaternion = RetailQuaternion {
        x: f32::from_bits(0xBE41_8051),
        y: f32::from_bits(0xBF2E_6F8D),
        z: f32::from_bits(0x3E41_804F),
        w: f32::from_bits(0x3F2E_6F8D),
    };
    const TRUCK_CENTER: Vector3 = Vector3::new(
        0.0,
        f32::from_bits(0xBD67_6C8B),
        f32::from_bits(0x3E78_D4FD),
    );
    const TRUCK_BASIS: Basis3 = Basis3 {
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
    };

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
    const TRUCK_FRAMES: RetailJointFramesRaw = RetailJointFramesRaw {
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
    const WHEEL_FRAMES: RetailJointFramesRaw = RetailJointFramesRaw {
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
        0x90007100, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,
        0x00000000, 0x00000000, 0x3EFED998, 0x00000000, 0x00000000, 0xBEFDB5D2, 0x3E34E52B,
        0x00000000, 0x3DB49A6E, 0xBEA2CEFF, 0x00000000, 0x33800000, 0xBEFED996, 0x3DC8AAAE,
        0x3D48AAAC, 0x33000002, 0xBEA2CEFF, 0xC5885A98, 0x00000000, 0x3EFFFFFE, 0x337ED998,
        0x3DC8AAAE, 0x3E34E52C, 0x3E800001, 0x3DB49A70, 0x45885A98, 0x3D41AF9C, 0x3D428F5C,
        0x31C1AF9E, 0xBF22CF00, 0x3D41AF9C, 0x3D428F5C, 0x31C1AF9E, 0xBF22CF00, 0x3F800000,
        0x00000000, 0x00000000, 0x90001000, 0x00000000, 0x34000000, 0x3F7FFFFE, 0x00000000,
        0x00000000, 0xBF7FFFFE, 0x34000000, 0x00000000, 0x3F2E6F8C, 0x3E418050, 0x3F2E6F8D,
        0x3F2E6F8C, 0x00000000, 0x34000000, 0x3F7FFFFE, 0x00000000, 0x3E418050, 0xBF2E6F8C,
        0x3E418052, 0x3E418050, 0x3F800000, 0x00000000, 0x00000000, 0x3F800000, 0x00000000,
        0x3F800000, 0x00000000, 0x3F800000, 0x00000000, 0x00000000, 0x3F800000, 0x3F800000,
        0x3F800000, 0x00000000, 0x00000000, 0x3F800000, 0x00000000, 0x3F800000, 0x00000000,
        0x3F800000, 0x00000000, 0x00000000, 0x3F800000, 0x3F800000,
    ];

    fn body(
        reaction_guest_address: u32,
        orientation: RetailQuaternion,
        center_of_mass: Vector3,
        basis: Basis3,
    ) -> RetailJointBodyInput {
        RetailJointBodyInput {
            reaction_guest_address,
            state: tu3::ACTIVE_BODY,
            orientation,
            center_of_mass,
            basis,
            linear_velocity: Vector3::ZERO,
            angular_velocity: Vector3::ZERO,
            force_acceleration: Vector3::new(0.0, f32::from_bits(0xC11C_CCCD), 0.0),
            torque_acceleration: Vector3::ZERO,
            inverse_mass: 1.0,
            world_inverse_inertia: IDENTITY_INERTIA,
        }
    }

    fn truck_fixture() -> RetailJointBuildInput {
        RetailJointBuildInput {
            parameters: TRUCK_PARAMETERS,
            frames: TRUCK_FRAMES,
            body_a: body(
                0x9000_7000,
                RetailQuaternion::IDENTITY,
                Vector3::ZERO,
                IDENTITY_BASIS,
            ),
            body_b: body(0x9000_7100, TRUCK_ORIENTATION, TRUCK_CENTER, TRUCK_BASIS),
            time_step: f32::from_bits(0x3C88_8889),
            joint_guest_address: 0x9000_1000,
        }
    }

    fn wheel_fixture() -> RetailJointBuildInput {
        RetailJointBuildInput {
            parameters: WHEEL_PARAMETERS,
            frames: WHEEL_FRAMES,
            body_a: body(0x9000_7000, TRUCK_ORIENTATION, TRUCK_CENTER, TRUCK_BASIS),
            body_b: body(
                0x9000_7100,
                RetailQuaternion::IDENTITY,
                Vector3::new(
                    f32::from_bits(0x3DC2_8F5C),
                    f32::from_bits(0xBD67_6C8B),
                    f32::from_bits(0x3E78_D4FD),
                ),
                IDENTITY_BASIS,
            ),
            time_step: f32::from_bits(0x3C88_8889),
            joint_guest_address: 0x9000_1000,
        }
    }

    fn assert_semantic_oracle(actual: &[u32; 96], expected: &[u32; 96]) {
        // `+0x4c` and `+0x5c` are unused VMX carry lanes.  The recovered
        // scalar semantics do not consume them, so they are intentionally
        // excluded rather than populated with fixture-specific constants.
        const UNRESOLVED_CARRY_WORDS: [usize; 2] = [19, 23];
        let mut mismatches = Vec::new();
        for index in 0..96 {
            if !UNRESOLVED_CARRY_WORDS.contains(&index) {
                let exact = actual[index] == expected[index];
                let actual_float = f32::from_bits(actual[index]);
                let expected_float = f32::from_bits(expected[index]);
                let absolute_match = actual_float.is_finite()
                    && expected_float.is_finite()
                    && (actual_float - expected_float).abs() <= 1.0e-6;
                let ulp_match = actual_float.is_finite()
                    && expected_float.is_finite()
                    && (actual[index] as i64 - expected[index] as i64).abs() <= 32;
                if !exact && !absolute_match && !ulp_match {
                    mismatches.push(format!(
                        "+0x{:03x}: actual 0x{:08X}, expected 0x{:08X}",
                        index * 4,
                        actual[index],
                        expected[index]
                    ));
                }
            }
        }
        assert!(
            mismatches.is_empty(),
            "oracle mismatches:\n{}",
            mismatches.join("\n")
        );
    }

    #[test]
    fn output_stride_is_the_observed_three_cache_lines() {
        assert_eq!(core::mem::size_of::<RetailJointJacobian>(), 0x180);
    }

    #[test]
    fn truck_build_matches_static_tu3_oracle_semantic_words() {
        let actual = build_retail_joint_jacobian(truck_fixture());
        assert_semantic_oracle(&actual.words, &TRUCK_BUILT);
    }

    #[test]
    fn wheel_build_matches_static_tu3_oracle_semantic_words() {
        let actual = build_retail_joint_jacobian(wheel_fixture());
        assert_semantic_oracle(&actual.words, &WHEEL_BUILT);
    }

    #[test]
    fn inactive_body_contributes_no_mass_or_inertia() {
        let mut input = wheel_fixture();
        input.body_b.state = 0;
        let built = build_retail_joint_jacobian(input);
        assert_eq!(&built.words[84..96], &[0; 12]);
    }
}
