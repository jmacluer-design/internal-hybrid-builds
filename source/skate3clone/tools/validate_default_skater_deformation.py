"""Sample representative retail clips and reject exploded or non-finite skinning."""

from __future__ import annotations

import json
import math
from pathlib import Path
import sys

import bpy


REPRESENTATIVE_ACTIONS = (
    "R_IDLE_HCOM_000",
    "R_ANTIC_CROUCH_OLLIE_N_0_INTO",
    "OLLIE_LOW_A",
    "360FLIP_D_HIGH_A",
    "BR_WALK_FWD_CYC",
    "BR_STAND_0_INTO_MOUNT",
    "BR_DISMOUNT_HI_INTO_RUN_FWD",
)


def main() -> None:
    if "--" not in sys.argv:
        raise RuntimeError("Expected GLB and report paths after --")
    tail = sys.argv[sys.argv.index("--") + 1 :]
    if len(tail) != 2:
        raise RuntimeError(
            "Usage: blender --background --python "
            "validate_default_skater_deformation.py -- model.glb report.json"
        )
    glb = Path(tail[0]).resolve()
    report_path = Path(tail[1]).resolve()
    if not glb.is_file():
        raise RuntimeError(f"Default-skater GLB is missing: {glb}")

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(glb))
    armatures = [obj for obj in bpy.data.objects if obj.type == "ARMATURE"]
    meshes = [
        obj
        for obj in bpy.data.objects
        if obj.type == "MESH"
        and any(modifier.type == "ARMATURE" for modifier in obj.modifiers)
    ]
    if len(armatures) != 1 or len(meshes) != 1:
        raise RuntimeError(
            f"Expected one armature and one joined skinned mesh, found "
            f"{len(armatures)} and {len(meshes)}"
        )
    armature = armatures[0]
    mesh_object = meshes[0]
    armature.animation_data_create()
    for track in armature.animation_data.nla_tracks:
        track.mute = True

    missing_actions = [
        name for name in REPRESENTATIVE_ACTIONS if bpy.data.actions.get(name) is None
    ]
    if missing_actions:
        raise RuntimeError(f"Representative deformation actions missing: {missing_actions}")

    samples = []
    depsgraph = bpy.context.evaluated_depsgraph_get()
    for action_name in REPRESENTATIVE_ACTIONS:
        action = bpy.data.actions[action_name]
        armature.animation_data.action = action
        start = int(action.frame_range[0])
        end = int(action.frame_range[1])
        frames = sorted({start, (start + end) // 2, end})
        for frame in frames:
            bpy.context.scene.frame_set(frame)
            bpy.context.view_layer.update()
            for bone in armature.pose.bones:
                if any(
                    not math.isfinite(value)
                    for row in bone.matrix
                    for value in row
                ):
                    raise RuntimeError(
                        f"Non-finite bone transform: {action_name} frame {frame} "
                        f"bone {bone.name}"
                    )
            evaluated = mesh_object.evaluated_get(depsgraph)
            mesh = evaluated.to_mesh()
            try:
                coordinates = [
                    evaluated.matrix_world @ vertex.co for vertex in mesh.vertices
                ]
                if any(
                    not math.isfinite(value)
                    for coordinate in coordinates
                    for value in coordinate
                ):
                    raise RuntimeError(
                        f"Non-finite deformed vertex: {action_name} frame {frame}"
                    )
                minimum = [
                    min(coordinate[axis] for coordinate in coordinates)
                    for axis in range(3)
                ]
                maximum = [
                    max(coordinate[axis] for coordinate in coordinates)
                    for axis in range(3)
                ]
                extents = [
                    maximum[axis] - minimum[axis] for axis in range(3)
                ]
                if any(extent <= 0.01 or extent > 12.0 for extent in extents):
                    raise RuntimeError(
                        f"Exploded/collapsed deformation: {action_name} frame "
                        f"{frame} extents={extents}"
                    )
                samples.append(
                    {
                        "action": action_name,
                        "frame": frame,
                        "vertices": len(coordinates),
                        "bounds_min": minimum,
                        "bounds_max": maximum,
                        "bounds_extents": extents,
                    }
                )
            finally:
                evaluated.to_mesh_clear()

    armature.animation_data.action = None
    report = {
        "schema": 1,
        "glb": str(glb),
        "actions": len(REPRESENTATIVE_ACTIONS),
        "samples": samples,
        "non_finite_transforms": 0,
        "non_finite_vertices": 0,
        "exploded_samples": 0,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        "DEFAULT_SKATER_DEFORMATION_OK "
        f"actions={len(REPRESENTATIVE_ACTIONS)} samples={len(samples)} "
        f"vertices={samples[0]['vertices']}"
    )


main()
