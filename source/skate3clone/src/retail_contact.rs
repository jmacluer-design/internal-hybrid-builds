//! Skate 3 TU3's RenderWare contact-record construction.
//!
//! This is the scalar form of the VMX128 block in TU3's two recovered
//! add-contact paths. It builds the 256-byte logical `rw::physics::Contact`
//! payload consumed in place by `ContactBatchBuild`; it does not solve the
//! contact or move a body.

#![allow(dead_code)]

use crate::skateboard_body::Vector3;

pub mod tu3 {
    /// Game-side physical-material combine helper used before both recovered
    /// collision-to-contact record writers.
    pub const COMBINE_PHYSICAL_MATERIALS: u32 = 0x8276_3078;
    /// First recovered collision-to-contact record block, end exclusive.
    pub const GENERATE_CONTACT_A: u32 = 0x8277_A828;
    pub const GENERATE_CONTACT_A_END: u32 = 0x8277_AA88;
    /// Second field-for-field collision-to-contact record block, end exclusive.
    pub const GENERATE_CONTACT_B: u32 = 0x8277_BFAC;
    pub const GENERATE_CONTACT_B_END: u32 = 0x8277_C21C;
    /// In-place contact Jacobian builder.
    pub const CONTACT_BATCH_BUILD: u32 = 0x82AE_10C8;
}

/// Exact TU3 constant used to reject a degenerate velocity-derived tangent.
///
/// The Xbox data table at `0x830382B0` contains `0x00800000` in every lane.
/// This is the smallest positive normal binary32 value, not a tuned gameplay
/// threshold.
pub const CONTACT_TANGENT_MINIMUM_SQUARED: f32 = f32::from_bits(0x0080_0000);
pub const CONTACT_FALLBACK_HALF: f32 = f32::from_bits(0x3F00_0000);

/// The five 16-byte body vectors copied into a contact's solver workspace.
///
/// Original member names and offsets are independently present in preserved
/// Skate-era EA SDK DWARF and are confirmed by TU3's loads:
///
/// - `mCom/mId` at body `+0x10`;
/// - `mIfull/mInvm` at `+0x70`;
/// - `mIsplt/mState` at `+0x80`;
/// - `mForce/mKine` at `+0x90`;
/// - `mTorque/mCool` at `+0xa0`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailContactBodyState {
    /// ID written to the contact header from the collision queue's body-ref
    /// entry. It is kept separate from `reaction_id` because TU3 loads them
    /// from different records.
    pub contact_body_id: u32,
    pub center_of_mass: Vector3,
    pub reaction_id: u32,
    /// Retail packed world inverse-inertia vector
    /// `mIfull = (Ixx, Ixy, Ixz)`.
    pub inverse_inertia_full: Vector3,
    pub inverse_mass: f32,
    /// Retail packed world inverse-inertia vector
    /// `mIsplt = (Izz, Iyy, Iyz)`.
    pub inverse_inertia_split: Vector3,
    pub state: u32,
    pub force_acceleration: Vector3,
    pub kinetic_energy: f32,
    pub torque_acceleration: Vector3,
    pub cool_down: u32,
    pub linear_velocity: Vector3,
    pub angular_velocity: Vector3,
}

/// Collision result and already-combined material values consumed by TU3's
/// contact generator.
///
/// The material-combine routine that produces the three scalars is outside the
/// recovered block and remains deliberately explicit at this boundary.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailContactInput {
    pub position_on_a: Vector3,
    pub position_on_b: Vector3,
    /// Separating normal in the collision pair's A-to-B convention.
    pub normal: Vector3,
    pub restitution: f32,
    pub static_friction: f32,
    pub dynamic_friction: f32,
    pub tag: u32,
}

/// Three scalar fields in the game-side physical material record consumed by
/// TU3 `0x82763078`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailContactMaterial {
    pub static_friction: f32,
    pub dynamic_friction: f32,
    pub restitution: f32,
}

/// Exact game-side material combine used immediately before the recovered
/// contact writers.
///
/// TU3 performs three independent ordered comparisons:
///
/// - static friction is the greater operand;
/// - dynamic friction is the lesser operand;
/// - restitution is the lesser operand.
///
/// The comparisons are kept explicit instead of using `f32::max`/`min`
/// because the retail branch behavior for unordered inputs is operand-order
/// sensitive. Physical materials are expected to contain finite values.
pub fn combine_contact_materials(
    material_a: RetailContactMaterial,
    material_b: RetailContactMaterial,
) -> RetailContactMaterial {
    let static_friction = if material_a.static_friction > material_b.static_friction {
        material_a.static_friction
    } else {
        material_b.static_friction
    };
    let dynamic_friction = if material_a.dynamic_friction > material_b.dynamic_friction {
        material_b.dynamic_friction
    } else {
        material_a.dynamic_friction
    };
    let restitution = if material_a.restitution < material_b.restitution {
        material_a.restitution
    } else {
        material_b.restitution
    };
    RetailContactMaterial {
        static_friction,
        dynamic_friction,
        restitution,
    }
}

/// Scalar representation of the complete logical 256-byte retail contact.
///
/// `body_a_workspace` and `body_b_workspace` correspond to the ten alternating
/// 16-byte vectors at offsets `0x60..0xff`. Keeping those copied values in the
/// record is important: `ContactBatchBuild` reads them from the contact and
/// does not dereference the live bodies.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailContact {
    pub position_on_a: Vector3,
    pub body_a_id: u32,
    pub position_on_b: Vector3,
    pub body_b_id: u32,
    pub normal: Vector3,
    pub restitution: f32,
    pub tangent_0: Vector3,
    pub static_friction: f32,
    pub tangent_1: Vector3,
    pub dynamic_friction: f32,
    /// Velocity at B's contact point minus velocity at A's contact point.
    pub relative_velocity: Vector3,
    pub tag: u32,
    pub body_a_workspace: RetailContactWorkspace,
    pub body_b_workspace: RetailContactWorkspace,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailContactWorkspace {
    pub center_of_mass: Vector3,
    pub reaction_id: u32,
    pub inverse_inertia_full: Vector3,
    pub inverse_mass: f32,
    pub inverse_inertia_split: Vector3,
    pub state: u32,
    pub force_acceleration: Vector3,
    pub kinetic_energy: f32,
    pub torque_acceleration: Vector3,
    pub cool_down: u32,
}

impl From<RetailContactBodyState> for RetailContactWorkspace {
    fn from(body: RetailContactBodyState) -> Self {
        Self {
            center_of_mass: body.center_of_mass,
            reaction_id: body.reaction_id,
            inverse_inertia_full: body.inverse_inertia_full,
            inverse_mass: body.inverse_mass,
            inverse_inertia_split: body.inverse_inertia_split,
            state: body.state,
            force_acceleration: body.force_acceleration,
            kinetic_energy: body.kinetic_energy,
            torque_acceleration: body.torque_acceleration,
            cool_down: body.cool_down,
        }
    }
}

/// Port of TU3 `0x8277A828..0x8277AA88` and its duplicate
/// `0x8277BFAC..0x8277C21C`.
///
/// VMX128 operation order is retained at the scalar-expression level:
///
/// 1. compute each contact arm from the copied body center of mass;
/// 2. compute point rates as `linear + angular cross arm`;
/// 3. derive tangent 0 from `relative_velocity cross normal`;
/// 4. if that axis is subnormal, use the exact X/Z projection fallback;
/// 5. derive tangent 1 as `normal cross tangent_0`;
/// 6. copy the ten body-state vectors used by `ContactBatchBuild`.
///
/// The retail input normal is already unit length. This routine intentionally
/// does not renormalize it or repair malformed collision input.
pub fn generate_contact(
    input: RetailContactInput,
    body_a: RetailContactBodyState,
    body_b: RetailContactBodyState,
) -> RetailContact {
    let arm_a = sub(input.position_on_a, body_a.center_of_mass);
    let arm_b = sub(input.position_on_b, body_b.center_of_mass);
    let point_velocity_a = add(
        body_a.linear_velocity,
        cross(body_a.angular_velocity, arm_a),
    );
    let point_velocity_b = add(
        body_b.linear_velocity,
        cross(body_b.angular_velocity, arm_b),
    );
    let relative_velocity = sub(point_velocity_b, point_velocity_a);

    let velocity_tangent = cross(relative_velocity, input.normal);
    let velocity_tangent_squared = length_squared(velocity_tangent);
    let (unnormalized_tangent, tangent_squared) =
        if velocity_tangent_squared >= CONTACT_TANGENT_MINIMUM_SQUARED {
            (velocity_tangent, velocity_tangent_squared)
        } else {
            fallback_tangent(input.normal)
        };

    // TU3 issues one reciprocal-square-root estimate and applies it to both
    // axes. `tangent_1` therefore assumes the collision normal is unit length.
    let inverse_length = tangent_squared.sqrt().recip();
    let tangent_0 = scale(unnormalized_tangent, inverse_length);
    let tangent_1 = scale(cross(input.normal, unnormalized_tangent), inverse_length);

    RetailContact {
        position_on_a: input.position_on_a,
        body_a_id: body_a.contact_body_id,
        position_on_b: input.position_on_b,
        body_b_id: body_b.contact_body_id,
        normal: input.normal,
        restitution: input.restitution,
        tangent_0,
        static_friction: input.static_friction,
        tangent_1,
        dynamic_friction: input.dynamic_friction,
        relative_velocity,
        tag: input.tag,
        body_a_workspace: body_a.into(),
        body_b_workspace: body_b.into(),
    }
}

/// Exact normal-only fallback selected by the TU3 VMX block.
fn fallback_tangent(normal: Vector3) -> (Vector3, f32) {
    let candidate_x = sub(Vector3::new(1.0, 0.0, 0.0), scale(normal, normal.x));
    let candidate_z = sub(Vector3::new(0.0, 0.0, 1.0), scale(normal, normal.z));
    if CONTACT_FALLBACK_HALF - normal.x * normal.x >= -0.0 {
        (candidate_x, candidate_x.x)
    } else {
        (scale(candidate_z, -1.0), candidate_z.z)
    }
}

fn add(left: Vector3, right: Vector3) -> Vector3 {
    Vector3::new(left.x + right.x, left.y + right.y, left.z + right.z)
}

fn sub(left: Vector3, right: Vector3) -> Vector3 {
    Vector3::new(left.x - right.x, left.y - right.y, left.z - right.z)
}

fn scale(vector: Vector3, scalar: f32) -> Vector3 {
    Vector3::new(vector.x * scalar, vector.y * scalar, vector.z * scalar)
}

fn cross(left: Vector3, right: Vector3) -> Vector3 {
    Vector3::new(
        left.y * right.z - left.z * right.y,
        left.z * right.x - left.x * right.z,
        left.x * right.y - left.y * right.x,
    )
}

fn dot(left: Vector3, right: Vector3) -> f32 {
    left.x * right.x + left.y * right.y + left.z * right.z
}

fn length_squared(vector: Vector3) -> f32 {
    dot(vector, vector)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body(contact_body_id: u32, center_of_mass: Vector3) -> RetailContactBodyState {
        RetailContactBodyState {
            contact_body_id,
            center_of_mass,
            reaction_id: contact_body_id + 10,
            inverse_inertia_full: Vector3::new(1.0, 2.0, 3.0),
            inverse_mass: 0.25,
            inverse_inertia_split: Vector3::new(4.0, 5.0, 6.0),
            state: 7,
            force_acceleration: Vector3::new(8.0, 9.0, 10.0),
            kinetic_energy: 11.0,
            torque_acceleration: Vector3::new(12.0, 13.0, 14.0),
            cool_down: 15,
            linear_velocity: Vector3::ZERO,
            angular_velocity: Vector3::ZERO,
        }
    }

    fn input(normal: Vector3) -> RetailContactInput {
        RetailContactInput {
            position_on_a: Vector3::new(2.0, 3.0, 4.0),
            position_on_b: Vector3::new(2.0, 3.0, 4.0),
            normal,
            restitution: 0.1,
            static_friction: 0.8,
            dynamic_friction: 0.7,
            tag: 0x1234_5678,
        }
    }

    #[test]
    fn material_combine_matches_tu3_branch_directions() {
        let combined = combine_contact_materials(
            RetailContactMaterial {
                static_friction: f32::from_bits(0x3F4C_CCCD),
                dynamic_friction: f32::from_bits(0x3F33_3333),
                restitution: f32::from_bits(0x3E4C_CCCD),
            },
            RetailContactMaterial {
                static_friction: f32::from_bits(0x3F00_0000),
                dynamic_friction: f32::from_bits(0x3F66_6666),
                restitution: f32::from_bits(0x3DCC_CCCD),
            },
        );

        assert_eq!(combined.static_friction.to_bits(), 0x3F4C_CCCD);
        assert_eq!(combined.dynamic_friction.to_bits(), 0x3F33_3333);
        assert_eq!(combined.restitution.to_bits(), 0x3DCC_CCCD);
    }

    #[test]
    fn material_combine_is_commutative_for_finite_values() {
        let a = RetailContactMaterial {
            static_friction: 0.8,
            dynamic_friction: 0.7,
            restitution: 0.0,
        };
        let b = RetailContactMaterial {
            static_friction: 0.5,
            dynamic_friction: 0.9,
            restitution: 0.2,
        };

        assert_eq!(
            combine_contact_materials(a, b),
            combine_contact_materials(b, a)
        );
    }

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

    #[test]
    fn velocity_axis_matches_the_tu3_cross_product_order() {
        let mut body_b = body(2, Vector3::ZERO);
        body_b.linear_velocity = Vector3::new(3.0, 0.0, 0.0);
        let contact = generate_contact(
            input(Vector3::new(0.0, -1.0, 0.0)),
            body(1, Vector3::ZERO),
            body_b,
        );

        assert_vec_close(contact.relative_velocity, Vector3::new(3.0, 0.0, 0.0));
        assert_vec_close(contact.tangent_0, Vector3::new(0.0, 0.0, -1.0));
        assert_vec_close(contact.tangent_1, Vector3::new(1.0, 0.0, 0.0));
    }

    #[test]
    fn angular_contact_rates_use_omega_cross_arm() {
        let mut body_a = body(1, Vector3::new(1.0, 3.0, 4.0));
        body_a.angular_velocity = Vector3::new(0.0, 0.0, 2.0);
        let contact = generate_contact(
            input(Vector3::new(0.0, -1.0, 0.0)),
            body_a,
            body(2, Vector3::new(2.0, 3.0, 4.0)),
        );

        assert_vec_close(contact.relative_velocity, Vector3::new(0.0, -2.0, 0.0));
    }

    #[test]
    fn zero_relative_rate_uses_the_exact_x_projection_fallback() {
        let contact = generate_contact(
            input(Vector3::new(0.0, -1.0, 0.0)),
            body(1, Vector3::ZERO),
            body(2, Vector3::ZERO),
        );

        assert_vec_close(contact.tangent_0, Vector3::new(1.0, 0.0, 0.0));
        assert_vec_close(contact.tangent_1, Vector3::new(0.0, 0.0, 1.0));
    }

    #[test]
    fn steep_x_normal_uses_negated_z_projection_fallback() {
        let normal = Vector3::new(0.8, 0.6, 0.0);
        let contact = generate_contact(
            input(normal),
            body(1, Vector3::ZERO),
            body(2, Vector3::ZERO),
        );

        assert_vec_close(contact.tangent_0, Vector3::new(0.0, 0.0, -1.0));
        assert_vec_close(contact.tangent_1, Vector3::new(-0.6, 0.8, 0.0));
    }

    #[test]
    fn contact_frame_is_orthonormal_for_unit_input_normal() {
        let normal = Vector3::new(0.36, 0.48, 0.8);
        let mut body_b = body(2, Vector3::ZERO);
        body_b.linear_velocity = Vector3::new(2.0, -1.0, 0.5);
        let contact = generate_contact(input(normal), body(1, Vector3::ZERO), body_b);

        assert_close(dot(contact.normal, contact.tangent_0), 0.0);
        assert_close(dot(contact.normal, contact.tangent_1), 0.0);
        assert_close(dot(contact.tangent_0, contact.tangent_1), 0.0);
        assert_close(length_squared(contact.tangent_0), 1.0);
        assert_close(length_squared(contact.tangent_1), 1.0);
        assert_vec_close(cross(contact.normal, contact.tangent_0), contact.tangent_1);
    }

    #[test]
    fn contact_copies_header_ids_materials_tag_and_body_workspaces() {
        let body_a = body(41, Vector3::new(1.0, 2.0, 3.0));
        let body_b = body(52, Vector3::new(4.0, 5.0, 6.0));
        let collision = input(Vector3::new(0.0, 1.0, 0.0));
        let contact = generate_contact(collision, body_a, body_b);

        assert_eq!(contact.body_a_id, 41);
        assert_eq!(contact.body_b_id, 52);
        assert_eq!(contact.restitution, collision.restitution);
        assert_eq!(contact.static_friction, collision.static_friction);
        assert_eq!(contact.dynamic_friction, collision.dynamic_friction);
        assert_eq!(contact.tag, collision.tag);
        assert_eq!(contact.body_a_workspace, body_a.into());
        assert_eq!(contact.body_b_workspace, body_b.into());
        assert_eq!(contact.body_a_workspace.reaction_id, 51);
        assert_eq!(contact.body_b_workspace.reaction_id, 62);
    }

    #[test]
    fn recovered_tangent_constants_keep_their_exact_binary32_bits() {
        assert_eq!(CONTACT_TANGENT_MINIMUM_SQUARED.to_bits(), 0x0080_0000);
        assert_eq!(CONTACT_FALLBACK_HALF.to_bits(), 0x3F00_0000);
    }
}
