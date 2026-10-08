# Skate 3 TU3 grind acquisition and lock-on boundary

`src/grind_contact.rs` is the evidence-gated boundary between authored rail
data, TU3 trajectory selection, the six-field grind chromosome, and the
existing grind graph. It ports only behavior proven by the executable or a
corroborating local native-format artifact.

It does **not** classify a grind from generic board/rail angles. The remaining
retail providers and arbitration branches are typed requirements.

## Build identity and static evidence

The read-only IDA database was:

`C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\XexDump\disposable\Skate3TU3_dump.community-disposable.i64`

Its input image was:

`C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\XexDump\default_82000000_011B0000.bin`

- Size: `18,546,688` bytes.
- SHA-256:
  `F4AA113EB541BFBA03DBC108CF5AB43F58C965B20FA3B82F9C40938A0AD841C4`.

Read-only IDALib decompilation was corroborated against the generated
instruction translation:

`C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\generated\skate3_animation_research_recomp.88.cpp`

- SHA-256:
  `93E826F1B4C79089D68B86B103C13DBB18D39C9993311E36EBE9E502BA787C1B`.

Function identities:

| Function | Address range | Size | SHA-256 |
|---|---:|---:|---|
| `TrajectorySelector::CalculateGrindTrajData` | `0x82D69F80..0x82D6A168` | 488 | `E191CA3C864ED0D874705D9801F687F531731E3655242BA0023BFCA1D3D21A22` |
| `TrajectorySelector::FindBestGrind` | `0x82D6A168..0x82D6A398` | 560 | `84EE2BECEC6790A7CF51898AD60C23F8AB4021E993675B08C6B93CEC190F1B5C` |
| `TrajectorySelector::ConsiderGrindPrimitive` | `0x82D6A398..0x82D6A840` | 1,192 | `AA1A9F4A827D4B9C03BAA2389DBB401BD68B6F971C568F1F1239906936D2B153` |
| `TrajectorySelector::AnalyzeAndAdjustTrajectory` | `0x82D6A840..0x82D6AF58` | 1,816 | `A6B4359508C32E17642B0C1EC958B86165C3A8E944115A2284C45BE86787E37A` |
| `GrindAirAdjust::UpdateGrindAdjust` | `0x82D712E0..0x82D71430` | 336 | `D5E8EE562E7E8C00EC3B0AF6D62956901A7CA557DB71F78EA613BA620A014FD1` |
| `GrindAirAdjust::ProjectPoints` | `0x82D71430..0x82D71F40` | 2,832 | `7C18FBB6D45661136217677C1CC29F2C1B7AAE5F275E0B33FB3231B2A7A4374D` |
| deck-Z/grind-angle calculation | `0x82D71F40..0x82D72B40` | 3,072 | `4C66B3B8FC5A635DA624EFAC0A11FEE4F2C902CF61503D221B8D031FDB48F8A6` |
| `GrindAirAdjust::InitTargets` | `0x82D72B40..0x82D72F08` | 968 | `BF9406EED17E4E77460B2EF21EB934C9B0C17862ACD523B4FD6A44B3C626CEF1` |

The known function names came from
`skate3-tu3-1.05-community.map` and IDA's recovered symbols. All addresses are
guest virtual addresses, not host ASLR addresses.

## Observed record topology

### Grind query

At `0x82D69FF4..0x82D6A150`, `CalculateGrindTrajData`:

- reads a primitive count from query offset `+0`;
- starts the primitive array at query offset `+16`;
- advances exactly `48` bytes for every primitive;
- calls `ConsiderGrindPrimitive` once per primitive in source order;
- stamps the zero-based source primitive index into accepted result offset
  `+80`;
- writes the query count to selector offset `+9556`;
- inserts accepted 85-byte results into the selector candidate list rooted at
  selector offset `+2992`.

The 48-byte primitive is three 16-byte vector fields. At
`0x82D6A3B0..0x82D6A3DC`, `ConsiderGrindPrimitive` immediately loads fields
`+0` and `+16` and subtracts `field_00` from `field_10`. This is implemented as
`GrindPrimitive::endpoint_delta_xyz`. The complete role of field `+32` is not
yet proven and remains offset-named.

### `GrindTrajectoryResults`

The exact payload copied by `CalculateGrindTrajData` and `FindBestGrind` is:

| Offset | Width | Port field |
|---:|---:|---|
| `+0x00` | 16 | `vector_00` |
| `+0x10` | 16 | `vector_10` |
| `+0x20` | 16 | `vector_20` |
| `+0x30` | 16 | `vector_30` |
| `+0x40` | 4 | `scalar_40` |
| `+0x44` | 4 | `scalar_44` |
| `+0x48` | 4 | `scalar_48` |
| `+0x4C` | 4 | `word_4c` |
| `+0x50` | 4 | source primitive index |
| `+0x54` | 1 | validity byte |

Total payload size: `85` bytes.

The module supports big-endian decode/encode for this payload and preserves
the validity byte rather than reducing it to a guessed enum.

## Observed candidate arbitration

`FindBestGrind` traverses the candidate list and compares `scalar_40`:

1. It loads a runtime primary score limit through the selector's runtime
   attribute chain.
2. Candidates with `scalar_40 < runtime_limit` enter a more complex primary
   comparator.
3. Other candidates enter a strict fallback comparison against a literal
   initial ceiling of `1000.0`.
4. A fallback candidate replaces the current fallback winner only when its
   score is strictly lower. Equal-score ties therefore retain the first
   traversed candidate.
5. The selected result is copied to the caller and its candidate-list node is
   removed.

The primary comparator includes additional vector/angle work and runtime data.
Its complete rule is not recovered. `CandidatePool::find_best_remove` therefore
requires a retail `PrimaryBranchResolution` whenever at least one candidate is
below the runtime primary limit. It cannot silently run the fallback path for
those candidates.

The runtime score limit itself is also required. The port does not substitute
`1000.0` for it; `1000.0` is only the independently observed fallback ceiling.

## Observed analyze/retry topology

At `0x82D6A8B8`, `AnalyzeAndAdjustTrajectory` first calls
`CalculateGrindTrajData`. It then:

- calls `FindBestGrind`;
- subjects that destructively removed candidate to later trajectory and
  runtime gates;
- on rejection, calls `FindBestGrind` again and tests the next selected
  candidate;
- uses result offset `+80` to index the original 48-byte primitive array;
- copies two selected primitive vector fields to selector offsets `+2944` and
  `+2960`;
- marks successful adjusted-trajectory state at selector offset `+9656`.

`analyze_and_adjust` reproduces this select-remove-test-retry order. Every gate
decision is supplied as retail evidence. If candidates remain but no next
attempt is supplied, the function returns
`GrindRequirement::AdditionalRetryEvidence`.

## Spline ABI corroboration

The local native map adapter:

`C:\Users\Daddy\Documents\Skate3Research\owned\world\src\grind_spline.cpp`

- SHA-256:
  `C855AB084AFA44927C8F48028F952FF8E80EF3B3F6493F31368A4C7B80B50732`.

It serializes the Pegasus grind-spline format consumed by the engine:

- 16-byte header;
- 32-byte rail records;
- 144-byte segment records.

The segment layout exposed by `RetailSplineSegment` is:

- delta vector at `+0x00`;
- two unresolved vectors at `+0x10` and `+0x20`;
- start vector at `+0x30`;
- reciprocal-length vector at `+0x40`;
- minimum and maximum bounds at `+0x50` and `+0x60`;
- length and cumulative length at `+0x70` and `+0x74`;
- rail, previous-segment, and next-segment guest addresses at
  `+0x78/+0x7C/+0x80`;
- three trailing words at `+0x84`.

The Rust decoder treats guest addresses as numeric guest addresses, never host
pointers. `evaluate_unclamped` implements only the serialized affine
`start + delta * parameter` operation. It does not clamp or manufacture the
parameter because TU3's parameter-selection and acquisition thresholds remain
unrecovered.

This source is corroborating project-owned format evidence, not independent
proof of every selector branch. Its adapter-only minimum segment length and
rail hash policy are deliberately not ported as Skate 3 mechanics.

## Chromosome provider boundary

`PhysOutConditioner_Grinds::NameGrind` and the existing
`grind_chromosome` module prove the final six raw enum domains:

| Field | Valid observed raw values |
|---|---|
| approach | `0..=1` |
| board end | `0..=1` |
| alignment | `0..=1` |
| height | `0..=1` |
| travel | `0..=4` |
| contact | `0..=5` |

`assemble_raw_chromosome` requires all six provider values. It validates only
these observed domains. It does not derive approach, board end, alignment,
height, travel, or contact from a generic angle threshold.

Travel value four is preserved because TU3's formatter labels it `UNK`, but
`RawGrindChromosome::is_table_classifiable` returns false because the canonical
name table has radix four. The downstream `grind_chromosome` classifier must
continue rejecting this sentinel.

## Graph route fields

The authored graph has additional decisions that are not determined by the
canonical chromosome name alone:

- blunt rail versus backslash route;
- dark-grind frontside versus backside approach route.

`GrindGraphRouteFields` carries both as explicit optional retail decisions.
Its `require_*` methods return typed requirements and never choose a default.

## Unresolved evidence seams

The following remain blocked:

- rail/ledge query ABI that produces the 48-byte primitive array;
- every retail rail acquisition threshold and runtime attribute;
- exact contact-position and ground-normal provider values used during
  primitive consideration;
- the primary candidate comparator below the runtime score limit;
- complete semantic names for the four result vectors and remaining scalars;
- PPC/Xenon vector normalization and rounding needed for bit-identical math;
- every later `AnalyzeAndAdjustTrajectory` acceptance/rejection threshold;
- lock transform and adjustment output;
- the individual producers of the six chromosome digits;
- blunt and dark graph-route arbitration.

Required runtime telemetry should capture, per selector tick:

- query count and all 48 primitive bytes;
- each 85-byte consideration result before collection;
- runtime primary score limit;
- primary comparator winner or no-winner result;
- destructive selection order;
- each later trajectory gate and rejection reason;
- final primitive index and selector fields `+2896`, `+2944`, `+2960`,
  `+9654`, `+9656`, `+9663`, and `+9664`;
- the six final chromosome provider words and both extra graph-route branches.

Until those captures exist, the Rust boundary returns a typed unresolved value
instead of substituting geometry heuristics.

## Validation

The focused module was compiled independently so no central integration file
needed to be edited:

```powershell
rustc --edition 2024 --test src\grind_contact.rs -D warnings
```

Coverage includes:

- 48-byte primitive decode and endpoint delta;
- exact primitive-array stride and length rejection;
- all 85 candidate bytes round-tripping big-endian;
- source-order collection and primitive-index stamping;
- typed unresolved primitive consideration;
- strict fallback ordering and first-tie behavior;
- the exact `1000.0` fallback ceiling;
- mandatory primary-branch evidence;
- destructive select/reject/retry behavior;
- typed missing-retry evidence;
- unclamped spline evaluation;
- provider-only chromosome assembly and raw-domain validation;
- preservation of travel `UNK`;
- non-defaulting graph route fields.

Result: `14 passed; 0 failed`, with warnings denied. No game, renderer,
Computer Use, or visual session was launched.
