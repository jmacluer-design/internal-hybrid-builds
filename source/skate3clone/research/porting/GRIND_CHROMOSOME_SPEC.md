# TU3 grind chromosome classifier

## Evidence identity

Observed in the read-only IDA database
`Skate3TU3_dump.community-disposable.i64`, whose input image is
`default_82000000_011B0000.bin`:

- Input image size: `18,546,688` bytes.
- Input image SHA-256:
  `F4AA113EB541BFBA03DBC108CF5AB43F58C965B20FA3B82F9C40938A0AD841C4`.
- `PhysOutConditioner_Grinds::NameGrind`: `0x82DEF1C8..0x82DEF514`,
  844 bytes, SHA-256
  `75A31CEDD743D42AB131A1ED39FF9AA61D58AAEF220F9A18D69F2E961B645B43`.
- Exact index-arithmetic block: `0x82DEF47C..0x82DEF4D4`, 88 bytes,
  SHA-256
  `E58FEE82D53376B865AA1F64C5B6FB6D375B44D67C5CE0C4A05A9F43364C98CB`.
- The lookup load at `0x82DEF4D0` indexes the runtime pointer array at
  `0x8307E090`.
- The 384 ordered display/canonical string pairs occupy
  `0x8206FCE4..0x8207268C`, 10,664 bytes, SHA-256
  `05CDB5C5313F63A567CD84AE34ACD869BBD65099787A3BCA847F64434D2B1646`.
- The NUL-separated canonical-name sequence alone is 4,224 bytes, SHA-256
  `8FA7CCBCA90F773DFCC1277ACA278E6ED572D82A80E532F8B24281CA7B24D317`.
  Its independently testable FNV-1a-64 fingerprint is
  `2CA85C957DD2E53D`.

The extracted
`MotionGraphIncludes/Grinds/Grinds.xml` has SHA-256
`89042598DC9BCAC397E7CF43DFEBE37E1C452EE42062029E53BE5A6459B5029E`.
Its 54 unique `GRIND_NAME` values exactly equal the 54 unique canonical
strings in the 384-entry executable table in both directions.

## Exact arithmetic

The PPC instructions at `0x82DEF47C..0x82DEF4D0` perform:

```text
index = (((((approach * 2 + board_end)
             * 2 + alignment)
             * 2 + height)
             * 4 + travel)
             * 6 + contact)
```

The observed labels and numeric values are:

| Field | Values |
|---|---|
| approach | `0 A-FS`, `1 A-BS` |
| board end | `0 NOSE`, `1 TAIL` |
| alignment | `0 TWST`, `1 STRT` |
| height | `0 HI`, `1 LO` |
| travel | `0 FOR`, `1 BAK`, `2 F180`, `3 B180`, `4 UNK` |
| contact | `0 5050`, `1 BOARD`, `2 TIP`, `3 5_O`, `4 BACKSLASH`, `5 NA` |

The arithmetic proves that travel's table radix is four even though the
diagnostic formatter recognizes value four as `UNK`. Therefore `UNK` is a
sentinel, not a fifth valid table digit. For example:

```text
FS/NOSE/TWST/HI/UNK/5050 == raw index 24
FS/NOSE/TWST/LO/FOR/5050 == raw index 24
```

At upper boundaries an `UNK` raw index can also exceed 383. The implementation
retains `Travel::Unknown` so telemetry can represent the observed label, but
classification rejects it. It does not invent an alias mapping.

## Port behavior

`src/grind_chromosome.rs` provides:

- typed enums for all six fields;
- `GrindChromosome` and validated raw conversion;
- exact mixed-radix `table_index`;
- `classify` returning `ClassificationResult`;
- the complete 384-entry canonical-name table;
- the 54-name XML set and `validate_table`.

All `2 * 2 * 2 * 2 * 4 * 6 = 384` valid tuples are observed and mapped. There
are no holes in that valid space. The only unresolved tuple category is travel
`UNK`: TU3's formatter labels it, but the executable provides no independent
canonical-table slots for it, so it remains intentionally unclassified.
