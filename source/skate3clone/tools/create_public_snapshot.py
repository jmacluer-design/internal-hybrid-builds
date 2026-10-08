#!/usr/bin/env python3
"""Create the deliberately small, source-only public distribution tree."""

from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]

ROOT_FILES = {
    ".gitignore",
    "Cargo.lock",
    "Cargo.toml",
    "LAUNCH LATEST MAIN.bat",
    "README.md",
    "SETUP FROM OWNED ISO.bat",
    "THIRD_PARTY_NOTICES.md",
    "build.rs",
}

PUBLIC_DIRECTORIES = {
    ".github",
    "assets",
    "docs",
    "parity",
    "research",
    "src",
    "university",
}

EXCLUDED_PUBLIC_PATHS = {
    "docs/CODEX_WORKTREE_WORKFLOW.md",
}

PUBLIC_TOOL_FILES = {
    "add_combined_flip_actions.py",
    "add_mirrored_onboard_actions.py",
    "add_onboard_ik_targets.py",
    "add_retail_fakie_composite_action.py",
    "apply_default_skater_materials.py",
    "assert_glb_360_flip_pose.py",
    "assert_glb_animations.ps1",
    "assert_glb_flip_in_pose.py",
    "assert_glb_foot_targets.py",
    "audit_public_tree.py",
    "build_default_skater_assets.ps1",
    "build_manual_visual_assets.ps1",
    "build_private_assets.ps1",
    "build_university_bevy_cache.py",
    "build_university_from_owned_game.ps1",
    "create_public_snapshot.py",
    "default_skater_retail_manifest.json",
    "export_bevy_glb.py",
    "extract_default_skater.py",
    "extract_owned_xiso.ps1",
    "launch_university_map_visual_test.ps1",
    "setup_from_owned_iso.ps1",
    "validate_default_skater.py",
    "validate_default_skater_deformation.py",
    "verify_fakie_channel_weights.py",
    "verify_skater_visual_compatibility.py",
}

PUBLIC_TOOL_PREFIXES = (
    "tools/owned_game/",
    "tools/vendor/",
)

REQUIRED_PUBLIC_PATHS = {
    "LAUNCH LATEST MAIN.bat",
    "SETUP FROM OWNED ISO.bat",
    "README.md",
    "Cargo.toml",
    "build.rs",
    "tools/setup_from_owned_iso.ps1",
    "tools/owned_game/extract_retail_inputs.py",
    "tools/build_default_skater_assets.ps1",
    "tools/build_university_from_owned_game.ps1",
    "tools/launch_university_map_visual_test.ps1",
}


def is_public_path(relative: str) -> bool:
    normalized = relative.replace("\\", "/")
    if normalized in EXCLUDED_PUBLIC_PATHS:
        return False
    if "/" not in normalized:
        return normalized in ROOT_FILES
    if normalized.startswith(PUBLIC_TOOL_PREFIXES):
        return True
    if normalized.startswith("tools/"):
        return normalized.removeprefix("tools/") in PUBLIC_TOOL_FILES
    return normalized.split("/", 1)[0] in PUBLIC_DIRECTORIES


def tracked_files() -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )
    return [
        entry.decode("utf-8", errors="strict")
        for entry in result.stdout.split(b"\0")
        if entry
    ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()

    destination = args.destination.resolve()
    if destination == ROOT or ROOT in destination.parents:
        raise RuntimeError("Destination must be outside the source checkout")
    if destination.exists() and any(destination.iterdir()):
        raise RuntimeError(f"Destination must be absent or empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True)

    copied = 0
    skipped = 0
    for relative in tracked_files():
        if not is_public_path(relative):
            skipped += 1
            continue
        source = ROOT / relative
        if not source.is_file():
            raise RuntimeError(f"Tracked source file is missing: {source}")
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        copied += 1

    missing = [
        relative
        for relative in sorted(REQUIRED_PUBLIC_PATHS)
        if not (destination / relative).is_file()
    ]
    if missing:
        raise RuntimeError(f"Public snapshot is missing required files: {missing}")

    print(
        f"PUBLIC_SNAPSHOT_OK destination={destination} "
        f"copied={copied} skipped={skipped}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
