//! Playable transition traversal for decoded level collision.
//!
//! Evidence-backed boundaries:
//! - authored riding triangles are the only support geometry;
//! - gravity is the retail world value `(0, -9.8, 0)`;
//! - grounded velocity is transported between adjacent contact normals rather
//!   than replaced by an analytic quarter-pipe tangent;
//! - lip takeoff is immediate face-contact loss;
//! - air velocity is ballistic and is never steered toward a target;
//! - restitution is zero and filtered ground reacquisition takes four frames.
//!
//! Provisional boundaries, explicitly authorized for this playable pass:
//! - a point carrier stands in for the unresolved seven-body startup state;
//! - a normal-directed face probe stands in for unresolved wheel edge/vertex
//!   contacts;
//! - the recovered Pumping force path is driven by a curvature/input proxy;
//! - ordinary-air visual orientation uses the recovered `NaturalAirTime`
//!   value as a smoothing time while its exact consumer remains unresolved.

use bevy::prelude::*;

use crate::contact_friction::{
    BoardContactState, ContactFrictionInput, ContactFrictionOutput, integrate_contact_friction,
};
#[cfg(test)]
use crate::ground_provider::SurfaceId;
use crate::ground_provider::{GroundProbe, GroundProvider, GroundVec3, SurfaceContact};
#[cfg(test)]
use crate::skateboard_body::transition_test_terrain::TransitionTestTerrain;
use crate::skateboard_body::{
    RETAIL_PHYSICS_DEFAULTS, retail_ground_filter::established_air_accepts_ground,
    retail_pumping::RETAIL_PHYSICS_MODE,
};

pub const RETAIL_WORLD_GRAVITY: Vec3 = Vec3::new(
    RETAIL_PHYSICS_DEFAULTS.world_gravity.x,
    RETAIL_PHYSICS_DEFAULTS.world_gravity.y,
    RETAIL_PHYSICS_DEFAULTS.world_gravity.z,
);
pub const RETAIL_GROUND_NORMAL_MINIMUM_Y: f32 = f32::from_bits(0x3E31_D0D9);
pub const RETAIL_NATURAL_AIR_TIME_SECONDS: f32 = 0.2;

// Provisional point-carrier/contact bridge. The distance starts with retail's
// 0.1 m simulation padding and adds a small carrier allowance. It is applied
// only along the previous support normal and cannot extend a triangle edge.
const PROVISIONAL_SUPPORT_DISTANCE: f32 = RETAIL_PHYSICS_DEFAULTS.simulation_padding + 0.04;
const PROVISIONAL_SUPPORT_PROBE_OFFSET: f32 = 0.24;
const PROVISIONAL_NORMAL_CONTINUITY_DOT: f32 = 0.5;
const PROVISIONAL_GROUND_ALIGNMENT_SECONDS: f32 = 0.10;
const PROVISIONAL_AIR_LANDING_LOOKAHEAD_METRES: f32 = 4.0;
const PROVISIONAL_SWEEP_START_EPSILON: f32 = 1.0e-4;
const PROVISIONAL_MIN_IMPACT_SPEED: f32 = 0.05;

// The recovered mode factor is 18. The missing COM/animation bridge is
// represented by this dimensionless scale and kept here as the one explicit
// pump tuning assumption.
const PROVISIONAL_PUMP_COM_BRIDGE_SCALE: f32 = 1.0 / 24.0;
const PROVISIONAL_MAX_CURVATURE_RATE: f32 = 4.0;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum TransitionPhase {
    #[default]
    Disabled,
    Grounded,
    Airborne,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TransitionStepInput {
    pub dt: f32,
    pub activation_yaw: f32,
    pub heading_delta: f32,
    pub pump_intent: f32,
    pub powersliding: bool,
    pub braking: bool,
    pub maximum_speed: f32,
    pub pop_launch_speed: Option<f32>,
}

impl TransitionStepInput {
    #[cfg(test)]
    pub fn coast(dt: f32, maximum_speed: f32) -> Self {
        Self {
            dt,
            activation_yaw: 0.0,
            heading_delta: 0.0,
            pump_intent: 0.0,
            powersliding: false,
            braking: false,
            maximum_speed,
            pop_launch_speed: None,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct TransitionStepOutput {
    pub left_ground_this_step: bool,
    pub landed_this_step: bool,
    pub filtered_grounded: bool,
    pub surface_id: Option<u32>,
    pub friction: ContactFrictionOutput,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TransitionRuntime {
    pub phase: TransitionPhase,
    pub support_up: Vec3,
    pub support_forward: Vec3,
    pub visual_up: Vec3,
    pub visual_forward: Vec3,
    pub air_time_seconds: f32,
    pub contact_evidence_frames: u32,
    pub curvature_rate_radians_per_second: f32,
    pub last_pump_acceleration: f32,
    pub last_surface_id: Option<u32>,
}

impl Default for TransitionRuntime {
    fn default() -> Self {
        Self {
            phase: TransitionPhase::Disabled,
            support_up: Vec3::Y,
            support_forward: Vec3::Z,
            visual_up: Vec3::Y,
            visual_forward: Vec3::Z,
            air_time_seconds: 0.0,
            contact_evidence_frames: 0,
            curvature_rate_radians_per_second: 0.0,
            last_pump_acceleration: 0.0,
            last_surface_id: None,
        }
    }
}

impl TransitionRuntime {
    pub fn is_enabled(&self) -> bool {
        self.phase != TransitionPhase::Disabled
    }

    pub fn is_physically_grounded(&self) -> bool {
        self.phase == TransitionPhase::Grounded
    }

    pub fn filtered_grounded(&self) -> bool {
        self.phase == TransitionPhase::Grounded
            && established_air_accepts_ground(self.contact_evidence_frames, true)
    }

    pub fn speed(&self, velocity: Vec3) -> f32 {
        if self.is_enabled() {
            velocity.length()
        } else {
            Vec2::new(velocity.x, velocity.z).length()
        }
    }

    pub fn longitudinal_speed(&self, velocity: Vec3) -> f32 {
        velocity.dot(self.support_forward)
    }

    pub fn visual_rotation(&self) -> Quat {
        frame_rotation(self.visual_up, self.visual_forward)
    }

    pub fn activate(&mut self, provider: &GroundProvider, position: &mut Vec3, yaw: f32) -> bool {
        let Some(contact) = query_down(provider, *position + Vec3::Y, 2.0) else {
            return false;
        };
        let up = contact_normal(contact);
        let forward = projected_heading(yaw, up, Vec3::Z);
        *position = contact_point(contact);
        self.phase = TransitionPhase::Grounded;
        self.support_up = up;
        self.support_forward = forward;
        self.visual_up = up;
        self.visual_forward = forward;
        self.air_time_seconds = 0.0;
        // Spawn is already an established grounded state.
        self.contact_evidence_frames = 4;
        self.curvature_rate_radians_per_second = 0.0;
        self.last_pump_acceleration = 0.0;
        self.last_surface_id = Some(contact.surface_id.0);
        true
    }

    pub fn step(
        &mut self,
        provider: &GroundProvider,
        position: &mut Vec3,
        velocity: &mut Vec3,
        input: TransitionStepInput,
    ) -> TransitionStepOutput {
        debug_assert!(input.dt.is_finite() && input.dt > 0.0);
        if self.phase == TransitionPhase::Disabled
            && !self.activate(provider, position, input.activation_yaw)
        {
            return TransitionStepOutput::default();
        }

        self.apply_heading_delta(input.heading_delta);
        self.last_pump_acceleration = 0.0;

        if let Some(launch_speed) = input.pop_launch_speed {
            if self.phase == TransitionPhase::Grounded {
                *velocity += self.support_up * launch_speed.max(0.0);
                self.phase = TransitionPhase::Airborne;
                self.air_time_seconds = 0.0;
                self.contact_evidence_frames = 0;
                self.last_surface_id = None;
                let mut output = self.step_airborne(provider, position, velocity, input);
                output.left_ground_this_step = true;
                return output;
            }
        }

        match self.phase {
            TransitionPhase::Disabled => TransitionStepOutput::default(),
            TransitionPhase::Grounded => self.step_grounded(provider, position, velocity, input),
            TransitionPhase::Airborne => self.step_airborne(provider, position, velocity, input),
        }
    }

    fn step_grounded(
        &mut self,
        provider: &GroundProvider,
        position: &mut Vec3,
        velocity: &mut Vec3,
        input: TransitionStepInput,
    ) -> TransitionStepOutput {
        let prior_velocity = *velocity;
        let gravity_tangent =
            RETAIL_WORLD_GRAVITY - self.support_up * RETAIL_WORLD_GRAVITY.dot(self.support_up);
        *velocity += gravity_tangent * input.dt;

        let pump_direction = velocity
            .normalize_or(self.support_forward)
            .reject_from(self.support_up)
            .normalize_or(self.support_forward);
        let pump_acceleration = input.pump_intent.clamp(0.0, 1.0)
            * self
                .curvature_rate_radians_per_second
                .clamp(0.0, PROVISIONAL_MAX_CURVATURE_RATE)
            * RETAIL_PHYSICS_MODE.factor
            * PROVISIONAL_PUMP_COM_BRIDGE_SCALE;
        *velocity += pump_direction * pump_acceleration * input.dt;
        self.last_pump_acceleration = pump_acceleration;

        let friction = apply_surface_friction(
            *velocity,
            self.support_up,
            self.support_forward,
            input,
            self.last_surface_id,
            false,
        );
        *velocity = friction.velocity;

        let proposed = *position + *velocity * input.dt;
        let Some(contact) = query_support(provider, proposed, self.support_up) else {
            *position = proposed;
            self.phase = TransitionPhase::Airborne;
            self.air_time_seconds = 0.0;
            self.contact_evidence_frames = 0;
            self.curvature_rate_radians_per_second = 0.0;
            self.last_surface_id = None;
            self.align_visual_air(provider, *position, input.dt);
            return TransitionStepOutput {
                left_ground_this_step: true,
                filtered_grounded: false,
                friction,
                ..default()
            };
        };

        let new_up = contact_normal(contact);
        let normal_dot = self.support_up.dot(new_up).clamp(-1.0, 1.0);
        if normal_dot < PROVISIONAL_NORMAL_CONTINUITY_DOT {
            *position = proposed;
            self.phase = TransitionPhase::Airborne;
            self.air_time_seconds = 0.0;
            self.contact_evidence_frames = 0;
            self.curvature_rate_radians_per_second = 0.0;
            self.last_surface_id = None;
            self.align_visual_air(provider, *position, input.dt);
            return TransitionStepOutput {
                left_ground_this_step: true,
                filtered_grounded: false,
                friction,
                ..default()
            };
        }

        let transport = Quat::from_rotation_arc(self.support_up, new_up);
        *velocity = transport * *velocity;
        self.support_forward =
            orthonormal_forward(new_up, transport * self.support_forward, *velocity);
        self.curvature_rate_radians_per_second = normal_dot.acos() / input.dt;
        self.support_up = new_up;
        *position = contact_point(contact);
        self.last_surface_id = Some(contact.surface_id.0);
        self.contact_evidence_frames = self.contact_evidence_frames.saturating_add(1);
        self.align_visual_to(
            self.support_up,
            self.support_forward,
            input.dt,
            PROVISIONAL_GROUND_ALIGNMENT_SECONDS,
        );

        let mut friction = friction;
        friction.acceleration = (*velocity - prior_velocity) / input.dt;
        friction.continuous_velocity_delta = *velocity - prior_velocity;

        TransitionStepOutput {
            filtered_grounded: self.filtered_grounded(),
            surface_id: self.last_surface_id,
            friction,
            ..default()
        }
    }

    fn step_airborne(
        &mut self,
        provider: &GroundProvider,
        position: &mut Vec3,
        velocity: &mut Vec3,
        input: TransitionStepInput,
    ) -> TransitionStepOutput {
        let previous_position = *position;
        let previous_velocity = *velocity;
        *velocity += RETAIL_WORLD_GRAVITY * input.dt;
        let proposed = previous_position + *velocity * input.dt;
        self.air_time_seconds += input.dt;

        if let Some(contact) = sweep_face_contact(provider, previous_position, proposed, *velocity)
        {
            let normal = contact_normal(contact);
            let incoming_normal_speed = velocity.dot(normal);
            if normal.y >= RETAIL_GROUND_NORMAL_MINIMUM_Y
                && incoming_normal_speed < -PROVISIONAL_MIN_IMPACT_SPEED
            {
                *position = contact_point(contact);
                // Retail floor restitution is zero. Resolve only the incoming
                // normal component; tangent momentum survives re-entry.
                *velocity -= normal * incoming_normal_speed;
                self.phase = TransitionPhase::Grounded;
                self.support_up = normal;
                self.support_forward = orthonormal_forward(normal, self.support_forward, *velocity);
                self.contact_evidence_frames = 1;
                self.air_time_seconds = 0.0;
                self.curvature_rate_radians_per_second = 0.0;
                self.last_surface_id = Some(contact.surface_id.0);
                self.align_visual_to(
                    self.support_up,
                    self.support_forward,
                    input.dt,
                    PROVISIONAL_GROUND_ALIGNMENT_SECONDS,
                );
                let friction = apply_surface_friction(
                    *velocity,
                    self.support_up,
                    self.support_forward,
                    input,
                    self.last_surface_id,
                    true,
                );
                *velocity = friction.velocity;
                return TransitionStepOutput {
                    landed_this_step: true,
                    filtered_grounded: false,
                    surface_id: self.last_surface_id,
                    friction,
                    ..default()
                };
            }
        }

        *position = proposed;
        self.align_visual_air(provider, *position, input.dt);
        let mut friction = integrate_contact_friction(ContactFrictionInput {
            velocity: *velocity,
            board_yaw: 0.0,
            fixed_delta_seconds: input.dt,
            contact: BoardContactState::airborne(),
            touchdown_this_step: false,
            powersliding: false,
            braking: false,
            maximum_speed: input.maximum_speed,
        });
        friction.acceleration = (*velocity - previous_velocity) / input.dt;
        friction.continuous_velocity_delta = *velocity - previous_velocity;
        TransitionStepOutput {
            filtered_grounded: false,
            friction,
            ..default()
        }
    }

    fn apply_heading_delta(&mut self, heading_delta: f32) {
        if heading_delta.abs() <= f32::EPSILON {
            return;
        }
        let physical_axis = if self.phase == TransitionPhase::Grounded {
            self.support_up
        } else {
            self.visual_up
        };
        self.support_forward = (Quat::from_axis_angle(physical_axis, heading_delta)
            * self.support_forward)
            .reject_from(physical_axis)
            .normalize_or(self.support_forward);
        self.visual_forward = (Quat::from_axis_angle(self.visual_up, heading_delta)
            * self.visual_forward)
            .reject_from(self.visual_up)
            .normalize_or(self.visual_forward);
    }

    fn align_visual_air(&mut self, provider: &GroundProvider, position: Vec3, dt: f32) {
        let landing = query_down(
            provider,
            position + Vec3::Y * PROVISIONAL_SWEEP_START_EPSILON,
            PROVISIONAL_AIR_LANDING_LOOKAHEAD_METRES,
        );
        let target_up = landing
            .filter(|contact| {
                let distance = position.y - contact.point.y;
                distance <= 1.0 || self.air_time_seconds >= RETAIL_NATURAL_AIR_TIME_SECONDS
            })
            .map(contact_normal)
            .unwrap_or(Vec3::Y);
        let target_forward =
            orthonormal_forward(target_up, self.visual_forward, self.support_forward);
        self.align_visual_to(
            target_up,
            target_forward,
            dt,
            RETAIL_NATURAL_AIR_TIME_SECONDS,
        );
    }

    fn align_visual_to(&mut self, up: Vec3, forward: Vec3, dt: f32, response_seconds: f32) {
        let current = frame_rotation(self.visual_up, self.visual_forward);
        let target = frame_rotation(up, forward);
        let weight = 1.0 - (-dt / response_seconds.max(f32::EPSILON)).exp();
        let rotation = current.slerp(target, weight).normalize();
        self.visual_up = (rotation * Vec3::Y).normalize_or(up);
        self.visual_forward = orthonormal_forward(self.visual_up, rotation * Vec3::Z, forward);
    }
}

#[cfg(test)]
pub fn build_transition_ground() -> GroundProvider {
    let terrain =
        TransitionTestTerrain::load_embedded().expect("embedded transition collider is valid");
    let mut provider = GroundProvider::new();
    for (triangle, surface_id) in terrain.triangles.iter().zip(&terrain.surface_ids) {
        provider
            .add_triangle(
                to_ground(triangle.triangle.vertex_0),
                to_ground(triangle.triangle.vertex_1),
                to_ground(triangle.triangle.vertex_2),
                SurfaceId(u32::from(*surface_id)),
            )
            .expect("validated transition triangle can enter the ground provider");
    }
    provider
}

fn apply_surface_friction(
    velocity: Vec3,
    up: Vec3,
    forward: Vec3,
    input: TransitionStepInput,
    surface_id: Option<u32>,
    touchdown: bool,
) -> ContactFrictionOutput {
    let forward = orthonormal_forward(up, forward, velocity);
    let right = up.cross(forward).normalize_or(Vec3::X);
    let local_velocity = Vec3::new(velocity.dot(right), 0.0, velocity.dot(forward));
    let local = integrate_contact_friction(ContactFrictionInput {
        velocity: local_velocity,
        board_yaw: 0.0,
        fixed_delta_seconds: input.dt,
        contact: BoardContactState::four_wheels(surface_id),
        touchdown_this_step: touchdown,
        powersliding: input.powersliding,
        braking: input.braking,
        maximum_speed: input.maximum_speed,
    });
    let world_velocity = right * local.velocity.x + forward * local.velocity.z;
    let world_delta = world_velocity - velocity;
    ContactFrictionOutput {
        velocity: world_velocity,
        acceleration: world_delta / input.dt,
        one_shot_velocity_delta: Vec3::ZERO,
        continuous_velocity_delta: world_delta,
        ..local
    }
}

fn query_support(
    provider: &GroundProvider,
    proposed: Vec3,
    previous_up: Vec3,
) -> Option<SurfaceContact> {
    let origin = proposed + previous_up * PROVISIONAL_SUPPORT_PROBE_OFFSET;
    let contact = query_direction(
        provider,
        origin,
        -previous_up,
        PROVISIONAL_SUPPORT_PROBE_OFFSET + PROVISIONAL_SUPPORT_DISTANCE,
    )?;
    let point = contact_point(contact);
    let separation = (proposed - point).dot(previous_up).abs();
    (separation <= PROVISIONAL_SUPPORT_DISTANCE).then_some(contact)
}

fn sweep_face_contact(
    provider: &GroundProvider,
    previous: Vec3,
    proposed: Vec3,
    velocity: Vec3,
) -> Option<SurfaceContact> {
    let displacement = proposed - previous;
    let distance = displacement.length();
    if distance <= PROVISIONAL_SWEEP_START_EPSILON {
        return None;
    }
    let direction = displacement / distance;
    let origin = previous + direction * PROVISIONAL_SWEEP_START_EPSILON;
    let contact = query_direction(
        provider,
        origin,
        direction,
        (distance - PROVISIONAL_SWEEP_START_EPSILON).max(0.0),
    )?;
    let normal = contact_normal(contact);
    (velocity.dot(normal) < 0.0).then_some(contact)
}

fn query_down(provider: &GroundProvider, origin: Vec3, distance: f32) -> Option<SurfaceContact> {
    provider
        .query_down(to_ground_vec(origin), distance)
        .expect("finite transition down probe")
        .contact()
}

fn query_direction(
    provider: &GroundProvider,
    origin: Vec3,
    direction: Vec3,
    distance: f32,
) -> Option<SurfaceContact> {
    let probe = GroundProbe::new(to_ground_vec(origin), to_ground_vec(direction), distance)
        .expect("finite transition face probe");
    provider.query(probe).contact()
}

fn contact_point(contact: SurfaceContact) -> Vec3 {
    Vec3::new(contact.point.x, contact.point.y, contact.point.z)
}

fn contact_normal(contact: SurfaceContact) -> Vec3 {
    Vec3::new(contact.normal.x, contact.normal.y, contact.normal.z).normalize_or(Vec3::Y)
}

fn projected_heading(yaw: f32, up: Vec3, fallback: Vec3) -> Vec3 {
    let horizontal = Vec3::new(yaw.sin(), 0.0, yaw.cos());
    orthonormal_forward(up, horizontal, fallback)
}

fn orthonormal_forward(up: Vec3, preferred: Vec3, fallback: Vec3) -> Vec3 {
    let up = up.normalize_or(Vec3::Y);
    let projected = preferred.reject_from(up);
    if projected.length_squared() > 1.0e-10 {
        return projected.normalize();
    }
    let fallback = fallback.reject_from(up);
    if fallback.length_squared() > 1.0e-10 {
        return fallback.normalize();
    }
    let axis = if up.y.abs() < 0.9 { Vec3::Y } else { Vec3::Z };
    axis.reject_from(up).normalize_or(Vec3::Z)
}

fn frame_rotation(up: Vec3, forward: Vec3) -> Quat {
    let up = up.normalize_or(Vec3::Y);
    let forward = orthonormal_forward(up, forward, Vec3::Z);
    let right = up.cross(forward).normalize_or(Vec3::X);
    let forward = right.cross(up).normalize_or(forward);
    Quat::from_mat3(&Mat3::from_cols(right, up, forward)).normalize()
}

#[cfg(test)]
fn to_ground(value: crate::skateboard_body::Vector3) -> GroundVec3 {
    GroundVec3::new(value.x, value.y, value.z)
}

fn to_ground_vec(value: Vec3) -> GroundVec3 {
    GroundVec3::new(value.x, value.y, value.z)
}

#[cfg(test)]
mod tests {
    use super::*;

    const DT: f32 = 1.0 / 120.0;
    const MAX_SPEED: f32 = 12.5;

    fn initialized(speed: f32) -> (GroundProvider, TransitionRuntime, Vec3, Vec3) {
        let provider = build_transition_ground();
        let mut runtime = TransitionRuntime::default();
        let mut position = Vec3::ZERO;
        assert!(runtime.activate(&provider, &mut position, 0.0));
        (provider, runtime, position, Vec3::Z * speed)
    }

    #[test]
    fn authored_fixture_is_the_only_runtime_ground() {
        let provider = build_transition_ground();
        assert_eq!(provider.len(), 314);
        assert!(provider.surfaces().iter().all(|surface| {
            matches!(
                surface,
                crate::ground_provider::AnalyticSurface::Triangle(_)
            )
        }));
    }

    #[test]
    fn sub_lip_coast_climbs_reverses_and_crosses_back_without_contact_loss() {
        let (provider, mut runtime, mut position, mut velocity) = initialized(6.25);
        let initial_energy = 0.5 * velocity.length_squared() - RETAIL_WORLD_GRAVITY.y * position.y;
        let mut maximum_height = position.y;
        let mut crossed_center_after_reversal = false;
        let mut prior_z = position.z;
        for _ in 0..900 {
            let output = runtime.step(
                &provider,
                &mut position,
                &mut velocity,
                TransitionStepInput::coast(DT, MAX_SPEED),
            );
            assert!(!output.left_ground_this_step);
            assert!(runtime.is_physically_grounded());
            maximum_height = maximum_height.max(position.y);
            crossed_center_after_reversal |= prior_z > 0.0 && position.z <= 0.0;
            prior_z = position.z;
            if crossed_center_after_reversal {
                break;
            }
        }
        let final_energy = 0.5 * velocity.length_squared() - RETAIL_WORLD_GRAVITY.y * position.y;
        assert!(maximum_height > 1.2);
        assert!(crossed_center_after_reversal);
        assert!((final_energy - initial_energy).abs() < 2.0);
    }

    #[test]
    fn sufficient_speed_leaves_the_open_lip_without_an_attachment_impulse() {
        let (provider, mut runtime, mut position, mut velocity) = initialized(8.5);
        let mut launch = None;
        for _ in 0..720 {
            let before = velocity;
            let output = runtime.step(
                &provider,
                &mut position,
                &mut velocity,
                TransitionStepInput::coast(DT, MAX_SPEED),
            );
            if output.left_ground_this_step {
                launch = Some((before, velocity, position));
                break;
            }
        }
        let (before, after, launch_position) = launch.expect("speed should clear the lip");
        assert_eq!(runtime.phase, TransitionPhase::Airborne);
        assert!(launch_position.y >= 2.45);
        assert!(after.y > 0.0);
        assert!((after - before).length() < 0.2);
    }

    #[test]
    fn airborne_motion_is_ballistic_and_has_no_target_lock() {
        let provider = build_transition_ground();
        let mut runtime = TransitionRuntime::default();
        runtime.phase = TransitionPhase::Airborne;
        runtime.support_up = Vec3::new(0.0, 0.0, -1.0);
        runtime.visual_up = runtime.support_up;
        let mut position = Vec3::new(0.0, 5.0, 20.0);
        let mut velocity = Vec3::new(1.25, 3.0, 2.5);
        let start_xz = Vec2::new(velocity.x, velocity.z);
        for _ in 0..30 {
            runtime.step(
                &provider,
                &mut position,
                &mut velocity,
                TransitionStepInput::coast(DT, MAX_SPEED),
            );
        }
        assert!((Vec2::new(velocity.x, velocity.z) - start_xz).length() < 1.0e-6);
        assert!((velocity.y - (3.0 + RETAIL_WORLD_GRAVITY.y * 30.0 * DT)).abs() < 1.0e-5);
        assert!(runtime.visual_up.dot(Vec3::Y) > 0.7);
    }

    #[test]
    fn swept_deck_landing_resolves_once_then_filters_on_fourth_frame() {
        let provider = build_transition_ground();
        let mut runtime = TransitionRuntime::default();
        runtime.phase = TransitionPhase::Airborne;
        runtime.visual_up = Vec3::Y;
        runtime.visual_forward = Vec3::Z;
        let mut position = Vec3::new(0.0, 3.2, 16.0);
        let mut velocity = Vec3::new(0.0, -3.0, 0.0);
        let mut landings = 0;
        let mut filtered_on = None;
        for frame in 1..=120 {
            let output = runtime.step(
                &provider,
                &mut position,
                &mut velocity,
                TransitionStepInput::coast(DT, MAX_SPEED),
            );
            landings += usize::from(output.landed_this_step);
            if output.filtered_grounded && filtered_on.is_none() {
                filtered_on = Some(frame);
            }
        }
        assert_eq!(landings, 1);
        assert!(runtime.is_physically_grounded());
        assert!(runtime.filtered_grounded());
        assert_eq!(runtime.contact_evidence_frames >= 4, true);
        assert!(filtered_on.is_some());
        assert!((position.y - 2.5).abs() < 1.0e-3);
    }

    #[test]
    fn descending_air_reenters_the_curved_transition_face() {
        let provider = build_transition_ground();
        let mut runtime = TransitionRuntime::default();
        runtime.phase = TransitionPhase::Airborne;
        runtime.visual_up = Vec3::Y;
        runtime.visual_forward = Vec3::Z;

        let angle = 60.0_f32.to_radians();
        let surface = Vec3::new(0.0, 2.5 * (1.0 - angle.cos()), 12.0 + 2.5 * angle.sin());
        let normal = Vec3::new(0.0, angle.cos(), -angle.sin());
        let downhill = Vec3::new(0.0, -angle.sin(), -angle.cos());
        let mut position = surface + normal * 0.20;
        let mut velocity = downhill * 3.0 - normal;
        let mut landed = false;

        for _ in 0..120 {
            let output = runtime.step(
                &provider,
                &mut position,
                &mut velocity,
                TransitionStepInput::coast(DT, MAX_SPEED),
            );
            landed |= output.landed_this_step;
            if landed {
                break;
            }
        }

        assert!(landed);
        assert!(runtime.is_physically_grounded());
        assert!(
            (0.2..0.9).contains(&runtime.support_up.y),
            "support_up={:?} position={position:?}",
            runtime.support_up
        );
        assert!(runtime.support_up.z < -0.5);
        assert!((12.0..14.5).contains(&position.z));
        assert!(position.y < 2.5);
        assert!(velocity.dot(runtime.support_up).abs() < 1.0e-4);
    }

    #[test]
    fn pump_proxy_adds_bounded_energy_only_while_curving() {
        let (provider, mut coast, mut coast_position, mut coast_velocity) = initialized(6.0);
        let mut pumped = coast;
        let mut pumped_position = coast_position;
        let mut pumped_velocity = coast_velocity;
        let mut saw_pump = false;
        for _ in 0..360 {
            coast.step(
                &provider,
                &mut coast_position,
                &mut coast_velocity,
                TransitionStepInput::coast(DT, MAX_SPEED),
            );
            let mut input = TransitionStepInput::coast(DT, MAX_SPEED);
            input.pump_intent = 1.0;
            pumped.step(&provider, &mut pumped_position, &mut pumped_velocity, input);
            saw_pump |= pumped.last_pump_acceleration > 0.01;
        }
        let coast_energy =
            0.5 * coast_velocity.length_squared() - RETAIL_WORLD_GRAVITY.y * coast_position.y;
        let pumped_energy =
            0.5 * pumped_velocity.length_squared() - RETAIL_WORLD_GRAVITY.y * pumped_position.y;
        assert!(saw_pump);
        assert!(
            pumped_energy > coast_energy,
            "pumped={pumped_energy} coast={coast_energy}"
        );
        assert!(pumped_velocity.length() <= MAX_SPEED + 1.0e-4);
    }

    #[test]
    fn visual_frame_remains_orthonormal_through_ground_air_and_landing() {
        let (provider, mut runtime, mut position, mut velocity) = initialized(8.5);
        for _ in 0..1200 {
            runtime.step(
                &provider,
                &mut position,
                &mut velocity,
                TransitionStepInput::coast(DT, MAX_SPEED),
            );
            let right = runtime.visual_up.cross(runtime.visual_forward);
            assert!((runtime.visual_up.length() - 1.0).abs() < 1.0e-4);
            assert!((runtime.visual_forward.length() - 1.0).abs() < 1.0e-4);
            assert!(runtime.visual_up.dot(runtime.visual_forward).abs() < 1.0e-4);
            assert!((right.length() - 1.0).abs() < 1.0e-4);
            assert!(position.is_finite() && velocity.is_finite());
        }
    }
}
