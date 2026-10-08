# Skate 3 TU3 fakie and automatic switch slice

This note separates recovered retail behavior from Bevy integration choices.
The SK8 harness was not launched for this work.

## Primary evidence

- `MotionGraph_OnBoard.xml`
  - SHA-256 `3D22018FBA263212A52681453D5AC3A19982B7DF66A188DB3E555B915223C8FA`
  - globally attaches `UpdateRidingFakie timeFromTeleportThreshold="1.0"`
    and `FakieHeadChannel`.
- `MotionGraphIncludes/air.xml` and `MotionGraphIncludes/Tricks/Tricks.xml`
  - established `InAir` uses `FORCE_ANIM_SKATEBOARD`;
  - the brief trick takeoff handoff uses `FOLLOW_ANIMATION_DATA`.
- `MotionGraphIncludes/ground.xml`
  - SHA-256 `8947045346B81235A3A9A7D043A473D0388A0CDA2AA63F16FD485CFD63FB4FF9`
  - `Turning.Idle` enters `Switch` when `IsRidingFakie` and either
    `IsRidingSwitch` or `InParentStateForTime greater="0.6"`.
  - push, manual, anticipation, and revert transitions are separate sibling
    routes before the switch state.
- `MotionGraphIncludes/switch.xml`
  - SHA-256 `577B5BE8EDCB0C154B1F8B1AD3AF5991F07E18DB5D9CC359567CE89475A0AC57`
  - plays virtual `B_SWITCH`, blend `0.1`, playback speed `1.0`, with
    `transitionUnder="true"`;
  - returns to `Turning.Idle` at `WillExpire InTime="0.02"`.
- `ActionGraphIncludes/T_Trick.xml`
  - maps each raw gesture through `IsMirrored`, selecting its physical
    trick counterpart (for example Kickflip versus Heelflip) unless the
    authored `DontMirrorTrick` gate applies;
  - it does not use `IsRidingFakie` as the trick-name selector.
- `ActionGraphIncludes/onground.xml`
  - creates `FakieTurn` from ordinary `Turn` with
    `fakieFilter="negate"`;
  - also publishes the unmodified `Turn`, proving fakie turn presentation is
    a separate sign transform rather than a global input reversal.
- `MotionGraphIncludes/Push.xml`, `air.xml`, and `ground.xml`
  - use `IsRidingGoofy` for current push-foot, one-foot-air, and foot-forward
    routing;
  - this predicate is distinct from `IsRidingSwitch`, `IsMirrored`, and
    `IsRidingFakie`.
- `MotionGraphIncludes/Tricks/Tricks.xml`
  - SHA-256 `1309813FA9D8075858D57BA035E05947E07847CA784C8BD15907C28123B5EFF4`
  - only the push-trick subtree explicitly rejects `IsRidingFakie`; normal
    tail/nose trick templates remain available.
- `skate3_onboard_clips.csv`
  - SHA-256 `7B2041D3E8FC305D589A05B65B72B5181319197B4CF4FC6C410C8BDDAA131D10`
  - `FAKIE_CHANNEL_CYC`, catalog 1276, 50 samples at 30 Hz;
  - `FAKIE_HEAD_CHANNEL_CYC`, catalog 1277, 50 samples at 30 Hz;
  - `FAKIE_MANUAL_CHANNEL_CYC`, catalog 1278, 50 samples at 30 Hz;
  - six `R_SWITCH_RIDE_*` leaves, catalog 1420 through 1425, each 23 samples
    at 30 Hz;
  - neutral style-0 leaf: `R_SWITCH_RIDE_N_0_N`, catalog 1424.
- `OnBoard.abin`
  - SHA-256 `30AA324D6D7C51C325D53E9268C1AD91783B0154D21BBEF5DC5A61EAE8333BD7`.
- `cameragraph_high.xml`
  - the selected `CameraHigh` graph leaves `low_ollie` for
    `bl_high_chase` with `transitionOut="0.5"`.

Independent RX2/ABIN world-pose decoding confirms:

- `FAKIE_CHANNEL_CYC` is a dedicated authored channel, not the ordinary
  `R_IDLE_HCOM_000` cycle under another name;
- `B_FAKIE_CHANNEL` is the type-7 selector at archive offset `0x491D90`. Its
  parameter is `TORSO` and its children, in authored order, are
  `FAKIE_MANUAL_CHANNEL_CYC`, `FAKIE_CHANNEL_CYC`, and
  `FAKIE_HEAD_CHANNEL_CYC`;
- `FAKIE_CHANNEL_CYC` begins at `0x48E1F0`. The data between each
  `AnimationPart` header and compression header is a per-bone channel-weight
  table. Its only nonzero entries are `SPINE2=0.5`, `SPINE3=0.7`, and
  `NECK=NECK1=HEAD=1.0`; the other 31 compact OnBoard bones are zero;
- decoded `FAKIE_CHANNEL_CYC` and `FAKIE_HEAD_CHANNEL_CYC` transform curves
  are identical, but their channel-weight bytes are not. Curve equality
  therefore does not make the leaves presentation-equivalent;
- the physical channel carries complete absolute curves, including a
  `SKATEBOARD_ROOT` frame that differs from ordinary `R_IDLE_HCOM_000` by
  matrix maximum error `1.75219494`. The zero channel weights on hips, legs,
  feet, arms, and board prove those curves are not allowed to replace the
  active riding result;
- `R_SWITCH_RIDE_N_0_N` starts near the regular idle pose, carries the
  authored shuffle, and ends in the opposite riding stance;
- the switch endpoint matches frame 3 of `R_IDLE_HCOM_000` after reflecting
  the HIPS subtree across `SKATEBOARD_ROOT` local Y and exchanging paired
  left/right bones: body RMS `0.015638`, feet RMS `0.012138`;
- the switch board bone stays stable through the 23 samples.

## Static condition separation

TU3 condition evaluators were read from the disposable IDA database:

| Condition | Evaluator | Provider call |
|---|---:|---:|
| `IsRidingSwitch` | `0x82BA4BE8` | skater-animation provider `+0x18` |
| `IsMirrored` | `0x82BA4C30` | skater-animation provider `+0x1C` |
| `IsRidingFakie` | `0x82BA4C78` | skater-animation provider `+0x0C` |
| `IsRollingBackwards` | `0x82BA4CC0` | physics provider and configured threshold |
| `IsRidingGoofy` | `0x82BA5AA8` | current skater record bytes `+0x9D/+0x9E` |

This proves fakie, switch, mirroring, and board-local backward rolling are not
one interchangeable boolean. The Bevy slice therefore compares planar travel
with the logical skater-facing heading continuously during eligible
physics-animation states and records board-longitudinal speed as a separate
observation.

The recovered `IsRidingGoofy` evaluator returns true when the two stance
bytes at decimal offsets 157 and 158 are equal. The natural/current role of
those bytes is not named in the stripped code, but the resulting truth table,
the `NaturalStance` parameter to `SkaterAnim::Initialize` at `0x82B97E38`,
the graph's separate `IsRidingSwitch` predicate, and the decoded B_SWITCH
endpoint together establish the player-facing relationship: switching flips
the actual regular/goofy riding stance while natural stance remains
persistent.

Static TU3 animation evaluation also establishes that stance mirroring is a
single post-animation operation rather than a special set of idle clips:

- `Andale::Mirror::Eval` at `0x82547560` evaluates its child animation and
  then calls `AnimCommandSystem::Mirror` at `0x828CDAF8`;
- `SkaterAnim::Initialize` at `0x82B97E38` stores the persistent natural
  mirror state used by the animation system;
- graph leaves throughout the on-board trees use `mirrorAnim` and
  `IsMirrored` around riding, trick, grab, slide, and adjustment paths.

This is consistent with the decoded `B_SWITCH` endpoint: the board carrier
does not rotate, while the body pose reflects across board-local Y and the
paired left/right chains exchange roles.

Static TU3 `UpdateRidingFakie` code at `0x82BB2330` also proves that fakie is
updated continuously rather than sampled only on touchdown. Its constructor
at `0x82BB2248` reads these authored defaults:

| Attribute | Value |
|---|---:|
| `highSpeedThreshold` | `1.0` |
| `lowSpeedThreshold` | `0.5` |
| `timeSlowlyRollingBackwardsThreshold` | `0.2` |
| `timeFromTeleportThreshold` | `3.0`, overridden to `1.0` by XML |

The update compares normalized travel/facing alignment against `-0.5`.
Above `1.0` speed, backward travel publishes fakie immediately; in the
`0.5..1.0` band it must remain backward for strictly more than `0.2 s`.

The same update accepts `PhysicsAnimationState` values `1` and `2` and rejects
the normal value `0` path. Static `ParsePhysAnimationState` at `0x82BB2790`
maps the authored names as follows:

| Value | Authored name | Fakie orientation update |
|---:|---|---|
| 0 | `FOLLOW_ANIMATION_DATA` | rejected |
| 1 | `FORCE_PHYSICS_SKATEBOARD` | accepted |
| 2 | `FORCE_ANIM_SKATEBOARD` | accepted |

Consequently the short takeoff handoff does not reclassify orientation, but
the established-air state does. A sufficiently completed airborne 180 can
therefore publish fakie before touchdown.

Static `FakieHeadChannel::Update` at `0x82BAC778` starts the separate
`B_FAKIE_CHANNEL` animation request with playback `1.0` and request fields
containing `0.3` for the authored in/out blends. It writes a MotionGraph
parameter named `torso`, initialized to the neutral endpoint `0.5`, and
clamps that parameter's change to the literal interval `[-0.01, 0.01]` per
retail update. The `torso` string is therefore a blend-tree attribute, not a
skeleton-part mask or a `0.5` animation-layer weight.

`ChannelBlend::Eval` at `0x82B965D8` evaluates the active animation and
channel child, then calls `AnimCommandSystem::ChannelBlend(float,bool)` at
`0x828CC210`. The latter consumes the animation weight streams as well as the
scalar request influence. Together with the physical leaf's embedded
per-bone table, this proves the retail neutral presentation is the live
riding pose plus weighted spine/head correction, not the raw physical leaf
as a standalone full-body animation.

The user comparison capture
`C:\Users\Daddy\Videos\2026-09-01 01-47-44.mp4` corroborates the decoded
pose: after the retail 180 landing the legs retain the backward stance while
the authored chest, neck, and head look down the direction of travel. In the
pre-fix Bevy half, state telemetry entered fakie while the primary clip
remained `R_PUSHHSP_HSTR_N_0_CYC2`; the dedicated fakie clip never became
the rendered riding presentation.

The follow-up capture
`C:\Users\Daddy\Videos\2026-09-01 02-11-30.mp4` shows the next integration
failure. At `4.30 s` the Bevy overlay explicitly reports `STATE fakie`,
`ACTION fakie`, and `CLIP FAKIE_CHANNEL_CYC`, while the skater and board
visibly rotate and oscillate. This proves state/selector routing occurred,
but promoting the raw independent channel as an absolute action was wrong.
It agrees with the decoded `SKATEBOARD_ROOT` frame mismatch and with retail
starting `B_FAKIE_CHANNEL` as a request beside the active MotionGraph state.

## Implemented

- Continuous eligible physics/established-air motion with travel opposite
  logical skater facing enters and retains `RidingFakie` using the recovered
  speed/time filters.
- Asset construction first verifies the physical channel-weight table
  directly from `OnBoard.abin`, failing unless exactly the five proven bones
  and values are present.
- Asset construction generates an action-relative `B_FAKIE_CHANNEL`
  composition for every one of the 275 physical source/composed actions.
  Each generated partner retains its source action's local
  location/scale channels and all 31 zero-weight bone rotations, then
  normalized-linearly blends only the five authored local quaternions
  against `FAKIE_CHANNEL_CYC`.
- Runtime applies the global channel request to the currently active riding,
  airborne trick, or landing action. It blends each source action toward its
  matching `RETAIL__B_FAKIE_CHANNEL__<action>` partner instead of waiting for
  graph ownership to return to neutral idle. A completed airborne 180 can
  therefore begin the authored upper-body/head transition before touchdown,
  and landing release cannot promote an unrelated idle pose and snap.
- Every generated action validates its weighted quaternion curves at zero
  rotation error. Hips, legs, feet, arms, board, trucks, and wheels therefore
  remain on the current action while the upper spine/head move down travel.
- Neutral fakie riding and action-relative fakie tricks crossfade into the
  authored `B_SWITCH` leaf when the delayed shuffle starts.
- The independent fakie animation request uses the recovered `0.3 s` blend.
  Its `torso` MotionGraph parameter separately moves toward `0.5` at the
  recovered `0.01` per 60 Hz update bound.
- The 30 Hz physical channel is resampled cyclically over the 101-sample
  60 Hz neutral ride, including the sample-49 to sample-0 wrap.
- Before the automatic shuffle, tricks retain the current actual riding
  stance while carrying explicit `fakie` approach metadata for status/scoring
  presentation. Completing `B_SWITCH` toggles persistent switch state.
  Current riding stance is then derived from natural stance plus that switch,
  and subsequent Flickit matching uses the ActionGraph's `IsMirrored` route.
- Live Flickit winners now pass through that recovered route before endpoint
  selection. The verified Kickflip/Heelflip pair changes physical trick
  identity with mirrored stance while the complete action bank preserves
  body stance through anticipation, trick, and landing.
- Eligible `Turning.Idle` time uses the strict authored `> 0.6 s` gate.
- Flickit displacement, anticipation, trick, landing, push, brake, slide,
  grind, grab, and manual ownership reset the `Turning.Idle` parent-state
  clock without mutating queued input. A fresh strict `> 0.6 s` is required
  after the blocking state clears.
- The automatic shuffle uses `R_SWITCH_RIDE_N_0_N`, blends in for `0.1 s`,
  exits `0.02 s` before its 22/30-second sample-interval duration, and blends
  back to riding over the existing 0.2-second `Turning.Idle` entry.
- Asset construction generates a stance-mirrored partner for all 550 base
  and action-relative-fakie actions after authored and composed actions have
  been assembled, producing 1,100 exported actions. Each partner reflects
  the complete HIPS subtree in board-local Y, exchanges every available
  LEFT/RIGHT chain and both reparented toe targets, and leaves the board
  carrier untouched. Riding, carving, anticipation, tricks, landing, push,
  BodySpin, and the weighted fakie compositions therefore use the same
  animation-level stance operation.
- Static `AnimCommandSystem::Mirror` receives `TrajectoryUse` as well as the
  skeleton command. The decoded Bevy exporter deliberately leaves
  `SKATEBOARD_ROOT` unchanged, while the distinct retail `OLLIE_*` and
  `NOLLIE_*` actions contain the physical tail/nose board trajectories.
  Applying the stance operation therefore routes Ollie to the mirrored
  Nollie physical action and Nollie to the mirrored Ollie physical action,
  while the winner's semantic trick identity and fakie approach metadata
  remain unchanged.
- Final animation samples route through the persistent stance mirror after
  graph selection. If a transition-under source is already mirrored, the
  operation is involutive and selects the original partner instead of
  applying a second mirror.
- Build validation still uses the decoded neutral `B_SWITCH` endpoint as a
  hard spatial check and fails if the mirrored neutral ride exceeds `0.03`
  body RMS or changes the board by more than `1e-5`.
- Riding lean uses the authored `FakieTurn = -Turn` mapping. The source HCOM
  coordinate is also inverted before a spatial stance mirror, preventing a
  goofy/switch skater from leaning opposite the carve. Once B_SWITCH starts,
  `switch.xml` explicitly attaches ordinary `Turn`, so the fakie sign
  inversion ends at that state boundary.
- Natural stance defaults to regular, survives respawn/reset, and can be set
  to `goofy` with `SKATE3_NATURAL_STANCE`. The status overlay independently
  reports natural stance, current riding stance, switch state, and
  fakie/regular approach.
- Completing the shuffle changes logical facing and persistent stance only;
  it does not rotate world board yaw or redirect planar velocity.
- While fakie, the chase heading remains aligned with planar travel rather
  than raw board yaw. After the shuffle, it follows logical skater facing, so
  completing the reorientation does not trigger a second camera orbit.

For the currently selected aggressive flat-ground landing leaves, retail
durations are 39, 71, or 70 samples at 60 Hz and Landing exits in its final
`0.1 s`. Therefore the derived touchdown-to-switch-start interval is roughly
`1.13..1.67 s` (landing ownership plus the strict `> 0.6 s` Idle gate), and
touchdown-to-shuffle-completion is roughly `1.84..2.38 s`. This is why the
visible retail behavior is normally perceived as a one-to-two-second wait,
not an immediate correction.

## Inferred

- `B_SWITCH` is a virtual selector. The neutral style-0 leaf is selected for
  this Bevy player's neutral/default riding style from the complete physical
  family and its naming dimensions. Runtime selected-leaf telemetry has not
  yet independently captured that exact selector output.
- The Bevy mapping from current goofy stance to `IsMirrored` trick routing
  follows the separate condition evaluators, `T_Trick.xml`, and decoded
  B_SWITCH reflection. The stripped provider method that assigns
  `IsMirrored` has not yet been named independently.
- The Bevy neutral skater uses the static channel endpoint `0.5`.
  Retail has provider branches that can override this endpoint to `0` or `1`;
  the exact player-style predicates behind those branches remain unnamed.
- The internal `bl_high_chase` yaw-source equation has not been named from
  the retail binary. Using travel heading specifically while
  `IsRidingFakie` is active is the minimal integration consistent with the
  retail separation of travel, board yaw, and skater facing and with the
  supplied visual reference. The selected graph's `0.5 s` transition is
  proven directly.
- Non-neutral selector interpolation and exact action-specific use of the
  weight stream still require separate integration; the neutral selector,
  physical leaf, weight table, and channel-blend call are now named.
- Physical counterpart endpoint routing remains evidence-gated where this
  slice has no decoded partner implementation. For example, the existing
  360 Flip endpoint is retained rather than guessing a Laserflip clip; its
  body animation is still stance-mirrored by the global action-bank route.
- The exact internal `TrajectoryUse` enum values passed by
  `AnimCommandSystem::Mirror` have not yet been named. Using the authored
  Ollie/Nollie counterpart for the physical board-root trajectory is the
  minimal action-level reconstruction supported by the separate retail
  leaves, the untouched mirrored board root, and the observed reversed pop.

## Unresolved / awaiting visual verification

- Non-neutral `B_SWITCH` leaf selection for lean/style dimensions.
- Exact style-provider selection of the `0`, `0.5`, or `1` torso endpoint.
- Human verification of natural-goofy and switch-to-regular complete action
  mirroring, especially carve direction, push-foot presentation, trick
  anticipation, and landing continuity.
- Human verification of pose continuity, foot shuffle readability, and the
  perceived `1.84..2.38 s` touchdown-to-completion delay in the Bevy renderer.
- Human verification that the fakie spine/head transition is already visible
  late in an airborne 180 and remains continuous through touchdown and
  landing release, without an idle-pose snap.
- Human verification that Ollie still pops the physical tail and Nollie the
  physical nose in both regular and opposite riding stances.
- Human verification that the corrected chase heading remains visually
  stable through both the fakie landing and the final shuffle, while the body
  and feet retain the mirrored riding stance without a board/world 180.
- Human verification that the action-relative
  `RETAIL__B_FAKIE_CHANNEL__*` bank reads as the retail fakie presentation
  throughout air, landing, riding, and trick preparation.
