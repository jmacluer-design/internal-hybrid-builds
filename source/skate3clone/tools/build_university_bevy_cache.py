#!/usr/bin/env python3
"""Build the ignored Bevy cache from the locally generated University package."""

from __future__ import annotations

import argparse
from array import array
import hashlib
import importlib
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile
import zlib


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_PATH = ROOT / "university" / "university_expected.json"
CACHE_ROOT = ROOT / "assets" / "private" / "university"
SOURCE_ROOT = CACHE_ROOT / "source"
RUNTIME_ROOT = CACHE_ROOT / "cache"
RUNTIME_MANIFEST = RUNTIME_ROOT / "runtime_manifest.json"
PRESERVATION_MANIFEST = RUNTIME_ROOT / "preservation_manifest.json"

AUTHORITATIVE_TOOL_ROOTS = (ROOT / "tools" / "vendor" / "university",)
RETAIL_ARCHIVE_CANDIDATES: tuple[Path, ...] = ()
RETAIL_SKYBOX_ROOT_CANDIDATES: tuple[Path, ...] = ()
UTT_ROOT_CANDIDATES = (ROOT / "tools" / "vendor" / "utt",)

PACKAGE_RELATIVE_CANDIDATES = (
    Path(
        "work/private-assets/university-build/"
        "University.full-fidelity.v15.skate"
    ),
    Path(
        "tools/vanilla_map_extraction/intermediate/"
        "university_full_fidelity/University.full-fidelity.v15.skate"
    ),
    Path(
        "out/university-visual-check/prepared/"
        "owned_maps/University.skate"
    ),
)

BLOCK_FILES = {
    "visual_vertices": "visual_vertices.bin",
    "visual_indices": "visual_indices.bin",
    "collision": "collision.bin",
    "grind_rails": "grind_rails.bin",
    "visual_groups": "visual_groups.bin",
    "retail_sky_mesh": "retail_sky_mesh.bin",
    "retail_sky_panorama": "retail_sky_panorama.rgba.zlib",
}


class BuildError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path, chunk_size: int = 8 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(chunk_size):
            digest.update(chunk)
    return digest.hexdigest()


def canonical_json_bytes(value: object) -> bytes:
    return (
        json.dumps(
            value,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
        )
        + "\n"
    ).encode("utf-8")


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        dir=path.parent, prefix=f".{path.name}.", delete=False
    ) as temporary:
        temporary.write(data)
        temporary.flush()
        temporary_path = Path(temporary.name)
    os.replace(temporary_path, path)


def write_if_changed(path: Path, data: bytes) -> bool:
    expected_hash = sha256_bytes(data)
    if path.is_file() and path.stat().st_size == len(data):
        if sha256_file(path) == expected_hash:
            return False
    atomic_write(path, data)
    return True


def load_expected() -> dict[str, object]:
    try:
        return json.loads(EXPECTED_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BuildError(f"cannot read {EXPECTED_PATH}: {error}") from error


def find_tool_root() -> Path:
    override = os.environ.get("SKATE3_UNIVERSITY_SK8_SOURCE")
    roots = ([Path(override)] if override else []) + list(
        AUTHORITATIVE_TOOL_ROOTS
    )
    for root in roots:
        analyzer = root / "tools" / "blender_owned_map" / "analyze_skate.py"
        if analyzer.is_file():
            return root
    searched = "\n  ".join(str(path) for path in roots)
    raise BuildError(
        "the bundled University analyzer was not found. Searched:\n"
        f"  {searched}\n"
        "Set SKATE3_UNIVERSITY_SK8_SOURCE to the full-fidelity Source folder."
    )


def find_package(expected: dict[str, object], tool_root: Path) -> Path:
    override = os.environ.get("SKATE3_UNIVERSITY_PACKAGE")
    candidates: list[Path] = []
    if override:
        candidates.append(Path(override))
    candidates.append(ROOT / PACKAGE_RELATIVE_CANDIDATES[0])
    candidates.extend(tool_root / relative for relative in PACKAGE_RELATIVE_CANDIDATES)
    for root in AUTHORITATIVE_TOOL_ROOTS:
        candidates.extend(root / relative for relative in PACKAGE_RELATIVE_CANDIDATES)

    expected_package = expected["package"]
    expected_size = int(expected_package["file_bytes"])
    expected_hash = str(expected_package["sha256"]).lower()
    rejected: list[str] = []
    for candidate in candidates:
        if not candidate.is_file():
            continue
        actual_size = candidate.stat().st_size
        if actual_size != expected_size:
            rejected.append(
                f"{candidate} (size {actual_size}, expected {expected_size})"
            )
            continue
        actual_hash = sha256_file(candidate)
        if actual_hash.lower() != expected_hash:
            rejected.append(
                f"{candidate} (SHA-256 {actual_hash}, expected {expected_hash})"
            )
            continue
        return candidate

    detail = "\n  ".join(rejected) if rejected else "no candidate files exist"
    raise BuildError(
        "the authoritative University.full-fidelity.v15.skate package is "
        "missing or stale.\n"
        f"Expected SHA-256 {expected_hash.upper()} and {expected_size} bytes.\n"
        f"Candidates: {detail}\n"
        "Run tools/build_university_from_owned_game.ps1 first, or set "
        "SKATE3_UNIVERSITY_PACKAGE to the matching package."
    )


def find_retail_archive(expected: dict[str, object]) -> tuple[Path, str]:
    override = os.environ.get("SKATE3_UNIVERSITY_RETAIL_ARCHIVE")
    candidates = ([Path(override)] if override else [])
    owned_manifest = (
        ROOT
        / "work"
        / "private-assets"
        / "owned-game"
        / "_owned_game_manifest.json"
    )
    if owned_manifest.is_file():
        try:
            owned = json.loads(owned_manifest.read_text(encoding="utf-8"))
            candidates.append(Path(owned["archives"]["university"]["path"]))
        except (OSError, KeyError, TypeError, json.JSONDecodeError):
            pass
    candidates.extend(RETAIL_ARCHIVE_CANDIDATES)
    source = expected["source"]
    expected_size = int(source["retail_archive_bytes"])
    expected_hash = str(source["retail_archive_sha256"]).lower()
    rejected: list[str] = []
    for candidate in candidates:
        if not candidate.is_file():
            continue
        actual_size = candidate.stat().st_size
        if actual_size != expected_size:
            rejected.append(
                f"{candidate} (size {actual_size}, expected {expected_size})"
            )
            continue
        actual_hash = sha256_file(candidate)
        if actual_hash.lower() == expected_hash:
            return candidate, actual_hash
        rejected.append(
            f"{candidate} (SHA-256 {actual_hash}, expected {expected_hash})"
        )
    detail = "\n  ".join(rejected) if rejected else "no candidate files exist"
    raise BuildError(
        "the authorized retail University archive is missing or stale.\n"
        f"Expected SHA-256 {expected_hash.upper()} and {expected_size} bytes.\n"
        f"Candidates: {detail}\n"
        "Set SKATE3_UNIVERSITY_RETAIL_ARCHIVE to the matching "
        "worldDIST_University.big."
    )


def find_retail_skybox(
    expected: dict[str, object],
) -> tuple[Path, Path, Path, dict[str, str]]:
    contract = expected["source"]["retail_skybox"]
    model_override = os.environ.get("SKATE3_RETAIL_SKYBOX_MODEL")
    textures_override = os.environ.get("SKATE3_RETAIL_SKYBOX_TEXTURES")
    if bool(model_override) != bool(textures_override):
        raise BuildError(
            "SKATE3_RETAIL_SKYBOX_MODEL and "
            "SKATE3_RETAIL_SKYBOX_TEXTURES must be set together"
        )
    roots = [
        ROOT
        / "work"
        / "private-assets"
        / "owned-game"
        / "data"
        / "content"
        / "world"
        / "models"
    ] + list(RETAIL_SKYBOX_ROOT_CANDIDATES)
    pairs = (
        [(Path(model_override), Path(textures_override))]
        if model_override and textures_override
        else [
            (
                root / str(contract["model_name"]),
                root / str(contract["textures_name"]),
            )
            for root in roots
        ]
    )
    rejected: list[str] = []
    model_path: Path | None = None
    textures_path: Path | None = None
    model_hash = ""
    textures_hash = ""
    for candidate_model, candidate_textures in pairs:
        if not candidate_model.is_file() or not candidate_textures.is_file():
            continue
        if candidate_model.stat().st_size != int(contract["model_bytes"]):
            rejected.append(f"{candidate_model} (unexpected size)")
            continue
        if candidate_textures.stat().st_size != int(contract["textures_bytes"]):
            rejected.append(f"{candidate_textures} (unexpected size)")
            continue
        candidate_model_hash = sha256_file(candidate_model)
        candidate_textures_hash = sha256_file(candidate_textures)
        if candidate_model_hash != str(contract["model_sha256"]).lower():
            rejected.append(f"{candidate_model} (SHA-256 {candidate_model_hash})")
            continue
        if candidate_textures_hash != str(contract["textures_sha256"]).lower():
            rejected.append(
                f"{candidate_textures} (SHA-256 {candidate_textures_hash})"
            )
            continue
        model_path = candidate_model
        textures_path = candidate_textures
        model_hash = candidate_model_hash
        textures_hash = candidate_textures_hash
        break
    if model_path is None or textures_path is None:
        detail = "\n  ".join(rejected) if rejected else "no candidate pair exists"
        raise BuildError(
            "the authorized retail Skate 3 skybox RX2 pair is missing or stale.\n"
            f"Candidates: {detail}\n"
            "Set SKATE3_RETAIL_SKYBOX_MODEL and "
            "SKATE3_RETAIL_SKYBOX_TEXTURES to the matching retail files."
        )

    utt_override = os.environ.get("SKATE3_UTT_ROOT")
    utt_candidates = ([Path(utt_override)] if utt_override else []) + list(
        UTT_ROOT_CANDIDATES
    )
    utt_root = next(
        (
            root
            for root in utt_candidates
            if (root / "mdl_parser" / "parser.py").is_file()
            and (root / "rx2_parser.py").is_file()
        ),
        None,
    )
    if utt_root is None:
        raise BuildError(
            "the authorized UTT RX2 parser is unavailable. Set "
            "SKATE3_UTT_ROOT to a folder containing mdl_parser/parser.py "
            "and rx2_parser.py."
        )
    return model_path, textures_path, utt_root, {
        "skybox_model_sha256": model_hash,
        "skybox_textures_sha256": textures_hash,
        "utt_model_parser_sha256": sha256_file(
            utt_root / "mdl_parser" / "parser.py"
        ),
        "utt_texture_parser_sha256": sha256_file(utt_root / "rx2_parser.py"),
    }


def extract_retail_skybox(
    expected: dict[str, object],
    model_path: Path,
    textures_path: Path,
    utt_root: Path,
) -> tuple[bytes, bytes, dict[str, object]]:
    contract = expected["source"]["retail_skybox"]
    sys.path.insert(0, str(utt_root))
    model_parser = importlib.import_module("mdl_parser.parser")
    texture_parser = importlib.import_module("rx2_parser")
    parsed_model = model_parser.parse_rx2(model_path.read_bytes())
    matching_meshes = [
        mesh
        for mesh in parsed_model.meshes
        if str(mesh.name) == str(contract["mesh_name"])
    ]
    require_equal("retail sky mesh count", len(matching_meshes), 1)
    mesh = matching_meshes[0]
    require_equal("retail sky vertices", len(mesh.vertices), contract["vertices"])
    require_equal("retail sky normals", len(mesh.normals), contract["vertices"])
    require_equal("retail sky UVs", len(mesh.uvs), contract["vertices"])
    require_equal("retail sky triangles", len(mesh.faces), contract["triangles"])

    packed_mesh = bytearray(b"UNIVSKY1")
    packed_mesh.extend(
        struct.pack("<II", len(mesh.vertices), len(mesh.faces) * 3)
    )
    for position, normal, uv in zip(
        mesh.vertices, mesh.normals, mesh.uvs, strict=True
    ):
        values = (*position, *normal, *uv)
        if not all(math.isfinite(float(value)) for value in values):
            raise BuildError("retail sky mesh contains a non-finite value")
        packed_mesh.extend(struct.pack("<8f", *(float(value) for value in values)))
    for face in mesh.faces:
        if len(face) != 3 or any(
            int(index) < 0 or int(index) >= len(mesh.vertices) for index in face
        ):
            raise BuildError("retail sky mesh contains an invalid face")
        packed_mesh.extend(struct.pack("<3I", *(int(index) for index in face)))
    require_equal(
        "retail sky packed mesh SHA-256",
        sha256_bytes(packed_mesh),
        str(contract["packed_mesh_sha256"]).lower(),
    )

    parsed_textures = texture_parser.parse_rx2(textures_path.read_bytes())
    texture_index = int(contract["panorama_texture_index"])
    if texture_index >= len(parsed_textures.textures):
        raise BuildError(
            f"retail sky panorama index {texture_index} is unavailable"
        )
    panorama = parsed_textures.textures[texture_index]
    require_equal(
        "retail sky panorama width",
        panorama.width,
        contract["panorama_width"],
    )
    require_equal(
        "retail sky panorama height", panorama.height, contract["panorama_height"]
    )
    panorama_rgba = bytes(panorama.rgba)
    require_equal(
        "retail sky panorama bytes",
        len(panorama_rgba),
        panorama.width * panorama.height * 4,
    )
    require_equal(
        "retail sky panorama SHA-256",
        sha256_bytes(panorama_rgba),
        str(contract["panorama_decoded_sha256"]).lower(),
    )
    compressed_panorama = zlib.compress(panorama_rgba, level=1)
    return bytes(packed_mesh), compressed_panorama, {
        "model": {
            "path": str(model_path.resolve()),
            "bytes": model_path.stat().st_size,
            "sha256": sha256_file(model_path),
        },
        "textures": {
            "path": str(textures_path.resolve()),
            "bytes": textures_path.stat().st_size,
            "sha256": sha256_file(textures_path),
        },
        "mesh_name": str(mesh.name),
        "vertices": len(mesh.vertices),
        "indices": len(mesh.faces) * 3,
        "triangles": len(mesh.faces),
        "panorama_width": panorama.width,
        "panorama_height": panorama.height,
        "panorama_decoded_bytes": len(panorama_rgba),
        "panorama_decoded_sha256": sha256_bytes(panorama_rgba),
    }


def validate_source_manifest(
    tool_root: Path, expected: dict[str, object]
) -> tuple[Path, dict[str, object]]:
    override = os.environ.get("SKATE3_UNIVERSITY_SOURCE_MANIFEST")
    path = (
        Path(override)
        if override
        else ROOT
        / "work"
        / "private-assets"
        / "university-build"
        / "intermediate"
        / "manifest.json"
    )
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BuildError(f"cannot read full-fidelity manifest {path}: {error}") from error
    summary = manifest.get("summary", {})
    checks = {
        "district_name": manifest.get("district_name"),
        "decoded_textures": summary.get("decoded_textures"),
        "mesh_parts": summary.get("mesh_parts"),
        "collision_mesh_assets": summary.get("collision_mesh_assets"),
        "collision_meshes": summary.get("collision_meshes"),
        "collision_clusters": summary.get("collision_clusters"),
        "collision_triangles": summary.get("collision_triangles"),
        "grind_rails": summary.get("grind_rails"),
        "grind_segments": summary.get("grind_segments"),
        "source_instance_records": summary.get("source_instance_records"),
    }
    required = {
        "district_name": expected["source"]["district_name"],
        "decoded_textures": expected["package"]["counts"]["textures"],
        "mesh_parts": 8546,
        "collision_mesh_assets": expected["package"]["retail_collision"]["assets"],
        "collision_meshes": expected["package"]["retail_collision"]["meshes"],
        "collision_clusters": expected["package"]["retail_collision"][
            "source_clusters"
        ],
        "collision_triangles": expected["package"]["retail_collision"][
            "source_triangles"
        ],
        "grind_rails": expected["package"]["counts"]["grind_rails"],
        "grind_segments": expected["package"]["counts"]["native_grind_segments"],
        "source_instance_records": 5027,
    }
    for label, value in required.items():
        require_equal(f"source manifest {label}", checks[label], value)
    return path, checks


def load_analyzer(tool_root: Path):
    analyzer_path = (
        tool_root / "tools" / "blender_owned_map" / "analyze_skate.py"
    )
    spec = importlib.util.spec_from_file_location(
        "sk8_university_analyze_skate", analyzer_path
    )
    if spec is None or spec.loader is None:
        raise BuildError(f"cannot import analyzer {analyzer_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module, analyzer_path


def require_equal(label: str, actual: object, expected: object) -> None:
    if actual != expected:
        raise BuildError(f"{label}: got {actual!r}, expected {expected!r}")


def validate_analysis(
    analysis: dict[str, object], expected: dict[str, object]
) -> None:
    package = expected["package"]
    require_equal("format version", analysis["version"], package["format_version"])
    require_equal("map name", analysis["map_name"], package["map_name"])
    require_equal("package bytes", analysis["file_bytes"], package["file_bytes"])
    for key, value in package["counts"].items():
        if key in analysis["counts"]:
            require_equal(f"count {key}", analysis["counts"][key], value)
    require_equal(
        "visual triangles",
        analysis["counts"]["indices"] // 3,
        package["counts"]["visual_triangles"],
    )
    require_equal(
        "material alpha modes",
        analysis["material_alpha_modes"],
        package["material_alpha_modes"],
    )
    require_equal(
        "dynamic lighting default",
        analysis["dynamic_lighting_enabled_by_default"],
        package["dynamic_lighting_enabled_by_default"],
    )
    integrity = analysis["integrity"]
    for key, value in package["integrity"].items():
        # Frame identity is emitted by the upstream full-fidelity validator,
        # while analyze_skate validates the containing extension stream hash.
        if key == "retail_world_frames_sha256":
            continue
        require_equal(f"integrity {key}", integrity[key].lower(), value.lower())
    require_equal(
        "portable collision hash",
        integrity["collision_sha256"].lower(),
        package["retail_collision"]["portable_sha256"].lower(),
    )
    for axis in range(3):
        require_equal(
            f"bounds min axis {axis}",
            integrity["bounds_min"][axis],
            package["bounds_min"][axis],
        )
        require_equal(
            f"bounds max axis {axis}",
            integrity["bounds_max"][axis],
            package["bounds_max"][axis],
        )


def parse_spawn(package_bytes: bytes) -> tuple[list[float], float]:
    offset = 12
    name_size = struct.unpack_from("<I", package_bytes, offset)[0]
    offset += 4 + name_size
    x, y, z, heading = struct.unpack_from("<4f", package_bytes, offset)
    return [x, y, z], heading


def section_offset(
    sections: dict[str, int], section_name: str
) -> tuple[int, int]:
    offset = 0
    for name, size in sections.items():
        if name == section_name:
            return offset, size
        offset += size
    raise BuildError(f"analyzer did not report section {section_name!r}")


def texture_usage(materials: list[dict[str, object]]) -> dict[int, set[str]]:
    usage: dict[int, set[str]] = {}
    stock_slots = {
        "albedo_texture": "albedo",
        "lightmap_texture": "lightmap",
        "normal_texture": "normal",
        "orm_texture": "orm",
        "emissive_texture": "emissive",
    }
    for material in materials:
        for field, role in stock_slots.items():
            texture_id = int(material.get(field, 0))
            if texture_id:
                usage.setdefault(texture_id, set()).add(role)
        for binding in material.get("retail_texture_bindings", []):
            texture_id = int(binding["texture"])
            if texture_id:
                usage.setdefault(texture_id, set()).add(
                    str(binding["semantic"])
                )
    return usage


def extract_textures(
    analyzer,
    package_bytes: bytes,
    sections: dict[str, int],
    expected_count: int,
    usage: dict[int, set[str]],
) -> tuple[list[dict[str, object]], str]:
    texture_offset, _ = section_offset(sections, "textures")
    reader = analyzer.Reader(package_bytes, texture_offset)
    decoded_payloads: list[bytes] = []
    records: list[dict[str, object]] = []
    inventory_digest = hashlib.sha256()
    texture_root = RUNTIME_ROOT / "textures"
    texture_root.mkdir(parents=True, exist_ok=True)

    for index in range(expected_count):
        texture_id = index + 1
        name = reader.string(f"texture {index} name")
        width = reader.u32(f"texture {index} width")
        height = reader.u32(f"texture {index} height")
        color_space = reader.u32(f"texture {index} color space")
        rgba = reader.stored(
            width * height * 4, f"texture {index}", decoded_payloads
        )
        decoded_payloads.append(rgba)
        compressed = zlib.compress(rgba, level=1)
        relative = f"textures/{texture_id:04d}.rgba.zlib"
        output = RUNTIME_ROOT / relative
        changed = write_if_changed(output, compressed)
        if index % 100 == 0 or changed and index % 25 == 0:
            print(
                f"[University cache] texture {texture_id}/{expected_count}: "
                f"{name}",
                flush=True,
            )
        rgba_hash = sha256_bytes(rgba)
        compressed_hash = sha256_bytes(compressed)
        inventory_digest.update(struct.pack("<III", texture_id, width, height))
        inventory_digest.update(bytes.fromhex(rgba_hash))
        records.append(
            {
                "id": texture_id,
                "name": name,
                "width": width,
                "height": height,
                "source_color_space": color_space,
                "decoded_sha256": rgba_hash,
                "compressed_sha256": compressed_hash,
                "decoded_bytes": len(rgba),
                "file": relative,
                "roles": sorted(usage.get(texture_id, ())),
            }
        )
    return records, inventory_digest.hexdigest()


def runtime_material(material: dict[str, object]) -> dict[str, object]:
    keys = (
        "id",
        "name",
        "display_color",
        "roughness",
        "emissive_intensity",
        "albedo_texture",
        "lightmap_texture",
        "baked_indirect_strength",
        "normal_texture",
        "orm_texture",
        "emissive_texture",
        "alpha_mode",
        "alpha_cutoff",
        "audio_surface",
        "physics_surface",
        "surface_pattern",
        "presentation_depth_layer",
        "retail_shader_family",
        "retail_render_flags",
        "retail_texture_bindings",
        "secondary_albedo_texture",
        "blend_mask_texture",
        "blend_factor",
        "blend_mask_channel",
        "albedo_address_mode",
        "secondary_address_mode",
        "blend_mask_address_mode",
        "cull_mode",
    )
    return {
        key: material[key]
        for key in keys
        if key in material and material[key] is not None
    }


def build_visual_groups(
    vertex_bytes: bytes, index_values: array, expected_materials: int
) -> tuple[Path, int, int]:
    """Write contiguous retail draw runs as indexed Bevy-ready mesh groups."""
    if len(vertex_bytes) % 56:
        raise BuildError("visual vertex block is not aligned to 56 bytes")
    vertex_count = len(vertex_bytes) // 56
    path = RUNTIME_ROOT / BLOCK_FILES["visual_groups"]
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        dir=path.parent, prefix=".visual_groups.", delete=False
    ) as stream:
        temporary_path = Path(stream.name)
        stream.write(b"UNIVVIS1")
        stream.write(struct.pack("<II", 0, 56))
        group_count = 0
        triangle_count = len(index_values) // 3
        triangle = 0
        while triangle < triangle_count:
            first_index = index_values[triangle * 3]
            material_id = struct.unpack_from(
                "<I", vertex_bytes, first_index * 56 + 40
            )[0]
            if not 1 <= material_id <= expected_materials:
                raise BuildError(
                    f"triangle {triangle} uses material {material_id}"
                )
            expanded: list[int] = []
            while triangle < triangle_count:
                corners = index_values[triangle * 3 : triangle * 3 + 3]
                corner_materials = [
                    struct.unpack_from("<I", vertex_bytes, corner * 56 + 40)[0]
                    for corner in corners
                ]
                if len(set(corner_materials)) != 1:
                    raise BuildError(
                        f"triangle {triangle} crosses materials "
                        f"{corner_materials}"
                    )
                if corner_materials[0] != material_id:
                    break
                expanded.extend(corners)
                triangle += 1

            local_by_global: dict[int, int] = {}
            local_vertices: list[int] = []
            local_indices = array("I")
            for source_index in expanded:
                if source_index >= vertex_count:
                    raise BuildError(
                        f"visual index {source_index} exceeds {vertex_count}"
                    )
                local_index = local_by_global.get(source_index)
                if local_index is None:
                    local_index = len(local_vertices)
                    local_by_global[source_index] = local_index
                    local_vertices.append(source_index)
                local_indices.append(local_index)
            if sys.byteorder != "little":
                local_indices.byteswap()
            stream.write(
                struct.pack(
                    "<III",
                    material_id,
                    len(local_vertices),
                    len(local_indices),
                )
            )
            for source_index in local_vertices:
                offset = source_index * 56
                stream.write(vertex_bytes[offset : offset + 56])
            stream.write(local_indices.tobytes())
            group_count += 1
            if group_count % 500 == 0:
                print(
                    f"[University cache] grouped {triangle:,}/"
                    f"{triangle_count:,} visual triangles",
                    flush=True,
                )
        stream.seek(8)
        stream.write(struct.pack("<I", group_count))
        stream.flush()
    os.replace(temporary_path, path)
    return path, group_count, path.stat().st_size


def cache_fingerprint(
    package_hash: str,
    retail_archive_hash: str,
    source_manifest_path: Path,
    analyzer_path: Path,
    skybox_hashes: dict[str, str],
) -> dict[str, str]:
    return {
        "package_sha256": package_hash.lower(),
        "retail_archive_sha256": retail_archive_hash.lower(),
        "source_manifest_sha256": sha256_file(source_manifest_path),
        "expected_sha256": sha256_file(EXPECTED_PATH),
        "builder_sha256": sha256_file(Path(__file__).resolve()),
        "analyzer_sha256": sha256_file(analyzer_path),
        **skybox_hashes,
    }


def valid_existing_cache(fingerprint: dict[str, str]) -> bool:
    if not RUNTIME_MANIFEST.is_file() or not PRESERVATION_MANIFEST.is_file():
        return False
    try:
        manifest = json.loads(RUNTIME_MANIFEST.read_text(encoding="utf-8"))
        if manifest.get("fingerprint") != fingerprint:
            return False
        for record in manifest["cache_files"].values():
            path = RUNTIME_ROOT / record["file"]
            if (
                not path.is_file()
                or path.stat().st_size != record["bytes"]
                or sha256_file(path) != record["sha256"]
            ):
                return False
        for texture in manifest["textures"]:
            path = RUNTIME_ROOT / texture["file"]
            if (
                not path.is_file()
                or sha256_file(path) != texture["compressed_sha256"]
            ):
                return False
        return True
    except (OSError, KeyError, TypeError, json.JSONDecodeError):
        return False


def build_cache(force: bool, verify_only: bool) -> None:
    expected = load_expected()
    tool_root = find_tool_root()
    retail_archive, retail_archive_hash = find_retail_archive(expected)
    (
        skybox_model_path,
        skybox_textures_path,
        utt_root,
        skybox_hashes,
    ) = find_retail_skybox(expected)
    source_manifest_path, source_inventory = validate_source_manifest(
        tool_root, expected
    )
    package_path = find_package(expected, tool_root)
    package_hash = sha256_file(package_path)
    analyzer, analyzer_path = load_analyzer(tool_root)
    fingerprint = cache_fingerprint(
        package_hash,
        retail_archive_hash,
        source_manifest_path,
        analyzer_path,
        skybox_hashes,
    )

    if not force and valid_existing_cache(fingerprint):
        print(
            "[University cache] verified deterministic cache "
            f"{RUNTIME_MANIFEST}",
            flush=True,
        )
        return
    if verify_only:
        raise BuildError(
            "University cache is missing or stale; rerun without --verify-only "
            "to rebuild it."
        )

    print(f"[University cache] source package: {package_path}", flush=True)
    print(f"[University cache] retail archive: {retail_archive}", flush=True)
    print(f"[University cache] retail skybox: {skybox_model_path}", flush=True)
    print("[University cache] running the bundled v15 analyzer...", flush=True)
    analysis = analyzer.analyze_package(package_path, include_payloads=True)
    validate_analysis(analysis, expected)
    package_bytes = package_path.read_bytes()
    spawn, heading = parse_spawn(package_bytes)
    require_equal("spawn position", spawn, expected["package"]["spawn"]["position"])
    require_equal(
        "spawn heading",
        heading,
        expected["package"]["spawn"]["heading_radians"],
    )

    SOURCE_ROOT.mkdir(parents=True, exist_ok=True)
    source_copy = SOURCE_ROOT / "University.full-fidelity.v15.skate"
    if (
        not source_copy.is_file()
        or source_copy.stat().st_size != len(package_bytes)
        or sha256_file(source_copy) != package_hash
    ):
        print(f"[University cache] staging ignored source: {source_copy}", flush=True)
        temporary = source_copy.with_suffix(".skate.tmp")
        shutil.copyfile(package_path, temporary)
        os.replace(temporary, source_copy)

    RUNTIME_ROOT.mkdir(parents=True, exist_ok=True)
    sections = analysis["sections"]
    index_values = array("I", analysis.pop("_indices"))
    if sys.byteorder != "little":
        index_values.byteswap()
    payloads = {
        "visual_vertices": analysis.pop("_vertex_bytes"),
        "visual_indices": index_values.tobytes(),
        "collision": analysis.pop("_collision_bytes"),
    }
    grind_offset, grind_size = section_offset(sections, "grind_rails")
    payloads["grind_rails"] = package_bytes[
        grind_offset : grind_offset + grind_size
    ]
    analysis.pop("_embedded_retail_collision_bytes", None)
    materials = analysis.pop("_materials")

    cache_files: dict[str, dict[str, object]] = {}
    for name, payload in payloads.items():
        output = RUNTIME_ROOT / BLOCK_FILES[name]
        print(
            f"[University cache] writing {name} ({len(payload):,} bytes)",
            flush=True,
        )
        write_if_changed(output, payload)
        cache_files[name] = {
            "file": BLOCK_FILES[name],
            "bytes": len(payload),
            "sha256": sha256_bytes(payload),
        }

    print(
        "[University cache] deriving contiguous indexed retail draw groups...",
        flush=True,
    )
    grouped_path, draw_group_count, grouped_bytes = build_visual_groups(
        payloads["visual_vertices"],
        index_values,
        int(expected["package"]["counts"]["materials"]),
    )
    cache_files["visual_groups"] = {
        "file": BLOCK_FILES["visual_groups"],
        "bytes": grouped_bytes,
        "sha256": sha256_file(grouped_path),
    }

    print("[University cache] extracting the retail Skate 3 skybox...", flush=True)
    sky_mesh, sky_panorama, skybox = extract_retail_skybox(
        expected,
        skybox_model_path,
        skybox_textures_path,
        utt_root,
    )
    for name, payload in (
        ("retail_sky_mesh", sky_mesh),
        ("retail_sky_panorama", sky_panorama),
    ):
        output = RUNTIME_ROOT / BLOCK_FILES[name]
        write_if_changed(output, payload)
        cache_files[name] = {
            "file": BLOCK_FILES[name],
            "bytes": len(payload),
            "sha256": sha256_bytes(payload),
        }

    print("[University cache] decoding byte-exact texture payloads...", flush=True)
    textures, texture_inventory_hash = extract_textures(
        analyzer,
        package_bytes,
        sections,
        int(expected["package"]["counts"]["textures"]),
        texture_usage(materials),
    )

    runtime = {
        "schema": 2,
        "generator": "tools/build_university_bevy_cache.py",
        "fingerprint": fingerprint,
        "map_name": analysis["map_name"],
        "format_version": analysis["version"],
        "source_package": {
            "file": "../source/University.full-fidelity.v15.skate",
            "bytes": len(package_bytes),
            "sha256": package_hash,
        },
        "retail_archive": {
            "path": str(retail_archive.resolve()),
            "bytes": retail_archive.stat().st_size,
            "sha256": retail_archive_hash,
            "district_indices": expected["source"]["district_indices"],
            "global_streams": expected["source"]["global_streams"],
            "presentation_cells": expected["source"]["presentation_cells"],
            "simulation_cells": expected["source"]["simulation_cells"],
            "texture_cells": expected["source"]["texture_cells"],
        },
        "retail_skybox": skybox,
        "spawn": {
            "position": spawn,
            "heading_radians": heading,
            "provenance": expected["package"]["spawn"]["provenance"],
        },
        "bounds_min": analysis["integrity"]["bounds_min"],
        "bounds_max": analysis["integrity"]["bounds_max"],
        "counts": {
            **analysis["counts"],
            "visual_triangles": analysis["counts"]["indices"] // 3,
        },
        "material_alpha_modes": analysis["material_alpha_modes"],
        "dynamic_lighting_enabled_by_default": analysis[
            "dynamic_lighting_enabled_by_default"
        ],
        "vertex_stride": 56,
        "collision_stride": 48,
        "cache_files": cache_files,
        "draw_group_count": draw_group_count,
        "texture_inventory_sha256": texture_inventory_hash,
        "textures": textures,
        "materials": [runtime_material(material) for material in materials],
        "preservation_manifest": "preservation_manifest.json",
        "preserved": [
            "positions",
            "normals",
            "base_uv",
            "lightmap_uv",
            "decal_uv",
            "packed_tangent_binormal",
            "material_ids",
            "all_named_texture_bindings",
            "all_retail_material_parameters",
            "collision_surface_material_and_edge_codes",
            "retail_native_grind_cubics",
            "object_ownership_and_source_metadata",
            "retail_skybox_mesh_and_panorama",
        ],
        "derived": [
            "spawn_is_SK8_collision_raycast_derived",
            "Bevy_collision_XZ_broadphase",
            "Bevy_low_energy_ambient_fill_requested_for_character_and_dark_foliage",
        ],
        "unsupported": [
            "retail_LocationDescData_default_spawn",
            "active_grind_engagement_thresholds",
            "decoded_irradiance_sections",
            "DMO_dynamic_prop_instantiation",
            "AI_routes_doors_and_local_lights",
            "retail_sky_sun_ramp_frame_constants",
        ],
    }
    preservation = {
        "schema": 1,
        "fingerprint": fingerprint,
        "analysis": analysis,
        "materials": materials,
        "expected_contract": expected,
        "retail_archive": runtime["retail_archive"],
        "source_manifest": {
            "path": str(source_manifest_path.resolve()),
            "sha256": fingerprint["source_manifest_sha256"],
            "inventory": source_inventory,
        },
    }
    atomic_write(PRESERVATION_MANIFEST, canonical_json_bytes(preservation))
    atomic_write(RUNTIME_MANIFEST, canonical_json_bytes(runtime))
    if not valid_existing_cache(fingerprint):
        raise BuildError("fresh cache failed its own deterministic verification")
    print(
        "[University cache] complete: "
        f"{analysis['counts']['indices'] // 3:,} visual triangles, "
        f"{analysis['counts']['collision_triangles']:,} collision triangles, "
        f"{len(textures):,} textures",
        flush=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--force", action="store_true", help="rebuild even if cache verifies"
    )
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="validate the current cache without rebuilding it",
    )
    arguments = parser.parse_args()
    try:
        build_cache(arguments.force, arguments.verify_only)
    except (BuildError, OSError, ValueError, struct.error) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
