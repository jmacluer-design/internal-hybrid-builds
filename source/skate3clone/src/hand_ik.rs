use std::collections::HashMap;

use bevy::math::Affine3A;
use bevy::prelude::*;

use crate::grab_graph::PhysicalGrabHands;
use crate::sim::SkateSim;

const RIGHT_ARM: ArmNames = ArmNames {
    upper: "RIGHTARM",
    lower: "RIGHTFOREARM",
    hand: "RIGHTHAND",
    target: "LEFTHAND_REPARENTED",
};
const LEFT_ARM: ArmNames = ArmNames {
    upper: "LEFTARM",
    lower: "LEFTFOREARM",
    hand: "LEFTHAND",
    target: "RIGHTHAND_REPARENTED",
};

#[derive(Clone, Copy)]
struct ArmNames {
    upper: &'static str,
    lower: &'static str,
    hand: &'static str,
    target: &'static str,
}

#[derive(Clone)]
struct PoseNode {
    local: Transform,
    parent: Option<Entity>,
}

#[derive(Clone, Copy)]
struct ArmEntities {
    upper: Entity,
    lower: Entity,
    hand: Entity,
    target: Entity,
}

#[derive(Clone, Copy)]
struct ArmSolution {
    upper: Entity,
    upper_rotation: Quat,
    lower: Entity,
    lower_rotation: Quat,
    hand: Entity,
    hand_rotation: Quat,
}

#[derive(Resource, Clone, Copy, Debug)]
pub struct HandIkDiagnostics {
    pub right_error_metres: f32,
    pub left_error_metres: f32,
    pub targets_resolved: bool,
}

impl Default for HandIkDiagnostics {
    fn default() -> Self {
        Self {
            right_error_metres: f32::INFINITY,
            left_error_metres: f32::INFINITY,
            targets_resolved: false,
        }
    }
}

/// Lock only the hand(s) selected by the held-trigger graph to compact
/// OnBoard target channels 34/35. The target positions and orientations are
/// authored in each retail clip; this system contributes no contact offsets.
///
/// The deform-hand labels and compact target labels use opposing handedness
/// conventions in the generated rig. The offline clip probe shows the crossed
/// pair within 1--23 mm throughout the selected grab cycles, while matching
/// labels are 0.7--1.2 m apart and unreachable by the arm chain.
pub fn lock_grab_hands_to_onboard_targets(
    sim: Res<SkateSim>,
    mut pose: ParamSet<(
        Query<(Entity, Option<&Name>, &Transform, Option<&ChildOf>)>,
        Query<&mut Transform>,
    )>,
) {
    let Some((active, constraint_weight)) = sim.active_grab_hand_ik() else {
        return;
    };
    let constraint_weight = constraint_weight.clamp(0.0, 1.0);

    let mut nodes = HashMap::new();
    let mut named = HashMap::new();
    for (entity, name, transform, parent) in pose.p0().iter() {
        nodes.insert(
            entity,
            PoseNode {
                local: *transform,
                parent: parent.map(ChildOf::parent),
            },
        );
        if let Some(name) = name {
            named.insert(name.as_str().to_owned(), entity);
        }
    }

    let arms: &[ArmNames] = match active {
        PhysicalGrabHands::Left => &[LEFT_ARM],
        PhysicalGrabHands::Right => &[RIGHT_ARM],
        PhysicalGrabHands::Both => &[LEFT_ARM, RIGHT_ARM],
    };
    let mut globals = HashMap::new();
    let solutions = arms
        .iter()
        .filter_map(|names| resolve_arm(*names, &named))
        .filter_map(|arm| solve_arm(arm, &nodes, &mut globals))
        .collect::<Vec<_>>();

    let mut mutable_pose = pose.p1();
    for solution in solutions {
        if let Ok(mut transform) = mutable_pose.get_mut(solution.upper) {
            transform.rotation = transform
                .rotation
                .slerp(solution.upper_rotation, constraint_weight);
        }
        if let Ok(mut transform) = mutable_pose.get_mut(solution.lower) {
            transform.rotation = transform
                .rotation
                .slerp(solution.lower_rotation, constraint_weight);
        }
        if let Ok(mut transform) = mutable_pose.get_mut(solution.hand) {
            transform.rotation = transform
                .rotation
                .slerp(solution.hand_rotation, constraint_weight);
        }
    }
}

pub fn measure_hand_target_error(
    pose: Query<(&Name, &GlobalTransform)>,
    mut diagnostics: ResMut<HandIkDiagnostics>,
) {
    let mut right_hand = None;
    let mut right_target = None;
    let mut left_hand = None;
    let mut left_target = None;
    for (name, global) in &pose {
        let translation = global.translation();
        match name.as_str() {
            "RIGHTHAND" => right_hand = Some(translation),
            "RIGHTHAND_REPARENTED" => right_target = Some(translation),
            "LEFTHAND" => left_hand = Some(translation),
            "LEFTHAND_REPARENTED" => left_target = Some(translation),
            _ => {}
        }
    }
    let Some((right_hand, right_target, left_hand, left_target)) = right_hand
        .zip(right_target)
        .zip(left_hand.zip(left_target))
        .map(|((right_hand, right_target), (left_hand, left_target))| {
            (right_hand, right_target, left_hand, left_target)
        })
    else {
        *diagnostics = HandIkDiagnostics::default();
        return;
    };
    diagnostics.right_error_metres = right_hand.distance(left_target);
    diagnostics.left_error_metres = left_hand.distance(right_target);
    diagnostics.targets_resolved = true;
}

fn resolve_arm(names: ArmNames, named: &HashMap<String, Entity>) -> Option<ArmEntities> {
    Some(ArmEntities {
        upper: *named.get(names.upper)?,
        lower: *named.get(names.lower)?,
        hand: *named.get(names.hand)?,
        target: *named.get(names.target)?,
    })
}

fn solve_arm(
    arm: ArmEntities,
    nodes: &HashMap<Entity, PoseNode>,
    globals: &mut HashMap<Entity, Affine3A>,
) -> Option<ArmSolution> {
    let upper_world = global_affine(arm.upper, nodes, globals)?;
    let lower_world = global_affine(arm.lower, nodes, globals)?;
    let hand_world = global_affine(arm.hand, nodes, globals)?;
    let target_world = global_affine(arm.target, nodes, globals)?;
    let upper_parent = nodes.get(&arm.upper)?.parent?;
    let upper_parent_world = global_affine(upper_parent, nodes, globals)?;

    let (_, upper_world_rotation, shoulder) = upper_world.to_scale_rotation_translation();
    let (_, lower_world_rotation, elbow) = lower_world.to_scale_rotation_translation();
    let (_, _, wrist) = hand_world.to_scale_rotation_translation();
    let (_, target_rotation, target_wrist) = target_world.to_scale_rotation_translation();
    let (_, upper_parent_rotation, _) = upper_parent_world.to_scale_rotation_translation();

    let upper_length = shoulder.distance(elbow);
    let lower_length = elbow.distance(wrist);
    let desired_elbow =
        solve_two_bone_joint(shoulder, elbow, target_wrist, upper_length, lower_length)?;
    let upper_delta = Quat::from_rotation_arc(
        (elbow - shoulder).normalize(),
        (desired_elbow - shoulder).normalize(),
    );
    let desired_upper_world_rotation = (upper_delta * upper_world_rotation).normalize();
    let lower_delta = Quat::from_rotation_arc(
        (wrist - elbow).normalize(),
        (target_wrist - desired_elbow).normalize(),
    );
    let desired_lower_world_rotation = (lower_delta * lower_world_rotation).normalize();

    Some(ArmSolution {
        upper: arm.upper,
        upper_rotation: (upper_parent_rotation.inverse() * desired_upper_world_rotation)
            .normalize(),
        lower: arm.lower,
        lower_rotation: (desired_upper_world_rotation.inverse() * desired_lower_world_rotation)
            .normalize(),
        hand: arm.hand,
        hand_rotation: (desired_lower_world_rotation.inverse() * target_rotation).normalize(),
    })
}

fn global_affine(
    entity: Entity,
    nodes: &HashMap<Entity, PoseNode>,
    cache: &mut HashMap<Entity, Affine3A>,
) -> Option<Affine3A> {
    if let Some(transform) = cache.get(&entity) {
        return Some(*transform);
    }
    let node = nodes.get(&entity)?;
    let local = node.local.compute_affine();
    let world = if let Some(parent) = node.parent {
        global_affine(parent, nodes, cache)? * local
    } else {
        local
    };
    cache.insert(entity, world);
    Some(world)
}

fn solve_two_bone_joint(
    root: Vec3,
    animated_joint: Vec3,
    target: Vec3,
    upper_length: f32,
    lower_length: f32,
) -> Option<Vec3> {
    const EPSILON: f32 = 1.0e-6;
    if upper_length <= EPSILON || lower_length <= EPSILON {
        return None;
    }
    let target_offset = target - root;
    let raw_distance = target_offset.length();
    if raw_distance <= EPSILON {
        return None;
    }
    let direction = target_offset / raw_distance;
    let distance = raw_distance.clamp(
        (upper_length - lower_length).abs() + EPSILON,
        upper_length + lower_length - EPSILON,
    );
    let along = (upper_length * upper_length - lower_length * lower_length + distance * distance)
        / (2.0 * distance);
    let height_squared = (upper_length * upper_length - along * along).max(0.0);
    let animated_offset = animated_joint - root;
    let projected = animated_offset - direction * animated_offset.dot(direction);
    let pole = if projected.length_squared() > EPSILON * EPSILON {
        projected.normalize()
    } else {
        direction.any_orthonormal_vector()
    };
    Some(root + direction * along + pole * height_squared.sqrt())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arm_solver_preserves_both_segment_lengths() {
        let shoulder = Vec3::new(0.0, 1.2, 0.0);
        let elbow = Vec3::new(0.25, 0.9, 0.1);
        let wrist = Vec3::new(0.4, 0.6, -0.05);
        let target = Vec3::new(0.28, 0.52, 0.08);
        let upper = shoulder.distance(elbow);
        let lower = elbow.distance(wrist);
        let solved =
            solve_two_bone_joint(shoulder, elbow, target, upper, lower).expect("reachable chain");
        assert!((shoulder.distance(solved) - upper).abs() < 1.0e-5);
        assert!((solved.distance(target) - lower).abs() < 1.0e-5);
    }

    #[test]
    fn exported_deform_hands_use_the_opposite_compact_target_labels() {
        assert_eq!(RIGHT_ARM.hand, "RIGHTHAND");
        assert_eq!(RIGHT_ARM.target, "LEFTHAND_REPARENTED");
        assert_eq!(LEFT_ARM.hand, "LEFTHAND");
        assert_eq!(LEFT_ARM.target, "RIGHTHAND_REPARENTED");
    }
}
