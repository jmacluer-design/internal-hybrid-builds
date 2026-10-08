#!/usr/bin/env python3
"""Extract Bevy inputs from a legally owned Skate 3 disc extraction."""

from __future__ import annotations

import argparse
import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from tools.owned_game.big import BigArchive, BigEntry
else:
    from .big import BigArchive, BigEntry


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = PROJECT_ROOT / "work" / "private-assets" / "owned-game"
DEFAULT_CHARACTER_MANIFEST = PROJECT_ROOT / "tools" / "default_skater_retail_manifest.json"
ABIN_IMPORTER = PROJECT_ROOT / "tools" / "vendor" / "skate3_anim" / "abin_importer.py"

ARCHIVES = {
    "miscload": {
        "relative": Path("data/big/miscload.big"),
        "size": 44_920_384,
        "sha256": "3673FDC0CA3B6DAA72260350DD9263F068EC5999D9604B3C11BFE4F4248942EC",
    },
    "character": {
        "relative": Path("data/content/createacharacter.big"),
        "size": 472_328_128,
        "sha256": "B87E9E01D446DF37D707D0F2AC2AB872BAF29BBA91EEAE5FD08997C7D475D4EB",
    },
    "university": {
        "relative": Path("data/content/worldDIST_University.big"),
        "size": 798_165_184,
        "sha256": "37D6A4517BD0A5E25F493F18409EDFBD3B3D74229F12F1AB6C15598AA3240091",
    },
}

REQUIRED_JOYSTICK = {
    "skater.pat",
    "skater90.pat",
    "skaterN90.pat",
    "skater_air.pat",
    "skater_fingerflip.pat",
    "skaterls.pat",
    "skaterstep.pat",
}
REQUIRED_MISCLOAD = {
    "data/anim/onboard.abin",
    "data/anim/offboard.abin",
    "data/cacrecipes/savedrecipefallbackmale.bin",
    "data/content/world/models/dist_skybox.rx2",
    "data/content/world/models/dist_skybox_textures.rx2",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def validate_archive(path: Path, description: dict[str, object]) -> None:
    if not path.is_file():
        raise RuntimeError(f"Required retail archive is missing: {path}")
    if path.stat().st_size != description["size"]:
        raise RuntimeError(
            f"{path.name} has size {path.stat().st_size}; expected "
            f"{description['size']}. Use an unmodified retail disc extraction."
        )
    actual_hash = sha256(path)
    if actual_hash != description["sha256"]:
        raise RuntimeError(
            f"{path.name} SHA-256 is {actual_hash}; expected "
            f"{description['sha256']}. Use the supported unmodified retail disc."
        )


def entry_map(archive: BigArchive) -> dict[str, BigEntry]:
    return {entry.path.lower(): entry for entry in archive.entries}


def require_entries(archive: BigArchive, paths: set[str], label: str) -> list[BigEntry]:
    by_name = entry_map(archive)
    missing = sorted(path for path in paths if path.lower() not in by_name)
    if missing:
        raise RuntimeError(f"{label} is missing archive entries: {missing}")
    return [by_name[path.lower()] for path in sorted(paths)]


def character_paths(manifest_path: Path) -> set[str]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    paths: set[str] = set()
    for component in manifest["components"]:
        model_id = component["model_id"].lower()
        paths.add(
            "data/content/createacharacter/model/cas_db/"
            f"{component['slot']}/0x{model_id}.rx2"
        )
        for texture_id in component["textures"].values():
            paths.add(
                "data/content/createacharacter/texture/"
                f"0x{texture_id.lower()}.rx2"
            )
    return paths


def load_abin_importer():
    spec = importlib.util.spec_from_file_location(
        "skate3_vendored_abin_importer", ABIN_IMPORTER
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load ABIN parser: {ABIN_IMPORTER}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def write_catalog(abin_path: Path, destination: Path) -> int:
    module = load_abin_importer()
    abin = module.AbinFile(abin_path.read_bytes())
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow(
            [
                "index",
                "name",
                "codec",
                "fps",
                "frames",
                "parts",
                "block_offset",
                "block_size",
            ]
        )
        for index, clip in enumerate(abin.clips):
            writer.writerow(
                [
                    index,
                    clip.header.name,
                    f"0x{clip.header.codec:08X}",
                    format(clip.fps, ".9g"),
                    clip.num_frames,
                    len(clip.parts),
                    clip.header.offset,
                    clip.header.size,
                ]
            )
    return len(abin.clips)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--game-root",
        type=Path,
        required=True,
        help="Root of an extracted legally owned Skate 3 Xbox 360 disc",
    )
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--character-manifest", type=Path, default=DEFAULT_CHARACTER_MANIFEST
    )
    parser.add_argument(
        "--miscload",
        type=Path,
        help="Development-only override for a clean miscload.big",
    )
    parser.add_argument(
        "--skip-university-files",
        action="store_true",
        help="Validate but do not unpack University files",
    )
    args = parser.parse_args()

    game_root = args.game_root.resolve()
    output_root = args.output_root.resolve()
    archive_paths = {
        key: (
            args.miscload.resolve()
            if key == "miscload" and args.miscload
            else game_root / description["relative"]
        )
        for key, description in ARCHIVES.items()
    }
    for key, path in archive_paths.items():
        validate_archive(path, ARCHIVES[key])

    miscload = BigArchive(archive_paths["miscload"])
    misc_paths = set(REQUIRED_MISCLOAD)
    misc_paths.update(f"data/joystick/{name}".lower() for name in REQUIRED_JOYSTICK)
    misc_paths.update(
        entry.path.lower()
        for entry in miscload.entries
        if entry.path.lower().startswith("data/state/")
    )
    misc_entries = require_entries(miscload, misc_paths, "miscload.big")
    miscload.extract_entries(misc_entries, output_root, overwrite=True)

    character = BigArchive(archive_paths["character"])
    selected_character_paths = character_paths(args.character_manifest)
    character_entries = require_entries(
        character, selected_character_paths, "createacharacter.big"
    )
    character.extract_entries(character_entries, output_root, overwrite=True)

    university = BigArchive(archive_paths["university"])
    if not args.skip_university_files:
        university.extract_entries(
            university.entries, output_root / "university-archive", overwrite=True
        )

    onboard = output_root / "data" / "anim" / "OnBoard.abin"
    catalog = output_root / "generated" / "skate3_onboard_clips.csv"
    clip_count = write_catalog(onboard, catalog)
    manifest = {
        "schema": 1,
        "game_root": str(game_root),
        "archives": {
            key: {
                "path": str(path),
                "size": path.stat().st_size,
                "sha256": sha256(path),
            }
            for key, path in archive_paths.items()
        },
        "outputs": {
            "miscload_entries": len(misc_entries),
            "character_entries": len(character_entries),
            "university_entries": len(university.entries),
            "university_unpacked": not args.skip_university_files,
            "onboard_clips": clip_count,
        },
    }
    manifest_path = output_root / "_owned_game_manifest.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    print(
        "OWNED_GAME_INPUTS_OK "
        f"miscload={len(misc_entries)} character={len(character_entries)} "
        f"university={len(university.entries)} clips={clip_count} "
        f"output={output_root}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"OWNED_GAME_INPUTS_FAILED: {error}", file=sys.stderr)
        raise SystemExit(1)
