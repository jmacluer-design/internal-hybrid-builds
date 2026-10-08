# Manual and Nose-Manual Implementation Evidence

Date: 2026-09-01
Implementation checkpoint: post-`1076723`

This document separates facts recovered from Skate 3 TU3 from deterministic
derivations, bounded implementation inferences, unresolved retail behavior, and
items requiring human visual verification. No retail or clone game process was
launched during this work.

## Source identity

- TU3 loaded image:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\XexDump\default_82000000_011B0000.bin`
  - SHA-256:
    `F4AA113EB541BFBA03DBC108CF5AB43F58C965B20FA3B82F9C40938A0AD841C4`
- Read-only IDA database:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\XexDump\disposable\Skate3TU3_dump.community-disposable.i64`
- Recompiled code:
  - `generated\skate3_animation_research_recomp.52.cpp` (raw input)
  - `generated\skate3_animation_research_recomp.18.cpp` (ActionGraph input)
  - `generated\skate3_animation_research_recomp.71.cpp` (timed intent)
  - `generated\skate3_animation_research_recomp.72.cpp` (manual conditions)
- State trees:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\VerifyCustomAnimation\data\state`
- Authoritative OnBoard ABIN:
  - SHA-256:
    `30AA324D6D7C51C325D53E9268C1AD91783B0154D21BBEF5DC5A61EAE8333BD7`
- Authoritative clip catalog:
  - SHA-256:
    `7B2041D3E8FC305D589A05B65B72B5181319197B4CF4FC6C410C8BDDAA131D10`
- Decoded manual visual bank:
  `C:\Users\Daddy\Documents\Skate3Research\godot\private_assets\skater_rig.glb`
  - SHA-256:
    `AB4DE56A839EF5E6C85BC1472AC408081813C4B93DE5BA7DD3AB68A5CD189D57`
  - manifest SHA-256:
    `0D3F5F153D61933450FE0F12648F2CD8D9756DC1E70864FC05B8B65F889E5B11`

## Proven: raw and processed right stick

`sub_8296D5F8` at `0x8296D5F8` reads signed 16-bit right-stick
X/Y from packed offsets `+44/+46`, scales them, and performs radial
conditioning.

| Address | Bits | Value | Meaning |
|---|---:|---:|---|
| `0x8231BB94` | `0x38000000` | `1/32768` | raw signed-axis scale |
| `0x82063A48` | `0x3A83126F` | `0.001` | divide/sqrt guard |
| `0x820C6D98` | `0x3E800000` | `0.25` | radial dead zone |
| `0x822F8EF0` | `0x3FB6DB6E` | `1.4285715` | remap gain |
| `0x8231A844` | `0x3F800000` | `1.0` | upper clamp |

Finite-input equivalent:

```text
raw = (rx, ry) / 32768
m = length(raw)
scale = m < 0.001 ? 0 : clamp((m - 0.25) * 1.4285715, 0, 1) / m
processed = raw * scale
```

The exact boundary is radial magnitude `<= 0.25` producing zero. Magnitude
first becomes positive strictly above `0.25` and saturates at raw magnitude
`0.95`.

Processed directions are channels 20/21/22/23 at frame offsets
`+80/+84/+88/+92`: right, left, up, down. `cInputMap` expression readers
`0x82590438` (`InputSK8+0x10C`) and `0x8255E010`
(`InputSK8+0x110`) feed `DerivedControllerInput+0x24/+0x28` through
`sub_82598FE0`; `DerivedControllerInput::Update` is `0x825992D8`.

The serialized expression opcode stream was not recovered. Recombining the
named directional channels into continuous X/Y is derived from the channel
identity and consumers.

## Proven: Manual and ManualBrake producer

- Caller: `Sk8::Skater::ActionGraphInputListener::Fill`, `0x825999F0`
- Call site: `0x8259A9D4`
- Producer: `sub_8259BA28`
- `f1`: processed right-stick radial magnitude
- `r4+0x0C`: processed right-stick Y
- owner flags: `+0x774` / decimal 1908
- suppression: numeric bit 9, mask `0x200`
- `Manual` FastString: `0x830BE900`, initializer `0x82F84D18`
- `ManualBrake` FastString: `0x830BE468`, initializer `0x82F84D30`

Equivalent behavior:

```text
if flags & 0x200 == 0:
    Y > 0 -> Manual = +magnitude
    Y < 0 -> Manual = -magnitude
    Y = 0 -> Manual absent

    magnitude > 0.9 ->
        ManualBrake = sign(Y) * (magnitude - 0.9) * 9.999998
```

The threshold comparison is strictly greater-than:

- threshold load at `0x8259BA50` from `0x820997B8`
  - bits `0x3F666666`, value `0.9`
- gain load at `0x8259BA60` from `0x822F9274`
  - bits `0x411FFFFE`, value `9.999998`

There is no second manual engage threshold above the radial dead zone.
`Manual` magnitude is radial magnitude, not `abs(Y)`. Stance is not an input to
this producer and does not invert tail/nose routing.

The semantic enum name and writer of owner bit `0x200` remain unresolved. The
implementation does not assign unrelated graph-owner meanings to this bit.

## Proven: hold timer and strict entry

`ActionGraphIncludes\onboardgeneral.xml:34-36` transports:

```xml
<CreateMGIntentFromAGIntent MGIntent="Manual" AGIntent="Manual"/>
<CreateMGIntentFromAGIntent MGIntent="ManualBrake" AGIntent="ManualBrake"/>
<CreateMGTimeIntentFromAGIntent MGIntent="ManualEngageTime" AGIntent="Manual"/>
```

Timed-intent implementation:

- registration initializer `0x82F86A38`
- factory `0x82BC2778`
- constructor `0x82BA3040`
- vtable `0x8231E660`
- update slot `0x82BA3158`

While `Manual` is present, the update adds graph delta time and publishes
`ManualEngageTime`. When `Manual` is absent, it zeros the accumulator and
removes the timed intent. It is elapsed presence time, not magnitude-weighted
time. A direct negative-to-positive sign change does not reset it; a sampled
zero/dead-zone value does.

`MotionGraphIncludes\ground.xml:337` requires
`ManualEngageTime > 0.2`, strictly. Exactly `0.2` does not enter.

The timer belongs to the parent OnBoard graph and can mature in air.
`air.xml:108-109` and `air.xml:164-165` explicitly route landing to tail or
nose manual before the ordinary Land transition. The implementation uses the
existing previous-step touchdown seam for this route.

The only hard landing rejection is the conjunction:

```text
LastState == InAir
AND center-of-mass velocity Y < -8.0
AND surface slope > 45 degrees
```

There is no minimum-speed entry gate.

## Proven: graph routes, attributes, and strict bands

Negative `Manual` routes to tail; positive routes to nose. No regular/goofy
condition or mirror argument exists in the manual XML. Tail/nose semantics are
therefore board-relative and stance invariant.

| Phase | Strict selector | Resource | Attributes | Transition |
|---|---|---|---|---:|
| Nose INTO | entry without brake | `B_NOSE_MANUAL_INTO` | `spin=Turn` | 0.1 s |
| Tail CYCLE | local Z `< -0.5` | `B_TAIL_MANUAL` | balance, spin, manual_angle | 0.3 s |
| Tail low CYCLE | otherwise | `B_TAIL_MANUAL_LOW` | balance, spin | 0.3 s |
| Nose CYCLE | local Z `> 0.5` | `B_NOSE_MANUAL` | balance, spin, manual_angle | 0.3 s |
| Nose low CYCLE | otherwise | `B_NOSE_MANUAL_LOW` | balance, spin | 0.3 s |
| Tail moving brake | `abs(local Z) > 0.1` | `M_BRAKE_N_0_CYC` | balance=-1, brake, spin | 0.2 s |
| Tail static brake | otherwise | `M_BRAKE_STAT_0_CYC` | balance=-1, brake | 0.5 s |
| Nose moving brake | `abs(local Z) > 0.1` | `S_M_NOSEBRAKE_N_0_CYC` | balance=+1, brake, spin | 0.2 s |
| Nose static brake | otherwise | `M_NOSEBRAKE_STAT_0_CYC` | balance=+1, brake | 0.5 s |
| Nose OUT | physics exit or loss of positive Manual | `B_NOSE_MANUAL_OUT` | none observed | 0.1 s |

Nose INTO uses `WillExpire 0.05` to CYCLE and `WillExpire 0.1` to brake.
Nose OUT completes at `WillExpire 0.1`. Tail has no authored OUT leaf.
`ground.xml:356` configures `SetManualOutTimer length="0.1"`.

Advanced manual reverts, one-foot manuals, grabs, and coping/transition routes
remain outside this implementation.

## Proven: PlayAnimation transition controls are separate from graph attributes

Static TU3 analysis used executable SHA-256
`0CB7534D8ECD07B509D583033100FF0EEBB45546F66763E3364DE8BFCD66E188`.

- factory `0x82BC6B60` allocates the 0xAC-byte behaviour and calls parser/
  constructor `0x82BB4B38`;
- `PlayAnimation::Begin` is `0x82BB5188`;
- parser string `time` is at `0x8230806C`;
- `transType` is at `0x823080BC`, `anim` at `0x823080E4`, and
  `playBackSpeed` at `0x823080EC`;
- `blendWithCurrentFrame`, `blendMatchPhase`, and `blendMatchFrame` are
  distinct booleans at `0x8231DAD0`, `0x8231DAE8`, and `0x8231DAF8`;
- `transitionUnder` and `useChannelFromWeights` are at `0x8231DB08` and
  `0x8231DB18`;
- the parser stores `time` at behaviour offset `+0x20`, playback speed at
  `+0x90`, `applyPosture` at `+0xA4`, and the current-frame/phase/frame match
  mode at `+0x28`;
- `Begin` copies the selected animation descriptor and these transition fields
  independently before dispatching through the animation controller.

The manual XML sets only `time` (and nose-INTO playback speed 1.0). It never
sets any current-frame, phase-match, or frame-match flag. More importantly,
nose-INTO attaches only `spin`; `balance=Manual` is first attached by CYCLE.
Nose OUT also has no balance attachment, while Brake replaces the live value
with an exact `balance=+/-1`.

Implementation consequence: the outer PlayAnimation transition cannot be
multiplied by live stick balance in nose-INTO, Brake, or nose-OUT. Balance
remains an inner virtual-selector coordinate only where the XML attaches it.

## Proven: manual-angle conditioning

- `PointGraphEval::Evaluate`: `0x82481E10`
- `SetManualAngle::Begin`: `0x82BA8C48`
- `SetManualAngle::Update`: `0x82BA8C60`
- `PowerSlideManualAtt::Update`: `0x82BB34D8`

The behaviour's state ownership is as important as its arithmetic. Retail
`TailManual.xml` places `<behaviour name="SetManualAngle"/>` only in
`Cycle/RollingBackwards`, whose strict speed condition is local skate Z
`< -0.5` and whose animation is `B_TAIL_MANUAL`. `NoseManual.xml` places it
only in `Holding/Cycle/RollingForwards`, whose strict condition is local skate
Z `> 0.5` and whose animation is `B_NOSE_MANUAL`. It is absent from nose INTO,
both opposite/stationary LOW children, Brake, OUT, and Revert.

Consequently, entering either owning child calls `SetManualAngle::Begin` and
clears angle/velocity before updates begin. The conditioner must not be run
from manual entry as a whole. Doing so pre-charges nose INTO for its full
14/30-second physical duration and can enter CYCLE already selecting
`M_NOSELEAN_N_0_CYC`; that 30-frame high leaf has far less pelvis motion than
the 102-frame `M_NOSEIDLE_N_0_CYC`, producing the observed apparently frozen
nose manual and a visible handoff jolt.

The saved retail run
`20260815T230727813Z-sandbox-push-nose-manual-hold-5e09be07/result.json`
traces producer `0x8259BA28` and `SetManualAngle::Update` `0x82BA8C60`
together. While the behaviour is active, Update appears once per consecutive
StateGraph frame (`1113..1165`, apart from observer loss/one duplicate at
1153), matching the project's recovered 60 Hz animation-signal clock. It is
not a 120 Hz physics callback. The Bevy clone therefore accumulates fixed-step
time and runs the native no-delta arithmetic at 60 Hz; calling it on every
120 Hz physics step doubles its velocity/acceleration rate and reaches the
low/high selector endpoint too early.

The VLT `anim_motion/manual` curve is:

```text
X = 0, .125, .25, .375, .5, .625, .80485338, 1
Y = 0, 0,    0,   0,    0,  0,    0,          1
```

Per update, with no delta-time multiplication:

```text
target = sign(Manual) * graph(abs(Manual))
desired_velocity = clamp(target - angle, +/-0.04)
acceleration = clamp(desired_velocity - velocity, +/-0.02)
velocity += acceleration
angle += velocity
```

`Begin` zeros angle and velocity. The implementation retains this exact
conditioner for the graph's `manual_angle` parameter. Static evidence does not
show `manual_angle` driving the physical board pitch.

## Proven: authored physical clips

All clips below are 30 Hz, eight-part OnBoard ABIN clips. Duration is
`(frames - 1) / 30`.

| Clip | Catalog | Frames | Duration | Offset | Size |
|---|---:|---:|---:|---:|---:|
| `M_NOSEBRAKE_N_0_CYC` | 1369 | 45 | 1.4667 | 5,286,272 | 4,400 |
| `M_NOSEBRAKE_STAT_0_CYC` | 1370 | 60 | 1.9667 | 5,290,672 | 3,696 |
| `M_NOSEIDLE_N_0_CYC` | 1380 | 102 | 3.3667 | 5,332,224 | 9,632 |
| `M_NOSEIDLE_N_0_INTO` | 1381 | 15 | 0.4667 | 5,341,856 | 3,584 |
| `M_NOSEIDLE_N_0_OUT` | 1382 | 15 | 0.4667 | 5,345,440 | 3,568 |
| `M_BRAKE_N_0_CYC` | 1400 | 45 | 1.4667 | 5,461,552 | 4,496 |
| `M_BRAKE_STAT_0_CYC` | 1401 | 45 | 1.4667 | 5,466,048 | 3,216 |
| `M_IDLE_N_0_CYC` | 1405 | 100 | 3.3000 | 5,504,992 | 9,872 |

The three directly graph-named physical brake leaves are proven.

## Proven: decoded ABIN manual selector hierarchy

The earlier implementation skipped OnBoard ABIN block types 7 and 8 and
therefore treated the virtual selector leaves as unresolved. Static decoding
of those blocks now proves the actual tree. `DataBase::GetAnimTree` at
`0x82D1B5B8` handles type 7: child count is at aligned payload `+8`, child
FastString36 records start at `+36`, and their stride is 24 bytes. The type-8
path at `0x82D1B9B4` selects the attribute-matched child and otherwise returns
the first/default child. Recompiled source:
`generated\skate3_animation_research_recomp.85.cpp`.

Exact OnBoard ABIN selector blocks include:

| Resource | Offset | Type | Recovered axis/role |
|---|---:|---:|---|
| `B_NOSE_MANUAL_TURN_LOW` | `0x00555330` | 7 | `ANGLE`: FS, BS, neutral |
| `B_NOSE_MANUAL_CROUCH_TURN_LOW` | `0x005553D0` | 7 | `ANGLE`: FS, BS, neutral |
| `B_NOSE_MANUAL_TURN_HIGH` | `0x00555470` | 7 | `ANGLE`: FS, BS, neutral |
| `B_NOSE_MANUAL_CROUCH_TURN_HIGH` | `0x00555510` | 7 | `ANGLE`: FS, BS, neutral |
| `B_NOSE_MANUAL_INTO` | `0x005555B0` | 7 | `DISTTOCOG` |
| `B_NOSE_MANUAL_OUT` | `0x00555640` | 7 | `DISTTOCOG` |
| `B_NOSE_MANUAL_LOW/HIGH` | `0x005556D0/0x00555760` | 7 | `DISTTOCOG` |
| `B_NOSE_MANUAL` | `0x005557F0` | 7 | `MANUAL_ANGLE` |
| `B_TAIL_MANUAL_TURN_LOW` | `0x00555A50` | 7 | `ANGLE`: FS, BS, neutral |
| `B_TAIL_MANUAL_CROUCH_TURN_LOW` | `0x00555AF0` | 7 | `ANGLE`: FS, BS, neutral |
| `B_TAIL_MANUAL_TURN_HIGH` | `0x00555B90` | 7 | `ANGLE`: FS, BS, neutral |
| `B_TAIL_MANUAL_CROUCH_TURN_HIGH` | `0x00555C30` | 7 | `ANGLE`: FS, BS, neutral |
| `B_TAIL_MANUAL_LOW/HIGH` | `0x00555CD0/0x00555D60` | 7 | `DISTTOCOG` |
| `B_TAIL_MANUAL` | `0x00555DF0` | 7 | `MANUAL_ANGLE` |

The complete CYCLE hierarchy is:

```text
MANUAL_ANGLE -> LOW/HIGH
DISTTOCOG    -> normal/crouch
ANGLE        -> FS/BS/neutral physical cycle
```

Tail physical families are `M_IDLE_*` for LOW and `M_LEAN_*` for HIGH.
Nose families are `M_NOSEIDLE_*` and `M_NOSELEAN_*`. The selector contains
normal and crouched neutral, FS, and BS leaves for all four rows.

`B_NOSE_MANUAL_INTO` child order is
`M_NOSEIDLE_CROUCH_0_INTO`, `M_NOSEIDLE_N_0_INTO`; OUT is the corresponding
crouch then normal pair. This serialized order is not a default rule for type
7: each child is queried for its authored coordinate and the resulting pairs
are sorted. The moving nose-brake type-8 `PROSKATER` selector does use child
zero as fallback, resolving to `M_NOSEBRAKE_N_0_CYC`.

`sub_82D25378` is the exact type-7 evaluator. It queries child attributes,
sorts with strict less-than, finds the adjacent endpoints, computes
`(clamp(value, lower, upper)-lower)/(upper-lower)`, and applies the two linear
weights. The ABIN stores no generic 0/1 selector weights.

Observed authored coordinates include:

- `ANGLE`: BS `-1`, neutral `0`, FS `+1`;
- `MANUAL_ANGLE`: tail HIGH `-0.9`, LOW `0`; nose LOW `0`, HIGH `+0.9`;
- nose INTO: crouch `0.598406971`, normal `0.896377325`;
- nose OUT: crouch `0.598507404`, normal `0.892133415`;
- all 24 CYCLE physical leaves carry their own `DISTTOCOG` value, ranging
  from `0.544377625` to `0.914747536`.

`sub_82D1A360` phase/speed propagation keeps simultaneously selected children
synchronized. The implementation uses the exact linear neighboring-endpoint
rule and phase-locks leaves with different authored durations.

## Derived from decoded clips: authored pose motion and handoff discontinuity

The pinned manual visual GLB has SHA-256
`AB4DE56A839EF5E6C85BC1472AC408081813C4B93DE5BA7DD3AB68A5CD189D57`.
Board-relative sampling of every authored key gives:

- tail CYCLE HIPS spans 0.061/0.120/0.027 m and reaches 11.8 degrees from its
  first sample;
- nose CYCLE HIPS spans 0.050/0.196/0.047 m and reaches 20.8 degrees;
- the board and both feet are effectively stable in both leaves while the
  torso and arms carry the balance motion.

These board-relative translation and geodesic-rotation magnitudes prove total
authored pose motion. They also establish that the neutral nose cycle has the
larger rider motion: its HIPS rotation reaches 20.8 degrees versus 11.8
degrees in the neutral tail cycle. Both neutral leaves run with authored
`ANGLE=0`; their motion therefore advances independently of the `Turn`
attribute. Nonzero Turn does not start balance motion. It blends from the
already-running neutral leaf into the authored FS or BS direction leaf.

A 2026-09-01 human correction explicitly confirmed the retail visual target:
balance sway continues without lateral steering and is substantially more
noticeable in a nose manual than a regular manual. The earlier interpretation
of an A/B diagnostic as proving turn-created sway was wrong. The diagnostic
only proved that steering-dependent deck roll and FS/BS selector motion remain
visible when neutral tail animation time is frozen. The default parity path
must not freeze either neutral cycle.

The final nose-INTO pose and first nose-CYCLE pose are not identical. Their
board-relative discontinuities include HIPS 0.011 m/2.8 degrees, left hand
0.083 m/22.3 degrees, left forearm 0.061 m/8.2 degrees, and right hand
0.019 m/6.4 degrees; `SKATEBOARD_ROOT` is continuous. The XML's 0.3-second
CYCLE PlayAnimation transition is therefore required to hide a real authored
pose discontinuity rather than an optional cosmetic ease.

## Proven and derived: graph attribute binding

`manual_angle` maps directly to `MANUAL_ANGLE`. The parent Riding state runs
`SetDistComToBoard attribute="disttocog"` and `Crouching
crouchName="disttocog"` before and throughout Manual. `SetDistComToBoard`
update `0x82BB04E8` publishes the skater provider's board-to-COM value; it is
not the right-stick `Manual` magnitude.

The non-crouched entry source `R_IDLE_HCOM_000` at ABIN `0x005C6BA0` proves
`DISTTOCOG=0.9649194479` (`0x3F7704F6`) and `ANGLE=0`. The current scope has no
crouch-control implementation, so that inherited evidence-backed value is
held through ordinary manual playback. It clamps to the normal, never crouched,
manual rows. This prevents a normal manual from accidentally selecting the
strong crouch variants.

The final `ANGLE` binding to attached `spin=Turn` is derived from the XML plus
the physical FS/BS/neutral coordinate records. Straight input selects only
neutral leaves; positive spin blends toward FS `+1`, negative toward BS `-1`.

The former whole-action `abs(balance)` blend against riding was incorrect.
After the exact PlayAnimation entry transition, the manual action remains at
full graph weight. `Manual` drives the already recovered physical pitch and
the separately conditioned `manual_angle`; it is not an extra pose-weight
multiplier.

## Derived implementation: synchronized entry and state handoff

The implementation preserves the outgoing graph action weight during each
PlayAnimation handoff. For a partial nose manual, the exact 0.3-second
INTO-to-CYCLE blend transitions from the full default nose-INTO action to the
full CYCLE selector action. At half transition the two graph actions contribute
0.5 each.

Because the manual XML leaves `blendWithCurrentFrame=false`, outgoing manual
leaves continue advancing during the handoff. Non-looping INTO/OUT leaves are
bounded by their proven `(frames-1)/30` duration and clamp at the final sample;
looping CYCLE/Brake leaves wrap. This avoids both a frozen handoff and an
accidental INTO wrap.

Physical deck pitch uses the same initial PlayAnimation transition window:
0.3 seconds for tail CYCLE and 0.1 seconds for nose-INTO. This is a derived
synchronization rule, not a newly tuned spring: it uses the exact authored XML
times and keeps board articulation, support wheels, post-animation foot IK,
and the body pose from changing on different entry frames.

## Proven and derived correction: turning-selector and riding-exit continuity

The manual direction row is not a set of discrete animation states. Both
`TailManual.xml:14,63` and `NoseManual.xml:14,45,92` attach the continuously
published `Turn` intent as `spin`; decoded type-7 evaluator `sub_82D25378`
then linearly blends the adjacent BS `-1`, neutral `0`, and FS `+1` children.
`sub_82D1A360` keeps those simultaneously selected children phase
synchronized. The directional leaves are complete rider poses, so replacing
one endpoint with the opposite endpoint in one clone frame creates a
whole-body discontinuity even though the decoded selector itself is linear.

The former Bevy integration supplied `sim.steer`, the instantaneous
post-dead-zone left-stick X value, directly to `ManualSignals.spin`. That
bypassed the already-running physical turn response. The deck and riding body
tilt continued through their second-order physical state and the recovered
60 Hz animation publication, while the manual's complete FS/neutral/BS pose
could jump immediately. Returning the stick to center or reversing direction
therefore moved the body and board on different response clocks.

The corrected integration derives presentation `spin` from that existing
60 Hz physics-owned deck-roll/body-tilt publication. This is a synchronization
derivation, not a newly fitted manual spring or a modification to the authored
selector: the exact decoded type-7 weights, phase propagation, clips, and
neutral-cycle balance sway remain unchanged. Deterministic tests prove that a
one-frame full reversal cannot swap a complete FS pose directly to BS and
that tail and nose manuals use the same continuous physical response.

Manual exit has a separate proven destination transition. The default
`OnGround.RidingIdle.Riding.Turning.Idle.Default` child plays
`BTREE_RIDING time="0.2"` in `MotionGraphIncludes\ground.xml:289-290`.
Tail manual has no authored OUT animation and leaves its CYCLE directly.
Nose manual first plays `B_NOSE_MANUAL_OUT time="0.1"` and transitions to
Turning when `WillExpire InTime=".1"`. The old integration discarded the
tail CYCLE on the first exit frame and discarded the final nose-OUT pose when
Manual ownership ended.

The implementation now retains and advances the outgoing manual leaves while
their action weight blends to riding over the exact default 0.2-second
PlayAnimation window. Looping tail CYCLE leaves wrap at their decoded
duration; the non-looping nose OUT leaf clamps at its final sample. This
presentation handoff is independent from the existing 0.1-second
`SetManualOutTimer`, which continues to return physical deck pitch to zero.

The exact temporal relationship between retail's ActionGraph `Turn` value and
the physics-published body-tilt value has not been observed simultaneously.
Using the physics-owned 60 Hz value for clone presentation is therefore
classified as derived, while the selector coordinates, child weights, phase
locking, and 0.2-second riding destination transition are proven.

## Proven: separation from Flickit

Manual is produced continuously by `ActionGraphInputListener::Fill`. Flickit
uses a separate notification-driven path:

```text
0x82859E70 input notification
 -> GameInputManager::Update 0x82696030
 -> lane update 0x826962D8
 -> PatternNode advancement 0x826974A8
 -> winner selection 0x826972B8
```

`sub_8259B878` separately checks embedded trick patterns at listener offsets
`+420/+432/+444/+456`. The manual producer does not read PatternNodes, winner
scores, gesture spans, or history.

Implementation consequence: held manual control samples the processed stick
without consuming, resetting, waiting for, or synthesizing Flickit
notifications. A genuine Flickit winner and its action-graph owner continue to
arbitrate normally. Existing anticipation uses the recovered strict
`magnitude > 0.9` vertical sectors only before a manual owns the graph; once
the manual owns it, full deflection remains available to ManualBrake.

## Derived implementation: physical pitch and deck-end contact

Static retail analysis exposes `TrucksOrDeckInContact`:

- initializer `0x82F86DB8`
- factory/constructor `0x82BC3118`
- derived vtable `0x8231E900`
- evaluator slot 12 `0x82BA42E0`

It ORs contact bytes reached through the board provider, including nested
offsets `+0xD90/+0xD93`. Which byte is trucks versus deck and whether retail
stores a per-end contact are unresolved. Manual XML does not invoke this named
condition.

The implementation derives a real geometric endpoint contact from the pinned
decoded board mesh rather than equating contact with a button threshold:

```text
nose axle longitudinal       +0.242859 m
nose first-contact vertex    (+0.4453125 m, +0.11695556 m)
nose contact limit           +30.014639 degrees

tail axle longitudinal       -0.243409 m
tail first-contact vertex    (-0.44781494 m, +0.11628418 m)
tail contact limit           -29.635047 degrees
```

For each side, the contact limit is
`atan(rest_height / horizontal_distance_from_support_axle)`. Continuous
`Manual` magnitude scales pitch from zero to that geometry-derived limit. The
projected endpoint height is evaluated every fixed step. Drag is allowed only
when that height reaches the ground plane. The deck is clamped at contact, so
the model does not push it through the floor.

## Proven and derived correction: physics owns the complete manual deck rotation

The retail ground parent begins with:

```xml
<!-- When on ground we always want physics to position the animation -->
<behaviour name="ForcePhysics" force="FORCE_PHYSICS_SKATEBOARD"/>
```

This is `MotionGraphIncludes\ground.xml:3-4`, SHA-256
`8947045346B81235A3A9A7D043A473D0388A0CDA2AA63F16FD485CFD63FB4FF9`.
The complete Riding/Turning/Manual subtree is below that behavior; neither
manual child overrides board authority. Native
`SkateboardBody::UpdatePostPhysics` is
`0x82C07D20..0x82C08968`, and
`SkateboardBody::SetTransform` at `0x82C0B2C8..0x82C0B560` writes the requested
deck transform before applying its common deck delta to the linked bodies.
This proves that the physical deck transform positions the animation on
ground. It does not authorize retaining a second animation-owned deck
rotation.

Direct ABIN world-pose sampling explains the reversed clone result. Across
`M_IDLE_N_0_CYC`, `SKATEBOARD_ROOT` reaches about 16 degrees of geodesic
rotation from its first sample. Across `M_NOSEIDLE_N_0_CYC`, it reaches about
5.6 degrees. Preserving that animated board rotation under physics authority
therefore made the regular manual appear to rock more than the nose manual,
even though the authored rider motion has the opposite and retail-correct
relationship.

The implementation now replaces the complete authored manual-board rotation
with the decoded bind rotation while `FORCE_PHYSICS_SKATEBOARD` is active,
then applies only simulation-owned continuous pitch and roll. This is not a
sway amplitude adjustment: no procedural oscillation or nose multiplier was
added. The rider's neutral cycle keeps advancing, preserving the stronger
authored nose-manual HIPS/torso balance motion and the subtler tail-manual
motion independently of Turn.

Board pitch is applied around the grounded axle after animation evaluation.
Trucks are counter-articulated; only the support pair receives wheel-ground
correction. The board subtree carries trucks/wheels and reparented toe
targets, and onboard foot IK runs after articulation, keeping legs, feet,
targets, board, and wheel presentation in one transform chain.

This geometry model is derived, not a recovered retail collision shape or
torque solver.

## Derived implementation: drag

Authorized retail stop fixtures:

- tail:
  `20260815T232408672Z-sandbox-push-highspeed-tailstop-1b52bf14`
- nose:
  `20260815T232438560Z-sandbox-push-highspeed-nosestop-da367ca2`

The full-strength `ManualBrake` events are observed at tail frame 1177
(`-1.0`) and nose frame 1179 (`+1.0`). Broader settled behavior in
`PROJECT_STATE.md:2953-2965` measures approximately:

- tail: `3.10 m/s²`
- nose: `2.90 m/s²`

Clean-window OLS fits give approximately `2.998 m/s²` and `2.767 m/s²`.
The observer recorded board position/basis, not the retail force or contact
channel. The retail cause of this slowdown is therefore unresolved.

The implementation uses the documented broader settled rates only after the
derived endpoint contact becomes true. It reduces planar speed continuously
toward zero and scales the existing planar velocity vector, preserving travel
direction and both velocity signs. It has no one-frame impulse, yaw correction,
teleport, or vertical velocity change. This path is separate from rolling side
slip, touchdown, powerslide, and footbrake friction.

## Proven correction: decoded animation ownership and Brake stability

The user recording
`C:\Users\Daddy\Videos\2026-08-31 23-43-28.mp4` exposed two presentation
faults without implicating the camera:

- around 6 seconds, the simulated state and speed remain a nose manual while
  the rendered skater travels far ahead of the gameplay-owned actor;
- around 8 seconds, `STATE manual brake` and processed `RS=+0.99` are present
  while `CLIP BTREE_RIDING` is displayed; around 9 seconds the same Brake
  state at `RS=+1.00` displays `M_NOSEBRAKE_N_0_CYC`.

The old separate manual GLB was produced by
`godot\tools\export_private_assets.ps1`, which did not use the shared
rider/board root-motion bake used by the project-local exporter. Bevy then
zeroed horizontal `HIPS` and `SKATEBOARD_ROOT` translation independently after
animation. That stopped actor travel but also erased the authored relative
pelvis motion and distorted the linked leg/board pose.

`tools\build_manual_visual_assets.ps1` now exports the exact 32 reachable
manual leaves and runs `tools\export_bevy_glb.py`. For each frame that exporter
subtracts one shared board-frame horizontal displacement from both `HIPS` and
`SKATEBOARD_ROOT`. Gameplay-owned travel is removed while their authored
relative displacement, foot targets, and board registration remain intact.
The runtime no longer zeroes either bone independently.

Static validation of the rebuilt bank reports:

- 32 actions, 192 locked root-motion curves and 11,124 locked keys;
- maximum anchor horizontal travel `0`;
- maximum toe-target vector error `3.15904617e-06`;
- source-pose matrix error no greater than approximately `5.72e-06`.

In the rebuilt bank, `M_IDLE_N_0_CYC` retains HIPS spans
0.061/0.120/0.027 m and 11.8 degrees, while `M_NOSEIDLE_N_0_CYC` retains
0.050/0.196/0.047 m and 20.8 degrees. This preserves the stronger authored
nose-manual motion without applying world travel twice.

Both retail XML Brake states prove an exact state-owned balance attribute:

```xml
<behaviour name="CreateAttribute" attName="balance" update="-1.0"/>
<behaviour name="CreateAttribute" attName="balance" update="1.0"/>
```

The former port overwrote that value every tick with live Manual (`0.9..1.0`).
Its evidence-gated adapter then correctly rejected the brake selector unless
the sample happened to be exactly `1.0`, causing the observed action on/off
behavior. Brake now retains the XML-authored exact sign while `ManualBrake`
remains attached separately.

The XML `PlayAnimation time` values remain the transition durations. Manual
resource changes now blend from the outgoing action for those exact
`0.1/0.2/0.3/0.5`-second windows instead of dropping through the riding
baseline. The nested Brake child also follows the XML's one-way
`Moving -> Stationary` transition at strict `abs(local Z) <= 0.1`; it is not
reselected back and forth from instantaneous speed.

Finally, Blender inspection of the pinned manual GLB shows its first imported
sample at scene sample 1 on a 60 Hz export timeline, while every decoded
manual source is 30 Hz. Manual seek time now uses the same
`(retail_sample + 1) / 60` conversion already used for the other decoded
OnBoard leaves.

## Unresolved

1. Semantic name and writer of the producer's suppression bit `0x200`.
2. Writer and physical meaning of the byte read by
   `PhysicsWantsManualExit` at evaluator `0x82BA7930`.
3. Exact per-end retail contact representation and contact-point data.
4. A retail manual-specific friction function or coefficient.
5. Whether measured full-brake slowdown is deck scrape, altered wheel
   resistance, another force, or a combination.
6. Exact semantic interpretation of ABIN's generically named final `ANGLE`
   coordinate beyond its derived binding to attached `spin=Turn`.
7. Regular/goofy animation mirroring beyond proven stance-invariant intent
   routing.
8. Dynamic crouch control and the resulting live `DISTTOCOG` provider value.
   Ordinary non-crouched manuals use the proven inherited riding coordinate;
   the crouched selector rows are decoded but intentionally not synthesized.
9. Physical balance failure/torque and advanced manual reverts.

## Awaiting human visual verification

- decoded manual body poses blend without a visible entry/release snap;
- the physics-authored board pitch does not double the clip's fixed pitch;
- support wheels stay planted while the opposite axle rises;
- the correct endpoint reaches, but does not pass through, the ground;
- onboard foot IK prevents foot separation across the analog range;
- full-deflection drag looks continuous at low and high speed;
- no accidental Ollie/Nollie, eaten Flickit gesture, powerslide, or push-cadence
  regression occurs under real controller input.
