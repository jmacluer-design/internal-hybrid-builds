# Flickit anticipation and 360 Flip implementation boundary

This note records the evidence used by the Bevy implementation. It separates
retail facts from implementation derivations and leaves unsupported animation
or interpolation behavior explicit.

## Evidence classes

- **Proven**: named directly by retail XML/pattern data, decoded from an
  authorized ABIN, or reproduced by the deterministic asset exporter.
- **Derived**: a direct mathematical consequence of proven values.
- **Inferred**: the narrowest runtime choice compatible with the evidence, but
  not independently observed at the relevant native boundary.
- **Unresolved**: no implementation claim is made.
- **Awaiting visual verification**: mechanically tested, but the user must
  judge the rendered motion.

## Anticipation admission

`onground.xml` and `T_Antic_PopShuv.xml` prove the strict radial gate
`AnticMag > 0.9` and these inclusive `AnticAngle` sectors. Angle zero is raw
right-stick down after the recovered radial normalization:

| Angle (radians) | Regular identity | Pop end |
| --- | --- | --- |
| `abs(angle) <= 0.52` | Ollie | tail |
| `-1.05 <= angle <= -0.52` | PopShuvit | tail |
| `0.52 <= angle <= 1.05` | FsPopShuvit | tail |
| `-1.57 <= angle <= -1.05` | ThreeSixtyPopShuvit | tail |
| `1.05 <= angle <= 1.57` | FsThreeSixtyPopShuvit | tail |
| `-2.09 <= angle <= -1.57` | NollieThreeSixtyPopShuvit | nose |
| `1.57 <= angle <= 2.09` | NollieFsThreeSixtyPopShuvit | nose |
| `-2.62 <= angle <= -2.09` | NolliePopShuvit | nose |
| `2.09 <= angle <= 2.62` | NollieFsPopShuvit | nose |
| `abs(angle) >= 2.62` | Nollie | nose |

Regular/switch mirroring swaps backside/frontside identities while retaining
the tail/nose pop end. Ollie and Nollie remain unchanged. Shared boundaries
satisfy two XML states because both comparisons are inclusive. The pure input
classifier reports those values as ambiguous; runtime declaration-order
selection is an **inferred** fallback for an exact floating-point boundary.

## Anticipation motion graph

The phase order and transition values are **proven**:

1. Generic tail `B_ANTIC_INTO` or nose `B_N_ANTIC_INTO`.
2. Held cycle, blended from Into over `0.3 s`.
3. Generic tail `B_ANTIC_OUT` or nose `B_N_ANTIC_OUT`.

`AnticCyc.xml` also authors `time="0.3" transitionUnder="true"` on every
individual held-cycle child. Consequently, changing between Ollie and either
shuv windup family does not replace the pose in one update: the evaluated
outgoing cycle continues beneath a `0.3 s` crossfade while the newly selected
cycle starts at local time zero. Re-targeting during that interval uses the
currently evaluated blend as `lastAnim`, so repeated sector changes remain
continuous. Pop and 360-pop identities that share the same authored cycle
resource do not restart it. These transition rules and durations are
**graph-authored**; advancing the outgoing repeating cycle clock under the
blend is **derived** from `transitionUnder`.

The held cycle resource is selected by sector:

| Identity group | Virtual cycle | Exported physical families |
| --- | --- | --- |
| Ollie | `B_ANTIC_CYC` | `R_[HIGH]ANTIC_OLLIE_{L,N,R}_0_CYC` |
| Nollie | `B_N_ANTIC_CYC` | `R_[HIGH]ANTIC_NOLLIE_{L,N,R}_0_CYC` |
| Tail BS pop/360 | `B_ANTIC_360SHUVIT_CYC` | `R_[HIGH]ANTIC_360SHUVIT_{L,N,R}_0_CYC` |
| Tail FS pop/360 | `B_ANTIC_FS360SHUVIT_CYC` | `R_[HIGH]ANTIC_FS360SHUVIT_{L,N,R}_0_CYC` |
| Nose BS pop/360 | `B_ANTIC_N360SHUVIT_CYC` | `R_[HIGH]ANTIC_N360SHUVIT_{L,N,R}_0_CYC` |
| Nose FS pop/360 | `B_ANTIC_NFS360SHUVIT_CYC` | `R_[HIGH]ANTIC_NFS360SHUVIT_{L,N,R}_0_CYC` |

These are distinct decoded physical actions with distinct authored body,
board-parented foot-target, and foot-bone transforms. Therefore side
anticipation now changes the actual windup/foot pose; it is not the vertical
ollie crouch reused under a broader input gate.

The L/N/R leaves and linear endpoint weights are **proven**. The upstream
projection that publishes retail `AnticDirection` is **unresolved**, so the
live path requests the neutral endpoint rather than deriving it from an
unrelated stick axis. Exact per-foot displacement by sector was not separately
quantified in this pass and remains **awaiting visual verification**.

Repeatable angle fixtures:

- `parity/replays/anticipation-tail-center.json`
- `parity/replays/anticipation-tail-bs-pop.json`
- `parity/replays/anticipation-tail-bs-360.json`
- `parity/replays/anticipation-tail-family-switch.json`
- `parity/replays/anticipation-nose-bs-360.json`
- `parity/replays/anticipation-nose-center.json`

## 360 Flip gesture

The first retail `360Flip` pattern in `skater.pat` has tolerance `0.4` and
these ordered PatternNode coordinates:

1. `(-0.965714, 0.268571)`
2. `(-0.497143, 0.840000)`
3. `(0.211429, 0.988571)`
4. `(0.908571, -0.405714)`

PatternNode reflects raw XInput Y once. The synchronized deterministic fixture
`parity/replays/dual-360-flip.json` therefore uses:

- 30-poll windup `(-31644, -8801)`;
- arc points `(-16290, -27524)` and `(-5898, -32112)`. The latter remains
  within the 360 Flip node's `0.4` tolerance while staying outside the
  three-point `90_PopShuvit` node's `0.35` final-coordinate tolerance;
- release `(29772, 13294)`.

The windup angle is approximately `-1.30 rad`, selecting the proven tail
backside 360-shuv anticipation family before the gesture completes.

## 360 Flip animation composition and timing

ABIN stores each channel as an SQT relative to `RIG_TPOSE`; that does not make
the complete physical animation an additive Ollie layer. The earlier port
incorrectly interpreted the `D` variant label as proof of that second
composition and baked `OLLIE_* + 360FLIP_D_*` actions. The user recording
`2026-08-31 21-21-52.mp4` disproved that path: it rotated the rider almost
sideways/upside-down with the board.

The preserved retail Blender renders
`Retail360Flip_D_Low.frame13/20/30.png` and
`Vanilla360Flip_TPose_High_A10.png` show the physical leaves already contain
the complete upright skater, board, foot separation, and catch pose. Re-import
of the final GLB independently measures:

| Physical action | Samples | Maximum rider-axis tilt | Cumulative board rotation |
| --- | ---: | ---: | ---: |
| `360FLIP_D_LOW_G` | 13 | `22.06°` | `53.57°` |
| `360FLIP_D_LOW_A` | 28 | `21.43°` | `500.67°` |
| `360FLIP_D_HIGH_G` | 13 | `22.36°` | `52.23°` |
| `360FLIP_D_HIGH_A` | 33 | `30.11°` | `494.31°` |

The corresponding erroneous low combined air action reached `89.19°` rider
tilt. The direct physical leaves are therefore the selected Bevy resources;
the generated `COMBINED_360FLIP_*` actions are retained only as unused
historical artifacts in the current private bank.

The Bevy sequence follows `T_TrickWithDarkCatch`:

1. Play physical G with the recovered `0.05 s` anticipation handoff.
2. Sequence into physical A, retaining the final `0.05 s` of G as the
   sequence lead.
3. At A's `WillExpire InTime="0.05"`, route to InAir, Land, or OnBoard.
4. For InAir, continue A's unconsumed final `0.05 s` underneath the physical
   `IA_IDLE_N_N_0_CYC` blend. `air.xml` authors the target as `B_AIR_CYC`,
   `time="0.2"`, `transitionUnder="true"`; the local catalog's observed
   neutral physical endpoint is `IA_IDLE_N_N_0_CYC`.
5. Touchdown takes precedence and the existing landing admission captures
   that source pose before clearing the air-trick owner.

The user recording `2026-08-31 21-42-39.mp4` and its matching deterministic
Bevy telemetry isolate the former catch jolt without relying on visual
interpretation alone. At `1.541666667 s`, the high A leaf was at
`0.483333 s`, exactly its `32/60 - 0.05` WillExpire boundary. On the next
fixed update, the old port entered InAir and sought the same leaf directly to
`0.533333 s`, skipping all three remaining 60 Hz samples before assigning any
weight to the air baseline. The corrected handoff starts at `29/60`, advances
to `32/60` over the first `0.05 s`, then holds that final source pose while
its remaining weight fades over the rest of the authored `0.2 s` blend. This
matches the already-recovered `T_Ollie.xml`/`air.xml` sequence-tail contract;
no new smoothing constant or replacement animation is introduced.

The decoded physical clips author the skater pose, deck flip-plus-backside
360-shove, foot separation, and catch. Board authority remains Physics before
wheel lift, FollowAnimationData during lift, Animation in established air and
the InAir finish, and returns to Physics at Land/OnBoard.

Only low and measured maximum-charge high endpoints are selected. The
continuous 360 Flip height mapping remains **unresolved** and is not borrowed
from Kickflip/Heelflip. Existing measured Ollie gravity, root carriers, planar
momentum, and touchdown systems are unchanged.

## Validation boundary

Automated tests cover all ten anticipation sectors, regular/switch mirroring,
sector-to-cycle mapping, L/N/R physical interpolation, unchanged Ollie/Nollie
phase behavior, the exact 360 G/A actions and sample lengths, sequence overlap,
endpoint selection, low/high `WillExpire` catch boundaries, frame-continuous
sequence-tail advancement, InAir blend, and landing cleanup.

The local private export contains 277 actions and is pinned by:

- manifest SHA-256
  `12C09459B800B163EEAA841AA4D87CED56655444F688F6D2E5ACFB1D6FB6989C`;
- GLB SHA-256
  `6CD11468301ED586B0AB78742E8C4958345B4898A87D9FA8E2B45EE0D078B537`;
- evidence JSON SHA-256
  `8FBB6DE290CD77EE02B10809E8065410351AEB90AADE2A2D188D40470E034383`.

The earlier user recording `2026-08-31 21-07-12.mp4` exposed a secondary
defect in the generated combined actions: board-parented target channels 32/33
were displaced by up to `1.57453 m`. Correcting those targets reduced the
exported maximum to `0.0383917 m`, but the later recording proved the combined
body pose itself remained invalid. The selected physical leaves preserve their
native target channels directly, and the launcher now validates those four
physical actions below `0.05 m`. The post-animation two-leg solver remains
enabled.

The direct physical action identity, body-axis measurements, board rotation,
and source-channel mapping are **observed/derived**. The `0.05 m` launcher
rejection ceiling remains a conservative **port validation threshold**, not a
claimed retail cutoff.

The worktree launcher does not use the replaceable canonical
`private/skater_push.glb`. That path is a junction into the integration
checkout and can be regenerated by another feature worktree with a different
action bank. The earlier missing-animation regression happened because Bevy
requested generated `COMBINED_360FLIP_*` names that were absent from a
309-action canonical GLB even though all four correct physical leaves were
already present.

`LAUNCH 360 FLIP VISUAL TEST.bat` instead selects
`private/skater_push.360-flip-candidate.glb`. On first use it builds that
ignored private asset from the authorized local extraction sources without
replacing the canonical GLB. Every launch parses the GLB animation table,
requires all four physical endpoints, then re-imports the GLB offline to check
their toe-target registration before Bevy starts. The runtime model override
is explicit and defaults to the canonical asset for every other scenario.

The physical 360 Flip actions use the catalog-backed exported frame-one
timeline offset. Verification mode runs the exact synchronized replay to
completion and measures the evaluated `SKATEBOARD_ROOT` matrices; a
static-board regression remains below its `300°` admission floor and fails.

The [Skate 3 trick toolkit](https://github.com/chasmlol/skate-3-trick-toolkit)
independently documents the same four low/high G/A 360 Flip source leaves and
the requirement to preserve all four authored actions rather than synthesize
missing variants.

Rendered pose quality, deck rotation readability, foot contact, absence of a
visible catch/touchdown jolt, and final settled stance are **awaiting human
visual verification**. No visual-parity claim is made.
