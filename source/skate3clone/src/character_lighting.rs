use bevy::{camera::visibility::RenderLayers, prelude::*, scene::SceneInstanceReady};

use crate::SkaterRoot;

const WORLD_RENDER_LAYER: usize = 0;
const SKATER_FILL_RENDER_LAYER: usize = 1;
pub const UNIVERSITY_SKATER_FILL_LUMENS: f32 = 450.0;

fn skater_render_layers() -> RenderLayers {
    RenderLayers::from_layers(&[WORLD_RENDER_LAYER, SKATER_FILL_RENDER_LAYER])
}

/// The University view must include the fill layer or Bevy excludes the
/// character light while assigning clustered lights to the camera.
pub fn university_camera_render_layers() -> RenderLayers {
    skater_render_layers()
}

pub fn university_fill_light() -> (Name, PointLight, Transform, RenderLayers) {
    (
        Name::new("University skater-only camera fill"),
        PointLight {
            color: Color::srgb(0.88, 0.94, 1.0),
            intensity: UNIVERSITY_SKATER_FILL_LUMENS,
            range: 18.0,
            radius: 1.5,
            shadows_enabled: false,
            affects_lightmapped_mesh_diffuse: false,
            ..default()
        },
        Transform::IDENTITY,
        RenderLayers::layer(SKATER_FILL_RENDER_LAYER),
    )
}

fn tag_scene_if_skater(
    scene_entity: Entity,
    commands: &mut Commands,
    children: &Query<&Children>,
    parents: &Query<&ChildOf>,
    skater_roots: &Query<(), With<SkaterRoot>>,
) {
    let mut ancestor = scene_entity;
    while skater_roots.get(ancestor).is_err() {
        let Ok(parent) = parents.get(ancestor) else {
            return;
        };
        ancestor = parent.parent();
    }

    commands.entity(scene_entity).insert(skater_render_layers());
    for descendant in children.iter_descendants(scene_entity) {
        commands.entity(descendant).insert(skater_render_layers());
    }
}

/// GLTF render layers do not inherit from a [`SceneRoot`]. Wait for Bevy's
/// scene-ready notification, then tag the complete instantiated hierarchy so
/// no mesh can miss its only `Added<Mesh3d>` frame while parenting settles.
pub fn tag_skater_scene_descendants(
    scene_ready: On<SceneInstanceReady>,
    mut commands: Commands,
    children: Query<&Children>,
    parents: Query<&ChildOf>,
    skater_roots: Query<(), With<SkaterRoot>>,
) {
    tag_scene_if_skater(
        scene_ready.entity,
        &mut commands,
        &children,
        &parents,
        &skater_roots,
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn university_camera_sees_world_and_character_fill_layers() {
        let world = RenderLayers::layer(WORLD_RENDER_LAYER);
        let (_, light, _, fill) = university_fill_light();
        let skater = skater_render_layers();
        let camera = university_camera_render_layers();

        assert!(skater.intersects(&world));
        assert!(skater.intersects(&fill));
        assert!(camera.intersects(&world));
        assert!(camera.intersects(&fill));
        assert!(!world.intersects(&fill));
        assert!(!light.affects_lightmapped_mesh_diffuse);
    }

    #[test]
    fn university_character_fill_is_soft_and_bounded() {
        assert!(UNIVERSITY_SKATER_FILL_LUMENS > 0.0);
        assert!(UNIVERSITY_SKATER_FILL_LUMENS <= 500.0);
    }

    #[derive(Component)]
    struct SceneUnderTest;

    fn tag_test_scenes(
        mut commands: Commands,
        scenes: Query<Entity, With<SceneUnderTest>>,
        children: Query<&Children>,
        parents: Query<&ChildOf>,
        skater_roots: Query<(), With<SkaterRoot>>,
    ) {
        for scene in &scenes {
            tag_scene_if_skater(scene, &mut commands, &children, &parents, &skater_roots);
        }
    }

    #[test]
    fn complete_nested_skater_scene_receives_both_layers() {
        let mut app = App::new();
        app.add_systems(Update, tag_test_scenes);

        let root = app.world_mut().spawn(SkaterRoot).id();
        let scene = app.world_mut().spawn(SceneUnderTest).id();
        let node = app.world_mut().spawn_empty().id();
        let mesh = app.world_mut().spawn(Mesh3d::default()).id();
        app.world_mut().entity_mut(root).add_child(scene);
        app.world_mut().entity_mut(scene).add_child(node);
        app.world_mut().entity_mut(node).add_child(mesh);

        let world_scene = app.world_mut().spawn(SceneUnderTest).id();
        let world_mesh = app.world_mut().spawn(Mesh3d::default()).id();
        app.world_mut()
            .entity_mut(world_scene)
            .add_child(world_mesh);

        app.update();

        for entity in [scene, node, mesh] {
            assert_eq!(
                app.world().get::<RenderLayers>(entity),
                Some(&skater_render_layers())
            );
        }
        assert!(app.world().get::<RenderLayers>(world_scene).is_none());
        assert!(app.world().get::<RenderLayers>(world_mesh).is_none());
    }
}
