"""Validate the four physical 360 Flip actions after final GLB export.

Run through Blender:
    blender --background --python assert_glb_360_flip_pose.py -- model.glb
"""

from pathlib import Path
import math
import sys

import bpy
from mathutils import Vector


ACTIONS = (
    "360FLIP_D_LOW_G",
    "360FLIP_D_LOW_A",
    "360FLIP_D_HIGH_G",
    "360FLIP_D_HIGH_A",
)
MAXIMUM_RIDER_AXIS_TILT_DEGREES = 35.0
MINIMUM_AIR_BOARD_ROTATION_DEGREES = 450.0


def parse_args():
    if "--" not in sys.argv:
        raise RuntimeError("Expected a GLB path after --")
    tail = sys.argv[sys.argv.index("--") + 1 :]
    if len(tail) != 1:
        raise RuntimeError(
            "Usage: blender --background --python "
            "assert_glb_360_flip_pose.py -- model.glb"
        )
    path = Path(tail[0]).resolve()
    if not path.is_file():
        raise RuntimeError(f"GLB is missing: {path}")
    return path


def iter_fcurves(action):
    for layer in action.layers:
        for strip in layer.strips:
            for channelbag in strip.channelbags:
                yield from channelbag.fcurves


def keyed_frames(action):
    return sorted(
        {
            float(point.co.x)
            for fcurve in iter_fcurves(action)
            for point in fcurve.keyframe_points
        }
    )


def set_fractional_frame(frame):
    whole = math.floor(frame)
    bpy.context.scene.frame_set(whole, subframe=frame - whole)
    bpy.context.view_layer.update()


def main():
    path = parse_args()
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

    required_bones = (
        "HEAD",
        "LEFTFOOT",
        "RIGHTFOOT",
        "SKATEBOARD_ROOT",
    )
    missing_bones = [
        name for name in required_bones if name not in armature.pose.bones
    ]
    if missing_bones:
        raise RuntimeError(f"Imported GLB is missing bones: {missing_bones}")

    for action_name in ACTIONS:
        action = bpy.data.actions.get(action_name)
        if action is None:
            raise RuntimeError(f"Imported GLB is missing action {action_name}")
        frames = keyed_frames(action)
        if len(frames) < 2:
            raise RuntimeError(
                f"Imported action has fewer than two keyed frames: {action_name}"
            )

        armature.animation_data.action = action
        maximum_tilt = 0.0
        cumulative_board_rotation = 0.0
        previous_board_rotation = None
        for frame in frames:
            set_fractional_frame(frame)
            head = armature.pose.bones["HEAD"].matrix.translation
            feet = (
                armature.pose.bones["LEFTFOOT"].matrix.translation
                + armature.pose.bones["RIGHTFOOT"].matrix.translation
            ) * 0.5
            body_axis = head - feet
            if body_axis.length_squared < 1.0e-8:
                raise RuntimeError(
                    f"{action_name} has a degenerate rider axis at frame {frame}"
                )
            tilt = math.degrees(
                body_axis.normalized().angle(Vector((0.0, 0.0, 1.0)))
            )
            maximum_tilt = max(maximum_tilt, tilt)

            board_rotation = armature.pose.bones[
                "SKATEBOARD_ROOT"
            ].matrix.to_quaternion()
            if previous_board_rotation is not None:
                cumulative_board_rotation += math.degrees(
                    previous_board_rotation.rotation_difference(
                        board_rotation
                    ).angle
                )
            previous_board_rotation = board_rotation

        if maximum_tilt > MAXIMUM_RIDER_AXIS_TILT_DEGREES:
            raise RuntimeError(
                f"{action_name} rotates the rider axis "
                f"{maximum_tilt:.6g} degrees; allowed "
                f"{MAXIMUM_RIDER_AXIS_TILT_DEGREES:.6g}"
            )
        if (
            action_name.endswith("_A")
            and cumulative_board_rotation
            < MINIMUM_AIR_BOARD_ROTATION_DEGREES
        ):
            raise RuntimeError(
                f"{action_name} board rotation is only "
                f"{cumulative_board_rotation:.6g} degrees; required "
                f"{MINIMUM_AIR_BOARD_ROTATION_DEGREES:.6g}"
            )
        print(
            "GLB_360_FLIP_POSE_ACTION_OK "
            f"action={action_name} keyed_frames={len(frames)} "
            f"maximum_rider_axis_tilt_degrees={maximum_tilt:.9g} "
            "cumulative_board_rotation_degrees="
            f"{cumulative_board_rotation:.9g}"
        )

    armature.animation_data.action = None
    print(
        "GLB_360_FLIP_POSE_OK "
        f"path={path} actions={len(ACTIONS)} "
        f"maximum_tilt_degrees={MAXIMUM_RIDER_AXIS_TILT_DEGREES:.9g} "
        "minimum_air_board_rotation_degrees="
        f"{MINIMUM_AIR_BOARD_ROTATION_DEGREES:.9g}"
    )


main()
