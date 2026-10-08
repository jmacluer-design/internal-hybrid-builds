"""Validate University material provenance inside the generated Blender file."""

from __future__ import annotations

from collections import Counter
import json
import struct

import bpy
from mathutils import Vector
import numpy


EXPECTED_MODE_COUNTS = {0: 6389, 1: 2118, 2: 39}
EXPECTED_GRIND_RAILS = 4201
EXPECTED_GRIND_SEGMENTS = 27008
EXPECTED_CLOSED_GRIND_RAILS = 372
EXPECTED_COLLISION_MESHES = 301
EXPECTED_COLLISION_SURFACES = 183
EXPECTED_COLLISION_TRIANGLES = 1_133_649
EXPECTED_EDITABLE_VISUAL_OWNERS = 12_993
EXPECTED_SOURCE_INSTANCE_VISUAL_OWNERS = 5_660
EXPECTED_LOGICAL_SOURCE_VISUAL_OWNERS = 7_333
EXPECTED_COLLISION_OWNERS = 8_842
EXPECTED_OWNED_GRIND_RAILS = 4_201
EXPECTED_UNOWNED_GRIND_RAILS = 0
EXPECTED_COLLISION_FACE_OWNED_GRIND_RAILS = 4_188
EXPECTED_PROXIMITY_OWNED_GRIND_RAILS = 13
MAXIMUM_GRIND_OWNER_DISTANCE = 2.0
EXPECTED_SOURCE_INSTANCES = 5_027
EXPECTED_NORMAL_MAPPED_OBJECTS = 2_987
EXPECTED_NORMAL_TEXTURES = 135
EXPECTED_SOURCE_LIGHTMAP_REFERENCES = 8_522
EXPECTED_LIGHTMAPPED_OBJECTS = 8_489
EXPECTED_LIGHTMAP_TEXTURES = 1_270
EXPECTED_LIGHTMAP_EXCLUSIONS = 33
EXPECTED_RETAIL_WORLD_FRAMES = 3_121
RETAIL_NORMAL_ATTRIBUTE = (
    "skate3_retail_normal",
    "FLOAT_VECTOR",
    "vector",
    3,
)
RETAIL_TANGENT_ATTRIBUTES = (
    "skate3_retail_tangent",
    "skate3_retail_binormal",
)
RETAIL_HANDEDNESS_ATTRIBUTE = (
    "skate3_retail_tangent_handedness",
    "FLOAT",
    "value",
    1,
)
EDITOR_VISUAL_OWNER_ATTRIBUTE = "ow_editor_visual_owner"
EDITOR_COLLISION_OWNER_ATTRIBUTE = "ow_editor_collision_owner"
EDITOR_VISUAL_OWNER_NAMES = "ow_editor_visual_owner_names"


def _stable_object_id(name: str) -> int:
    value = 2166136261
    for byte in name.encode("utf-8"):
        value ^= byte
        value = (value * 16777619) & 0xFFFFFFFF
    return value or 1
REGRESSION_BINDINGS = {
    ("0xF6CC7BFCC2C45F8C", 40): (
        "0x861894DE4209CE82",
        "0x00800078",
        24,
        "0x2c70170a001d00aa",
        "0x893793c0de31aab1",
        0,
    ),
    ("0xF6CC7BFCC2C45F8C", 41): (
        "0xFA839F99082D42ED",
        "0x0080007B",
        38,
        "0x2c70170a0004000e",
        "0xba390198c38936f0",
        0,
    ),
    ("0xF6CC7BFCC2C45F8C", 42): (
        "0x96879C786774C31D",
        "0x0080007E",
        12,
        "0x00008d6a03e3870a",
        "0xba390198c38936f0",
        0,
    ),
    ("0x759E349006948F63", 2): (
        "0x861894DE4209CE82",
        "0x00800006",
        0,
        "0x2c70170a001d00aa",
        "0x893793c0de31aab1",
        0,
    ),
    ("0x759E349006948F63", 3): (
        "0xA0683D15728B6787",
        "0x00800009",
        3,
        "0x2c70170a00053a88",
        "0x893793c0de31aab1",
        1,
    ),
}


def main() -> int:
    objects = [
        obj
        for obj in bpy.data.objects
        if (
            obj.type == "MESH"
            and "skate3_asset_id" in obj
            and not bool(obj.get("skate3_retail_collision", False))
        )
    ]
    if len(objects) != 8546:
        raise RuntimeError(
            f"University has {len(objects)} imported mesh parts, expected 8546"
        )

    modes: Counter[int] = Counter()
    unresolved: Counter[int] = Counter()
    normal_mapped_objects = 0
    normal_texture_ids: set[str] = set()
    normal_materials: set[int] = set()
    source_lightmap_references = 0
    lightmapped_objects = 0
    lightmap_texture_ids: set[str] = set()
    lightmap_materials: set[int] = set()
    lightmap_exclusions = 0
    retail_world_frames = 0
    lookup: dict[tuple[str, int], bpy.types.Object] = {}
    for obj in objects:
        alpha_mode = int(obj.get("skate3_alpha_mode", 0))
        texture_id = str(obj.get("skate3_texture_id", ""))
        modes[alpha_mode] += 1
        lookup[
            (
                str(obj["skate3_asset_id"]),
                int(obj["skate3_mesh_index"]),
            )
        ] = obj
        source_lightmap_texture_id = str(
            obj.get("skate3_source_lightmap_texture_id", "")
        )
        lightmap_texture_id = str(
            obj.get("skate3_lightmap_texture_id", "")
        )
        if source_lightmap_texture_id:
            source_lightmap_references += 1
        if not obj.data.materials:
            raise RuntimeError(
                f"{obj.name!r} lost its retail material definition"
            )
        material = obj.data.materials[0]
        has_retail_world_frame = bool(
            obj.get("skate3_retail_world_frame", False)
        )
        tangent_attributes = [
            obj.data.attributes.get(name)
            for name in RETAIL_TANGENT_ATTRIBUTES
        ]
        if sum(attribute is not None for attribute in tangent_attributes) > 1:
            raise RuntimeError(
                f"{obj.name!r} has both current and legacy retail tangent "
                "attributes"
            )
        selected_tangent_name = (
            RETAIL_TANGENT_ATTRIBUTES[
                next(
                    (
                        index
                        for index, attribute in enumerate(tangent_attributes)
                        if attribute is not None
                    ),
                    0,
                )
            ]
        )
        frame_schema = (
            RETAIL_NORMAL_ATTRIBUTE,
            (selected_tangent_name, "FLOAT_VECTOR", "vector", 3),
            RETAIL_HANDEDNESS_ATTRIBUTE,
        )
        frame_attributes = []
        for (
            attribute_name,
            data_type,
            _property_name,
            _components,
        ) in frame_schema:
            attribute = obj.data.attributes.get(attribute_name)
            if has_retail_world_frame:
                if (
                    attribute is None
                    or attribute.domain != "POINT"
                    or attribute.data_type != data_type
                    or len(attribute.data) != len(obj.data.vertices)
                ):
                    raise RuntimeError(
                        f"{obj.name!r} has invalid retail world-frame "
                        f"attribute {attribute_name!r}"
                    )
                frame_attributes.append(attribute)
            elif attribute is not None:
                raise RuntimeError(
                    f"{obj.name!r} has unexpected retail world-frame "
                    f"attribute {attribute_name!r}"
                )
        if has_retail_world_frame:
            decoded = []
            for attribute, (
                _attribute_name,
                _data_type,
                property_name,
                components,
            ) in zip(
                frame_attributes,
                frame_schema,
                strict=True,
            ):
                values = numpy.empty(
                    len(attribute.data) * components,
                    dtype=numpy.float32,
                )
                attribute.data.foreach_get(property_name, values)
                if not numpy.isfinite(values).all():
                    raise RuntimeError(
                        f"{obj.name!r} retail world frame is non-finite"
                    )
                decoded.append(values.reshape((-1, components)))
            normal_lengths = numpy.linalg.norm(decoded[0], axis=1)
            if (
                normal_lengths.size
                and (
                    float(normal_lengths.min()) < 0.999
                    or float(normal_lengths.max()) > 1.001
                )
            ):
                raise RuntimeError(
                    f"{obj.name!r} retail normals are not unit length"
                )
            if not numpy.all(numpy.abs(decoded[2][:, 0]) > 0.999):
                raise RuntimeError(
                    f"{obj.name!r} retail tangent handedness is invalid"
                )
            retail_world_frames += 1
        expected_material_texture_id = texture_id or "NO_DIFFUSE"
        if (
            str(material.get("skate3_texture_id", ""))
            != expected_material_texture_id
            or int(material.get("skate3_alpha_mode", -1)) != alpha_mode
        ):
            raise RuntimeError(
                f"{obj.name!r} material provenance does not match the mesh"
            )
        if "skate3_fallback_reason" in material:
            unresolved[alpha_mode] += 1
        if lightmap_texture_id:
            if lightmap_texture_id != source_lightmap_texture_id:
                raise RuntimeError(
                    f"{obj.name!r} substituted retail lightmap "
                    f"{source_lightmap_texture_id!r} with "
                    f"{lightmap_texture_id!r}"
                )
            lightmap_layer = obj.data.uv_layers.get("Lightmap")
            if (
                lightmap_layer is None
                or len(lightmap_layer.data) != len(obj.data.loops)
            ):
                raise RuntimeError(
                    f"{obj.name!r} lost its retail lightmap UVs"
                )
            lightmap_image = bpy.data.images.get(lightmap_texture_id)
            if lightmap_image is None:
                raise RuntimeError(
                    f"{obj.name!r} is missing lightmap image "
                    f"{lightmap_texture_id!r}"
                )
            if lightmap_image.colorspace_settings.name != "Non-Color":
                raise RuntimeError(
                    f"{lightmap_texture_id!r} is not marked Non-Color"
                )
            if (
                str(material.get("skate3_lightmap_texture_id", ""))
                != lightmap_texture_id
                or str(material.get("ow_lightmap_image", ""))
                != lightmap_image.name
                or str(material.get("ow_lightmap_encoding", ""))
                != "skate3_retail_sqrt_linear_over_4"
                or float(material.get("ow_baked_strength", 0.0)) != 1.0
            ):
                raise RuntimeError(
                    f"{material.name!r} does not export its retail lightmap"
                )
            lightmapped_objects += 1
            lightmap_texture_ids.add(lightmap_texture_id)
            lightmap_materials.add(material.as_pointer())
        elif source_lightmap_texture_id:
            reason = str(obj.get("skate3_lightmap_exclusion", ""))
            if not reason:
                raise RuntimeError(
                    f"{obj.name!r} silently discarded retail lightmap "
                    f"{source_lightmap_texture_id!r}"
                )
            if (
                str(material.get("skate3_lightmap_texture_id", ""))
                or str(material.get("ow_lightmap_image", ""))
            ):
                raise RuntimeError(
                    f"{obj.name!r} inherited a lightmap despite exclusion"
                )
            lightmap_exclusions += 1
        normal_texture_id = str(
            obj.get("skate3_normal_texture_id", "")
        )
        source_normal_texture_id = str(
            obj.get("skate3_source_normal_texture_id", "")
        )
        if normal_texture_id:
            if normal_texture_id != source_normal_texture_id:
                raise RuntimeError(
                    f"{obj.name!r} substituted retail normal "
                    f"{source_normal_texture_id!r} with "
                    f"{normal_texture_id!r}"
                )
            if (
                str(material.get("skate3_normal_texture_id", ""))
                != normal_texture_id
            ):
                raise RuntimeError(
                    f"{obj.name!r} material lost normal provenance"
                )
            normal_image = bpy.data.images.get(normal_texture_id)
            if normal_image is None:
                raise RuntimeError(
                    f"{obj.name!r} is missing normal image "
                    f"{normal_texture_id!r}"
                )
            if normal_image.colorspace_settings.name != "Non-Color":
                raise RuntimeError(
                    f"{normal_texture_id!r} is not marked Non-Color"
                )
            if (
                str(material.get("ow_normal_image", ""))
                != normal_image.name
            ):
                raise RuntimeError(
                    f"{material.name!r} does not export its retail normal"
                )
            normal_mapped_objects += 1
            normal_texture_ids.add(normal_texture_id)
            normal_materials.add(material.as_pointer())
        elif (
            str(material.get("skate3_normal_texture_id", ""))
            or str(material.get("ow_normal_image", ""))
        ):
            raise RuntimeError(
                f"{obj.name!r} unexpectedly inherited another mesh's normal"
            )

    if dict(modes) != EXPECTED_MODE_COUNTS:
        raise RuntimeError(
            f"University alpha modes changed: {dict(modes)}"
        )
    if normal_mapped_objects != EXPECTED_NORMAL_MAPPED_OBJECTS:
        raise RuntimeError(
            f"University has {normal_mapped_objects} normal-mapped mesh "
            f"parts, expected {EXPECTED_NORMAL_MAPPED_OBJECTS}"
        )
    if len(normal_texture_ids) != EXPECTED_NORMAL_TEXTURES:
        raise RuntimeError(
            f"University has {len(normal_texture_ids)} conventional retail "
            f"normal textures, expected {EXPECTED_NORMAL_TEXTURES}"
        )
    if source_lightmap_references != EXPECTED_SOURCE_LIGHTMAP_REFERENCES:
        raise RuntimeError(
            f"University has {source_lightmap_references} source lightmap "
            f"references, expected {EXPECTED_SOURCE_LIGHTMAP_REFERENCES}"
        )
    if lightmapped_objects != EXPECTED_LIGHTMAPPED_OBJECTS:
        raise RuntimeError(
            f"University has {lightmapped_objects} lightmapped mesh parts, "
            f"expected {EXPECTED_LIGHTMAPPED_OBJECTS}"
        )
    if len(lightmap_texture_ids) != EXPECTED_LIGHTMAP_TEXTURES:
        raise RuntimeError(
            f"University has {len(lightmap_texture_ids)} exported retail "
            f"lightmaps, expected {EXPECTED_LIGHTMAP_TEXTURES}"
        )
    if lightmap_exclusions != EXPECTED_LIGHTMAP_EXCLUSIONS:
        raise RuntimeError(
            f"University has {lightmap_exclusions} explicit lightmap "
            f"exclusions, expected {EXPECTED_LIGHTMAP_EXCLUSIONS}"
        )
    if retail_world_frames != EXPECTED_RETAIL_WORLD_FRAMES:
        raise RuntimeError(
            f"University has {retail_world_frames} exact retail world "
            f"frames, expected {EXPECTED_RETAIL_WORLD_FRAMES}"
        )

    for key, expected in REGRESSION_BINDINGS.items():
        obj = lookup.get(key)
        if obj is None:
            raise RuntimeError(f"regression mesh {key!r} is missing")
        actual = (
            str(obj.get("skate3_retail_material_guid", "")),
            str(obj.get("skate3_retail_material_handle", "")),
            int(obj.get("skate3_retail_material_group_index", -1)),
            str(obj.get("skate3_texture_id", "")),
            str(obj.get("skate3_lightmap_texture_id", "")),
            int(obj.get("skate3_alpha_mode", 0)),
        )
        if actual != expected:
            raise RuntimeError(
                f"regression mesh {key!r}: {actual!r} != {expected!r}"
            )

    grind_objects = [
        obj
        for obj in bpy.data.objects
        if obj.type == "CURVE"
        and bool(obj.get("skate3_retail_grind", False))
    ]
    if len(grind_objects) != EXPECTED_GRIND_RAILS:
        raise RuntimeError(
            f"University has {len(grind_objects)} retail grind rails, "
            f"expected {EXPECTED_GRIND_RAILS}"
        )
    grind_segments = 0
    closed_grinds = 0
    for obj in grind_objects:
        if len(obj.data.splines) != 1:
            raise RuntimeError(
                f"{obj.name!r} does not contain exactly one retail spline"
            )
        spline = obj.data.splines[0]
        if spline.type != "BEZIER":
            raise RuntimeError(f"{obj.name!r} is not a Bezier spline")
        segment_count = int(
            obj["skate3_retail_grind_segment_count"]
        )
        actual_segment_count = (
            len(spline.bezier_points)
            if spline.use_cyclic_u
            else len(spline.bezier_points) - 1
        )
        if actual_segment_count != segment_count:
            raise RuntimeError(
                f"{obj.name!r} has {actual_segment_count} Blender segments "
                f"but {segment_count} retail segments"
            )
        payload = bytes.fromhex(
            str(obj["skate3_retail_grind_segment_payload"])
        )
        if len(payload) != segment_count * 120:
            raise RuntimeError(
                f"{obj.name!r} has an invalid native segment payload"
            )
        if int(
            str(obj["skate3_retail_grind_spline_id"]),
            16,
        ) == 0 or int(
            str(obj["skate3_retail_grind_type_signature"]),
            16,
        ) == 0:
            raise RuntimeError(
                f"{obj.name!r} lost its retail spline identity"
            )

        points = spline.bezier_points
        for segment_index in range(segment_count):
            values = struct.unpack_from(
                ">30f",
                payload,
                segment_index * 120,
            )
            coefficient_a = values[0:3]
            coefficient_b = values[4:7]
            coefficient_c = values[8:11]
            coefficient_d = values[12:15]
            runtime_controls = (
                coefficient_d,
                tuple(
                    coefficient_d[axis] + coefficient_c[axis] / 3.0
                    for axis in range(3)
                ),
                tuple(
                    coefficient_d[axis]
                    + (
                        2.0 * coefficient_c[axis]
                        + coefficient_b[axis]
                    )
                    / 3.0
                    for axis in range(3)
                ),
                tuple(
                    coefficient_d[axis]
                    + coefficient_c[axis]
                    + coefficient_b[axis]
                    + coefficient_a[axis]
                    for axis in range(3)
                ),
            )
            expected_controls = tuple(
                Vector((point[0], -point[2], point[1]))
                for point in runtime_controls
            )
            current = points[segment_index]
            following = points[
                (segment_index + 1) % len(points)
            ]
            actual_controls = (
                obj.matrix_world @ current.co,
                obj.matrix_world @ current.handle_right,
                obj.matrix_world @ following.handle_left,
                obj.matrix_world @ following.co,
            )
            control_errors = [
                (actual - expected).length
                for actual, expected in zip(
                    actual_controls,
                    expected_controls,
                )
            ]
            # Blender stores curve points as float32. Retail cubic endpoints
            # are independently evaluated coefficients, so cancellation at
            # University-scale coordinates can add sub-millimetre rounding.
            if any(error > 2.0e-3 for error in control_errors):
                raise RuntimeError(
                    f"{obj.name!r} segment {segment_index} no longer "
                    "matches its exact retail cubic: "
                    f"control errors={control_errors}"
                )
        grind_segments += segment_count
        closed_grinds += bool(spline.use_cyclic_u)

    if (
        grind_segments != EXPECTED_GRIND_SEGMENTS
        or closed_grinds != EXPECTED_CLOSED_GRIND_RAILS
    ):
        raise RuntimeError(
            "University retail grind totals changed: "
            f"segments={grind_segments}, closed={closed_grinds}"
        )

    collision_objects = [
        obj
        for obj in bpy.data.objects
        if obj.type == "MESH"
        and bool(obj.get("skate3_retail_collision", False))
    ]
    if len(collision_objects) != EXPECTED_COLLISION_MESHES:
        raise RuntimeError(
            f"University has {len(collision_objects)} retail collision "
            f"meshes, expected {EXPECTED_COLLISION_MESHES}"
        )
    collision_triangles = 0
    collision_surfaces: set[int] = set()
    for obj in collision_objects:
        if not obj.data.materials or any(
            material is None for material in obj.data.materials
        ):
            raise RuntimeError(
                f"{obj.name!r} has an invalid retail collision material slot"
            )
        if not bool(obj.get("ow_use_face_materials", False)):
            raise RuntimeError(
                f"{obj.name!r} would flatten per-face retail surfaces"
            )
        expected_surface_ids = {
            int(value, 16)
            for value in json.loads(
                str(obj["skate3_retail_surface_ids"])
            )
        }
        material_surface_ids: list[int] = []
        for material in obj.data.materials:
            surface = int(
                str(material["skate3_retail_surface_id"]),
                16,
            )
            encoded = (
                int(material["ow_audio_surface"])
                | (int(material["ow_physics_surface"]) << 7)
                | (int(material["ow_surface_pattern"]) << 12)
            )
            if encoded != surface:
                raise RuntimeError(
                    f"{obj.name!r} packed surface changed: "
                    f"0x{encoded:04X} != 0x{surface:04X}"
                )
            material_surface_ids.append(surface)
        if set(material_surface_ids) != expected_surface_ids:
            raise RuntimeError(
                f"{obj.name!r} retail collision surface set changed"
            )
        for polygon in obj.data.polygons:
            if polygon.material_index >= len(material_surface_ids):
                raise RuntimeError(
                    f"{obj.name!r} has an invalid per-face surface slot"
                )
            collision_surfaces.add(
                material_surface_ids[polygon.material_index]
            )
        if not bool(
            obj.get("ow_preserve_opposite_wound_collision", False)
        ):
            raise RuntimeError(
                f"{obj.name!r} would discard reverse-wound retail collision"
            )
        if not bool(obj.get("ow_preserve_retail_edge_codes", False)):
            raise RuntimeError(
                f"{obj.name!r} would discard native retail edge codes"
            )
        for corner in range(3):
            attribute_name = f"skate3_retail_edge_code_{corner}"
            attribute = obj.data.attributes.get(attribute_name)
            if (
                attribute is None
                or attribute.domain != "FACE"
                or attribute.data_type != "INT"
                or len(attribute.data) != len(obj.data.polygons)
            ):
                raise RuntimeError(
                    f"{obj.name!r} has invalid {attribute_name!r} metadata"
                )
        triangle_count = len(obj.data.polygons)
        if triangle_count != int(obj["skate3_retail_triangle_count"]):
            raise RuntimeError(
                f"{obj.name!r} retail triangle count changed"
            )
        collision_triangles += triangle_count
    if len(collision_surfaces) != EXPECTED_COLLISION_SURFACES:
        raise RuntimeError(
            f"University has {len(collision_surfaces)} retail collision "
            f"surfaces, expected {EXPECTED_COLLISION_SURFACES}"
        )
    if collision_triangles != EXPECTED_COLLISION_TRIANGLES:
        raise RuntimeError(
            f"University has {collision_triangles} retail collision triangles, "
            f"expected {EXPECTED_COLLISION_TRIANGLES}"
        )

    owner_collection = bpy.data.collections.get(
        "UNIVERSITY_EDITABLE_OWNERS"
    )
    editable_owners = (
        []
        if owner_collection is None
        else [
            obj
            for obj in owner_collection.objects
            if obj.type == "EMPTY"
            and bool(obj.get("ow_editor_editable", False))
        ]
    )
    source_instances = [
        obj
        for obj in bpy.data.objects
        if (
            obj.type == "EMPTY"
            and "skate3_source_instance_id" in obj
            and "skate3_instance_matrix" in obj
        )
    ]
    if len(source_instances) != EXPECTED_SOURCE_INSTANCES:
        raise RuntimeError(
            f"University has {len(source_instances)} source-instance metadata "
            f"objects, expected {EXPECTED_SOURCE_INSTANCES}"
        )
    source_instance_ids = {
        str(obj["skate3_source_instance_id"])
        for obj in source_instances
    }
    if len(source_instance_ids) != EXPECTED_SOURCE_INSTANCES:
        raise RuntimeError("University source-instance stable IDs collide")
    for obj in source_instances:
        raw_matrix = obj["skate3_instance_matrix"]
        if len(raw_matrix) != 16:
            raise RuntimeError(
                f"{obj.name!r} lost its exact retail InstanceData matrix"
            )
        expected_location = Vector(
            (
                float(raw_matrix[12]),
                -float(raw_matrix[14]),
                float(raw_matrix[13]),
            )
        )
        if (obj.matrix_world.translation - expected_location).length > 1.0e-4:
            raise RuntimeError(
                f"{obj.name!r} source transform does not match its raw "
                "InstanceData matrix"
            )
    owned_grinds = sum(
        obj.parent is not None
        and bool(str(obj.get("skate3_inferred_editor_owner", "")).strip())
        for obj in grind_objects
    )
    unowned_grinds = len(grind_objects) - owned_grinds
    collision_face_owned_grinds = sum(
        str(obj.get("skate3_editor_owner_method", ""))
        == "nearest exact collision face owner"
        for obj in grind_objects
    )
    proximity_owned_grinds = sum(
        str(obj.get("skate3_editor_owner_method", ""))
        == "nearest visual owner in source fuse/cell"
        for obj in grind_objects
    )
    expected_owned_grinds = (
        EXPECTED_OWNED_GRIND_RAILS if editable_owners else 0
    )
    expected_unowned_grinds = (
        EXPECTED_UNOWNED_GRIND_RAILS
        if editable_owners
        else EXPECTED_GRIND_RAILS
    )
    if (
        owned_grinds != expected_owned_grinds
        or unowned_grinds != expected_unowned_grinds
    ):
        raise RuntimeError(
            "University grind ownership totals changed: "
            f"owned={owned_grinds}, unowned={unowned_grinds}"
        )
    instance_owner_count = 0
    logical_owner_count = 0
    collision_owner_ids: set[int] = set()
    if editable_owners:
        if len(editable_owners) != EXPECTED_EDITABLE_VISUAL_OWNERS:
            raise RuntimeError(
                f"University has {len(editable_owners)} editable visual "
                f"owners, expected {EXPECTED_EDITABLE_VISUAL_OWNERS}"
            )
        owners_by_name = {owner.name: owner for owner in editable_owners}
        owners_by_id = {
            _stable_object_id(owner.name_full): owner
            for owner in editable_owners
        }
        instance_owner_count = sum(
            "skate3_source_instance_id" in owner
            for owner in editable_owners
        )
        logical_owner_count = sum(
            "skate3_source_object_key" in owner
            and "skate3_source_instance_id" not in owner
            for owner in editable_owners
        )
        if (
            len(owners_by_name) != len(editable_owners)
            or len(owners_by_id) != len(editable_owners)
            or instance_owner_count != EXPECTED_SOURCE_INSTANCE_VISUAL_OWNERS
            or logical_owner_count != EXPECTED_LOGICAL_SOURCE_VISUAL_OWNERS
            or instance_owner_count + logical_owner_count
            != len(editable_owners)
        ):
            raise RuntimeError(
                "University editable owner names/IDs collide or source "
                "instance/logical owner counts changed"
            )
        for owner in editable_owners:
            if "skate3_source_instance_id" not in owner:
                continue
            source_template = json.loads(
                str(owner.get("skate3_source_template", "null"))
            )
            if not isinstance(source_template, dict):
                raise RuntimeError(
                    f"{owner.name!r} incorrectly treats a null streaming "
                    "record as an editable retail object"
                )
        for obj in objects:
            owner_name = str(obj.get("ow_map_object_owner", ""))
            owner = owners_by_name.get(owner_name)
            if owner is None:
                raise RuntimeError(
                    f"{obj.name!r} lost its emitted editable visual owner"
                )
            attribute = obj.data.attributes.get(
                EDITOR_VISUAL_OWNER_ATTRIBUTE
            )
            if (
                attribute is None
                or attribute.domain != "FACE"
                or attribute.data_type != "INT"
                or len(attribute.data) != len(obj.data.polygons)
            ):
                raise RuntimeError(
                    f"{obj.name!r} lost face-level visual ownership"
                )
            referenced_names = json.loads(
                str(obj.get(EDITOR_VISUAL_OWNER_NAMES, "[]"))
            )
            referenced_ids = {
                _stable_object_id(str(name)) for name in referenced_names
            }
            values = numpy.empty(len(attribute.data), dtype=numpy.int32)
            attribute.data.foreach_get("value", values)
            face_ids = {int(value) & 0xFFFFFFFF for value in values}
            if (
                not face_ids
                or not face_ids.issubset(referenced_ids)
                or not face_ids.issubset(owners_by_id)
            ):
                raise RuntimeError(
                    f"{obj.name!r} references invalid visual owner IDs"
                )
        for obj in collision_objects:
            owner_name = str(obj.get("ow_map_object_owner", ""))
            owner = owners_by_name.get(owner_name)
            if owner is None:
                raise RuntimeError(
                    f"{obj.name!r} lost its emitted editable collision owner"
                )
            attribute = obj.data.attributes.get(
                EDITOR_COLLISION_OWNER_ATTRIBUTE
            )
            if (
                attribute is None
                or attribute.domain != "FACE"
                or attribute.data_type != "INT"
                or len(attribute.data) != len(obj.data.polygons)
            ):
                raise RuntimeError(
                    f"{obj.name!r} lost face-level collision ownership"
                )
            values = numpy.empty(len(attribute.data), dtype=numpy.int32)
            attribute.data.foreach_get("value", values)
            ids = {int(value) & 0xFFFFFFFF for value in values}
            if not ids.issubset(owners_by_id):
                raise RuntimeError(
                    f"{obj.name!r} references invalid collision owner IDs"
                )
            collision_owner_ids.update(ids)
        if len(collision_owner_ids) != EXPECTED_COLLISION_OWNERS:
            raise RuntimeError(
                f"University has {len(collision_owner_ids)} collision owners, "
                f"expected {EXPECTED_COLLISION_OWNERS}"
            )
        for obj in grind_objects:
            inferred_owner = str(
                obj.get("skate3_inferred_editor_owner", "")
            )
            owner_method = str(
                obj.get("skate3_editor_owner_method", "")
            )
            owner_distance = float(
                obj.get("skate3_editor_owner_distance", float("inf"))
            )
            if (
                not inferred_owner
                or obj.parent is None
                or obj.parent.name != inferred_owner
                or inferred_owner not in owners_by_name
                or owner_method
                not in {
                    "nearest exact collision face owner",
                    "nearest visual owner in source fuse/cell",
                }
                or owner_distance > MAXIMUM_GRIND_OWNER_DISTANCE
            ):
                raise RuntimeError(
                    f"{obj.name!r} lost its deterministic inferred editor "
                    "owner"
                )
        if (
            collision_face_owned_grinds
            != EXPECTED_COLLISION_FACE_OWNED_GRIND_RAILS
            or proximity_owned_grinds
            != EXPECTED_PROXIMITY_OWNED_GRIND_RAILS
        ):
            raise RuntimeError(
                "University grind ownership method totals changed: "
                f"collision_face={collision_face_owned_grinds}, "
                f"proximity={proximity_owned_grinds}"
            )

    print(
        json.dumps(
            {
                "status": "UNIVERSITY_BLEND_MATERIALS_OK",
                "mesh_parts": len(objects),
                "alpha_modes": dict(sorted(modes.items())),
                "unresolved_by_alpha_mode": dict(sorted(unresolved.items())),
                "regression_bindings": len(REGRESSION_BINDINGS),
                "normal_mapped_objects": normal_mapped_objects,
                "normal_textures": len(normal_texture_ids),
                "normal_materials": len(normal_materials),
                "source_lightmap_references": source_lightmap_references,
                "lightmapped_objects": lightmapped_objects,
                "lightmap_textures": len(lightmap_texture_ids),
                "lightmap_materials": len(lightmap_materials),
                "lightmap_exclusions": lightmap_exclusions,
                "retail_world_frames": retail_world_frames,
                "grind_rails": len(grind_objects),
                "grind_segments": grind_segments,
                "closed_grind_rails": closed_grinds,
                "collision_meshes": len(collision_objects),
                "collision_surfaces": len(collision_surfaces),
                "collision_triangles": collision_triangles,
                "editable_visual_owners": len(editable_owners),
                "source_instance_visual_owners": instance_owner_count,
                "logical_source_visual_owners": logical_owner_count,
                "collision_owners": len(collision_owner_ids),
                "source_instances": len(source_instances),
                "owned_grind_rails": owned_grinds,
                "unowned_grind_rails": unowned_grinds,
                "collision_face_owned_grind_rails": (
                    collision_face_owned_grinds
                ),
                "proximity_owned_grind_rails": proximity_owned_grinds,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
