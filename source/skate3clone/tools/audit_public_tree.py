#!/usr/bin/env python3
"""Fail when the tracked source tree contains likely retail/private payloads."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

from create_public_snapshot import REQUIRED_PUBLIC_PATHS, is_public_path


ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_PREFIXES = (
    "assets/private/",
    "work/private-assets/",
    "artifacts/",
    "runtime/",
    "target/",
)
FORBIDDEN_SUFFIXES = (
    ".iso",
    ".xex",
    ".xexp",
    ".abin",
    ".rx2",
    ".big",
    ".id0",
    ".id1",
    ".id2",
    ".idb",
    ".i64",
    ".nam",
    ".til",
    ".pdb",
)


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
    parser.add_argument(
        "--distribution",
        action="store_true",
        help="also enforce the intentionally small public distribution surface",
    )
    args = parser.parse_args()

    failures: list[str] = []
    files = tracked_files()
    tracked = set(files)
    for relative in files:
        normalized = relative.replace("\\", "/")
        lowered = normalized.lower()
        if lowered.startswith(FORBIDDEN_PREFIXES):
            failures.append(f"forbidden private path: {relative}")
            continue
        if lowered.endswith(FORBIDDEN_SUFFIXES):
            failures.append(f"forbidden retail/reversing format: {relative}")
            continue

        path = ROOT / relative
        if not path.is_file():
            continue
        with path.open("rb") as stream:
            magic = stream.read(4)
        if magic in (b"XEX2", b"MZ\x90\x00"):
            failures.append(f"forbidden executable signature: {relative}")

    if args.distribution:
        for required in sorted(REQUIRED_PUBLIC_PATHS - tracked):
            failures.append(f"missing required public file: {required}")
        for relative in files:
            if not is_public_path(relative):
                failures.append(f"non-distribution clutter: {relative}")

    if failures:
        print("PUBLIC_TREE_AUDIT_FAILED")
        for failure in failures:
            print(f"  {failure}")
        return 1

    mode = "distribution" if args.distribution else "source"
    print(f"PUBLIC_TREE_AUDIT_OK mode={mode} tracked_files={len(files)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
