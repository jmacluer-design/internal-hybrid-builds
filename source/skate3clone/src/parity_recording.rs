use std::{
    collections::HashMap,
    fmt::Write as _,
    path::PathBuf,
    time::{SystemTime, UNIX_EPOCH},
};

use bevy::transform::TransformSystems;
use bevy::{app::AppExit, prelude::*};
use serde::{Deserialize, Serialize};

use crate::sim::{
    CanonicalPadState, FIXED_HZ, PushFoot, SkateInput, SkateSim, canonical_axis_to_normalized,
};

const RETAIL_INPUT_HZ: u64 = 60;
const FIXED_TICKS_PER_RETAIL_POLL: u64 = 2;
const XINPUT_A: u16 = 0x1000;
const XINPUT_B: u16 = 0x2000;
const XINPUT_X: u16 = 0x4000;
const XINPUT_Y: u16 = 0x8000;
const RECORDED_BONES: [&str; 33] = [
    "HIPS",
    "SPINE",
    "SPINE1",
    "SPINE2",
    "SPINE3",
    "NECK",
    "NECK1",
    "HEAD",
    "RIGHTSHOULDER",
    "RIGHTARM",
    "RIGHTFOREARM",
    "RIGHTHAND",
    "LEFTSHOULDER",
    "LEFTARM",
    "LEFTFOREARM",
    "LEFTHAND",
    "RIGHTUPLEG",
    "RIGHTLEG",
    "RIGHTFOOT",
    "RIGHTTOEBASE",
    "LEFTUPLEG",
    "LEFTLEG",
    "LEFTFOOT",
    "LEFTTOEBASE",
    "SKATEBOARD_ROOT",
    "TRUCK_FRONT",
    "RIGHT_WHEELFRONT",
    "LEFT_WHEELFRONT",
    "TRUCK_BACK",
    "LEFT_WHEELBACK",
    "RIGHT_WHEELBACK",
    "RIGHTTOEBASE_REPARENTED",
    "LEFTTOEBASE_REPARENTED",
];

pub struct ParityRecordingPlugin;

impl Plugin for ParityRecordingPlugin {
    fn build(&self, app: &mut App) {
        let runtime = ParityRuntime::from_environment();
        app.insert_resource(runtime)
            .init_resource::<ParityRecorderStatus>()
            .add_systems(Startup, begin_environment_recording)
            .add_systems(PreUpdate, toggle_recording_hotkey)
            .add_systems(
                FixedUpdate,
                drive_parity_replay.before(crate::sim::fixed_step),
            )
            .add_systems(
                FixedUpdate,
                record_parity_tick.after(crate::sim::fixed_step),
            )
            .add_systems(Update, finish_completed_auto_replay)
            .add_systems(
                PostUpdate,
                record_parity_bones.after(TransformSystems::Propagate),
            )
            .add_systems(Last, flush_on_exit);
    }
}

#[derive(Resource, Default, Debug)]
pub struct ParityRecorderStatus {
    pub recording: bool,
    pub replaying: bool,
    pub poll: u64,
    pub output: Option<PathBuf>,
    pub message: String,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize)]
struct ReplayStep {
    #[serde(alias = "frames")]
    polls: u32,
    buttons: u16,
    #[serde(default)]
    lt: u8,
    #[serde(default)]
    rt: u8,
    #[serde(default)]
    lx: i16,
    #[serde(default)]
    ly: i16,
    #[serde(default)]
    rx: i16,
    #[serde(default)]
    ry: i16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    bevy_lx: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    bevy_ly: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    bevy_rx: Option<f32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    bevy_ry: Option<f32>,
}

impl ReplayStep {
    fn from_input(input: &SkateInput) -> Self {
        let pad = input.canonical_pad;
        Self {
            polls: 1,
            buttons: pad.buttons,
            lt: pad.left_trigger,
            rt: pad.right_trigger,
            lx: pad.left_x,
            ly: pad.left_y,
            rx: pad.right_x,
            ry: pad.right_y,
            bevy_lx: Some(input.left_stick.x),
            bevy_ly: Some(input.left_stick.y),
            bevy_rx: Some(input.right_stick.x),
            bevy_ry: Some(input.right_stick.y),
        }
    }

    fn same_state(&self, other: &Self) -> bool {
        self.buttons == other.buttons
            && self.lt == other.lt
            && self.rt == other.rt
            && self.lx == other.lx
            && self.ly == other.ly
            && self.rx == other.rx
            && self.ry == other.ry
            && self.bevy_lx == other.bevy_lx
            && self.bevy_ly == other.bevy_ly
            && self.bevy_rx == other.bevy_rx
            && self.bevy_ry == other.bevy_ry
    }

    fn canonical_pad(self) -> CanonicalPadState {
        CanonicalPadState {
            buttons: self.buttons,
            left_trigger: self.lt,
            right_trigger: self.rt,
            left_x: self.lx,
            left_y: self.ly,
            right_x: self.rx,
            right_y: self.ry,
        }
    }

    fn bevy_left_stick(self) -> Vec2 {
        if let (Some(x), Some(y)) = (self.bevy_lx, self.bevy_ly) {
            return Vec2::new(x, y).clamp_length_max(1.0);
        }
        Vec2::new(
            canonical_axis_to_normalized(self.lx),
            canonical_axis_to_normalized(self.ly),
        )
        .clamp_length_max(1.0)
    }

    fn bevy_right_stick(self) -> Vec2 {
        if let (Some(x), Some(y)) = (self.bevy_rx, self.bevy_ry) {
            return Vec2::new(x, y).clamp_length_max(1.0);
        }
        Vec2::new(
            canonical_axis_to_normalized(self.rx),
            canonical_axis_to_normalized(self.ry),
        )
        .clamp_length_max(1.0)
    }
}

#[derive(Debug)]
struct ReplayDriver {
    source: PathBuf,
    steps: Vec<ReplayStep>,
    step_index: usize,
    ticks_left_in_step: u64,
    current: ReplayStep,
    previous_buttons: u16,
    complete: bool,
    padding_ticks: u64,
}

impl ReplayDriver {
    fn load(path: PathBuf) -> Self {
        let bytes = std::fs::read(&path)
            .unwrap_or_else(|error| panic!("could not read replay {}: {error}", path.display()));
        let steps: Vec<ReplayStep> = serde_json::from_slice(&bytes)
            .unwrap_or_else(|error| panic!("invalid replay {}: {error}", path.display()));
        assert!(!steps.is_empty(), "parity replay cannot be empty");
        assert!(
            steps.iter().all(|step| step.polls != 0),
            "parity replay steps must contain at least one poll"
        );
        Self {
            source: path,
            steps,
            step_index: 0,
            ticks_left_in_step: 0,
            current: ReplayStep {
                polls: 1,
                buttons: 0,
                lt: 0,
                rt: 0,
                lx: 0,
                ly: 0,
                rx: 0,
                ry: 0,
                bevy_lx: Some(0.0),
                bevy_ly: Some(0.0),
                bevy_rx: Some(0.0),
                bevy_ry: Some(0.0),
            },
            previous_buttons: 0,
            complete: false,
            padding_ticks: 0,
        }
    }

    fn advance(&mut self) -> ReplayStep {
        if self.complete {
            self.padding_ticks = self.padding_ticks.saturating_add(1);
            return ReplayStep {
                polls: 1,
                ..default()
            };
        }
        if self.ticks_left_in_step == 0 {
            if self.step_index >= self.steps.len() {
                self.complete = true;
                return self.advance();
            }
            self.current = self.steps[self.step_index];
            self.step_index += 1;
            self.ticks_left_in_step = self.current.polls as u64 * FIXED_TICKS_PER_RETAIL_POLL;
        }
        self.ticks_left_in_step -= 1;
        self.current
    }
}

#[derive(Debug)]
struct RecordingSession {
    output: PathBuf,
    replay: Vec<ReplayStep>,
    telemetry: String,
    bones: String,
    fixed_tick: u64,
    bone_sample: u64,
    started_unix_ms: u128,
    replay_source: Option<PathBuf>,
}

impl RecordingSession {
    fn new(output: PathBuf, replay_source: Option<PathBuf>) -> Self {
        std::fs::create_dir_all(&output).unwrap_or_else(|error| {
            panic!(
                "could not create parity output {}: {error}",
                output.display()
            )
        });
        let mut bones = "sample,sim_time_seconds,animation_clip,animation_revision".to_owned();
        for name in RECORDED_BONES {
            for component in [
                "m00", "m01", "m02", "tx", "m10", "m11", "m12", "ty", "m20", "m21", "m22", "tz",
            ] {
                write!(bones, ",{name}_{component}")
                    .expect("writing a bone telemetry header cannot fail");
            }
        }
        bones.push('\n');

        Self {
            output,
            replay: Vec::new(),
            telemetry: concat!(
                "fixed_tick,time_seconds,state,animation_clip,animation_revision,",
                "animation_speed,animation_repeat,speed_mps,position_x,position_y,",
                "position_z,velocity_x,velocity_z,yaw_radians,processed_lx,",
                "processed_ly,processed_rx,processed_ry,buttons,lt,rt,",
                "raw_lx,raw_ly,raw_rx,raw_ry,",
                "brake_hold_seconds,brake_active,powerslide_radians,",
                "deck_roll_radians,wheel_spin_radians,ride_phase_seconds,",
                "body_tilt,push_phase,push_phase_seconds,push_phase_duration,",
                "push_hstr_vel_b,push_lstr_vel_b,push_vel_e,",
                "push_target_hstr_vel_b,push_target_lstr_vel_b,push_target_vel_e,",
                "push_delta_velocity,push_hold_seconds,push_strength,",
                "push_strength_frozen,push_drive_active,push_drive_progress,",
                "push_contact_start_speed,push_contact_target_speed,",
                "push_repush_queued,push_repush_hold_seconds,push_repush_strength,",
                "push_repeat_count,action_weight,",
                "action_layers,slide_phase,slide_decel,slide_decel_target,",
                "slide_disttocog,brake_speed_blend,local_longitudinal_speed,",
                "local_lateral_speed,yaw_rate,body_spin_angle,body_spin_velocity,",
                "body_spin_animation_phase,acceleration_x,acceleration_z,",
                "lateral_friction_rate,candidate_slide_weight,candidate_slide_flag,",
                "board_authority,ground_contact_valid,ground_normal_x,",
                "ground_normal_y,ground_normal_z,ground_surface_id,",
                "basic_trick_phase,basic_trick_resource,basic_trick_resolution,",
                "flickit_probe_samples,flickit_probe_cadence,flickit_processed_rx,",
                "flickit_processed_ry,flickit_geometry_candidates,",
                "flickit_publication_status,flickit_selected_contact,",
                "skateboard_body_step,wheel_contact_mask,wheel_compression_front,",
                "wheel_compression_back,wheel_compression_all,grind_table_index,",
                "grind_canonical_name,grind_phase,grind_virtual_resource,",
                "riding_force_queue_len,riding_post_result,conditioned_body_tilt,",
                "conditioned_body_tilt_delta,conditioned_body_tilt_enabled,",
                "manual_kind,manual_phase,manual_virtual_resource,manual_raw_balance,",
                "manual_conditioned_angle,manual_conditioned_velocity,",
                "air_trick_intent,air_trick_phase,air_trick_virtual_resource,",
                "grab_identity,grab_phase,grab_resource,grab_resolution,",
                "landing_quality,landing_virtual_resource,landing_resolution,",
                "landing_elapsed_seconds,landing_selected_variant,",
                "contact_touching_bodies,contact_touching_wheels,",
                "contact_dominant_surface,contact_airborne_seconds,",
                "flickit_retail_notifications,flickit_retail_cadence,",
                "flickit_retail_winner,flickit_retail_selected_contact,",
                "anticipation_side,anticipation_phase,anticipation_phase_seconds,",
                "anticipation_charge_seconds,pop_active,pop_launch_speed,",
                "pop_ground_height,pop_separated,pop_elapsed_since_flick,",
                "pop_board_height,pop_skater_height,pop_touched_down,velocity_y,",
                "contact_friction_path,contact_friction_touching_wheels,",
                "contact_friction_deck_touching,contact_friction_surface_id,",
                "contact_friction_touchdown,contact_friction_speed_before,",
                "contact_friction_speed_after,contact_friction_speed_loss,",
                "contact_friction_lateral_before,contact_friction_lateral_after,",
                "contact_friction_one_shot_delta_x,contact_friction_one_shot_delta_z,",
                "contact_friction_continuous_delta_x,contact_friction_continuous_delta_z,",
                "landing_provider_code,landing_approach_speed,",
                "landing_board_velocity_heading_delta,landing_completed_rotation,",
                "landing_admission,manual_engage_seconds,deck_pitch_radians,",
                "manual_deck_end,manual_deck_height,manual_deck_touching,",
                "manual_deck_drag_deceleration,manual_deck_speed_loss\n"
            )
            .to_owned(),
            bones,
            fixed_tick: 0,
            bone_sample: 0,
            started_unix_ms: unix_millis(),
            replay_source,
        }
    }

    fn capture_retail_poll(&mut self, input: &SkateInput) {
        let next = ReplayStep::from_input(input);
        if let Some(last) = self.replay.last_mut()
            && last.same_state(&next)
        {
            last.polls = last.polls.saturating_add(1);
        } else {
            self.replay.push(next);
        }
    }

    fn capture_telemetry(&mut self, input: &SkateInput, sim: &SkateSim) {
        let clip = sim.animation_clip.as_deref().unwrap_or("BTREE_RIDING");
        let pad = input.canonical_pad;
        let action = sim.action_animation_state();
        let action_layers = action
            .samples
            .iter()
            .map(|sample| {
                format!(
                    "{}@{:.6}@{:.6}",
                    sample.clip, sample.weight, sample.seek_time_seconds
                )
            })
            .collect::<Vec<_>>()
            .join("|");
        let (
            push_phase,
            push_phase_time,
            push_phase_duration,
            hstr_vel_b,
            lstr_vel_b,
            vel_e,
            target_hstr_vel_b,
            target_lstr_vel_b,
            target_vel_e,
            push_delta_velocity,
            push_hold_time,
            push_strength,
            push_strength_frozen,
            push_drive_active,
            push_drive_progress,
            push_contact_start_speed,
            push_contact_target_speed,
            push_repush_queued,
            push_repush_hold_time,
            push_repush_strength,
            push_repeat_count,
        ) = sim.push.as_ref().map_or(
            (
                "", 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, false, false, 0.0, 0.0,
                0.0, false, 0.0, 0.0, 0,
            ),
            |push| {
                (
                    push.phase.label(),
                    push.phase_time,
                    push.phase_duration,
                    push.coefficients.high_strength_velocity_begin,
                    push.coefficients.low_strength_velocity_begin,
                    push.coefficients.velocity_end,
                    push.target_coefficients.high_strength_velocity_begin,
                    push.target_coefficients.low_strength_velocity_begin,
                    push.target_coefficients.velocity_end,
                    push.push_delta_velocity,
                    push.hold_time,
                    push.strength,
                    push.strength_frozen,
                    push.contact_propulsion_enabled,
                    push.drive_progress(),
                    push.contact_start_speed,
                    push.contact_target_speed,
                    push.queued_repush,
                    push.queued_repush_hold_time,
                    push.queued_repush_strength,
                    push.repeat_count,
                )
            },
        );
        let (slide_phase, slide_decel, slide_decel_target, slide_disttocog) =
            sim.slide.as_ref().map_or(("", 0.0, 0.0, 0.0), |slide| {
                (
                    slide.phase.label(),
                    slide.decel,
                    slide.decel_target,
                    slide.distance_to_cog,
                )
            });
        let brake_speed_blend = sim.brake.as_ref().map_or(0.0, |brake| {
            if brake.phase == crate::sim::BrakePhase::MovingCycle {
                (sim.speed() / 4.0).clamp(0.0, 1.0)
            } else {
                0.0
            }
        });
        let (basic_trick_phase, basic_trick_resource) =
            sim.basic_trick.as_ref().map_or(("", ""), |playback| {
                (
                    playback.phase_label(),
                    playback.requested_resource().unwrap_or(""),
                )
            });
        let basic_trick_resolution = match sim.basic_trick_animation_state() {
            Ok(Some(_)) => "resolved".to_owned(),
            Ok(None) => String::new(),
            Err(unresolved) => format!("unresolved:{:?}", unresolved.reason),
        };
        let flickit_processed = sim.trick_input.processed_sample();
        let wheel_contact_mask = sim
            .skateboard_body
            .wheels
            .iter()
            .enumerate()
            .fold(0_u8, |mask, (index, wheel)| {
                mask | (u8::from(wheel.contact.touching) << index)
            });
        let (grind_table_index, grind_name, grind_phase, grind_resource) =
            sim.grind.as_ref().map_or_else(
                || (String::new(), String::new(), String::new(), String::new()),
                |playback| {
                    (
                        playback.classification.table_index.to_string(),
                        playback.classification.canonical_name.to_owned(),
                        match playback.runtime.phase {
                            crate::grind_graph::GrindPhase::Cycle => "cycle",
                            crate::grind_graph::GrindPhase::GrabInto => "grab_into",
                            crate::grind_graph::GrindPhase::GrabCycle => "grab_cycle",
                            crate::grind_graph::GrindPhase::GrabOut => "grab_out",
                            crate::grind_graph::GrindPhase::ExitingToAir => "air_exit",
                            crate::grind_graph::GrindPhase::TrickOut => "trick_out",
                            crate::grind_graph::GrindPhase::Complete => "complete",
                        }
                        .to_owned(),
                        playback
                            .runtime
                            .animation_request()
                            .map_or_else(String::new, |request| request.resource.name),
                    )
                },
            );
        let riding_post_result =
            sim.last_riding_post_physics
                .map_or("", |state| match state.plan.result {
                    crate::riding_forces::PostPhysicsResultCode::Variant0 => "variant_0",
                    crate::riding_forces::PostPhysicsResultCode::Variant1 => "variant_1",
                    crate::riding_forces::PostPhysicsResultCode::Variant2 => "variant_2",
                });
        let (
            manual_kind,
            manual_phase,
            manual_resource,
            manual_raw_balance,
            manual_conditioned_angle,
            manual_conditioned_velocity,
        ) = sim
            .manual
            .as_ref()
            .map_or(("", "", "", 0.0, 0.0, 0.0), |playback| {
                (
                    match playback.runtime.kind {
                        crate::manual_graph::ManualKind::Tail => "tail",
                        crate::manual_graph::ManualKind::Nose => "nose",
                    },
                    match playback.runtime.phase {
                        crate::manual_graph::ManualPhase::NoseInto => "nose_into",
                        crate::manual_graph::ManualPhase::Cycle => "cycle",
                        crate::manual_graph::ManualPhase::Brake => "brake",
                        crate::manual_graph::ManualPhase::NoseOut => "nose_out",
                        crate::manual_graph::ManualPhase::Revert(_) => "revert",
                        crate::manual_graph::ManualPhase::ExitRequested => "exit_requested",
                        crate::manual_graph::ManualPhase::Complete => "complete",
                    },
                    playback
                        .runtime
                        .animation_request()
                        .map_or("", |request| request.resource),
                    playback.runtime.balance,
                    playback.balance_conditioner.angle(),
                    playback.balance_conditioner.velocity(),
                )
            });
        let (air_trick_intent, air_trick_phase, air_trick_resource) =
            sim.air_trick.as_ref().map_or_else(
                || (String::new(), String::new(), String::new()),
                |playback| {
                    (
                        playback.runtime.trick.intent_name().to_owned(),
                        playback.phase_label().to_owned(),
                        playback.requested_resource().unwrap_or_default(),
                    )
                },
            );
        let (grab_identity, grab_phase, grab_resource) =
            sim.grab.as_ref().map_or(("", "", ""), |playback| {
                (
                    match playback.runtime.identity {
                        crate::grab_graph::GrabIdentity::Fs => "fs",
                        crate::grab_graph::GrabIdentity::Bs => "bs",
                        crate::grab_graph::GrabIdentity::Double => "double",
                        crate::grab_graph::GrabIdentity::Mute => "mute",
                        crate::grab_graph::GrabIdentity::Stale => "stale",
                        crate::grab_graph::GrabIdentity::Coffin => "coffin",
                        crate::grab_graph::GrabIdentity::Superman => "superman",
                    },
                    playback.phase_label(),
                    playback.requested_resource().unwrap_or(""),
                )
            });
        let grab_resolution = match sim.grab_animation_state() {
            Ok(Some(_)) => "resolved".to_owned(),
            Ok(None) => String::new(),
            Err(failure) => format!("blocked:{:?}", failure.reason),
        };
        let (landing_quality, landing_resource, landing_elapsed, landing_variant) =
            sim.landing.as_ref().map_or_else(
                || (String::new(), String::new(), 0.0, String::new()),
                |playback| {
                    (
                        match playback.runtime.quality {
                            crate::landing_graph::LandingQuality::Spin => "spin",
                            crate::landing_graph::LandingQuality::Sketchy => "sketchy",
                            crate::landing_graph::LandingQuality::Straight => "straight",
                        }
                        .to_owned(),
                        playback.requested_resource().to_owned(),
                        playback.runtime.elapsed_seconds,
                        playback
                            .selected_variant
                            .map_or_else(String::new, |variant| variant.to_string()),
                    )
                },
            );
        let landing_resolution = match sim.landing_animation_state() {
            Ok(Some(_)) => "resolved".to_owned(),
            Ok(None) => String::new(),
            Err(unresolved) => format!("blocked:{:?}", unresolved.reason),
        };
        let (
            landing_provider_code,
            landing_approach_speed,
            landing_heading_delta,
            landing_completed_rotation,
        ) = sim.last_landing_decision_input.map_or_else(
            || (String::new(), String::new(), String::new(), String::new()),
            |decision| {
                (
                    decision
                        .provider_code
                        .map_or_else(String::new, |code| code.0.to_string()),
                    decision.approach_speed_metres_per_second.to_string(),
                    decision
                        .board_velocity_heading_delta_radians
                        .map_or_else(String::new, |angle| angle.to_string()),
                    decision.completed_rotation_radians.to_string(),
                )
            },
        );
        let landing_admission = sim
            .last_landing_admission
            .map_or_else(String::new, |admission| format!("{admission:?}"));
        let (
            contact_touching_bodies,
            contact_touching_wheels,
            contact_dominant_surface,
            contact_airborne_seconds,
        ) = sim.last_contact_bridge.as_ref().map_or(
            (0, 0, 0, sim.skateboard_airborne_time_seconds),
            |bridge| {
                (
                    bridge.touching_body_count,
                    bridge.touching_wheel_count,
                    bridge.dominant_surface_class,
                    bridge.airborne_time_seconds,
                )
            },
        );
        let (anticipation_side, anticipation_phase, anticipation_phase_time, anticipation_charge) =
            sim.anticipation
                .as_ref()
                .map_or(("", "", 0.0, 0.0), |runtime| {
                    (
                        match runtime.side {
                            crate::trick_catalog::AnticipationSide::Tail => "tail",
                            crate::trick_catalog::AnticipationSide::Nose => "nose",
                        },
                        runtime.phase_label(),
                        runtime.phase_time_seconds,
                        runtime.charge_seconds,
                    )
                });
        let (
            pop_active,
            pop_launch_speed,
            pop_ground_height,
            pop_separated,
            pop_elapsed_since_flick,
            pop_board_height,
            pop_skater_height,
            pop_touched_down,
        ) = sim
            .pop_motion
            .as_ref()
            .map_or((0, 0.0, 0.0, 0, 0.0, 0.0, 0.0, 0), |motion| {
                (
                    1,
                    motion.launch_speed,
                    motion.ground_height,
                    u8::from(motion.separated_from_ground),
                    motion.elapsed_since_flick_seconds,
                    motion.board_height,
                    motion.skater_height,
                    u8::from(motion.touched_down),
                )
            });
        write!(
            self.telemetry,
            concat!(
                "{},{:.9},{},{},{},{:.6},{},",
                "{:.9},{:.9},{:.9},{:.9},{:.9},{:.9},{:.9},{:.9},{:.9},{:.9},{:.9},",
                "{},{},{},{},{},{},{},",
                "{:.9},{},{:.9},{:.9},{:.9},{:.9},{:.9},",
                "{},{:.9},{:.9},{:.9},{:.9},{:.9},{:.9},{:.9},{:.9},{:.9},",
                "{:.9},{:.9},{},{},{:.9},{:.9},{:.9},{},{:.9},{:.9},{},{:.9},{},",
                "{},{:.9},{:.9},{:.9},{:.9},{:.9},{:.9},{:.9},",
                "{:.9},{:.9},{:.9},",
                "{:.9},{:.9},{:.9},{:.9},{},{},{},",
                "{:.9},{:.9},{:.9},{},{},{},{},",
                "{},{},{:.9},{:.9},{},{},{},{},{},{:.9},{:.9},{:.9},",
                "{},{},{},{},{},{},{:.9},{:.9},{},",
                "{},{},{},{:.9},{:.9},{:.9}"
            ),
            self.fixed_tick,
            self.fixed_tick as f64 / FIXED_HZ,
            csv_field(sim.state_label()),
            csv_field(clip),
            sim.animation_revision,
            sim.animation_speed,
            u8::from(sim.animation_repeat),
            sim.speed(),
            sim.position.x,
            sim.position.y,
            sim.position.z,
            sim.velocity.x,
            sim.velocity.z,
            sim.yaw,
            input.left_stick.x,
            input.left_stick.y,
            input.right_stick.x,
            input.right_stick.y,
            pad.buttons,
            pad.left_trigger,
            pad.right_trigger,
            pad.left_x,
            pad.left_y,
            pad.right_x,
            pad.right_y,
            sim.brake_hold_time,
            u8::from(sim.brake_active),
            sim.powerslide_rotation,
            sim.deck_roll,
            sim.wheel_spin,
            sim.ride_phase_time,
            sim.body_tilt,
            csv_field(push_phase),
            push_phase_time,
            push_phase_duration,
            hstr_vel_b,
            lstr_vel_b,
            vel_e,
            target_hstr_vel_b,
            target_lstr_vel_b,
            target_vel_e,
            push_delta_velocity,
            push_hold_time,
            push_strength,
            u8::from(push_strength_frozen),
            u8::from(push_drive_active),
            push_drive_progress,
            push_contact_start_speed,
            push_contact_target_speed,
            u8::from(push_repush_queued),
            push_repush_hold_time,
            push_repush_strength,
            push_repeat_count,
            action.weight,
            csv_field(&action_layers),
            csv_field(slide_phase),
            slide_decel,
            slide_decel_target,
            slide_disttocog,
            brake_speed_blend,
            sim.local_longitudinal_speed(),
            sim.local_lateral_speed(),
            sim.yaw_rate,
            sim.body_spin_angle,
            sim.body_spin_velocity,
            sim.body_spin_animation_phase_seconds,
            sim.planar_acceleration.x,
            sim.planar_acceleration.z,
            sim.lateral_friction_rate,
            sim.candidate_slide_weight,
            u8::from(sim.candidate_slide_active),
            sim.board_authority.label(),
            u8::from(sim.ground_contact_valid),
            sim.ground_normal.x,
            sim.ground_normal.y,
            sim.ground_normal.z,
            sim.ground_surface_id
                .map_or_else(String::new, |surface| surface.to_string()),
            csv_field(basic_trick_phase),
            csv_field(basic_trick_resource),
            csv_field(&basic_trick_resolution),
            sim.trick_input.probe_sample_count,
            sim.trick_input.cadence_label(),
            flickit_processed.x,
            flickit_processed.y,
            sim.trick_input.geometry_candidate_count(),
            sim.trick_input.publication_status_label(),
            sim.trick_input.selected_contact_label(),
            sim.skateboard_body
                .last_step
                .map_or_else(String::new, |step| step.to_string()),
            wheel_contact_mask,
            sim.skateboard_body.compression.front,
            sim.skateboard_body.compression.back,
            sim.skateboard_body.compression.all_wheels,
            grind_table_index,
            grind_name,
            grind_phase,
            grind_resource,
            sim.riding_force_queue.len(),
            riding_post_result,
            sim.body_tilt_conditioner.value,
            sim.body_tilt_conditioner.first_difference,
            u8::from(sim.body_tilt_conditioner.was_application_enabled),
            manual_kind,
            manual_phase,
            manual_resource,
            manual_raw_balance,
            manual_conditioned_angle,
            manual_conditioned_velocity,
        )
        .expect("writing to an in-memory telemetry buffer cannot fail");
        writeln!(
            self.telemetry,
            concat!(
                ",{},{},{},{},{},{},{},{},{},{},{:.9},{},{},{},{},{:.9},",
                "{},{},{},{},{},{},{:.9},{:.9},{},{:.9},{:.9},{},{:.9},",
                "{:.9},{:.9},{},{:.9},{},{},{},{},{},{:.9},{:.9},{:.9},",
                "{:.9},{:.9},{:.9},{:.9},{:.9},{:.9},",
                "{},{:.9},{:.9},{},{},",
                "{:.9},{:.9},{},{:.9},{},{:.9},{:.9}"
            ),
            csv_field(&air_trick_intent),
            csv_field(&air_trick_phase),
            csv_field(&air_trick_resource),
            csv_field(grab_identity),
            csv_field(grab_phase),
            csv_field(grab_resource),
            csv_field(&grab_resolution),
            csv_field(&landing_quality),
            csv_field(&landing_resource),
            csv_field(&landing_resolution),
            landing_elapsed,
            landing_variant,
            contact_touching_bodies,
            contact_touching_wheels,
            contact_dominant_surface,
            contact_airborne_seconds,
            sim.trick_input.retail_notification_count,
            sim.trick_input.retail_cadence_label(),
            csv_field(sim.trick_input.retail_winner_name().unwrap_or("")),
            sim.trick_input.retail_selected_contact_label(),
            anticipation_side,
            anticipation_phase,
            anticipation_phase_time,
            anticipation_charge,
            pop_active,
            pop_launch_speed,
            pop_ground_height,
            pop_separated,
            pop_elapsed_since_flick,
            pop_board_height,
            pop_skater_height,
            pop_touched_down,
            sim.velocity.y,
            csv_field(sim.last_contact_friction.path.label()),
            sim.last_contact_friction.contact.touching_wheels,
            u8::from(sim.last_contact_friction.contact.deck_touching),
            sim.last_contact_friction
                .contact
                .surface_id
                .map_or_else(String::new, |surface| surface.to_string()),
            u8::from(sim.last_contact_friction.touchdown_this_step),
            sim.last_contact_friction.local_before.speed,
            sim.last_contact_friction.local_after.speed,
            sim.last_contact_friction.speed_loss,
            sim.last_contact_friction.local_before.lateral,
            sim.last_contact_friction.local_after.lateral,
            sim.last_contact_friction.one_shot_velocity_delta.x,
            sim.last_contact_friction.one_shot_velocity_delta.z,
            sim.last_contact_friction.continuous_velocity_delta.x,
            sim.last_contact_friction.continuous_velocity_delta.z,
            landing_provider_code,
            landing_approach_speed,
            landing_heading_delta,
            landing_completed_rotation,
            csv_field(&landing_admission),
            sim.manual_control.engage_seconds(),
            sim.deck_pitch,
            sim.manual_deck_contact.end.map_or("", |end| end.label()),
            sim.manual_deck_contact.endpoint_height,
            u8::from(sim.manual_deck_contact.touching),
            sim.manual_deck_contact.drag_deceleration,
            sim.manual_deck_contact.speed_loss,
        )
        .expect("writing recovered action telemetry cannot fail");
        if self.fixed_tick % FIXED_TICKS_PER_RETAIL_POLL == 0 {
            self.capture_retail_poll(input);
        }
        self.fixed_tick = self.fixed_tick.saturating_add(1);
    }

    fn capture_bones(&mut self, sim: &SkateSim, transforms: &Query<(&Name, &GlobalTransform)>) {
        let named: HashMap<_, _> = transforms
            .iter()
            .filter_map(|(name, transform)| {
                RECORDED_BONES
                    .contains(&name.as_str())
                    .then_some((name.as_str(), transform))
            })
            .collect();
        if named.len() != RECORDED_BONES.len() {
            return;
        }

        let clip = sim.animation_clip.as_deref().unwrap_or("BTREE_RIDING");
        write!(
            self.bones,
            "{},{:.9},{},{}",
            self.bone_sample,
            sim.elapsed,
            csv_field(clip),
            sim.animation_revision,
        )
        .expect("writing to an in-memory bone telemetry buffer cannot fail");
        for name in RECORDED_BONES {
            let matrix = named[name].to_matrix();
            for value in [
                matrix.x_axis.x,
                matrix.y_axis.x,
                matrix.z_axis.x,
                matrix.w_axis.x,
                matrix.x_axis.y,
                matrix.y_axis.y,
                matrix.z_axis.y,
                matrix.w_axis.y,
                matrix.x_axis.z,
                matrix.y_axis.z,
                matrix.z_axis.z,
                matrix.w_axis.z,
            ] {
                write!(self.bones, ",{value:.9}")
                    .expect("writing to an in-memory bone telemetry buffer cannot fail");
            }
        }
        self.bones.push('\n');
        self.bone_sample = self.bone_sample.saturating_add(1);
    }

    fn finish(self) {
        let replay_path = self.output.join("input-replay.json");
        let telemetry_path = self.output.join("bevy-telemetry.csv");
        let bones_path = self.output.join("bevy-bones.csv");
        let metadata_path = self.output.join("bevy-run.json");
        std::fs::write(
            &replay_path,
            serde_json::to_vec_pretty(&self.replay)
                .expect("serializing canonical replay cannot fail"),
        )
        .unwrap_or_else(|error| panic!("could not write {}: {error}", replay_path.display()));
        std::fs::write(&telemetry_path, self.telemetry.as_bytes()).unwrap_or_else(|error| {
            panic!("could not write {}: {error}", telemetry_path.display())
        });
        std::fs::write(&bones_path, self.bones.as_bytes())
            .unwrap_or_else(|error| panic!("could not write {}: {error}", bones_path.display()));
        let metadata = serde_json::json!({
            "schema": 1,
            "engine": "bevy",
            "fixed_hz": FIXED_HZ,
            "retail_input_hz": RETAIL_INPUT_HZ,
            "started_unix_ms": self.started_unix_ms,
            "finished_unix_ms": unix_millis(),
            "fixed_ticks": self.fixed_tick,
            "bone_samples": self.bone_sample,
            "bone_names": &RECORDED_BONES[..],
            "replay_steps": self.replay.len(),
            "replay_polls": self.replay.iter().map(|step| u64::from(step.polls)).sum::<u64>(),
            "replay_source": self.replay_source,
            "map": "skate_parity_grid",
        });
        std::fs::write(
            &metadata_path,
            serde_json::to_vec_pretty(&metadata).expect("serializing run metadata cannot fail"),
        )
        .unwrap_or_else(|error| panic!("could not write {}: {error}", metadata_path.display()));
        info!(
            "PARITY_RECORDING_SAVED output={} ticks={} replay_steps={}",
            self.output.display(),
            self.fixed_tick,
            self.replay.len()
        );
    }
}

#[derive(Resource, Debug)]
struct ParityRuntime {
    base_output: PathBuf,
    explicit_output: Option<PathBuf>,
    replay_start_gate: Option<PathBuf>,
    session: Option<RecordingSession>,
    replay: Option<ReplayDriver>,
    auto_record: bool,
    auto_exit: bool,
    exit_after_manual_record: bool,
}

impl ParityRuntime {
    fn from_environment() -> Self {
        let replay = std::env::var_os("SKATE3_PARITY_REPLAY")
            .map(PathBuf::from)
            .map(ReplayDriver::load);
        Self {
            base_output: PathBuf::from("parity/dual-runs"),
            explicit_output: std::env::var_os("SKATE3_PARITY_OUTPUT").map(PathBuf::from),
            replay_start_gate: std::env::var_os("SKATE3_PARITY_START_GATE").map(PathBuf::from),
            auto_record: std::env::var_os("SKATE3_PARITY_RECORD").is_some() || replay.is_some(),
            auto_exit: std::env::var_os("SKATE3_PARITY_AUTO_EXIT").is_some(),
            exit_after_manual_record: std::env::var_os("SKATE3_PARITY_EXIT_AFTER_RECORD").is_some(),
            session: None,
            replay,
        }
    }

    fn output_for_new_session(&self) -> PathBuf {
        self.explicit_output.clone().unwrap_or_else(|| {
            self.base_output
                .join(format!("run-{}", unix_millis()))
                .join("bevy")
        })
    }

    fn start(&mut self) -> PathBuf {
        if let Some(session) = &self.session {
            return session.output.clone();
        }
        let output = self.output_for_new_session();
        let replay_source = self.replay.as_ref().map(|replay| replay.source.clone());
        self.session = Some(RecordingSession::new(output.clone(), replay_source));
        output
    }

    fn replay_start_permitted(&self) -> bool {
        self.replay_start_gate
            .as_ref()
            .is_none_or(|gate| gate.is_file())
    }

    fn stop(&mut self) -> Option<PathBuf> {
        let session = self.session.take()?;
        let output = session.output.clone();
        session.finish();
        Some(output)
    }
}

fn begin_environment_recording(
    mut runtime: ResMut<ParityRuntime>,
    mut status: ResMut<ParityRecorderStatus>,
) {
    status.replaying = runtime.replay.is_some();
    if runtime.auto_record && runtime.replay_start_permitted() {
        let output = runtime.start();
        status.recording = true;
        status.output = Some(output.clone());
        status.message = format!("recording {}", output.display());
    } else if runtime.auto_record {
        status.message = format!(
            "waiting for replay start gate {}",
            runtime
                .replay_start_gate
                .as_ref()
                .expect("a blocked replay has a configured start gate")
                .display()
        );
    } else {
        status.message = "F9 starts a parity take".to_owned();
    }
}

fn toggle_recording_hotkey(
    keyboard: Res<ButtonInput<KeyCode>>,
    mut runtime: ResMut<ParityRuntime>,
    mut status: ResMut<ParityRecorderStatus>,
    mut exit: MessageWriter<AppExit>,
) {
    if !keyboard.just_pressed(KeyCode::F9) {
        return;
    }
    if runtime.session.is_some() {
        if let Some(output) = runtime.stop() {
            status.recording = false;
            status.output = Some(output.clone());
            status.message = format!("saved {}", output.display());
            if runtime.exit_after_manual_record {
                exit.write(AppExit::Success);
            }
        }
    } else {
        let output = runtime.start();
        status.recording = true;
        status.output = Some(output.clone());
        status.message = format!("recording {}", output.display());
    }
}

fn drive_parity_replay(
    mut runtime: ResMut<ParityRuntime>,
    mut status: ResMut<ParityRecorderStatus>,
    mut input: ResMut<SkateInput>,
) {
    if !runtime.replay_start_permitted() {
        return;
    }
    if runtime.replay.is_none() {
        return;
    }
    if runtime.auto_record && runtime.session.is_none() {
        let output = runtime.start();
        status.recording = true;
        status.output = Some(output.clone());
        status.message = format!("recording {}", output.display());
    }
    let Some(replay) = runtime.replay.as_mut() else {
        return;
    };
    let step = replay.advance();
    let buttons = step.buttons;
    let regular_rising = buttons & XINPUT_A != 0 && replay.previous_buttons & XINPUT_A == 0;
    let mongo_rising = buttons & XINPUT_X != 0 && replay.previous_buttons & XINPUT_X == 0;
    let toggle_rising = buttons & XINPUT_Y != 0 && replay.previous_buttons & XINPUT_Y == 0;

    input.left_stick = step.bevy_left_stick();
    input.right_stick = step.bevy_right_stick();
    input.left_trigger = step.lt as f32 / u8::MAX as f32;
    input.right_trigger = step.rt as f32 / u8::MAX as f32;
    input.observe_canonical_pad(step.canonical_pad());
    input.regular_push_held = buttons & XINPUT_A != 0;
    input.mongo_push_held = buttons & XINPUT_X != 0;
    input.brake_held = buttons & XINPUT_B != 0;
    input.toggle_offboard_pending |= toggle_rising;
    input.reset = false;
    if input.pending_push.is_none() {
        input.pending_push = if regular_rising {
            Some(PushFoot::Regular)
        } else if mongo_rising {
            Some(PushFoot::Mongo)
        } else {
            None
        };
    }
    replay.previous_buttons = buttons;
}

fn record_parity_tick(
    input: Res<SkateInput>,
    sim: Res<SkateSim>,
    mut runtime: ResMut<ParityRuntime>,
    mut status: ResMut<ParityRecorderStatus>,
) {
    let Some(session) = runtime.session.as_mut() else {
        return;
    };
    session.capture_telemetry(&input, &sim);
    status.poll = session.fixed_tick / FIXED_TICKS_PER_RETAIL_POLL;
}

fn record_parity_bones(
    transforms: Query<(&Name, &GlobalTransform)>,
    animators: Query<(), With<crate::animation::SkaterAnimator>>,
    sim: Res<SkateSim>,
    mut runtime: ResMut<ParityRuntime>,
) {
    // Do not seed the motion signature with the glTF rest pose while the
    // animation graph is still loading. Keep absolute sim_time_seconds so
    // input and retail telemetry remain on the same clock.
    if animators.is_empty() {
        return;
    }
    let Some(session) = runtime.session.as_mut() else {
        return;
    };
    session.capture_bones(&sim, &transforms);
}

fn finish_completed_auto_replay(
    mut runtime: ResMut<ParityRuntime>,
    mut status: ResMut<ParityRecorderStatus>,
    mut exit: MessageWriter<AppExit>,
) {
    let replay_complete = runtime
        .replay
        .as_ref()
        .is_some_and(|replay| replay.complete && replay.padding_ticks >= FIXED_HZ as u64);
    if !replay_complete {
        return;
    }
    if let Some(output) = runtime.stop() {
        status.recording = false;
        status.message = format!("replay complete {}", output.display());
        status.output = Some(output);
    }
    status.replaying = false;
    runtime.replay = None;
    if runtime.auto_exit {
        exit.write(AppExit::Success);
    }
}

fn flush_on_exit(
    mut exits: MessageReader<AppExit>,
    mut runtime: ResMut<ParityRuntime>,
    mut status: ResMut<ParityRecorderStatus>,
) {
    if exits.read().next().is_none() {
        return;
    }
    if let Some(output) = runtime.stop() {
        status.recording = false;
        status.output = Some(output.clone());
        status.message = format!("saved {}", output.display());
    }
}

fn unix_millis() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock must be after the Unix epoch")
        .as_millis()
}

fn csv_field(value: &str) -> String {
    if value.contains([',', '"', '\n']) {
        format!("\"{}\"", value.replace('"', "\"\""))
    } else {
        value.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replay_start_gate_blocks_until_the_capture_tool_opens_it() {
        let gate = std::env::temp_dir().join(format!("skate3-bevy-video-gate-{}", unix_millis()));
        let mut runtime = ParityRuntime {
            base_output: PathBuf::new(),
            explicit_output: None,
            replay_start_gate: Some(gate.clone()),
            session: None,
            replay: None,
            auto_record: true,
            auto_exit: false,
            exit_after_manual_record: false,
        };
        assert!(!runtime.replay_start_permitted());

        std::fs::write(&gate, b"recording\n").unwrap();
        assert!(runtime.replay_start_permitted());
        std::fs::remove_file(&gate).unwrap();

        runtime.replay_start_gate = None;
        assert!(runtime.replay_start_permitted());
    }

    #[test]
    fn replay_run_length_encoding_keeps_only_state_changes() {
        let output = std::env::temp_dir().join("skate3-bevy-parity-rle-test");
        let mut session = RecordingSession::new(output, None);
        let input = SkateInput {
            left_stick: Vec2::new(0.5, -0.25),
            canonical_pad: CanonicalPadState {
                buttons: XINPUT_A,
                left_x: 123,
                left_y: -456,
                ..default()
            },
            ..default()
        };
        session.capture_retail_poll(&input);
        session.capture_retail_poll(&input);
        assert_eq!(session.replay.len(), 1);
        assert_eq!(session.replay[0].polls, 2);
    }

    #[test]
    fn contact_friction_telemetry_keeps_header_and_row_widths_equal() {
        let output = std::env::temp_dir().join(format!(
            "skate3-bevy-contact-friction-telemetry-{}",
            unix_millis()
        ));
        let mut session = RecordingSession::new(output.clone(), None);
        session.capture_telemetry(&SkateInput::default(), &SkateSim::default());

        let mut lines = session.telemetry.lines();
        let header = lines.next().unwrap();
        let row = lines.next().unwrap();
        assert!(header.contains("contact_friction_path"));
        assert!(header.contains("contact_friction_continuous_delta_z"));
        assert_eq!(header.split(',').count(), row.split(',').count());

        std::fs::remove_dir_all(output).unwrap();
    }

    #[test]
    fn replay_step_preserves_both_bevy_processed_sticks() {
        let step = ReplayStep {
            polls: 1,
            buttons: 0,
            lt: 0,
            rt: 0,
            lx: i16::MAX,
            ly: i16::MIN,
            rx: 0,
            ry: 0,
            bevy_lx: Some(0.25),
            bevy_ly: Some(-0.75),
            bevy_rx: Some(-0.5),
            bevy_ry: Some(0.375),
        };
        assert_eq!(step.bevy_left_stick(), Vec2::new(0.25, -0.75));
        assert_eq!(step.bevy_right_stick(), Vec2::new(-0.5, 0.375));
    }

    #[test]
    fn completed_replay_releases_sticks_triggers_and_buttons() {
        let mut replay = ReplayDriver {
            source: PathBuf::new(),
            steps: Vec::new(),
            step_index: 0,
            ticks_left_in_step: 0,
            current: ReplayStep {
                polls: 1,
                buttons: XINPUT_A,
                lt: u8::MAX,
                rt: u8::MAX,
                lx: i16::MAX,
                ly: i16::MIN,
                rx: i16::MIN,
                ry: i16::MAX,
                bevy_lx: Some(1.0),
                bevy_ly: Some(-1.0),
                bevy_rx: Some(-1.0),
                bevy_ry: Some(1.0),
            },
            previous_buttons: XINPUT_A,
            complete: true,
            padding_ticks: 0,
        };

        let neutral = replay.advance();
        assert_eq!(neutral.buttons, 0);
        assert_eq!(neutral.lt, 0);
        assert_eq!(neutral.rt, 0);
        assert_eq!(neutral.bevy_left_stick(), Vec2::ZERO);
        assert_eq!(neutral.bevy_right_stick(), Vec2::ZERO);
    }

    #[test]
    fn replay_step_accepts_the_shared_sk8_frames_field() {
        let step: ReplayStep = serde_json::from_str(
            r#"{
                "label": "kickflip_charge",
                "frames": 6,
                "buttons": 0,
                "ry": -32768
            }"#,
        )
        .unwrap();

        assert_eq!(step.polls, 6);
        assert_eq!(step.ry, -32768);
    }
}
