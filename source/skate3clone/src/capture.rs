use std::{fmt::Write as _, path::PathBuf};

use bevy::{
    app::AppExit,
    prelude::*,
    render::view::screenshot::{Screenshot, save_to_disk},
};

use crate::{
    animation::SkateAnimationRig,
    sim::{PushFoot, SkateInput, SkateSim},
};

const CAPTURES: &[(u64, &str)] = &[
    (90, "01_idle_riding.png"),
    (205, "02_hard_push_contact.png"),
    (430, "03_carve.png"),
    (535, "04_moving_brake.png"),
    (835, "05_powerslide.png"),
    (885, "06_powerslide_out.png"),
    (1480, "07_random_idle.png"),
];

pub struct CaptureSuitePlugin {
    output: PathBuf,
}

impl CaptureSuitePlugin {
    pub fn from_environment() -> Option<Self> {
        if std::env::var_os("SKATE3_CAPTURE_SUITE").is_none() {
            return None;
        }
        let output = std::env::var_os("SKATE3_CAPTURE_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("parity/captures/latest"));
        Some(Self { output })
    }
}

impl Plugin for CaptureSuitePlugin {
    fn build(&self, app: &mut App) {
        std::fs::create_dir_all(&self.output)
            .unwrap_or_else(|error| panic!("could not create capture output: {error}"));
        app.insert_resource(CaptureSuite {
            output: self.output.clone(),
            trace: "fixed_tick,state,animation_clip,speed_mps,position_x,position_z,yaw_radians,stick_x,stick_y,brake_hold_seconds,brake_active,powerslide_degrees,deck_roll_radians,wheel_spin_radians\n".to_owned(),
            ..default()
        })
        .add_systems(
            PreUpdate,
            drive_capture_input.after(crate::sim::sample_input),
        )
        .add_systems(
            FixedUpdate,
            record_capture_tick.after(crate::sim::fixed_step),
        )
        .add_systems(
            Update,
            (capture_checkpoint_frames, finish_capture_suite).chain(),
        );
    }
}

#[derive(Resource, Default)]
struct CaptureSuite {
    output: PathBuf,
    fixed_tick: u64,
    next_capture: usize,
    first_push_sent: bool,
    first_reset_sent: bool,
    second_push_sent: bool,
    second_reset_sent: bool,
    frames_after_last_capture: u32,
    trace: String,
    trace_saved: bool,
}

fn drive_capture_input(mut suite: ResMut<CaptureSuite>, mut input: ResMut<SkateInput>) {
    input.left_stick = Vec2::ZERO;
    input.regular_push_held = false;
    input.mongo_push_held = false;
    input.brake_held = false;

    let tick = suite.fixed_tick;
    if tick >= 120 && !suite.first_push_sent {
        input.pending_push = Some(PushFoot::Regular);
        suite.first_push_sent = true;
    }
    if (360..=470).contains(&tick) {
        input.left_stick = Vec2::X * 0.75;
    }
    if (490..=590).contains(&tick) {
        input.brake_held = true;
    }

    if tick >= 680 && !suite.first_reset_sent {
        input.reset = true;
        suite.first_reset_sent = true;
    }
    if tick >= 700 && !suite.second_push_sent {
        input.pending_push = Some(PushFoot::Regular);
        suite.second_push_sent = true;
    }
    if (795..=925).contains(&tick) {
        input.left_stick = Vec2::new(0.447, -0.894);
    }

    if tick >= 1080 && !suite.second_reset_sent {
        input.reset = true;
        suite.second_reset_sent = true;
    }
}

fn record_capture_tick(mut suite: ResMut<CaptureSuite>, sim: Res<SkateSim>) {
    let clip = sim.animation_clip.as_deref().unwrap_or("BTREE_RIDING");
    let fixed_tick = suite.fixed_tick;
    writeln!(
        suite.trace,
        "{},{},{},{:.6},{:.6},{:.6},{:.6},{:.6},{:.6},{:.6},{},{:.6},{:.6},{:.6}",
        fixed_tick,
        sim.state_label().replace(',', " "),
        clip,
        sim.speed(),
        sim.position.x,
        sim.position.z,
        sim.yaw,
        sim.left_stick.x,
        sim.left_stick.y,
        sim.brake_hold_time,
        u8::from(sim.brake_active),
        sim.powerslide_rotation.to_degrees(),
        sim.deck_roll,
        sim.wheel_spin,
    )
    .expect("writing to an in-memory trace cannot fail");
    suite.fixed_tick = suite.fixed_tick.wrapping_add(1);
}

fn capture_checkpoint_frames(
    mut commands: Commands,
    rig: Option<Res<SkateAnimationRig>>,
    mut suite: ResMut<CaptureSuite>,
) {
    if rig.is_none() || suite.next_capture >= CAPTURES.len() {
        return;
    }
    let (capture_tick, filename) = CAPTURES[suite.next_capture];
    if suite.fixed_tick < capture_tick {
        return;
    }

    let output = suite.output.join(filename);
    info!(
        "SKATE3_CAPTURE tick={} path={}",
        suite.fixed_tick,
        output.display()
    );
    commands
        .spawn(Screenshot::primary_window())
        .observe(save_to_disk(output));
    suite.next_capture += 1;
}

fn finish_capture_suite(mut suite: ResMut<CaptureSuite>, mut exit: MessageWriter<AppExit>) {
    if suite.next_capture < CAPTURES.len() {
        return;
    }
    if !suite.trace_saved {
        let trace_path = suite.output.join("runtime-trace.csv");
        std::fs::write(&trace_path, suite.trace.as_bytes())
            .unwrap_or_else(|error| panic!("could not save {}: {error}", trace_path.display()));
        suite.trace_saved = true;
    }
    suite.frames_after_last_capture += 1;
    if suite.frames_after_last_capture >= 120 {
        info!(
            "SKATE3_CAPTURE_SUITE_COMPLETE output={}",
            suite.output.display()
        );
        exit.write(AppExit::Success);
    }
}
