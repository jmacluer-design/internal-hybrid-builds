"""Bake legacy double-composition actions for offline comparison only.

The standard ABIN importer has already applied each clip delta to RIG_TPOSE,
producing the physical full-pose actions selected by the retail graph. These
COMBINED actions apply the delta again over an Ollie/Nollie action. Captured
gameplay and exported rider-axis measurements proved that this rotates the
rider sideways or upside-down, so no runtime route may select these actions.
They remain in the private bank as reproducible negative-control artifacts.
"""

from pathlib import Path
import sys

import bpy


TOE_TARGET_PAIRS = (
    ("RIGHTTOEBASE", "RIGHTTOEBASE_REPARENTED"),
    ("LEFTTOEBASE", "LEFTTOEBASE_REPARENTED"),
)
MAXIMUM_TOE_TARGET_DISTANCE_METRES = 0.05

SPECS = (
    ("OLLIE_LOW_G", "KICKFLIP_IN_LOW_G", "COMBINED_KICKFLIP_LOW_G"),
    ("OLLIE_LOW_A", "KICKFLIP_IN_LOW_A", "COMBINED_KICKFLIP_LOW_A"),
    ("OLLIE_HIGH_G", "KICKFLIP_IN_HIGH_G", "COMBINED_KICKFLIP_HIGH_G"),
    ("OLLIE_HIGH_A", "KICKFLIP_IN_HIGH_A", "COMBINED_KICKFLIP_HIGH_A"),
    ("OLLIE_LOW_G", "HEELFLIP_IN_LOW_G", "COMBINED_HEELFLIP_LOW_G"),
    ("OLLIE_LOW_A", "HEELFLIP_IN_LOW_A", "COMBINED_HEELFLIP_LOW_A"),
    ("OLLIE_HIGH_G", "HEELFLIP_IN_HIGH_G", "COMBINED_HEELFLIP_HIGH_G"),
    ("OLLIE_HIGH_A", "HEELFLIP_IN_HIGH_A", "COMBINED_HEELFLIP_HIGH_A"),
    ("NOLLIE_LOW_G", "N_KICKFLIP_IN_LOW_G", "COMBINED_N_KICKFLIP_LOW_G"),
    ("NOLLIE_LOW_A", "N_KICKFLIP_IN_LOW_A", "COMBINED_N_KICKFLIP_LOW_A"),
    ("NOLLIE_HIGH_G", "N_KICKFLIP_IN_HIGH_G", "COMBINED_N_KICKFLIP_HIGH_G"),
    ("NOLLIE_HIGH_A", "N_KICKFLIP_IN_HIGH_A", "COMBINED_N_KICKFLIP_HIGH_A"),
    ("NOLLIE_LOW_G", "N_HEELFLIP_IN_LOW_G", "COMBINED_N_HEELFLIP_LOW_G"),
    ("NOLLIE_LOW_A", "N_HEELFLIP_IN_LOW_A", "COMBINED_N_HEELFLIP_LOW_A"),
    ("NOLLIE_HIGH_G", "N_HEELFLIP_IN_HIGH_G", "COMBINED_N_HEELFLIP_HIGH_G"),
    ("NOLLIE_HIGH_A", "N_HEELFLIP_IN_HIGH_A", "COMBINED_N_HEELFLIP_HIGH_A"),
    ("OLLIE_LOW_G", "360FLIP_D_LOW_G", "COMBINED_360FLIP_LOW_G"),
    ("OLLIE_LOW_A", "360FLIP_D_LOW_A", "COMBINED_360FLIP_LOW_A"),
    ("OLLIE_HIGH_G", "360FLIP_D_HIGH_G", "COMBINED_360FLIP_HIGH_G"),
    ("OLLIE_HIGH_A", "360FLIP_D_HIGH_A", "COMBINED_360FLIP_HIGH_A"),
)


def parse_args():
    if "--" not in sys.argv:
        raise RuntimeError("Expected OnBoard ABIN and importer directory after --")
    tail = sys.argv[sys.argv.index("--") + 1 :]
    if len(tail) != 2:
        raise RuntimeError(
            "Usage: blender source.blend --python add_combined_flip_actions.py "
            "-- OnBoard.abin importer_directory"
        )
    return Path(tail[0]).resolve(), Path(tail[1]).resolve()


def remove_action(name):
    action = bpy.data.actions.get(name)
    if action is not None:
        bpy.data.actions.remove(action)


def sample_compact_target_relations(
    armature, source_action, frame_start, frame_end
):
    """Sample native toe-to-target matrices from compact channels 32/33."""
    animation_data = armature.animation_data
    animation_data.action = source_action
    relations = {}
    for frame in range(frame_start, frame_end + 1):
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        relations[frame] = {
            target_name: (
                armature.pose.bones[toe_name].matrix.inverted()
                @ armature.pose.bones[target_name].matrix
            )
            for toe_name, target_name in TOE_TARGET_PAIRS
        }
    animation_data.action = None
    return relations


def bake_combined_action(
    armature,
    base_action,
    raw_action,
    output_name,
    compact_target_relations,
):
    animation_data = armature.animation_data
    animation_data.action = None
    base_track = animation_data.nla_tracks.new()
    base_track.name = f"__COMBINE_BASE__{output_name}"
    base_strip = base_track.strips.new(base_action.name, 1, base_action)
    base_strip.extrapolation = "NOTHING"
    base_strip.blend_type = "REPLACE"
    base_strip.influence = 1.0
    delta_track = animation_data.nla_tracks.new()
    delta_track.name = f"__COMBINE_DELTA__{output_name}"
    delta_strip = delta_track.strips.new(raw_action.name, 1, raw_action)
    delta_strip.extrapolation = "NOTHING"
    delta_strip.blend_type = "COMBINE"
    delta_strip.influence = 1.0

    frame_start = int(raw_action.frame_range[0])
    frame_end = int(raw_action.frame_range[1])
    samples = {}
    previous_rotations = {}
    try:
        for frame in range(frame_start, frame_end + 1):
            bpy.context.scene.frame_set(frame)
            bpy.context.view_layer.update()

            # The standard RX2 rig maps only 31 of the compact OnBoard bank's
            # 36 channels, so Blender's temporary raw AddSQT layer cannot
            # carry the two board-parented foot targets. Reconstruct their
            # authored armature-space matrices from the combined toe pose and
            # the exact native toe-to-target relation sampled above. Assigning
            # through pose_bone.matrix converts that result back through the
            # evaluated skateboard parent/rest basis before keys are baked.
            for toe_name, target_name in TOE_TARGET_PAIRS:
                toe_matrix = armature.pose.bones[toe_name].matrix.copy()
                armature.pose.bones[target_name].matrix = (
                    toe_matrix
                    @ compact_target_relations[frame][target_name]
                )
            bpy.context.view_layer.update()

            frame_samples = {}
            for pose_bone in armature.pose.bones:
                location, rotation, scale = pose_bone.matrix_basis.decompose()
                previous = previous_rotations.get(pose_bone.name)
                if previous is not None and previous.dot(rotation) < 0.0:
                    rotation.negate()
                previous_rotations[pose_bone.name] = rotation.copy()
                frame_samples[pose_bone.name] = (
                    location.copy(),
                    rotation.copy(),
                    scale.copy(),
                )
            samples[frame] = frame_samples
    finally:
        animation_data.nla_tracks.remove(delta_track)
        animation_data.nla_tracks.remove(base_track)

    remove_action(output_name)
    output = bpy.data.actions.new(output_name)
    output.use_fake_user = True
    animation_data.action = output
    for frame, frame_samples in samples.items():
        for bone_name, (location, rotation, scale) in frame_samples.items():
            pose_bone = armature.pose.bones[bone_name]
            pose_bone.rotation_mode = "QUATERNION"
            pose_bone.location = location
            pose_bone.rotation_quaternion = rotation
            pose_bone.scale = scale
            pose_bone.keyframe_insert(
                data_path="location", frame=frame, group=bone_name
            )
            pose_bone.keyframe_insert(
                data_path="rotation_quaternion", frame=frame, group=bone_name
            )
            pose_bone.keyframe_insert(
                data_path="scale", frame=frame, group=bone_name
            )
    animation_data.action = None
    maximum_toe_target_distance = 0.0
    animation_data.action = output
    for frame in range(frame_start, frame_end + 1):
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        for toe_name, target_name in TOE_TARGET_PAIRS:
            toe = armature.pose.bones[toe_name].matrix.translation
            target = armature.pose.bones[target_name].matrix.translation
            maximum_toe_target_distance = max(
                maximum_toe_target_distance,
                (toe - target).length,
            )
    animation_data.action = None
    if maximum_toe_target_distance > MAXIMUM_TOE_TARGET_DISTANCE_METRES:
        raise RuntimeError(
            f"{output_name}: composed toe-target distance "
            f"{maximum_toe_target_distance:.9g} m exceeds "
            f"{MAXIMUM_TOE_TARGET_DISTANCE_METRES:.9g} m"
        )
    return output, maximum_toe_target_distance


def main():
    abin_path, importer_dir = parse_args()
    sys.path.insert(0, str(importer_dir))
    import abin_importer

    data = abin_path.read_bytes()
    abin = abin_importer.AbinFile(data)
    if abin.hierarchy is None:
        raise RuntimeError("OnBoard ABIN does not contain a hierarchy")
    clips = {clip.header.name: clip for clip in abin.clips}
    required_delta_names = {delta for _, delta, _ in SPECS}
    missing = sorted(required_delta_names - clips.keys())
    if missing:
        raise RuntimeError(f"OnBoard ABIN is missing delta clips: {missing}")

    armatures = [obj for obj in bpy.data.objects if obj.type == "ARMATURE"]
    if len(armatures) != 1:
        raise RuntimeError(f"Expected one armature, found {len(armatures)}")
    armature = armatures[0]
    armature.animation_data_create()
    animation_data = armature.animation_data
    original_action = animation_data.action
    original_tracks = list(animation_data.nla_tracks)
    original_mutes = [track.mute for track in original_tracks]
    for track in original_tracks:
        track.mute = True

    try:
        for base_name, delta_name, output_name in SPECS:
            base_action = bpy.data.actions.get(base_name)
            if base_action is None:
                raise RuntimeError(f"Source Blend is missing {base_name}")
            raw_name = f"__RAW_DELTA__{delta_name}"
            remove_action(raw_name)
            abin_importer._apply_clip_to_armature(
                armature,
                data,
                clips[delta_name],
                abin.hierarchy,
                action_name=raw_name,
                quat_conv="XZ_SWAP",
                trans_conv="XZ_SWAP",
                finger_quat_conv="XZ_SWAP",
                push_to_nla=False,
                base_pose_data=None,
                compose_base=False,
            )
            raw_action = animation_data.action
            raw_action.use_fake_user = False
            animation_data.action = None
            physical_action = bpy.data.actions.get(delta_name)
            if physical_action is None:
                raise RuntimeError(
                    f"Source Blend is missing physical action {delta_name}"
                )
            compact_target_relations = sample_compact_target_relations(
                armature,
                physical_action,
                int(raw_action.frame_range[0]),
                int(raw_action.frame_range[1]),
            )
            output, maximum_toe_target_distance = bake_combined_action(
                armature,
                base_action,
                raw_action,
                output_name,
                compact_target_relations,
            )
            bpy.data.actions.remove(raw_action)
            print(
                f"COMBINED_FLIP_ACTION_OK action={output.name} "
                f"frames={int(output.frame_range[1] - output.frame_range[0] + 1)} "
                "maximum_toe_target_distance_metres="
                f"{maximum_toe_target_distance:.9g}"
            )
    finally:
        animation_data.action = original_action
        for track, mute in zip(original_tracks, original_mutes):
            track.mute = mute

    bpy.ops.wm.save_as_mainfile(filepath=bpy.data.filepath)
    print(f"COMBINED_FLIP_ACTIONS_OK actions={len(SPECS)}")


main()
