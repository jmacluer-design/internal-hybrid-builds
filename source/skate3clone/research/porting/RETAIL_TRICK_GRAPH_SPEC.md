# Skate 3 TU3 trick graph recovery

This file records recovered behavior separately from Bevy implementation
choices. Visual resemblance is not evidence.

## Build identity and primary evidence

- `MotionGraph_OnBoard.xml`
  - Path: `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\VerifyCustomAnimation\data\state\MotionGraph_OnBoard.xml`
  - SHA-256: `3D22018FBA263212A52681453D5AC3A19982B7DF66A188DB3E555B915223C8FA`
- `ActionGraph_OnBoard.xml`
  - Path: `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\VerifyCustomAnimation\data\state\ActionGraph_OnBoard.xml`
  - SHA-256: `B8CA3C220833D8DCD8E0F397F967ACA9E776D7687C1DA95BB3A22FCF40FC1B24`
- `OnBoard.abin`
  - Path: `C:\Users\Daddy\Documents\Skate3Research\research\animation\Skate3Extracted\data\anim\OnBoard.abin`
  - SHA-256: `30AA324D6D7C51C325D53E9268C1AD91783B0154D21BBEF5DC5A61EAE8333BD7`
  - 2,672 clips and 87 poses.
- Static gesture table:
  - `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\symbols\gesture-trick-mapping-records.json`
  - 270 recovered records, already cross-checked against runtime events.

The independent `VerifyCustomAnimation` and `MiscloadState` graph copies are
identical.

## Observed parent path

```text
ActionGraph OnGround.Antic
  -> anticipation intent and Compression
ActionGraph Trick
  -> gesture mapping resolves Tail / Nose / Square group
MotionGraph Anticipation
  -> AnticInto -> AnticCyc
MotionGraph Trick
  -> TailTrick | NoseTrick
  -> Takeoff -> LeftGround -> InAir
MotionGraph Air
  -> InAirStatic | GrabsTweaks | BoardAdjusts | Lateflip
  -> Land | Grind | WipeOut
MotionGraph Land
  -> Riding idle
```

The parent trick gate requires ground or grind physics state, `Trick`,
`AllowedToTrick`, `OkToDoTrickOnStairs`, not dark, and not grabbing an
object.

## Observed anticipation classification and timing

ActionGraph enters anticipation when `AnticMag > 0.9`.

| AnticAngle sector | Tail/nose anticipation |
|---|---|
| absolute angle `<= 0.52` | ollie |
| `-1.05 .. -0.52` | pop shuvit |
| `0.52 .. 1.05` | FS pop shuvit |
| tail outer sectors to `+/-1.57` | 360 shuvit families |
| absolute angle `>= 2.62` | nollie |
| sectors between `+/-1.57` and `+/-2.62` | nose shuvit families |

Relevant files:

- `ActionGraphIncludes\onground.xml`
- `MotionGraphIncludes\Anticipations\AnticInto.xml`
- `MotionGraphIncludes\Anticipations\AnticCyc.xml`
- `MotionGraphIncludes\Anticipations\AnticOut.xml`

Physical anticipation clips:

- Tail: `B_ANTIC_INTO`, `B_ANTIC_CYC`,
  `B_ANTIC_360SHUVIT_CYC`, `B_ANTIC_FS360SHUVIT_CYC`,
  `B_ANTIC_OUT`.
- Nose: `B_N_ANTIC_INTO`, `B_N_ANTIC_CYC`,
  `B_ANTIC_N360SHUVIT_CYC`, `B_ANTIC_NFS360SHUVIT_CYC`,
  `B_N_ANTIC_OUT`.

Timing:

- Into blend `0.2 s`, playback `1.2`, expiry window `0.07 s`.
- Cycle blend `0.3 s`.
- Compression filter ramp `0.2 s`, rise `0.166 s`, fall `0.05 s`.
- Cancel/out blend `0.15 s`.

## Observed core trick sequencing

Core tricks use a ground/takeoff `_G` leaf followed by an airborne `_A` leaf.
The transition checks `WillExpire 0.05`; the `_A` animation is played as a
sequence and receives `TrickHeight` from the outgoing animation.

First vertical-slice leaves:

| Family | Low | High |
|---|---|---|
| Ollie takeoff | `OLLIE_LOW_G`, 13f @ 60 Hz | `OLLIE_HIGH_G`, 13f @ 60 Hz |
| Ollie air | `OLLIE_LOW_A`, 29f @ 60 Hz | `OLLIE_HIGH_A`, 19f @ 60 Hz |
| Nollie takeoff | `NOLLIE_LOW_G`, 13f @ 60 Hz | `NOLLIE_HIGH_G`, 13f @ 60 Hz |
| Nollie air | `NOLLIE_LOW_A`, 29f @ 60 Hz | `NOLLIE_HIGH_A`, 24f @ 60 Hz |

Other catalog families are data variants of the same graph template:
kickflip, heelflip, pop shuvit, FS pop shuvit, varial flip/heel,
hardflip/inward heel, 360 shuvits, 360 flip/laser flip, and nose equivalents.

Kickflip/heelflip additionally use `CYC1..3` and `OUT1..4`, each with a
`0.05 s` expiry window. Hold intents delay out selection. `TimeToLand`,
`cantranstounderflip`, and `underflipwindowend` select branches.

## Observed air, landing, and board authority

- Air baseline: `B_AIR_CYC`, default blend `0.2 s`.
- Straight landing virtual tree: `BLEND_LAND`, blend `0.15 s`.
- Nice/spin landing: `B_LAND_NICE`, blend `0.15 s`.
- Sketchy landing: `B_LAND_SKETCH`, blend `0.15 s`.
- Tricks remain disabled for `0.3 s` after landing.

Board transform ownership:

| State | Retail directive |
|---|---|
| ground riding | `FORCE_PHYSICS_SKATEBOARD` |
| takeoff after wheel lift | `FOLLOW_ANIMATION_DATA` |
| established air | `FORCE_ANIM_SKATEBOARD` |
| landing | `FORCE_PHYSICS_SKATEBOARD` |

Binary post-animation stages:

- `0x82BD9028` `Skeleton::UpdateLandingAdjust`
- `0x82BDCC28` `Skeleton::UpdateLandingOnSkateboardAdjust`
- `0x82BDD630` `Skeleton::UpdateSkateboardOffsetTransform`

### Odd-shove catch orientation

`tools/analyze_trick_catch_endpoints.py` measures the physical `_A` leaves in
the authorized 369-action export against `IA_IDLE_N_N_0_CYC`.

- Proven from extracted matrices: Pop Shuvit, FS Pop Shuvit, varial
  kickflip/heelflip, hardflip and inward heelflip (tail and nose families) end
  approximately 180 degrees from the air baseline around the deck-normal axis.
  The recovered relation is `baseline.rotation_difference(endpoint)`: it is a
  `SKATEBOARD_ROOT`-local post-rotation. Treating it as an armature-space
  pre-rotation turns the deck upside down.
- Proven from extracted matrices: the corresponding 360-shove families return
  near the baseline orientation; `360FLIP_D_LOW_A` and
  `360FLIP_D_HIGH_A` are within 6.67 and 5.68 degrees respectively.
- Derived integration rule: an odd-shove completion changes persistent
  nose/tail parity. The post-animation skateboard offset finishes the remaining
  `WillExpire` tail over 0.05 s, then holds that parity while the character
  performs air.xml's 0.2 s sequence-to-air blend.
- Proven hierarchy requirement: the reparented onboard toe targets are direct
  `SKATEBOARD_ROOT` children. The board-only offset therefore applies the
  inverse transform to those targets before SkeletonIK, preserving the authored
  foot targets instead of rotating the rider through the deck.
- Proven from extracted endpoint matrices: odd-shove catch targets are not
  identical to the air baseline. Across the audited low/high tail and nose
  leaves, target translation differences range from 20.95 mm to 124.46 mm,
  while endpoint toe-to-target errors remain at or below 20.74 mm.
- Derived integration rule: capture each reparented target in rig space at the
  catch boundary and blend that matrix directly to the physical air baseline
  over the same 0.2 s sequence-to-air interval. Interpolating the
  target as a child of Bevy's already blended board and merely counter-rotating
  it preserves the nested blend's curved path, which makes SkeletonIK visibly
  readjust both legs at catch.
- The exact raw glTF/Bevy-local 60 Hz track for the board and both targets
  through the complete 0.2 s catch blend is pinned in
  `AIR_BASELINE_BOARD_POSE.json`. It is extracted directly by
  `tools/extract_glb_action_pose.py --through 0.2`, avoiding Blender's
  coordinate-system conversion. The right and left target translations move
  another 10.26 mm and 8.83 mm respectively during that interval; freezing
  frame 1 and releasing to the live air cycle therefore creates a catch seam.
  Riding HCOM target positions differ from this air baseline by 50.21-80.75 mm,
  so they are not substituted for the proven air target.

The exact scalar/interpolation internals of native
`Skeleton::UpdateSkateboardOffsetTransform` remain unresolved; this port does
not claim that its interpolation curve is bit-identical.

## Unresolved measurements

These must remain telemetry questions rather than implementation guesses:

- exact low/high `TrickHeight` interpolation;
- timestamps of embedded attributes such as `CanBranch`,
  `sequencetoair`, and `absorbLand`;
- world-root versus relative-board transform under
  `FOLLOW_ANIMATION_DATA`;
- physics thresholds for straight/nice/sketchy/runout/wipeout landing;
- pro-skater-specific leaf selection.

## Port order

1. Extract anticipation, ollie/nollie low/high, air baseline, and physical
   straight-landing leaves.
2. Implement anticipation input and clip sequencing.
3. Implement ollie `_G -> _A -> air -> land -> riding`.
4. Add nollie through the same data-driven path.
5. Add flip/shuvit catalog entries, then multi-flip hold/out behavior.
6. Add grabs/tweaks, manuals, landing classification, then wipeout.

