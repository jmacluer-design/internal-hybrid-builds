#!/usr/bin/env python3
"""Deterministic structural validation for the private default-skater GLB."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import sys


COMPONENT_FORMAT = {
    5120: ("b", 1),
    5121: ("B", 1),
    5122: ("h", 2),
    5123: ("H", 2),
    5125: ("I", 4),
    5126: ("f", 4),
}
TYPE_SIZE = {
    "SCALAR": 1,
    "VEC2": 2,
    "VEC3": 3,
    "VEC4": 4,
    "MAT4": 16,
}


def load_glb(path: Path) -> tuple[dict, bytes]:
    data = path.read_bytes()
    if data[:4] != b"glTF" or struct.unpack_from("<I", data, 4)[0] != 2:
        raise RuntimeError(f"Not a glTF 2 GLB: {path}")
    declared = struct.unpack_from("<I", data, 8)[0]
    if declared != len(data):
        raise RuntimeError(f"GLB length mismatch: {declared} != {len(data)}")
    offset = 12
    document = None
    binary = b""
    while offset < len(data):
        length, chunk_type = struct.unpack_from("<II", data, offset)
        offset += 8
        payload = data[offset : offset + length]
        offset += length
        if chunk_type == 0x4E4F534A:
            document = json.loads(payload.rstrip(b" \0").decode("utf-8"))
        elif chunk_type == 0x004E4942:
            binary = payload
    if document is None:
        raise RuntimeError("GLB has no JSON chunk")
    return document, binary


def accessor_values(document: dict, binary: bytes, index: int):
    accessor = document["accessors"][index]
    view = document["bufferViews"][accessor["bufferView"]]
    component_type = accessor["componentType"]
    fmt, component_bytes = COMPONENT_FORMAT[component_type]
    width = TYPE_SIZE[accessor["type"]]
    packed_size = component_bytes * width
    stride = view.get("byteStride", packed_size)
    start = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
    unpack = struct.Struct("<" + fmt * width)
    for item in range(accessor["count"]):
        yield unpack.unpack_from(binary, start + item * stride)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def expected_morph_weight(name: str, retail: dict) -> float:
    body = retail["preset"]["body_mods"]
    if name == "fat" or name.startswith("fat_"):
        return float(body["fatness"])
    if name == "thin" or name.startswith("thin_"):
        return float(body["skinniness"])
    if name in retail["morph_assembly"]["face_targets"]:
        return float(body["face_fields"])
    raise RuntimeError(f"Retail morph target has no recipe mapping: {name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--glb", type=Path, required=True)
    parser.add_argument("--retail-manifest", type=Path, required=True)
    parser.add_argument("--extraction-report", type=Path, required=True)
    parser.add_argument("--material-report", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    retail = json.loads(args.retail_manifest.read_text(encoding="utf-8"))
    extraction = json.loads(args.extraction_report.read_text(encoding="utf-8"))
    material = json.loads(args.material_report.read_text(encoding="utf-8"))
    document, binary = load_glb(args.glb)

    normal_encoding = "dxt5nm-ag-to-gltf-rgb-v1"
    require(
        extraction.get("normal_encoding") == normal_encoding,
        "Extraction report does not identify reconstructed DXT5nm normals",
    )
    require(
        material.get("normal_encoding") == normal_encoding,
        "Material report does not identify reconstructed DXT5nm normals",
    )
    uv_encoding = "rx2-top-left-to-blender-bottom-left-v1"
    require(
        material.get("uv_encoding") == uv_encoding,
        "Material report does not identify the RX2/Blender V-axis conversion",
    )
    tint_encoding = "gltf-linear-base-color-factor-v1"
    require(
        material.get("tint_encoding") == tint_encoding,
        "Material report does not identify the exported retail tint policy",
    )
    alpha_encoding = "gltf-mask-retail-alpha-v1"
    require(
        material.get("alpha_encoding") == alpha_encoding,
        "Material report does not identify the retail hair-cutout policy",
    )
    morph_encoding = "rx2-dense-position-delta-direct-weight-v1"
    require(
        retail["morph_assembly"].get("encoding") == morph_encoding,
        "Retail manifest does not identify the head morph assembly",
    )
    require(
        material.get("morph_encoding") == morph_encoding,
        "Material report does not identify the head morph assembly",
    )
    body_mods = extraction.get("body_mods")
    expected_body_mods = [
        retail["preset"]["body_mods"]["skinniness"],
        retail["preset"]["body_mods"]["fatness"],
        *[
            retail["preset"]["body_mods"]["face_fields"]
            for _ in retail["morph_assembly"]["face_targets"]
        ],
    ]
    require(
        body_mods == expected_body_mods,
        f"Extracted fallback body modifiers changed: "
        f"{body_mods} != {expected_body_mods}",
    )

    animation_names = [animation.get("name", "") for animation in document["animations"]]
    require(
        len(animation_names) == 2580,
        "Expected the current 2580-action regular/fakie/mirrored bank, "
        f"found {len(animation_names)}",
    )
    require(
        len(set(animation_names)) == len(animation_names),
        "GLB animation names are not unique",
    )

    required_actions = {
        "R_IDLE_HCOM_000",
        "OLLIE_LOW_G",
        "360FLIP_D_LOW_G",
        "BR_WALK_FWD_CYC",
        "BR_STAND_0_INTO_MOUNT",
    }
    missing_actions = sorted(required_actions - set(animation_names))
    require(not missing_actions, f"Representative actions missing: {missing_actions}")

    require(len(document.get("skins", [])) == 1, "Expected exactly one runtime skin")
    skin = document["skins"][0]
    joints = skin["joints"]
    require(len(joints) >= 31, f"Runtime skin has too few joints: {len(joints)}")
    joint_names = {document["nodes"][index].get("name", "") for index in joints}
    required_joints = {
        "HIPS",
        "SPINE3",
        "HEAD",
        "LEFTHAND",
        "RIGHTHAND",
        "LEFTFOOT",
        "RIGHTFOOT",
        "SKATEBOARD_ROOT",
    }
    require(
        required_joints <= joint_names,
        f"Runtime skin is missing joints: {sorted(required_joints - joint_names)}",
    )
    ibm_accessor = document["accessors"][skin["inverseBindMatrices"]]
    require(
        ibm_accessor["count"] == len(joints),
        "Inverse-bind matrix count does not match skin joint count",
    )
    for matrix in accessor_values(document, binary, skin["inverseBindMatrices"]):
        require(all(math.isfinite(value) for value in matrix), "Non-finite inverse bind matrix")

    mesh_primitives = [
        primitive
        for mesh in document.get("meshes", [])
        for primitive in mesh["primitives"]
    ]
    require(len(mesh_primitives) == 10, f"Expected 10 modular material primitives, found {len(mesh_primitives)}")
    require(len(document.get("materials", [])) == 10, "Expected one retail material per modular part")
    for component in retail["components"]:
        matching_materials = [
            item
            for item in document["materials"]
            if item.get("name", "").startswith(f"Retail_{component['slot']}_")
        ]
        require(
            len(matching_materials) == 1,
            f"Missing or duplicate material for {component['slot']}",
        )
        pbr = matching_materials[0]["pbrMetallicRoughness"]
        exported_tint = pbr.get("baseColorFactor", [1.0, 1.0, 1.0, 1.0])
        expected_tint = [*component["tint"], 1.0]
        require(
            max(
                abs(exported_tint[index] - expected_tint[index])
                for index in range(4)
            )
            < 2.0e-6,
            f"Retail tint changed for {component['slot']}: "
            f"{exported_tint} != {expected_tint}",
        )
        if component["alpha_mode"] == "MASK":
            require(
                matching_materials[0].get("alphaMode") == "MASK",
                f"{component['slot']} is not exported as a hard alpha cutout",
            )
            exported_cutoff = matching_materials[0].get("alphaCutoff", 0.5)
            require(
                abs(exported_cutoff - component["alpha_cutoff"]) < 1.0e-7,
                f"{component['slot']} alpha cutoff changed: "
                f"{exported_cutoff} != {component['alpha_cutoff']}",
            )
        else:
            require(
                matching_materials[0].get("alphaMode", "OPAQUE") == "OPAQUE",
                f"{component['slot']} unexpectedly enables transparency",
            )
    require(
        all("normalTexture" in item for item in document["materials"]),
        "Every retail component must bind its reconstructed normal texture",
    )

    total_export_vertices = 0
    total_export_indices = 0
    max_weight_error = 0.0
    bounds_min = [float("inf")] * 3
    bounds_max = [float("-inf")] * 3
    material_parts = {part["slot"]: part for part in material["parts"]}
    for primitive in mesh_primitives:
        attributes = primitive["attributes"]
        required_attributes = {"POSITION", "NORMAL", "TEXCOORD_0", "JOINTS_0", "WEIGHTS_0"}
        missing = sorted(required_attributes - set(attributes))
        require(not missing, f"Primitive attributes missing: {missing}")
        position_accessor = document["accessors"][attributes["POSITION"]]
        total_export_vertices += position_accessor["count"]
        for axis in range(3):
            bounds_min[axis] = min(bounds_min[axis], position_accessor["min"][axis])
            bounds_max[axis] = max(bounds_max[axis], position_accessor["max"][axis])
        index_accessor = document["accessors"][primitive["indices"]]
        total_export_indices += index_accessor["count"]
        require(index_accessor["count"] % 3 == 0, "Index count is not triangular")

        weights = list(accessor_values(document, binary, attributes["WEIGHTS_0"]))
        joint_rows = list(accessor_values(document, binary, attributes["JOINTS_0"]))
        require(len(weights) == len(joint_rows), "Joint/weight accessor count mismatch")
        for weight_row, joint_row in zip(weights, joint_rows):
            require(all(math.isfinite(value) for value in weight_row), "Non-finite skin weight")
            require(all(value >= -1.0e-6 for value in weight_row), "Negative skin weight")
            max_weight_error = max(max_weight_error, abs(sum(weight_row) - 1.0))
            require(max(joint_row) < len(joints), "Joint index exceeds skin palette")
        for semantic in ("POSITION", "NORMAL", "TEXCOORD_0"):
            for values in accessor_values(document, binary, attributes[semantic]):
                require(all(math.isfinite(value) for value in values), f"Non-finite {semantic}")

        material_name = document["materials"][primitive["material"]]["name"]
        matching_slots = [
            component["slot"]
            for component in retail["components"]
            if material_name.startswith(f"Retail_{component['slot']}_")
        ]
        require(
            len(matching_slots) == 1,
            f"Cannot identify retail slot for material {material_name}",
        )
        slot = matching_slots[0]
        first_export_uv = next(
            accessor_values(document, binary, attributes["TEXCOORD_0"])
        )
        first_rx2_uv = material_parts[slot]["first_rx2_uv"]
        require(
            max(
                abs(first_export_uv[index] - first_rx2_uv[index])
                for index in range(2)
            )
            < 2.0e-6,
            f"Exported UV V-axis is wrong for {slot}: "
            f"{first_export_uv} != {first_rx2_uv}",
        )
        morph_report = material_parts[slot]["morphs"]
        expected_targets = retail["morph_assembly"]["expected_targets"][slot]
        actual_targets = [
            target["name"] for target in morph_report["targets"]
        ]
        require(
            actual_targets == expected_targets,
            f"Retail morph target order changed for {slot}: "
            f"{actual_targets} != {expected_targets}",
        )
        for target in morph_report["targets"]:
            expected_weight = expected_morph_weight(target["name"], retail)
            require(
                abs(target["weight"] - expected_weight) < 1.0e-7,
                f"Retail morph weight changed for {slot}/{target['name']}: "
                f"{target['weight']} != {expected_weight}",
            )
        first_export_position = next(
            accessor_values(document, binary, attributes["POSITION"])
        )
        first_morphed_position = morph_report[
            "first_morphed_source_position"
        ]
        require(
            max(
                abs(
                    first_export_position[index]
                    - first_morphed_position[index]
                )
                for index in range(3)
            )
            < 2.0e-6,
            f"Exported retail morph assembly changed for {slot}: "
            f"{first_export_position} != {first_morphed_position}",
        )

    rostral_morphs = material_parts["Rostral"]["morphs"]
    require(
        len(rostral_morphs["targets"]) == 19,
        "Expected the retail head's 19 blend-shape streams",
    )
    require(
        rostral_morphs["moved_vertices"] > 0,
        "Fallback face controls did not deform the retail head",
    )
    for slot in ("Arm", "OuterTorso", "Pants"):
        require(
            material_parts[slot]["morphs"]["moved_vertices"] == 0,
            f"Neutral fallback body unexpectedly deforms {slot}",
        )

    require(max_weight_error < 2.0e-4, f"Skin weight sum error is {max_weight_error}")
    extents = [bounds_max[axis] - bounds_min[axis] for axis in range(3)]
    require(all(0.1 < extent < 10.0 for extent in extents), f"Implausible character bounds: {extents}")
    require(material["vertices"] == retail["rig_evidence"]["selected_vertices"], "Retail source vertex total changed")
    require(material["triangles"] == retail["rig_evidence"]["selected_triangles"], "Retail source triangle total changed")
    require(material["generated_weights"] is False, "Generated replacement weights are forbidden")
    require(len(extraction["models"]) == 10, "Extraction model count changed")
    require(len(extraction["textures"]) == 33, "Extraction texture count changed")

    images = document.get("images", [])
    textures = document.get("textures", [])
    require(len(images) >= 18, f"Too few embedded retail material images: {len(images)}")
    require(len(textures) >= 18, f"Too few glTF textures: {len(textures)}")
    images_by_name = {image.get("name", ""): image for image in images}
    for component in retail["components"]:
        slot = component["slot"]
        image_name = f"{slot}_normal"
        require(
            image_name in images_by_name,
            f"Corrected embedded normal texture is missing for {slot}",
        )
        image = images_by_name[image_name]
        view = document["bufferViews"][image["bufferView"]]
        start = view.get("byteOffset", 0)
        embedded = binary[start : start + view["byteLength"]]
        embedded_hash = hashlib.sha256(embedded).hexdigest().upper()
        expected_hash = extraction["material_images"][slot]["normal_sha256"]
        require(
            embedded_hash == expected_hash,
            f"Embedded normal texture changed for {slot}: "
            f"{embedded_hash} != {expected_hash}",
        )

    glb_hash = hashlib.sha256(args.glb.read_bytes()).hexdigest().upper()
    result = {
        "schema": 1,
        "glb": str(args.glb.resolve()),
        "glb_sha256": glb_hash,
        "preset": retail["preset"]["name"],
        "recipe_sha256": retail["preset"]["recipe_sha256"],
        "actions": len(animation_names),
        "skin_joints": len(joints),
        "source_parts": len(material["parts"]),
        "source_vertices": material["vertices"],
        "source_triangles": material["triangles"],
        "export_primitives": len(mesh_primitives),
        "export_vertices": total_export_vertices,
        "export_triangles": total_export_indices // 3,
        "materials": len(document["materials"]),
        "images": len(images),
        "textures": len(textures),
        "max_weight_error": max_weight_error,
        "bounds_min": bounds_min,
        "bounds_max": bounds_max,
        "bounds_extents": extents,
        "extraction_assembly_sha256": extraction["assembly_sha256"],
        "normal_encoding": normal_encoding,
        "uv_encoding": uv_encoding,
        "tint_encoding": tint_encoding,
        "alpha_encoding": alpha_encoding,
        "morph_encoding": morph_encoding,
        "head_morph_targets": len(rostral_morphs["targets"]),
        "head_morphed_vertices": rostral_morphs["moved_vertices"],
        "head_maximum_applied_source_delta": rostral_morphs[
            "maximum_applied_source_delta"
        ],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        "DEFAULT_SKATER_GLB_OK "
        f"actions={result['actions']} parts={result['source_parts']} "
        f"materials={result['materials']} joints={result['skin_joints']} "
        f"sha256={glb_hash}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"DEFAULT_SKATER_GLB_FAILED: {error}", file=sys.stderr)
        raise
