use std::{collections::HashMap, sync::OnceLock};

use bevy::prelude::*;
use serde::Deserialize;

use crate::sim::{ActionAnimationState, AnimationSample};

const ROOT_MOTION_JSON: &str =
    include_str!("../assets/private/default_skate3_skater.root_motion.json");

const STAND_EXIT_STEER_MAGNITUDE: f32 = 0.01;
const STAND_MINIMUM_SECONDS: f32 = 0.06;
const WALK_RUN_STEER_MAGNITUDE: f32 = 0.5;
const RETAIL_WALK_SPEED_MPS: f32 = 2.1603;
const RETAIL_RUN_SPEED_MPS: f32 = 5.9993;
const RETAIL_SPRINT_SPEED_SAMPLES: [(f32, f32); 6] = [
    (1.0, 8.94),
    (1.5, 8.59),
    (2.0, 8.23),
    (2.5, 7.90),
    (3.0, 7.55),
    (4.0, 7.08),
];
const STOP_RESTART_STEER_MAGNITUDE: f32 = 0.2;
const START_GAIT_SWITCH_SECONDS: f32 = 0.2;
const START_STOP_WILL_EXPIRE_SECONDS: f32 = 0.1;
const STOP_RESTART_WILL_EXPIRE_SECONDS: f32 = 0.5;
const DISMOUNT_WILL_EXPIRE_SECONDS: f32 = 0.1;
const MOUNT_WILL_EXPIRE_SECONDS: f32 = 0.3;
const STAND_MOUNT_HANDOFF_SECONDS: f32 = 0.55;
const RIDING_BLEND_SECONDS: f32 = 0.2;
const ACTION_BLEND_SECONDS: f32 = 0.1;
const DISMOUNT_BLEND_SECONDS: f32 = 0.2;

// `physics_state_offboard/default` stores this `TurnVsStickAngle`
// PointNegGraphData8 attribute. Retail sub_82D310F8 constructs the signed
// biped/stick angle with atan, multiplies its absolute value by 1/pi, evaluates
// this graph, then multiplies the result by that normalized angle.
const TURN_VS_STICK_ANGLE_X: [f32; 8] = [
    0.0,
    0.159_609_1,
    0.563_517_9,
    0.692_182_4,
    0.757_329,
    0.918_566_8,
    0.975_57,
    1.0,
];
const TURN_VS_STICK_ANGLE_Y: [f32; 8] = [
    1.7,
    1.36,
    1.159_643,
    0.862_857_2,
    0.611_428_6,
    0.085_714_29,
    0.0,
    0.0,
];
// The same retail physics-state collection authors the downstream
// `TurnAngleVsInput` graph. Its zero shoulder suppresses tiny angular demand,
// while the steep upper samples produce the sharp response missing in Bevy.
const TURN_ANGLE_INPUT_X: [f32; 8] = [
    0.0,
    0.232_899,
    0.319_218_2,
    0.403_908_8,
    0.527_687_3,
    0.703_583_1,
    0.884_364_8,
    1.0,
];
const TURN_ANGLE_DEGREES_Y: [f32; 8] =
    [0.0, 0.0, 2.571_429, 6.857_143, 16.571_43, 38.0, 76.0, 80.0];
// The established moving-diagonal retail fixture settles at 1.061 rad/s.
// Normalize the composed decoded curves to that independently measured point.
const MEASURED_MOVING_DIAGONAL_RATE: f32 = 1.061;
// In the paired sprint fixture, loose-right input turns 11.04 degrees while
// the previous linear response turns 17.56 degrees over the same 60 frames.
// Retain that measured low-angle response below the curve's authored shoulder.
const LOOSE_MOVING_HEADING_GAIN: f32 = MOVING_HEADING_GAIN * (11.04 / 17.56);
// The TurnAngleVsInput zero shoulder supplies a deterministic hysteresis band:
// enter at the first positive authored sample, leave only after returning to
// the last authored zero sample. This prevents gait churn around the shoulder.
const TURN_WALK_ENTER_INTENT: f32 = TURN_ANGLE_INPUT_X[2];
const TURN_WALK_EXIT_INTENT: f32 = TURN_ANGLE_INPUT_X[1];

// The offboard graph attaches the complete OB_BipedWorldX/Z trajectory to the
// skeleton; it does not pick left/right/back locomotion clips. A clean retail
// provider-1 capture settles at roughly 61.2 degrees/second for a 45-degree
// moving trajectory, which gives this heading-error gain.
const MOVING_HEADING_GAIN: f32 = 1.36;
// The stationary full-back fixture ramps by about 1.55 rad/s each 60 Hz frame,
// then plateaus at about 10.9 rad/s while the start action still has no root
// translation. These are trajectory-controller observations, not animation
// timing guesses.
const STATIONARY_HEADING_GAIN: f32 = 5.0;
const STATIONARY_MAX_YAW_RATE: f32 = 10.9;
const STATIONARY_YAW_ACCELERATION: f32 = 95.0;
const MOVING_MAX_YAW_RATE: f32 = 4.3;
const MOVING_YAW_ACCELERATION: f32 = 18.0;
// The backward fixture remains position-locked until the biped is within
// roughly forty degrees of its requested world trajectory.
const TRAJECTORY_MOVE_START_ANGLE: f32 = 0.70;
const TRAJECTORY_MOVE_FULL_ANGLE: f32 = 0.35;
const TRAJECTORY_ACQUIRE_RESPONSE: f32 = 5.0;
// Rearward camera-relative intent has a distinct acquire-then-travel shape in
// the preserved retail back-turn fixture: the root remains fixed while the
// biped turns, then the same forward gait proceeds on the acquired heading.
// Keep a rear-cone acquisition target in world space so camera follow cannot
// feed back into the trajectory and produce repeated circles.
const BACKWARD_REORIENT_INPUT_CHANGE: f32 = TRAJECTORY_MOVE_FULL_ANGLE;
// Once root translation starts, Skate's chase direction follows the biped.
// Fitting this first-order response to the three-second held-back arc gives
// approximately 1.3 inverse seconds.
const OFFBOARD_VIEW_FOLLOW_RATE: f32 = 1.30;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OffboardGait {
    Walk,
    Run,
    Sprint,
}

impl OffboardGait {
    fn cycle_clip(self) -> &'static str {
        match self {
            Self::Walk => "BR_WALK_FWD_CYC",
            Self::Run => "BR_RUN_FWD_CYC",
            Self::Sprint => "BR_SPRINT_FWD_CYC",
        }
    }

    fn start_clip(self) -> &'static str {
        match self {
            Self::Walk => "BR_STAND_0_INTO_WALK_FWD",
            Self::Run => "BR_STAND_0_INTO_RUN_FWD",
            Self::Sprint => "BR_STAND_0_INTO_SPRINT_FWD",
        }
    }

    fn cadence_prefix(self) -> &'static str {
        match self {
            Self::Walk => "BR_WALK_FWD",
            Self::Run => "BR_RUN_FWD",
            Self::Sprint => "BR_SPRINT_FWD",
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct BipedCadence {
    phase: f32,
}

impl BipedCadence {
    fn at_cycle_entry(gait: OffboardGait) -> Self {
        let phase = match gait {
            OffboardGait::Walk => 0.500000,
            OffboardGait::Run => 0.480769,
            OffboardGait::Sprint => 0.483871,
        };
        Self { phase }
    }

    fn advance(&mut self, gait: OffboardGait, distance: f32) {
        let cycle_distance = action_cycle_distance(gait.cycle_clip());
        if cycle_distance > f32::EPSILON {
            self.phase = (self.phase + distance / cycle_distance).rem_euclid(1.0);
        }
    }

    fn seek_time(self, gait: OffboardGait) -> f32 {
        self.phase * action_duration(gait.cycle_clip())
    }

    fn quarter(self) -> u8 {
        cadence_quarter_from_phase(self.phase)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DismountKind {
    Stand,
    Run,
    FastRun,
}

impl DismountKind {
    fn clip(self) -> &'static str {
        match self {
            Self::Stand => "BR_DISMOUNT_HI_INTO_STAND_0",
            Self::Run => "BR_DISMOUNT_HI_INTO_RUN_FWD",
            Self::FastRun => "BR_DISMOUNT_FAST_HI_INTO_RUN_FWD",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum MountKind {
    Stand,
    Step,
    Cadence { gait: OffboardGait, quarter: u8 },
}

impl MountKind {
    fn clip(self) -> String {
        match self {
            Self::Stand => "BR_STAND_0_INTO_MOUNT".to_owned(),
            Self::Step => "BR_STEP_INTO_MOUNT".to_owned(),
            Self::Cadence { gait, quarter } => {
                format!("{}_{}_INTO_MOUNT", gait.cadence_prefix(), quarter)
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum StopKind {
    Cadence { gait: OffboardGait, quarter: u8 },
}

impl StopKind {
    fn clip(self) -> String {
        match self {
            Self::Cadence { gait, quarter } => {
                format!("{}_{}_INTO_STAND_0", gait.cadence_prefix(), quarter)
            }
        }
    }

    fn gait(self) -> OffboardGait {
        match self {
            Self::Cadence { gait, .. } => gait,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum OffboardPhase {
    Dismount(DismountKind),
    Stand,
    Start(OffboardGait),
    Locomotion(OffboardGait),
    Stop(StopKind),
    Mount(MountKind),
}

impl OffboardPhase {
    fn clip(self) -> String {
        match self {
            Self::Dismount(kind) => kind.clip().to_owned(),
            Self::Stand => "BR_STAND_0_CYC".to_owned(),
            Self::Start(gait) => gait.start_clip().to_owned(),
            Self::Locomotion(gait) => gait.cycle_clip().to_owned(),
            Self::Stop(kind) => kind.clip(),
            Self::Mount(kind) => kind.clip(),
        }
    }

    fn loops(self) -> bool {
        matches!(self, Self::Stand | Self::Locomotion(_))
    }

    fn label(self) -> &'static str {
        match self {
            Self::Dismount(DismountKind::Stand) => "dismount to stand",
            Self::Dismount(DismountKind::Run) => "dismount to run",
            Self::Dismount(DismountKind::FastRun) => "fast dismount to run",
            Self::Stand => "offboard stand",
            Self::Start(OffboardGait::Walk) => "start walking",
            Self::Start(OffboardGait::Run) => "start running",
            Self::Start(OffboardGait::Sprint) => "start sprinting",
            Self::Locomotion(OffboardGait::Walk) => "offboard walk",
            Self::Locomotion(OffboardGait::Run) => "offboard run",
            Self::Locomotion(OffboardGait::Sprint) => "offboard sprint",
            Self::Stop(kind) => match kind.gait() {
                OffboardGait::Walk => "stop walking",
                OffboardGait::Run => "stop running",
                OffboardGait::Sprint => "stop sprinting",
            },
            Self::Mount(MountKind::Stand) => "mount from stand",
            Self::Mount(MountKind::Step) => "step onto board",
            Self::Mount(MountKind::Cadence {
                gait: OffboardGait::Walk,
                ..
            }) => "mount from walk",
            Self::Mount(MountKind::Cadence {
                gait: OffboardGait::Run,
                ..
            }) => "mount from run",
            Self::Mount(MountKind::Cadence {
                gait: OffboardGait::Sprint,
                ..
            }) => "mount from sprint",
        }
    }
}

#[derive(Clone, Debug)]
struct BlendSource {
    clip: String,
    time: f32,
    loops: bool,
    weight: f32,
}

#[derive(Clone, Debug)]
struct SourceBlend {
    sources: Vec<BlendSource>,
    elapsed: f32,
    duration: f32,
}

#[derive(Clone, Copy, Debug)]
struct BackwardReorientation {
    input_heading: f32,
    world_heading: f32,
}

#[derive(Clone, Debug)]
pub struct OffboardRuntime {
    phase: OffboardPhase,
    phase_time: f32,
    biped_cadence: Option<BipedCadence>,
    want_out_of_stand_seconds: f32,
    source_blend: Option<SourceBlend>,
    riding_blend_time: Option<f32>,
    yaw_rate: f32,
    view_yaw: f32,
    trajectory_motion_weight: f32,
    turning_walk: bool,
    sprint_endurance_seconds: f32,
    backward_reorientation: Option<BackwardReorientation>,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct OffboardControl {
    pub left_stick: Vec2,
    pub sprint_held: bool,
    pub world_yaw: f32,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct OffboardStep {
    pub local_delta: Vec3,
    pub yaw_rate: f32,
    pub view_yaw: f32,
    pub mounted: bool,
}

impl OffboardRuntime {
    pub fn begin_dismount(onboard_speed: f32, world_yaw: f32) -> Self {
        let speed = onboard_speed.abs();
        let kind = if speed < 1.0 {
            DismountKind::Stand
        } else if speed < 8.0 {
            DismountKind::Run
        } else if speed < 15.0 {
            DismountKind::FastRun
        } else {
            // The >=15 branch is observed, but no distinct exported leaf has
            // been proven. Keep the highest recovered action instead of
            // inventing another dismount animation.
            DismountKind::FastRun
        };
        Self {
            phase: OffboardPhase::Dismount(kind),
            phase_time: 0.0,
            biped_cadence: None,
            want_out_of_stand_seconds: 0.0,
            source_blend: None,
            riding_blend_time: None,
            yaw_rate: 0.0,
            view_yaw: world_yaw,
            trajectory_motion_weight: 0.0,
            turning_walk: false,
            sprint_endurance_seconds: 0.0,
            backward_reorientation: None,
        }
    }

    pub fn state_label(&self) -> &'static str {
        self.phase.label()
    }

    pub fn primary_clip(&self) -> String {
        self.phase.clip()
    }

    pub fn repeats(&self) -> bool {
        self.phase.loops()
    }

    pub fn transition_seconds(&self) -> f32 {
        if matches!(self.phase, OffboardPhase::Dismount(_)) && self.source_blend.is_none() {
            DISMOUNT_BLEND_SECONDS
        } else if self.riding_blend_time.is_some() {
            RIDING_BLEND_SECONDS
        } else {
            self.source_blend
                .as_ref()
                .map_or(ACTION_BLEND_SECONDS, |blend| blend.duration)
        }
    }

    /// Physical ownership has returned to riding while the authored mount
    /// animation is still fading out.
    pub fn riding_handoff_active(&self) -> bool {
        self.riding_blend_time.is_some()
    }

    /// The visual mount layer can be discarded after its recovered
    /// riding-transition duration has elapsed.
    pub fn riding_handoff_blend_finished(&self) -> bool {
        self.riding_blend_time
            .is_some_and(|time| time >= RIDING_BLEND_SECONDS)
    }

    pub fn request_mount(&mut self) -> bool {
        if matches!(
            self.phase,
            OffboardPhase::Dismount(_) | OffboardPhase::Mount(_)
        ) {
            return false;
        }

        let kind = match self.phase {
            OffboardPhase::Stand => MountKind::Stand,
            OffboardPhase::Locomotion(gait) => MountKind::Cadence {
                gait,
                quarter: self.biped_cadence.map_or(0, BipedCadence::quarter),
            },
            OffboardPhase::Start(gait) => MountKind::Cadence {
                gait,
                quarter: cadence_quarter(self.phase_time, action_duration(gait.start_clip())),
            },
            OffboardPhase::Stop(_) => MountKind::Step,
            OffboardPhase::Dismount(_) | OffboardPhase::Mount(_) => return false,
        };
        self.transition_to(OffboardPhase::Mount(kind), ACTION_BLEND_SECONDS, 0.0);
        true
    }

    pub fn step(&mut self, dt: f32, control: OffboardControl) -> OffboardStep {
        let current_clip = self.phase.clip();
        let old_time = self.phase_time;
        self.phase_time += dt;
        let locomotion_gait = match self.phase {
            OffboardPhase::Locomotion(gait) => Some(gait),
            _ => None,
        };
        let requested_physical_gait =
            gait_for_input(control.left_stick.length(), control.sprint_held);
        if requested_physical_gait == Some(OffboardGait::Sprint) {
            if matches!(self.phase, OffboardPhase::Locomotion(OffboardGait::Sprint)) {
                self.sprint_endurance_seconds = self.sprint_endurance_seconds.max(self.phase_time);
            } else if self.turning_walk
                && matches!(self.phase, OffboardPhase::Locomotion(OffboardGait::Walk))
            {
                self.sprint_endurance_seconds += dt;
            }
        } else {
            self.sprint_endurance_seconds = 0.0;
        }
        let translation_gait = locomotion_gait.map(|gait| requested_physical_gait.unwrap_or(gait));
        let current_delta = locomotion_gait.map_or_else(
            || action_delta(&current_clip, old_time, self.phase_time, self.phase.loops()),
            |_| {
                let gait = translation_gait.expect("locomotion must retain a physical gait");
                let elapsed = if gait == OffboardGait::Sprint {
                    self.sprint_endurance_seconds
                } else {
                    self.phase_time
                };
                Vec3::Z * retail_locomotion_speed(gait, elapsed) * dt
            },
        );

        let mut local_delta = current_delta;
        let mut blend_finished = false;
        if let Some(blend) = self.source_blend.as_mut() {
            blend.elapsed += dt;
            let mut source_delta = Vec3::ZERO;
            for source in &mut blend.sources {
                let old_source_time = source.time;
                source.time += dt;
                source_delta +=
                    action_delta(&source.clip, old_source_time, source.time, source.loops)
                        * source.weight;
            }
            let target_weight = (blend.elapsed / blend.duration).clamp(0.0, 1.0);
            local_delta = source_delta.lerp(current_delta, target_weight);
            blend_finished = blend.elapsed >= blend.duration;
        }
        if blend_finished {
            self.source_blend = None;
        }

        if let Some(riding_blend_time) = self.riding_blend_time.as_mut() {
            *riding_blend_time += dt;
        }

        let (yaw_rate, motion_weight) =
            self.step_trajectory_heading(dt, control.left_stick, control.world_yaw, local_delta);
        local_delta *= motion_weight;

        if let Some(gait) = locomotion_gait
            && let Some(cadence) = self.biped_cadence.as_mut()
        {
            let cadence_distance = if self.turning_walk && gait == OffboardGait::Walk {
                RETAIL_WALK_SPEED_MPS * dt
            } else {
                Vec2::new(local_delta.x, local_delta.z).length()
            };
            cadence.advance(gait, cadence_distance);
        }

        if self.riding_blend_time.is_none() {
            self.evaluate_motion_graph(dt, control);
        }
        let mounted = self.riding_blend_time.is_some();

        OffboardStep {
            local_delta,
            yaw_rate,
            view_yaw: self.view_yaw,
            mounted,
        }
    }

    fn step_trajectory_heading(
        &mut self,
        dt: f32,
        stick: Vec2,
        world_yaw: f32,
        local_delta: Vec3,
    ) -> (f32, f32) {
        let magnitude = stick.length();
        if magnitude <= STAND_EXIT_STEER_MAGNITUDE {
            self.yaw_rate = move_towards(self.yaw_rate, 0.0, STATIONARY_YAW_ACCELERATION * dt);
            self.view_yaw = lerp_angle(self.view_yaw, world_yaw, 1.0 - (-7.0 * dt).exp());
            self.trajectory_motion_weight = 0.0;
            self.turning_walk = false;
            self.backward_reorientation = None;
            return (self.yaw_rate, 1.0);
        }

        // OB_BipedWorldX/Z is a local desired trajectory. Skate keeps the
        // forward BR locomotion family and rotates the biped toward its world
        // heading. Negating X retains the verified controller convention:
        // right stick input produces negative Bevy yaw.
        //
        // UNRESOLVED: the exact camera-relative transform feeding this
        // trajectory has not been recovered. view_yaw remains a chase-view
        // approximation and must not be treated as exact retail behavior.
        let local_heading = if stick.y < 0.0 && stick.x.abs() <= f32::EPSILON {
            // Exactly backward is the only ambiguous 2D heading. The retail
            // fixture resolves that tie toward negative yaw.
            -std::f32::consts::PI
        } else {
            (-stick.x).atan2(stick.y)
        };
        // The exact rear-cone boundary is not named in the recovered native
        // point graphs. The directional intent itself is observed, and the
        // preserved full-back fixture proves that its target must stay fixed
        // while the camera catches up. Restrict that evidence-backed state to
        // the rear 90-degree cone; lateral/forward steering retains the
        // measured continuous moving response below.
        let requests_backward_reorientation = stick.y < 0.0 && stick.y.abs() >= stick.x.abs();
        if requests_backward_reorientation {
            self.turning_walk = false;
            let replace_target = self.backward_reorientation.is_none_or(|reorientation| {
                wrap_angle(local_heading - reorientation.input_heading).abs()
                    > BACKWARD_REORIENT_INPUT_CHANGE
            });
            if replace_target {
                self.backward_reorientation = Some(BackwardReorientation {
                    input_heading: local_heading,
                    world_heading: wrap_angle(self.view_yaw + local_heading),
                });
                self.trajectory_motion_weight = 0.0;
            }
        } else {
            self.backward_reorientation = None;
            let turn_intent = retail_turn_intent(local_heading);
            self.turning_walk = if self.turning_walk {
                turn_intent > TURN_WALK_EXIT_INTENT
            } else {
                turn_intent >= TURN_WALK_ENTER_INTENT
            };
        }
        let desired_world_yaw = self
            .backward_reorientation
            .map_or(self.view_yaw + local_heading, |state| state.world_heading);
        let heading_error = wrap_angle(desired_world_yaw - world_yaw);
        // The preserved sharp-turn fixture travels 4.91 m in 0.75 seconds;
        // forward/lateral steering therefore cannot use the rearward
        // acquisition's position lock. Only the proven rear cone gates root
        // translation while the biped rotates.
        let motion_weight = if self.backward_reorientation.is_some() {
            let alignment = inverse_smoothstep(
                heading_error.abs(),
                TRAJECTORY_MOVE_FULL_ANGLE,
                TRAJECTORY_MOVE_START_ANGLE,
            );
            if self.trajectory_motion_weight > 0.0 {
                1.0 - (1.0 - self.trajectory_motion_weight)
                    * (-TRAJECTORY_ACQUIRE_RESPONSE * dt).exp()
            } else {
                alignment
            }
        } else {
            1.0
        };
        let authored_speed = match self.phase {
            OffboardPhase::Locomotion(gait) => retail_locomotion_speed(gait, self.phase_time),
            _ => self
                .phase_gait()
                .map(|gait| action_average_speed(gait.cycle_clip()))
                .unwrap_or(0.0),
        };
        let current_speed = Vec2::new(local_delta.x, local_delta.z).length() / dt.max(f32::EPSILON);
        let moving_weight = if authored_speed > f32::EPSILON {
            (current_speed / authored_speed).clamp(0.0, 1.0) * motion_weight
        } else {
            0.0
        };
        let acceleration = STATIONARY_YAW_ACCELERATION.lerp(MOVING_YAW_ACCELERATION, moving_weight);
        let stationary_target_rate = (heading_error * STATIONARY_HEADING_GAIN)
            .clamp(-STATIONARY_MAX_YAW_RATE, STATIONARY_MAX_YAW_RATE);
        // The clean moving-diagonal capture directly measures -1.061 rad/s
        // for a -pi/4 local trajectory. Keep this measured local response
        // separate from the unresolved chase-camera transform above.
        let moving_target_rate = if self.backward_reorientation.is_some() {
            // A rearward request is an acquisition, not a sustained carve.
            // Continue converging on the captured world heading as authored
            // forward root motion comes in.
            stationary_target_rate
        } else {
            retail_moving_turn_rate(local_heading)
        };
        let target_rate = stationary_target_rate.lerp(moving_target_rate, moving_weight);
        self.yaw_rate = move_towards(self.yaw_rate, target_rate, acceleration * dt);
        self.trajectory_motion_weight = motion_weight;
        let view_response = 1.0 - (-OFFBOARD_VIEW_FOLLOW_RATE * moving_weight * dt).exp();
        self.view_yaw = lerp_angle(self.view_yaw, world_yaw, view_response);
        (self.yaw_rate, motion_weight)
    }

    fn phase_gait(&self) -> Option<OffboardGait> {
        match self.phase {
            OffboardPhase::Start(gait) | OffboardPhase::Locomotion(gait) => Some(gait),
            OffboardPhase::Stop(kind) => Some(kind.gait()),
            OffboardPhase::Dismount(_) | OffboardPhase::Stand | OffboardPhase::Mount(_) => None,
        }
    }

    pub fn animation_state(&self) -> ActionAnimationState {
        let current_clip = self.phase.clip();
        let current_seek = action_seek_time(
            &current_clip,
            self.phase_animation_time(),
            self.phase.loops(),
        );
        let (current_weight, source_samples) = if let Some(blend) = self.source_blend.as_ref() {
            let target_weight = (blend.elapsed / blend.duration).clamp(0.0, 1.0);
            (
                target_weight,
                blend
                    .sources
                    .iter()
                    .filter_map(|source| {
                        let weight = source.weight * (1.0 - target_weight);
                        (weight > f32::EPSILON).then(|| AnimationSample {
                            clip: source.clip.clone(),
                            weight,
                            seek_time_seconds: action_seek_time(
                                &source.clip,
                                source.time,
                                source.loops,
                            ),
                        })
                    })
                    .collect::<Vec<_>>(),
            )
        } else {
            (1.0, Vec::new())
        };

        let mut samples = Vec::with_capacity(source_samples.len() + 1);
        samples.extend(source_samples);
        if current_weight > f32::EPSILON {
            samples.push(AnimationSample {
                clip: current_clip,
                weight: current_weight,
                seek_time_seconds: current_seek,
            });
        }

        let weight = if let Some(time) = self.riding_blend_time {
            1.0 - (time / RIDING_BLEND_SECONDS).clamp(0.0, 1.0)
        } else if matches!(self.phase, OffboardPhase::Dismount(_)) && self.source_blend.is_none() {
            (self.phase_time / DISMOUNT_BLEND_SECONDS).clamp(0.0, 1.0)
        } else {
            1.0
        };

        ActionAnimationState { samples, weight }
    }

    fn evaluate_motion_graph(&mut self, dt: f32, control: OffboardControl) {
        // Retail offboard.xml uses OB_SteerMagnitude for stand/start/restart
        // gates. Its established locomotion leaves instead condition on the
        // physics-owned LocoState; there is no OB_SteerMagnitude condition on
        // those walk/run/sprint leaves. Keep the recovered stick-magnitude
        // gait input independent of heading so a continuous turn cannot feed
        // back into walk/run/sprint oscillation.
        let steer_magnitude = control.left_stick.length();
        let requested_gait = gait_for_input(steer_magnitude, control.sprint_held);
        let desired_gait = requested_gait.map(|gait| {
            if self.turning_walk && matches!(gait, OffboardGait::Run | OffboardGait::Sprint) {
                OffboardGait::Walk
            } else {
                gait
            }
        });
        let phase_duration = action_duration(&self.phase.clip());

        match self.phase {
            OffboardPhase::Dismount(_) => {
                if self.phase_time >= phase_duration - DISMOUNT_WILL_EXPIRE_SECONDS {
                    let destination =
                        desired_gait.map_or(OffboardPhase::Stand, OffboardPhase::Locomotion);
                    self.transition_to(destination, ACTION_BLEND_SECONDS, 0.0);
                }
            }
            OffboardPhase::Stand => {
                if steer_magnitude > STAND_EXIT_STEER_MAGNITUDE {
                    self.want_out_of_stand_seconds += dt;
                } else {
                    self.want_out_of_stand_seconds = 0.0;
                }
                if self.want_out_of_stand_seconds > STAND_MINIMUM_SECONDS {
                    if let Some(gait) = desired_gait {
                        self.transition_to(OffboardPhase::Start(gait), ACTION_BLEND_SECONDS, 0.0);
                    }
                }
            }
            OffboardPhase::Start(gait) => {
                if let Some(next_gait) = desired_gait
                    && next_gait != gait
                    && self.phase_time <= START_GAIT_SWITCH_SECONDS
                {
                    self.transition_to(OffboardPhase::Start(next_gait), ACTION_BLEND_SECONDS, 0.0);
                } else if steer_magnitude <= STAND_EXIT_STEER_MAGNITUDE {
                    // NotStand's neutral transition targets IntoStand before
                    // OutOfStand's release-to-Locomotion hook is evaluated.
                    // MatchCadence therefore selects the stop directly from
                    // the current authored start phase; exposing a one-tick
                    // locomotion cycle here caused a visible release snap.
                    let quarter = cadence_quarter(self.phase_time, phase_duration);
                    self.transition_to(
                        OffboardPhase::Stop(StopKind::Cadence { gait, quarter }),
                        ACTION_BLEND_SECONDS,
                        0.0,
                    );
                } else if self.phase_time >= phase_duration - START_STOP_WILL_EXPIRE_SECONDS {
                    self.transition_to(OffboardPhase::Locomotion(gait), ACTION_BLEND_SECONDS, 0.0);
                }
            }
            OffboardPhase::Locomotion(gait) => {
                if steer_magnitude <= STAND_EXIT_STEER_MAGNITUDE {
                    let quarter = self.biped_cadence.map_or(0, BipedCadence::quarter);
                    self.transition_to(
                        OffboardPhase::Stop(StopKind::Cadence { gait, quarter }),
                        ACTION_BLEND_SECONDS,
                        0.0,
                    );
                } else if let Some(next_gait) = desired_gait
                    && next_gait != gait
                {
                    self.transition_to(
                        OffboardPhase::Locomotion(next_gait),
                        RIDING_BLEND_SECONDS,
                        0.0,
                    );
                }
            }
            OffboardPhase::Stop(_) => {
                if steer_magnitude > STOP_RESTART_STEER_MAGNITUDE {
                    if let Some(gait) = desired_gait {
                        if self.phase_time >= phase_duration - STOP_RESTART_WILL_EXPIRE_SECONDS {
                            // IntoStand's first transition wins in the final
                            // 0.5 seconds and routes through authored
                            // OutOfStand.
                            self.transition_to(
                                OffboardPhase::Start(gait),
                                ACTION_BLEND_SECONDS,
                                0.0,
                            );
                        } else {
                            // Before that window, the following Locomotion
                            // transition's OB_SteerMagnitude > 0.2 condition
                            // is already true. Retail therefore resumes the
                            // cadence cycle immediately instead of waiting
                            // through the stop action.
                            self.transition_to(
                                OffboardPhase::Locomotion(gait),
                                RIDING_BLEND_SECONDS,
                                0.0,
                            );
                        }
                    }
                } else if self.phase_time >= phase_duration {
                    // IntoStand's WillExpire gate is 0.0. The authored
                    // cadence stop therefore reaches its true end before the
                    // stand cycle enters with stand.xml's 0.2-second blend.
                    self.transition_to(OffboardPhase::Stand, RIDING_BLEND_SECONDS, 0.0);
                }
            }
            OffboardPhase::Mount(kind) => {
                let handoff_seconds = match kind {
                    MountKind::Stand => STAND_MOUNT_HANDOFF_SECONDS,
                    MountKind::Step | MountKind::Cadence { .. } => {
                        phase_duration - MOUNT_WILL_EXPIRE_SECONDS
                    }
                };
                if self.riding_blend_time.is_none() && self.phase_time >= handoff_seconds {
                    self.riding_blend_time = Some(0.0);
                }
            }
        }
    }

    fn transition_to(&mut self, destination: OffboardPhase, duration: f32, destination_time: f32) {
        let source_phase = self.phase;
        let source_cadence = self.biped_cadence;
        let sources = self.current_animation_sources();
        let source = SourceBlend {
            sources,
            elapsed: 0.0,
            duration,
        };
        self.phase = destination;
        self.phase_time = destination_time;
        self.biped_cadence = match destination {
            OffboardPhase::Locomotion(gait) => {
                match source_phase {
                    OffboardPhase::Locomotion(_) => {
                        source_cadence.or_else(|| Some(BipedCadence::at_cycle_entry(gait)))
                    }
                    OffboardPhase::Stop(StopKind::Cadence { quarter, .. }) => {
                        // IntoStand owns MatchCadence, so an interrupted stop
                        // rejoins the cycle at its authored cadence quarter.
                        Some(BipedCadence {
                            phase: f32::from(quarter) / 100.0,
                        })
                    }
                    _ => Some(BipedCadence::at_cycle_entry(gait)),
                }
            }
            _ => None,
        };
        self.want_out_of_stand_seconds = 0.0;
        self.source_blend = Some(source);
        self.riding_blend_time = None;
    }

    fn current_animation_sources(&self) -> Vec<BlendSource> {
        let current = BlendSource {
            clip: self.phase.clip(),
            time: self.phase_animation_time(),
            loops: self.phase.loops(),
            weight: 1.0,
        };
        let Some(blend) = self.source_blend.as_ref() else {
            return vec![current];
        };

        let target_weight = (blend.elapsed / blend.duration).clamp(0.0, 1.0);
        let source_weight = 1.0 - target_weight;
        let mut sources = Vec::with_capacity(blend.sources.len() + 1);
        sources.extend(blend.sources.iter().filter_map(|source| {
            let weight = source.weight * source_weight;
            (weight > f32::EPSILON).then(|| BlendSource {
                clip: source.clip.clone(),
                time: source.time,
                loops: source.loops,
                weight,
            })
        }));
        if target_weight > f32::EPSILON {
            sources.push(BlendSource {
                weight: target_weight,
                ..current
            });
        }
        sources
    }

    fn phase_animation_time(&self) -> f32 {
        match (self.phase, self.biped_cadence) {
            (OffboardPhase::Locomotion(gait), Some(cadence)) => cadence.seek_time(gait),
            _ => self.phase_time,
        }
    }
}

fn gait_for_input(steer_magnitude: f32, sprint_held: bool) -> Option<OffboardGait> {
    if steer_magnitude <= STAND_EXIT_STEER_MAGNITUDE {
        None
    } else if steer_magnitude <= WALK_RUN_STEER_MAGNITUDE {
        Some(OffboardGait::Walk)
    } else if sprint_held {
        Some(OffboardGait::Sprint)
    } else {
        Some(OffboardGait::Run)
    }
}

fn point_graph_8(value: f32, xs: &[f32; 8], ys: &[f32; 8]) -> f32 {
    if value <= xs[0] {
        return ys[0];
    }
    for index in 1..xs.len() {
        if value <= xs[index] {
            let interval = xs[index] - xs[index - 1];
            let weight = if interval.abs() <= f32::EPSILON {
                0.0
            } else {
                (value - xs[index - 1]) / interval
            };
            return ys[index - 1] + (ys[index] - ys[index - 1]) * weight;
        }
    }
    ys[ys.len() - 1]
}

fn normalized_turn_angle(local_heading: f32) -> f32 {
    wrap_angle(local_heading).abs() / std::f32::consts::PI
}

fn retail_turn_intent(local_heading: f32) -> f32 {
    let angle = normalized_turn_angle(local_heading);
    angle * point_graph_8(angle, &TURN_VS_STICK_ANGLE_X, &TURN_VS_STICK_ANGLE_Y)
}

fn retail_turn_angle_degrees(local_heading: f32) -> f32 {
    point_graph_8(
        retail_turn_intent(local_heading),
        &TURN_ANGLE_INPUT_X,
        &TURN_ANGLE_DEGREES_Y,
    )
}

fn retail_moving_turn_rate(local_heading: f32) -> f32 {
    let absolute_heading = local_heading.abs();
    let diagonal_response = retail_turn_angle_degrees(std::f32::consts::FRAC_PI_4);
    let graphed_rate = retail_turn_angle_degrees(local_heading)
        * (MEASURED_MOVING_DIAGONAL_RATE / diagonal_response);
    let loose_rate = absolute_heading * LOOSE_MOVING_HEADING_GAIN;
    local_heading.signum() * loose_rate.max(graphed_rate).min(MOVING_MAX_YAW_RATE)
}

fn retail_locomotion_speed(gait: OffboardGait, elapsed_seconds: f32) -> f32 {
    match gait {
        OffboardGait::Walk => RETAIL_WALK_SPEED_MPS,
        OffboardGait::Run => RETAIL_RUN_SPEED_MPS,
        OffboardGait::Sprint => retail_sprint_speed(elapsed_seconds),
    }
}

fn retail_sprint_speed(elapsed_seconds: f32) -> f32 {
    if elapsed_seconds <= RETAIL_SPRINT_SPEED_SAMPLES[0].0 {
        return RETAIL_SPRINT_SPEED_SAMPLES[0].1;
    }

    for samples in RETAIL_SPRINT_SPEED_SAMPLES.windows(2) {
        let (start_time, start_speed) = samples[0];
        let (end_time, end_speed) = samples[1];
        if elapsed_seconds <= end_time {
            let weight = (elapsed_seconds - start_time) / (end_time - start_time);
            return start_speed + (end_speed - start_speed) * weight;
        }
    }

    RETAIL_SPRINT_SPEED_SAMPLES
        .last()
        .map_or(0.0, |(_, speed)| *speed)
}

fn normalized_cycle_phase(time: f32, duration: f32) -> f32 {
    if duration <= f32::EPSILON {
        0.0
    } else {
        time.rem_euclid(duration) / duration
    }
}

fn cadence_quarter(time: f32, duration: f32) -> u8 {
    cadence_quarter_from_phase(normalized_cycle_phase(time, duration))
}

fn cadence_quarter_from_phase(phase: f32) -> u8 {
    let quarter = (phase.rem_euclid(1.0) * 4.0).round() as i32 % 4;
    match quarter {
        0 => 0,
        1 => 25,
        2 => 50,
        _ => 75,
    }
}

#[derive(Debug, Deserialize)]
struct RootMotionDocument {
    actions: HashMap<String, RootMotionAction>,
}

#[derive(Debug, Deserialize)]
struct RootMotionAction {
    frame_start: i32,
    frame_end: i32,
    sample_rate_hz: f32,
    samples: Vec<RootMotionSample>,
}

impl RootMotionAction {
    fn duration(&self) -> f32 {
        (self.frame_end - self.frame_start).max(0) as f32 / self.sample_rate_hz
    }

    fn position_at(&self, time: f32) -> Vec3 {
        if self.samples.is_empty() {
            return Vec3::ZERO;
        }
        let sample_position = (time.clamp(0.0, self.duration()) * self.sample_rate_hz)
            .clamp(0.0, (self.samples.len() - 1) as f32);
        let lower = sample_position.floor() as usize;
        let upper = (lower + 1).min(self.samples.len() - 1);
        let blend = sample_position - lower as f32;
        Vec3::from_array(self.samples[lower].delta_bevy)
            .lerp(Vec3::from_array(self.samples[upper].delta_bevy), blend)
    }

    fn absolute_loop_position(&self, time: f32) -> Vec3 {
        let duration = self.duration();
        if duration <= f32::EPSILON {
            return Vec3::ZERO;
        }
        let loops = (time / duration).floor();
        let remainder = time.rem_euclid(duration);
        self.position_at(duration) * loops + self.position_at(remainder)
    }
}

#[derive(Debug, Deserialize)]
struct RootMotionSample {
    #[allow(dead_code)]
    frame: i32,
    delta_bevy: [f32; 3],
}

fn root_motion() -> &'static RootMotionDocument {
    static DOCUMENT: OnceLock<RootMotionDocument> = OnceLock::new();
    DOCUMENT.get_or_init(|| {
        serde_json::from_str(ROOT_MOTION_JSON)
            .expect("private Skate 3 root-motion sidecar must be valid")
    })
}

fn root_action(clip: &str) -> &'static RootMotionAction {
    root_motion()
        .actions
        .get(clip)
        .unwrap_or_else(|| panic!("root motion is missing exported action {clip}"))
}

fn action_duration(clip: &str) -> f32 {
    root_action(clip).duration()
}

fn action_average_speed(clip: &str) -> f32 {
    let action = root_action(clip);
    let duration = action.duration();
    if duration <= f32::EPSILON {
        0.0
    } else {
        let delta = action.position_at(duration);
        Vec2::new(delta.x, delta.z).length() / duration
    }
}

fn action_cycle_distance(clip: &str) -> f32 {
    let action = root_action(clip);
    let delta = action.position_at(action.duration());
    Vec2::new(delta.x, delta.z).length()
}

fn move_towards(current: f32, target: f32, maximum_delta: f32) -> f32 {
    let delta = target - current;
    if delta.abs() <= maximum_delta {
        target
    } else {
        current + delta.signum() * maximum_delta
    }
}

fn wrap_angle(angle: f32) -> f32 {
    (angle + std::f32::consts::PI).rem_euclid(std::f32::consts::TAU) - std::f32::consts::PI
}

fn lerp_angle(current: f32, target: f32, weight: f32) -> f32 {
    current + wrap_angle(target - current) * weight.clamp(0.0, 1.0)
}

fn inverse_smoothstep(value: f32, full_below: f32, zero_above: f32) -> f32 {
    let linear = ((zero_above - value) / (zero_above - full_below)).clamp(0.0, 1.0);
    linear * linear * (3.0 - 2.0 * linear)
}

fn action_seek_time(clip: &str, time: f32, loops: bool) -> f32 {
    let duration = action_duration(clip);
    if loops && duration > f32::EPSILON {
        time.rem_euclid(duration)
    } else {
        time.clamp(0.0, duration)
    }
}

fn action_delta(clip: &str, old_time: f32, new_time: f32, loops: bool) -> Vec3 {
    let action = root_action(clip);
    if matches!(clip, "BR_STAND_0_CYC") {
        return Vec3::ZERO;
    }
    if loops {
        action.absolute_loop_position(new_time) - action.absolute_loop_position(old_time)
    } else {
        action.position_at(new_time) - action.position_at(old_time)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DT: f32 = 1.0 / 120.0;

    fn runtime_in_phase(phase: OffboardPhase) -> OffboardRuntime {
        let biped_cadence = match phase {
            OffboardPhase::Locomotion(gait) => Some(BipedCadence::at_cycle_entry(gait)),
            _ => None,
        };
        OffboardRuntime {
            phase,
            phase_time: 0.0,
            biped_cadence,
            want_out_of_stand_seconds: 0.0,
            source_blend: None,
            riding_blend_time: None,
            yaw_rate: 0.0,
            view_yaw: 0.0,
            trajectory_motion_weight: 0.0,
            turning_walk: false,
            sprint_endurance_seconds: 0.0,
            backward_reorientation: None,
        }
    }

    #[test]
    fn exported_cycles_retain_their_authored_stride_lengths() {
        let walk = root_action("BR_WALK_FWD_CYC");
        let run = root_action("BR_RUN_FWD_CYC");
        let sprint = root_action("BR_SPRINT_FWD_CYC");
        let speed =
            |action: &RootMotionAction| action.position_at(action.duration()).z / action.duration();
        assert!((speed(walk) - 1.68).abs() < 0.03);
        assert!((speed(run) - 5.35).abs() < 0.03);
        assert!((speed(sprint) - 9.08).abs() < 0.04);
    }

    #[test]
    fn dismount_speed_thresholds_select_the_recovered_hi_actions() {
        assert_eq!(
            OffboardRuntime::begin_dismount(0.99, 0.0).primary_clip(),
            "BR_DISMOUNT_HI_INTO_STAND_0"
        );
        assert_eq!(
            OffboardRuntime::begin_dismount(1.0, 0.0).primary_clip(),
            "BR_DISMOUNT_HI_INTO_RUN_FWD"
        );
        assert_eq!(
            OffboardRuntime::begin_dismount(7.999, 0.0).primary_clip(),
            "BR_DISMOUNT_HI_INTO_RUN_FWD"
        );
        for speed in [8.0, 14.999, 15.0, 30.0] {
            assert_eq!(
                OffboardRuntime::begin_dismount(speed, 0.0).primary_clip(),
                "BR_DISMOUNT_FAST_HI_INTO_RUN_FWD"
            );
        }
        assert_eq!(
            OffboardRuntime::begin_dismount(-15.0, 0.0).primary_clip(),
            "BR_DISMOUNT_FAST_HI_INTO_RUN_FWD"
        );
    }

    #[test]
    fn stand_walk_run_and_sprint_follow_retail_input_thresholds() {
        assert_eq!(gait_for_input(0.01, false), None);
        assert_eq!(gait_for_input(0.011, false), Some(OffboardGait::Walk));
        assert_eq!(gait_for_input(0.5, true), Some(OffboardGait::Walk));
        assert_eq!(gait_for_input(0.501, false), Some(OffboardGait::Run));
        assert_eq!(gait_for_input(0.501, true), Some(OffboardGait::Sprint));
    }

    #[test]
    fn held_forward_reaches_a_root_motion_run_cycle() {
        let mut runtime = OffboardRuntime::begin_dismount(0.0, 0.0);
        let control = OffboardControl {
            left_stick: Vec2::Y,
            sprint_held: false,
            world_yaw: 0.0,
        };
        for _ in 0..600 {
            runtime.step(DT, control);
            if runtime.phase == OffboardPhase::Locomotion(OffboardGait::Run)
                && runtime.source_blend.is_none()
            {
                return;
            }
        }
        panic!("dismount never reached the run cycle");
    }

    #[test]
    fn want_out_of_stand_accumulates_while_held_and_resets_on_release() {
        let mut runtime = runtime_in_phase(OffboardPhase::Stand);
        let held = OffboardControl {
            left_stick: Vec2::Y,
            ..default()
        };

        for _ in 0..3 {
            runtime.step(0.02, held);
        }
        assert_eq!(runtime.phase, OffboardPhase::Stand);
        assert!((runtime.want_out_of_stand_seconds - 0.06).abs() < 0.0001);

        runtime.step(0.01, OffboardControl::default());
        assert_eq!(runtime.want_out_of_stand_seconds, 0.0);

        for _ in 0..3 {
            runtime.step(0.02, held);
        }
        assert_eq!(runtime.phase, OffboardPhase::Stand);
        runtime.step(0.02, held);
        assert_eq!(runtime.phase, OffboardPhase::Start(OffboardGait::Run));
    }

    #[test]
    fn forward_cycles_enter_at_the_measured_biped_cadence_phases() {
        let cases = [
            (
                OffboardGait::Walk,
                OffboardControl {
                    left_stick: Vec2::Y * 0.5,
                    ..default()
                },
                0.500000,
            ),
            (
                OffboardGait::Run,
                OffboardControl {
                    left_stick: Vec2::Y,
                    ..default()
                },
                0.480769,
            ),
            (
                OffboardGait::Sprint,
                OffboardControl {
                    left_stick: Vec2::Y,
                    sprint_held: true,
                    ..default()
                },
                0.483871,
            ),
        ];

        for (gait, control, expected_phase) in cases {
            let mut runtime = runtime_in_phase(OffboardPhase::Start(gait));
            runtime.phase_time =
                action_duration(gait.start_clip()) - START_STOP_WILL_EXPIRE_SECONDS - DT * 0.5;
            runtime.step(DT, control);
            assert_eq!(runtime.phase, OffboardPhase::Locomotion(gait));
            let cadence = runtime
                .biped_cadence
                .expect("locomotion must own a cadence controller");
            assert!((cadence.phase - expected_phase).abs() < 0.000001);

            let normalized_seek =
                runtime.phase_animation_time() / action_duration(gait.cycle_clip());
            assert!((normalized_seek - expected_phase).abs() < 0.000001);
        }
    }

    #[test]
    fn flat_walk_and_run_use_retail_speed_and_distance_driven_cadence() {
        for (gait, expected_speed) in [
            (OffboardGait::Walk, RETAIL_WALK_SPEED_MPS),
            (OffboardGait::Run, RETAIL_RUN_SPEED_MPS),
        ] {
            let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(gait));
            let initial_phase = runtime.biped_cadence.unwrap().phase;
            let control = OffboardControl {
                left_stick: if gait == OffboardGait::Walk {
                    Vec2::Y * 0.5
                } else {
                    Vec2::Y
                },
                ..default()
            };
            let mut distance = 0.0;
            for _ in 0..120 {
                distance += runtime.step(DT, control).local_delta.z;
            }

            assert!((distance - expected_speed).abs() < 0.0002);
            let expected_phase = (initial_phase
                + expected_speed / action_cycle_distance(gait.cycle_clip()))
            .rem_euclid(1.0);
            let cadence = runtime.biped_cadence.unwrap();
            assert!((cadence.phase - expected_phase).abs() < 0.0002);
        }
    }

    #[test]
    fn sprint_endurance_uses_the_measured_speed_table() {
        for (elapsed_seconds, expected_speed) in RETAIL_SPRINT_SPEED_SAMPLES {
            assert!(
                (retail_locomotion_speed(OffboardGait::Sprint, elapsed_seconds) - expected_speed)
                    .abs()
                    < 0.00001
            );
        }
        assert_eq!(retail_locomotion_speed(OffboardGait::Sprint, 10.0), 7.08);
    }

    #[test]
    fn stand_mount_hands_ownership_over_on_retail_frame_33_to_35() {
        let mut runtime = runtime_in_phase(OffboardPhase::Stand);
        assert!(runtime.request_mount());
        assert_eq!(runtime.primary_clip(), "BR_STAND_0_INTO_MOUNT");
        let mut handoff_frame = None;
        for frame in 1..=120 {
            if runtime.step(DT, OffboardControl::default()).mounted {
                handoff_frame = Some(frame);
                break;
            }
        }
        let handoff_frame = handoff_frame.expect("stand mount never handed ownership to riding");
        assert!((66..=70).contains(&handoff_frame));
        assert!(runtime.animation_state().weight > 0.0);

        let mut runtime_60_hz = runtime_in_phase(OffboardPhase::Stand);
        assert!(runtime_60_hz.request_mount());
        let frame_60_hz = (1..=60)
            .find(|_| {
                runtime_60_hz
                    .step(1.0 / 60.0, OffboardControl::default())
                    .mounted
            })
            .expect("60 Hz stand mount never handed ownership to riding");
        assert!((33..=35).contains(&frame_60_hz));
    }

    #[test]
    fn mount_handoff_remains_as_a_visual_layer_until_riding_blend_finishes() {
        let mut runtime = runtime_in_phase(OffboardPhase::Stand);
        assert!(runtime.request_mount());
        for _ in 0..240 {
            runtime.step(DT, OffboardControl::default());
            if runtime.riding_handoff_active() {
                break;
            }
        }
        assert!(runtime.riding_handoff_active());
        assert!(!runtime.riding_handoff_blend_finished());

        for _ in 0..23 {
            runtime.step(DT, OffboardControl::default());
        }
        assert!(!runtime.riding_handoff_blend_finished());
        runtime.step(DT, OffboardControl::default());
        assert!(runtime.riding_handoff_blend_finished());
        assert_eq!(runtime.animation_state().weight, 0.0);
    }

    #[test]
    fn loop_delta_is_continuous_across_the_authored_cycle_boundary() {
        let clip = "BR_RUN_FWD_CYC";
        let duration = action_duration(clip);
        let delta = action_delta(clip, duration - DT, duration + DT, true);
        assert!(delta.z > 0.04);
        assert!(delta.z < 0.15);
    }

    #[test]
    fn every_gait_release_enters_its_authored_cadence_stop_and_point_one_blend() {
        let cases = [
            (OffboardGait::Walk, 0.10, 0),
            (OffboardGait::Walk, 0.30, 25),
            (OffboardGait::Run, 0.60, 50),
            (OffboardGait::Sprint, 0.80, 75),
        ];

        for (gait, cadence_phase, expected_quarter) in cases {
            let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(gait));
            runtime.biped_cadence = Some(BipedCadence {
                phase: cadence_phase,
            });
            runtime.step(DT, OffboardControl::default());

            assert_eq!(
                runtime.primary_clip(),
                format!(
                    "{}_{}_INTO_STAND_0",
                    gait.cadence_prefix(),
                    expected_quarter
                )
            );
            assert_eq!(runtime.transition_seconds(), ACTION_BLEND_SECONDS);
            let source = runtime
                .source_blend
                .as_ref()
                .expect("release must blend from the cadence-owned cycle");
            assert_eq!(source.sources.len(), 1);
            assert_eq!(source.sources[0].clip, gait.cycle_clip());
            assert!(
                source.sources[0].time > 0.0,
                "the source cycle must retain its cadence seek"
            );

            runtime.step(ACTION_BLEND_SECONDS * 0.5, OffboardControl::default());
            let animation = runtime.animation_state();
            assert_eq!(animation.samples.len(), 2);
            assert!((animation.samples[0].weight - 0.5).abs() < 1.0e-5);
            assert!((animation.samples[1].weight - 0.5).abs() < 1.0e-5);
        }
    }

    #[test]
    fn release_during_authored_start_goes_directly_to_into_stand() {
        for gait in [OffboardGait::Walk, OffboardGait::Run, OffboardGait::Sprint] {
            let mut runtime = runtime_in_phase(OffboardPhase::Start(gait));
            runtime.phase_time = action_duration(gait.start_clip()) * 0.42;
            runtime.step(DT, OffboardControl::default());

            assert!(matches!(runtime.phase, OffboardPhase::Stop(_)));
            assert!(runtime.primary_clip().contains("_INTO_STAND_0"));
            let source = runtime
                .source_blend
                .as_ref()
                .expect("start release must retain the authored start pose");
            assert_eq!(source.sources.len(), 1);
            assert_eq!(source.sources[0].clip, gait.start_clip());
            assert_eq!(source.duration, ACTION_BLEND_SECONDS);
        }
    }

    #[test]
    fn authored_stop_reaches_true_expiry_then_uses_stands_point_two_blend() {
        for gait in [OffboardGait::Walk, OffboardGait::Run, OffboardGait::Sprint] {
            let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(gait));
            runtime.step(DT, OffboardControl::default());
            let stop_clip = runtime.primary_clip();
            let stop_duration = action_duration(&stop_clip);
            runtime.source_blend = None;
            runtime.phase_time = stop_duration - DT * 1.5;

            runtime.step(DT, OffboardControl::default());
            assert!(
                matches!(runtime.phase, OffboardPhase::Stop(_)),
                "{stop_clip} left before authored expiry"
            );
            runtime.step(DT, OffboardControl::default());
            assert_eq!(runtime.phase, OffboardPhase::Stand);
            assert_eq!(runtime.transition_seconds(), RIDING_BLEND_SECONDS);
            let source = runtime
                .source_blend
                .as_ref()
                .expect("stand entry must retain the completed stop");
            assert_eq!(source.sources.len(), 1);
            assert_eq!(source.sources[0].clip, stop_clip);
            assert!((source.sources[0].time - stop_duration).abs() <= DT);
        }
    }

    #[test]
    fn strong_stop_restart_follows_retail_transition_order_without_dead_time() {
        let restart = OffboardControl {
            left_stick: Vec2::Y,
            ..default()
        };

        let mut early = runtime_in_phase(OffboardPhase::Stop(StopKind::Cadence {
            gait: OffboardGait::Run,
            quarter: 25,
        }));
        early.phase_time = 0.1;
        early.step(DT, restart);
        assert_eq!(early.phase, OffboardPhase::Locomotion(OffboardGait::Run));
        assert_eq!(early.transition_seconds(), RIDING_BLEND_SECONDS);
        assert!((early.biped_cadence.expect("restart lost cadence").phase - 0.25).abs() < 1.0e-6);
        let early_sources = &early
            .source_blend
            .as_ref()
            .expect("restart must retain the interrupted stop")
            .sources;
        assert_eq!(early_sources.len(), 1);
        assert_eq!(early_sources[0].clip, "BR_RUN_FWD_25_INTO_STAND_0");

        let mut late = runtime_in_phase(OffboardPhase::Stop(StopKind::Cadence {
            gait: OffboardGait::Run,
            quarter: 25,
        }));
        late.phase_time =
            action_duration(&late.primary_clip()) - STOP_RESTART_WILL_EXPIRE_SECONDS - DT * 0.5;
        late.step(DT, restart);
        assert_eq!(late.phase, OffboardPhase::Start(OffboardGait::Run));
        assert_eq!(late.transition_seconds(), ACTION_BLEND_SECONDS);

        let mut weak = runtime_in_phase(OffboardPhase::Stop(StopKind::Cadence {
            gait: OffboardGait::Run,
            quarter: 0,
        }));
        weak.phase_time =
            action_duration(&weak.primary_clip()) - STOP_RESTART_WILL_EXPIRE_SECONDS + DT;
        weak.step(
            DT,
            OffboardControl {
                left_stick: Vec2::Y * STOP_RESTART_STEER_MAGNITUDE,
                ..default()
            },
        );
        assert!(matches!(weak.phase, OffboardPhase::Stop(_)));
    }

    #[test]
    fn one_tick_release_and_restart_keeps_translation_continuous() {
        let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(OffboardGait::Run));
        runtime.phase_time = 1.0;
        runtime.biped_cadence = Some(BipedCadence { phase: 0.25 });

        let released = runtime.step(DT, OffboardControl::default());
        assert!(matches!(runtime.phase, OffboardPhase::Stop(_)));
        let restarted = runtime.step(
            DT,
            OffboardControl {
                left_stick: Vec2::Y,
                ..default()
            },
        );
        assert_eq!(runtime.phase, OffboardPhase::Locomotion(OffboardGait::Run));
        assert!(released.local_delta.z > 0.03);
        assert!(restarted.local_delta.z > 0.03);
        let interrupted_pose = runtime.animation_state();
        assert_eq!(interrupted_pose.samples.len(), 2);
        assert!(
            interrupted_pose
                .samples
                .iter()
                .any(|sample| sample.clip == "BR_RUN_FWD_CYC")
        );
        assert!(
            interrupted_pose
                .samples
                .iter()
                .any(|sample| sample.clip == "BR_RUN_FWD_25_INTO_STAND_0")
        );
        assert!(
            (interrupted_pose
                .samples
                .iter()
                .map(|sample| sample.weight)
                .sum::<f32>()
                - 1.0)
                .abs()
                < 1.0e-6
        );

        let mut previous_speed = restarted.local_delta.z / DT;
        for _ in 0..24 {
            let step = runtime.step(
                DT,
                OffboardControl {
                    left_stick: Vec2::Y,
                    ..default()
                },
            );
            let speed = step.local_delta.z / DT;
            assert!(speed > 0.5, "restart introduced a dead frame");
            assert!(
                (speed - previous_speed).abs() < 0.8,
                "restart speed jolted from {previous_speed} to {speed}"
            );
            previous_speed = speed;
        }
        assert!(runtime.source_blend.is_none());
    }

    #[test]
    fn stationary_back_trajectory_matches_the_measured_eight_frame_turn_ramp() {
        let mut runtime = runtime_in_phase(OffboardPhase::Stand);
        let mut yaw = 0.0;
        let mut translated = Vec3::ZERO;
        let expected_yaw = [
            -0.02178367,
            -0.06767300,
            -0.13984492,
            -0.23860674,
            -0.36288502,
            -0.51346126,
            -0.69226802,
            -0.87463365,
        ];
        for expected in expected_yaw {
            for _ in 0..2 {
                let step = runtime.step(
                    DT,
                    OffboardControl {
                        left_stick: -Vec2::Y,
                        sprint_held: false,
                        world_yaw: yaw,
                    },
                );
                yaw += step.yaw_rate * DT;
                translated += step.local_delta;
            }
            assert!(
                (yaw - expected).abs() < 0.04,
                "yaw={yaw}, retail={expected}"
            );
        }

        assert!((-11.0..-10.8).contains(&runtime.yaw_rate));
        assert!(translated.length() < 0.001);
    }

    #[test]
    fn moving_diagonal_trajectory_reproduces_the_retail_turn_rate() {
        let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(OffboardGait::Run));
        runtime.phase_time = 1.0;
        let run_speed = RETAIL_RUN_SPEED_MPS;
        let local_delta = Vec3::Z * run_speed * DT;
        let mut world_yaw = 0.0;
        for _ in 0..1200 {
            let (yaw_rate, _) = runtime.step_trajectory_heading(
                DT,
                Vec2::new(
                    std::f32::consts::FRAC_1_SQRT_2,
                    std::f32::consts::FRAC_1_SQRT_2,
                ),
                world_yaw,
                local_delta,
            );
            world_yaw += yaw_rate * DT;
        }

        assert!(
            (runtime.yaw_rate - -1.061).abs() <= 0.04,
            "yaw_rate={}",
            runtime.yaw_rate
        );
    }

    #[test]
    fn decoded_turn_vs_stick_angle_samples_are_preserved_exactly() {
        for (x, expected) in TURN_VS_STICK_ANGLE_X.iter().zip(TURN_VS_STICK_ANGLE_Y) {
            assert!(
                (point_graph_8(*x, &TURN_VS_STICK_ANGLE_X, &TURN_VS_STICK_ANGLE_Y,) - expected)
                    .abs()
                    <= f32::EPSILON
            );
        }
    }

    #[test]
    fn retail_turn_intent_uses_the_native_atan_over_pi_domain() {
        assert_eq!(normalized_turn_angle(0.0), 0.0);
        assert!((normalized_turn_angle(std::f32::consts::FRAC_PI_2) - 0.5).abs() < 1.0e-6);
        assert!((normalized_turn_angle(-std::f32::consts::PI) - 1.0).abs() < 1.0e-6);

        let diagonal_angle = 0.25;
        let expected = diagonal_angle
            * point_graph_8(
                diagonal_angle,
                &TURN_VS_STICK_ANGLE_X,
                &TURN_VS_STICK_ANGLE_Y,
            );
        assert!((retail_turn_intent(std::f32::consts::FRAC_PI_4) - expected).abs() < 1.0e-6);
    }

    #[test]
    fn loose_turn_retains_established_run_or_sprint_without_restarting_blends() {
        for gait in [OffboardGait::Run, OffboardGait::Sprint] {
            let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(gait));
            runtime.phase_time = 1.0;
            runtime.biped_cadence = Some(BipedCadence { phase: 0.73 });
            let mut yaw = 0.0;

            for _ in 0..180 {
                let heading = 30.0_f32.to_radians();
                let step = runtime.step(
                    DT,
                    OffboardControl {
                        left_stick: Vec2::new(heading.sin(), heading.cos()),
                        sprint_held: gait == OffboardGait::Sprint,
                        world_yaw: yaw,
                    },
                );
                yaw += step.yaw_rate * DT;

                assert_eq!(runtime.phase, OffboardPhase::Locomotion(gait));
                assert_eq!(runtime.primary_clip(), gait.cycle_clip());
                assert!(
                    runtime.source_blend.is_none(),
                    "loose steering retriggered a locomotion blend"
                );
            }

            assert!(
                runtime.biped_cadence.expect("turn lost cadence").phase != 0.73,
                "held locomotion did not advance cadence"
            );
        }
    }

    #[test]
    fn hard_turn_walk_is_persistent_and_rapid_reversal_does_not_restart_its_blend() {
        for gait in [OffboardGait::Run, OffboardGait::Sprint] {
            let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(gait));
            runtime.phase_time = 1.0;
            runtime.biped_cadence = Some(BipedCadence { phase: 0.73 });
            let mut yaw = 0.0;
            let mut distance = 0.0;

            for tick in 0..120 {
                let stick = if tick % 2 == 0 { Vec2::X } else { -Vec2::X };
                let step = runtime.step(
                    DT,
                    OffboardControl {
                        left_stick: stick,
                        sprint_held: gait == OffboardGait::Sprint,
                        world_yaw: yaw,
                    },
                );
                yaw += step.yaw_rate * DT;
                distance += step.local_delta.length();
                assert_eq!(runtime.phase, OffboardPhase::Locomotion(OffboardGait::Walk));
                if tick > (RIDING_BLEND_SECONDS / DT).ceil() as usize {
                    assert!(
                        runtime.source_blend.is_none(),
                        "lateral reversal restarted the gait blend"
                    );
                }
            }

            assert!(
                distance > RETAIL_WALK_SPEED_MPS,
                "hard-turn locomotion collapsed to an in-place walk"
            );
            assert!(runtime.turning_walk);
        }
    }

    #[test]
    fn hard_turn_walk_exits_at_the_zero_shoulder_and_preserves_sprint_endurance() {
        let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(OffboardGait::Sprint));
        runtime.phase_time = 2.5;
        runtime.sprint_endurance_seconds = 2.5;
        let mut yaw = 0.0;

        for _ in 0..60 {
            let step = runtime.step(
                DT,
                OffboardControl {
                    left_stick: Vec2::X,
                    sprint_held: true,
                    world_yaw: yaw,
                },
            );
            yaw += step.yaw_rate * DT;
        }
        assert_eq!(runtime.phase, OffboardPhase::Locomotion(OffboardGait::Walk));
        let endurance_after_turn = runtime.sprint_endurance_seconds;
        assert!(endurance_after_turn > 2.9);

        let aligned = Vec2::new(30.0_f32.to_radians().sin(), 30.0_f32.to_radians().cos());
        runtime.step(
            DT,
            OffboardControl {
                left_stick: aligned,
                sprint_held: true,
                world_yaw: yaw,
            },
        );
        assert_eq!(
            runtime.phase,
            OffboardPhase::Locomotion(OffboardGait::Sprint)
        );
        assert!(
            runtime.sprint_endurance_seconds >= endurance_after_turn,
            "hard-turn animation reset sprint endurance"
        );
        let speed = retail_sprint_speed(runtime.sprint_endurance_seconds);
        assert!(speed < RETAIL_SPRINT_SPEED_SAMPLES[0].1);
    }

    #[test]
    fn turn_walk_hysteresis_uses_the_authored_turn_angle_shoulder() {
        let mut enter_angle = 0.0;
        let mut exit_angle = 0.0;
        for degree in 0..=1800 {
            let angle = (degree as f32 / 10.0).to_radians();
            let intent = retail_turn_intent(angle);
            if enter_angle == 0.0 && intent >= TURN_WALK_ENTER_INTENT {
                enter_angle = angle;
            }
            if exit_angle == 0.0 && intent >= TURN_WALK_EXIT_INTENT {
                exit_angle = angle;
            }
        }
        assert!(enter_angle > exit_angle);
        assert!(enter_angle.to_degrees() > 40.0);
        assert!(enter_angle.to_degrees() < 90.0);
        assert_eq!(TURN_WALK_ENTER_INTENT, TURN_ANGLE_INPUT_X[2]);
        assert_eq!(TURN_WALK_EXIT_INTENT, TURN_ANGLE_INPUT_X[1]);
    }

    #[test]
    fn sharp_forward_turn_never_uses_the_backward_translation_lock() {
        let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(OffboardGait::Sprint));
        runtime.phase_time = 1.0;
        runtime.sprint_endurance_seconds = 1.0;
        let control = OffboardControl {
            left_stick: Vec2::new(28000.0, 14000.0).normalize(),
            sprint_held: true,
            world_yaw: 0.0,
        };

        let first = runtime.step(DT, control);
        assert!(runtime.backward_reorientation.is_none());
        assert_eq!(runtime.trajectory_motion_weight, 1.0);
        assert!(
            first.local_delta.length() > 0.04,
            "sharp forward turn was incorrectly position-locked"
        );
        assert_eq!(runtime.phase, OffboardPhase::Locomotion(OffboardGait::Walk));
    }

    #[test]
    fn retail_turn_curve_keeps_diagonal_rate_and_sharpens_large_angles() {
        let diagonal = retail_moving_turn_rate(-std::f32::consts::FRAC_PI_4);
        assert!((diagonal + MEASURED_MOVING_DIAGONAL_RATE).abs() < 0.01);

        let loose = retail_moving_turn_rate(-13.13_f32.to_radians());
        assert!((loose.to_degrees() + 11.2).abs() < 0.5);

        let sharp = retail_moving_turn_rate(-63.435_f32.to_radians());
        assert!(
            sharp.abs() > loose.abs() * 7.0,
            "decoded curve did not provide nonlinear sharp-turn response"
        );
        assert!(sharp.abs() <= MOVING_MAX_YAW_RATE);
    }

    #[test]
    fn rearward_reorientation_never_enters_turn_walk() {
        let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(OffboardGait::Sprint));
        runtime.phase_time = 1.0;
        runtime.step(
            DT,
            OffboardControl {
                left_stick: -Vec2::Y,
                sprint_held: true,
                world_yaw: 0.0,
            },
        );
        assert!(runtime.backward_reorientation.is_some());
        assert!(!runtime.turning_walk);
        assert_eq!(
            runtime.phase,
            OffboardPhase::Locomotion(OffboardGait::Sprint)
        );
    }

    #[test]
    fn turn_walk_cadence_is_not_driven_at_sprint_stride_rate() {
        let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(OffboardGait::Sprint));
        runtime.phase_time = 1.0;
        runtime.biped_cadence = Some(BipedCadence { phase: 0.25 });
        runtime.step(
            DT,
            OffboardControl {
                left_stick: Vec2::X,
                sprint_held: true,
                world_yaw: 0.0,
            },
        );
        let entry_phase = runtime.biped_cadence.expect("turn walk lost cadence").phase;
        runtime.source_blend = None;
        runtime.step(
            DT,
            OffboardControl {
                left_stick: Vec2::X,
                sprint_held: true,
                world_yaw: 0.0,
            },
        );
        let next_phase = runtime.biped_cadence.expect("turn walk lost cadence").phase;
        let expected_advance =
            RETAIL_WALK_SPEED_MPS * DT / action_cycle_distance(OffboardGait::Walk.cycle_clip());
        assert!(((next_phase - entry_phase).rem_euclid(1.0) - expected_advance).abs() < 1.0e-5);
    }

    #[test]
    fn turn_walk_preserves_cadence_phase_at_entry() {
        let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(OffboardGait::Run));
        runtime.phase_time = 1.0;
        runtime.biped_cadence = Some(BipedCadence { phase: 0.73 });
        runtime.step(
            DT,
            OffboardControl {
                left_stick: Vec2::X,
                world_yaw: 0.0,
                ..default()
            },
        );
        let cadence = runtime.biped_cadence.expect("turn walk lost cadence");
        assert!(
            (cadence.phase - 0.73).abs() < 0.02,
            "turn walk discarded source cadence: {}",
            cadence.phase
        );
    }

    #[test]
    fn full_stick_supports_every_local_direction_without_changing_clip_family() {
        let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(OffboardGait::Run));
        runtime.phase_time = 1.0;
        let local_delta = Vec3::Z * RETAIL_RUN_SPEED_MPS * DT;

        let forward = runtime
            .step_trajectory_heading(DT, Vec2::Y, 0.0, local_delta)
            .0;
        assert_eq!(forward, 0.0);
        let right = runtime
            .step_trajectory_heading(DT, Vec2::X, 0.0, local_delta)
            .0;
        assert!(right < 0.0);
        runtime.yaw_rate = 0.0;
        let left = runtime
            .step_trajectory_heading(DT, -Vec2::X, 0.0, local_delta)
            .0;
        assert!(left > 0.0);
        runtime.yaw_rate = 0.0;
        let back = runtime
            .step_trajectory_heading(DT, -Vec2::Y, 0.0, local_delta)
            .0;
        assert!(back < 0.0);
        assert_eq!(runtime.primary_clip(), "BR_RUN_FWD_CYC");
    }

    fn simulate_lateral_partition(dt: f32, seconds: f32) -> (f32, Vec3) {
        let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(OffboardGait::Run));
        runtime.phase_time = 1.0;
        let control_stick = Vec2::new(
            std::f32::consts::FRAC_1_SQRT_2,
            std::f32::consts::FRAC_1_SQRT_2,
        );
        let mut yaw = 0.0;
        let mut position = Vec3::ZERO;
        for _ in 0..(seconds / dt).round() as usize {
            let step = runtime.step(
                dt,
                OffboardControl {
                    left_stick: control_stick,
                    world_yaw: yaw,
                    ..default()
                },
            );
            let next_yaw = yaw + step.yaw_rate * dt;
            position += Quat::from_rotation_y((yaw + next_yaw) * 0.5) * step.local_delta;
            yaw = next_yaw;
        }
        (yaw, position)
    }

    #[test]
    fn lateral_trajectory_is_responsive_and_frame_partition_invariant() {
        let (yaw_120, position_120) = simulate_lateral_partition(1.0 / 120.0, 1.0);
        let (yaw_60, position_60) = simulate_lateral_partition(1.0 / 60.0, 1.0);
        assert!(
            yaw_120 < -0.95,
            "measured diagonal response was not reached: {yaw_120}"
        );
        assert!((yaw_120 - yaw_60).abs() < 0.02);
        let partition_distance = (position_120 - position_60).length();
        assert!(
            partition_distance < 0.08,
            "partitioned trajectories diverged by {partition_distance}"
        );
    }

    fn simulate_sharp_turn_partition(dt: f32, seconds: f32) -> (f32, Vec3, f32, bool) {
        let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(OffboardGait::Sprint));
        runtime.phase_time = 1.0;
        runtime.sprint_endurance_seconds = 1.0;
        let stick = Vec2::new(28000.0, 14000.0).normalize();
        let mut yaw = 0.0;
        let mut position = Vec3::ZERO;
        for _ in 0..(seconds / dt).round() as usize {
            let step = runtime.step(
                dt,
                OffboardControl {
                    left_stick: stick,
                    sprint_held: true,
                    world_yaw: yaw,
                },
            );
            let next_yaw = yaw + step.yaw_rate * dt;
            position += Quat::from_rotation_y((yaw + next_yaw) * 0.5) * step.local_delta;
            yaw = next_yaw;
        }
        (
            yaw,
            position,
            runtime
                .biped_cadence
                .expect("sharp turn lost cadence")
                .phase,
            runtime.turning_walk,
        )
    }

    #[test]
    fn sharp_turn_walk_and_trajectory_are_frame_partition_invariant() {
        let (yaw_120, position_120, cadence_120, turning_120) =
            simulate_sharp_turn_partition(1.0 / 120.0, 1.0);
        let (yaw_60, position_60, cadence_60, turning_60) =
            simulate_sharp_turn_partition(1.0 / 60.0, 1.0);

        assert!(turning_120 && turning_60);
        assert!((yaw_120 - yaw_60).abs() < 0.025);
        assert!((position_120 - position_60).length() < 0.12);
        assert!((cadence_120 - cadence_60).abs() < 0.015);
    }

    #[test]
    fn offboard_camera_follow_is_monotonic_during_a_held_sharp_turn() {
        let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(OffboardGait::Sprint));
        runtime.phase_time = 1.0;
        runtime.sprint_endurance_seconds = 1.0;
        let stick = Vec2::new(28000.0, 14000.0).normalize();
        let mut yaw = 0.0;
        let mut previous_view_yaw = runtime.view_yaw;

        for _ in 0..240 {
            let step = runtime.step(
                DT,
                OffboardControl {
                    left_stick: stick,
                    sprint_held: true,
                    world_yaw: yaw,
                },
            );
            yaw += step.yaw_rate * DT;
            assert!(
                step.view_yaw <= previous_view_yaw + 1.0e-6,
                "offboard camera reversed direction: {} -> {}",
                previous_view_yaw,
                step.view_yaw
            );
            assert!(
                step.view_yaw >= yaw - 0.4,
                "offboard camera overshot the biped heading"
            );
            previous_view_yaw = step.view_yaw;
        }
    }

    #[test]
    fn held_back_rotates_then_moves_without_repeated_circles() {
        let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(OffboardGait::Run));
        runtime.phase_time = 1.0;
        let mut yaw = 0.0;
        let mut position = Vec3::ZERO;
        let mut first_motion_yaw = None;
        let mut post_acquire_yaws = Vec::new();

        for tick in 0..720 {
            let step = runtime.step(
                DT,
                OffboardControl {
                    left_stick: -Vec2::Y,
                    world_yaw: yaw,
                    ..default()
                },
            );
            let next_yaw = yaw + step.yaw_rate * DT;
            let world_delta = Quat::from_rotation_y((yaw + next_yaw) * 0.5) * step.local_delta;
            if first_motion_yaw.is_none() && world_delta.length() > 0.001 {
                first_motion_yaw = Some(yaw);
            }
            position += world_delta;
            yaw = next_yaw;
            if tick >= 360 {
                post_acquire_yaws.push(yaw);
            }
        }

        let first_motion_yaw = first_motion_yaw.expect("backward hold never began moving");
        assert!(
            first_motion_yaw.abs() > 2.35,
            "translation began before the retail reorientation: {first_motion_yaw}"
        );
        assert!(
            (yaw + std::f32::consts::PI).abs() < 0.08,
            "held backward kept carving instead of settling: {yaw}"
        );
        let yaw_span = post_acquire_yaws
            .iter()
            .copied()
            .fold((f32::INFINITY, f32::NEG_INFINITY), |(min, max), value| {
                (min.min(value), max.max(value))
            });
        assert!(
            yaw_span.1 - yaw_span.0 < 0.08,
            "acquired heading did not remain stable: {yaw_span:?}"
        );
        assert!(
            position.length() > 20.0,
            "forward root did not proceed on the acquired heading"
        );
    }

    #[test]
    fn reversing_back_to_forward_cancels_reorientation_without_stale_turning() {
        let mut runtime = runtime_in_phase(OffboardPhase::Locomotion(OffboardGait::Run));
        runtime.phase_time = 1.0;
        let mut yaw = 0.0;
        for _ in 0..180 {
            let step = runtime.step(
                DT,
                OffboardControl {
                    left_stick: -Vec2::Y,
                    world_yaw: yaw,
                    ..default()
                },
            );
            yaw += step.yaw_rate * DT;
        }
        assert!(runtime.backward_reorientation.is_some());

        for _ in 0..120 {
            let step = runtime.step(
                DT,
                OffboardControl {
                    left_stick: Vec2::Y,
                    world_yaw: yaw,
                    ..default()
                },
            );
            yaw += step.yaw_rate * DT;
        }
        assert!(runtime.backward_reorientation.is_none());
        assert!(runtime.yaw_rate.abs() < 0.02);
    }
}
