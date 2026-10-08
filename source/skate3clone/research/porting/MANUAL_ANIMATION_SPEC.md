# Skate 3 TU3 manual animation adapter

> Historical evidence checkpoint. Its virtual-selector blockers were resolved
> on 2026-09-01 by decoding OnBoard ABIN type-7/type-8 blocks and the native
> `DataBase::GetAnimTree` paths. The current proven topology, offsets, blend
> behavior, physical leaves, and implementation status are in
> `MANUAL_IMPLEMENTATION_EVIDENCE.md`. Revert selectors remain unresolved.

## Scope

This pass inventories every animation resource emitted by
`src/manual_graph.rs`, separates exact OnBoard ABIN leaves from virtual
MotionGraph resources, records the graph transition and parameter context, and
implements a hard Bevy boundary in `src/manual_animation.rs`.

It does not map a virtual resource to a name-similar ABIN leaf. Static XML and
the ABIN catalog do not expose the runtime selector definition, weights, or
character/style overrides needed to prove such a mapping.

## Pinned evidence

| Artifact | SHA-256 |
|---|---|
| `Skate3Extracted/data/anim/OnBoard.abin` | `30AA324D6D7C51C325D53E9268C1AD91783B0154D21BBEF5DC5A61EAE8333BD7` |
| `research/animation/reports/skate3_onboard_clips.csv` | `7B2041D3E8FC305D589A05B65B72B5181319197B4CF4FC6C410C8BDDAA131D10` |
| `MotionGraphIncludes/Manual/TailManual.xml` | `39BFAAD4FA388C1898FE1CCB0E284084EA58FED427D38C21923D69A6A24001A8` |
| `MotionGraphIncludes/Manual/NoseManual.xml` | `6CAD7008AC169B7B1A93F29EF822B09D9CD25D48F0DB68312410BE0100DE6EA3` |
| `MotionGraphIncludes/Manual/t_manual_revert.xml` | `D4FDE35A59964B4A7B04486B344484B18B962A5A8E3BF1280B7663F372D3677F` |
| `src/manual_graph.rs` at analysis time | `87B88A24503E1D22B00F9B8FFC6B618E4C49735D7A0E52ABE97FBB823D610112` |
| `assets/private/skater_push.manifest.txt` | `B5578A493A9432685A98179085655D787E3D82B48E8A649BC41998C672FDE56F` |
| `assets/private/skater_push.glb` | `50FD4FF6300A7EA49B135E6B1AD110EB9101CC4472B87471C87358FB90B14EE3` |
| `src/manual_animation.rs` | `3B2F2E559D2D17CF981CB5E78A853469D3F74DC7A7AC256752E6A3DFDC4A16E8` |

The XML paths are rooted at
`C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\VerifyCustomAnimation\data\state`.
The authoritative ABIN and catalog are rooted at
`C:\Users\Daddy\Documents\Skate3Research\research\animation`.

## Resource coverage

`ManualRuntime::animation_request` emits 13 unique names:

- two are exact physical leaves in the authoritative OnBoard catalog;
- eleven are absent as exact ABIN names and are classified as virtual
  resources;
- all 13 are classified by `MANUAL_GRAPH_RESOURCES`;
- neither physical leaf is present among the pinned GLB's 243 actions.

The graph timing below is the `PlayAnimation time` transported by
`manual_graph`; it is a transition duration, not clip duration.

| Graph resource | Class | Graph transition | Repeats | Observed owning-state context | Adapter result |
|---|---|---:|---:|---|---|
| `B_NOSE_MANUAL_INTO` | virtual | 0.1 s | no | `spin`; XML playback speed 1.0 | blocked: selected leaf/weights/duration missing |
| `B_TAIL_MANUAL` | virtual | 0.3 s | yes | negative `balance`, `spin`, published `manual_angle` | blocked: selected leaf/weights/duration missing |
| `B_TAIL_MANUAL_LOW` | virtual | 0.3 s | yes | negative `balance`, `spin` | blocked: selected leaf/weights/duration missing |
| `B_NOSE_MANUAL` | virtual | 0.3 s | yes | positive `balance`, `spin`, published `manual_angle` | blocked: selected leaf/weights/duration missing |
| `B_NOSE_MANUAL_LOW` | virtual | 0.3 s | yes | positive `balance`, `spin` | blocked: selected leaf/weights/duration missing |
| `M_BRAKE_N_0_CYC` | exact physical | 0.2 s | yes | `balance=-1`, active `manualbrake`, `spin` | resolves to exact ABIN leaf; blocked at Bevy manifest |
| `S_M_NOSEBRAKE_N_0_CYC` | virtual alias/selector | 0.2 s | yes | `balance=+1`, active `manualbrake`, `spin` | blocked: alias target/timing missing |
| `M_NOSEBRAKE_STAT_0_CYC` | exact physical | 0.5 s | yes | `balance=+1`, active `manualbrake` | resolves to exact ABIN leaf; blocked at Bevy manifest |
| `B_NOSE_MANUAL_OUT` | virtual | 0.1 s | no | no new animation attribute attached in `Out` | blocked: selected leaf/weights/duration missing |
| `B_TAIL_MANUAL_FS_REVERT` | virtual | 0.2 s | no | negative `balance`, `RevertDir=-1` | blocked: leaf/mirror/weights/duration missing |
| `B_TAIL_MANUAL_BS_REVERT` | virtual | 0.2 s | no | negative `balance`, `RevertDir=+1` | blocked: leaf/mirror/weights/duration missing |
| `B_NOSE_MANUAL_FS_REVERT` | virtual | 0.2 s | no | positive `balance`, `RevertDir=-1` | blocked: leaf/mirror/weights/duration missing |
| `B_NOSE_MANUAL_BS_REVERT` | virtual | 0.2 s | no | positive `balance`, `RevertDir=+1` | blocked: leaf/mirror/weights/duration missing |

The adapter calls these values a capture-context contract. The XML proves they
are attached or published in the owning state; it does not prove that each is
internally consumed by the unresolved selector.

## Exact physical leaves

Observed directly in the catalog:

| Name | Index | FPS | Samples | Authored duration | Parts | Offset | Size |
|---|---:|---:|---:|---:|---:|---:|---:|
| `M_NOSEBRAKE_STAT_0_CYC` | 1370 | 30 | 60 | 59/30 s | 8 | 5,290,672 | 3,696 |
| `M_BRAKE_N_0_CYC` | 1400 | 30 | 45 | 44/30 s | 8 | 5,461,552 | 4,496 |

Authored duration is derived as `(sample_count - 1) / sample_rate`. This keeps
clip duration separate from the graph's 0.2/0.5-second transition.

## Relevant physical inventory that is not a proven mapping

The ABIN contains additional manual-named leaves. Their presence is observed,
but no virtual selector mapping is inferred:

| Name | Index | FPS | Samples | Offset | Size | Why it remains unresolved |
|---|---:|---:|---:|---:|---:|---|
| `FAKIE_MANUAL_CHANNEL_CYC` | 1278 | 30 | 50 | 4,783,696 | 3,616 | no selector definition or selected-leaf capture |
| `M_NOSEBRAKE_N_0_CYC` | 1369 | 30 | 45 | 5,286,272 | 4,400 | name-similar to `S_M_NOSEBRAKE_N_0_CYC`, but alias target is unobserved |
| `PRO_DILL_MANUAL_IDLE_N_0_CYC` | 1395 | 30 | 88 | 5,409,600 | 9,008 | possible character/style override; no mapping |
| `PRO_DILL_MANUAL_NOSEIDLE_N_0_CYC` | 1396 | 30 | 143 | 5,418,608 | 14,784 | possible character/style override; no mapping |
| `PRO_HSU_MANUAL_NOSEIDLE_N_0_CYC` | 1397 | 30 | 116 | 5,433,392 | 12,192 | possible character/style override; no mapping |
| `PRO_MCARROLL_NOSEBRAKE_CYC` | 1398 | 30 | 119 | 5,445,584 | 10,368 | possible character/style override; no mapping |
| `M_BRAKE_STAT_0_CYC` | 1401 | 30 | 45 | 5,466,048 | 3,216 | directly named by retail TailManual XML, but not emitted by current `manual_graph.rs` |

## Current graph discrepancy found during coverage audit

Observed in retail XML:

- tail brake chooses `M_BRAKE_N_0_CYC` only when absolute board-local Z speed
  is greater than 0.1 and otherwise chooses `M_BRAKE_STAT_0_CYC`;
- nose brake chooses `S_M_NOSEBRAKE_N_0_CYC` at the same absolute-speed
  boundary and otherwise chooses `M_NOSEBRAKE_STAT_0_CYC`.

Observed in the analyzed `src/manual_graph.rs`:

- both tail speed bands emit `M_BRAKE_N_0_CYC`, so the stationary tail leaf is
  unreachable;
- nose brake reuses the cycle speed band (`>0.5` forward versus otherwise)
  instead of the retail absolute-speed `>0.1` brake split.

This worker did not modify `manual_graph.rs` because it is outside the assigned
ownership. The adapter covers exactly what that module currently emits and
does not hide this upstream discrepancy with a guessed remap.

## Adapter behavior

- `classify_manual_resource` covers all 13 current graph resources.
- `resolve_manual_request` resolves only exact physical ABIN names.
- A direct physical resolution has one leaf at weight 1.0.
- Local time, transition time, playback speed, repeat state, and
  `applyPosture` are transported without introducing another clock.
- Negative/non-finite time, non-positive playback speed, missing context, and
  non-finite context values return typed failures.
- Tail/nose balance signs and the exact `RevertDir` values observed in XML are
  validated.
- All virtual resources return a typed missing-evidence result after context
  validation.
- `adapt_manual_for_bevy` additionally requires the exact physical action in
  the pinned GLB manifest.
- `BevyManualAnimation` has no raw-resource constructor, so `B_*` and
  `S_*` resources cannot leak to the animation player.

## Required synchronized telemetry

For each of the eleven virtual resources, capture on the same simulation tick:

1. graph resource name and full MotionGraph state path;
2. final selected physical leaf name and ABIN/catalog identity;
3. every selected leaf weight, normalized/local time, playback speed, repeat
   flag, authored duration, graph transition duration, and posture flag;
4. `balance`, `spin`, `manual_angle`, `manualbrake`, and `RevertDir`;
5. raw/conditioned manual intent, board-local Z speed, manual kind, regular or
   goofy stance, fakie state, current skater/style, and mirror decision;
6. selector enter, cycle, exit, interruption, and `WillExpire` timestamps.

Discriminating captures are required for:

- tail and nose neutral, low-speed, forward, and backward boundaries around
  `-0.5`, `+0.5`, and absolute speed `0.1`;
- several manual balance and turn values, including limits;
- FS and BS reverts in both stances, with mirror state recorded;
- default skater plus every known pro animation override;
- nose into/out interrupted before and at the 0.05/0.1 expiry boundaries.

The telemetry must expose selected leaves after all style, stance, and mirror
resolution. Logging only the virtual graph name cannot establish a Bevy
binding.

## Validation

- Standalone module tests: 11 passed with Rust warnings denied.
- Tests cover complete resource classification, exact catalog metadata,
  authored-duration calculation, context contracts, side/revert invariants,
  virtual typed failures, invalid timing, unknown resources, and GLB manifest
  blocking.
- No game or visual session was launched.
