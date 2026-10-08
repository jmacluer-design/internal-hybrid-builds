"""Decode retail RenderWare InstanceData and source-object identities.

Skate 3 keeps the authored world-instance table in ``tInstanceData`` even
when presentation geometry and collision have been fused into stream-cell
resources.  This module preserves those records without applying runtime
fixups: section references remain stable RX2 table indices and strings remain
exact section-relative values.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re
import struct


RX2_TOC_RECORD_SIZE = 24
RX2_TYPE_EXTERNAL_REFERENCES = 0x00EB000B
RX2_TYPE_INSTANCE_DATA = 0x00EB000D
INSTANCE_HEADER_SIZE = 32
INSTANCE_RECORD_SIZE = 160
EXTERNAL_REFERENCE_SIZE = 24

_TEMPLATE_PAIR_PATTERN = re.compile(
    r"(0x[0-9A-Fa-f]{16}):(0x[0-9A-Fa-f]{16})::"
)
_FUSE_PATTERN = re.compile(
    r"(?P<prefix>(?:\[0x[0-9A-Fa-f]{16}\])+)"
    r"_HighLOD_Proc_Fuse_Seed_(?P<seed>\d+)_Split_(?P<split>\d+)"
)
_FUSE_BYTES_PATTERN = re.compile(
    rb"(?P<prefix>(?:\[0x[0-9A-Fa-f]{16}\])+)"
    rb"_HighLOD_Proc_Fuse_Seed_(?P<seed>\d+)_Split_(?P<split>\d+)"
)
_STREAM_CELL_PATTERN = re.compile(
    r"^c(?:Pres|Sim)_(-?\d+)_(-?\d+)_high\.xsf$",
    re.IGNORECASE,
)


@dataclass(frozen=True, slots=True)
class Rx2Section:
    index: int
    offset: int
    size: int
    alignment: int
    type_index: int
    section_type: int


@dataclass(frozen=True, slots=True)
class ExternalReference:
    section_index: int
    entry_index: int
    unknown_0: int
    unknown_1: int
    guid: int
    import_type: int
    handle: int


@dataclass(frozen=True, slots=True)
class InstanceRecord:
    section_index: int
    record_index: int
    guid: int
    matrix: tuple[float, ...]
    bounds_min: tuple[float, float, float]
    bounds_max: tuple[float, float, float]
    reference_indices: tuple[int, int, int]
    reference_types: tuple[int | None, int | None, int | None]
    strings: tuple[str, str, str, str]

    @property
    def name(self) -> str:
        return self.strings[0]

    def to_manifest(self) -> dict[str, object]:
        template_pair = source_template_pair(self.name)
        return {
            "section_index": self.section_index,
            "record_index": self.record_index,
            "guid": f"0x{self.guid:016X}",
            "matrix": list(self.matrix),
            "bounds": {
                "minimum": list(self.bounds_min),
                "maximum": list(self.bounds_max),
            },
            "reference_indices": list(self.reference_indices),
            "reference_types": [
                f"0x{value:08X}" if value is not None else None
                for value in self.reference_types
            ],
            "strings": list(self.strings),
            "source_template": (
                {
                    "presentation_guid": template_pair[0],
                    "simulation_guid": template_pair[1],
                }
                if template_pair is not None
                else None
            ),
        }


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def read_rx2_sections(data: bytes) -> tuple[Rx2Section, ...]:
    _require(
        len(data) >= 0x34 and data[:7] == b"\x89RW4xb2",
        "asset is not an Xbox 360 RW4 RX2 resource",
    )
    count = struct.unpack_from(">I", data, 0x20)[0]
    table = struct.unpack_from(">I", data, 0x30)[0]
    _require(
        table + count * RX2_TOC_RECORD_SIZE <= len(data),
        "RX2 section table extends beyond the file",
    )
    sections: list[Rx2Section] = []
    for index in range(count):
        record = table + index * RX2_TOC_RECORD_SIZE
        offset, _, size, alignment, type_index, section_type = (
            struct.unpack_from(">6I", data, record)
        )
        _require(
            offset + size <= len(data),
            f"RX2 section {index} extends beyond the file",
        )
        sections.append(
            Rx2Section(
                index=index,
                offset=offset,
                size=size,
                alignment=alignment,
                type_index=type_index,
                section_type=section_type,
            )
        )
    return tuple(sections)


def decode_external_references(
    data: bytes,
    sections: tuple[Rx2Section, ...] | None = None,
) -> tuple[ExternalReference, ...]:
    sections = sections or read_rx2_sections(data)
    result: list[ExternalReference] = []
    for section in sections:
        if section.section_type != RX2_TYPE_EXTERNAL_REFERENCES:
            continue
        _require(
            section.size >= 8,
            "RX2 external-reference section omits its header",
        )
        count, table = struct.unpack_from(">2I", data, section.offset)
        _require(
            table >= 8
            and table + count * EXTERNAL_REFERENCE_SIZE <= section.size,
            "RX2 external-reference table has invalid bounds",
        )
        for entry_index in range(count):
            entry = (
                section.offset
                + table
                + entry_index * EXTERNAL_REFERENCE_SIZE
            )
            (
                unknown_0,
                unknown_1,
                guid_high,
                guid_low,
                import_type,
                handle,
            ) = struct.unpack_from(">6I", data, entry)
            result.append(
                ExternalReference(
                    section_index=section.index,
                    entry_index=entry_index,
                    unknown_0=unknown_0,
                    unknown_1=unknown_1,
                    guid=(guid_high << 32) | guid_low,
                    import_type=import_type,
                    handle=handle,
                )
            )
    return tuple(result)


def _section_string(
    data: bytes,
    section: Rx2Section,
    relative_offset: int,
) -> str:
    if relative_offset == 0:
        return ""
    _require(
        relative_offset < section.size,
        "RX2 InstanceData string offset is outside its section",
    )
    start = section.offset + relative_offset
    end = data.find(b"\0", start, section.offset + section.size)
    _require(end >= 0, "RX2 InstanceData string is not terminated")
    return data[start:end].decode("utf-8", errors="surrogateescape")


def decode_instance_data(
    data: bytes,
    sections: tuple[Rx2Section, ...] | None = None,
) -> tuple[InstanceRecord, ...]:
    sections = sections or read_rx2_sections(data)
    result: list[InstanceRecord] = []
    for section in sections:
        if section.section_type != RX2_TYPE_INSTANCE_DATA:
            continue
        _require(
            section.size >= INSTANCE_HEADER_SIZE,
            "RX2 InstanceData section omits its header",
        )
        (
            _signature,
            count,
            _string_count,
            record_table,
            string_table,
            _unknown_0,
            _unknown_1,
            _unknown_2,
        ) = struct.unpack_from(">8I", data, section.offset)
        _require(
            record_table >= INSTANCE_HEADER_SIZE
            and record_table + count * INSTANCE_RECORD_SIZE <= section.size,
            "RX2 InstanceData record table has invalid bounds",
        )
        _require(
            string_table == 0
            or record_table + count * INSTANCE_RECORD_SIZE
            <= string_table
            <= section.size,
            "RX2 InstanceData string table has invalid bounds",
        )
        for record_index in range(count):
            offset = (
                section.offset
                + record_table
                + record_index * INSTANCE_RECORD_SIZE
            )
            words = struct.unpack_from(">40I", data, offset)
            reference_indices = tuple(words[32:35])
            reference_types: list[int | None] = []
            for reference in reference_indices:
                if reference == 0:
                    reference_types.append(None)
                    continue
                _require(
                    reference < len(sections),
                    "RX2 InstanceData references a missing section",
                )
                reference_types.append(sections[reference].section_type)
            bounds = struct.unpack_from(">8f", data, offset + 64)
            result.append(
                InstanceRecord(
                    section_index=section.index,
                    record_index=record_index,
                    guid=(words[24] << 32) | words[25],
                    matrix=struct.unpack_from(">16f", data, offset),
                    bounds_min=tuple(bounds[:3]),
                    bounds_max=tuple(bounds[4:7]),
                    reference_indices=reference_indices,
                    reference_types=tuple(reference_types),
                    strings=tuple(
                        _section_string(data, section, relative)
                        for relative in words[35:39]
                    ),
                )
            )
    return tuple(result)


def source_template_pair(name: str) -> tuple[str, str] | None:
    match = _TEMPLATE_PAIR_PATTERN.search(name)
    if match is None:
        return None
    return tuple(value.lower() for value in match.groups())


def fuse_identity(name: str, *, split_offset: int = 0) -> tuple[str, int, int] | None:
    match = _FUSE_PATTERN.search(name)
    if match is None:
        return None
    return (
        match.group("prefix").lower(),
        int(match.group("seed")),
        int(match.group("split")) + split_offset,
    )


def fuse_identities(data: bytes) -> tuple[tuple[str, int, int], ...]:
    result: list[tuple[str, int, int]] = []
    seen: set[tuple[str, int, int]] = set()
    for match in _FUSE_BYTES_PATTERN.finditer(data):
        identity = (
            match.group("prefix").decode("ascii").lower(),
            int(match.group("seed")),
            int(match.group("split")),
        )
        if identity not in seen:
            seen.add(identity)
            result.append(identity)
    return tuple(result)


def stream_cell_key(stream_file: str | Path) -> str:
    name = Path(stream_file).name
    match = _STREAM_CELL_PATTERN.match(name)
    if match is not None:
        return f"{int(match.group(1))}:{int(match.group(2))}"
    if name.casefold() in {"cpres_global.xsf", "csim_global.xsf"}:
        return "global"
    return name.casefold()


def visual_fuse_key(
    stream_file: str | Path,
    identity: tuple[str, int, int],
) -> str:
    prefix, seed, split = identity
    return f"{stream_cell_key(stream_file)}|{prefix}|{seed}|{split}"
