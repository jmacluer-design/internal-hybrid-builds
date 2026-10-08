"""Verify the authored per-bone weights embedded in FAKIE_CHANNEL_CYC."""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path


EXPECTED = {
    "SPINE2": 0.5,
    "SPINE3": 0.7,
    "NECK": 1.0,
    "NECK1": 1.0,
    "HEAD": 1.0,
}


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--abin", required=True, type=Path)
    parser.add_argument("--importer-dir", required=True, type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    sys.path.insert(0, str(args.importer_dir.resolve()))
    from abin_importer import AbinFile, BONE_NAMES  # pylint: disable=import-error

    data = args.abin.read_bytes()
    archive = AbinFile(data)
    if archive.hierarchy is None:
        raise RuntimeError("OnBoard archive has no hierarchy")
    clip = next(
        (item for item in archive.clips if item.header.name == "FAKIE_CHANNEL_CYC"),
        None,
    )
    if clip is None:
        raise RuntimeError("OnBoard archive has no FAKIE_CHANNEL_CYC")
    if len(clip.parts) != archive.hierarchy.num_parts:
        raise RuntimeError(
            "FAKIE_CHANNEL_CYC part count does not match the OnBoard hierarchy"
        )

    actual = {}
    for animation_part, skeleton_part in zip(
        clip.parts,
        archive.hierarchy.parts,
        strict=True,
    ):
        weight_bytes = animation_part.comp_hdr_rel - 0x10
        required_bytes = 4 * skeleton_part.total_bone_count
        if weight_bytes < required_bytes:
            raise RuntimeError(
                "FAKIE_CHANNEL_CYC is missing its authored channel-weight table "
                f"for part {animation_part.table_index}"
            )
        for local_index in range(skeleton_part.total_bone_count):
            bone_index = skeleton_part.sqt_offset + local_index
            bone_name = BONE_NAMES[bone_index]
            weight = struct.unpack_from(
                ">f",
                data,
                animation_part.abs_offset + 0x10 + local_index * 4,
            )[0]
            actual[bone_name] = weight

    nonzero = {
        name: weight for name, weight in actual.items() if abs(weight) > 1.0e-7
    }
    if set(nonzero) != set(EXPECTED):
        raise RuntimeError(
            f"FAKIE_CHANNEL_CYC weighted bones changed: {sorted(nonzero)}"
        )
    for name, expected in EXPECTED.items():
        if abs(nonzero[name] - expected) > 1.0e-6:
            raise RuntimeError(
                f"FAKIE_CHANNEL_CYC {name} weight changed: "
                f"expected {expected}, found {nonzero[name]}"
            )

    print(
        "FAKIE_CHANNEL_WEIGHTS_OK "
        + json.dumps(
            {
                "clip": clip.header.name,
                "block_offset": f"0x{clip.header.offset:X}",
                "weights": nonzero,
                "zero_weight_bones": len(actual) - len(nonzero),
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
