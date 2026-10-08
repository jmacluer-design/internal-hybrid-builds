use std::collections::{HashMap, HashSet};
use std::ffi::OsString;

use bevy::animation::AnimationTargetId;
use bevy::prelude::*;
use bevy::{asset::LoadState, gltf::Gltf};

use crate::fakie::{
    FAKIE_CLIP_DURATION_SECONDS, FAKIE_RIDING_CLIP, SWITCH_NEUTRAL_STYLE_ZERO_CLIP,
};
use crate::manual_animation::{MANUAL_VISUAL_CLIPS, manual_visual_native_fps};
use crate::manual_graph::ManualKind;
use crate::sim::{
    ActionAnimationState, AnimationSample, BODY_SPIN_BACKSIDE_CLIP, BODY_SPIN_FRONTSIDE_CLIP,
    SkateSim,
};
use crate::trick_catalog::physical_clip_by_name;

pub const MODEL_PATH: &str = "private/default_skate3_skater.glb";
pub const MODEL_PATH_ENV: &str = "SKATE3_PRIVATE_MODEL_PATH";
pub const VISUAL_MODEL_PATH: &str = "private/default_skate3_skater.glb";
pub const VISUAL_MODEL_PATH_ENV: &str = "SKATE3_PRIVATE_VISUAL_MODEL_PATH";
pub const MANUAL_MODEL_PATH: &str = "manual://skater_rig.glb";
const RIDE_LEFT: &str = "R_IDLE_HCOM_N100";
const RIDE_NEUTRAL: &str = "R_IDLE_HCOM_000";
const RIDE_RIGHT: &str = "R_IDLE_HCOM_P100";
const BODY_SPIN_LOWER_BODY_MASK_GROUP: u32 = 0;
const BODY_SPIN_MASKED_ONBOARD_TARGETS: [&str; 4] = [
    "RIGHTTOEBASE_REPARENTED",
    "LEFTTOEBASE_REPARENTED",
    "RIGHTHAND_REPARENTED",
    "LEFTHAND_REPARENTED",
];
/// Blender places the first imported ABIN sample on frame 1 and exports the
/// mixed-rate action bank on a 60 Hz scene timeline.
const PRIVATE_GLTF_TIMELINE_HZ: f32 = 60.0;
pub const NO_TAIL_SWAY_DIAGNOSTIC_ENV: &str = "SKATE3_DIAGNOSTIC_NO_TAIL_SWAY";
pub const TAIL_TURN_ONLY_DIAGNOSTIC_ENV: &str = "SKATE3_DIAGNOSTIC_TAIL_TURN_ONLY";
pub const MIRRORED_ACTION_PREFIX: &str = "MIRRORED__";
pub const FAKIE_ACTION_PREFIX: &str = "RETAIL__B_FAKIE_CHANNEL__";
const SWITCH_RIDE_LEFT: &str = "MIRRORED__R_IDLE_HCOM_N100";
const SWITCH_RIDE_NEUTRAL: &str = "MIRRORED__R_IDLE_HCOM_000";
const SWITCH_RIDE_RIGHT: &str = "MIRRORED__R_IDLE_HCOM_P100";
const LOWER_BODY_MASK_GROUP: u32 = 0;
pub const FORCE_FAKIE_PREVIEW_ENV: &str = "SKATE3_FORCE_FAKIE_PREVIEW";

#[derive(Resource, Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AnimationDiagnostics {
    pub tail_manual_sway_forced_off: bool,
    pub tail_manual_turn_only: bool,
}

impl AnimationDiagnostics {
    pub fn from_environment() -> Self {
        Self {
            tail_manual_sway_forced_off: std::env::var_os(NO_TAIL_SWAY_DIAGNOSTIC_ENV)
                .is_some_and(|value| value != "0"),
            tail_manual_turn_only: std::env::var_os(TAIL_TURN_ONLY_DIAGNOSTIC_ENV)
                .is_some_and(|value| value != "0"),
        }
    }
}

#[derive(Resource, Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AnimationPreviewMode {
    pub force_fakie: bool,
}

impl AnimationPreviewMode {
    pub fn from_environment() -> Self {
        Self {
            force_fakie: std::env::var_os(FORCE_FAKIE_PREVIEW_ENV).is_some(),
        }
    }
}

#[derive(Resource)]
pub struct SkateModel {
    pub gltf: Handle<Gltf>,
    pub visual_gltf: Handle<Gltf>,
    pub asset_path: String,
    pub visual_asset_path: String,
    pub manual_gltf: Handle<Gltf>,
}

#[derive(Resource)]
pub struct SkateAnimationRig {
    pub graph: Handle<AnimationGraph>,
    pub nodes: HashMap<String, AnimationNodeIndex>,
    pub clip_count: usize,
}

#[derive(Component, Default)]
pub struct SkaterAnimator {
    active_nodes: HashSet<AnimationNodeIndex>,
    missing_clips_reported: HashSet<String>,
}

#[derive(Clone, Copy)]
struct DesiredNode {
    weight: f32,
    seek_time_seconds: f32,
}

pub fn load_model(mut commands: Commands, asset_server: Res<AssetServer>) {
    let asset_path = configured_model_path(std::env::var_os(MODEL_PATH_ENV));
    let visual_asset_path = configured_visual_model_path(std::env::var_os(VISUAL_MODEL_PATH_ENV));
    let working_directory = std::env::current_dir()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|error| format!("<unavailable: {error}>"));
    eprintln!(
        "ASSET_BOOT cwd={working_directory} animation_model={asset_path} \
         visual_model={visual_asset_path}"
    );
    commands.insert_resource(SkateModel {
        gltf: asset_server.load(asset_path.clone()),
        visual_gltf: asset_server.load(visual_asset_path.clone()),
        asset_path,
        visual_asset_path,
        manual_gltf: asset_server.load(MANUAL_MODEL_PATH),
    });
}

pub fn build_animation_graph(
    mut commands: Commands,
    model: Res<SkateModel>,
    asset_server: Res<AssetServer>,
    gltfs: Res<Assets<Gltf>>,
    mut graphs: ResMut<Assets<AnimationGraph>>,
    existing: Option<Res<SkateAnimationRig>>,
    mut load_failure_reported: Local<bool>,
    mut previous_load_state: Local<String>,
) {
    if existing.is_some() {
        return;
    }
    let Some(gltf) = gltfs.get(&model.gltf) else {
        let load_state = format!("{:?}", asset_server.get_load_state(model.gltf.id()));
        if *previous_load_state != load_state {
            eprintln!(
                "ANIMATION_GRAPH_LOAD_STATE path={} state={load_state}",
                model.asset_path
            );
            *previous_load_state = load_state;
        }
        if !*load_failure_reported
            && let Some(LoadState::Failed(error)) = asset_server.get_load_state(model.gltf.id())
        {
            eprintln!(
                "ANIMATION_GRAPH_LOAD_FAILED path={} error={error}",
                model.asset_path
            );
            *load_failure_reported = true;
        }
        return;
    };
    let Some(visual_gltf) = gltfs.get(&model.visual_gltf) else {
        let load_state = format!("{:?}", asset_server.get_load_state(model.visual_gltf.id()));
        if *previous_load_state != load_state {
            eprintln!(
                "ANIMATION_GRAPH_LOAD_STATE path={} state={load_state}",
                model.visual_asset_path
            );
            *previous_load_state = load_state;
        }
        if !*load_failure_reported
            && let Some(LoadState::Failed(error)) =
                asset_server.get_load_state(model.visual_gltf.id())
        {
            eprintln!(
                "ANIMATION_GRAPH_LOAD_FAILED path={} error={error}",
                model.visual_asset_path
            );
            *load_failure_reported = true;
        }
        return;
    };
    let Some(manual_gltf) = gltfs.get(&model.manual_gltf) else {
        let load_state = format!("{:?}", asset_server.get_load_state(model.manual_gltf.id()));
        if *previous_load_state != load_state {
            eprintln!("ANIMATION_GRAPH_LOAD_STATE path={MANUAL_MODEL_PATH} state={load_state}");
            *previous_load_state = load_state;
        }
        if !*load_failure_reported
            && let Some(LoadState::Failed(error)) =
                asset_server.get_load_state(model.manual_gltf.id())
        {
            eprintln!("ANIMATION_GRAPH_LOAD_FAILED path={MANUAL_MODEL_PATH} error={error}");
            *load_failure_reported = true;
        }
        return;
    };

    // Every retail leaf remains independently addressable. Runtime weights are
    // supplied by the recovered motion-graph state instead of selecting one
    // nearest leaf.
    let mut graph = AnimationGraph::new();
    let mut nodes = HashMap::new();
    // The animation carrier remains authoritative. The textured retail skater
    // contributes only actions absent from that carrier (currently the latest
    // expanded grab family), and the decoded manual bank fills its own leaves.
    // All three assets share the recovered RX2 target hierarchy.
    for source in [gltf, visual_gltf, manual_gltf] {
        let mut names: Vec<_> = source.named_animations.keys().cloned().collect();
        names.sort();
        for name in names {
            if nodes.contains_key(name.as_ref()) {
                continue;
            }
            let Some(clip) = source.named_animations.get(&name) else {
                continue;
            };
            let mask = if is_body_spin_clip(&name) {
                1 << BODY_SPIN_LOWER_BODY_MASK_GROUP
            } else {
                0
            };
            let node = graph.add_clip_with_mask(clip.clone(), mask, 1.0, graph.root);
            nodes.insert(name.to_string(), node);
        }
    }
    add_body_spin_lower_body_mask(&mut graph);

    let base_required = [
        RIDE_LEFT,
        RIDE_NEUTRAL,
        RIDE_RIGHT,
        SWITCH_RIDE_LEFT,
        SWITCH_RIDE_NEUTRAL,
        SWITCH_RIDE_RIGHT,
        FAKIE_RIDING_CLIP,
        SWITCH_NEUTRAL_STYLE_ZERO_CLIP,
    ];
    let missing_base = base_required.iter().any(|name| !nodes.contains_key(*name));
    let missing_manual = MANUAL_VISUAL_CLIPS
        .iter()
        .any(|(name, _)| !nodes.contains_key(*name));
    if missing_base || missing_manual {
        error!("Private GLB banks are missing required riding, fakie, or manual clips");
        return;
    }
    let clip_count = nodes.len();
    eprintln!(
        "ANIMATION_GRAPH_READY clips={clip_count} path={} manual_path={MANUAL_MODEL_PATH}",
        model.asset_path
    );
    if let Some(path) = std::env::var_os("SKATE3_ANIMATION_READY_FILE") {
        let path = std::path::PathBuf::from(path);
        if let Some(parent) = path.parent()
            && let Err(error) = std::fs::create_dir_all(parent)
        {
            eprintln!(
                "ANIMATION_GRAPH_READY_FILE_FAILED path={} error={error}",
                path.display()
            );
        } else if let Err(error) = std::fs::write(
            &path,
            format!("clips={clip_count} path={}\n", model.asset_path),
        ) {
            eprintln!(
                "ANIMATION_GRAPH_READY_FILE_FAILED path={} error={error}",
                path.display()
            );
        }
    }
    commands.insert_resource(SkateAnimationRig {
        graph: graphs.add(graph),
        nodes,
        clip_count,
    });
}

pub fn attach_animator(
    mut commands: Commands,
    rig: Option<Res<SkateAnimationRig>>,
    mut players: Query<(Entity, &mut AnimationPlayer), Without<SkaterAnimator>>,
) {
    let Some(rig) = rig else {
        return;
    };
    for (entity, mut player) in &mut players {
        let mut animator = SkaterAnimator::default();
        for name in [RIDE_LEFT, RIDE_NEUTRAL, RIDE_RIGHT] {
            let node = rig.nodes[name];
            player
                .play(node)
                .repeat()
                .pause()
                .set_weight(if name == RIDE_NEUTRAL { 1.0 } else { 0.0 });
            animator.active_nodes.insert(node);
        }
        commands
            .entity(entity)
            .insert((AnimationGraphHandle(rig.graph.clone()), animator));
    }
}

pub fn drive_animation_graph(
    sim: Res<SkateSim>,
    diagnostics: Res<AnimationDiagnostics>,
    time: Res<Time>,
    preview: Res<AnimationPreviewMode>,
    rig: Option<Res<SkateAnimationRig>>,
    mut players: Query<(&mut AnimationPlayer, &mut SkaterAnimator)>,
) {
    let Some(rig) = rig else {
        return;
    };
    let desired_by_name = if preview.force_fakie {
        vec![forced_fakie_animation_sample(time.elapsed_secs())]
    } else {
        let action = sim.action_animation_state();
        desired_animation_samples(&sim, &action, *diagnostics)
    };

    for (mut player, mut animator) in &mut players {
        let mut desired_nodes = HashMap::new();
        for sample in &desired_by_name {
            let Some(node) = rig.nodes.get(&sample.clip).copied() else {
                if animator.missing_clips_reported.insert(sample.clip.clone()) {
                    error!(
                        "Retail animation leaf is missing from private GLB: {}",
                        sample.clip
                    );
                }
                continue;
            };
            desired_nodes
                .entry(node)
                .and_modify(|desired: &mut DesiredNode| desired.weight += sample.weight)
                .or_insert(DesiredNode {
                    weight: sample.weight,
                    seek_time_seconds: sample.seek_time_seconds,
                });
        }
        let stale: Vec<_> = animator
            .active_nodes
            .iter()
            .copied()
            .filter(|node| !desired_nodes.contains_key(node))
            .collect();
        for node in stale {
            player.stop(node);
            animator.active_nodes.remove(&node);
        }

        for (node, desired) in desired_nodes {
            if !player.is_playing_animation(node) {
                player.play(node).repeat().pause();
                animator.active_nodes.insert(node);
            }
            if let Some(active) = player.animation_mut(node) {
                // The retail StateGraph is evaluated on the fixed simulation
                // clock. Pausing Bevy's autonomous clock and seeking every
                // frame prevents render cadence from changing sequence phase.
                active
                    .pause()
                    .set_weight(desired.weight.max(0.0))
                    .set_seek_time(desired.seek_time_seconds.max(0.0));
            }
        }
    }
}

fn forced_fakie_animation_sample(elapsed_seconds: f32) -> AnimationSample {
    let retail_phase = elapsed_seconds
        .max(0.0)
        .rem_euclid(FAKIE_CLIP_DURATION_SECONDS);
    AnimationSample {
        clip: FAKIE_RIDING_CLIP.to_owned(),
        weight: 1.0,
        seek_time_seconds: private_gltf_seek_time(FAKIE_RIDING_CLIP, retail_phase),
    }
}

fn desired_animation_samples(
    sim: &SkateSim,
    action: &ActionAnimationState,
    diagnostics: AnimationDiagnostics,
) -> Vec<AnimationSample> {
    let action_weight = action.weight.clamp(0.0, 1.0);
    let riding_weight = 1.0 - action_weight;
    let [left, neutral, right] = body_tilt_weights(sim.riding_animation_source_tilt());
    let ride_clips = if sim.stance_source_is_pre_mirrored() {
        [SWITCH_RIDE_LEFT, SWITCH_RIDE_NEUTRAL, SWITCH_RIDE_RIGHT]
    } else {
        [RIDE_LEFT, RIDE_NEUTRAL, RIDE_RIGHT]
    };
    let mut desired = vec![
        AnimationSample {
            clip: ride_clips[0].to_owned(),
            weight: left * riding_weight,
            seek_time_seconds: sim.ride_phase_time,
        },
        AnimationSample {
            clip: ride_clips[1].to_owned(),
            weight: neutral * riding_weight,
            seek_time_seconds: sim.ride_phase_time,
        },
        AnimationSample {
            clip: ride_clips[2].to_owned(),
            weight: right * riding_weight,
            seek_time_seconds: sim.ride_phase_time,
        },
    ];

    let source_weight: f32 = action
        .samples
        .iter()
        .filter(|sample| !is_body_spin_clip(&sample.clip))
        .map(|sample| sample.weight.max(0.0))
        .sum();
    if source_weight > f32::EPSILON && action_weight > 0.0 {
        desired.extend(
            action
                .samples
                .iter()
                .filter(|sample| !is_body_spin_clip(&sample.clip))
                .map(|sample| AnimationSample {
                    clip: sample.clip.clone(),
                    weight: action_weight * sample.weight.max(0.0) / source_weight,
                    seek_time_seconds: private_gltf_seek_time(
                        &sample.clip,
                        diagnostic_manual_seek_time(
                            sim,
                            &sample.clip,
                            sample.seek_time_seconds,
                            diagnostics,
                        ),
                    ),
                }),
        );
        // Retail BodySpin is a parallel animation behaviour. Its authored
        // clips animate the upper body, but their physical leaves also carry
        // compact OnBoard target channels. The mask keeps HIPS, legs, board,
        // and all board-contact targets owned by the underlying action, so
        // this independent weight cannot move the grab target that IK uses.
        desired.extend(
            action
                .samples
                .iter()
                .filter(|sample| is_body_spin_clip(&sample.clip))
                .map(|sample| AnimationSample {
                    clip: sample.clip.clone(),
                    weight: action_weight * sample.weight.max(0.0),
                    seek_time_seconds: private_gltf_seek_time(
                        &sample.clip,
                        sample.seek_time_seconds,
                    ),
                }),
        );
    }
    desired = apply_fakie_channel_to_samples(desired, sim.fakie.animation_channel_weight());
    for sample in &mut desired {
        sample.clip = stance_resolved_action_name(
            &sample.clip,
            sim.should_use_mirrored_character_animation(),
        );
    }
    desired
}

fn diagnostic_manual_seek_time(
    sim: &SkateSim,
    clip: &str,
    seek_time_seconds: f32,
    diagnostics: AnimationDiagnostics,
) -> f32 {
    let tail_manual_active = sim
        .manual
        .as_ref()
        .is_some_and(|manual| manual.runtime.kind == ManualKind::Tail);
    let manual_leaf = manual_visual_native_fps(clip).is_some();
    let freeze_all_tail = diagnostics.tail_manual_sway_forced_off;
    let freeze_neutral_tail = diagnostics.tail_manual_turn_only && !clip.contains("_TURN_");
    if tail_manual_active && manual_leaf && (freeze_all_tail || freeze_neutral_tail) {
        // Diagnostic A/B mode only: pin every authored regular-manual leaf to
        // its first ABIN sample, or pin only neutral leaves while leaving the
        // FS/BS turn leaves live. Physics-owned deck pitch/contact and the
        // nose manual graph remain live. This is intentionally not a parity
        // rule.
        0.0
    } else {
        seek_time_seconds
    }
}

fn is_body_spin_clip(name: &str) -> bool {
    matches!(
        base_action_name(name),
        BODY_SPIN_BACKSIDE_CLIP | BODY_SPIN_FRONTSIDE_CLIP
    )
}

fn mirrored_action_name(name: &str) -> String {
    format!("{MIRRORED_ACTION_PREFIX}{name}")
}

fn unmirrored_action_name(name: &str) -> &str {
    name.strip_prefix(MIRRORED_ACTION_PREFIX).unwrap_or(name)
}

fn base_action_name(name: &str) -> &str {
    let name = unmirrored_action_name(name);
    if name == FAKIE_RIDING_CLIP {
        return RIDE_NEUTRAL;
    }
    name.strip_prefix(FAKIE_ACTION_PREFIX).unwrap_or(name)
}

fn fakie_action_name(name: &str) -> String {
    if name == FAKIE_RIDING_CLIP || name.starts_with(FAKIE_ACTION_PREFIX) {
        return name.to_owned();
    }
    if let Some(unmirrored) = name.strip_prefix(MIRRORED_ACTION_PREFIX) {
        return mirrored_action_name(&fakie_action_name(unmirrored));
    }
    if name == RIDE_NEUTRAL {
        FAKIE_RIDING_CLIP.to_owned()
    } else {
        format!("{FAKIE_ACTION_PREFIX}{name}")
    }
}

fn apply_fakie_channel_to_samples(
    samples: Vec<AnimationSample>,
    channel_weight: f32,
) -> Vec<AnimationSample> {
    let channel_weight = channel_weight.clamp(0.0, 1.0);
    if channel_weight <= f32::EPSILON {
        return samples;
    }
    let mut result = Vec::with_capacity(samples.len() * 2);
    for sample in samples {
        if sample.weight <= f32::EPSILON {
            continue;
        }
        if sample.clip == FAKIE_RIDING_CLIP
            || unmirrored_action_name(&sample.clip).starts_with(FAKIE_ACTION_PREFIX)
        {
            result.push(sample);
            continue;
        }
        if channel_weight < 1.0 {
            result.push(AnimationSample {
                weight: sample.weight * (1.0 - channel_weight),
                ..sample.clone()
            });
        }
        result.push(AnimationSample {
            clip: fakie_action_name(&sample.clip),
            weight: sample.weight * channel_weight,
            ..sample
        });
    }
    result
}

fn longitudinal_mirror_source_name(name: &str) -> String {
    let (prefix, base) = if name == FAKIE_RIDING_CLIP {
        return name.to_owned();
    } else if let Some(base) = name.strip_prefix(FAKIE_ACTION_PREFIX) {
        (FAKIE_ACTION_PREFIX, base)
    } else {
        ("", name)
    };
    let counterpart = if let Some(suffix) = base.strip_prefix("OLLIE_") {
        format!("NOLLIE_{suffix}")
    } else if let Some(suffix) = base.strip_prefix("NOLLIE_") {
        format!("OLLIE_{suffix}")
    } else {
        base.to_owned()
    };
    format!("{prefix}{counterpart}")
}

/// Resolve Andale's final pose mirror against the selected source action.
///
/// B_SWITCH transition-under frames already use a mirrored source. Toggling
/// that source must therefore remove the prefix, while ordinary source
/// actions gain it. This is the action-bank equivalent of an involutive
/// post-evaluation `AnimCommandSystem::Mirror` call.
fn stance_resolved_action_name(name: &str, toggle_mirror: bool) -> String {
    if !toggle_mirror {
        return name.to_owned();
    }
    if let Some(unmirrored) = name.strip_prefix(MIRRORED_ACTION_PREFIX) {
        unmirrored.to_owned()
    } else {
        // AnimCommandSystem::Mirror receives TrajectoryUse as well as the
        // skeleton command. The distinct retail OLLIE/NOLLIE trajectory
        // leaves provide the physical nose/tail counterpart when the stance
        // operation reverses the body along the board.
        mirrored_action_name(&longitudinal_mirror_source_name(name))
    }
}

fn add_body_spin_lower_body_mask(graph: &mut AnimationGraph) {
    const PATHS: &[&[&str]] = &[
        &["Skate3_RX2_Rig", "HIPS"],
        &["Skate3_RX2_Rig", "HIPS", "RIGHTUPLEG"],
        &["Skate3_RX2_Rig", "HIPS", "RIGHTUPLEG", "RIGHTLEG"],
        &[
            "Skate3_RX2_Rig",
            "HIPS",
            "RIGHTUPLEG",
            "RIGHTLEG",
            "RIGHTFOOT",
        ],
        &[
            "Skate3_RX2_Rig",
            "HIPS",
            "RIGHTUPLEG",
            "RIGHTLEG",
            "RIGHTFOOT",
            "RIGHTTOEBASE",
        ],
        &["Skate3_RX2_Rig", "HIPS", "LEFTUPLEG"],
        &["Skate3_RX2_Rig", "HIPS", "LEFTUPLEG", "LEFTLEG"],
        &["Skate3_RX2_Rig", "HIPS", "LEFTUPLEG", "LEFTLEG", "LEFTFOOT"],
        &[
            "Skate3_RX2_Rig",
            "HIPS",
            "LEFTUPLEG",
            "LEFTLEG",
            "LEFTFOOT",
            "LEFTTOEBASE",
        ],
        &["Skate3_RX2_Rig", "SKATEBOARD_ROOT"],
        &["Skate3_RX2_Rig", "SKATEBOARD_ROOT", "TRUCK_FRONT"],
        &[
            "Skate3_RX2_Rig",
            "SKATEBOARD_ROOT",
            "TRUCK_FRONT",
            "RIGHT_WHEELFRONT",
        ],
        &[
            "Skate3_RX2_Rig",
            "SKATEBOARD_ROOT",
            "TRUCK_FRONT",
            "LEFT_WHEELFRONT",
        ],
        &["Skate3_RX2_Rig", "SKATEBOARD_ROOT", "TRUCK_BACK"],
        &[
            "Skate3_RX2_Rig",
            "SKATEBOARD_ROOT",
            "TRUCK_BACK",
            "RIGHT_WHEELBACK",
        ],
        &[
            "Skate3_RX2_Rig",
            "SKATEBOARD_ROOT",
            "TRUCK_BACK",
            "LEFT_WHEELBACK",
        ],
    ];
    for path in PATHS {
        let names = path.iter().map(|name| Name::new(*name)).collect::<Vec<_>>();
        graph.add_target_to_mask_group(
            AnimationTargetId::from_names(names.iter()),
            LOWER_BODY_MASK_GROUP,
        );
    }
    for target in BODY_SPIN_MASKED_ONBOARD_TARGETS {
        let names = [
            Name::new("Skate3_RX2_Rig"),
            Name::new("SKATEBOARD_ROOT"),
            Name::new(target),
        ];
        graph.add_target_to_mask_group(
            AnimationTargetId::from_names(names.iter()),
            BODY_SPIN_LOWER_BODY_MASK_GROUP,
        );
    }
}

fn configured_model_path(value: Option<OsString>) -> String {
    value
        .and_then(|value| value.into_string().ok())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| MODEL_PATH.to_owned())
}

fn configured_visual_model_path(value: Option<OsString>) -> String {
    value
        .and_then(|value| value.into_string().ok())
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| VISUAL_MODEL_PATH.to_owned())
}

fn private_gltf_seek_time(clip: &str, retail_time_seconds: f32) -> f32 {
    let is_legacy_fakie_ride = unmirrored_action_name(clip) == FAKIE_RIDING_CLIP;
    let clip = base_action_name(clip);
    if clip.starts_with("KICKFLIP_IN_")
        || clip.starts_with("HEELFLIP_IN_")
        || clip.starts_with("N_KICKFLIP_IN_")
        || clip.starts_with("N_HEELFLIP_IN_")
        || clip.starts_with("360FLIP_D_")
        || clip.starts_with("COMBINED_KICKFLIP_")
        || clip.starts_with("COMBINED_HEELFLIP_")
        || is_physical_flip_loop_action(clip)
        || is_legacy_fakie_ride
    {
        return (retail_time_seconds.max(0.0) * PRIVATE_GLTF_TIMELINE_HZ + 1.0)
            / PRIVATE_GLTF_TIMELINE_HZ;
    }
    if let Some(native_fps) = crate::grab_animation::grab_clip_native_fps(clip) {
        let sample_position = retail_time_seconds.max(0.0) * native_fps as f32;
        return (sample_position + 1.0) / PRIVATE_GLTF_TIMELINE_HZ;
    }
    let native_fps = physical_clip_by_name(clip)
        .map(|entry| entry.native_fps)
        .or_else(|| manual_visual_native_fps(clip));
    let Some(native_fps) = native_fps else {
        return retail_time_seconds.max(0.0);
    };
    let sample_position = retail_time_seconds.max(0.0) * native_fps as f32;
    (sample_position + 1.0) / PRIVATE_GLTF_TIMELINE_HZ
}

fn is_physical_flip_loop_action(clip: &str) -> bool {
    const PREFIXES: [&str; 16] = [
        "T_LOW_KICK_",
        "T_HI_KICK_",
        "T_KICKFLIP_LOW_4FLIPS_0_OUT",
        "T_KICKFLIP_HI_4FLIPS_0_OUT",
        "T_LOW_HEEL_",
        "T_HI_HEEL_",
        "T_HEELFLIP_LOW_4FLIPS_0_OUT",
        "T_HEELFLIP_HI_4FLIPS_0_OUT",
        "T_LOW_N_KICK_",
        "T_HI_N_KICK_",
        "T_N_KICKFLIP_LOW_4FLIPS_0_OUT",
        "T_N_KICKFLIP_HI_4FLIPS_0_OUT",
        "T_LOW_N_HEEL_",
        "T_HI_N_HEEL_",
        "T_N_HEELFLIP_LOW_4FLIPS_0_OUT",
        "T_N_HEELFLIP_HI_4FLIPS_0_OUT",
    ];
    PREFIXES.iter().any(|prefix| clip.starts_with(prefix))
}

fn body_tilt_weights(body_tilt: f32) -> [f32; 3] {
    let body_tilt = body_tilt.clamp(-1.0, 1.0);
    [
        (-body_tilt).max(0.0),
        1.0 - body_tilt.abs(),
        body_tilt.max(0.0),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn body_spin_mask_preserves_all_board_contact_targets_for_post_animation_ik() {
        let mut graph = AnimationGraph::new();
        add_body_spin_lower_body_mask(&mut graph);

        for target in BODY_SPIN_MASKED_ONBOARD_TARGETS {
            let names = [
                Name::new("Skate3_RX2_Rig"),
                Name::new("SKATEBOARD_ROOT"),
                Name::new(target),
            ];
            let id = AnimationTargetId::from_names(names.iter());
            assert_eq!(
                graph.mask_groups.get(&id).copied(),
                Some(1 << BODY_SPIN_LOWER_BODY_MASK_GROUP),
                "{target} must remain owned by the underlying OnBoard action"
            );
        }
    }

    #[test]
    fn hcom_weights_are_normalized_and_use_adjacent_clips() {
        assert_eq!(body_tilt_weights(-1.0), [1.0, 0.0, 0.0]);
        assert_eq!(body_tilt_weights(0.0), [0.0, 1.0, 0.0]);
        assert_eq!(body_tilt_weights(1.0), [0.0, 0.0, 1.0]);

        let weights = body_tilt_weights(-0.35);
        assert_eq!(weights[2], 0.0);
        assert!((weights.iter().sum::<f32>() - 1.0).abs() < f32::EPSILON);
    }

    #[test]
    fn riding_and_action_layers_always_sum_to_one() {
        let mut sim = SkateSim::default();
        sim.body_tilt = -0.35;
        let action = ActionAnimationState {
            samples: vec![
                AnimationSample {
                    clip: "A".to_owned(),
                    weight: 0.25,
                    seek_time_seconds: 0.1,
                },
                AnimationSample {
                    clip: "B".to_owned(),
                    weight: 0.75,
                    seek_time_seconds: 0.2,
                },
            ],
            weight: 0.6,
        };
        let desired = desired_animation_samples(&sim, &action, AnimationDiagnostics::default());
        assert!((desired.iter().map(|sample| sample.weight).sum::<f32>() - 1.0).abs() < 1.0e-6);
    }

    #[test]
    fn manual_clips_seek_through_the_exported_sixty_hz_scene_clock() {
        assert!(
            (private_gltf_seek_time("M_IDLE_N_0_CYC", 99.0 / 30.0) - 100.0 / 60.0).abs()
                < f32::EPSILON
        );
        assert!(
            (private_gltf_seek_time("M_NOSEBRAKE_N_0_CYC", 44.0 / 30.0) - 45.0 / 60.0).abs()
                < f32::EPSILON
        );
    }

    #[test]
    fn private_abin_samples_map_to_the_exported_sixty_hertz_timeline() {
        assert!(
            (private_gltf_seek_time("R_ANTIC_OLLIE_N_0_INTO", 0.0) - 1.0 / 60.0).abs() < 1.0e-6
        );
        assert!(
            (private_gltf_seek_time("R_ANTIC_OLLIE_N_0_INTO", 14.0 / 30.0) - 15.0 / 60.0).abs()
                < 1.0e-6
        );
        assert!((private_gltf_seek_time("OLLIE_HIGH_G", 12.0 / 60.0) - 13.0 / 60.0).abs() < 1.0e-6);
        assert!(
            (private_gltf_seek_time("KICKFLIP_IN_LOW_G", 12.0 / 60.0) - 13.0 / 60.0).abs() < 1.0e-6
        );
        assert!(
            (private_gltf_seek_time("N_HEELFLIP_IN_HIGH_A", 12.0 / 60.0) - 13.0 / 60.0).abs()
                < 1.0e-6
        );
        assert!(
            (private_gltf_seek_time("T_LOW_KICK_CYC1", 12.0 / 60.0) - 13.0 / 60.0).abs() < 1.0e-6
        );
        assert!(
            (private_gltf_seek_time("T_N_HEELFLIP_HI_4FLIPS_0_OUT3", 12.0 / 60.0) - 13.0 / 60.0)
                .abs()
                < 1.0e-6
        );
        assert!(
            (private_gltf_seek_time("360FLIP_D_HIGH_A", 12.0 / 60.0) - 13.0 / 60.0).abs() < 1.0e-6
        );
        assert!(
            (private_gltf_seek_time(FAKIE_RIDING_CLIP, 24.0 / 30.0) - 49.0 / 60.0).abs() < 1.0e-6
        );
        assert_eq!(private_gltf_seek_time("R_IDLE_HCOM_000", 0.25), 0.25);
    }

    #[test]
    fn private_model_override_is_explicit_and_empty_values_use_the_default() {
        assert_eq!(configured_model_path(None), MODEL_PATH);
        assert_eq!(configured_model_path(Some(OsString::new())), MODEL_PATH);
        assert_eq!(
            configured_model_path(Some(OsString::from(
                "private/skater_push.360-flip-candidate.glb"
            ))),
            "private/skater_push.360-flip-candidate.glb"
        );
    }

    #[test]
    fn every_live_grab_family_uses_its_native_thirty_hertz_clock() {
        for clip in [
            "GR_GRAB_N_BS_0_INTO",
            "GR_NOSEGRAB_N_BS_0_INTO",
            "1FT_AIR_GRAB_N_FSL_0_INTO",
            "GR_DSMNT_SUPER_DBL_0_INTO",
            "GR_DSMNT_N_NOFOOT_TO_SUPER",
            "GR_GROUND_N_COFFIN_0_INTO",
        ] {
            assert_eq!(
                crate::grab_animation::grab_clip_native_fps(clip),
                Some(30),
                "{clip}"
            );
            assert!(
                (private_gltf_seek_time(clip, 9.0 / 30.0) - 10.0 / 60.0).abs() < 1.0e-6,
                "{clip}"
            );
        }
    }

    #[test]
    fn private_visual_model_override_is_separate_from_the_animation_bank() {
        assert_eq!(configured_visual_model_path(None), VISUAL_MODEL_PATH);
        assert_eq!(
            configured_visual_model_path(Some(OsString::new())),
            VISUAL_MODEL_PATH
        );
        assert_eq!(
            configured_visual_model_path(Some(OsString::from("private/custom_visual.glb"))),
            "private/custom_visual.glb"
        );
        assert_eq!(VISUAL_MODEL_PATH, MODEL_PATH);
    }

    #[test]
    fn forced_fakie_preview_is_the_baked_retail_channel_composition() {
        let start = forced_fakie_animation_sample(0.0);
        assert_eq!(start.clip, FAKIE_RIDING_CLIP);
        assert_eq!(start.weight, 1.0);
        assert!((start.seek_time_seconds - 1.0 / 60.0).abs() < 1.0e-6);

        let repeated = forced_fakie_animation_sample(FAKIE_CLIP_DURATION_SECONDS + 12.0 / 30.0);
        assert_eq!(repeated.clip, FAKIE_RIDING_CLIP);
        assert_eq!(repeated.weight, 1.0);
        assert!((repeated.seek_time_seconds - 25.0 / 60.0).abs() < 1.0e-6);
    }

    #[test]
    fn riding_fakie_selects_the_retail_weighted_channel_composition() {
        let mut sim = SkateSim::default();
        sim.fakie.phase = crate::fakie::FakiePhase::RidingFakie;
        for _ in 0..120 {
            sim.fakie.step(1.0 / crate::sim::FIXED_HZ as f32, true);
        }
        let desired = desired_animation_samples(
            &sim,
            &sim.action_animation_state(),
            AnimationDiagnostics::default(),
        );

        assert_eq!(
            desired
                .iter()
                .find(|sample| sample.clip == RIDE_NEUTRAL)
                .map(|sample| sample.weight),
            None
        );
        assert_eq!(
            desired
                .iter()
                .find(|sample| sample.clip == FAKIE_RIDING_CLIP)
                .map(|sample| sample.weight),
            Some(1.0)
        );
    }

    #[test]
    fn committed_action_uses_its_action_relative_fakie_composition() {
        let mut sim = SkateSim::default();
        sim.fakie.phase = crate::fakie::FakiePhase::RidingFakie;
        for _ in 0..120 {
            sim.fakie.step(1.0 / crate::sim::FIXED_HZ as f32, true);
        }
        let desired = desired_animation_samples(
            &sim,
            &ActionAnimationState {
                samples: vec![AnimationSample {
                    clip: "LANDING".to_owned(),
                    weight: 1.0,
                    seek_time_seconds: 0.1,
                }],
                weight: 1.0,
            },
            AnimationDiagnostics::default(),
        );

        assert_eq!(desired.len(), 1);
        assert!(desired.iter().any(|sample| {
            sample.clip == "RETAIL__B_FAKIE_CHANNEL__LANDING"
                && (sample.weight - 1.0).abs() < 1.0e-6
        }));
        assert!(
            !desired
                .iter()
                .any(|sample| sample.clip == FAKIE_RIDING_CLIP)
        );
    }

    #[test]
    fn airborne_fakie_channel_blends_without_replacing_the_trick_with_idle() {
        let mut sim = SkateSim::default();
        sim.fakie.phase = crate::fakie::FakiePhase::RidingFakie;
        sim.fakie
            .step(crate::fakie::FAKIE_CHANNEL_BLEND_SECONDS * 0.5, true);
        let desired = desired_animation_samples(
            &sim,
            &ActionAnimationState {
                samples: vec![AnimationSample {
                    clip: "OLLIE_LOW_A".to_owned(),
                    weight: 1.0,
                    seek_time_seconds: 0.2,
                }],
                weight: 1.0,
            },
            AnimationDiagnostics::default(),
        );

        assert!(desired.iter().any(|sample| {
            sample.clip == "OLLIE_LOW_A" && (sample.weight - 0.5).abs() < 1.0e-6
        }));
        assert!(desired.iter().any(|sample| {
            sample.clip == "RETAIL__B_FAKIE_CHANNEL__OLLIE_LOW_A"
                && (sample.weight - 0.5).abs() < 1.0e-6
        }));
        assert!(
            !desired
                .iter()
                .any(|sample| sample.clip == FAKIE_RIDING_CLIP)
        );
    }

    #[test]
    fn retail_idle_phase_is_taken_from_fixed_simulation_state() {
        let sim = SkateSim::default();
        let desired = desired_animation_samples(
            &sim,
            &ActionAnimationState::default(),
            AnimationDiagnostics::default(),
        );
        assert!(
            desired
                .iter()
                .all(|sample| sample.seek_time_seconds == sim.ride_phase_time)
        );
        assert_eq!(
            desired
                .iter()
                .find(|sample| sample.clip == RIDE_NEUTRAL)
                .map(|sample| sample.weight),
            Some(1.0)
        );
    }

    #[test]
    fn diagnostic_mode_freezes_only_regular_manual_animation_time() {
        let mut sim = SkateSim::default();
        assert!(sim.begin_manual(
            crate::manual_graph::ManualEntryContext {
                manual: -0.5,
                manual_engage_time_seconds: 0.201,
                ..default()
            },
            -2.0,
        ));
        let diagnostics = AnimationDiagnostics {
            tail_manual_sway_forced_off: true,
            ..default()
        };
        assert_eq!(
            diagnostic_manual_seek_time(&sim, "M_IDLE_N_0_CYC", 1.25, diagnostics),
            0.0
        );
        assert_eq!(
            diagnostic_manual_seek_time(&sim, "M_BRAKE_N_0_CYC", 0.75, diagnostics),
            0.0
        );
        assert_eq!(
            diagnostic_manual_seek_time(&sim, "R_IDLE_HCOM_000", 1.25, diagnostics),
            1.25
        );

        sim.manual.as_mut().unwrap().runtime.kind = ManualKind::Nose;
        assert_eq!(
            diagnostic_manual_seek_time(&sim, "M_NOSEIDLE_N_0_CYC", 1.25, diagnostics),
            1.25
        );
    }

    #[test]
    fn completed_shuffle_selects_the_complete_mirrored_action_bank() {
        let mut sim = SkateSim::default();
        sim.fakie.riding_switch = true;
        let desired = desired_animation_samples(
            &sim,
            &ActionAnimationState::default(),
            AnimationDiagnostics::default(),
        );

        assert!(sim.should_use_mirrored_character_animation());
        assert_eq!(
            desired
                .iter()
                .find(|sample| sample.weight > 0.0)
                .map(|sample| sample.clip.as_str()),
            Some(SWITCH_RIDE_NEUTRAL)
        );
    }

    #[test]
    fn turn_only_diagnostic_freezes_neutral_tail_but_advances_fs_bs_leaves() {
        let mut sim = SkateSim::default();
        assert!(sim.begin_manual(
            crate::manual_graph::ManualEntryContext {
                manual: -0.5,
                manual_engage_time_seconds: 0.201,
                ..default()
            },
            -2.0,
        ));
        let diagnostics = AnimationDiagnostics {
            tail_manual_turn_only: true,
            ..default()
        };
        assert_eq!(
            diagnostic_manual_seek_time(&sim, "M_IDLE_N_0_CYC", 1.25, diagnostics),
            0.0
        );
        assert_eq!(
            diagnostic_manual_seek_time(&sim, "M_IDLE_N_0_TURN_FS_0_CYC", 1.25, diagnostics),
            1.25
        );
        assert_eq!(
            diagnostic_manual_seek_time(&sim, "M_IDLE_N_0_TURN_BS_0_CYC", 1.25, diagnostics),
            1.25
        );
    }

    #[test]
    fn switch_transition_under_uses_the_proven_baked_endpoint_pose() {
        let mut sim = SkateSim::default();
        sim.fakie.riding_switch = true;
        sim.fakie.switch_out_elapsed_seconds = Some(0.0);
        let desired = desired_animation_samples(
            &sim,
            &ActionAnimationState::default(),
            AnimationDiagnostics::default(),
        );

        assert!(!sim.should_use_mirrored_character_animation());
        assert_eq!(
            desired
                .iter()
                .find(|sample| sample.weight > 0.0)
                .map(|sample| sample.clip.as_str()),
            Some(SWITCH_RIDE_NEUTRAL)
        );
    }

    #[test]
    fn fakie_and_goofy_each_invert_the_source_carve_coordinate_once() {
        let mut sim = SkateSim::default();
        sim.body_tilt = 0.7;
        let regular = desired_animation_samples(
            &sim,
            &ActionAnimationState::default(),
            AnimationDiagnostics::default(),
        );
        assert_eq!(
            regular
                .iter()
                .find(|sample| sample.weight > 0.0 && sample.clip == RIDE_RIGHT)
                .map(|sample| sample.weight),
            Some(0.7)
        );

        sim.fakie.phase = crate::fakie::FakiePhase::RidingFakie;
        let fakie = desired_animation_samples(
            &sim,
            &ActionAnimationState::default(),
            AnimationDiagnostics::default(),
        );
        assert_eq!(
            fakie
                .iter()
                .find(|sample| sample.weight > 0.0 && sample.clip == RIDE_LEFT)
                .map(|sample| sample.weight),
            Some(0.7)
        );

        sim.fakie.phase = crate::fakie::FakiePhase::Regular;
        sim.fakie.riding_switch = true;
        let goofy = desired_animation_samples(
            &sim,
            &ActionAnimationState::default(),
            AnimationDiagnostics::default(),
        );
        assert_eq!(
            goofy
                .iter()
                .find(|sample| sample.weight > 0.0 && sample.clip == SWITCH_RIDE_LEFT)
                .map(|sample| sample.weight),
            Some(0.7)
        );
    }

    #[test]
    fn goofy_stance_mirrors_tricks_landings_and_fakie_composition() {
        let mut sim = SkateSim::default();
        sim.fakie.riding_switch = true;
        let action = ActionAnimationState {
            samples: vec![
                AnimationSample {
                    clip: "COMBINED_HEELFLIP_LOW_G".to_owned(),
                    weight: 0.75,
                    seek_time_seconds: 0.1,
                },
                AnimationSample {
                    clip: "L_LAND_HIGH_AGGR_1_N".to_owned(),
                    weight: 0.25,
                    seek_time_seconds: 0.2,
                },
            ],
            weight: 1.0,
        };
        let desired = desired_animation_samples(&sim, &action, AnimationDiagnostics::default());

        assert!(desired.iter().any(|sample| {
            sample.clip == "MIRRORED__COMBINED_HEELFLIP_LOW_G"
                && (sample.weight - 0.75).abs() < 1.0e-6
        }));
        assert!(desired.iter().any(|sample| {
            sample.clip == "MIRRORED__L_LAND_HIGH_AGGR_1_N" && (sample.weight - 0.25).abs() < 1.0e-6
        }));

        sim.fakie.phase = crate::fakie::FakiePhase::RidingFakie;
        for _ in 0..120 {
            sim.fakie.step(1.0 / crate::sim::FIXED_HZ as f32, true);
        }
        let fakie = desired_animation_samples(
            &sim,
            &sim.action_animation_state(),
            AnimationDiagnostics::default(),
        );
        assert!(fakie.iter().any(|sample| {
            sample.clip == format!("{MIRRORED_ACTION_PREFIX}{FAKIE_RIDING_CLIP}")
                && sample.weight > 0.0
        }));
    }

    #[test]
    fn stance_action_resolution_is_an_involution_for_transition_under_sources() {
        assert_eq!(
            stance_resolved_action_name("OLLIE_LOW_G", true),
            "MIRRORED__NOLLIE_LOW_G"
        );
        assert_eq!(
            stance_resolved_action_name("NOLLIE_HIGH_A", true),
            "MIRRORED__OLLIE_HIGH_A"
        );
        assert_eq!(
            stance_resolved_action_name("RETAIL__B_FAKIE_CHANNEL__OLLIE_LOW_A", true),
            "MIRRORED__RETAIL__B_FAKIE_CHANNEL__NOLLIE_LOW_A"
        );
        assert_eq!(
            stance_resolved_action_name("MIRRORED__OLLIE_LOW_G", true),
            "OLLIE_LOW_G"
        );
        assert_eq!(
            stance_resolved_action_name("MIRRORED__OLLIE_LOW_G", false),
            "MIRRORED__OLLIE_LOW_G"
        );
    }
}
