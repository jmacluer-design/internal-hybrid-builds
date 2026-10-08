"""Bake Skate 3's B_FAKIE_CHANNEL over every active animation.

FakieHeadChannel is attached globally in MotionGraph_OnBoard.xml. Retail's
ChannelBlend evaluates the current MotionGraph action and the fakie channel
together, using the OnBoard.abin per-bone weights:

    SPINE2 0.5, SPINE3 0.7, NECK 1.0, NECK1 1.0, HEAD 1.0

The previous Bevy adaptation baked that result only over R_IDLE_HCOM_000.
That made the correct pose available after landing, but it could not preserve
an active airborne trick or landing pose. This exporter copies every source
action and replaces only those five local quaternion curves with the exact
weighted channel result. Runtime can then blend toward the matching composite
during the authored 0.3-second request instead of snapping to an idle-based
fakie action when the trick owner releases.
"""

from __future__ import annotations

import math

import bpy
from mathutils import Quaternion


SOURCE = "FAKIE_CHANNEL_CYC"
REFERENCE = "R_IDLE_HCOM_000"
LEGACY_REFERENCE_OUTPUT = "RETAIL__B_FAKIE_CHANNEL__R_IDLE_HCOM_000"
OUTPUT_PREFIX = "RETAIL__B_FAKIE_CHANNEL__"
MIRRORED_PREFIX = "MIRRORED__"
OBSOLETE_OUTPUT = "REBASED__FAKIE_CHANNEL_CYC"
SOURCE_SAMPLE_COUNT = 50
CHANNEL_WEIGHTS = {
    "SPINE2": 0.5,
    "SPINE3": 0.7,
    "NECK": 1.0,
    "NECK1": 1.0,
    "HEAD": 1.0,
}


def iter_fcurves(action):
    for layer in action.layers:
        for strip in layer.strips:
            for channelbag in strip.channelbags:
                yield from channelbag.fcurves


def remove_action(name: str) -> None:
    action = bpy.data.actions.get(name)
    if action is not None:
        bpy.data.actions.remove(action)


def output_name(source_name: str) -> str:
    if source_name == REFERENCE:
        return LEGACY_REFERENCE_OUTPUT
    return OUTPUT_PREFIX + source_name


def quaternion_curves(action, bone_name: str):
    path = f'pose.bones["{bone_name}"].rotation_quaternion'
    curves = {
        curve.array_index: curve
        for curve in iter_fcurves(action)
        if curve.data_path == path
    }
    if curves.keys() != {0, 1, 2, 3}:
        raise RuntimeError(
            f"{action.name} has incomplete quaternion curves for {bone_name}: "
            f"{sorted(curves)}"
        )
    return curves


def evaluate_quaternion(curves, frame: float) -> Quaternion:
    result = Quaternion(tuple(curves[index].evaluate(frame) for index in range(4)))
    result.normalize()
    return result


def normalized_lerp(left: Quaternion, right: Quaternion, amount: float) -> Quaternion:
    right = right.copy()
    if left.dot(right) < 0.0:
        right.negate()
    result = Quaternion(
        tuple(
            (1.0 - amount) * left[index] + amount * right[index]
            for index in range(4)
        )
    )
    result.normalize()
    return result


def sample_looped_source(source_curves, sample_position: float) -> Quaternion:
    lower = math.floor(sample_position)
    fraction = sample_position - lower
    first_frame = 1 + lower % SOURCE_SAMPLE_COUNT
    second_frame = 1 + (lower + 1) % SOURCE_SAMPLE_COUNT
    first = evaluate_quaternion(source_curves, first_frame)
    second = evaluate_quaternion(source_curves, second_frame)
    return normalized_lerp(first, second, fraction)


def set_key_value(curve, frame: float, value: float) -> None:
    for point in curve.keyframe_points:
        if abs(point.co.x - frame) <= 1.0e-4:
            difference = value - point.co.y
            point.co.y = value
            point.handle_left.y += difference
            point.handle_right.y += difference
            return
    point = curve.keyframe_points.insert(frame, value)
    point.interpolation = "LINEAR"


def source_actions():
    actions = [
        action
        for action in bpy.data.actions
        if not action.name.startswith((OUTPUT_PREFIX, MIRRORED_PREFIX))
        and action.name not in (LEGACY_REFERENCE_OUTPUT, OBSOLETE_OUTPUT)
    ]
    actions.sort(key=lambda action: action.name)
    if REFERENCE not in {action.name for action in actions}:
        raise RuntimeError(f"Source Blend is missing {REFERENCE}")
    return actions


def bake_composite(reference, channel_curves):
    name = output_name(reference.name)
    remove_action(name)
    output = reference.copy()
    output.name = name
    output.use_fake_user = True
    start, end = (int(value) for value in reference.frame_range)
    maximum_error = 0.0

    for bone_name, channel_weight in CHANNEL_WEIGHTS.items():
        base_curves = quaternion_curves(reference, bone_name)
        output_curves = quaternion_curves(output, bone_name)
        expected_by_frame = {}
        previous = None
        for frame in range(start, end + 1):
            base = evaluate_quaternion(base_curves, frame)
            # Imported ABIN source leaves keep one key per 30 Hz sample while
            # the private Blender scene and active actions run at 60 Hz.
            channel = sample_looped_source(
                channel_curves[bone_name],
                (frame - start) * 0.5,
            )
            expected = normalized_lerp(base, channel, channel_weight)
            if previous is not None and previous.dot(expected) < 0.0:
                expected.negate()
            previous = expected.copy()
            expected_by_frame[frame] = expected
            for component in range(4):
                set_key_value(output_curves[component], frame, expected[component])

        for frame, expected in expected_by_frame.items():
            rendered = evaluate_quaternion(output_curves, frame)
            if rendered.dot(expected) < 0.0:
                rendered.negate()
            maximum_error = max(
                maximum_error,
                rendered.rotation_difference(expected).angle,
            )

    if maximum_error > 1.0e-5:
        raise RuntimeError(
            f"{name} weighted quaternion verification failed: "
            f"{maximum_error:.9g} rad"
        )
    return output, maximum_error


def main() -> None:
    armatures = [obj for obj in bpy.data.objects if obj.type == "ARMATURE"]
    if len(armatures) != 1:
        raise RuntimeError(f"Expected one armature, found {len(armatures)}")
    armature = armatures[0]
    missing_bones = CHANNEL_WEIGHTS.keys() - armature.pose.bones.keys()
    if missing_bones:
        raise RuntimeError(f"Missing fakie channel bones: {sorted(missing_bones)}")

    source = bpy.data.actions.get(SOURCE)
    if source is None:
        raise RuntimeError(f"Source Blend is missing {SOURCE}")
    if tuple(int(value) for value in source.frame_range) != (1, SOURCE_SAMPLE_COUNT):
        raise RuntimeError(
            f"{SOURCE} sample range changed: {tuple(source.frame_range)}"
        )
    channel_curves = {
        bone_name: quaternion_curves(source, bone_name)
        for bone_name in CHANNEL_WEIGHTS
    }

    remove_action(OBSOLETE_OUTPUT)
    actions = source_actions()
    maximum_error = 0.0
    for reference in actions:
        output, error = bake_composite(reference, channel_curves)
        maximum_error = max(maximum_error, error)
        print(
            f"RETAIL_FAKIE_ACTION_OK action={output.name} "
            f"frames={int(output.frame_range[1] - output.frame_range[0] + 1)}"
        )

    bpy.ops.wm.save_as_mainfile(filepath=bpy.data.filepath)
    weights = ",".join(
        f"{name}:{weight:g}" for name, weight in CHANNEL_WEIGHTS.items()
    )
    print(
        "RETAIL_FAKIE_ACTION_BANK_OK "
        f"actions={len(actions)} weights={weights} "
        f"maximum_error={maximum_error:.9g}"
    )


main()
