"""Prepare the extracted University scene for the owned-world exporter."""

from __future__ import annotations

from array import array
import hashlib
import json
import math
from pathlib import Path
import re
import sys

import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree


GROUP_1 = "OW_GROUP_1_PRESENTATION_COLLISION"
GROUP_2 = "OW_GROUP_2_NO_PRESENTATION"
GROUP_3 = "OW_GROUP_3_NO_COLLISION"
GROUP_4 = "OW_GROUP_4_GRINDS"
GROUP_5 = "OW_GROUP_5_PATHING"
OWNER_COLLECTION = "UNIVERSITY_EDITABLE_OWNERS"
SPAWN = "OW_SPAWN"
EDITOR_VISUAL_OWNER_ATTRIBUTE = "ow_editor_visual_owner"
EDITOR_COLLISION_OWNER_ATTRIBUTE = "ow_editor_collision_owner"
EDITOR_VISUAL_OWNER_NAMES = "ow_editor_visual_owner_names"
CELL_RE = re.compile(r"c(?:Pres|Sim)_(-?\d+)_(-?\d+)_high\.xsf", re.I)
GUID_RE = re.compile(r"0x[0-9a-fA-F]{16}")
NO_COLLISION_MARKERS = (
    "billboard",
    "cloud",
    "decal",
    "foliage",
    "leaf",
    "leaves",
    "particle",
    "reflection",
    "shadow",
    "shrub",
    "sky",
    "tree",
    "water",
)
# Flat wooden starting deck inside Super Ultra Mega Park.  The height target
# prevents the ray cast from selecting terrain underneath the park structures.
SPAWN_RUNTIME_XZ = (330.0, -710.0)
SPAWN_TARGET_HEIGHT = 132.0
SOLID_COLOR_TEXTURES = {
    # The retail resource is an intentional 16x16 opaque black swatch.
    # Store it as a material constant so the general exporter can continue
    # rejecting accidentally blank texture decodes.
    "0x0000119903e3870a": (0.0, 0.0, 0.0),
}


def _new_group(name: str) -> bpy.types.Collection:
    existing = bpy.data.collections.get(name)
    if existing is not None:
        bpy.data.collections.remove(existing)
    collection = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(collection)
    return collection


def _new_owner_group() -> bpy.types.Collection:
    existing = bpy.data.collections.get(OWNER_COLLECTION)
    if existing is not None:
        for owner in list(existing.objects):
            for child in list(owner.children):
                world_matrix = child.matrix_world.copy()
                child.parent = None
                child.matrix_world = world_matrix
            bpy.data.objects.remove(owner, do_unlink=True)
        bpy.data.collections.remove(existing)
    collection = bpy.data.collections.new(OWNER_COLLECTION)
    bpy.context.scene.collection.children.link(collection)
    return collection


def _default_material() -> bpy.types.Material:
    material = bpy.data.materials.get("MAT_UNIVERSITY_FALLBACK")
    if material is None:
        material = bpy.data.materials.new("MAT_UNIVERSITY_FALLBACK")
        material.diffuse_color = (0.62, 0.62, 0.62, 1.0)
    return material


def _configure_material(material: bpy.types.Material) -> None:
    texture_id = str(material.get("skate3_texture_id", ""))
    solid_color = SOLID_COLOR_TEXTURES.get(texture_id)
    if solid_color is not None:
        retail_image = bpy.data.images.get(texture_id)
        if retail_image is not None:
            retail_image["skate3_allow_blank_rgb"] = True
            retail_image["skate3_constant_rgb"] = solid_color
    image = (
        bpy.data.images.get(texture_id)
        if texture_id and solid_color is None
        else None
    )
    material["ow_flags"] = 1
    material["ow_friction"] = 0.82
    material["ow_restitution"] = 0.0
    material["ow_display_color"] = (
        solid_color
        if solid_color is not None
        else tuple(material.diffuse_color[:3])
    )
    material["ow_roughness"] = 0.68
    material["ow_emissive"] = 0.0
    material["ow_albedo_image"] = image.name if image is not None else ""
    lightmap_texture_id = str(
        material.get("skate3_lightmap_texture_id", "")
    )
    lightmap_image = (
        bpy.data.images.get(lightmap_texture_id)
        if lightmap_texture_id
        else None
    )
    if lightmap_texture_id and lightmap_image is None:
        raise RuntimeError(
            f"{material.name!r} lost retail lightmap image "
            f"{lightmap_texture_id!r}"
        )
    material["ow_lightmap_image"] = (
        lightmap_image.name if lightmap_image is not None else ""
    )
    material["ow_lightmap_encoding"] = (
        "skate3_retail_sqrt_linear_over_4"
        if lightmap_image is not None
        else ""
    )
    material["ow_baked_strength"] = (
        1.0 if lightmap_image is not None else 0.0
    )
    normal_texture_id = str(
        material.get("skate3_normal_texture_id", "")
    )
    normal_image = (
        bpy.data.images.get(normal_texture_id)
        if normal_texture_id
        else None
    )
    if normal_texture_id and normal_image is None:
        raise RuntimeError(
            f"{material.name!r} lost retail normal image "
            f"{normal_texture_id!r}"
        )
    material["ow_normal_image"] = (
        normal_image.name if normal_image is not None else ""
    )
    material["ow_orm_image"] = ""
    material["ow_emissive_image"] = ""
    material["ow_alpha_mode"] = int(material.get("skate3_alpha_mode", 0))
    material["ow_alpha_cutoff"] = float(
        material.get("skate3_alpha_cutoff", 0.5)
    )
    material["ow_audio_surface"] = 3
    material["ow_physics_surface"] = 1
    material["ow_surface_pattern"] = 0
    # Presentation meshes keep their established export ordering, but retail
    # ClusteredMesh objects are now the sole collision authority.
    material["ow_collision_enabled"] = False


def _ensure_export_uvs(
    mesh: bpy.types.Mesh,
    *,
    require_retail_lightmap: bool,
) -> None:
    source = mesh.uv_layers.get("UVMap")
    if source is None:
        source = mesh.uv_layers.new(name="UVMap")
    source_uvs = array("f", [0.0]) * (len(mesh.loops) * 2)
    source.data.foreach_get("uv", source_uvs)
    lightmap = mesh.uv_layers.get("Lightmap")
    if lightmap is None:
        if require_retail_lightmap:
            raise RuntimeError(
                f"{mesh.name!r} lost its exact retail Lightmap UV layer"
            )
        lightmap = mesh.uv_layers.new(name="Lightmap")
        lightmap.data.foreach_set("uv", source_uvs)
    decal = mesh.uv_layers.get("Decal")
    if decal is None:
        decal = mesh.uv_layers.new(name="Decal")
        decal.data.foreach_set("uv", source_uvs)


def _presentation_only(obj: bpy.types.Object) -> bool:
    identity = " ".join(
        (
            obj.name,
            str(obj.get("skate3_material_name", "")),
        )
    ).lower()
    return any(marker in identity for marker in NO_COLLISION_MARKERS)


def _logical_owner_name(source_object_key: str) -> str:
    digest = hashlib.sha256(
        source_object_key.encode("utf-8")
    ).hexdigest()[:16]
    return f"UNIVERSITY_OBJECT_{digest}"


def _instance_object_owner_name(
    source_instance_id: str,
    source_object_key: str,
) -> str:
    identity = f"{source_instance_id}|{source_object_key}"
    digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:16]
    return f"UNIVERSITY_INSTANCE_OBJECT_{digest}"


def _stable_object_id(name: str) -> int:
    value = 2166136261
    for byte in name.encode("utf-8"):
        value ^= byte
        value = (value * 16777619) & 0xFFFFFFFF
    return value or 1


def _signed_int32(value: int) -> int:
    return value if value < 0x80000000 else value - 0x100000000


def _cell_key(stream_file: str) -> tuple[int, int] | None:
    match = CELL_RE.fullmatch(Path(stream_file).name)
    if match is None:
        return None
    return int(match.group(1)), int(match.group(2))


def _runtime_point(point: Vector) -> Vector:
    return Vector((point.x, point.z, -point.y))


def _blender_point(point: Vector) -> Vector:
    return Vector((point.x, -point.z, point.y))


def _source_instances() -> tuple[
    dict[tuple[int, int], list[dict[str, object]]],
    dict[str, dict[str, object]],
]:
    by_cell: dict[tuple[int, int], list[dict[str, object]]] = {}
    by_id: dict[str, dict[str, object]] = {}
    for obj in bpy.data.objects:
        source_id = str(obj.get("skate3_source_instance_id", "")).strip()
        raw_template = str(obj.get("skate3_source_template", "")).strip()
        if (
            not source_id
            or str(obj.get("skate3_source_category", "")) != "simulation"
            or not raw_template
        ):
            continue
        try:
            source_template = json.loads(raw_template)
        except json.JSONDecodeError as error:
            raise RuntimeError(
                f"{obj.name!r} has invalid source-template metadata"
            ) from error
        if not isinstance(source_template, dict):
            # The extractor intentionally preserves InstanceData records that
            # have no template relation as JSON null.  They are streaming
            # bookkeeping records, not selectable retail object instances.
            continue
        presentation_guid = str(
            source_template.get("presentation_guid", "")
        ).lower()
        simulation_guid = str(
            source_template.get("simulation_guid", "")
        ).lower()
        if (
            GUID_RE.fullmatch(presentation_guid) is None
            or GUID_RE.fullmatch(simulation_guid) is None
        ):
            raise RuntimeError(
                f"{obj.name!r} has incomplete source-template GUIDs"
            )
        cell = _cell_key(str(obj.get("skate3_stream_file", "")))
        if cell is None:
            continue
        minimum = Vector(tuple(obj["skate3_instance_bounds_min"]))
        maximum = Vector(tuple(obj["skate3_instance_bounds_max"]))
        record: dict[str, object] = {
            "id": source_id,
            "cell": cell,
            "minimum": minimum,
            "maximum": maximum,
            "metadata": obj,
            "presentation_guid": presentation_guid,
            "simulation_guid": simulation_guid,
        }
        by_cell.setdefault(cell, []).append(record)
        if source_id in by_id:
            raise RuntimeError(f"duplicate source instance ID {source_id!r}")
        by_id[source_id] = record
    for records in by_cell.values():
        records.sort(key=lambda record: str(record["id"]))
    return by_cell, by_id


def _best_instance(
    point: Vector,
    candidates: list[dict[str, object]],
    maximum_distance: float | None = 0.5,
) -> dict[str, object] | None:
    best: tuple[float, str, dict[str, object]] | None = None
    for candidate in candidates:
        minimum = candidate["minimum"]
        maximum = candidate["maximum"]
        outside = Vector(
            (
                max(minimum.x - 0.5 - point.x, 0.0, point.x - maximum.x - 0.5),
                max(minimum.y - 0.5 - point.y, 0.0, point.y - maximum.y - 0.5),
                max(minimum.z - 0.5 - point.z, 0.0, point.z - maximum.z - 0.5),
            )
        )
        distance = outside.length
        if maximum_distance is not None and distance > maximum_distance:
            continue
        center = (minimum + maximum) * 0.5
        extent = maximum - minimum
        normalized = Vector(
            (
                (point.x - center.x) / max(extent.x, 0.1),
                (point.y - center.y) / max(extent.y, 0.1),
                (point.z - center.z) / max(extent.z, 0.1),
            )
        ).length
        rank = (distance * 1000.0 + normalized, str(candidate["id"]), candidate)
        if best is None or rank[:2] < best[:2]:
            best = rank
    return None if best is None else best[2]


def _grind_runtime_points(obj: bpy.types.Object) -> list[Vector]:
    points: list[Vector] = []
    for spline in obj.data.splines:
        if spline.type == "BEZIER":
            source_points = (
                point.co for point in spline.bezier_points
            )
        else:
            source_points = (
                point.co.to_3d() for point in spline.points
            )
        points.extend(
            _runtime_point(obj.matrix_world @ point)
            for point in source_points
        )
    if points:
        return points
    return [
        sum(
            (
                _runtime_point(obj.matrix_world @ Vector(corner))
                for corner in obj.bound_box
            ),
            Vector(),
        )
        / len(obj.bound_box)
    ]


def _nearest_collision_owner(
    runtime_points: list[Vector],
    collision_queries: list[dict[str, object]],
    maximum_distance: float = 2.0,
) -> tuple[str, float] | None:
    votes: dict[str, tuple[int, float, float]] = {}
    for runtime_point in runtime_points:
        blender_point = _blender_point(runtime_point)
        nearest: tuple[float, str] | None = None
        for query in collision_queries:
            bvh = query["bvh"]
            local_point = query["inverse"] @ blender_point
            hit = bvh.find_nearest(local_point)
            if hit is None or hit[0] is None or hit[2] is None:
                continue
            face_index = int(hit[2])
            owner_names = query["owner_names"]
            if face_index < 0 or face_index >= len(owner_names):
                continue
            nearest_world = query["matrix"] @ hit[0]
            distance = (
                _runtime_point(nearest_world) - runtime_point
            ).length
            candidate = (distance, str(owner_names[face_index]))
            if nearest is None or candidate < nearest:
                nearest = candidate
        if nearest is None or nearest[0] > maximum_distance:
            continue
        distance, owner_name = nearest
        count, total, closest = votes.get(
            owner_name, (0, 0.0, math.inf)
        )
        votes[owner_name] = (
            count + 1,
            total + distance,
            min(closest, distance),
        )
    if not votes:
        return None
    owner_name, (count, total, closest) = min(
        votes.items(),
        key=lambda item: (
            -item[1][0],
            item[1][1] / item[1][0],
            item[1][2],
            item[0],
        ),
    )
    return owner_name, total / count


def _face_owner_names(
    obj: bpy.types.Object,
    candidates: list[dict[str, object]],
    fallback_name: str,
    allowed_instances: set[str] | None = None,
    nearest_allowed_fallback: bool = False,
    owner_bounds: dict[str, tuple[Vector, Vector]] | None = None,
) -> list[str]:
    names: list[str] = []
    for polygon in obj.data.polygons:
        point = _runtime_point(obj.matrix_world @ polygon.center)
        instance = _best_instance(point, candidates)
        source_id = "" if instance is None else str(instance["id"])
        if (
            nearest_allowed_fallback
            and (
                instance is None
                or allowed_instances is not None
                and source_id not in allowed_instances
            )
        ):
            instance = _best_instance(
                point,
                [
                    candidate
                    for candidate in candidates
                    if allowed_instances is None
                    or str(candidate["id"]) in allowed_instances
                ],
                maximum_distance=None,
            )
            source_id = "" if instance is None else str(instance["id"])
        owner_name = (
            str(instance["owner_name"])
            if instance is not None
            and (allowed_instances is None or source_id in allowed_instances)
            else fallback_name
        )
        names.append(owner_name)
        if owner_bounds is not None:
            bounds = owner_bounds.get(owner_name)
            if bounds is None:
                owner_bounds[owner_name] = (point.copy(), point.copy())
            else:
                minimum, maximum = bounds
                minimum.x = min(minimum.x, point.x)
                minimum.y = min(minimum.y, point.y)
                minimum.z = min(minimum.z, point.z)
                maximum.x = max(maximum.x, point.x)
                maximum.y = max(maximum.y, point.y)
                maximum.z = max(maximum.z, point.z)
    return names


def _write_face_owners(
    obj: bpy.types.Object,
    attribute_name: str,
    owner_names: list[str],
) -> None:
    if len(owner_names) != len(obj.data.polygons):
        raise RuntimeError(f"{obj.name!r} owner partition has wrong face count")
    old = obj.data.attributes.get(attribute_name)
    if old is not None:
        obj.data.attributes.remove(old)
    attribute = obj.data.attributes.new(
        name=attribute_name,
        type="INT",
        domain="FACE",
    )
    values = array(
        "i",
        (_signed_int32(_stable_object_id(name)) for name in owner_names),
    )
    attribute.data.foreach_set("value", values)


def _new_owner(
    name: str,
    collection: bpy.types.Collection,
    minimum: Vector,
    maximum: Vector,
) -> bpy.types.Object:
    owner = bpy.data.objects.new(name, None)
    collection.objects.link(owner)
    owner.empty_display_type = "CUBE"
    owner.empty_display_size = max(
        0.25,
        min(10.0, float((maximum - minimum).length) * 0.025),
    )
    owner.location = (minimum + maximum) * 0.5
    owner["ow_editor_editable"] = True
    return owner


def _retail_mesh_descriptors(
    mesh_objects: list[bpy.types.Object],
    instances_by_cell: dict[tuple[int, int], list[dict[str, object]]],
) -> dict[bpy.types.Object, dict[str, str]]:
    manifest_block = bpy.data.texts.get("SKATE3_RETAIL_MANIFEST")
    if manifest_block is None:
        raise RuntimeError("University scene lost its retail manifest")
    manifest = json.loads(manifest_block.as_string())
    presentation_guids = {
        str(record["presentation_guid"])
        for records in instances_by_cell.values()
        for record in records
    }
    lookup: dict[tuple[str, str, int], dict[str, object]] = {}
    for model in manifest.get("models", []):
        asset_id = str(model["asset_id"]).lower()
        stream_file = str(model["stream_file"]).lower()
        for mesh_index, mesh in enumerate(model["meshes"]):
            key = (asset_id, stream_file, mesh_index)
            if key in lookup:
                raise RuntimeError(f"duplicate retail mesh identity {key!r}")
            lookup[key] = {
                "name": str(mesh.get("name", "")),
                "source_fuse_key": str(
                    (model.get("source_fuse") or {}).get("key", "")
                ),
            }

    descriptors: dict[bpy.types.Object, dict[str, str]] = {}
    for obj in mesh_objects:
        if obj.name == SPAWN or bool(obj.get("skate3_retail_collision", False)):
            continue
        key = (
            str(obj.get("skate3_asset_id", "")).lower(),
            str(obj.get("skate3_stream_file", "")).lower(),
            int(obj.get("skate3_mesh_index", -1)),
        )
        mesh = lookup.get(key)
        if mesh is None:
            raise RuntimeError(
                f"{obj.name!r} has no exact retail mesh-manifest entry"
            )
        mesh_name = str(mesh["name"])
        template_matches = sorted(
            {
                token.lower()
                for token in GUID_RE.findall(mesh_name)
            }
            & presentation_guids
        )
        if len(template_matches) > 1:
            raise RuntimeError(
                f"{obj.name!r} ambiguously names retail templates "
                f"{template_matches!r}"
            )
        fuse_key = str(obj.get("skate3_visual_fuse_key", "")).strip()
        if fuse_key != str(mesh["source_fuse_key"]):
            raise RuntimeError(
                f"{obj.name!r} source fuse changed since retail import"
            )
        source_prefix = mesh_name.split("::", 1)[0].strip() or mesh_name
        source_object_key = "|".join(
            (
                str(obj.get("skate3_stream_file", "")),
                fuse_key,
                source_prefix,
            )
        )
        descriptor = {
            "mesh_name": mesh_name,
            "source_object_key": source_object_key,
            "template_guid": (
                template_matches[0] if template_matches else ""
            ),
        }
        descriptors[obj] = descriptor
        obj["skate3_source_mesh_name"] = mesh_name
        obj["skate3_source_object_key"] = source_object_key
        obj["skate3_presentation_template_guid"] = descriptor[
            "template_guid"
        ]
    return descriptors


def _owner_blender_bounds(
    runtime_minimum: Vector,
    runtime_maximum: Vector,
) -> tuple[Vector, Vector]:
    corners = [
        _blender_point(Vector((x, y, z)))
        for x in (runtime_minimum.x, runtime_maximum.x)
        for y in (runtime_minimum.y, runtime_maximum.y)
        for z in (runtime_minimum.z, runtime_maximum.z)
    ]
    return (
        Vector(
            (
                min(point.x for point in corners),
                min(point.y for point in corners),
                min(point.z for point in corners),
            )
        ),
        Vector(
            (
                max(point.x for point in corners),
                max(point.y for point in corners),
                max(point.z for point in corners),
            )
        ),
    )


def _create_visual_owners(
    mesh_objects: list[bpy.types.Object],
    collection: bpy.types.Collection,
) -> tuple[
    dict[str, bpy.types.Object],
    dict[str, bpy.types.Object],
    dict[tuple[int, int], list[dict[str, object]]],
    dict[str, list[dict[str, object]]],
    dict[tuple[int, int], list[dict[str, object]]],
]:
    instances_by_cell, _instances_by_id = _source_instances()
    descriptors = _retail_mesh_descriptors(mesh_objects, instances_by_cell)
    logical_owner_names = {
        descriptor["source_object_key"]: _logical_owner_name(
            descriptor["source_object_key"]
        )
        for descriptor in descriptors.values()
    }
    owner_names: set[str] = set()
    visual_partitions: dict[bpy.types.Object, list[str]] = {}
    used_instance_objects: set[tuple[str, str]] = set()
    runtime_owner_bounds: dict[str, tuple[Vector, Vector]] = {}
    for obj, descriptor in descriptors.items():
        fuse_key = str(obj.get("skate3_visual_fuse_key", "")).strip()
        if not fuse_key:
            raise RuntimeError(
                f"presentation mesh {obj.name!r} lost its source fuse key"
            )
        fallback_name = logical_owner_names[
            descriptor["source_object_key"]
        ]
        cell = _cell_key(str(obj.get("skate3_stream_file", "")))
        candidates = instances_by_cell.get(cell, []) if cell is not None else []
        template_guid = descriptor["template_guid"]
        if template_guid:
            candidates = [
                {
                    **candidate,
                    "owner_name": _instance_object_owner_name(
                        str(candidate["id"]),
                        descriptor["source_object_key"],
                    ),
                }
                for candidate in candidates
                if candidate["presentation_guid"] == template_guid
            ]
            names = _face_owner_names(
                obj,
                candidates,
                fallback_name,
                owner_bounds=runtime_owner_bounds,
            )
        else:
            names = [fallback_name] * len(obj.data.polygons)
            candidates = []
            for corner in obj.bound_box:
                point = _runtime_point(obj.matrix_world @ Vector(corner))
                bounds = runtime_owner_bounds.get(fallback_name)
                if bounds is None:
                    runtime_owner_bounds[fallback_name] = (
                        point.copy(),
                        point.copy(),
                    )
                else:
                    minimum, maximum = bounds
                    minimum.x = min(minimum.x, point.x)
                    minimum.y = min(minimum.y, point.y)
                    minimum.z = min(minimum.z, point.z)
                    maximum.x = max(maximum.x, point.x)
                    maximum.y = max(maximum.y, point.y)
                    maximum.z = max(maximum.z, point.z)
        visual_partitions[obj] = names
        emitted = set(names)
        used_instance_objects.update(
            (str(candidate["id"]), descriptor["source_object_key"])
            for candidate in candidates
            if str(candidate["owner_name"]) in emitted
        )

    logical_owners: dict[str, bpy.types.Object] = {}
    emitted_owner_names = {
        name for names in visual_partitions.values() for name in names
    }
    for source_object_key, owner_name in sorted(logical_owner_names.items()):
        if owner_name not in emitted_owner_names:
            continue
        runtime_minimum, runtime_maximum = runtime_owner_bounds[owner_name]
        minimum, maximum = _owner_blender_bounds(
            runtime_minimum,
            runtime_maximum,
        )
        owner = _new_owner(owner_name, collection, minimum, maximum)
        owner["skate3_source_object_key"] = source_object_key
        owner["skate3_visual_bounds_min"] = tuple(minimum)
        owner["skate3_visual_bounds_max"] = tuple(maximum)
        logical_owners[source_object_key] = owner
        if owner_name in owner_names:
            raise RuntimeError(f"duplicate editable owner {owner_name!r}")
        owner_names.add(owner_name)

    instance_owners: dict[str, bpy.types.Object] = {}
    for source_id, source_object_key in sorted(used_instance_objects):
        record = _instances_by_id[source_id]
        owner_name = _instance_object_owner_name(
            source_id,
            source_object_key,
        )
        if owner_name in owner_names:
            raise RuntimeError(f"duplicate editable owner {owner_name!r}")
        owner_names.add(owner_name)
        runtime_minimum, runtime_maximum = runtime_owner_bounds[owner_name]
        minimum, maximum = _owner_blender_bounds(
            runtime_minimum,
            runtime_maximum,
        )
        owner = _new_owner(owner_name, collection, minimum, maximum)
        owner["skate3_source_instance_id"] = source_id
        owner["skate3_source_object_key"] = source_object_key
        owner["skate3_source_category"] = "simulation"
        owner["skate3_stream_file"] = str(
            record["metadata"].get("skate3_stream_file", "")
        )
        owner["skate3_instance_bounds_min"] = tuple(record["minimum"])
        owner["skate3_instance_bounds_max"] = tuple(record["maximum"])
        owner["skate3_visual_bounds_min"] = tuple(runtime_minimum)
        owner["skate3_visual_bounds_max"] = tuple(runtime_maximum)
        owner["skate3_source_template"] = str(
            record["metadata"].get("skate3_source_template", "")
        )
        instance_owners[owner_name] = owner

    for obj, names in visual_partitions.items():
        unique_names = sorted(set(names))
        _write_face_owners(obj, EDITOR_VISUAL_OWNER_ATTRIBUTE, names)
        obj[EDITOR_VISUAL_OWNER_NAMES] = json.dumps(unique_names)
        obj["ow_map_object_owner"] = unique_names[0]
    visual_records_by_fuse: dict[str, list[dict[str, object]]] = {}
    visual_records_by_cell: dict[
        tuple[int, int], list[dict[str, object]]
    ] = {}
    emitted_records: dict[
        tuple[str, str, tuple[int, int]], dict[str, object]
    ] = {}
    for obj, names in visual_partitions.items():
        fuse_key = str(obj.get("skate3_visual_fuse_key", "")).strip()
        cell = _cell_key(str(obj.get("skate3_stream_file", "")))
        if cell is None:
            continue
        for owner_name in set(names):
            key = (owner_name, fuse_key, cell)
            if key in emitted_records:
                continue
            runtime_minimum, runtime_maximum = runtime_owner_bounds[owner_name]
            owner_record: dict[str, object] = {
                "id": owner_name,
                "owner_name": owner_name,
                "minimum": runtime_minimum,
                "maximum": runtime_maximum,
                "cell": cell,
                "fuse_key": fuse_key,
            }
            emitted_records[key] = owner_record
            visual_records_by_fuse.setdefault(fuse_key, []).append(
                owner_record
            )
            visual_records_by_cell.setdefault(cell, []).append(owner_record)
    for records in visual_records_by_fuse.values():
        records.sort(key=lambda record: str(record["owner_name"]))
    for records in visual_records_by_cell.values():
        records.sort(key=lambda record: str(record["owner_name"]))
    return (
        logical_owners,
        instance_owners,
        instances_by_cell,
        visual_records_by_fuse,
        visual_records_by_cell,
    )


def _surface_hits(
    x: float,
    runtime_z: float,
) -> list[tuple[float, float, str]]:
    scene = bpy.context.scene
    depsgraph = bpy.context.evaluated_depsgraph_get()
    origin = (x, -runtime_z, 400.0)
    hits: list[tuple[float, float, str]] = []
    for _ in range(64):
        hit, location, normal, _face, obj, _matrix = scene.ray_cast(
            depsgraph,
            origin,
            (0.0, 0.0, -1.0),
            distance=800.0,
        )
        if not hit:
            break
        hits.append((float(location.z), float(normal.z), obj.name))
        origin = (x, -runtime_z, float(location.z) - 0.02)
    return hits


def _create_spawn() -> tuple[float, float, float]:
    old = bpy.data.objects.get(SPAWN)
    if old is not None:
        bpy.data.objects.remove(old, do_unlink=True)
    x, runtime_z = SPAWN_RUNTIME_XZ
    candidates = [
        hit
        for hit in _surface_hits(x, runtime_z)
        if hit[1] >= 0.65
        and not any(marker in hit[2].lower() for marker in NO_COLLISION_MARKERS)
    ]
    if not candidates:
        raise RuntimeError(
            f"no upward University surface found at runtime XZ {(x, runtime_z)}"
        )
    surface_height, _normal_z, owner = min(
        candidates,
        key=lambda hit: abs(hit[0] - SPAWN_TARGET_HEIGHT),
    )
    vertices = [
        (-2.0, -2.0, 0.0),
        (2.0, -2.0, 0.0),
        (2.0, 2.0, 0.0),
        (-2.0, 2.0, 0.0),
        (0.0, -3.0, 0.0),
    ]
    mesh = bpy.data.meshes.new(f"{SPAWN}_MESH")
    mesh.from_pydata(vertices, [], [(0, 1, 2, 3), (0, 4, 1)])
    spawn = bpy.data.objects.new(SPAWN, mesh)
    bpy.context.scene.collection.objects.link(spawn)
    spawn.location = (x, -runtime_z, surface_height + 1.0)
    spawn.rotation_euler.z = math.radians(-90.0)
    spawn.hide_render = True
    spawn["university_surface_object"] = owner
    # Exporter converts Blender (x, y, z) to runtime (x, z, -y).
    return (x, surface_height + 1.0, runtime_z)


def main() -> int:
    arguments = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    if len(arguments) != 1:
        raise SystemExit(
            "usage: blender --background DIST_University.blend --python "
            "prepare_university_owned.py -- OUTPUT_BLEND"
        )
    output = Path(arguments[0]).resolve()
    group_1 = _new_group(GROUP_1)
    group_2 = _new_group(GROUP_2)
    group_3 = _new_group(GROUP_3)
    group_4 = _new_group(GROUP_4)
    _new_group(GROUP_5)
    owner_collection = _new_owner_group()
    fallback = _default_material()
    _configure_material(fallback)

    mesh_objects = sorted(
        (obj for obj in bpy.data.objects if obj.type == "MESH"),
        key=lambda obj: obj.name_full,
    )
    (
        logical_owners,
        instance_owners,
        instances_by_cell,
        visual_records_by_fuse,
        visual_records_by_cell,
    ) = _create_visual_owners(mesh_objects, owner_collection)
    owners_by_name = {
        owner.name: owner
        for owner in (*logical_owners.values(), *instance_owners.values())
    }
    # Newly created Empty transforms are dependency-graph evaluated lazily.
    # Resolve them before computing parent inverses for exact retail grinds.
    bpy.context.view_layer.update()
    material_ids: set[int] = set()
    collidable = 0
    presentation_only = 0
    triangle_count = 0
    retail_collision_objects = 0
    retail_collision_triangles = 0
    collision_queries_by_cell: dict[
        tuple[int, int], list[dict[str, object]]
    ] = {}
    depsgraph = bpy.context.evaluated_depsgraph_get()
    for obj in mesh_objects:
        if obj.name == SPAWN:
            continue
        if bool(obj.get("skate3_retail_collision", False)):
            if not obj.data.materials:
                raise RuntimeError(
                    f"{obj.name!r} has no retail collision material"
                )
            if any(material is None for material in obj.data.materials):
                raise RuntimeError(
                    f"{obj.name!r} has an empty retail collision material slot"
                )
            fuse_key = str(
                obj.get("skate3_visual_fuse_key", "")
            ).strip()
            cell = _cell_key(str(obj.get("skate3_stream_file", "")))
            candidates = visual_records_by_fuse.get(fuse_key, [])
            if not candidates and cell is not None:
                candidates = visual_records_by_cell.get(cell, [])
            if not candidates:
                raise RuntimeError(
                    f"{obj.name!r} has no emitted visual owner near source "
                    f"fuse {fuse_key!r} or cell {cell!r}"
                )
            collision_owner_names = _face_owner_names(
                obj,
                candidates,
                str(candidates[0]["owner_name"]),
                nearest_allowed_fallback=True,
            )
            obj["ow_map_object_owner"] = sorted(
                set(collision_owner_names)
            )[0]
            _write_face_owners(
                obj,
                EDITOR_COLLISION_OWNER_ATTRIBUTE,
                collision_owner_names,
            )
            if cell is not None:
                collision_queries_by_cell.setdefault(cell, []).append(
                    {
                        "object": obj,
                        "bvh": BVHTree.FromObject(
                            obj,
                            depsgraph,
                            deform=False,
                            cage=False,
                            epsilon=0.0,
                        ),
                        "matrix": obj.matrix_world.copy(),
                        "inverse": obj.matrix_world.inverted_safe(),
                        "owner_names": tuple(collision_owner_names),
                    }
                )
            obj["ow_material"] = obj.data.materials[0].name
            obj["ow_use_face_materials"] = True
            group_2.objects.link(obj)
            retail_collision_objects += 1
            retail_collision_triangles += len(obj.data.polygons)
            continue
        if not obj.data.materials:
            obj.data.materials.append(fallback)
        require_retail_lightmap = any(
            material is not None
            and bool(material.get("skate3_lightmap_texture_id", ""))
            for material in obj.data.materials
        )
        _ensure_export_uvs(
            obj.data,
            require_retail_lightmap=require_retail_lightmap,
        )
        for material in obj.data.materials:
            if material is not None and material.as_pointer() not in material_ids:
                material_ids.add(material.as_pointer())
                _configure_material(material)
        obj["ow_material"] = obj.data.materials[0].name
        triangle_count += len(obj.data.polygons)
        if _presentation_only(obj):
            group_3.objects.link(obj)
            presentation_only += 1
        else:
            group_1.objects.link(obj)
            collidable += 1

    grind_objects = sorted(
        (
            obj
            for obj in bpy.data.objects
            if obj.type == "CURVE"
            and bool(obj.get("skate3_retail_grind", False))
        ),
        key=lambda obj: obj.name_full,
    )
    grind_segments = 0
    owned_grinds = 0
    unowned_grinds = 0
    collision_face_owned_grinds = 0
    proximity_owned_grinds = 0
    maximum_grind_owner_distance = 0.0
    for obj in grind_objects:
        fuse_key = str(
            obj.get("skate3_visual_fuse_key", "")
        ).strip()
        cell = _cell_key(str(obj.get("skate3_stream_file", "")))
        candidates = visual_records_by_fuse.get(fuse_key, []) if fuse_key else []
        if not candidates and cell is not None:
            candidates = visual_records_by_cell.get(cell, [])
        owner_record = None
        owner_method = ""
        owner_distance = math.inf
        runtime_points = _grind_runtime_points(obj)
        collision_owner = (
            _nearest_collision_owner(
                runtime_points,
                collision_queries_by_cell.get(cell, []),
            )
            if cell is not None
            else None
        )
        if collision_owner is not None:
            owner_name, owner_distance = collision_owner
            owner = owners_by_name.get(owner_name)
            if owner is None:
                raise RuntimeError(
                    f"{obj.name!r} resolved missing collision owner "
                    f"{owner_name!r}"
                )
            owner_method = "nearest exact collision face owner"
            collision_face_owned_grinds += 1
        elif candidates:
            center = sum(runtime_points, Vector()) / len(runtime_points)
            owner_record = _best_instance(
                center,
                candidates,
                maximum_distance=None,
            )
            if owner_record is not None:
                owner = owners_by_name[str(owner_record["owner_name"])]
                minimum = owner_record["minimum"]
                maximum = owner_record["maximum"]
                nearest = Vector(
                    (
                        min(max(center.x, minimum.x), maximum.x),
                        min(max(center.y, minimum.y), maximum.y),
                        min(max(center.z, minimum.z), maximum.z),
                    )
                )
                owner_distance = (nearest - center).length
                owner_method = "nearest visual owner in source fuse/cell"
                proximity_owned_grinds += 1
        if collision_owner is not None or owner_record is not None:
            world_matrix = obj.matrix_world.copy()
            obj.parent = owner
            obj.matrix_parent_inverse = owner.matrix_world.inverted()
            obj.matrix_world = world_matrix
            obj["skate3_inferred_editor_owner"] = owner.name
            obj["skate3_editor_owner_method"] = owner_method
            obj["skate3_editor_owner_distance"] = owner_distance
            maximum_grind_owner_distance = max(
                maximum_grind_owner_distance,
                owner_distance,
            )
            owned_grinds += 1
        else:
            unowned_grinds += 1
        group_4.objects.link(obj)
        grind_segments += int(obj["skate3_retail_grind_segment_count"])

    spawn_runtime = _create_spawn()
    scene = bpy.context.scene
    scene["ow_map_name"] = "University District"
    scene["ow_dynamic_lighting_enabled_by_default"] = False
    scene["ow_cycle_seconds"] = 0.0
    scene["ow_start_hour"] = 11.0
    scene["ow_end_hour"] = 18.0
    scene["ow_cycle_ping_pong"] = False
    scene["ow_sky_zenith"] = (0.10, 0.36, 0.75)
    scene["ow_sky_horizon"] = (0.64, 0.82, 1.0)
    scene["ow_sky_nadir"] = (0.18, 0.24, 0.30)
    scene["ow_day_ambient"] = 0.34
    scene["ow_night_ambient"] = 0.10
    scene["university_collision_source"] = (
        "exact retail RenderWare ClusteredMesh triangles and packed surfaces"
    )
    scene["university_grind_source"] = (
        "exact retail Pegasus tSplineData cubic segment payloads"
    )
    visual_owner_count = len(logical_owners) + len(instance_owners)
    collision_owner_ids: set[int] = set()
    for obj in mesh_objects:
        if not bool(obj.get("skate3_retail_collision", False)):
            continue
        attribute = obj.data.attributes.get(EDITOR_COLLISION_OWNER_ATTRIBUTE)
        values = array("i", [0]) * len(obj.data.polygons)
        attribute.data.foreach_get("value", values)
        collision_owner_ids.update(value & 0xFFFFFFFF for value in values)
    scene["university_editable_owner_count"] = visual_owner_count
    scene["university_collision_owner_count"] = len(collision_owner_ids)
    scene["university_owned_grind_count"] = owned_grinds
    scene["university_unowned_grind_count"] = unowned_grinds
    scene["university_grind_ownership"] = (
        "no serialized rail-to-instance owner was found; each exact retail "
        "rail is deterministically associated with the nearest exact "
        "collision face owner, with source-cell visual proximity as fallback"
    )
    scene["university_spawn_runtime"] = spawn_runtime
    output.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output))
    print(
        json.dumps(
            {
                "output": str(output),
                "mesh_objects": len(mesh_objects),
                "materials": len(material_ids),
                "triangles": triangle_count,
                "collidable_objects": collidable,
                "presentation_only_objects": presentation_only,
                "editable_visual_owners": visual_owner_count,
                "source_instance_visual_owners": len(instance_owners),
                "logical_source_visual_owners": len(logical_owners),
                "editable_collision_owners": len(collision_owner_ids),
                "retail_collision_objects": retail_collision_objects,
                "retail_collision_triangles": retail_collision_triangles,
                "grind_rails": len(grind_objects),
                "owned_grind_rails": owned_grinds,
                "unowned_grind_rails": unowned_grinds,
                "collision_face_owned_grind_rails": (
                    collision_face_owned_grinds
                ),
                "proximity_owned_grind_rails": proximity_owned_grinds,
                "maximum_grind_owner_distance": (
                    maximum_grind_owner_distance
                ),
                "grind_segments": grind_segments,
                "spawn_runtime": spawn_runtime,
                "collision_source": scene["university_collision_source"],
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
