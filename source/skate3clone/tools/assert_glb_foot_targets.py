"""Fail when exported combined actions contain displaced OnBoard foot targets.

Run through Blender:
    blender --background --python assert_glb_foot_targets.py -- \
        model.glb COMBINED_ 0.05
"""

from pathlib import Path
import sys

import bpy


TOE_TARGET_PAIRS = (
    ("RIGHTTOEBASE", "RIGHTTOEBASE_REPARENTED"),
    ("LEFTTOEBASE", "LEFTTOEBASE_REPARENTED"),
)


def parse_args():
    if "--" not in sys.argv:
        raise RuntimeError(
            "Expected GLB path, action prefix, and maximum distance after --"
        )
    tail = sys.argv[sys.argv.index("--") + 1 :]
    if len(tail) != 3:
        raise RuntimeError(
            "Usage: blender --background --python "
            "assert_glb_foot_targets.py -- model.glb prefix max_metres"
        )
    path = Path(tail[0]).resolve()
    prefixes = tuple(part for part in tail[1].split(",") if part)
    maximum = float(tail[2])
    if not path.is_file():
        raise RuntimeError(f"GLB is missing: {path}")
    if not prefixes:
        raise RuntimeError("Action prefix cannot be empty")
    if maximum <= 0.0:
        raise RuntimeError("Maximum distance must be positive")
    return path, prefixes, maximum


def main():
    path, prefixes, allowed_maximum = parse_args()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(path))

    armatures = [obj for obj in bpy.data.objects if obj.type == "ARMATURE"]
    if len(armatures) != 1:
        raise RuntimeError(
            f"Expected one imported armature, found {len(armatures)}"
        )
    armature = armatures[0]
    armature.animation_data_create()
    for track in armature.animation_data.nla_tracks:
        track.mute = True

    missing_bones = sorted(
        {
            name
            for pair in TOE_TARGET_PAIRS
            for name in pair
            if name not in armature.pose.bones
        }
    )
    if missing_bones:
        raise RuntimeError(f"Imported GLB is missing bones: {missing_bones}")

    actions = sorted(
        (
            action
            for action in bpy.data.actions
            if any(action.name.startswith(prefix) for prefix in prefixes)
        ),
        key=lambda action: action.name,
    )
    if not actions:
        raise RuntimeError(f"No imported actions start with any of {prefixes!r}")

    overall_maximum = 0.0
    worst = None
    for action in actions:
        armature.animation_data.action = action
        frame_start = int(action.frame_range[0])
        frame_end = int(action.frame_range[1])
        action_maximum = 0.0
        for frame in range(frame_start, frame_end + 1):
            bpy.context.scene.frame_set(frame)
            bpy.context.view_layer.update()
            for toe_name, target_name in TOE_TARGET_PAIRS:
                toe = armature.pose.bones[toe_name].matrix.translation
                target = armature.pose.bones[target_name].matrix.translation
                distance = float((toe - target).length)
                action_maximum = max(action_maximum, distance)
                if distance > overall_maximum:
                    overall_maximum = distance
                    worst = (action.name, frame, toe_name, distance)
        print(
            "GLB_FOOT_TARGET_ACTION_OK "
            f"action={action.name} "
            f"maximum_distance_metres={action_maximum:.9g}"
        )

    armature.animation_data.action = None
    if overall_maximum > allowed_maximum:
        action_name, frame, toe_name, distance = worst
        raise RuntimeError(
            "Exported foot target is displaced: "
            f"action={action_name} frame={frame} toe={toe_name} "
            f"distance={distance:.9g} m allowed={allowed_maximum:.9g} m"
        )
    print(
        "GLB_FOOT_TARGETS_OK "
        f"path={path} actions={len(actions)} "
        f"maximum_distance_metres={overall_maximum:.9g} "
        f"allowed_metres={allowed_maximum:.9g}"
    )


main()
