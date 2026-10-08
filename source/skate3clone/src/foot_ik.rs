use std::collections::HashMap;

use bevy::math::Affine3A;
use bevy::prelude::*;

use crate::grab_graph::{GrabFootRelease, ReleasedFoot};
use crate::sim::SkateSim;

const RIGHT_LEG: LegNames = LegNames {
    upper: "RIGHTUPLEG",
    lower: "RIGHTLEG",
    foot: "RIGHTFOOT",
    toe: "RIGHTTOEBASE",
    target: "RIGHTTOEBASE_REPARENTED",
};
const LEFT_LEG: LegNames = LegNames {
    upper: "LEFTUPLEG",
    lower: "LEFTLEG",
    foot: "LEFTFOOT",
    toe: "LEFTTOEBASE",
    target: "LEFTTOEBASE_REPARENTED",
};

#[derive(Clone, Copy)]
struct LegNames {
    upper: &'static str,
    lower: &'static str,
    foot: &'static str,
    toe: &'static str,
    target: &'static str,
}

#[derive(Clone)]
struct PoseNode {
    local: Transform,
    parent: Option<Entity>,
}

#[derive(Clone, Copy)]
struct LegEntities {
    upper: Entity,
    lower: Entity,
    foot: Entity,
    toe: Entity,
    target: Entity,
}

#[derive(Clone, Copy)]
struct LegSolution {
    upper: Entity,
    upper_rotation: Quat,
    lower: Entity,
    lower_rotation: Quat,
    foot: Entity,
    foot_rotation: Quat,
}

#[derive(Resource, Clone, Copy, Debug)]
pub struct FootIkDiagnostics {
    pub right_error_metres: f32,
    pub left_error_metres: f32,
    pub targets_resolved: bool,
}

impl Default for FootIkDiagnostics {
    fn default() -> Self {
        Self {
            right_error_metres: f32::INFINITY,
            left_error_metres: f32::INFINITY,
            targets_resolved: false,
        }
    }
}

/// Apply Skate 3's grounded two-leg SkeletonIK branch after animation and
/// board articulation. Compact OnBoard channels 32/33 are the source targets;
/// this system does not synthesize board contact locations.
pub fn lock_riding_feet_to_onboard_targets(
    sim: Res<SkateSim>,
    mut pose: ParamSet<(
        Query<(Entity, Option<&Name>, &Transform, Option<&ChildOf>)>,
        Query<&mut Transform>,
    )>,
) {
    // The recovered SkeletonIK branch is an OnBoard branch. Applying it to BR_
    // locomotion would incorrectly pull both feet back toward the carried deck.
    if !sim.is_onboard() {
        return;
    }

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

    let mut globals = HashMap::new();
    let release = sim.active_grab_foot_release();
    let solutions: Vec<_> = [RIGHT_LEG, LEFT_LEG]
        .into_iter()
        .enumerate()
        .filter(|(index, _)| match release {
            GrabFootRelease::None => true,
            GrabFootRelease::Both => false,
            GrabFootRelease::One(ReleasedFoot::Right) => *index != 0,
            GrabFootRelease::One(ReleasedFoot::Left) => *index != 1,
        })
        .map(|(_, names)| names)
        .filter_map(|names| {
            let entities = resolve_leg(names, &named)?;
            solve_leg(entities, &nodes, &mut globals)
        })
        .collect();

    let mut mutable_pose = pose.p1();
    for solution in solutions {
        if let Ok(mut transform) = mutable_pose.get_mut(solution.upper) {
            transform.rotation = solution.upper_rotation;
        }
        if let Ok(mut transform) = mutable_pose.get_mut(solution.lower) {
            transform.rotation = solution.lower_rotation;
        }
        if let Ok(mut transform) = mutable_pose.get_mut(solution.foot) {
            transform.rotation = solution.foot_rotation;
        }
    }
}

pub fn measure_toe_target_error(
    pose: Query<(&Name, &GlobalTransform)>,
    mut diagnostics: ResMut<FootIkDiagnostics>,
) {
    let mut right_toe = None;
    let mut right_target = None;
    let mut left_toe = None;
    let mut left_target = None;
    for (name, global) in &pose {
        let translation = global.translation();
        match name.as_str() {
            "RIGHTTOEBASE" => right_toe = Some(translation),
            "RIGHTTOEBASE_REPARENTED" => right_target = Some(translation),
            "LEFTTOEBASE" => left_toe = Some(translation),
            "LEFTTOEBASE_REPARENTED" => left_target = Some(translation),
            _ => {}
        }
    }

    let Some((right_toe, right_target, left_toe, left_target)) = right_toe
        .zip(right_target)
        .zip(left_toe.zip(left_target))
        .map(|((right_toe, right_target), (left_toe, left_target))| {
            (right_toe, right_target, left_toe, left_target)
        })
    else {
        *diagnostics = FootIkDiagnostics::default();
        return;
    };

    diagnostics.right_error_metres = right_toe.distance(right_target);
    diagnostics.left_error_metres = left_toe.distance(left_target);
    diagnostics.targets_resolved = true;
}

fn resolve_leg(names: LegNames, named: &HashMap<String, Entity>) -> Option<LegEntities> {
    Some(LegEntities {
        upper: *named.get(names.upper)?,
        lower: *named.get(names.lower)?,
        foot: *named.get(names.foot)?,
        toe: *named.get(names.toe)?,
        target: *named.get(names.target)?,
    })
}

fn solve_leg(
    leg: LegEntities,
    nodes: &HashMap<Entity, PoseNode>,
    globals: &mut HashMap<Entity, Affine3A>,
) -> Option<LegSolution> {
    let upper_world = global_affine(leg.upper, nodes, globals)?;
    let lower_world = global_affine(leg.lower, nodes, globals)?;
    let foot_world = global_affine(leg.foot, nodes, globals)?;
    let toe_world = global_affine(leg.toe, nodes, globals)?;
    let target_toe_world = global_affine(leg.target, nodes, globals)?;
    let upper_parent = nodes.get(&leg.upper)?.parent?;
    let upper_parent_world = global_affine(upper_parent, nodes, globals)?;

    // The target channel describes the toe matrix. Recover the ankle/foot
    // matrix using the currently evaluated retail foot-to-toe local transform.
    let foot_to_toe = foot_world.inverse() * toe_world;
    let desired_foot_world = target_toe_world * foot_to_toe.inverse();

    let (_, upper_world_rotation, hip) = upper_world.to_scale_rotation_translation();
    let (_, lower_world_rotation, knee) = lower_world.to_scale_rotation_translation();
    let (_, _, ankle) = foot_world.to_scale_rotation_translation();
    let (_, desired_foot_rotation, desired_ankle) =
        desired_foot_world.to_scale_rotation_translation();
    let (_, upper_parent_rotation, _) = upper_parent_world.to_scale_rotation_translation();

    let upper_length = hip.distance(knee);
    let lower_length = knee.distance(ankle);
    let desired_knee = solve_two_bone_knee(hip, knee, desired_ankle, upper_length, lower_length)?;

    let upper_delta =
        Quat::from_rotation_arc((knee - hip).normalize(), (desired_knee - hip).normalize());
    let desired_upper_world_rotation = (upper_delta * upper_world_rotation).normalize();
    let lower_delta = Quat::from_rotation_arc(
        (ankle - knee).normalize(),
        (desired_ankle - desired_knee).normalize(),
    );
    let desired_lower_world_rotation = (lower_delta * lower_world_rotation).normalize();

    Some(LegSolution {
        upper: leg.upper,
        upper_rotation: (upper_parent_rotation.inverse() * desired_upper_world_rotation)
            .normalize(),
        lower: leg.lower,
        lower_rotation: (desired_upper_world_rotation.inverse() * desired_lower_world_rotation)
            .normalize(),
        foot: leg.foot,
        foot_rotation: (desired_lower_world_rotation.inverse() * desired_foot_rotation).normalize(),
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

/// Closed-form two-segment solve used by the retail matrix path: preserve the
/// animated bend plane, then place the knee at the triangle solution formed by
/// upper length, lower length, and target distance.
fn solve_two_bone_knee(
    hip: Vec3,
    animated_knee: Vec3,
    target_ankle: Vec3,
    upper_length: f32,
    lower_length: f32,
) -> Option<Vec3> {
    const EPSILON: f32 = 1.0e-6;
    if upper_length <= EPSILON || lower_length <= EPSILON {
        return None;
    }

    let target_offset = target_ankle - hip;
    let raw_distance = target_offset.length();
    if raw_distance <= EPSILON {
        return None;
    }
    let direction = target_offset / raw_distance;
    let minimum = (upper_length - lower_length).abs() + EPSILON;
    let maximum = upper_length + lower_length - EPSILON;
    let distance = raw_distance.clamp(minimum, maximum);
    let along = (upper_length * upper_length - lower_length * lower_length + distance * distance)
        / (2.0 * distance);
    let height_squared = (upper_length * upper_length - along * along).max(0.0);

    let animated_offset = animated_knee - hip;
    let projected = animated_offset - direction * animated_offset.dot(direction);
    let pole = if projected.length_squared() > EPSILON * EPSILON {
        projected.normalize()
    } else {
        direction.any_orthonormal_vector()
    };
    Some(hip + direction * along + pole * height_squared.sqrt())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unchanged_target_reproduces_the_animated_knee() {
        let hip = Vec3::new(0.0, 0.0, 1.0);
        let knee = Vec3::new(0.12, 0.03, 0.58);
        let ankle = Vec3::new(-0.04, -0.07, 0.18);
        let solved =
            solve_two_bone_knee(hip, knee, ankle, hip.distance(knee), knee.distance(ankle))
                .unwrap();
        assert!(solved.distance(knee) < 1.0e-5);
    }

    #[test]
    fn solved_chain_preserves_both_segment_lengths() {
        let hip = Vec3::new(0.0, 0.0, 1.0);
        let knee = Vec3::new(0.12, 0.03, 0.58);
        let ankle = Vec3::new(-0.04, -0.07, 0.18);
        let target = Vec3::new(0.03, -0.12, 0.20);
        let upper_length = hip.distance(knee);
        let lower_length = knee.distance(ankle);
        let solved = solve_two_bone_knee(hip, knee, target, upper_length, lower_length).unwrap();
        assert!((hip.distance(solved) - upper_length).abs() < 1.0e-5);
        assert!((solved.distance(target) - lower_length).abs() < 1.0e-5);
    }
}
