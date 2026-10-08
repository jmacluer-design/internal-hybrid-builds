use bevy::app::AnimationSystems;
use bevy::math::Affine3A;
use bevy::prelude::*;
use bevy::transform::TransformSystems;
use serde::Deserialize;
use std::sync::OnceLock;

use crate::air_trick_graph::WILL_EXPIRE_WINDOW_SECONDS;
use crate::board_authority::BoardAuthority;
use crate::manual_contact::DeckEnd;
use crate::sim::SkateSim;

const BOARD_ROOT: &str = "SKATEBOARD_ROOT";
const FRONT_TRUCK: &str = "TRUCK_FRONT";
const BACK_TRUCK: &str = "TRUCK_BACK";
const FRONT_WHEELS: [&str; 2] = ["RIGHT_WHEELFRONT", "LEFT_WHEELFRONT"];
const BACK_WHEELS: [&str; 2] = ["LEFT_WHEELBACK", "RIGHT_WHEELBACK"];
const REPARENTED_TOE_TARGETS: [&str; 2] = ["RIGHTTOEBASE_REPARENTED", "LEFTTOEBASE_REPARENTED"];
const AIR_BASELINE_TRACK_JSON: &str =
    include_str!("../research/porting/AIR_BASELINE_BOARD_POSE.json");
const AIR_BASELINE_ACTION: &str = "IA_IDLE_N_N_0_CYC";
const AIR_BASELINE_SOURCE_SHA256: &str =
    "00D0A9B7CBE0B95DC01449F7ACCF3CBB57E70E836E54CCC0DC52BAA4C9F7F2AA";
const BOARD_BIND_ROTATION_X: f32 = -std::f32::consts::FRAC_PI_2;
const FRONT_TRUCK_PIVOT: Vec3 = Vec3::new(0.0, -0.259_179_06, -0.027_862_463);
const BACK_TRUCK_PIVOT: Vec3 = Vec3::new(0.0, 0.259_178_88, -0.027_862_504);

pub struct BoardPlugin;

#[derive(Resource, Default)]
struct SkateboardOffsetRuntime {
    last_output_rotation: Option<Quat>,
    transition_start_rotation: Option<Quat>,
    transition_active: bool,
    foot_targets: [FootTargetOffsetRuntime; 2],
}

#[derive(Clone, Copy, Default)]
struct FootTargetOffsetRuntime {
    last_output_rig: Option<Transform>,
    transition_start_rig: Option<Transform>,
}

#[derive(Deserialize)]
struct AirBaselineTrackDocument {
    action: String,
    source_sha256: String,
    sample_rate_hz: f32,
    through_seconds: f32,
    samples: Vec<AirBaselineTrackSample>,
}

#[derive(Deserialize)]
struct AirBaselineTrackSample {
    time_seconds: f32,
    nodes: AirBaselineTrackNodes,
}

#[derive(Deserialize)]
#[allow(non_snake_case)]
struct AirBaselineTrackNodes {
    SKATEBOARD_ROOT: AirBaselineTrackTransform,
    RIGHTTOEBASE_REPARENTED: AirBaselineTrackTransform,
    LEFTTOEBASE_REPARENTED: AirBaselineTrackTransform,
}

#[derive(Deserialize)]
struct AirBaselineTrackTransform {
    translation: [f32; 3],
    rotation: [f32; 4],
    scale: [f32; 3],
}

impl AirBaselineTrackTransform {
    fn pose(&self) -> Transform {
        Transform {
            translation: Vec3::from_array(self.translation),
            rotation: Quat::from_array(self.rotation).normalize(),
            scale: Vec3::from_array(self.scale),
        }
    }
}

impl Plugin for BoardPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<crate::foot_ik::FootIkDiagnostics>();
        app.init_resource::<SkateboardOffsetRuntime>();
        app.init_resource::<crate::hand_ik::HandIkDiagnostics>();
        // ABIN animation is evaluated in PostUpdate. Apply SkateboardBody-style
        // articulation afterwards, then let Bevy propagate the final bone poses.
        app.add_systems(
            PostUpdate,
            (
                apply_retail_board_carrier,
                apply_retail_skateboard_offset,
                articulate_retail_board,
                crate::foot_ik::lock_riding_feet_to_onboard_targets,
                crate::hand_ik::lock_grab_hands_to_onboard_targets,
            )
                .chain()
                .after(AnimationSystems)
                .before(TransformSystems::Propagate),
        );
        app.add_systems(
            PostUpdate,
            (
                crate::foot_ik::measure_toe_target_error,
                crate::hand_ik::measure_hand_target_error,
            )
                .after(TransformSystems::Propagate),
        );
    }
}

fn board_reversal_rotation(reversal: f32) -> Quat {
    // Endpoint extraction resolves baseline.rotation_difference(endpoint) as
    // a half turn around SKATEBOARD_ROOT's local deck-normal Z axis.
    Quat::from_rotation_z(std::f32::consts::PI * reversal.clamp(0.0, 1.0))
}

fn apply_board_reversal(authored_rotation: Quat, reversal: f32) -> Quat {
    // This must be post-multiplied. Pre-multiplying rotates around the
    // armature parent's Z axis, which rolls the already-oriented deck upside
    // down instead of exchanging its nose and tail.
    (authored_rotation * board_reversal_rotation(reversal)).normalize()
}

fn air_baseline_track() -> &'static AirBaselineTrackDocument {
    static TRACK: OnceLock<AirBaselineTrackDocument> = OnceLock::new();
    TRACK.get_or_init(|| {
        let track: AirBaselineTrackDocument =
            serde_json::from_str(AIR_BASELINE_TRACK_JSON).expect("air baseline track must parse");
        assert_eq!(track.action, AIR_BASELINE_ACTION);
        assert_eq!(track.source_sha256, AIR_BASELINE_SOURCE_SHA256);
        assert!(track.sample_rate_hz > 0.0);
        assert!(track.samples.len() >= 2);
        assert_eq!(
            track.samples.len(),
            (track.through_seconds * track.sample_rate_hz).round() as usize + 1
        );
        assert!(
            track
                .samples
                .windows(2)
                .all(|samples| samples[0].time_seconds < samples[1].time_seconds)
        );
        assert!(
            track.through_seconds + f32::EPSILON
                >= crate::sim::SEQUENCE_TO_AIR_BASELINE_BLEND_SECONDS
        );
        track
    })
}

fn air_baseline_poses(sample_time_seconds: f32) -> (Transform, [Transform; 2]) {
    let track = air_baseline_track();
    let sample_time_seconds = sample_time_seconds.clamp(0.0, track.through_seconds);
    let upper_index = track
        .samples
        .partition_point(|sample| sample.time_seconds <= sample_time_seconds)
        .min(track.samples.len() - 1);
    let lower_index = upper_index.saturating_sub(1);
    let lower_sample = &track.samples[lower_index];
    let upper_sample = &track.samples[upper_index];
    let interval = upper_sample.time_seconds - lower_sample.time_seconds;
    let weight = if interval <= f32::EPSILON {
        0.0
    } else {
        (sample_time_seconds - lower_sample.time_seconds) / interval
    };
    let lower = &lower_sample.nodes;
    let upper = &upper_sample.nodes;
    let sample = |lower: &AirBaselineTrackTransform, upper: &AirBaselineTrackTransform| {
        blend_pose(lower.pose(), upper.pose(), weight)
    };
    (
        sample(&lower.SKATEBOARD_ROOT, &upper.SKATEBOARD_ROOT),
        [
            sample(
                &lower.RIGHTTOEBASE_REPARENTED,
                &upper.RIGHTTOEBASE_REPARENTED,
            ),
            sample(&lower.LEFTTOEBASE_REPARENTED, &upper.LEFTTOEBASE_REPARENTED),
        ],
    )
}

fn transform_from_affine(affine: Affine3A) -> Transform {
    let (scale, rotation, translation) = affine.to_scale_rotation_translation();
    Transform {
        translation,
        rotation: rotation.normalize(),
        scale,
    }
}

fn child_rig_pose(parent: Transform, child: Transform) -> Transform {
    transform_from_affine(parent.compute_affine() * child.compute_affine())
}

fn child_pose_for_rig(parent: Transform, rig_pose: Transform) -> Transform {
    transform_from_affine(parent.compute_affine().inverse() * rig_pose.compute_affine())
}

fn blend_pose(from: Transform, to: Transform, weight: f32) -> Transform {
    let weight = weight.clamp(0.0, 1.0);
    Transform {
        translation: from.translation.lerp(to.translation, weight),
        rotation: from.rotation.slerp(to.rotation, weight).normalize(),
        scale: from.scale.lerp(to.scale, weight),
    }
}

fn apply_retail_skateboard_offset(
    sim: Res<SkateSim>,
    mut runtime: ResMut<SkateboardOffsetRuntime>,
    mut transforms: Query<(Entity, &Name, Option<&ChildOf>, &mut Transform)>,
) {
    let mut board_root = None;
    let mut target_candidates = Vec::new();
    for (entity, name, parent, transform) in transforms.iter() {
        if name.as_str() == BOARD_ROOT {
            board_root = Some((entity, *transform));
        } else if let Some(target_index) = REPARENTED_TOE_TARGETS
            .iter()
            .position(|target| *target == name.as_str())
        {
            target_candidates.push((
                target_index,
                entity,
                parent.map(ChildOf::parent),
                *transform,
            ));
        }
    }
    let Some((root_entity, authored_root)) = board_root else {
        return;
    };

    let reversal_transition = sim.visual_board_reversal_transition();
    let transition_started = reversal_transition.is_some() && !runtime.transition_active;
    let air_baseline = reversal_transition
        .map(|(_, transition_elapsed, _)| air_baseline_poses(transition_elapsed));
    let corrected_rotation =
        if let Some((target_reversal, transition_elapsed, _transition_duration)) =
            reversal_transition
        {
            if transition_started {
                runtime.transition_start_rotation = runtime.last_output_rotation.or(Some(
                    apply_board_reversal(authored_root.rotation, 1.0 - target_reversal),
                ));
            }
            let start = runtime
                .transition_start_rotation
                .unwrap_or(authored_root.rotation);
            let target = apply_board_reversal(
                air_baseline
                    .as_ref()
                    .expect("transition has an air-baseline sample")
                    .0
                    .rotation,
                target_reversal,
            );
            // WillExpire enters 0.05 s before the physical leaf endpoint.
            // Finish only that remaining authored offset, then keep the deck
            // settled while the character continues its 0.2 s air blend.
            let tail_weight = (transition_elapsed / WILL_EXPIRE_WINDOW_SECONDS).clamp(0.0, 1.0);
            start.slerp(target, tail_weight).normalize()
        } else {
            runtime.transition_start_rotation = None;
            apply_board_reversal(authored_root.rotation, sim.visual_board_reversal())
        };
    let mut corrected_root = authored_root;
    corrected_root.rotation = corrected_rotation;

    if let Ok((_, _, _, mut root)) = transforms.get_mut(root_entity) {
        *root = corrected_root;
    }
    for (target_index, target_entity, parent, authored_target) in target_candidates {
        if parent != Some(root_entity) {
            continue;
        }
        let target_runtime = &mut runtime.foot_targets[target_index];
        let authored_rig = child_rig_pose(authored_root, authored_target);

        let corrected_rig =
            if let Some((_target_reversal, transition_elapsed, transition_duration)) =
                reversal_transition
            {
                if transition_started {
                    target_runtime.transition_start_rig =
                        target_runtime.last_output_rig.or(Some(authored_rig));
                }
                let start = target_runtime.transition_start_rig.unwrap_or(authored_rig);
                let (baseline_board, baseline_targets) = air_baseline
                    .as_ref()
                    .expect("transition has an air-baseline sample");
                let target = child_rig_pose(*baseline_board, baseline_targets[target_index]);
                let weight = if transition_duration <= f32::EPSILON {
                    1.0
                } else {
                    transition_elapsed / transition_duration
                };
                blend_pose(start, target, weight)
            } else {
                target_runtime.transition_start_rig = None;
                authored_rig
            };
        let corrected_target = child_pose_for_rig(corrected_root, corrected_rig);
        if let Ok((_, _, _, mut target)) = transforms.get_mut(target_entity) {
            *target = corrected_target;
        }
        target_runtime.last_output_rig = Some(corrected_rig);
    }
    runtime.transition_active = reversal_transition.is_some();
    runtime.last_output_rotation = Some(corrected_rotation);
}

fn apply_retail_board_carrier(
    sim: Res<SkateSim>,
    parents: Query<&GlobalTransform>,
    mut transforms: Query<(&Name, &ChildOf, &mut Transform)>,
) {
    let correction = sim.visual_board_correction_y();
    if correction.abs() <= f32::EPSILON {
        return;
    }
    for (name, parent, mut transform) in &mut transforms {
        if name.as_str() != BOARD_ROOT {
            continue;
        }
        let Ok(parent_global) = parents.get(parent.parent()) else {
            return;
        };
        let local_correction = parent_global
            .affine()
            .inverse()
            .transform_vector3(Vec3::Y * correction);
        transform.translation += local_correction;
        return;
    }
}

#[derive(Clone)]
struct NamedBone {
    entity: Entity,
    transform: Transform,
}

#[derive(Default)]
struct BoardBones {
    root: Option<NamedBone>,
    front_truck: Option<NamedBone>,
    back_truck: Option<NamedBone>,
    front_wheels: Vec<NamedBone>,
    back_wheels: Vec<NamedBone>,
}

fn articulate_retail_board(
    sim: Res<SkateSim>,
    mut transforms: Query<(Entity, &Name, &mut Transform)>,
) {
    // BR_ offboard and mount/dismount clips author the complete carried-board
    // pose. SkateboardBody articulation resumes only after the graph has
    // returned to OnBoard.
    if !sim.is_onboard() || sim.board_authority != BoardAuthority::Physics {
        return;
    }

    let mut board = BoardBones::default();
    for (entity, name, transform) in transforms.iter() {
        let bone = NamedBone {
            entity,
            transform: transform.clone(),
        };
        match name.as_str() {
            BOARD_ROOT => board.root = Some(bone),
            FRONT_TRUCK => board.front_truck = Some(bone),
            BACK_TRUCK => board.back_truck = Some(bone),
            name if FRONT_WHEELS.contains(&name) => board.front_wheels.push(bone),
            name if BACK_WHEELS.contains(&name) => board.back_wheels.push(bone),
            _ => {}
        }
    }

    let Some(root) = board.root else {
        return;
    };
    let local_deck_pitch = Quat::from_rotation_x(sim.deck_pitch);
    let local_deck_roll = Quat::from_rotation_y(-sim.deck_roll);
    let local_articulation = local_deck_pitch * local_deck_roll;
    let manual_pivot = match sim.manual_deck_contact.end {
        Some(DeckEnd::Tail) => Some(BACK_TRUCK_PIVOT),
        Some(DeckEnd::Nose) => Some(FRONT_TRUCK_PIVOT),
        None => None,
    };
    if let Ok((_, _, mut transform)) = transforms.get_mut(root.entity) {
        // SKATEBOARD_ROOT's local Y axis is the retail deck's longitudinal
        // axis and local X is its axle/pitch axis. ground.xml applies
        // FORCE_PHYSICS_SKATEBOARD above the complete Riding/Manual subtree:
        // the physical deck transform positions the animation while the
        // decoded manual leaf supplies the rider's board-relative pose.
        //
        // Do not retain any authored manual-board yaw/roll/pitch here. The
        // low tail cycle carries a large animated board rotation that is not
        // present in the physics-owned retail deck and made the regular
        // manual visibly rock more than the nose manual. Physics supplies the
        // continuous pitch/roll below; the neutral nose leaf still carries
        // its stronger authored rider balance motion independently of Turn.
        let base_rotation = if sim.manual.is_some() {
            physics_owned_manual_board_base_rotation(root.transform.rotation)
        } else {
            root.transform.rotation
        };
        if let Some(pivot) = manual_pivot {
            transform.translation =
                root.transform.translation + base_rotation * (pivot - local_deck_pitch * pivot);
        }
        transform.rotation = (base_rotation * local_articulation).normalize();
    }

    if let Some(truck) = board.front_truck {
        articulate_truck(
            &mut transforms,
            &truck,
            &board.front_wheels,
            local_articulation,
            sim.wheel_spin,
            !sim.manual.is_some() || sim.manual_deck_contact.end == Some(DeckEnd::Nose),
        );
    }
    if let Some(truck) = board.back_truck {
        articulate_truck(
            &mut transforms,
            &truck,
            &board.back_wheels,
            local_articulation,
            sim.wheel_spin,
            !sim.manual.is_some() || sim.manual_deck_contact.end == Some(DeckEnd::Tail),
        );
    }
}

fn physics_owned_manual_board_base_rotation(_authored_rotation: Quat) -> Quat {
    Quat::from_rotation_x(BOARD_BIND_ROTATION_X)
}

fn articulate_truck(
    transforms: &mut Query<(Entity, &Name, &mut Transform)>,
    truck: &NamedBone,
    wheels: &[NamedBone],
    deck_roll: Quat,
    wheel_spin: f32,
    keep_wheels_grounded: bool,
) {
    // Skate 3 treats the deck, both trucks and all four wheels as separate
    // physics parts. Counter-articulating the hanger keeps its axle frame
    // level while the deck rolls around its longitudinal axis.
    if let Ok((_, _, mut transform)) = transforms.get_mut(truck.entity) {
        transform.rotation = (deck_roll.inverse() * truck.transform.rotation).normalize();
    }

    let rolled_mount = deck_roll * truck.transform.translation;
    let vertical_contact_error = if keep_wheels_grounded {
        truck.transform.translation.z - rolled_mount.z
    } else {
        0.0
    };
    let contact_correction = truck.transform.rotation.inverse() * Vec3::Z * vertical_contact_error;
    let axle_axis_in_truck = (truck.transform.rotation.inverse() * Vec3::X).normalize();
    let spin = Quat::from_axis_angle(axle_axis_in_truck, wheel_spin);

    for wheel in wheels {
        if let Ok((_, _, mut transform)) = transforms.get_mut(wheel.entity) {
            // Compression is applied per wheel bone, after the truck frame,
            // so the tyre centres stay on their original ground plane.
            transform.translation = wheel.transform.translation + contact_correction;
            transform.rotation = (spin * wheel.transform.rotation).normalize();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counter_articulation_preserves_truck_world_orientation() {
        let root = Quat::from_rotation_x(-std::f32::consts::FRAC_PI_2);
        let truck = Quat::from_euler(EulerRot::XYZ, 0.37, -0.22, 0.11);
        let roll = Quat::from_rotation_y(0.24);
        let original = root * truck;
        let articulated = root * roll * roll.inverse() * truck;
        assert!((original * Vec3::X - articulated * Vec3::X).length() < 1.0e-5);
    }

    #[test]
    fn wheel_contact_correction_cancels_mount_height_change() {
        let mount = Vec3::new(0.0, 0.25917888, -0.0278625);
        let roll = Quat::from_rotation_y(0.24);
        let rolled = roll * mount;
        let correction = mount.z - rolled.z;
        assert!((rolled.z + correction - mount.z).abs() < 1.0e-6);
    }

    #[test]
    fn skater_carrier_counter_rotation_preserves_physical_board_heading() {
        let board_yaw = -1.7;
        let skater_offset = 0.56;
        let authored_board = Quat::from_rotation_x(-0.31);
        let original_world = Quat::from_rotation_y(board_yaw) * authored_board;
        let separated_world = Quat::from_rotation_y(board_yaw + skater_offset)
            * Quat::from_rotation_y(-skater_offset)
            * authored_board;

        assert!((original_world * Vec3::Z - separated_world * Vec3::Z).length() < 1.0e-6);
    }

    #[test]
    fn skateboard_offset_does_not_move_reparented_foot_targets_in_rig_space() {
        let authored_board = Transform::from_xyz(0.01, -0.02, 0.03)
            .with_rotation(Quat::from_euler(EulerRot::XYZ, -0.31, 0.17, 0.08).normalize());
        let mut corrected_board = authored_board;
        corrected_board.rotation = apply_board_reversal(authored_board.rotation, 1.0);
        let authored_target = Transform::from_xyz(0.04, 0.27, -0.03)
            .with_rotation(Quat::from_euler(EulerRot::XYZ, 0.11, -0.07, 0.03));
        let authored_rig = child_rig_pose(authored_board, authored_target);
        let corrected_target = child_pose_for_rig(corrected_board, authored_rig);
        let corrected_rig = child_rig_pose(corrected_board, corrected_target);

        assert!((authored_rig.translation - corrected_rig.translation).length() < 1.0e-5);
        assert!(
            (authored_rig.rotation * Vec3::Y - corrected_rig.rotation * Vec3::Y).length() < 1.0e-5
        );
    }

    #[test]
    fn catch_target_blend_is_linear_in_rig_space() {
        let start =
            Transform::from_xyz(-0.08, 0.31, 0.04).with_rotation(Quat::from_rotation_x(-0.24));
        let baseline =
            Transform::from_xyz(0.02, 0.27, -0.01).with_rotation(Quat::from_rotation_y(0.18));
        let midpoint = blend_pose(start, baseline, 0.5);

        assert!(
            (midpoint.translation - start.translation.lerp(baseline.translation, 0.5)).length()
                < 1.0e-6
        );
        assert!(
            (midpoint.rotation * Vec3::Z - start.rotation.slerp(baseline.rotation, 0.5) * Vec3::Z)
                .length()
                < 1.0e-6
        );
    }

    #[test]
    fn air_baseline_track_covers_the_complete_sequence_to_air_blend() {
        let track = air_baseline_track();
        assert_eq!(track.samples[0].time_seconds, 0.0);
        assert!(
            (track.samples.last().unwrap().time_seconds
                - crate::sim::SEQUENCE_TO_AIR_BASELINE_BLEND_SECONDS)
                .abs()
                < 1.0e-6
        );
        assert_eq!(
            track.samples.len(),
            (track.through_seconds * track.sample_rate_hz).round() as usize + 1
        );
    }

    #[test]
    fn sampled_air_baseline_reaches_the_live_catch_endpoint_without_a_release_jump() {
        let duration = crate::sim::SEQUENCE_TO_AIR_BASELINE_BLEND_SECONDS;
        let (board, targets) = air_baseline_poses(duration);
        let endpoint = &air_baseline_track().samples.last().unwrap().nodes;
        let expected = [
            endpoint.SKATEBOARD_ROOT.pose(),
            endpoint.RIGHTTOEBASE_REPARENTED.pose(),
            endpoint.LEFTTOEBASE_REPARENTED.pose(),
        ];
        for (label, actual, expected) in [
            ("board", board, expected[0]),
            ("right target", targets[0], expected[1]),
            ("left target", targets[1], expected[2]),
        ] {
            assert!(
                actual.translation.distance(expected.translation) < 1.0e-7,
                "{label} translation"
            );
            assert!(
                (actual.rotation * Vec3::Y - expected.rotation * Vec3::Y).length() < 1.0e-7,
                "{label} rotation"
            );
            assert!(
                actual.scale.distance(expected.scale) < 1.0e-7,
                "{label} scale"
            );
        }
    }

    #[test]
    fn manual_pitch_rotation_keeps_the_selected_axle_pivot_fixed() {
        for (pivot, pitch) in [(BACK_TRUCK_PIVOT, -0.35), (FRONT_TRUCK_PIVOT, 0.35)] {
            let base = Quat::from_rotation_x(BOARD_BIND_ROTATION_X);
            let rotation = Quat::from_rotation_x(pitch);
            let translated_origin = base * (pivot - rotation * pivot);
            let transformed_pivot = translated_origin + base * rotation * pivot;
            let original_pivot = base * pivot;
            assert!((transformed_pivot - original_pivot).length() < 1.0e-6);
        }
    }

    #[test]
    fn half_turn_reversal_preserves_the_oriented_deck_normal() {
        let authored = Quat::from_euler(EulerRot::XYZ, -1.17, 0.29, -0.41).normalize();
        let reversed = apply_board_reversal(authored, 1.0);
        let authored_normal = authored * Vec3::Z;
        let authored_longitudinal = authored * Vec3::Y;

        assert!((reversed * Vec3::Z - authored_normal).length() < 1.0e-6);
        assert!((reversed * Vec3::Y + authored_longitudinal).length() < 1.0e-6);
    }

    #[test]
    fn physics_manual_pose_replaces_every_authored_board_rotation_axis() {
        let bind = Quat::from_rotation_x(BOARD_BIND_ROTATION_X);
        for authored in [
            bind * Quat::from_euler(EulerRot::XYZ, -0.4, 0.3, -0.2),
            bind * Quat::from_euler(EulerRot::XYZ, 0.2, -0.5, 0.4),
            bind * Quat::from_euler(EulerRot::XYZ, 0.55, 0.1, -0.35),
        ] {
            let recovered = physics_owned_manual_board_base_rotation(authored);
            for axis in [Vec3::X, Vec3::Y, Vec3::Z] {
                assert!((recovered * axis - bind * axis).length() < 1.0e-6);
                assert!(
                    (authored * axis - recovered * axis).length() > 1.0e-3,
                    "fixture must contain authored rotation for every case"
                );
            }
        }
    }
}
