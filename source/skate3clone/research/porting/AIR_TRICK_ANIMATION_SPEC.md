# TU3 air-trick animation resolution

Status: evidence-gated standalone adapter implemented. Live `SkateSim`
playback additionally resolves the recovered one-shot and four multi-flip
families documented in `FLICKIT_ONE_SHOT_TRICKS_SPEC.md` and
`FLICKIT_MULTI_FLIP_SPEC.md`.

## Scope and rule

`src/air_trick_graph.rs` emits 86 unique animation resource names: two direct
grind-out leaves, 56 ground/air virtual resources, 12 flip-cycle resources and
16 flip-out resources. `src/air_trick_animation.rs` classifies that complete
surface.

A similar ABIN name is not resolution evidence. The adapter returns a physical
leaf only when local artifacts establish both:

1. the exact TU3 ABIN record; and
2. the emitted virtual resource's relationship to that record at the requested
   endpoint.

Interior `TrickHeight` values are rejected until the retail blend curve and
weights are recovered. Physical leaves absent from the current GLB are rejected
at the Bevy boundary. There are no aliases, nearest-name matches, default clips
or low-height fallbacks.

## Pinned artifacts

| Artifact | SHA-256 |
|---|---|
| `research/animation/Skate3Extracted/data/anim/OnBoard.abin` | `30AA324D6D7C51C325D53E9268C1AD91783B0154D21BBEF5DC5A61EAE8333BD7` |
| `research/animation/reports/skate3_onboard_clips.csv` | `7B2041D3E8FC305D589A05B65B72B5181319197B4CF4FC6C410C8BDDAA131D10` |
| `research/reverse-engineering/VerifyCustomAnimation/data/state/MotionGraph_OnBoard.stategraph` | `484189731E7651539E532056662835C5492D11EC3BF56668E1B589E013AAA68D` |
| `src/air_trick_graph.rs` | `265A627AD152F8EE6AEF68CB491D109AAC8ED34FC3B44733DB08A6832BA9CBCE` |
| `T_Kickflip.xml` | `8C0F59FA05AF01A7DF829AC6056FDEBD1E15BF89C008B868CFF280E50DEA5063` |
| `T_Trick.xml` | `F0A46D02B1F5E404152AEDBD5A8A8E47A4BA37563AA5A81BD018B19B076AD8E6` |
| `T_TrickWithUnderflip.xml` | `4849908C082AF64569F2FDB9BE38332F1430231B92970C6C8368A09419CCA834` |
| `T_TrickWithDarkCatch.xml` | `2B3917F38B540627F921E9644F3DFA38131F6E02618FA486C2D7F2F09E39253A` |
| 360 Flip four-leaf replacement fixture | `F5C4BD956AB69BD77FE8ADA6E3EEFB7F0DC1733C175A0A79AF288E543A407BC3` |
| 360 Flip run `result.json` | `A02795128054B6638587B7F3AA8152B598B67A352FCEF9C370724D7F1ED71A78` |
| 360 Flip run `telemetry.jsonl` | `1AB0E3D0CCD8B0B5F91E2A11041D5FD75F5E8F8D9CDD96D0257589D7C0748660` |
| `assets/private/skater_push.manifest.txt` | `61219ECB31E1EE16D00C251210E04E2354D9BCC71376AADE90FC3F97C3B816A3` |
| `assets/private/skater_push.glb` | `2A3556A426EC88305B0E59DEDDA30320694F5C4E46A04E22980FC8CE4A38D8D7` |

The XML files are below
`research/reverse-engineering/VerifyCustomAnimation/data/state/MotionGraphIncludes/Tricks`.
The fixture and run are below `harness/experiments/fixtures` and
`harness/runs/20260803T033231818Z-research-single-360flip-leaf-replacement-cbe11fcd`.

## Evidence classes

- **Observed/catalog**: exact row decoded from the pinned TU3 ABIN catalog.
- **Observed/runtime**: live instrumentation recorded a resource lookup,
  replacement bind or stream evaluation.
- **Derived**: direct consequence of observed records, such as
  `(frame_count - 1) / 60` authored duration.
- **Graph-authored**: literal behavior in the pinned XML/compiled graph.
- **Unresolved**: a plausible association exists but selected-leaf or blend
  evidence is absent.

## Resolvable physical leaves

All records are VBR, 60 Hz and eight-part. Duration is the interval from first
to final authored sample, not `frame_count / fps`.

| Emitted resource / endpoint | Physical leaf | Index | Frames | Duration | Offset | Size | Evidence |
|---|---|---:|---:|---:|---:|---:|---|
| `GRIND_OUT_NOSE` | `GRIND_OUT_NOSE` | 2168 | 13 | 0.200000 s | 8,921,840 | 2,896 | catalog + direct graph name |
| `GRIND_OUT_TAIL` | `GRIND_OUT_TAIL` | 2169 | 11 | 0.166667 s | 8,924,736 | 2,864 | catalog + direct graph name |
| `B_KICKFLIP_IN_G`, low only | `KICKFLIP_IN_LOW_G` | 2400 | 13 | 0.200000 s | 9,790,640 | 3,104 | catalog + runtime copied/evaluated ground stream |
| `B_KICKFLIP_IN_A`, low only | `KICKFLIP_IN_LOW_A` | 2401 | 11 | 0.166667 s | 9,793,744 | 3,312 | catalog + runtime copied/evaluated air stream |
| `B_360FLIP_G`, low | `360FLIP_D_LOW_G` | 2448 | 13 | 0.200000 s | 9,961,744 | 3,088 | catalog + runtime four-leaf bind/evaluation |
| `B_360FLIP_A`, low | `360FLIP_D_LOW_A` | 2449 | 28 | 0.450000 s | 9,964,832 | 4,288 | catalog + runtime four-leaf bind/evaluation |
| `B_360FLIP_G`, high | `360FLIP_D_HIGH_G` | 2450 | 13 | 0.200000 s | 9,969,120 | 3,088 | catalog + runtime four-leaf bind/evaluation |
| `B_360FLIP_A`, high | `360FLIP_D_HIGH_A` | 2451 | 33 | 0.533333 s | 9,972,208 | 4,448 | catalog + runtime four-leaf bind/evaluation |

The 360 Flip run's overall result is `error` because
`actor_lifecycle:ground>air>ground` did not satisfy its harness expectation.
That verdict is not treated as a passing gameplay test. Separately, its
animation telemetry recorded:

- `AT` lookups for `B_360FLIP_G` and `B_360FLIP_A`;
- four successful source/target bindings;
- `animation_leaf_replacement_eval_count` reaching four;
- low and high ground evaluations at frames 1425 and 2267;
- low and high air evaluations at frames 1457 and 2295.

That is evidence for the four children and their ground/air membership. It is
not evidence for the interior blend weights.

## Authored transition and blend contract

The adapter transports these values from `AnimationRequest` unchanged and
validates finite, non-negative explicit times.

| Graph entry/segment | Transition | Time | `transitionUnder` |
|---|---|---:|---|
| grind-out takeoff | channel blend | 0.75 s | false |
| ground from anticipation/manual | play | 0.05 s | false |
| ground from drop-in | blend | 0.05 s | false |
| ground from grind | channel blend | 0.85 s | false |
| air after grind-out assist | play | 0.10 s | true |
| normal air | sequence | implicit | true |
| flip cycles 1-3 | sequence | implicit | true |
| flip outs 1-2 | sequence | implicit | true |
| flip outs 3-4 | sequence | implicit | false |

Graph-authored `TrickHeight` facts:

- anticipation/manual derives `TrickHeight` from `AnticStrength`;
- drop-in fixes it to `0.6`;
- grind fixes it to `0.5`;
- grind-out assist fixes it to `1.0`;
- air, cycle and out `PlayAnimation` behaviors use
  `SetBlend=true`, `from=lastAnim`, `attribute=TrickHeight`.

The available artifacts do **not** prove:

- normalization or clamping of `AnticStrength`;
- low/high knot positions;
- interpolation curve;
- per-child weights for `0.5`, `0.6` or any other interior value;
- whether time remapping differs between unequal-duration low/high leaves.

Consequently, only `TrickHeight::LowEndpoint` and
`TrickHeight::HighEndpoint` can resolve where both endpoint children are
proven. `ContinuousUnresolved(f32)` always returns
`ContinuousBlendCurveAndWeights`; a non-finite value returns
`InvalidContinuousTrickHeight`.

## Complete resource coverage

`AIR_TRICK_GRAPH_RESOURCES` is the canonical exact list and has a uniqueness
and classification test. Coverage by class:

| Class | Count | Current result |
|---|---:|---|
| direct grind-out | 2 | physical ABIN resolution |
| tail Kickflip ground/air | 2 | low endpoint resolves; high/interior fail |
| tail 360 Flip ground/air | 2 | low/high resolve; interior fails |
| other ground/air trees | 52 | typed unresolved failure |
| flip cycles | 12 | typed unresolved failure |
| flip outs | 16 | typed unresolved failure |

Within the 52 unresolved ground/air resources,
`B_FSPOPSHUVIT_G/A`, `B_VARIALHEELFLIP_G/A` and their currently relevant
ambiguous authored families are classified as `AuthoredVariantSelector`; the
catalog contains competing D/CARR or D/DILL families. Similarity does not choose
one. Other trees return `PhysicalLeafTopology`.

### Catalog-only candidate families

The pinned CSV proves the following physical records exist, but does not by
itself prove that the similarly named virtual resource selects them. They are
therefore documentation, not adapter mappings.

| Physical family | Indices | Frame counts (`LOW_G, LOW_A, HIGH_G, HIGH_A`) |
|---|---:|---|
| `HEELFLIP_IN` | 2404-2407 | 13, 12, 13, 12 |
| `POPSHUVIT` | 2408-2411 | 13, 24, 13, 24 |
| `FSPOPSHUVIT_D` | 2412-2415 | 13, 24, 13, 24 |
| competing `FSPOPSHUVIT_CARR` | 2416-2419 | catalog present; selector unresolved |
| `VARIALKICKFLIP` | 2420-2423 | 13, 30, 13, 30 |
| `VARIALHEELFLIP_D` | 2424-2427 | 13, 25, 13, 25 |
| competing `VARIALHEELFLIP_DILL` | 2428-2431 | catalog present; selector unresolved |
| `INWARDHEELFLIP` | 2432-2435 | 12, 29, 12, 31 |
| `HARDFLIP` | 2436-2439 | 13, 27, 13, 33 |
| `360POPSHUVIT` | 2440-2443 | 13, 29, 13, 31 |
| `FS360POPSHUVIT` | 2444-2447 | 13, 30, 13, 30 |
| competing `360FLIP_GONZ` / `360FLIP_HSU` | 2452-2459 | catalog present; D selection is runtime-proven only for the ordinary tail tree |
| `LASERFLIP` | 2460-2463 | 13, 28, 13, 28 |
| `360INWARDHEELFLIP` | 2464-2467 | 13, 30, 13, 38 |
| `360HARDFLIP` | 2468-2471 | 13, 31, 13, 33 |
| `N_HEELFLIP_IN` | 2476-2479 | 13, 14, 13, 14 |
| `N_KICKFLIP_IN` | 2480-2483 | 13, 17, 13, 17 |
| `N_POPSHUVIT` | 2484-2487 | 13, 23, 13, 23 |
| `N_FSPOPSHUVIT` | 2488-2491 | 13, 24, 13, 24 |
| `N_VARIALKICKFLIP` | 2492-2495 | 13, 29, 13, 32 |
| `N_VARIALHEELFLIP` | 2496-2499 | 13, 29, 13, 29 |
| `N_INWARDHEELFLIP` | 2500-2503 | 13, 28, 13, 28 |
| `N_HARDFLIP` | 2504-2507 | 13, 26, 13, 32 |
| `N_360POPSHUVIT` | 2508-2511 | 13, 28, 13, 31 |
| `N_FS360POPSHUVIT` | 2512-2515 | 13, 28, 13, 33 |
| `N_360FLIP` | 2516-2519 | 13, 29, 13, 29 |
| `N_LASERFLIP` | 2520-2523 | 13, 28, 13, 32 |
| `N_360INWARDHEELFLIP` | 2524-2527 | 13, 31, 13, 33 |
| `N_360HARDFLIP` | 2528-2531 | 13, 28, 13, 33 |

Cycle/out candidates also exist in four low/high groups:

| Group | High indices | Low indices | Cycle frame counts high / low | Out frame counts high / low |
|---|---:|---:|---|---|
| tail Heel | 2204-2210 | 2219-2225 | CYC 13,28,29 / 13,28,29 | OUT1-4 16,28,28,29 / 13,28,28,29 |
| tail Kick | 2234-2240 | 2249-2255 | CYC 12,29,27 / 13,27,27 | OUT1-4 12,27,28,27 / 17,27,27,31 |
| nose Heel | 2310-2316 | 2325-2331 | CYC 11,22,24 / 11,22,24 | OUT1-4 13,29,30,23 / 13,29,30,23 |
| nose Kick | 2342-2348 | 2357-2363 | CYC 13,25,27 / 13,25,27 | OUT1-4 13,25,25,30 / 17,25,26,30 |

Adjacent dark-catch and underflip records are not normal cycle/out mappings.
No current selected-leaf capture establishes the virtual cycle/out topology,
so every one remains `FlipLoopLeafTopology`.

That statement describes the conservative standalone adapter. The live
multi-flip route now uses the exact catalog groups as a **derived** physical
mapping: their tail/nose, kick/heel, low/high, and CYC/OUT names and contiguous
ordering uniquely match the four graph families. Existing normal OUT1 runtime
traces corroborate the ordinary low/high selection and transition-under seam.
The remaining cycle/out mapping confidence is derived rather than newly
runtime-observed because harness use was not authorized for this pass. See
`FLICKIT_MULTI_FLIP_SPEC.md`.

## Bevy boundary

The pinned 251-action manifest contains all eight currently resolvable physical
leaves. `adapt_air_trick_for_bevy` therefore accepts the direct grind-out
leaves, the observed low Kickflip ground/air endpoint, and all four observed
360 Flip ground/air endpoints. Unresolved virtual resources and continuous
height values remain typed failures.

## Focused tests

The module includes tests for:

- all 86 emitted names being unique and classified;
- exact catalog order, metadata and authored-duration calculation;
- direct grind-out resolution and transition preservation;
- all four 360 Flip endpoint resolutions;
- continuous-height rejection;
- low-only Kickflip gating;
- unresolved resources never becoming physical samples;
- current GLB availability acceptance for all eight proven leaves;
- timing validation before resource resolution.

The module intentionally is not wired into `main.rs` by this worker because
that file is outside the assigned ownership boundary. The orchestrator must add
`mod air_trick_animation;` (or equivalent library integration) for Cargo to
discover these focused tests.

## Required next evidence

1. Capture selected physical children and weights for every emitted virtual
   resource at explicit low, high and at least two interior `TrickHeight`
   values.
2. Disambiguate D/CARR, D/DILL and other authored variant selectors.
3. Capture cycle/out low/high children and verify time synchronization between
   unequal-duration endpoints.
4. Recover or observe clamping and interpolation for `SetBlend`.
5. Export only proven physical leaves into the Bevy GLB, regenerate the
   manifest and update its pinned hash.
