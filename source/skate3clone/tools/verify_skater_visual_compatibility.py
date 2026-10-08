#!/usr/bin/env python3
"""Verify the private textured skater can use the external animation bank."""

from __future__ import annotations

import json
import os
from pathlib import Path
import struct
import sys


ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOT = ROOT / "assets"
ANIMATION_DEFAULT = "private/default_skate3_skater.glb"
VISUAL_DEFAULT = "private/default_skate3_skater.glb"
EXPECTED_ANIMATIONS = 2580
REQUIRED_ANIMATIONS = {
    "R_IDLE_HCOM_000",
    "MIRRORED__R_IDLE_HCOM_000",
    "RETAIL__B_FAKIE_CHANNEL__R_IDLE_HCOM_000",
}
POST_ANIMATION_IK_TARGETS = {
    "LEFTHAND_REPARENTED",
    "RIGHTHAND_REPARENTED",
}
EXPECTED_VISUAL_PRIMITIVES = 10
EXPECTED_TEXTURED_MATERIALS = 10


class VerificationError(RuntimeError):
    """The ignored private skater assets are missing or incompatible."""


def configured_asset(environment_name: str, default: str) -> tuple[str, Path]:
    relative = os.environ.get(environment_name, "").strip() or default
    relative_path = Path(relative)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise VerificationError(
            f"{environment_name} must stay within the Bevy assets directory"
        )
    # Do not resolve here: assets/private may intentionally be a junction to
    # the user's ignored private-asset integration directory.
    path = ASSET_ROOT / relative_path
    return relative.replace("\\", "/"), path


def read_glb_json(path: Path) -> dict[str, object]:
    if not path.is_file():
        raise VerificationError(f"private skater GLB is missing: {path}")
    data = path.read_bytes()
    if len(data) < 20 or data[:4] != b"glTF":
        raise VerificationError(f"not a binary glTF file: {path}")
    version, declared_length = struct.unpack_from("<II", data, 4)
    json_length, json_type = struct.unpack_from("<I4s", data, 12)
    if (
        version != 2
        or declared_length != len(data)
        or json_type != b"JSON"
        or 20 + json_length > len(data)
    ):
        raise VerificationError(f"invalid GLB header or JSON chunk: {path}")
    try:
        document = json.loads(data[20 : 20 + json_length].decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"invalid glTF JSON in {path}: {error}") from error
    if not isinstance(document, dict):
        raise VerificationError(f"glTF JSON root is not an object: {path}")
    return document


def named_node_paths(document: dict[str, object], label: str) -> dict[str, str]:
    nodes = document.get("nodes")
    if not isinstance(nodes, list):
        raise VerificationError(f"{label} GLB has no node inventory")
    parents: dict[int, int] = {}
    for parent_index, node in enumerate(nodes):
        if not isinstance(node, dict):
            raise VerificationError(f"{label} GLB contains a malformed node")
        for child in node.get("children", []):
            child_index = int(child)
            if child_index in parents:
                raise VerificationError(
                    f"{label} node {child_index} has multiple parents"
                )
            parents[child_index] = parent_index

    paths: dict[str, str] = {}
    for node_index, node in enumerate(nodes):
        name = node.get("name")
        if not isinstance(name, str) or not name:
            raise VerificationError(f"{label} node {node_index} has no stable name")
        if name in paths:
            raise VerificationError(f"{label} has duplicate node name {name}")
        parts: list[str] = []
        cursor: int | None = node_index
        visited: set[int] = set()
        while cursor is not None:
            if cursor in visited:
                raise VerificationError(f"{label} node hierarchy contains a cycle")
            visited.add(cursor)
            ancestor = nodes[cursor]
            parts.append(str(ancestor["name"]))
            cursor = parents.get(cursor)
        paths[name] = "/".join(reversed(parts))
    return paths


def verify() -> None:
    animation_relative, animation_path = configured_asset(
        "SKATE3_PRIVATE_MODEL_PATH", ANIMATION_DEFAULT
    )
    visual_relative, visual_path = configured_asset(
        "SKATE3_PRIVATE_VISUAL_MODEL_PATH", VISUAL_DEFAULT
    )
    animation = read_glb_json(animation_path)
    visual = read_glb_json(visual_path)

    animations = animation.get("animations", [])
    animation_count = len(animations)
    animation_names = {
        item.get("name")
        for item in animations
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }
    missing_animations = sorted(REQUIRED_ANIMATIONS - animation_names)
    if animation_count != EXPECTED_ANIMATIONS or missing_animations:
        raise VerificationError(
            f"animation bank has {animation_count} clips; expected exactly "
            f"{EXPECTED_ANIMATIONS}; missing required clips "
            f"{missing_animations}: {animation_path}"
        )

    meshes = visual.get("meshes", [])
    primitives = sum(
        len(mesh.get("primitives", []))
        for mesh in meshes
        if isinstance(mesh, dict)
    )
    materials = visual.get("materials", [])
    textured_materials = sum(
        isinstance(material, dict)
        and isinstance(material.get("pbrMetallicRoughness"), dict)
        and "baseColorTexture" in material["pbrMetallicRoughness"]
        for material in materials
    )
    normal_materials = sum(
        isinstance(material, dict) and "normalTexture" in material
        for material in materials
    )
    images = visual.get("images", [])
    embedded_images = sum(
        isinstance(image, dict) and "bufferView" in image for image in images
    )
    if (
        primitives != EXPECTED_VISUAL_PRIMITIVES
        or len(materials) != EXPECTED_TEXTURED_MATERIALS
        or textured_materials != EXPECTED_TEXTURED_MATERIALS
        or normal_materials != EXPECTED_TEXTURED_MATERIALS
        or not images
        or embedded_images != len(images)
    ):
        raise VerificationError(
            "textured visual contract failed: "
            f"{primitives} primitives, {len(materials)} materials, "
            f"{textured_materials} base-colour textures, "
            f"{normal_materials} normal textures, "
            f"{embedded_images}/{len(images)} embedded images"
        )

    animation_paths = named_node_paths(animation, "animation")
    visual_paths = named_node_paths(visual, "visual")
    incompatible = [
        name
        for name, path in visual_paths.items()
        if name not in POST_ANIMATION_IK_TARGETS
        and animation_paths.get(name) != path
    ]
    if incompatible:
        raise VerificationError(
            "visual and animation node paths differ: " + ", ".join(incompatible)
        )

    print(
        "[Skater visual] verified "
        f"{visual_relative}: {primitives} textured primitives, "
        f"{len(images)} embedded images, {len(visual_paths)} compatible nodes; "
        f"{animation_relative}: {animation_count} animation clips"
    )


if __name__ == "__main__":
    try:
        verify()
    except (OSError, VerificationError) as error:
        print(f"[Skater visual] verification failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
