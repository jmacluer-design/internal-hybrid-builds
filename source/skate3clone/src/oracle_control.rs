use std::{
    io::{BufRead, BufReader, Write},
    net::{TcpListener, TcpStream},
    sync::{Arc, Condvar, Mutex, MutexGuard},
    thread,
    time::{Duration, Instant},
};

use bevy::prelude::*;

use crate::camera::RetailCameraRig;
use crate::parity_recording::ParityRecorderStatus;
use crate::sim::{CanonicalPadState, PushFoot, SkateInput, SkateSim, canonical_axis_to_normalized};

pub const ORACLE_ADDRESS: &str = "127.0.0.1:38473";
const FIXED_TICKS_PER_RETAIL_FRAME: u64 = 2;
const XINPUT_START: u16 = 0x0010;
const XINPUT_A: u16 = 0x1000;
const XINPUT_B: u16 = 0x2000;
const XINPUT_X: u16 = 0x4000;
const XINPUT_Y: u16 = 0x8000;

pub struct OracleControlPlugin;

#[derive(SystemSet, Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct OracleSimulationSet;

#[derive(Resource, Clone)]
pub(crate) struct OracleControl {
    shared: Arc<SharedOracle>,
}

struct SharedOracle {
    state: Mutex<OracleState>,
    changed: Condvar,
}

#[derive(Debug)]
struct OracleState {
    paused: bool,
    input_enabled: bool,
    desired_pad: CanonicalPadState,
    previous_buttons: u16,
    fixed_permits: u64,
    fixed_ticks_completed: u64,
    retail_frames_completed: u64,
    in_flight: bool,
    snapshot: String,
}

impl Default for OracleState {
    fn default() -> Self {
        Self {
            paused: false,
            input_enabled: false,
            desired_pad: CanonicalPadState::default(),
            previous_buttons: 0,
            fixed_permits: 0,
            fixed_ticks_completed: 0,
            retail_frames_completed: 0,
            in_flight: false,
            snapshot: "snapshot_valid=0".to_owned(),
        }
    }
}

impl Plugin for OracleControlPlugin {
    fn build(&self, app: &mut App) {
        let shared = Arc::new(SharedOracle {
            state: Mutex::new(OracleState::default()),
            changed: Condvar::new(),
        });
        if std::env::var_os("SKATE3_DISABLE_ORACLE_SERVER").is_some() {
            eprintln!("BEVY_ORACLE disabled");
        } else {
            start_server(shared.clone());
        }
        app.insert_resource(OracleControl { shared })
            .configure_sets(
                FixedUpdate,
                OracleSimulationSet.run_if(simulation_permitted),
            )
            .add_systems(
                FixedUpdate,
                (
                    apply_oracle_input.before(crate::sim::fixed_step),
                    complete_oracle_fixed_tick.after(crate::camera::step_retail_camera),
                )
                    .in_set(OracleSimulationSet),
            );
    }
}

/// Keep physical input sampling out of the deterministic oracle path.
///
/// `apply_oracle_input` owns the complete canonical pad while injection is
/// enabled. Letting the normal PreUpdate sampler run at the same time inserts
/// a physical/neutral right-stick notification between lockstep frames, which
/// makes a held anticipation look like an immediate release.
pub(crate) fn physical_input_allowed(
    control: Res<OracleControl>,
    parity: Res<ParityRecorderStatus>,
) -> bool {
    let state = control.shared.state.lock().expect("oracle state poisoned");
    should_sample_physical_input(state.input_enabled, parity.replaying)
}

const fn should_sample_physical_input(
    oracle_input_enabled: bool,
    parity_replay_enabled: bool,
) -> bool {
    !oracle_input_enabled && !parity_replay_enabled
}

fn simulation_permitted(control: Res<OracleControl>) -> bool {
    let mut state = control.shared.state.lock().expect("oracle state poisoned");
    if !state.paused {
        state.in_flight = true;
        return true;
    }

    // A pause request that lands between Bevy's two 120 Hz substeps is allowed
    // to finish the pair. This keeps every externally visible boundary aligned
    // to Skate 3's 60 Hz normalized input frame.
    let finishing_partial_retail_frame =
        state.fixed_ticks_completed % FIXED_TICKS_PER_RETAIL_FRAME != 0;
    if state.fixed_permits == 0 && !finishing_partial_retail_frame {
        state.in_flight = false;
        control.shared.changed.notify_all();
        return false;
    }

    if !finishing_partial_retail_frame {
        state.fixed_permits -= 1;
    } else if state.fixed_permits != 0 {
        state.fixed_permits -= 1;
    }
    state.in_flight = true;
    true
}

fn apply_oracle_input(control: Res<OracleControl>, mut input: ResMut<SkateInput>) {
    let mut state = control.shared.state.lock().expect("oracle state poisoned");
    if !state.input_enabled {
        return;
    }

    let pad = state.desired_pad;
    let previous_buttons = state.previous_buttons;
    input.left_stick = Vec2::new(
        canonical_axis_to_normalized(pad.left_x),
        canonical_axis_to_normalized(pad.left_y),
    )
    .clamp_length_max(1.0);
    input.right_stick = Vec2::new(
        canonical_axis_to_normalized(pad.right_x),
        canonical_axis_to_normalized(pad.right_y),
    )
    .clamp_length_max(1.0);
    input.left_trigger = pad.left_trigger as f32 / u8::MAX as f32;
    input.right_trigger = pad.right_trigger as f32 / u8::MAX as f32;
    input.observe_canonical_pad(pad);
    input.regular_push_held = pad.buttons & XINPUT_A != 0;
    input.mongo_push_held = pad.buttons & XINPUT_X != 0;
    input.brake_held = pad.buttons & XINPUT_B != 0;
    input.toggle_offboard_pending |=
        pad.buttons & XINPUT_Y != 0 && previous_buttons & XINPUT_Y == 0;
    input.reset = pad.buttons & XINPUT_START != 0 && previous_buttons & XINPUT_START == 0;
    input.pending_push = if pad.buttons & XINPUT_A != 0 && previous_buttons & XINPUT_A == 0 {
        Some(PushFoot::Regular)
    } else if pad.buttons & XINPUT_X != 0 && previous_buttons & XINPUT_X == 0 {
        Some(PushFoot::Mongo)
    } else {
        None
    };
    state.previous_buttons = pad.buttons;
}

fn complete_oracle_fixed_tick(
    control: Res<OracleControl>,
    sim: Res<SkateSim>,
    camera: Res<RetailCameraRig>,
) {
    let mut state = control.shared.state.lock().expect("oracle state poisoned");
    state.fixed_ticks_completed = state.fixed_ticks_completed.saturating_add(1);
    if state.fixed_ticks_completed % FIXED_TICKS_PER_RETAIL_FRAME == 0 {
        state.retail_frames_completed = state.retail_frames_completed.saturating_add(1);
    }
    state.snapshot = snapshot_fields(&sim, &camera);
    state.in_flight = false;
    control.shared.changed.notify_all();
}

fn snapshot_fields(sim: &SkateSim, camera: &RetailCameraRig) -> String {
    let push_phase = sim
        .push
        .as_ref()
        .map_or("none", |push| push.phase.label())
        .replace(' ', "_");
    let animation = sim.animation_clip.as_deref().unwrap_or("BTREE_RIDING");
    let action = sim.action_animation_state();
    let layers = action
        .samples
        .iter()
        .map(|sample| {
            format!(
                "{}@{:.9}@{:.9}",
                sample.clip, sample.weight, sample.seek_time_seconds
            )
        })
        .collect::<Vec<_>>()
        .join("|");
    let (
        anticipation_side,
        anticipation_phase,
        anticipation_time,
        anticipation_charge,
        anticipation_compression,
        anticipation_compression_delta,
    ) = sim
        .anticipation
        .as_ref()
        .map_or(("none", "none", 0.0, 0.0, 0.0, 0.0), |runtime| {
            (
                match runtime.side {
                    crate::trick_catalog::AnticipationSide::Tail => "tail",
                    crate::trick_catalog::AnticipationSide::Nose => "nose",
                },
                runtime.phase_label(),
                runtime.phase_time_seconds,
                runtime.charge_seconds,
                runtime.compression_value,
                runtime.compression_delta,
            )
        });
    let (pop_active, pop_launch, pop_ground, pop_separated) =
        sim.pop_motion.as_ref().map_or((0, 0.0, 0.0, 0), |motion| {
            (
                1,
                motion.launch_speed,
                motion.ground_height,
                u8::from(motion.separated_from_ground),
            )
        });
    format!(
        concat!(
            "snapshot_valid=1 state={} animation={} animation_revision={} ",
            "elapsed={:.9} speed={:.9} position={:.9}:{:.9}:{:.9} ",
            "velocity={:.9}:{:.9}:{:.9} yaw={:.9} skater_yaw={:.9} view_yaw={:.9} yaw_rate={:.9} ",
            "camera_position={:.9}:{:.9}:{:.9} camera_right={:.9}:{:.9}:{:.9} ",
            "camera_up={:.9}:{:.9}:{:.9} camera_forward={:.9}:{:.9}:{:.9} ",
            "camera_yaw={:.9} camera_yaw_velocity={:.9} camera_turning={} ",
            "body_spin={:.9} body_spin_velocity={:.9} body_spin_phase={:.9} ",
            "steer={:.9} right_stick={:.9}:{:.9} triggers={:.9}:{:.9} ",
            "deck_roll={:.9} body_tilt={:.9} wheel_spin={:.9} ",
            "candidate_slide={:.9} push_phase={} action_weight={:.9} ",
            "action_layers={} board_authority={} ground_contact={} ",
            "ground_normal={:.9}:{:.9}:{:.9} ground_surface={} ",
            "flickit_samples={} flickit_cadence={} flickit_processed={:.9}:{:.9} ",
            "flickit_candidates={} flickit_publication={} flickit_contact={} ",
            "retail_flickit_notifications={} retail_flickit_cadence={} ",
            "retail_flickit_winner={} retail_flickit_contact={} ",
            "anticipation_side={} anticipation_phase={} anticipation_time={:.9} ",
            "anticipation_charge={:.9} anticipation_compression={:.9} ",
            "anticipation_compression_delta={:.9} pop_active={} pop_launch={:.9} ",
            "pop_ground={:.9} pop_separated={} landing_avgvely={:.9}"
        ),
        sim.state_label().replace(' ', "_"),
        animation,
        sim.animation_revision,
        sim.elapsed,
        sim.speed(),
        sim.position.x,
        sim.position.y,
        sim.position.z,
        sim.velocity.x,
        sim.velocity.y,
        sim.velocity.z,
        sim.yaw,
        sim.yaw + sim.visual_skater_yaw_offset(),
        sim.view_yaw,
        sim.yaw_rate,
        camera.position.x,
        camera.position.y,
        camera.position.z,
        camera.right.x,
        camera.right.y,
        camera.right.z,
        camera.up.x,
        camera.up.y,
        camera.up.z,
        camera.forward.x,
        camera.forward.y,
        camera.forward.z,
        camera.yaw,
        camera.yaw_velocity,
        u8::from(camera.turning_shot),
        sim.body_spin_angle,
        sim.body_spin_velocity,
        sim.body_spin_animation_phase_seconds,
        sim.steer,
        sim.right_stick.x,
        sim.right_stick.y,
        sim.left_trigger,
        sim.right_trigger,
        sim.deck_roll,
        sim.body_tilt,
        sim.wheel_spin,
        sim.candidate_slide_weight,
        push_phase,
        action.weight,
        layers,
        sim.board_authority.label(),
        u8::from(sim.ground_contact_valid),
        sim.ground_normal.x,
        sim.ground_normal.y,
        sim.ground_normal.z,
        sim.ground_surface_id
            .map_or_else(|| "none".to_owned(), |surface| surface.to_string()),
        sim.trick_input.probe_sample_count,
        sim.trick_input.cadence_label(),
        sim.trick_input.processed_sample().x,
        sim.trick_input.processed_sample().y,
        sim.trick_input.geometry_candidate_count(),
        sim.trick_input.publication_status_label(),
        sim.trick_input.selected_contact_label(),
        sim.trick_input.retail_notification_count,
        sim.trick_input.retail_cadence_label(),
        sim.trick_input.retail_winner_name().unwrap_or("none"),
        sim.trick_input.retail_selected_contact_label(),
        anticipation_side,
        anticipation_phase,
        anticipation_time,
        anticipation_charge,
        anticipation_compression,
        anticipation_compression_delta,
        pop_active,
        pop_launch,
        pop_ground,
        pop_separated,
        sim.landing_average_velocity_y,
    )
}

fn start_server(shared: Arc<SharedOracle>) {
    thread::Builder::new()
        .name("bevy-dual-oracle".to_owned())
        .spawn(move || {
            let listener = match TcpListener::bind(ORACLE_ADDRESS) {
                Ok(listener) => listener,
                Err(error) => {
                    eprintln!("BEVY_ORACLE bind_failed address={ORACLE_ADDRESS} error={error}");
                    return;
                }
            };
            eprintln!("BEVY_ORACLE listening address={ORACLE_ADDRESS}");
            for stream in listener.incoming() {
                match stream {
                    Ok(stream) => serve_client(&shared, stream),
                    Err(error) => eprintln!("BEVY_ORACLE accept_failed error={error}"),
                }
            }
        })
        .expect("could not start Bevy dual-oracle server");
}

fn serve_client(shared: &SharedOracle, mut stream: TcpStream) {
    let mut command = String::new();
    {
        let mut reader = BufReader::new(&mut stream);
        if reader.read_line(&mut command).is_err() {
            return;
        }
    }
    let response = handle_command(shared, command.trim());
    let _ = writeln!(stream, "{response}");
    let _ = stream.flush();
}

fn handle_command(shared: &SharedOracle, command: &str) -> String {
    if command == "PING" {
        return "OK PONG".to_owned();
    }
    if command == "STATUS" || command == "ORACLE STATUS" {
        let state = shared.state.lock().expect("oracle state poisoned");
        return format!("OK {}", status_fields(&state));
    }
    if command == "CAPSULE_SNAPSHOT" || command == "SNAPSHOT" {
        let state = shared.state.lock().expect("oracle state poisoned");
        return format!(
            "OK protocol=1 engine=bevy fixed_tick={} retail_frame={} {}",
            state.fixed_ticks_completed, state.retail_frames_completed, state.snapshot
        );
    }
    if command == "ORACLE RUN" {
        let mut state = shared.state.lock().expect("oracle state poisoned");
        state.paused = false;
        state.fixed_permits = 0;
        shared.changed.notify_all();
        return format!("OK {}", status_fields(&state));
    }
    if command == "ORACLE PAUSE" {
        return pause_at_boundary(shared);
    }
    if let Some(count) = command.strip_prefix("ORACLE STEP ") {
        return step_retail_frames(shared, count);
    }
    if command == "DISABLE" || command == "CLEAR" {
        let mut state = shared.state.lock().expect("oracle state poisoned");
        state.input_enabled = false;
        state.desired_pad = CanonicalPadState::default();
        state.previous_buttons = 0;
        return "OK disabled".to_owned();
    }
    if let Some(encoded) = command.strip_prefix("SET REPLACE ") {
        let pad = match parse_pad(encoded) {
            Ok(pad) => pad,
            Err(error) => return format!("ERR {error}"),
        };
        let mut state = shared.state.lock().expect("oracle state poisoned");
        state.desired_pad = pad;
        state.input_enabled = true;
        return "OK state held".to_owned();
    }
    "ERR unknown command".to_owned()
}

fn pause_at_boundary(shared: &SharedOracle) -> String {
    let mut state = shared.state.lock().expect("oracle state poisoned");
    state.paused = true;
    state.fixed_permits = 0;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if !state.in_flight && state.fixed_ticks_completed % FIXED_TICKS_PER_RETAIL_FRAME == 0 {
            return format!("OK {}", status_fields(&state));
        }
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            return "ERR oracle pause timed out before a retail frame boundary".to_owned();
        };
        let (next, result) = shared
            .changed
            .wait_timeout(state, remaining)
            .expect("oracle state poisoned");
        state = next;
        if result.timed_out() {
            return "ERR oracle pause timed out before a retail frame boundary".to_owned();
        }
    }
}

fn step_retail_frames(shared: &SharedOracle, encoded_count: &str) -> String {
    let requested = match encoded_count.parse::<u64>() {
        Ok(value @ 1..=3600) => value,
        _ => return "ERR oracle step count must be between 1 and 3600".to_owned(),
    };
    let mut state = shared.state.lock().expect("oracle state poisoned");
    if !state.paused
        || state.in_flight
        || state.fixed_ticks_completed % FIXED_TICKS_PER_RETAIL_FRAME != 0
    {
        return "ERR oracle must be paused at a retail frame boundary".to_owned();
    }
    let target = state.retail_frames_completed.saturating_add(requested);
    state.fixed_permits = state
        .fixed_permits
        .saturating_add(requested * FIXED_TICKS_PER_RETAIL_FRAME);
    let deadline = Instant::now() + Duration::from_secs(5) + Duration::from_millis(requested * 50);
    loop {
        if state.retail_frames_completed >= target
            && state.fixed_permits == 0
            && !state.in_flight
            && state.fixed_ticks_completed % FIXED_TICKS_PER_RETAIL_FRAME == 0
        {
            return format!("OK stepped={requested} {}", status_fields(&state));
        }
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            return "ERR oracle step timed out".to_owned();
        };
        let (next, result) = shared
            .changed
            .wait_timeout(state, remaining)
            .expect("oracle state poisoned");
        state = next;
        if result.timed_out() {
            return "ERR oracle step timed out".to_owned();
        }
    }
}

fn status_fields(state: &MutexGuard<'_, OracleState>) -> String {
    let waiting = state.paused
        && state.fixed_permits == 0
        && !state.in_flight
        && state.fixed_ticks_completed % FIXED_TICKS_PER_RETAIL_FRAME == 0;
    format!(
        concat!(
            "protocol=1 engine=bevy endpoint={} input_enabled={} paused={} ",
            "waiting={} in_flight={} permits={} fixed_tick={} retail_frame={}"
        ),
        ORACLE_ADDRESS,
        state.input_enabled as u8,
        state.paused as u8,
        waiting as u8,
        state.in_flight as u8,
        state.fixed_permits,
        state.fixed_ticks_completed,
        state.retail_frames_completed,
    )
}

fn parse_pad(encoded: &str) -> Result<CanonicalPadState, &'static str> {
    let fields = encoded.split(',').collect::<Vec<_>>();
    if fields.len() != 7 {
        return Err("state needs buttons,lt,rt,lx,ly,rx,ry");
    }
    let buttons = parse_integer(fields[0], 0, u16::MAX as i64)? as u16;
    let left_trigger = parse_integer(fields[1], 0, u8::MAX as i64)? as u8;
    let right_trigger = parse_integer(fields[2], 0, u8::MAX as i64)? as u8;
    let left_x = parse_integer(fields[3], i16::MIN as i64, i16::MAX as i64)? as i16;
    let left_y = parse_integer(fields[4], i16::MIN as i64, i16::MAX as i64)? as i16;
    let right_x = parse_integer(fields[5], i16::MIN as i64, i16::MAX as i64)? as i16;
    let right_y = parse_integer(fields[6], i16::MIN as i64, i16::MAX as i64)? as i16;
    Ok(CanonicalPadState {
        buttons,
        left_trigger,
        right_trigger,
        left_x,
        left_y,
        right_x,
        right_y,
    })
}

fn parse_integer(text: &str, minimum: i64, maximum: i64) -> Result<i64, &'static str> {
    let text = text.trim();
    let (negative, unsigned) = text
        .strip_prefix('-')
        .map_or((false, text), |value| (true, value));
    let (radix, digits) = unsigned
        .strip_prefix("0x")
        .or_else(|| unsigned.strip_prefix("0X"))
        .map_or((10, unsigned), |value| (16, value));
    let magnitude = i64::from_str_radix(digits, radix).map_err(|_| "invalid state value")?;
    let value = if negative { -magnitude } else { magnitude };
    if !(minimum..=maximum).contains(&value) {
        return Err("state value outside valid XInput range");
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_decimal_and_hex_xinput_packets() {
        let pad = parse_pad("0x1000,0,255,-32768,32767,0,1").unwrap();
        assert_eq!(pad.buttons, XINPUT_A);
        assert_eq!(pad.right_trigger, 255);
        assert_eq!(pad.left_x, i16::MIN);
        assert_eq!(pad.left_y, i16::MAX);
    }

    #[test]
    fn rejects_out_of_range_packets() {
        assert!(parse_pad("0,0,0,32768,0,0,0").is_err());
        assert!(parse_pad("0,0,0,0,0,0").is_err());
    }

    #[test]
    fn deterministic_input_owners_exclude_the_physical_sampler() {
        assert!(!should_sample_physical_input(true, false));
        assert!(!should_sample_physical_input(false, true));
        assert!(!should_sample_physical_input(true, true));
        assert!(should_sample_physical_input(false, false));
    }
}
