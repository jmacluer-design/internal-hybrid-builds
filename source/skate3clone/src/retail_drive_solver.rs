//! Scalar port of Skate 3 TU3's RenderWare drive Jacobian and solve path.
//!
//! A retail drive is not a generic six-degree-of-freedom Bevy joint. TU3
//! builds three linear and three quaternion-component constraint rows into a
//! 384-byte workspace, then solves each drive sequentially. This module keeps
//! those rows in named scalar fields and preserves the observed soft/hard
//! coefficient and impulse-limit equations.

#![allow(dead_code)]

use crate::skateboard_body::{
    RetailDriveDynamics, RetailDriveParams, RetailDriveType, Vector3,
    retail_drive_frames::{RetailDriveFrame, RetailDriveFrames},
    retail_rigid_body::{
        RetailPackedWorldInverseInertia, RetailQuaternion, RetailReactionCorrections,
        basis_from_quaternion, multiply_packed_world_inverse_inertia,
    },
};

pub mod tu3 {
    pub const DRIVE_JACOBIAN_BUILD: u32 = 0x82AE_1AE8;
    pub const ITERATIVE_CONSTRAINT_SOLVER: u32 = 0x82AE_27D0;
}

pub const ACTIVE_BODY: u32 = 4;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailDriveBodyState {
    pub reaction_index: usize,
    pub state: u32,
    pub orientation: RetailQuaternion,
    pub center_of_mass: Vector3,
    pub linear_velocity: Vector3,
    pub angular_velocity: Vector3,
    pub force_acceleration: Vector3,
    pub torque_acceleration: Vector3,
    pub inverse_mass: f32,
    pub world_inverse_inertia: RetailPackedWorldInverseInertia,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailDriveRows {
    /// Body paired with `DriveFrames::body_a`.
    pub frame_a_body: RetailDriveBodyState,
    /// Body paired with `DriveFrames::body_b`.
    pub frame_b_body: RetailDriveBodyState,
    pub arm_a: Vector3,
    pub arm_b: Vector3,
    /// World-space columns of the frame-B basis.
    pub linear_axes: [Vector3; 3],
    /// Normalized world-space quaternion-component Jacobian axes.
    ///
    /// Unlike an ordinary rotation basis, these three axes are generally not
    /// orthogonal.
    pub angular_axes: [Vector3; 3],
    pub linear_inverse_effective_mass: [f32; 3],
    pub angular_inverse_effective_mass: [f32; 3],
    pub linear_softness: f32,
    pub angular_softness: f32,
    /// Preconditioned target impulses in constraint-row order.
    pub linear_target_impulse: [f32; 3],
    pub angular_target_impulse: [f32; 3],
    pub linear_maximum_impulse: [f32; 3],
    pub angular_maximum_impulse: [f32; 3],
    pub accumulated_linear_impulse: [f32; 3],
    pub accumulated_angular_impulse: [f32; 3],
}

/// Scalar translation of TU3 `DriveJacobian::Build`.
///
/// RenderWare pairs frame A with internal `Drive::m_bodyA` at `Drive+0x10`
/// and frame B with `Drive::m_bodyB` at `Drive+0x14`. `Simulation::AddDrive`
/// stores its second body argument as internal A and its first as internal B.
/// The linear error is frame-B minus frame-A; the solver therefore applies
/// positive impulse to frame A and negative impulse to frame B.
pub fn build_drive_rows(
    frame_a_body: RetailDriveBodyState,
    frame_b_body: RetailDriveBodyState,
    frames: RetailDriveFrames,
    dynamics: RetailDriveDynamics,
    time_step: f32,
) -> RetailDriveRows {
    debug_assert!(time_step.is_finite() && time_step > 0.0);

    let frame_a_world = world_frame(frame_a_body, frames.body_a);
    let frame_b_world = world_frame(frame_b_body, frames.body_b);
    let arm_a = frame_a_world.arm;
    let arm_b = frame_b_world.arm;
    let linear_axes = basis_columns(basis_from_quaternion(frame_b_world.orientation));

    let relative_orientation = multiply_quaternions(
        conjugate(frame_a_world.orientation),
        frame_b_world.orientation,
    );
    let (angular_axes_local, angular_position_error) =
        quaternion_component_rows(relative_orientation);
    let angular_axes = angular_axes_local.map(|axis| rotate(frame_a_world.orientation, axis));

    let linear_position_error = sub(frame_b_world.position, frame_a_world.position);
    let linear_velocity_error = sub(
        point_rate(
            frame_b_body.linear_velocity,
            frame_b_body.angular_velocity,
            arm_b,
        ),
        point_rate(
            frame_a_body.linear_velocity,
            frame_a_body.angular_velocity,
            arm_a,
        ),
    );
    let linear_acceleration_error = sub(
        point_rate(
            frame_b_body.force_acceleration,
            frame_b_body.torque_acceleration,
            arm_b,
        ),
        point_rate(
            frame_a_body.force_acceleration,
            frame_a_body.torque_acceleration,
            arm_a,
        ),
    );
    let linear_position_components = project(linear_position_error, linear_axes);
    let linear_velocity_components = project(linear_velocity_error, linear_axes);
    let linear_acceleration_components = project(linear_acceleration_error, linear_axes);

    let angular_velocity_error = sub(frame_b_body.angular_velocity, frame_a_body.angular_velocity);
    let angular_acceleration_error = sub(
        frame_b_body.torque_acceleration,
        frame_a_body.torque_acceleration,
    );
    let angular_velocity_components = project(angular_velocity_error, angular_axes);
    let angular_acceleration_components = project(angular_acceleration_error, angular_axes);

    let linear_inverse_effective_mass = core::array::from_fn(|index| {
        linear_effective_mass(frame_a_body, frame_b_body, arm_a, arm_b, linear_axes[index]).recip()
    });
    let angular_inverse_effective_mass = core::array::from_fn(|index| {
        angular_effective_mass(frame_a_body, frame_b_body, angular_axes[index]).recip()
    });

    let linear_coefficients = build_coefficients(
        dynamics.linear,
        linear_position_components,
        linear_velocity_components,
        linear_acceleration_components,
        linear_inverse_effective_mass,
        time_step,
    );
    let angular_coefficients = build_coefficients(
        dynamics.angular,
        angular_position_error,
        angular_velocity_components,
        angular_acceleration_components,
        angular_inverse_effective_mass,
        time_step,
    );

    RetailDriveRows {
        frame_a_body,
        frame_b_body,
        arm_a,
        arm_b,
        linear_axes,
        angular_axes,
        linear_inverse_effective_mass,
        angular_inverse_effective_mass,
        linear_softness: linear_coefficients.softness,
        angular_softness: angular_coefficients.softness,
        linear_target_impulse: linear_coefficients.target_impulse,
        angular_target_impulse: angular_coefficients.target_impulse,
        linear_maximum_impulse: linear_coefficients.maximum_impulse,
        angular_maximum_impulse: angular_coefficients.maximum_impulse,
        accumulated_linear_impulse: [0.0; 3],
        accumulated_angular_impulse: [0.0; 3],
    }
}

/// Runs TU3's drive portion of the sequential iterative constraint solver.
pub fn solve_drive_rows(
    drives: &mut [RetailDriveRows],
    reactions: &mut [RetailReactionCorrections],
    maximum_iterations: u32,
) {
    for _ in 0..maximum_iterations {
        solve_drive_iteration(drives, reactions);
    }
}

/// Runs one sequential drive pass.
///
/// This is the unit consumed after contact and joint passes in TU3's shared
/// iteration order. It is intentionally only a factoring of the already
/// recovered drive branch.
pub fn solve_drive_iteration(
    drives: &mut [RetailDriveRows],
    reactions: &mut [RetailReactionCorrections],
) {
    for drive in drives.iter_mut() {
        solve_drive(drive, reactions);
    }
}

fn solve_drive(drive: &mut RetailDriveRows, reactions: &mut [RetailReactionCorrections]) {
    let frame_a_reaction = reactions[drive.frame_a_body.reaction_index];
    let frame_b_reaction = reactions[drive.frame_b_body.reaction_index];
    let point_correction_a =
        point_correction(frame_a_reaction, drive.arm_a, is_active(drive.frame_a_body));
    let point_correction_b =
        point_correction(frame_b_reaction, drive.arm_b, is_active(drive.frame_b_body));
    let relative_point_correction = sub(point_correction_a, point_correction_b);

    let next_linear = solve_row_vector(
        drive.accumulated_linear_impulse,
        drive.linear_target_impulse,
        drive.linear_maximum_impulse,
        drive.linear_softness,
        drive.linear_inverse_effective_mass,
        project(relative_point_correction, drive.linear_axes),
    );
    let linear_delta = subtract_rows(next_linear, drive.accumulated_linear_impulse);
    drive.accumulated_linear_impulse = next_linear;
    let world_linear_impulse = combine_rows(drive.linear_axes, linear_delta);
    apply_point_impulse(
        reactions,
        drive.frame_a_body,
        drive.arm_a,
        world_linear_impulse,
        1.0,
    );
    apply_point_impulse(
        reactions,
        drive.frame_b_body,
        drive.arm_b,
        world_linear_impulse,
        -1.0,
    );

    // TU3 builds the angular candidate after applying the linear impulse, so
    // torque induced by an off-center linear row participates immediately.
    let angular_correction_a = reactions[drive.frame_a_body.reaction_index].angular_displacement;
    let angular_correction_b = reactions[drive.frame_b_body.reaction_index].angular_displacement;
    let relative_angular_correction = sub(angular_correction_a, angular_correction_b);
    let next_angular = solve_row_vector(
        drive.accumulated_angular_impulse,
        drive.angular_target_impulse,
        drive.angular_maximum_impulse,
        drive.angular_softness,
        drive.angular_inverse_effective_mass,
        project(relative_angular_correction, drive.angular_axes),
    );
    let angular_delta = subtract_rows(next_angular, drive.accumulated_angular_impulse);
    drive.accumulated_angular_impulse = next_angular;
    let world_angular_impulse = combine_rows(drive.angular_axes, angular_delta);
    apply_angular_impulse(reactions, drive.frame_a_body, world_angular_impulse, 1.0);
    apply_angular_impulse(reactions, drive.frame_b_body, world_angular_impulse, -1.0);
}

#[derive(Clone, Copy)]
struct WorldFrame {
    orientation: RetailQuaternion,
    arm: Vector3,
    position: Vector3,
}

fn world_frame(body: RetailDriveBodyState, frame: RetailDriveFrame) -> WorldFrame {
    let arm = rotate(body.orientation, frame.translation);
    WorldFrame {
        orientation: multiply_quaternions(body.orientation, frame.orientation),
        arm,
        position: add(body.center_of_mass, arm),
    }
}

#[derive(Clone, Copy)]
struct DriveCoefficients {
    softness: f32,
    target_impulse: [f32; 3],
    maximum_impulse: [f32; 3],
}

fn build_coefficients(
    params: RetailDriveParams,
    position_error: [f32; 3],
    velocity_error: [f32; 3],
    acceleration_error: [f32; 3],
    inverse_effective_mass: [f32; 3],
    time_step: f32,
) -> DriveCoefficients {
    let dt_squared = time_step * time_step;
    let predicted_rate_displacement: [f32; 3] = core::array::from_fn(|index| {
        time_step * velocity_error[index] + dt_squared * acceleration_error[index]
    });

    let (softness, target_displacement) = match params.drive_type {
        RetailDriveType::NoDrive => (
            1.0,
            core::array::from_fn(|index| {
                position_error[index] + predicted_rate_displacement[index]
            }),
        ),
        RetailDriveType::SoftDrive => {
            let denominator =
                1.0 + time_step * params.damping + dt_squared * params.spring_or_max_velocity;
            (
                (1.0 + time_step * params.damping) / denominator,
                core::array::from_fn(|index| {
                    (dt_squared * params.spring_or_max_velocity * position_error[index]
                        + predicted_rate_displacement[index])
                        / denominator
                }),
            )
        }
        RetailDriveType::HardDrive => {
            let unclamped = core::array::from_fn(|index| {
                position_error[index] + predicted_rate_displacement[index]
            });
            let maximum_displacement = time_step * params.spring_or_max_velocity;
            let clamped = clamp_row_length(unclamped, maximum_displacement);
            let damping_denominator = 1.0 + time_step * params.damping;
            (
                1.0,
                clamped.map(|component| component / damping_denominator),
            )
        }
    };

    let strength = match params.drive_type {
        RetailDriveType::NoDrive => 0.0,
        RetailDriveType::SoftDrive | RetailDriveType::HardDrive => dt_squared * params.max_strength,
    };

    DriveCoefficients {
        softness,
        target_impulse: core::array::from_fn(|index| {
            target_displacement[index] * inverse_effective_mass[index]
        }),
        maximum_impulse: core::array::from_fn(|index| strength * inverse_effective_mass[index]),
    }
}

fn solve_row_vector(
    old: [f32; 3],
    target: [f32; 3],
    maximum: [f32; 3],
    softness: f32,
    inverse_effective_mass: [f32; 3],
    relative_correction: [f32; 3],
) -> [f32; 3] {
    core::array::from_fn(|index| {
        let candidate = target[index]
            + softness * (old[index] - inverse_effective_mass[index] * relative_correction[index]);
        candidate.clamp(-maximum[index], maximum[index])
    })
}

fn quaternion_component_rows(relative: RetailQuaternion) -> ([Vector3; 3], [f32; 3]) {
    let raw_axes = [
        Vector3::new(relative.w, relative.z, -relative.y),
        Vector3::new(-relative.z, relative.w, relative.x),
        Vector3::new(relative.y, -relative.x, relative.w),
    ];
    let lengths = raw_axes.map(length);
    let axes = core::array::from_fn(|index| scale(raw_axes[index], lengths[index].recip()));
    let error = [
        2.0 * relative.x / lengths[0],
        2.0 * relative.y / lengths[1],
        2.0 * relative.z / lengths[2],
    ];
    (axes, error)
}

fn linear_effective_mass(
    frame_a: RetailDriveBodyState,
    frame_b: RetailDriveBodyState,
    arm_a: Vector3,
    arm_b: Vector3,
    axis: Vector3,
) -> f32 {
    let mut denominator = 0.0;
    if is_active(frame_a) {
        let angular = cross(arm_a, axis);
        denominator += frame_a.inverse_mass
            + dot(
                angular,
                multiply_packed_world_inverse_inertia(frame_a.world_inverse_inertia, angular),
            );
    }
    if is_active(frame_b) {
        let angular = cross(arm_b, axis);
        denominator += frame_b.inverse_mass
            + dot(
                angular,
                multiply_packed_world_inverse_inertia(frame_b.world_inverse_inertia, angular),
            );
    }
    denominator
}

fn angular_effective_mass(
    frame_a: RetailDriveBodyState,
    frame_b: RetailDriveBodyState,
    axis: Vector3,
) -> f32 {
    let mut denominator = 0.0;
    if is_active(frame_a) {
        denominator += dot(
            axis,
            multiply_packed_world_inverse_inertia(frame_a.world_inverse_inertia, axis),
        );
    }
    if is_active(frame_b) {
        denominator += dot(
            axis,
            multiply_packed_world_inverse_inertia(frame_b.world_inverse_inertia, axis),
        );
    }
    denominator
}

fn apply_point_impulse(
    reactions: &mut [RetailReactionCorrections],
    body: RetailDriveBodyState,
    arm: Vector3,
    impulse: Vector3,
    sign: f32,
) {
    if !is_active(body) {
        return;
    }
    let reaction = &mut reactions[body.reaction_index];
    reaction.linear_displacement = add(
        reaction.linear_displacement,
        scale(impulse, sign * body.inverse_mass),
    );
    reaction.angular_displacement = add(
        reaction.angular_displacement,
        scale(
            multiply_packed_world_inverse_inertia(body.world_inverse_inertia, cross(arm, impulse)),
            sign,
        ),
    );
}

fn apply_angular_impulse(
    reactions: &mut [RetailReactionCorrections],
    body: RetailDriveBodyState,
    impulse: Vector3,
    sign: f32,
) {
    if !is_active(body) {
        return;
    }
    let reaction = &mut reactions[body.reaction_index];
    reaction.angular_displacement = add(
        reaction.angular_displacement,
        scale(
            multiply_packed_world_inverse_inertia(body.world_inverse_inertia, impulse),
            sign,
        ),
    );
}

fn point_correction(reaction: RetailReactionCorrections, arm: Vector3, active: bool) -> Vector3 {
    if active {
        add(
            reaction.linear_displacement,
            cross(reaction.angular_displacement, arm),
        )
    } else {
        Vector3::ZERO
    }
}

fn is_active(body: RetailDriveBodyState) -> bool {
    body.state & ACTIVE_BODY == ACTIVE_BODY
}

fn basis_columns(basis: crate::skateboard_body::Basis3) -> [Vector3; 3] {
    basis
        .columns
        .map(|column| Vector3::new(column[0], column[1], column[2]))
}

fn rotate(orientation: RetailQuaternion, vector: Vector3) -> Vector3 {
    combine_rows(
        basis_columns(basis_from_quaternion(orientation)),
        [vector.x, vector.y, vector.z],
    )
}

fn multiply_quaternions(a: RetailQuaternion, b: RetailQuaternion) -> RetailQuaternion {
    RetailQuaternion {
        x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    }
}

const fn conjugate(q: RetailQuaternion) -> RetailQuaternion {
    RetailQuaternion {
        x: -q.x,
        y: -q.y,
        z: -q.z,
        w: q.w,
    }
}

fn project(vector: Vector3, axes: [Vector3; 3]) -> [f32; 3] {
    axes.map(|axis| dot(vector, axis))
}

fn combine_rows(rows: [Vector3; 3], coefficients: [f32; 3]) -> Vector3 {
    add(
        add(
            scale(rows[0], coefficients[0]),
            scale(rows[1], coefficients[1]),
        ),
        scale(rows[2], coefficients[2]),
    )
}

fn subtract_rows(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    core::array::from_fn(|index| a[index] - b[index])
}

fn clamp_row_length(value: [f32; 3], maximum: f32) -> [f32; 3] {
    let magnitude = (value[0] * value[0] + value[1] * value[1] + value[2] * value[2]).sqrt();
    if magnitude > maximum {
        let factor = maximum / magnitude;
        value.map(|component| component * factor)
    } else {
        value
    }
}

fn point_rate(linear: Vector3, angular: Vector3, arm: Vector3) -> Vector3 {
    add(linear, cross(angular, arm))
}

fn length(value: Vector3) -> f32 {
    dot(value, value).sqrt()
}

const fn add(a: Vector3, b: Vector3) -> Vector3 {
    Vector3::new(a.x + b.x, a.y + b.y, a.z + b.z)
}

const fn sub(a: Vector3, b: Vector3) -> Vector3 {
    Vector3::new(a.x - b.x, a.y - b.y, a.z - b.z)
}

const fn scale(value: Vector3, factor: f32) -> Vector3 {
    Vector3::new(value.x * factor, value.y * factor, value.z * factor)
}

const fn dot(a: Vector3, b: Vector3) -> f32 {
    a.x * b.x + a.y * b.y + a.z * b.z
}

const fn cross(a: Vector3, b: Vector3) -> Vector3 {
    Vector3::new(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const DT: f32 = f32::from_bits(0x3C88_8889);

    fn active_body(reaction_index: usize) -> RetailDriveBodyState {
        RetailDriveBodyState {
            reaction_index,
            state: ACTIVE_BODY,
            orientation: RetailQuaternion::IDENTITY,
            center_of_mass: Vector3::ZERO,
            linear_velocity: Vector3::ZERO,
            angular_velocity: Vector3::ZERO,
            force_acceleration: Vector3::new(0.0, -9.8, 0.0),
            torque_acceleration: Vector3::ZERO,
            inverse_mass: 1.0,
            world_inverse_inertia: RetailPackedWorldInverseInertia {
                full: Vector3::new(1.0, 0.0, 0.0),
                split: Vector3::new(1.0, 1.0, 0.0),
            },
        }
    }

    fn no_drive() -> RetailDriveParams {
        RetailDriveParams {
            spring_or_max_velocity: 0.0,
            damping: 0.0,
            max_strength: 0.0,
            drive_type: RetailDriveType::NoDrive,
        }
    }

    fn soft_linear() -> RetailDriveParams {
        RetailDriveParams {
            spring_or_max_velocity: 3600.0,
            damping: 60.0,
            max_strength: 35999.996,
            drive_type: RetailDriveType::SoftDrive,
        }
    }

    fn frames_with_translation(translation: Vector3) -> RetailDriveFrames {
        RetailDriveFrames {
            body_a: RetailDriveFrame {
                orientation: RetailQuaternion::IDENTITY,
                translation: Vector3::ZERO,
            },
            body_b: RetailDriveFrame {
                orientation: RetailQuaternion::IDENTITY,
                translation,
            },
        }
    }

    fn assert_near(actual: f32, expected: f32) {
        assert!(
            (actual - expected).abs() <= 1.0e-6,
            "actual={actual:?} expected={expected:?}"
        );
    }

    fn assert_vector_near(actual: Vector3, expected: Vector3) {
        assert_near(actual.x, expected.x);
        assert_near(actual.y, expected.y);
        assert_near(actual.z, expected.z);
    }

    #[test]
    fn soft_linear_builder_matches_tu3_static_oracle() {
        let rows = build_drive_rows(
            active_body(0),
            active_body(1),
            frames_with_translation(Vector3::new(0.1, 0.2, 0.3)),
            RetailDriveDynamics {
                linear: soft_linear(),
                angular: no_drive(),
            },
            DT,
        );

        assert_near(rows.linear_softness, 0.666666687);
        for (actual, expected) in rows.linear_inverse_effective_mass.into_iter().zip([
            0.469483554,
            0.476190507,
            0.48780489,
        ]) {
            assert_near(actual, expected);
        }
        for (actual, expected) in
            rows.linear_target_impulse
                .into_iter()
                .zip([0.0156494547, 0.0317460373, 0.0487804972])
        {
            assert_near(actual, expected);
        }
        for (actual, expected) in rows
            .linear_maximum_impulse
            .into_iter()
            .zip([4.69483519, 4.76190472, 4.87804842])
        {
            assert_near(actual, expected);
        }
    }

    #[test]
    fn soft_linear_solver_matches_one_and_twenty_five_iteration_oracles() {
        let drive = build_drive_rows(
            active_body(0),
            active_body(1),
            frames_with_translation(Vector3::new(0.1, 0.2, 0.3)),
            RetailDriveDynamics {
                linear: soft_linear(),
                angular: no_drive(),
            },
            DT,
        );
        let mut one = [drive];
        let mut one_reactions = [RetailReactionCorrections::default(); 2];
        solve_drive_rows(&mut one, &mut one_reactions, 1);
        assert_eq!(
            one[0].accumulated_linear_impulse,
            [0.0156494547, 0.0317460373, 0.0487804972]
        );
        assert_vector_near(
            one_reactions[0].linear_displacement,
            Vector3::new(0.0156494547, 0.0317460373, 0.0487804972),
        );
        assert_vector_near(
            one_reactions[1].angular_displacement,
            Vector3::new(-0.000232287683, 0.000183213037, -0.0000447127968),
        );

        let mut converged = [drive];
        let mut converged_reactions = [RetailReactionCorrections::default(); 2];
        solve_drive_rows(&mut converged, &mut converged_reactions, 25);
        for (actual, expected) in converged[0].accumulated_linear_impulse.into_iter().zip([
            0.0163202751,
            0.0327940285,
            0.0495796055,
        ]) {
            assert_near(actual, expected);
        }
        assert_vector_near(
            converged_reactions[1].angular_displacement,
            Vector3::new(-0.0000777119785, 0.0000618777194, -0.0000153478159),
        );
    }

    #[test]
    fn angular_component_rows_match_nonorthogonal_tu3_oracle() {
        let inverse_root_fourteen = 1.0 / 14.0f32.sqrt();
        let orientation = RetailQuaternion {
            x: 0.5 * inverse_root_fourteen,
            y: inverse_root_fourteen,
            z: 1.5 * inverse_root_fourteen,
            w: 0.8660254,
        };
        let rows = build_drive_rows(
            active_body(0),
            active_body(1),
            RetailDriveFrames {
                body_a: RetailDriveFrame {
                    orientation: RetailQuaternion::IDENTITY,
                    translation: Vector3::ZERO,
                },
                body_b: RetailDriveFrame {
                    orientation,
                    translation: Vector3::ZERO,
                },
            },
            RetailDriveDynamics {
                linear: no_drive(),
                angular: RetailDriveParams {
                    spring_or_max_velocity: 1000.0,
                    damping: 0.0,
                    max_strength: 100000.0,
                    drive_type: RetailDriveType::HardDrive,
                },
            },
            DT,
        );

        assert_vector_near(
            rows.angular_axes[0],
            Vector3::new(0.873862803, 0.404519886, -0.269679934),
        );
        assert_vector_near(
            rows.angular_axes[1],
            Vector3::new(-0.416025162, 0.898717046, 0.138675049),
        );
        assert_vector_near(
            rows.angular_axes[2],
            Vector3::new(0.291729957, -0.145864978, 0.945313096),
        );
        for (actual, expected) in
            rows.angular_target_impulse
                .into_iter()
                .zip([0.134839997, 0.277350068, 0.437595069])
        {
            assert_near(actual, expected);
        }
    }

    #[test]
    fn hard_angular_velocity_and_strength_clamps_match_tu3() {
        let quarter_turn_half_angle = RetailQuaternion {
            x: 0.0,
            y: 0.38268343,
            z: 0.0,
            w: 0.9238795,
        };
        let mut rows = [build_drive_rows(
            active_body(0),
            active_body(1),
            RetailDriveFrames {
                body_a: RetailDriveFrame {
                    orientation: RetailQuaternion::IDENTITY,
                    translation: Vector3::ZERO,
                },
                body_b: RetailDriveFrame {
                    orientation: quarter_turn_half_angle,
                    translation: Vector3::ZERO,
                },
            },
            RetailDriveDynamics {
                linear: no_drive(),
                angular: RetailDriveParams {
                    spring_or_max_velocity: 1.0,
                    damping: 0.0,
                    max_strength: 2.0,
                    drive_type: RetailDriveType::HardDrive,
                },
            },
            DT,
        )];
        assert_near(rows[0].angular_target_impulse[1], 0.00833333377);
        assert_near(rows[0].angular_maximum_impulse[1], 0.000277777814);

        let mut reactions = [RetailReactionCorrections::default(); 2];
        solve_drive_rows(&mut rows, &mut reactions, 1);
        assert_near(rows[0].accumulated_angular_impulse[1], 0.000277777814);
        assert_vector_near(
            reactions[0].angular_displacement,
            Vector3::new(0.0, 0.000277777814, 0.0),
        );
        assert_vector_near(
            reactions[1].angular_displacement,
            Vector3::new(0.0, -0.000277777814, 0.0),
        );
    }

    #[test]
    fn hard_damping_divides_the_post_velocity_clamp_correction() {
        let rows = build_drive_rows(
            active_body(0),
            active_body(1),
            frames_with_translation(Vector3::new(3.0, 4.0, 0.0)),
            RetailDriveDynamics {
                linear: RetailDriveParams {
                    spring_or_max_velocity: 1.0,
                    damping: 60.0,
                    max_strength: 100000.0,
                    drive_type: RetailDriveType::HardDrive,
                },
                angular: no_drive(),
            },
            DT,
        );

        assert_near(rows.linear_target_impulse[0], 0.000277777814);
        assert_near(rows.linear_target_impulse[1], 0.000606060668);
        assert_eq!(rows.linear_target_impulse[2].to_bits(), 0);
    }

    #[test]
    fn rate_and_acceleration_terms_use_retail_dt_and_dt_squared() {
        let mut frame_b = active_body(1);
        frame_b.linear_velocity = Vector3::new(1.0, 0.0, 0.0);
        frame_b.force_acceleration = Vector3::new(1.0, -9.8, 0.0);
        let rows = build_drive_rows(
            active_body(0),
            frame_b,
            frames_with_translation(Vector3::ZERO),
            RetailDriveDynamics {
                linear: RetailDriveParams {
                    spring_or_max_velocity: 100.0,
                    damping: 0.0,
                    max_strength: 100000.0,
                    drive_type: RetailDriveType::HardDrive,
                },
                angular: no_drive(),
            },
            DT,
        );

        assert_near(rows.linear_target_impulse[0], 0.5 * (DT + DT * DT));
    }
}
