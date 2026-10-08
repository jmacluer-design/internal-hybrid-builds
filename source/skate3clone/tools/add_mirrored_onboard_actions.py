"""Bake Andale's complete mirrored onboard action bank for Bevy.

Decoded R_SWITCH_RIDE_N_0_N ends in the ordinary riding pose reflected across
SKATEBOARD_ROOT's local Y plane with left/right character chains exchanged,
corroborating the static Andale::Mirror -> AnimCommandSystem::Mirror path.
Skate 3 applies that operation after animation evaluation, so riding,
anticipation, tricks, landing, push, fakie channels, and their handoffs all
share one stance operation. Bevy has no equivalent animation-graph command;
this exporter therefore bakes a mirrored partner for every source action.
"""

from __future__ import annotations

import math

import bpy
from mathutils import Matrix


PREFIX = "MIRRORED__"
BOARD = "SKATEBOARD_ROOT"
HIPS = "HIPS"
TARGET_PAIRS = (
    ("RIGHTTOEBASE_REPARENTED", "LEFTTOEBASE_REPARENTED"),
)
MIRROR = Matrix.Diagonal((1.0, -1.0, 1.0, 1.0))


def paired_name(name: str, available: set[str]) -> str:
    if name.startswith("LEFT"):
        paired = "RIGHT" + name[4:]
        return paired if paired in available else name
    if name.startswith("RIGHT"):
        paired = "LEFT" + name[5:]
        return paired if paired in available else name
    return name


def descendants(root: bpy.types.PoseBone) -> set[str]:
    result = {root.name}
    pending = list(root.children)
    while pending:
        bone = pending.pop()
        result.add(bone.name)
        pending.extend(bone.children)
    return result


def remove_action(name: str) -> None:
    action = bpy.data.actions.get(name)
    if action is not None:
        bpy.data.actions.remove(action)


def sample_mirrored_pose(armature, source, frame, mirrored_names, all_names):
    armature.animation_data.action = source
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()
    source_matrices = {
        bone.name: bone.matrix.copy() for bone in armature.pose.bones
    }
    board = source_matrices[BOARD]
    inverse_board = board.inverted()
    desired = dict(source_matrices)
    for name in mirrored_names:
        paired = paired_name(name, all_names)
        local = inverse_board @ source_matrices[paired]
        desired[name] = board @ MIRROR @ local @ MIRROR
    return desired


def apply_pose_and_key(armature, desired, frame):
    def depth(bone):
        result = 0
        parent = bone.parent
        while parent is not None:
            result += 1
            parent = parent.parent
        return result

    # Matrix assignment is converted through the current parent pose. Apply
    # parents first and evaluate each assignment so no child is solved against
    # a stale parent matrix.
    bones = sorted(armature.pose.bones, key=depth)
    for bone in bones:
        bone.rotation_mode = "QUATERNION"
        bone.matrix = desired[bone.name]
        bpy.context.view_layer.update()
    for bone in bones:
        location, rotation, scale = bone.matrix_basis.decompose()
        bone.location = location
        bone.rotation_quaternion = rotation
        bone.scale = scale
        bone.keyframe_insert(data_path="location", frame=frame, group=bone.name)
        bone.keyframe_insert(
            data_path="rotation_quaternion", frame=frame, group=bone.name
        )
        bone.keyframe_insert(data_path="scale", frame=frame, group=bone.name)


def bake_action(armature, source, output_name, mirrored_names, all_names):
    start, end = (int(value) for value in source.frame_range)
    samples = {
        frame: sample_mirrored_pose(
            armature, source, frame, mirrored_names, all_names
        )
        for frame in range(start, end + 1)
    }
    remove_action(output_name)
    output = bpy.data.actions.new(output_name)
    output.use_fake_user = True
    armature.animation_data.action = output
    for frame, desired in samples.items():
        apply_pose_and_key(armature, desired, frame)
    armature.animation_data.action = None
    return output


def pose_error(
    armature,
    action,
    frame,
    reference,
    reference_frame,
    board_reference,
    board_reference_frame,
    names,
):
    armature.animation_data.action = action
    bpy.context.scene.frame_set(frame)
    bpy.context.view_layer.update()
    actual = {name: armature.pose.bones[name].matrix.copy() for name in names}
    board_actual = armature.pose.bones[BOARD].matrix.copy()
    armature.animation_data.action = reference
    bpy.context.scene.frame_set(reference_frame)
    bpy.context.view_layer.update()
    squared = 0.0
    count = 0
    for name in names:
        delta = actual[name] - armature.pose.bones[name].matrix
        for row in range(3):
            for column in range(4):
                squared += delta[row][column] ** 2
                count += 1
    armature.animation_data.action = board_reference
    bpy.context.scene.frame_set(board_reference_frame)
    bpy.context.view_layer.update()
    board_delta = board_actual - armature.pose.bones[BOARD].matrix
    board_max = max(
        abs(board_delta[row][column])
        for row in range(4)
        for column in range(4)
    )
    return math.sqrt(squared / count), board_max


def source_actions():
    sources = [
        action
        for action in bpy.data.actions
        if not action.name.startswith(PREFIX)
    ]
    sources.sort(key=lambda action: action.name)
    if not sources:
        raise RuntimeError("Source Blend contains no actions to mirror")
    return sources


def main() -> None:
    armatures = [obj for obj in bpy.data.objects if obj.type == "ARMATURE"]
    if len(armatures) != 1:
        raise RuntimeError(f"Expected one armature, found {len(armatures)}")
    armature = armatures[0]
    armature.animation_data_create()
    animation_data = armature.animation_data
    original_action = animation_data.action
    tracks = list(animation_data.nla_tracks)
    track_mutes = [track.mute for track in tracks]
    for track in tracks:
        track.mute = True

    all_names = {bone.name for bone in armature.pose.bones}
    mirrored_names = descendants(armature.pose.bones[HIPS])
    for left, right in TARGET_PAIRS:
        if left not in all_names or right not in all_names:
            raise RuntimeError(f"Missing mirrored SkeletonIK pair: {left}, {right}")
        mirrored_names.update((left, right))

    try:
        sources = source_actions()
        for source in sources:
            output_name = PREFIX + source.name
            output = bake_action(
                armature, source, output_name, mirrored_names, all_names
            )
            print(
                f"MIRRORED_ONBOARD_ACTION_OK action={output.name} "
                f"frames={int(output.frame_range[1] - output.frame_range[0] + 1)}"
            )

        switch = bpy.data.actions.get("R_SWITCH_RIDE_N_0_N")
        if switch is None:
            raise RuntimeError("Source Blend is missing R_SWITCH_RIDE_N_0_N")
        body_names = (
            "HIPS",
            "SPINE",
            "SPINE3",
            "HEAD",
            "RIGHTUPLEG",
            "RIGHTLEG",
            "RIGHTFOOT",
            "LEFTUPLEG",
            "LEFTLEG",
            "LEFTFOOT",
        )
        rms, board_max = pose_error(
            armature,
            bpy.data.actions[PREFIX + "R_IDLE_HCOM_000"],
            3,
            switch,
            int(switch.frame_range[1]),
            bpy.data.actions["R_IDLE_HCOM_000"],
            3,
            body_names,
        )
        if rms > 0.03 or board_max > 1.0e-5:
            raise RuntimeError(
                "Decoded switch endpoint no longer matches mirrored riding: "
                f"body_rms={rms:.9g} board_max={board_max:.9g}"
            )
        print(
            "MIRRORED_RIDING_EVIDENCE_OK "
            f"body_rms={rms:.9g} board_max={board_max:.9g}"
        )
    finally:
        animation_data.action = original_action
        for track, mute in zip(tracks, track_mutes):
            track.mute = mute

    bpy.ops.wm.save_as_mainfile(filepath=bpy.data.filepath)
    print(f"MIRRORED_ONBOARD_ACTIONS_OK actions={len(sources)}")


main()
