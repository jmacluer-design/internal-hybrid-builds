# Skate 3 TU3 Flickit PatternNode and Arbitration

This specification records only behavior observed in the TU3 executable or
directly derived from those instructions. It does not assign gameplay meanings
to unresolved packed fields.

## Evidence identity

- IDA database:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\XexDump\disposable\Skate3TU3_dump.community-disposable.i64`
- Database SHA-256:
  `C15ADE171038CEE5E00B7C5FFE4E7FBD21EECEE2C6FF1EEC676E792408DFDF8B`
- Generated TU containing the five functions:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\generated\skate3_animation_research_recomp.26.cpp`
- Generated TU SHA-256:
  `8B70FDAAAA7E6C247115F34804CFFEFDDFC5302DE72C085243688877A2F385FE`
- Reusable read-only extractor:
  `C:\Users\Daddy\Documents\skate3clone\tools\ida_decompile_flickit.py`
- Runtime recompilation image:
  `C:\Users\Daddy\Documents\Skate3Research\harness\skate3.exe`
- Runtime image SHA-256:
  `28C3B477B80A94C6E10DB6E1A4174762A1229696C18FC6ABB68DD34433612D4D`

## Critical path

| Address | Observed role |
| --- | --- |
| `0x826962D8` | Filters components, pushes one 16-byte sample, visits patterns and publishes matches. |
| `0x82697168` | Pattern match/lock wrapper. Requires more than one history sample. |
| `0x826972B8` | Updates nodes, selects the maximum-score complete node, writes the 16-byte match result. |
| `0x826974A8` | Advances every 32-byte PatternNode from the current sample/history. |
| `0x82699738` | 201-entry, 16-byte-element ring-buffer `push_front`. |
| `0x826997A8` | Ring-buffer indexed access used by PatternNode advancement. |
| `0x82696030` | Per-player input update; invokes `0x826962D8` once for each of two lanes. |
| `0x82859E70` | Input-notification path which invokes `0x82696030` when input recognition is enabled. |

## PatternNode layout

Each node is 32 bytes.

| Offset | Observed access |
| --- | --- |
| `+0x00` | Pointer used for ring-history indexing. |
| `+0x04` | Packed state word. |
| `+0x08` | Accumulated squared-distance value; reset to `0.0`. |
| `+0x0C` | Squared tolerance copied from pattern data. |
| `+0x10` | 16-byte vector copied during node initialization and read by the inactive path. |

Packed word consumers and producers:

| Bits | Observed behavior |
| --- | --- |
| `31` | Active flag tested by `0x826974A8`; set by the inactive-to-active path. |
| `30` | Complete/eligible flag tested by `0x826972B8`; set by the terminal advancement path. |
| `26..29` | Four-bit field initialized from `coordinate_count - 1`, read for history indices, decremented during advancement. |
| `16..25` | Ten-bit field incremented during advancement, consumed by winner scoring, and copied to result `+0x0C`. |
| `10..15` | Six-bit field incremented/reset during advancement and compared with pattern byte `+0x21`. |
| `6..9` | Four-bit coordinate count inserted by node initialization and consumed by scoring. |
| `0..5` | Preserved by the observed reset paths; producer meaning remains unresolved. |

The initializer at `0x82696A90` proves the coordinate-count and initial
coordinate-index relationships.

The parser pushes each file-order `coord` to the front of a ring. Runtime
ring index zero is therefore the final file coordinate, while the ring's last
element is file coordinate zero.

Exact advancement at `0x826974A8`:

1. An inactive node compares the sample with file coordinate zero.
2. A hit sets bit 31, stores its squared distance, sets span to one, and sets
   the coordinate index to `coordinate_count - 2`.
3. An active node compares against the reverse-ring coordinate at the current
   index.
4. A hit adds squared distance, increments span, clears the consecutive-gap
   field, and decrements the coordinate index. A hit at index zero sets bit 30.
5. A miss increments span and consecutive gap, except while the sample remains
   within tolerance of the immediately preceding matched coordinate in the
   observed `count - index == 2` branch.
6. The node resets only when consecutive gap is strictly greater than the
   recognizer-attribute byte at matcher config offset `+0x21`. Headless runtime
   capture recovered the retail value as `10`.
7. Reset uses mask `0x3C0003FF`: active, complete, span, and gap are cleared;
   coordinate index/count and low six bits are preserved.

## Exact candidate arbitration

Only nodes with bit 30 set participate. Nodes are scanned in storage order.
The first eligible node becomes the winner. A later node replaces it only when
its score is strictly greater, so ties are stable.

Let:

- `n = packed[6..9]`
- `span = packed[16..25]`
- `error = node(+0x08)`

The internal selection score is:

```text
n^4 / (min(max(0.15, error) / n, 0.15) * span)
```

The selected node writes:

```text
result +0x00 = pattern/name pointer
result +0x08 = error
result +0x0C = float(span)
```

Result `+0x04` is a piecewise quality curve over `ratio = span / n`.

Default mode:

```text
ratio <= 1.75 -> 1
ratio >= 4.4  -> 0
otherwise     -> (4.4 - ratio) / (4.4 - 1.75)
```

Mode 2:

```text
ratio <= 1.5 -> 1
ratio >= 3.0 -> 0
otherwise    -> (3.0 - ratio) / (3.0 - 1.5)
```

Referenced constants read directly by headless IDA:

| Address | Float |
| --- | ---: |
| `0x82165A10` | `0.0` |
| `0x822F88D4` | `1000000.0` |
| `0x820994B4` | `0.150000006` |
| `0x822249B4` | `1.5` |
| `0x82063B08` | `3.0` |
| `0x821E63E8` | `1.75` |
| `0x821E63EC` | `4.4000001` |
| `0x8231A844` | `1.0` |

## Pattern contexts

Retail ships normal ground, `+90`, `-90`, airborne, and fingerflip
right-stick patterns in five separate files. The recovered initialization and
update path keeps these as context-selected collections; file prefixes and the
recovered gesture-group tables independently preserve the same separation.
They are not one 269-node semantic ground-trick list.

The Rust recognizer therefore requires a typed `PatternContext`. Its default
playable context is normal ground and advances only the 78 `skater.pat` nodes.
The other four right-stick collections remain constructible for their future
graph owners. Candidate acceptance also rejects a `PatternId` from a sibling
context, preventing an externally supplied rotated/air winner from entering
the normal held/released path.

## Cadence

Static call-graph evidence proves event-driven placement, not a fixed Hertz:

1. `0x82859E70` handles an input notification.
2. If recognition byte `+0x91` is enabled, it calls `0x82696030`.
3. `0x82696030` visits each active player and calls `0x826962D8` once per
   enabled lane.
4. Each `0x826962D8` call pushes exactly one sample before pattern evaluation.

Headless Frida attached to the paused SK8 Oracle and hooked the generated host
functions by their `PPCFuncMappings` entries. A single upstream notification
produced the exact ratio:

```text
0x82859E70 input notification : 1
0x82696030 recognizer dispatch: 1
0x826962D8 lane update        : 2
0x826974A8 matcher update     : 7
```

Repeated controlled `ORACLE STEP 1` commands preserved that ratio whenever a
notification occurred. Oracle steps themselves can coalesce: seven controlled
steps produced five input notifications in one capture, while a separate
20-step batch produced three. Therefore a rendered-frame or simulation-step
Hertz would be an invention. The exact recognizer contract is event-driven:
invoke one lane update, and push one sample, for each retail input
notification. Rust exposes that contract directly and retains
`RecognizerSampleCadence` only for the unresolved outer SK8
Oracle/render/simulation-to-notification mapping.

## Runtime matcher configuration

At `0x826974A8`, the headless hook decoded the guest matcher pointer from
`PPCContext.r3`, translated the big-endian config pointer at matcher `+0x04`,
and read config byte `+0x21`.

All observed live matcher objects returned `10`:

```text
config 0x42062310: five matcher objects, 15 calls, value 10
config 0x42062340: two matcher objects,  6 calls, value 10
```

This removes `PatternNodeMaximumGapConfiguration` from the Rust typed blocker
set. `RETAIL_PATTERN_MAXIMUM_GAP_SAMPLES` is the evidence-backed live default;
the explicit configuration method remains available for deterministic capture
comparison.

## Rust implementation

`src/trick_input.rs` now includes:

- exact live PatternNode initialization and advancement;
- exact reversal from file coordinate order to TU3 ring order;
- strict retail gap reset behavior with captured value `10`;
- exact packed-field extraction;
- exact internal arbitration score;
- stable strict-greater winner selection;
- exact result-quality curves;
- typed isolation of the five retail right-stick pattern contexts;
- externally advanced/captured node acceptance into the already proven
  held/released path;
- an exact retail live entry point using the captured runtime gap byte;
- deterministic tests for node activation, previous-coordinate hold,
  progression, strict gap reset, field extraction, score, quality,
  eligibility, tie behavior, and winner activation.

The compatibility geometry-only entry point still refuses to publish a trick
because it bypasses the event-driven PatternNode producer. The recovered retail
entry point is `observe_processed_retail`; the explicit comparison entry point
is `observe_processed_with_retail_pattern_config`.

## Remaining runtime capture

The matcher byte and recognizer-side cadence are resolved. A future telemetry
take may correlate retail notification sequence numbers with the outer SK8
Oracle/render/simulation clocks. This is not needed inside the recognizer and
no fixed Hertz is assumed by the Rust port.
