mod air_trick_animation;
mod air_trick_graph;
mod animation;
mod anticipation_graph;
mod basic_trick_graph;
mod board;
mod board_authority;
mod camera;
mod capture;
mod character_lighting;
mod contact_friction;
mod fakie;
mod foot_ik;
mod foot_placement;
mod grab_animation;
mod grab_graph;
mod grind_chromosome;
mod grind_contact;
mod grind_graph;
mod ground_provider;
mod hand_ik;
mod landing_animation;
mod landing_graph;
mod manual_animation;
mod manual_balance;
mod manual_contact;
mod manual_control;
mod manual_graph;
mod offboard;
mod offboard_animation;
mod oracle_control;
mod parity_recording;
mod retail_push;
mod retail_skateboard;
mod riding_forces;
mod sim;
mod skateboard_body;
mod skateboard_solver;
mod stance;
mod transition;
mod trick_animation;
mod trick_catalog;
mod trick_input;
mod university;

use std::time::Duration;

use animation::{AnimationPreviewMode, SkateAnimationRig, SkateModel};
use bevy::app::ScheduleRunnerPlugin;
use bevy::asset::{AssetMetaCheck, io::AssetSourceBuilder};
use bevy::camera::Exposure;
use bevy::gltf::GltfAssetLabel;
use bevy::prelude::*;
use bevy::render::{
    RenderPlugin,
    settings::{Backends, InstanceFlags, RenderCreation, WgpuSettings},
};
use sim::{FIXED_HZ, LevelSpawn, SkateGround, SkateInput, SkateSim};
use stance::NaturalStance;
use university::{
    ActiveLevel, RETAIL_LIGHTMAP_VIEW_EV100, UNIVERSITY_AMBIENT_BRIGHTNESS, UniversityLoad,
};

const PARITY_MAP_PATH: &str = "parity/skate_parity_grid.glb";

#[derive(Component)]
pub(crate) struct SkaterRoot;

#[derive(Component)]
struct FollowCamera;

#[derive(Component)]
struct StatusText;

fn main() {
    if std::env::args().any(|argument| argument == "--verify-university") {
        if let Err(error) = university::verify_headless() {
            eprintln!("University headless verification failed: {error}");
            std::process::exit(1);
        }
        return;
    }
    if std::env::var_os("SKATE3_HEADLESS_REPLAY").is_some() {
        run_headless_replay();
        return;
    }

    let active_level = ActiveLevel::selected();
    let university = if active_level == ActiveLevel::University {
        match UniversityLoad::load_and_validate() {
            Ok(load) => Some(load),
            Err(error) => {
                eprintln!("University load failed: {error}");
                std::process::exit(1);
            }
        }
    } else {
        None
    };
    let capture_suite = capture::CaptureSuitePlugin::from_environment();
    let animation_diagnostics = animation::AnimationDiagnostics::from_environment();
    let animation_preview = AnimationPreviewMode::from_environment();
    if animation_preview.force_fakie {
        eprintln!(
            "FORCED_FAKIE_PREVIEW_ENABLED virtual=B_FAKIE_CHANNEL \
             base=R_IDLE_HCOM_000 leaf=FAKIE_CHANNEL_CYC \
             weights=SPINE2:.5,SPINE3:.7,NECK:1,NECK1:1,HEAD:1"
        );
    }
    let mut app = App::new();
    let manual_asset_directory = std::env::var_os("SKATE3_MANUAL_ASSET_DIR")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| {
            std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("assets")
                .join("private")
                .join("manual")
        });
    let manual_asset_directory = manual_asset_directory.to_string_lossy().into_owned();
    app.register_asset_source(
        "manual",
        AssetSourceBuilder::platform_default(&manual_asset_directory, None),
    );
    app.add_plugins(
        DefaultPlugins
            .set(AssetPlugin {
                meta_check: AssetMetaCheck::Never,
                ..default()
            })
            .set(RenderPlugin {
                render_creation: RenderCreation::Automatic(WgpuSettings {
                    // DX12 currently trips a wgpu binding-layout assertion on
                    // the RTX 5090. Vulkan renders correctly; its latest SDK
                    // validation layer rejects otherwise valid generated
                    // atomics, so development validation is disabled here.
                    backends: Some(Backends::VULKAN),
                    instance_flags: InstanceFlags::empty(),
                    ..default()
                }),
                ..default()
            }),
    )
    .insert_resource(Time::<Fixed>::from_hz(FIXED_HZ))
    .insert_resource(active_level)
    .insert_resource(animation_diagnostics)
    .insert_resource(animation_preview)
    .init_resource::<SkateInput>()
    .init_resource::<camera::RetailCameraRig>()
    .add_plugins(board::BoardPlugin)
    .add_plugins(oracle_control::OracleControlPlugin)
    .add_plugins(parity_recording::ParityRecordingPlugin)
    .add_systems(
        Startup,
        (
            configure_natural_stance,
            animation::load_model,
            setup_world,
            university::spawn_university_world.run_if(resource_equals(ActiveLevel::University)),
        )
            .chain(),
    )
    .add_observer(character_lighting::tag_skater_scene_descendants)
    .add_systems(
        PreUpdate,
        (
            sim::sample_input.run_if(oracle_control::physical_input_allowed),
            animation::build_animation_graph,
            animation::attach_animator,
        ),
    )
    .add_systems(
        FixedUpdate,
        (
            sim::fixed_step,
            camera::step_retail_camera.after(sim::fixed_step),
        )
            .in_set(oracle_control::OracleSimulationSet),
    )
    .add_systems(
        Update,
        (
            sync_skater_transform,
            camera::apply_retail_camera,
            university::follow_university_sky
                .after(camera::apply_retail_camera)
                .run_if(resource_equals(ActiveLevel::University)),
            animation::drive_animation_graph,
            sim::log_gamepad_inventory,
            update_status,
        ),
    );
    if let Some(load) = university {
        let spawn = LevelSpawn {
            position: load.sim.position,
            yaw: load.sim.yaw,
        };
        app.insert_resource(load.ground)
            .insert_resource(load.sim)
            .insert_resource(spawn)
            .insert_resource(load.level.grind_rails.clone())
            .insert_resource(load.level);
    } else {
        app.init_resource::<SkateSim>()
            .init_resource::<SkateGround>()
            .init_resource::<LevelSpawn>();
    }
    if let Some(capture_suite) = capture_suite {
        app.add_plugins(capture_suite);
    }
    app.run();
}

fn run_headless_replay() {
    let mut app = App::new();
    app.add_plugins(
        MinimalPlugins.set(ScheduleRunnerPlugin::run_loop(Duration::from_secs_f64(
            1.0 / FIXED_HZ,
        ))),
    )
    .insert_resource(Time::<Fixed>::from_hz(FIXED_HZ))
    .init_resource::<ButtonInput<KeyCode>>()
    .init_resource::<SkateInput>()
    .init_resource::<SkateSim>()
    .init_resource::<SkateGround>()
    .add_plugins(parity_recording::ParityRecordingPlugin)
    .add_systems(FixedUpdate, sim::fixed_step);
    app.run();
}

fn configure_natural_stance(mut sim: ResMut<SkateSim>) {
    let Some(value) = std::env::var_os("SKATE3_NATURAL_STANCE") else {
        return;
    };
    let value = value.to_string_lossy();
    sim.natural_stance = if value.eq_ignore_ascii_case("goofy") {
        NaturalStance::Goofy
    } else if value.eq_ignore_ascii_case("regular") {
        NaturalStance::Regular
    } else {
        warn!("Ignoring SKATE3_NATURAL_STANCE={value:?}; expected regular or goofy");
        return;
    };
    info!(
        "NATURAL_STANCE configured={} riding={}",
        sim.natural_stance.label(),
        sim.riding_stance().label()
    );
}

fn setup_world(
    mut commands: Commands,
    asset_server: Res<AssetServer>,
    model: Res<SkateModel>,
    active_level: Res<ActiveLevel>,
    preview: Res<AnimationPreviewMode>,
) {
    commands.insert_resource(ClearColor(Color::srgb(0.035, 0.045, 0.055)));
    if *active_level == ActiveLevel::University {
        // Retail baked lightmaps remain authoritative. This low-energy,
        // cool-neutral fill is the explicit Bevy ambient requested for the
        // non-lightmapped skater and supplies the recovered tree shader's
        // otherwise-missing minimum illumination.
        commands.insert_resource(GlobalAmbientLight {
            color: Color::srgb(0.72, 0.79, 0.88),
            brightness: UNIVERSITY_AMBIENT_BRIGHTNESS,
            affects_lightmapped_meshes: true,
        });
    } else {
        commands.insert_resource(GlobalAmbientLight {
            color: Color::srgb(0.70, 0.78, 0.88),
            brightness: 900.0,
            affects_lightmapped_meshes: true,
        });
        commands.spawn((
            Name::new("Canonical Skate Parity Grid"),
            SceneRoot(asset_server.load(GltfAssetLabel::Scene(0).from_asset(PARITY_MAP_PATH))),
            Transform::default(),
        ));
        commands.spawn((
            DirectionalLight {
                illuminance: 18_000.0,
                shadows_enabled: true,
                ..default()
            },
            Transform::from_rotation(Quat::from_euler(EulerRot::XYZ, -0.85, -0.55, 0.0)),
        ));
        commands.spawn((
            PointLight {
                intensity: 1_100_000.0,
                range: 30.0,
                color: Color::srgb(1.0, 0.76, 0.55),
                shadows_enabled: false,
                ..default()
            },
            Transform::from_xyz(-7.0, 8.0, -4.0),
        ));
    }

    commands
        .spawn((SkaterRoot, Transform::IDENTITY, Visibility::default()))
        .with_children(|root| {
            root.spawn((
                SceneRoot(
                    asset_server
                        .load(GltfAssetLabel::Scene(0).from_asset(model.visual_asset_path.clone())),
                ),
                Transform::IDENTITY,
            ));
        });

    let camera_exposure = if *active_level == ActiveLevel::University {
        // The decoded retail lightmaps are already in SK8's world-pass
        // lighting domain. Bevy's default physical exposure (~0.001) would
        // apply an extra attenuation and reduce the map to silhouettes.
        Exposure {
            ev100: RETAIL_LIGHTMAP_VIEW_EV100,
        }
    } else {
        Exposure::default()
    };
    let mut camera = commands.spawn((
        FollowCamera,
        Camera3d::default(),
        camera_exposure,
        Projection::Perspective(PerspectiveProjection {
            fov: camera::RETAIL_HIGH_VERTICAL_FOV,
            far: if *active_level == ActiveLevel::University {
                5_000.0
            } else {
                1_000.0
            },
            ..default()
        }),
        Transform::from_xyz(0.0, 2.7, -6.2).looking_at(Vec3::new(0.0, 1.0, 1.5), Vec3::Y),
    ));
    if *active_level == ActiveLevel::University {
        camera.insert(character_lighting::university_camera_render_layers());
        camera.with_child(character_lighting::university_fill_light());
    }

    commands.spawn((
        StatusText,
        Text::new("Loading private Skate 3 rig and animation graph…"),
        TextFont {
            font_size: 20.0,
            ..default()
        },
        TextColor(Color::srgb(0.92, 0.95, 0.98)),
        Node {
            position_type: PositionType::Absolute,
            top: px(22),
            left: px(26),
            ..default()
        },
    ));
    let controls = if preview.force_fakie {
        "FORCED RETAIL FAKIE COMPOSITION\n\
         Board/body face opposite travel; neutral ride keeps hips, legs, feet, arms, and board.\n\
         B_FAKIE_CHANNEL corrects SPINE2 .5, SPINE3 .7, and NECK/NECK1/HEAD 1.0.\n\
         Close this window when you have finished inspecting the stance and head."
    } else {
        "W / A / S / D or left stick: move / carve    Y key / Y / Triangle: mount or dismount\n\
         RIGHT STICK / arrow keys: Flickit trick input (Ollie, Nollie, 360 Flip endpoint slice)\n\
         LT / Q: left-hand grab    RT / E: right-hand grab    hold both: two-hand grab\n\
         AIR GRABS  RS then trigger: directional family    trigger then RS: tweak / shifty\n\
         Hold grab + A / X: one-foot    + B: no-foot / walk / Superdude\n\
         PARTIAL RIGHT STICK down/up: Manual/Nose Manual · full after entry: deck drag\n\
         ONBOARD  Space / A / Cross: hard push    Left Shift / X / Square: mongo    \
         B key / B / Circle: footbrake\n\
         OFFBOARD  Space / A / Cross: sprint    R / Menu / Start: reset\n\
         F9: start / stop a synchronized parity take\n\
         LANDING VISUAL MODE  1: next Straight   2: next Nice   3: next Sketchy"
    };
    commands.spawn((
        Text::new(controls),
        TextFont {
            font_size: 16.0,
            ..default()
        },
        TextColor(Color::srgb(0.72, 0.79, 0.84)),
        Node {
            position_type: PositionType::Absolute,
            bottom: px(24),
            left: px(26),
            ..default()
        },
    ));
}

fn sync_skater_transform(
    sim: Res<SkateSim>,
    preview: Res<AnimationPreviewMode>,
    mut roots: Query<&mut Transform, With<SkaterRoot>>,
) {
    if let Ok(mut root) = roots.single_mut() {
        root.translation = sim.position + Vec3::Y * sim.visual_skater_root_offset_y();
        let preview_fakie_yaw = if preview.force_fakie {
            std::f32::consts::PI
        } else {
            0.0
        };
        root.rotation = Quat::from_rotation_y(preview_fakie_yaw) * sim.visual_world_rotation();
    }
}

fn update_status(
    sim: Res<SkateSim>,
    input: Res<SkateInput>,
    preview: Res<AnimationPreviewMode>,
    rig: Option<Res<SkateAnimationRig>>,
    model: Option<Res<SkateModel>>,
    diagnostics: Res<animation::AnimationDiagnostics>,
    foot_ik: Res<foot_ik::FootIkDiagnostics>,
    hand_ik: Res<hand_ik::HandIkDiagnostics>,
    recorder: Res<parity_recording::ParityRecorderStatus>,
    mut labels: Query<&mut Text, With<StatusText>>,
) {
    let Ok(mut label) = labels.single_mut() else {
        return;
    };
    if preview.force_fakie {
        let asset_state = if let Some(rig) = &rig {
            format!("RX2/ABIN READY · {} retail clips", rig.clip_count)
        } else if model.is_some() {
            "loading RX2/ABIN animation graph".to_owned()
        } else {
            "loading private model".to_owned()
        };
        **label = format!(
            "{asset_state}\n\
             FORCED RETAIL FAKIE COMPOSITION\n\
             VIRTUAL B_FAKIE_CHANNEL · torso 0.5\n\
             BASE    R_IDLE_HCOM_000\n\
             LEAF    FAKIE_CHANNEL_CYC\n\
             WEIGHTS SPINE2 .5 · SPINE3 .7 · NECK/NECK1/HEAD 1.0\n\
             OUTPUT  {} · LOOP {:.3}s · body faces opposite travel",
            fakie::FAKIE_RIDING_CLIP,
            fakie::FAKIE_CLIP_DURATION_SECONDS,
        );
        return;
    }
    let action_animation = sim.action_animation_state();
    let animation = if action_animation.samples.is_empty() {
        sim.animation_clip
            .clone()
            .unwrap_or_else(|| "BTREE_RIDING".to_owned())
    } else {
        action_animation
            .samples
            .iter()
            .map(|sample| sample.clip.as_str())
            .collect::<Vec<_>>()
            .join("+")
    };
    let action = if sim.offboard.is_some() {
        "offboard motion graph"
    } else if let Some(landing) = &sim.landing {
        match landing.runtime.quality {
            landing_graph::LandingQuality::Straight => "landing straight",
            landing_graph::LandingQuality::Spin => "landing nice",
            landing_graph::LandingQuality::Sketchy => "landing sketchy",
        }
    } else if let Some(anticipation) = &sim.anticipation {
        anticipation.phase_label()
    } else if sim.grab.is_some() {
        sim.state_label()
    } else if let Some(trick) = &sim.basic_trick {
        trick.phase_label()
    } else if let Some(trick) = &sim.air_trick {
        trick.phase_label()
    } else if sim.manual.is_some() {
        sim.state_label()
    } else if let Some(push) = &sim.push {
        push.foot.label()
    } else if sim.slide.is_some() {
        "board slide"
    } else if sim.brake.is_some() {
        "footbrake"
    } else if sim.fakie.is_riding_fakie() {
        sim.fakie.phase.label()
    } else {
        "—"
    };
    let trick_context = sim.active_trick_context.as_ref().map_or_else(
        || "none".to_owned(),
        |context| format!("{} {}", context.approach.label(), context.name),
    );
    let asset_state = if rig.is_some() {
        format!(
            "RX2/ABIN READY · {} retail clips",
            rig.as_ref().map_or(0, |rig| rig.clip_count)
        )
    } else if model.is_some() {
        "loading RX2/ABIN animation graph".to_owned()
    } else {
        "loading private model".to_owned()
    };
    let diagnostic_state = if diagnostics.tail_manual_sway_forced_off {
        "\nDIAGNOSTIC  TAIL SWAY: FORCED OFF · NOSE SWAY: LIVE"
    } else if diagnostics.tail_manual_turn_only {
        "\nDIAGNOSTIC  TAIL NEUTRAL: FROZEN · TAIL FS/BS TURNS: LIVE"
    } else {
        ""
    };
    let ik_state = if !sim.is_onboard() {
        "ONBOARD IK  inactive while BR_ graph owns the complete pose".to_owned()
    } else if foot_ik.targets_resolved {
        format!(
            "ONBOARD IK  R {:>5.2} mm  L {:>5.2} mm",
            foot_ik.right_error_metres * 1000.0,
            foot_ik.left_error_metres * 1000.0,
        )
    } else {
        "ONBOARD IK  waiting for target bones".to_owned()
    };
    let hand_ik_state = if sim.active_grab_hands().is_none() {
        "GRAB IK  inactive".to_owned()
    } else if hand_ik.targets_resolved {
        format!(
            "GRAB IK  R {:>5.2} mm  L {:>5.2} mm",
            hand_ik.right_error_metres * 1000.0,
            hand_ik.left_error_metres * 1000.0,
        )
    } else {
        "GRAB IK  waiting for authored hand targets".to_owned()
    };
    let pad_state = if input.gamepads_usable == 0 {
        format!("PAD    none usable / {} detected", input.gamepads_detected)
    } else {
        format!(
            "PAD    {} usable / {} detected · {}",
            input.gamepads_usable,
            input.gamepads_detected,
            input
                .active_gamepad
                .as_deref()
                .unwrap_or("waiting for input")
        )
    };
    let parity_state = if recorder.recording {
        format!("PARITY REC  poll {} · {}", recorder.poll, recorder.message)
    } else if recorder.replaying {
        format!(
            "PARITY REPLAY  poll {} · {}",
            recorder.poll, recorder.message
        )
    } else {
        format!("PARITY  {}", recorder.message)
    };
    let landing_test_state = if let Some(decision) = sim.last_landing_decision_input {
        let route = match decision.provider_code {
            Some(landing_graph::LandingTypeCode::STRAIGHT) => "STRAIGHT",
            Some(landing_graph::LandingTypeCode::SKETCHY) => "SKETCHY",
            Some(landing_graph::LandingTypeCode::SPIN) => "NICE/SPIN",
            Some(landing_graph::LandingTypeCode::MILD_OFF_AXIS) => "MILD -> STRAIGHT",
            Some(_) => "DEFAULT -> STRAIGHT",
            None => "UNAVAILABLE",
        };
        let heading_delta = decision.board_velocity_heading_delta_radians.map_or_else(
            || "n/a".to_owned(),
            |value| format!("{:+.1}°", value.to_degrees()),
        );
        format!(
            "LANDING TU3  {route} · speed {:.2} m/s · board/velocity Δ {heading_delta} · rotation {:+.1}°",
            decision.approach_speed_metres_per_second,
            decision.completed_rotation_radians.to_degrees()
        )
    } else {
        "LANDING TU3  waiting for first measured touchdown".to_owned()
    };
    **label = format!(
        "{asset_state}{diagnostic_state}\nSTATE  {:<20}  SPEED {:>5.2} m/s  STICK {:+.2} {:+.2}\n\
         MANUAL RS {:+.2} {:+.2} · hold {:.3}s · pitch {:+.1}° · {} {}\n\
         ACTION {:<20}  CLIP  {}\n\
         STANCE natural {:<7} · riding {:<7} · switch {:<3} · approach {:<13} · torso {:>4.2}  TRICK {}\n\
         BRAKE {:<3} {:>4.2}s    SLIDE {:>6.1}°\n{}\n{}\n{}\n{}\n{}",
        sim.state_label(),
        sim.speed(),
        sim.left_stick.x,
        sim.left_stick.y,
        sim.right_stick.x,
        sim.right_stick.y,
        sim.manual_control.engage_seconds(),
        sim.deck_pitch.to_degrees(),
        sim.manual_deck_contact
            .end
            .map_or("no deck end", |end| end.label()),
        if sim.manual_deck_contact.touching {
            "DRAG"
        } else {
            "clear"
        },
        action,
        animation,
        sim.natural_stance.label(),
        sim.riding_stance().label(),
        if sim.fakie.is_riding_switch() {
            "yes"
        } else {
            "no"
        },
        sim.fakie.phase.label(),
        sim.fakie.torso_parameter(),
        trick_context,
        if sim.brake_active { "ON" } else { "off" },
        sim.brake_hold_time,
        sim.powerslide_rotation.to_degrees(),
        pad_state,
        ik_state,
        hand_ik_state,
        parity_state,
        landing_test_state,
    );
}
