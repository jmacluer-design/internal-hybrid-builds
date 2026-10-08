use bevy::prelude::*;

use crate::ground_provider::{GroundProbe, GroundProvider, GroundVec3};
use crate::sim::{FIXED_HZ, SkateSim};
use crate::transition::TransitionPhase;

// Retail High-camera evidence, 2026-08-31:
// - Default_cameragraph.xml selects camera type 1 for CameraHigh.
// - cameragraph_high.xml keeps grounded riding on bl_high_chase; unlike the
//   Low graph, it has no TurningCentredTime/bl_turning branch.
// - A live type-1 ViewCamera snapshot measured 2.597 m horizontal distance
//   and 1.796 m height from the board reference at rest.
// - ViewCamera projection m11 is exactly 1.5, giving 67.380135 degrees
//   vertical FOV.
//
pub(crate) const RETAIL_HIGH_VERTICAL_FOV: f32 = 1.176_005_2;

// These chase heading coefficients were measured while the Low graph was in
// its stable bl_chase regime. The High graph's grounded shot is
// bl_high_chase, so sharing the stable chase response is currently inferred;
// critically, the proven Low-only bl_turning accumulator is not used.
const CHASE_STIFFNESS: f32 = 19.682_44;
const CHASE_DAMPING: f32 = 16.085_688;

const CHASE_DISTANCE_AT_REST: f32 = 2.597;
const CAMERA_HEIGHT_AT_REST: f32 = 1.7957;

// These small speed terms remain inherited from the synchronized Low-camera
// capture until a deterministic type-1 harness capture is available.
const CHASE_DISTANCE_PER_MPS: f32 = 0.0125;
const CAMERA_HEIGHT_PER_MPS: f32 = 0.013;
const CAMERA_SPEED_RANGE: f32 = 9.0;
const SUBJECT_HEIGHT: f32 = 1.145;
const LOW_OLLIE_PITCH: f32 = -13.9_f32.to_radians();
const PITCH_RESPONSE: f32 = 10.0;

// cameragraph_high.xml still selects low_ollie for a normal small Ollie. Its
// first-order vertical response and measured pitch therefore remain valid.
const AIR_VERTICAL_RESPONSE: f32 = 0.60;
const GROUND_VERTICAL_RESPONSE: f32 = 4.0;
// Both recovered camera graphs select offboard_ground with transitionIn=1.0.
// The shot's own rig parameters remain unavailable, so only its proven
// transition ownership is ported here; framing stays on the existing measured
// High-camera values.
const OFFBOARD_GROUND_TRANSITION_SECONDS: f32 = 1.0;

// Provisional transition-camera bridge, authorized for the playable transition
// pass. The retail High graph proves that natural transition air selects
// bl_high_air rather than low_ollie, but the decoded shot-position payload is
// not yet available. Keep its spatial assumptions isolated here:
// - frame the authored skater along the transition runtime's conditioned visual
//   up axis instead of assuming the body always extends along world Y;
// - reuse the measured High chase distance/height;
// - reuse the existing grounded follow response for bl_high_air instead of the
//   captured low_ollie lag;
// - keep the camera on the subject side of authored transition geometry.
const PROVISIONAL_TRANSITION_CAMERA_CLEARANCE: f32 = 0.10;
const PROVISIONAL_STEEP_TRANSITION_UP_Y: f32 = std::f32::consts::FRAC_1_SQRT_2;
const PROVISIONAL_TRANSITION_ORBIT_UP_Y: f32 = 0.95;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum RetailCameraShot {
    #[default]
    HighChase,
    LowOllie,
    HighAir,
}

#[derive(Resource, Debug, Clone)]
pub struct RetailCameraRig {
    pub position: Vec3,
    pub focus: Vec3,
    pub forward: Vec3,
    pub right: Vec3,
    pub up: Vec3,
    pub yaw: f32,
    pub yaw_velocity: f32,
    pub pitch: f32,
    // Kept in oracle telemetry for capture-schema compatibility. The High
    // graph has no grounded turning-shot branch, so this remains false.
    pub turning_shot: bool,
    pub shot: RetailCameraShot,
    initialized: bool,
    offboard_ground_active: bool,
    offboard_transition_remaining: f32,
}

impl Default for RetailCameraRig {
    fn default() -> Self {
        Self {
            position: Vec3::new(0.0, CAMERA_HEIGHT_AT_REST, -CHASE_DISTANCE_AT_REST),
            focus: Vec3::Y * SUBJECT_HEIGHT,
            forward: Vec3::Z,
            right: Vec3::X,
            up: Vec3::Y,
            yaw: 0.0,
            yaw_velocity: 0.0,
            pitch: 0.0,
            turning_shot: false,
            shot: RetailCameraShot::HighChase,
            initialized: false,
            offboard_ground_active: false,
            offboard_transition_remaining: 0.0,
        }
    }
}

impl RetailCameraRig {
    fn step(&mut self, sim: &SkateSim, provider: Option<&GroundProvider>, dt: f32) {
        if sim.transition.is_enabled() {
            self.step_transition(sim, provider, dt);
        } else {
            self.step_flat(sim, dt);
        }
    }

    fn step_heading(&mut self, target_yaw: f32, dt: f32) {
        self.yaw_velocity += wrap_angle(target_yaw - self.yaw) * CHASE_STIFFNESS * dt;
        self.yaw_velocity *= (-CHASE_DAMPING * dt).exp();
        self.yaw = wrap_angle(self.yaw + self.yaw_velocity * dt);
    }

    fn step_flat(&mut self, sim: &SkateSim, dt: f32) {
        if !self.initialized {
            self.yaw = sim.view_yaw;
            self.position.y = sim.position.y + camera_height(sim.speed());
            self.pitch = ground_pitch(self.position.y - sim.position.y, CHASE_DISTANCE_AT_REST);
            self.focus = sim.position + Vec3::Y * SUBJECT_HEIGHT;
            self.initialized = true;
        }

        if sim.offboard.is_some() {
            if !self.offboard_ground_active {
                self.offboard_ground_active = true;
                self.offboard_transition_remaining = OFFBOARD_GROUND_TRANSITION_SECONDS;
                self.yaw_velocity = 0.0;
            }

            // CameraChooseShot owns this one-second transition. A bounded
            // angular interpolation cannot overshoot a monotonic trajectory,
            // unlike the onboard second-order chase spring that previously
            // fed visible side-to-side motion into offboard reorientation.
            if self.offboard_transition_remaining > 0.0 {
                let weight = (dt / self.offboard_transition_remaining).clamp(0.0, 1.0);
                self.yaw = wrap_angle(lerp_angle(self.yaw, sim.view_yaw, weight));
                self.offboard_transition_remaining =
                    (self.offboard_transition_remaining - dt).max(0.0);
            } else {
                self.yaw = sim.view_yaw;
            }
            self.yaw_velocity = 0.0;
        } else {
            if self.offboard_ground_active {
                self.offboard_ground_active = false;
                self.offboard_transition_remaining = 0.0;
                self.yaw_velocity = 0.0;
            }
            self.yaw_velocity += wrap_angle(sim.view_yaw - self.yaw) * CHASE_STIFFNESS * dt;
            self.yaw_velocity *= (-CHASE_DAMPING * dt).exp();
            self.yaw = wrap_angle(self.yaw + self.yaw_velocity * dt);
        }

        let speed = sim.speed().clamp(0.0, CAMERA_SPEED_RANGE);
        let distance = CHASE_DISTANCE_AT_REST + CHASE_DISTANCE_PER_MPS * speed;
        let horizontal_forward = Vec3::new(self.yaw.sin(), 0.0, self.yaw.cos());
        self.position.x = sim.position.x - horizontal_forward.x * distance;
        self.position.z = sim.position.z - horizontal_forward.z * distance;

        let desired_y = sim.position.y + camera_height(speed);
        let vertical_rate = if sim.ground_contact_valid {
            GROUND_VERTICAL_RESPONSE
        } else {
            AIR_VERTICAL_RESPONSE
        };
        let vertical_weight = 1.0 - (-vertical_rate * dt).exp();
        self.position.y += (desired_y - self.position.y) * vertical_weight;

        let desired_pitch = if sim.ground_contact_valid {
            self.shot = RetailCameraShot::HighChase;
            ground_pitch(self.position.y - sim.position.y, distance)
        } else {
            self.shot = RetailCameraShot::LowOllie;
            LOW_OLLIE_PITCH
        };
        let pitch_weight = 1.0 - (-PITCH_RESPONSE * dt).exp();
        self.pitch += (desired_pitch - self.pitch) * pitch_weight;
        let pitch_cos = self.pitch.cos();
        self.forward = Vec3::new(
            self.yaw.sin() * pitch_cos,
            self.pitch.sin(),
            self.yaw.cos() * pitch_cos,
        );
        self.right = Vec3::Y.cross(self.forward).normalize_or(Vec3::X);
        self.up = self.forward.cross(self.right).normalize_or(Vec3::Y);
        self.focus = self.position + self.forward * distance;
    }

    fn step_transition(&mut self, sim: &SkateSim, provider: Option<&GroundProvider>, dt: f32) {
        let speed = sim.speed().clamp(0.0, CAMERA_SPEED_RANGE);
        let distance = CHASE_DISTANCE_AT_REST + CHASE_DISTANCE_PER_MPS * speed;
        let subject_up = sim.transition.visual_up.normalize_or(Vec3::Y);
        let desired_focus = sim.position + subject_up * SUBJECT_HEIGHT;

        self.shot = select_transition_shot(
            sim.transition.phase,
            sim.pop_motion.is_some(),
            sim.transition.support_up.y,
        );

        if !self.initialized {
            self.yaw = sim.view_yaw;
            self.focus = desired_focus;
            let horizontal_forward = Vec3::new(self.yaw.sin(), 0.0, self.yaw.cos());
            self.position = desired_focus - horizontal_forward * distance
                + Vec3::Y * (camera_height(speed) - SUBJECT_HEIGHT);
            self.initialized = true;
        }

        self.step_heading(transition_target_yaw(sim.view_yaw, subject_up), dt);
        self.focus = desired_focus;

        let horizontal_forward = Vec3::new(self.yaw.sin(), 0.0, self.yaw.cos());
        let desired_position = self.focus - horizontal_forward * distance
            + Vec3::Y * (camera_height(speed) - SUBJECT_HEIGHT);

        // X/Z remain directly tied to the chase subject, as in the measured
        // flat shot. High transition air must not inherit low_ollie's 1.67 s
        // vertical lag, because the High graph selects bl_high_air here.
        self.position.x = desired_position.x;
        self.position.z = desired_position.z;
        let vertical_weight = 1.0 - (-GROUND_VERTICAL_RESPONSE * dt).exp();
        self.position.y += (desired_position.y - self.position.y) * vertical_weight;

        if let Some(provider) = provider {
            self.position = collision_safe_position(provider, self.focus, self.position, distance);
        }

        self.forward = (self.focus - self.position).normalize_or(horizontal_forward);
        self.pitch = self.forward.y.asin();
        self.right = Vec3::Y.cross(self.forward).normalize_or(Vec3::X);
        self.up = self.forward.cross(self.right).normalize_or(Vec3::Y);
    }
}

fn camera_height(speed: f32) -> f32 {
    CAMERA_HEIGHT_AT_REST + CAMERA_HEIGHT_PER_MPS * speed.clamp(0.0, CAMERA_SPEED_RANGE)
}

fn ground_pitch(camera_height: f32, distance: f32) -> f32 {
    (SUBJECT_HEIGHT - camera_height).atan2(distance)
}

fn wrap_angle(angle: f32) -> f32 {
    (angle + std::f32::consts::PI).rem_euclid(std::f32::consts::TAU) - std::f32::consts::PI
}

fn lerp_angle(current: f32, target: f32, weight: f32) -> f32 {
    current + wrap_angle(target - current) * weight.clamp(0.0, 1.0)
}

fn select_transition_shot(
    phase: TransitionPhase,
    pop_active: bool,
    support_up_y: f32,
) -> RetailCameraShot {
    match phase {
        TransitionPhase::Airborne
            if pop_active && support_up_y >= PROVISIONAL_STEEP_TRANSITION_UP_Y =>
        {
            RetailCameraShot::LowOllie
        }
        TransitionPhase::Airborne => RetailCameraShot::HighAir,
        TransitionPhase::Disabled | TransitionPhase::Grounded => RetailCameraShot::HighChase,
    }
}

fn transition_target_yaw(view_yaw: f32, subject_up: Vec3) -> f32 {
    if subject_up.y >= PROVISIONAL_TRANSITION_ORBIT_UP_Y {
        return view_yaw;
    }
    let inward = Vec3::new(subject_up.x, 0.0, subject_up.z).normalize_or_zero();
    if inward == Vec3::ZERO {
        return view_yaw;
    }
    let camera_forward = -inward;
    camera_forward.x.atan2(camera_forward.z)
}

fn collision_safe_position(
    provider: &GroundProvider,
    focus: Vec3,
    desired_position: Vec3,
    fallback_distance: f32,
) -> Vec3 {
    let offset = desired_position - focus;
    let distance = offset.length();
    if !distance.is_finite() || distance <= f32::EPSILON {
        return focus - Vec3::Z * fallback_distance;
    }
    let direction = offset / distance;
    let Ok(probe) = GroundProbe::new(
        GroundVec3::new(focus.x, focus.y, focus.z),
        GroundVec3::new(direction.x, direction.y, direction.z),
        distance,
    ) else {
        return desired_position;
    };
    let Some(contact) = provider.query(probe).contact() else {
        return desired_position;
    };
    let safe_distance = (contact.distance - PROVISIONAL_TRANSITION_CAMERA_CLEARANCE).max(0.0);
    focus + direction * safe_distance
}

pub(crate) fn step_retail_camera(
    mut rig: ResMut<RetailCameraRig>,
    sim: Res<SkateSim>,
    ground: Res<crate::sim::SkateGround>,
) {
    rig.step(
        &sim,
        sim.transition.is_enabled().then_some(&ground.provider),
        1.0 / FIXED_HZ as f32,
    );
}

pub(crate) fn apply_retail_camera(
    rig: Res<RetailCameraRig>,
    mut cameras: Query<&mut Transform, With<crate::FollowCamera>>,
) {
    let Ok(mut camera) = cameras.single_mut() else {
        return;
    };
    camera.translation = rig.position;
    camera.look_to(rig.forward, Vec3::Y);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transition::{TransitionRuntime, TransitionStepInput, build_transition_ground};

    #[test]
    fn settled_camera_uses_measured_retail_framing() {
        let sim = SkateSim::default();
        let mut rig = RetailCameraRig::default();
        for _ in 0..240 {
            rig.step(&sim, None, 1.0 / FIXED_HZ as f32);
        }
        assert!((rig.position.z + CHASE_DISTANCE_AT_REST).abs() < 1.0e-4);
        assert!((rig.position.y - CAMERA_HEIGHT_AT_REST).abs() < 1.0e-4);
        assert!(
            (rig.pitch - ground_pitch(CAMERA_HEIGHT_AT_REST, CHASE_DISTANCE_AT_REST)).abs()
                < 1.0e-4
        );
    }

    #[test]
    fn retail_projection_matches_captured_high_camera() {
        let projection_m11 = 1.0 / (RETAIL_HIGH_VERTICAL_FOV * 0.5).tan();
        assert!((projection_m11 - 1.5).abs() < 1.0e-6);
    }

    #[test]
    fn high_camera_uses_stable_chase_during_alternating_carves() {
        let mut sim = SkateSim::default();
        sim.velocity.z = 5.0;
        let mut rig = RetailCameraRig::default();
        for _ in 0..120 {
            rig.step(&sim, None, 1.0 / FIXED_HZ as f32);
        }

        for target in [0.55, -0.55, 0.55, -0.55, 0.0] {
            sim.view_yaw = target;
            for _ in 0..600 {
                rig.step(&sim, None, 1.0 / FIXED_HZ as f32);
                assert!(!rig.turning_shot);
            }
            assert!(
                wrap_angle(rig.yaw - target).abs() < 0.004,
                "target={target} yaw={} velocity={}",
                rig.yaw,
                rig.yaw_velocity
            );
            assert!(
                rig.yaw_velocity.abs() < 0.005,
                "target={target} yaw={} velocity={}",
                rig.yaw,
                rig.yaw_velocity
            );
        }
    }

    #[test]
    fn offboard_ground_transition_is_monotonic_and_never_overshoots() {
        let mut sim = SkateSim::default();
        sim.offboard = Some(crate::offboard::OffboardRuntime::begin_dismount(
            0.0, sim.yaw,
        ));
        let mut rig = RetailCameraRig::default();
        rig.step(&sim, None, 1.0 / FIXED_HZ as f32);

        let mut previous_yaw = rig.yaw;
        for frame in 1..=FIXED_HZ as usize {
            sim.view_yaw = -1.5 * frame as f32 / FIXED_HZ as f32;
            rig.step(&sim, None, 1.0 / FIXED_HZ as f32);
            let delta = wrap_angle(rig.yaw - previous_yaw);
            assert!(
                delta <= 1.0e-6,
                "offboard camera reversed direction at frame {frame}: {delta}"
            );
            assert!(
                rig.yaw >= sim.view_yaw - 1.0e-5,
                "offboard camera overshot its target at frame {frame}"
            );
            assert_eq!(rig.yaw_velocity, 0.0);
            previous_yaw = rig.yaw;
        }
        assert!((rig.yaw - sim.view_yaw).abs() < 1.0e-5);

        for _ in 0..FIXED_HZ as usize {
            let before = rig.yaw;
            rig.step(&sim, None, 1.0 / FIXED_HZ as f32);
            assert!(wrap_angle(rig.yaw - before).abs() < 1.0e-6);
            assert_eq!(rig.yaw_velocity, 0.0);
        }
    }

    #[test]
    fn mounting_returns_camera_to_the_unchanged_onboard_chase_path() {
        let mut sim = SkateSim::default();
        sim.offboard = Some(crate::offboard::OffboardRuntime::begin_dismount(
            0.0, sim.yaw,
        ));
        let mut rig = RetailCameraRig::default();
        rig.step(&sim, None, 1.0 / FIXED_HZ as f32);
        sim.view_yaw = -0.8;
        for _ in 0..FIXED_HZ as usize {
            rig.step(&sim, None, 1.0 / FIXED_HZ as f32);
        }
        assert!(rig.offboard_ground_active);

        sim.offboard = None;
        sim.view_yaw = 0.45;
        rig.step(&sim, None, 1.0 / FIXED_HZ as f32);
        assert!(!rig.offboard_ground_active);
        assert!(rig.yaw_velocity > 0.0);
        for _ in 0..600 {
            rig.step(&sim, None, 1.0 / FIXED_HZ as f32);
        }
        assert!(wrap_angle(rig.yaw - sim.view_yaw).abs() < 0.004);
        assert!(rig.yaw_velocity.abs() < 0.005);
    }

    #[test]
    fn low_ollie_holds_the_captured_air_pitch() {
        let mut sim = SkateSim::default();
        let mut rig = RetailCameraRig::default();
        rig.step(&sim, None, 1.0 / FIXED_HZ as f32);
        sim.ground_contact_valid = false;
        sim.position.y = 0.86;
        for _ in 0..120 {
            rig.step(&sim, None, 1.0 / FIXED_HZ as f32);
        }
        assert!((rig.pitch - LOW_OLLIE_PITCH).abs() < 1.0e-4);
        assert_eq!(rig.shot, RetailCameraShot::LowOllie);
    }

    #[test]
    fn transition_air_selects_high_air_instead_of_flat_low_ollie() {
        let mut sim = SkateSim::default();
        sim.transition.phase = TransitionPhase::Airborne;
        sim.transition.visual_up = Vec3::NEG_Z;
        sim.transition.visual_forward = Vec3::Y;
        sim.ground_contact_valid = false;
        sim.position = Vec3::new(0.0, 2.5, 12.0);
        sim.velocity = Vec3::Y * 2.0;

        let mut rig = RetailCameraRig::default();
        rig.step(&sim, None, 1.0 / FIXED_HZ as f32);

        assert_eq!(rig.shot, RetailCameraShot::HighAir);
        assert_eq!(rig.focus, sim.position + Vec3::NEG_Z * SUBJECT_HEIGHT);
        assert!(rig.forward.dot((rig.focus - rig.position).normalize()) > 0.9999);
    }

    #[test]
    fn steep_transition_pop_does_not_reuse_the_flat_low_ollie_shot() {
        assert_eq!(
            select_transition_shot(TransitionPhase::Airborne, true, 0.2),
            RetailCameraShot::HighAir
        );
        assert_eq!(
            select_transition_shot(TransitionPhase::Airborne, true, 0.9),
            RetailCameraShot::LowOllie
        );
    }

    #[test]
    fn vertical_transition_frames_the_oriented_body_not_the_board_root() {
        let mut sim = SkateSim::default();
        sim.transition.phase = TransitionPhase::Grounded;
        sim.transition.support_up = Vec3::NEG_Z;
        sim.transition.support_forward = Vec3::Y;
        sim.transition.visual_up = Vec3::NEG_Z;
        sim.transition.visual_forward = Vec3::Y;
        sim.position = Vec3::new(0.0, 2.5, 12.0);
        sim.velocity = Vec3::Y * 4.0;

        let mut rig = RetailCameraRig::default();
        for _ in 0..120 {
            rig.step(&sim, None, 1.0 / FIXED_HZ as f32);
        }

        let expected_focus = sim.position + Vec3::NEG_Z * SUBJECT_HEIGHT;
        assert!((rig.focus - expected_focus).length() < 1.0e-5);
        assert!(
            (rig.position - rig.focus).length() > CHASE_DISTANCE_AT_REST,
            "camera collapsed into the horizontal skater: position={:?} focus={:?}",
            rig.position,
            rig.focus
        );
        assert!(rig.forward.dot((rig.focus - rig.position).normalize()) > 0.9999);
        assert!(rig.up.dot(Vec3::Y) > 0.5);
    }

    #[test]
    fn transition_camera_stays_on_the_subject_side_of_authored_geometry() {
        let mut provider = GroundProvider::new();
        provider
            .add_plane(
                GroundVec3::new(0.0, 0.0, -1.0),
                GroundVec3::new(0.0, 0.0, 1.0),
                crate::ground_provider::SurfaceId(77),
            )
            .unwrap();
        let focus = Vec3::new(0.0, SUBJECT_HEIGHT, 0.0);
        let desired = Vec3::new(0.0, CAMERA_HEIGHT_AT_REST, -CHASE_DISTANCE_AT_REST);
        let safe = collision_safe_position(&provider, focus, desired, CHASE_DISTANCE_AT_REST);

        assert!(safe.z > -1.0);
        assert!(safe.z < 0.0);
        let hit_clearance = -1.0 - safe.z;
        assert!(
            (hit_clearance + PROVISIONAL_TRANSITION_CAMERA_CLEARANCE).abs() < 0.02,
            "safe={safe:?} clearance={hit_clearance}"
        );
    }

    #[test]
    fn transition_traversal_never_flips_the_high_camera_frame() {
        let provider = build_transition_ground();
        let mut sim = SkateSim::default();
        sim.velocity = Vec3::Z * 8.5;
        sim.transition = TransitionRuntime::default();
        assert!(
            sim.transition
                .activate(&provider, &mut sim.position, sim.yaw)
        );
        let mut rig = RetailCameraRig::default();
        for _ in 0..1200 {
            let output = sim.transition.step(
                &provider,
                &mut sim.position,
                &mut sim.velocity,
                TransitionStepInput::coast(1.0 / FIXED_HZ as f32, crate::sim::MAX_SPEED),
            );
            sim.ground_contact_valid = output.filtered_grounded;
            rig.step(&sim, Some(&provider), 1.0 / FIXED_HZ as f32);
            assert!(rig.position.is_finite());
            assert!(rig.forward.is_finite() && rig.right.is_finite() && rig.up.is_finite());
            assert!(
                (rig.focus - (sim.position + sim.transition.visual_up * SUBJECT_HEIGHT)).length()
                    < 1.0e-4
            );
            assert!(rig.forward.dot((rig.focus - rig.position).normalize()) > 0.999);
            if sim.transition.visual_up.y < 0.4 {
                assert!(
                    (rig.position - rig.focus).length() > 2.0,
                    "camera collapsed into the skater at {:?}",
                    sim.position
                );
            }
            if sim.transition.phase == TransitionPhase::Airborne {
                assert_eq!(rig.shot, RetailCameraShot::HighAir);
            }
            assert!(rig.up.dot(Vec3::Y) > 0.5);
            assert!(rig.forward.dot(rig.right).abs() < 1.0e-4);
            assert!(rig.forward.dot(rig.up).abs() < 1.0e-4);
        }
    }

    #[test]
    fn sub_lip_back_and_forth_keeps_camera_clear_on_both_vertical_walls() {
        let provider = build_transition_ground();
        let mut sim = SkateSim::default();
        sim.velocity = Vec3::Z * 6.5;
        sim.transition = TransitionRuntime::default();
        assert!(
            sim.transition
                .activate(&provider, &mut sim.position, sim.yaw)
        );
        let mut rig = RetailCameraRig::default();
        let mut saw_positive_wall = false;
        let mut saw_negative_wall = false;
        let mut previous_camera_position = None;

        for _ in 0..2_400 {
            let output = sim.transition.step(
                &provider,
                &mut sim.position,
                &mut sim.velocity,
                TransitionStepInput::coast(1.0 / FIXED_HZ as f32, crate::sim::MAX_SPEED),
            );
            sim.ground_contact_valid = output.filtered_grounded;
            rig.step(&sim, Some(&provider), 1.0 / FIXED_HZ as f32);

            if let Some(previous) = previous_camera_position {
                assert!(
                    rig.position.distance(previous) < 0.25,
                    "camera snapped from {previous:?} to {:?}",
                    rig.position
                );
            }
            previous_camera_position = Some(rig.position);

            if sim.transition.visual_up.y < 0.4 {
                saw_positive_wall |= sim.position.z > 0.0;
                saw_negative_wall |= sim.position.z < 0.0;
                assert!(
                    (rig.position - rig.focus).length() > 2.0,
                    "camera collapsed into the skater at position={:?} up={:?} camera={:?}",
                    sim.position,
                    sim.transition.visual_up,
                    rig.position
                );
            }
        }

        assert!(saw_positive_wall);
        assert!(saw_negative_wall);
    }
}
