# TU3 offboard animation adapter

Status: evidence-backed physical-leaf inventory for the resources emitted by
`src/offboard.rs`. This document does not claim that the current Bevy offboard
state machine has complete TU3 parity.

## Build and artifact identity

| Artifact | SHA-256 |
|---|---|
| Skate 3 TU3 `data/anim/OffBoard.abin` (3,982,936 bytes, 652 clips) | `4C7E33FD054B621F24CA9394D29B82EE40108700A7B8CC6CE1DC9AA4F5A5E00D` |
| Parsed ABIN catalog `skate3_offboard_clips.csv` | `4FD04CDC17209D4DFC15415D7280FF121CC64E07093A11AB451812CDB3677906` |
| Pinned 243-action Bevy manifest | `B5578A493A9432685A98179085655D787E3D82B48E8A649BC41998C672FDE56F` |
| Pinned Bevy GLB | `50FD4FF6300A7EA49B135E6B1AD110EB9101CC4472B87471C87358FB90B14EE3` |
| Pinned root-motion export | `885C80DABE7F778F3589B7A28594EEE13225852CC8FABC7DDDB64C85319BDD05` |
| Audited `src/offboard.rs` | `27DCAF5726C6F53C29578C44E0032132E6094BFCD402732D0D6FE9E041D911C8` |
| TU3 ground offboard graph XML | `4E1C238A574BBEBAC1DD50088067232C1E045CD47A8F93166874F2F23F4042D8` |
| TU3 mount graph XML | `C29D5B46D5299DCE3F43A0E04914DAF0BC81B4EB00AD79FCA3622B364C6744C6` |
| TU3 dismount graph XML | `AE43F3A429137F746DD7C96C39C355D731728E1EE66E92BA32FB8F5D2E5D67FC` |

The ABIN report is an observed parse of the authorized local TU3 bank. GLB
indices were independently read from the binary GLB JSON chunk, not inferred
from the manifest line order.

## Resource audit

`src/offboard.rs` can emit 36 unique names. All 36 are physical TU3 ABIN leaves,
and all 36 exist in the pinned GLB. There is no missing asset in this specific
set.

| Resource | ABIN | GLB | Frames | Offset | Bytes | Retail transition |
|---|---:|---:|---:|---:|---:|---:|
| `BR_DISMOUNT_FAST_HI_INTO_RUN_FWD` | 331 | 0 | 79 | 2,157,040 | 9,776 | 0.1 s |
| `BR_DISMOUNT_HI_INTO_RUN_FWD` | 333 | 2 | 72 | 2,176,656 | 8,800 | 0.1 s |
| `BR_DISMOUNT_HI_INTO_STAND_0` | 334 | 3 | 96 | 2,185,456 | 9,440 | 0.2 s |
| `BR_RUN_FWD_0_INTO_MOUNT` | 382 | 6 | 54 | 2,704,384 | 7,376 | 0.1 s |
| `BR_RUN_FWD_0_INTO_STAND_0` | 225 | 7 | 67 | 1,560,160 | 7,104 | 0.1 s |
| `BR_RUN_FWD_25_INTO_MOUNT` | 383 | 8 | 54 | 2,711,760 | 7,328 | 0.1 s |
| `BR_RUN_FWD_25_INTO_STAND_0` | 228 | 9 | 58 | 1,579,760 | 6,480 | 0.1 s |
| `BR_RUN_FWD_50_INTO_MOUNT` | 384 | 10 | 45 | 2,719,088 | 6,976 | 0.1 s |
| `BR_RUN_FWD_50_INTO_STAND_0` | 231 | 11 | 67 | 1,598,848 | 7,040 | 0.1 s |
| `BR_RUN_FWD_75_INTO_MOUNT` | 385 | 12 | 48 | 2,726,064 | 7,216 | 0.1 s |
| `BR_RUN_FWD_75_INTO_STAND_0` | 234 | 13 | 58 | 1,618,224 | 6,496 | 0.1 s |
| `BR_RUN_FWD_CYC` | 169 | 14 | 39 | 973,104 | 5,776 | 0.2 s |
| `BR_SPRINT_FWD_0_INTO_MOUNT` | 386 | 15 | 45 | 2,733,280 | 7,184 | 0.1 s |
| `BR_SPRINT_FWD_0_INTO_STAND_0` | 248 | 16 | 62 | 1,715,136 | 5,840 | 0.1 s |
| `BR_SPRINT_FWD_25_INTO_MOUNT` | 387 | 17 | 49 | 2,740,464 | 7,472 | 0.1 s |
| `BR_SPRINT_FWD_25_INTO_STAND_0` | 249 | 18 | 54 | 1,720,976 | 4,928 | 0.1 s |
| `BR_SPRINT_FWD_50_INTO_MOUNT` | 388 | 19 | 55 | 2,747,936 | 7,632 | 0.1 s |
| `BR_SPRINT_FWD_50_INTO_STAND_0` | 250 | 20 | 62 | 1,725,904 | 5,808 | 0.1 s |
| `BR_SPRINT_FWD_75_INTO_MOUNT` | 389 | 21 | 57 | 2,755,568 | 8,160 | 0.1 s |
| `BR_SPRINT_FWD_75_INTO_STAND_0` | 251 | 22 | 54 | 1,731,712 | 5,120 | 0.1 s |
| `BR_SPRINT_FWD_CYC` | 187 | 23 | 31 | 1,086,016 | 4,608 | 0.2 s |
| `BR_STAND_0_CYC` | 197 | 24 | 781 | 1,138,608 | 51,120 | 0.2 s |
| `BR_STAND_0_INTO_MOUNT` | 390 | 25 | 52 | 2,763,728 | 7,984 | 0.1 s |
| `BR_STAND_0_INTO_RUN_FWD` | 256 | 26 | 32 | 1,764,144 | 4,752 | 0.1 s |
| `BR_STAND_0_INTO_SPRINT_FWD` | 257 | 27 | 37 | 1,768,896 | 5,760 | 0.1 s |
| `BR_STAND_0_INTO_WALK_FWD` | 258 | 28 | 52 | 1,774,656 | 5,744 | 0.1 s |
| `BR_STEP_INTO_MOUNT` | 391 | 29 | 99 | 2,771,712 | 12,240 | 0.1 s |
| `BR_WALK_FWD_0_INTO_MOUNT` | 392 | 30 | 43 | 2,783,952 | 6,848 | 0.1 s |
| `BR_WALK_FWD_0_INTO_STAND_0` | 271 | 31 | 67 | 1,859,504 | 5,968 | 0.1 s |
| `BR_WALK_FWD_25_INTO_MOUNT` | 393 | 32 | 37 | 2,790,800 | 6,256 | 0.1 s |
| `BR_WALK_FWD_25_INTO_STAND_0` | 274 | 33 | 60 | 1,877,584 | 6,048 | 0.1 s |
| `BR_WALK_FWD_50_INTO_MOUNT` | 394 | 34 | 39 | 2,797,056 | 6,192 | 0.1 s |
| `BR_WALK_FWD_50_INTO_STAND_0` | 277 | 35 | 67 | 1,894,512 | 6,064 | 0.1 s |
| `BR_WALK_FWD_75_INTO_MOUNT` | 395 | 36 | 47 | 2,803,248 | 6,752 | 0.1 s |
| `BR_WALK_FWD_75_INTO_STAND_0` | 280 | 37 | 60 | 1,912,240 | 5,824 | 0.1 s |
| `BR_WALK_FWD_CYC` | 208 | 38 | 57 | 1,434,176 | 6,400 | 0.2 s |

Every listed action is VBR, 60 Hz, eight parts. Authored duration is
`(frames - 1) / 60`.

## Observed graph behavior

- Stand and flat walk/run/sprint cycle `PlayAnimation` nodes blend for 0.2 s.
- Stand-to-walk, stand-to-run, and stand-to-sprint blend for 0.1 s.
- Walk/run/sprint-to-stand use `MatchCadence`, select a 0/25/50/75 physical
  leaf, and blend for 0.1 s.
- Walk/run/sprint mount uses `MatchCadence` and blends for 0.1 s.
- Stand mount blends for 0.1 s.
- Step mount sets `blendMatchFrame="true"` and blends for 0.1 s.
- Ground dismount-to-stand uses a 0.2 s blend. Dismount-to-run and fast-run use
  0.1 s.
- Dismount selectors feed `disttocog` from the previous animation with
  `SetBlend="true"`.
- Ground locomotion and mount attach `OB_BipedWorldX`, `OB_BipedWorldZ`,
  `OB_Steer`, and `OB_SteerMagnitude`. The stand exit test is strictly
  `OB_SteerMagnitude > 0.01`, sustained for more than 0.06 s.

## Turn-in-place and multidirectional locomotion

Observed: the TU3 graph's flat locomotion leaves are only
`BR_WALK_FWD_CYC`, `BR_RUN_FWD_CYC`, and `BR_SPRINT_FWD_CYC`. It does not
select left, right, or backward locomotion leaves for stick direction.

Derived contract: the animation adapter must retain the forward physical leaf
while passing the four trajectory attributes to the trajectory controller.
Backward, left, right, and diagonal requests therefore resolve to the same
physical leaf. Selecting a made-up directional animation would contradict the
graph.

Unresolved: the exact native trajectory-controller function that converts
these attributes into per-tick yaw, root translation, and physics coupling is
outside this adapter. `src/offboard.rs` currently contains a separately fitted
heading controller. This adapter neither validates nor upgrades that controller.

## Virtual-resource gate

The retail XML uses aliases which are expanded by behavior code rather than
physical ABIN names:

- `BR_DISMOUNT_INTO_STAND_0`
- `BR_DISMOUNT_INTO_RUN_FWD`
- `BR_DISMOUNT_FAST_INTO_RUN_FWD`
- `BR_{WALK,RUN,SPRINT}_FWD_INTO_STAND_0`
- `BR_{WALK,RUN,SPRINT}_FWD_INTO_MOUNT`

These nine aliases cannot reach Bevy through this adapter. Dismount aliases
require the unrecovered `disttocog` blend weights/thresholds. Cadence aliases
require the exact native cadence clock and quarter-boundary behavior. Supplying
the expected parameter produces a typed `MissingEvidence` error, not a guessed
leaf.

`src/offboard.rs` already emits expanded physical cadence names, so its 36-name
audit succeeds. Its direct selection of only the `*_HI_*` dismount endpoints is
not equivalent to the retail `disttocog` blend; the adapter marks those leaves
as `DismountHighEndpoint` instead of presenting them as a recovered selector.

## Bevy gate

`adapt_offboard_for_bevy` succeeds only after:

1. the name classifies as one of the 36 physical leaves;
2. local time and optional trajectory attributes are finite;
3. steer magnitude is non-negative; and
4. the leaf is marked present in the pinned manifest/GLB.

Unknown names, virtual aliases, invalid parameters, and future physical leaves
missing from the pinned GLB fail with typed errors. No `B_*`, selector alias, or
invented directional name can become a Bevy clip.
