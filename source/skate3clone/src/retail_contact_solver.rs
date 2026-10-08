//! Scalar port of Skate 3 TU3's RenderWare contact-Jacobian rows.
//!
//! The retail VMX implementation stores three contact rows in a packed
//! 256-byte workspace. This module preserves the same physical quantities in
//! named scalar fields so they can be verified without depending on Xenon
//! register lane order. It is not wired to Bevy gameplay yet.

#![allow(dead_code)]

use crate::skateboard_body::{
    Vector3,
    retail_contact::{RetailContact, RetailContactWorkspace},
    retail_rigid_body::{
        RetailPackedWorldInverseInertia, RetailReactionCorrections,
        multiply_packed_world_inverse_inertia,
    },
};

pub mod tu3 {
    pub const CONTACT_BATCH_BUILD: u32 = 0x82AE_10C8;
    pub const ITERATIVE_CONSTRAINT_SOLVER: u32 = 0x82AE_27D0;
}

/// `rw::physics::BodyState::ACTIVE_BODY`.
pub const ACTIVE_BODY: u32 = 4;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailContactJacobian {
    pub reaction_index_a: usize,
    pub reaction_index_b: usize,
    pub body_a_active: bool,
    pub body_b_active: bool,
    pub arm_a: Vector3,
    pub arm_b: Vector3,
    /// Retail contact-row order: normal, tangent zero, tangent one.
    pub axes: [Vector3; 3],
    pub angular_jacobian_a: [Vector3; 3],
    pub angular_jacobian_b: [Vector3; 3],
    pub angular_response_a: [Vector3; 3],
    pub angular_response_b: [Vector3; 3],
    pub inverse_mass_a: f32,
    pub inverse_mass_b: f32,
    pub inverse_effective_mass: [f32; 3],
    /// Velocity-producing target displacement for each row.
    pub target_displacement: [f32; 3],
    /// Position-only normal correction.
    pub penetration_displacement: f32,
    pub static_friction: f32,
    pub dynamic_friction: f32,
    /// Normal, tangent-zero, tangent-one, position-only normal impulse.
    pub accumulated_impulse: [f32; 4],
}

/// Scalar translation of the contact-row arithmetic performed by TU3
/// `ContactBatchBuild`.
///
/// The active-body gate is the exact `(state & 4) == 4` branch. The target
/// includes current relative point velocity, one frame of accumulated linear
/// and angular acceleration, restitution only for positive normal relative
/// velocity, and the position-only contact separation lane.
pub fn build_contact_jacobian(contact: RetailContact, time_step: f32) -> RetailContactJacobian {
    debug_assert!(time_step.is_finite() && time_step > 0.0);

    let body_a_active = is_active(contact.body_a_workspace);
    let body_b_active = is_active(contact.body_b_workspace);
    let arm_a = sub(
        contact.position_on_a,
        contact.body_a_workspace.center_of_mass,
    );
    let arm_b = sub(
        contact.position_on_b,
        contact.body_b_workspace.center_of_mass,
    );
    let axes = [contact.normal, contact.tangent_0, contact.tangent_1];
    let angular_jacobian_a = axes.map(|axis| cross(arm_a, axis));
    let angular_jacobian_b = axes.map(|axis| cross(arm_b, axis));
    let packed_a = packed_inverse_inertia(contact.body_a_workspace);
    let packed_b = packed_inverse_inertia(contact.body_b_workspace);
    let angular_response_a = angular_jacobian_a.map(|row| {
        if body_a_active {
            multiply_packed_world_inverse_inertia(packed_a, row)
        } else {
            Vector3::ZERO
        }
    });
    let angular_response_b = angular_jacobian_b.map(|row| {
        if body_b_active {
            multiply_packed_world_inverse_inertia(packed_b, row)
        } else {
            Vector3::ZERO
        }
    });
    let inverse_mass_a = if body_a_active {
        contact.body_a_workspace.inverse_mass
    } else {
        0.0
    };
    let inverse_mass_b = if body_b_active {
        contact.body_b_workspace.inverse_mass
    } else {
        0.0
    };
    let inverse_effective_mass = core::array::from_fn(|index| {
        let denominator = inverse_mass_a
            + inverse_mass_b
            + dot(angular_jacobian_a[index], angular_response_a[index])
            + dot(angular_jacobian_b[index], angular_response_b[index]);
        denominator.recip()
    });

    let point_acceleration_a = if body_a_active {
        add(
            contact.body_a_workspace.force_acceleration,
            cross(contact.body_a_workspace.torque_acceleration, arm_a),
        )
    } else {
        Vector3::ZERO
    };
    let point_acceleration_b = if body_b_active {
        add(
            contact.body_b_workspace.force_acceleration,
            cross(contact.body_b_workspace.torque_acceleration, arm_b),
        )
    } else {
        Vector3::ZERO
    };
    let relative_acceleration = sub(point_acceleration_b, point_acceleration_a);
    let dt_squared = time_step * time_step;
    let contact_separation = sub(contact.position_on_a, contact.position_on_b);
    let mut target_displacement = core::array::from_fn(|index| {
        -dot(contact_separation, axes[index])
            + time_step * dot(contact.relative_velocity, axes[index])
            + dt_squared * dot(relative_acceleration, axes[index])
    });
    let normal_velocity = dot(contact.relative_velocity, contact.normal);
    if normal_velocity > 0.0 {
        target_displacement[0] += time_step * normal_velocity * contact.restitution;
    }
    let penetration_displacement = -dot(contact_separation, contact.normal);

    RetailContactJacobian {
        reaction_index_a: contact.body_a_workspace.reaction_id as usize,
        reaction_index_b: contact.body_b_workspace.reaction_id as usize,
        body_a_active,
        body_b_active,
        arm_a,
        arm_b,
        axes,
        angular_jacobian_a,
        angular_jacobian_b,
        angular_response_a,
        angular_response_b,
        inverse_mass_a,
        inverse_mass_b,
        inverse_effective_mass,
        target_displacement,
        penetration_displacement,
        static_friction: contact.static_friction,
        dynamic_friction: contact.dynamic_friction,
        accumulated_impulse: [0.0; 4],
    }
}

/// Runs TU3's contact portion of the iterative constraint solver.
///
/// Each pass is sequential over contacts, matching the retail Gauss-Seidel
/// ownership of the reaction-frame stack. Friction is the observed per-axis
/// static/dynamic branch: retain a candidate inside
/// `static_friction * normal_impulse`; otherwise clamp that component to
/// `dynamic_friction * normal_impulse`.
pub fn solve_contact_jacobians(
    contacts: &mut [RetailContactJacobian],
    reactions: &mut [RetailReactionCorrections],
    maximum_iterations: u32,
) {
    for _ in 0..maximum_iterations {
        solve_contact_jacobian_iteration(contacts, reactions);
    }
}

/// Runs one sequential contact pass.
///
/// TU3's shared solver receives contact, joint, and drive arrays together.
/// Exposing exactly one pass lets the owning simulation preserve that
/// recovered per-iteration array order instead of converging one constraint
/// family before starting the next.
pub fn solve_contact_jacobian_iteration(
    contacts: &mut [RetailContactJacobian],
    reactions: &mut [RetailReactionCorrections],
) {
    for contact in contacts.iter_mut() {
        solve_contact(contact, reactions);
    }
}

fn solve_contact(contact: &mut RetailContactJacobian, reactions: &mut [RetailReactionCorrections]) {
    let reaction_a = reactions[contact.reaction_index_a];
    let reaction_b = reactions[contact.reaction_index_b];
    let velocity_relative_correction = sub(
        point_correction(
            reaction_b.linear_displacement,
            reaction_b.angular_displacement,
            contact.arm_b,
            contact.body_b_active,
        ),
        point_correction(
            reaction_a.linear_displacement,
            reaction_a.angular_displacement,
            contact.arm_a,
            contact.body_a_active,
        ),
    );
    let position_relative_correction = sub(
        point_correction(
            reaction_b.position_displacement,
            reaction_b.orientation_displacement,
            contact.arm_b,
            contact.body_b_active,
        ),
        point_correction(
            reaction_a.position_displacement,
            reaction_a.orientation_displacement,
            contact.arm_a,
            contact.body_a_active,
        ),
    );

    let old = contact.accumulated_impulse;
    let mut next = old;
    next[0] = (old[0]
        + contact.inverse_effective_mass[0]
            * (contact.target_displacement[0]
                + dot(
                    add(velocity_relative_correction, position_relative_correction),
                    contact.axes[0],
                )))
    .max(0.0);
    next[3] = (old[3]
        + contact.inverse_effective_mass[0]
            * (contact.penetration_displacement
                + dot(position_relative_correction, contact.axes[0])))
    .max(0.0);

    for tangent_index in 1..=2 {
        let candidate = old[tangent_index]
            + contact.inverse_effective_mass[tangent_index]
                * (contact.target_displacement[tangent_index]
                    + dot(
                        add(velocity_relative_correction, position_relative_correction),
                        contact.axes[tangent_index],
                    ));
        // TU3 reads the accumulated normal lane before writing this
        // iteration's candidate. Friction therefore uses the prior normal
        // impulse, which is observable in the first two retail iterations.
        let static_limit = contact.static_friction * old[0];
        next[tangent_index] = if candidate.abs() <= static_limit {
            candidate
        } else {
            candidate.clamp(
                -contact.dynamic_friction * old[0],
                contact.dynamic_friction * old[0],
            )
        };
    }

    let velocity_delta = [next[0] - old[0], next[1] - old[1], next[2] - old[2]];
    let position_delta = next[3] - old[3];
    contact.accumulated_impulse = next;

    if contact.body_a_active {
        apply_velocity_impulse(
            &mut reactions[contact.reaction_index_a],
            contact,
            velocity_delta,
            1.0,
        );
        apply_position_impulse(
            &mut reactions[contact.reaction_index_a],
            contact,
            position_delta,
            1.0,
        );
    }
    if contact.body_b_active {
        apply_velocity_impulse(
            &mut reactions[contact.reaction_index_b],
            contact,
            velocity_delta,
            -1.0,
        );
        apply_position_impulse(
            &mut reactions[contact.reaction_index_b],
            contact,
            position_delta,
            -1.0,
        );
    }
}

fn apply_velocity_impulse(
    reaction: &mut RetailReactionCorrections,
    contact: &RetailContactJacobian,
    delta: [f32; 3],
    sign: f32,
) {
    let (inverse_mass, angular_response) = if sign > 0.0 {
        (contact.inverse_mass_a, contact.angular_response_a)
    } else {
        (contact.inverse_mass_b, contact.angular_response_b)
    };
    let linear_impulse = combine_rows(contact.axes, delta);
    let angular_impulse = combine_rows(angular_response, delta);
    reaction.linear_displacement = add(
        reaction.linear_displacement,
        scale(linear_impulse, sign * inverse_mass),
    );
    reaction.angular_displacement =
        add(reaction.angular_displacement, scale(angular_impulse, sign));
}

fn apply_position_impulse(
    reaction: &mut RetailReactionCorrections,
    contact: &RetailContactJacobian,
    delta: f32,
    sign: f32,
) {
    let (inverse_mass, angular_response) = if sign > 0.0 {
        (contact.inverse_mass_a, contact.angular_response_a[0])
    } else {
        (contact.inverse_mass_b, contact.angular_response_b[0])
    };
    reaction.position_displacement = add(
        reaction.position_displacement,
        scale(contact.axes[0], sign * inverse_mass * delta),
    );
    reaction.orientation_displacement = add(
        reaction.orientation_displacement,
        scale(angular_response, sign * delta),
    );
}

fn point_correction(linear: Vector3, angular: Vector3, arm: Vector3, active: bool) -> Vector3 {
    if active {
        add(linear, cross(angular, arm))
    } else {
        Vector3::ZERO
    }
}

fn packed_inverse_inertia(workspace: RetailContactWorkspace) -> RetailPackedWorldInverseInertia {
    RetailPackedWorldInverseInertia {
        full: workspace.inverse_inertia_full,
        split: workspace.inverse_inertia_split,
    }
}

fn is_active(workspace: RetailContactWorkspace) -> bool {
    workspace.state & ACTIVE_BODY == ACTIVE_BODY
}

fn combine_rows(rows: [Vector3; 3], weights: [f32; 3]) -> Vector3 {
    add(
        add(scale(rows[0], weights[0]), scale(rows[1], weights[1])),
        scale(rows[2], weights[2]),
    )
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

fn dot(left: Vector3, right: Vector3) -> f32 {
    left.x * right.x + left.y * right.y + left.z * right.z
}

fn cross(left: Vector3, right: Vector3) -> Vector3 {
    Vector3::new(
        left.y * right.z - left.z * right.y,
        left.z * right.x - left.x * right.z,
        left.x * right.y - left.y * right.x,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::skateboard_body::retail_contact::{
        RetailContactBodyState, RetailContactInput, generate_contact,
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

    fn body(
        reaction_id: u32,
        state: u32,
        inverse_mass: f32,
        force_acceleration: Vector3,
    ) -> RetailContactBodyState {
        RetailContactBodyState {
            contact_body_id: reaction_id,
            center_of_mass: Vector3::ZERO,
            reaction_id,
            inverse_inertia_full: Vector3::ZERO,
            inverse_mass,
            inverse_inertia_split: Vector3::ZERO,
            state,
            force_acceleration,
            kinetic_energy: 0.0,
            torque_acceleration: Vector3::ZERO,
            cool_down: 0,
            linear_velocity: Vector3::ZERO,
            angular_velocity: Vector3::ZERO,
        }
    }

    fn baseline_contact(
        relative_velocity: Vector3,
        static_friction: f32,
        dynamic_friction: f32,
    ) -> RetailContact {
        let mut contact = generate_contact(
            RetailContactInput {
                position_on_a: Vector3::new(0.0, 0.031, 0.0),
                position_on_b: Vector3::ZERO,
                normal: Vector3::new(0.0, -1.0, 0.0),
                restitution: 0.0,
                static_friction,
                dynamic_friction,
                tag: 0x1234_5678,
            },
            body(0, ACTIVE_BODY, 1.0 / 0.415, Vector3::new(0.0, -9.8, 0.0)),
            body(1, 1, 0.0, Vector3::ZERO),
        );
        contact.relative_velocity = relative_velocity;
        contact
    }

    #[test]
    fn builder_matches_tu3_static_floor_oracle() {
        let jacobian = build_contact_jacobian(
            baseline_contact(Vector3::new(2.0, -3.0, 1.0), 0.8, 0.7),
            1.0 / 60.0,
        );
        for effective_mass in jacobian.inverse_effective_mass {
            assert_close(effective_mass, 0.415);
        }
        assert_close(jacobian.target_displacement[0], 0.07827778);
        assert_close(jacobian.target_displacement[1], 0.033333335);
        assert_close(jacobian.target_displacement[2], 0.016666668);
        assert_close(jacobian.penetration_displacement, 0.031);
        assert_eq!(jacobian.angular_response_a, [Vector3::ZERO; 3]);
        assert_eq!(jacobian.angular_response_b, [Vector3::ZERO; 3]);
    }

    #[test]
    fn one_contact_solve_matches_tu3_reaction_frame_oracle() {
        let mut contacts = [build_contact_jacobian(
            baseline_contact(Vector3::new(2.0, -3.0, 1.0), 0.8, 0.7),
            1.0 / 60.0,
        )];
        let mut reactions = [RetailReactionCorrections::default(); 2];
        solve_contact_jacobians(&mut contacts, &mut reactions, 25);

        assert_close(contacts[0].accumulated_impulse[0], 0.0196203);
        assert_close(contacts[0].accumulated_impulse[1], 0.0138333);
        assert_close(contacts[0].accumulated_impulse[2], 0.00691667);
        assert_close(contacts[0].accumulated_impulse[3], 0.012865);
        assert_vec_close(
            reactions[0].linear_displacement,
            Vector3::new(0.033333335, -0.04727779, 0.016666668),
        );
        assert_vec_close(
            reactions[0].position_displacement,
            Vector3::new(0.0, -0.031, 0.0),
        );
        assert_eq!(reactions[0].angular_displacement, Vector3::ZERO);
        assert_eq!(reactions[0].orientation_displacement, Vector3::ZERO);
        assert_eq!(reactions[1], RetailReactionCorrections::default());
    }

    #[test]
    fn dynamic_friction_branch_matches_tu3_component_clamps() {
        let mut contacts = [build_contact_jacobian(
            baseline_contact(Vector3::new(20.0, -3.0, 10.0), 0.8, 0.7),
            1.0 / 60.0,
        )];
        let mut reactions = [RetailReactionCorrections::default(); 2];
        solve_contact_jacobians(&mut contacts, &mut reactions, 25);

        assert_close(contacts[0].accumulated_impulse[0], 0.0196203);
        assert_close(contacts[0].accumulated_impulse[1], 0.0137342);
        assert_close(contacts[0].accumulated_impulse[2], 0.0137342);
        assert_close(
            contacts[0].accumulated_impulse[1],
            contacts[0].dynamic_friction * contacts[0].accumulated_impulse[0],
        );
        assert_close(
            contacts[0].accumulated_impulse[2],
            contacts[0].dynamic_friction * contacts[0].accumulated_impulse[0],
        );
    }

    #[test]
    fn two_active_body_signs_match_tu3_reaction_frames() {
        let mut contact = baseline_contact(Vector3::new(2.0, -3.0, 1.0), 0.8, 0.7);
        contact.body_b_workspace.state = ACTIVE_BODY;
        contact.body_b_workspace.inverse_mass = 1.0;
        let mut contacts = [build_contact_jacobian(contact, 1.0 / 60.0)];
        let mut reactions = [RetailReactionCorrections::default(); 2];
        solve_contact_jacobians(&mut contacts, &mut reactions, 25);

        assert_close(contacts[0].accumulated_impulse[0], 0.0138659);
        assert_close(contacts[0].accumulated_impulse[1], 0.00977621);
        assert_close(contacts[0].accumulated_impulse[2], 0.0048881);
        assert_close(contacts[0].accumulated_impulse[3], 0.00909187);
        assert_vec_close(
            reactions[0].linear_displacement,
            Vector3::new(0.02355713, -0.03341186, 0.01177856),
        );
        assert_vec_close(
            reactions[0].position_displacement,
            Vector3::new(0.0, -0.02190812, 0.0),
        );
        assert_vec_close(
            reactions[1].linear_displacement,
            Vector3::new(-0.00977621, 0.01386592, -0.0048881),
        );
        assert_vec_close(
            reactions[1].position_displacement,
            Vector3::new(0.0, 0.00909187, 0.0),
        );
    }

    #[test]
    fn rotated_contact_rows_match_tu3_nonzero_inertia_oracle() {
        let mut contact = baseline_contact(Vector3::new(2.0, -3.0, 1.0), 0.8, 0.7);
        contact.position_on_a = Vector3::new(1.0, 2.0, 3.0);
        contact.body_a_workspace.inverse_inertia_full = Vector3::new(2.0, 0.0, 0.0);
        contact.body_a_workspace.inverse_inertia_split = Vector3::new(5.0, 3.0, 0.0);
        let mut contacts = [build_contact_jacobian(contact, 1.0 / 60.0)];
        let mut reactions = [RetailReactionCorrections::default(); 2];
        solve_contact_jacobians(&mut contacts, &mut reactions, 25);

        assert_vec_close(
            contacts[0].angular_response_a[0],
            Vector3::new(6.0, 0.0, -5.0),
        );
        assert_vec_close(
            contacts[0].angular_response_a[1],
            Vector3::new(0.0, 9.0, -10.0),
        );
        assert_vec_close(
            contacts[0].angular_response_a[2],
            Vector3::new(4.0, -3.0, 0.0),
        );
        assert_close(contacts[0].accumulated_impulse[0], 0.00490218);
        assert_close(contacts[0].accumulated_impulse[1], -0.00329813);
        assert_close(contacts[0].accumulated_impulse[2], -0.00329813);
        assert_close(contacts[0].accumulated_impulse[3], 0.0787103);
        assert_vec_close(
            reactions[0].linear_displacement,
            Vector3::new(-0.00794731, -0.01181247, -0.00794731),
        );
        assert_vec_close(
            reactions[0].position_displacement,
            Vector3::new(0.0, -0.18966335, 0.0),
        );
        assert_vec_close(
            reactions[0].angular_displacement,
            Vector3::new(0.01622056, -0.01978875, 0.00847047),
        );
        assert_vec_close(
            reactions[0].orientation_displacement,
            Vector3::new(0.47226173, 0.0, -0.39355144),
        );
    }

    #[test]
    fn positive_normal_rate_is_the_only_restitution_branch() {
        let mut positive = baseline_contact(Vector3::new(0.0, -3.0, 0.0), 0.8, 0.7);
        positive.restitution = 0.5;
        let positive = build_contact_jacobian(positive, 1.0 / 60.0);
        assert_close(positive.target_displacement[0], 0.10327778);

        let mut negative = baseline_contact(Vector3::new(0.0, 3.0, 0.0), 0.8, 0.7);
        negative.restitution = 0.5;
        let negative = build_contact_jacobian(negative, 1.0 / 60.0);
        assert_close(negative.target_displacement[0], -0.021722224);
    }
}
