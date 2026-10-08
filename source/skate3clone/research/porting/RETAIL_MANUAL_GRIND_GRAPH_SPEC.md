# Skate 3 TU3 manual and grind graph recovery

This document records the first manual/grind recovery pass. It is not an
implementation specification for unresolved physics. XML state behavior and
named binary functions are observed; catalog counts and state groupings are
derived; proposed telemetry and port order are explicitly marked as such.

## Evidence identity

Primary graph fragments:

- `MotionGraphIncludes\Manual\TailManual.xml`
  - SHA-256
    `39BFAAD4FA388C1898FE1CCB0E284084EA58FED427D38C21923D69A6A24001A8`
- `MotionGraphIncludes\Manual\NoseManual.xml`
  - SHA-256
    `6CAD7008AC169B7B1A93F29EF822B09D9CD25D48F0DB68312410BE0100DE6EA3`
- `MotionGraphIncludes\Manual\t_manual_revert.xml`
  - SHA-256
    `D4FDE35A59964B4A7B04486B344484B18B962A5A8E3BF1280B7663F372D3677F`
- `MotionGraphIncludes\Grinds\Grinds.xml`
  - SHA-256
    `89042598DC9BCAC397E7CF43DFEBE37E1C452EE42062029E53BE5A6459B5029E`
- `ActionGraphIncludes\grinding.xml`
  - SHA-256
    `523B3AC16FC0D186A6B348B79EC3DBC8BB440E81EDB787E4368C782FF4653C2D`

All paths are below:

`C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\VerifyCustomAnimation\data\state`

Binary observations use:

`C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\XexDump\disposable\Skate3TU3_dump.community-disposable.i64`

## Manual parent gate

Observed in `MotionGraphIncludes\ground.xml`:

- manual entry requires `ManualEngageTime > 0.2`;
- entry is rejected for the combined case:
  - last state was `InAir`;
  - vertical centre-of-mass velocity is below `-8.0`;
  - surface slope is greater than 45 degrees;
- a `Bumped` transition is available after more than `0.5` seconds in
  `OnGround`;
- the graph creates the `Manual` attribute, raises `IsManualing`, and sets a
  manual-out timer to `0.1` seconds;
- negative `Manual` selects tail manual; the other branch is nose manual;
- tail and nose can transition directly to tail/nose trick branches;
- tail can transition to powersliding;
- slide state has high-priority transitions into tail/nose manual reverts.

The ActionGraph transports:

- `Manual`;
- `ManualBrake`;
- timed `ManualEngageTime`;
- `GrindBalanceX`;
- left/right grind-grab requests.

## Tail manual

Observed states and conditions:

| State | Condition | Animation resource | Blend |
|---|---|---|---:|
| rolling backward | board-local Z speed `< -0.5` | `B_TAIL_MANUAL` | 0.3 s |
| forward or stationary | not board-local Z speed `< -0.5` | `B_TAIL_MANUAL_LOW` | 0.3 s |
| brake moving | absolute board-local Z speed `> 0.1` | `M_BRAKE_N_0_CYC` | 0.2 s |
| brake stationary | not absolute board-local Z speed `> 0.1` | `M_BRAKE_STAT_0_CYC` | 0.5 s |

The cycle attaches `Manual` as `balance` and `Turn` as `spin`. It remains
active only while manual brake is absent and physics does not request a manual
exit. The brake branch forces `balance=-1.0`, attaches `manualbrake`, can
return to cycle when brake is released, and can transition to ground runout.

The two physical tail-brake leaves are 30 Hz, 45 samples each in the
authoritative OnBoard ABIN inventory. The two `B_TAIL_MANUAL*` names are
virtual resources and still require concrete-leaf telemetry.

## Nose manual

Observed states and conditions:

- `Holding` requires `Manual > 0`;
- `Into` plays `B_NOSE_MANUAL_INTO`, blend `0.1`, playback `1.0`;
- release during `Into` returns directly to turning idle;
- `Into -> Cycle` uses `WillExpire 0.05`;
- `Into -> Brake` uses `WillExpire 0.1`;
- cycle can transition to nose-manual revert or out;
- rolling forward at board-local Z speed `> 0.5` uses
  `B_NOSE_MANUAL`, blend `0.3`, and runs `SetManualAngle`;
- backward or stationary uses `B_NOSE_MANUAL_LOW`, blend `0.3`;
- out is selected by `PhysicsWantsManualExit` or loss of positive manual
  intent, plays `B_NOSE_MANUAL_OUT` with a `0.1` blend, then returns to
  turning with `WillExpire 0.1`.

Nose brake:

| State | Condition | Animation resource | Blend |
|---|---|---|---:|
| moving | absolute board-local Z speed `> 0.1` | `S_M_NOSEBRAKE_N_0_CYC` | 0.2 s |
| stationary | otherwise | `M_NOSEBRAKE_STAT_0_CYC` | 0.5 s |

The ABIN inventory contains `M_NOSEBRAKE_N_0_CYC` (45 samples at 30 Hz) and
`M_NOSEBRAKE_STAT_0_CYC` (60 samples at 30 Hz). The XML's
`S_M_NOSEBRAKE_N_0_CYC` is not an exact physical ABIN name, so its runtime
leaf must be observed before binding it.

## Manual reverts

The shared revert template:

- selects BS from `SlideBs180` and FS from `SlideFs180`;
- uses a `0.2` animation blend;
- sets `RevertDir=+1` for BS and `RevertDir=-1` for FS;
- uses mirrored score augmentation;
- returns to the source manual or turning with `WillExpire 0.01`.

Virtual resources:

- `B_TAIL_MANUAL_FS_REVERT`
- `B_TAIL_MANUAL_BS_REVERT`
- `B_NOSE_MANUAL_FS_REVERT`
- `B_NOSE_MANUAL_BS_REVERT`

## Manual-angle binary behavior

Observed static identities:

- `0x82BC95F0` constructs `SetManualAngle`;
- its attribute name is `manual_angle`;
- the recovered instance update is at `0x82BA8C60`;
- `0x82BB34D8` updates `PowerSlideManualAtt`.

`SetManualAngle` reads the `Manual` intent, evaluates a point graph, reads two
runtime-configured limits, conditions two persistent float values, and
publishes `manual_angle`. The point-graph data and the two live configured
limits are not yet recovered, so the port must not replace this with an
arbitrary stick-to-pitch curve.

`PowerSlideManualAtt` checks the manual intent against exactly `0.0` and writes
the `balance` attribute on the qualifying branch. The exact surrounding
slide/manual interaction still requires context telemetry.

## Grind graph authority and inputs

Observed at the grind parent:

- board authority is `FORCE_PHYSICS_SKATEBOARD`;
- `CreateGrindAttributes` and `ControlGrindCrouch` run at the parent;
- the ActionGraph transports crouch, mirrored `GrindBalanceX`, left/right
  grind-grab requests, and double-grab state;
- trick-out routing differs for tail, nose, square, and sideways 90-degree
  grind groups;
- dark grind trick-out temporarily uses animation board authority in the
  separate dark-grind trick branch.

## Grind catalog

Derived from parameter-expanded includes in `Grinds.xml`:

- 60 grind-template instantiations;
- 54 unique grind names;
- 38 unique top-level animation resources.

The 54 names cover regular and board-flipped variants of:

- 5-0, 50-50, nosegrind;
- crook/overcrook;
- salad;
- smith/feeble;
- willy/overwilly;
- boardslide/lipslide;
- noseslide/tailslide;
- noseblunt/blunt;
- darkslide.

The catalog includes frontside/backside and the applicable board-flipped
prefixes. Physics, not animation naming, is the source of the selected grind
identity.

## Generic grind cycle

Observed template behavior:

- `IsGrinding(grindName)` selects the state;
- the base animation blends for `0.3` seconds, normally from the current
  frame and with posture application;
- `GrindControlFade` receives:
  - animation attribute `DistToCog`;
  - animation attribute `twist`;
  - MotionGraph intent `GrindBalanceX`;
  - fade time `2.5`;
- ordinary in-air exits use channel blends of `0.3` seconds for most
  templates;
- some grab or dark-grind paths override the in-air channel blend to
  `1.0` or `1.5` seconds;
- trick transitions remain available from the cycle.

## Grind grabs

Observed common sequence:

1. `Into`: selected by the relevant hand intent or double grab while not
   already crouched enough; sets hand busy, ends the gesture, and blends the
   into leaf for `0.3` seconds.
2. `GrabCycle`: entered at `WillExpire 0.01` with a `0.05` blend, or directly
   from a matching current grab with a `0.3` blend.
3. `Out`: selected when the hand/double-grab intent is absent, blends the out
   leaf for `0.1`, and returns to the base cycle.

The graph creates `Grabbing=1.0` and
`PhysGrindGrabMinHeight=0.2`. Board and dark grinds additionally instantiate
single- and double-grab templates with generated `G_BSLIDE_*` or
`G_DSLIDE_*` leaf names.

## Grind physics critical path

Observed function identities:

- `0x82D69F80` `TrajectorySelector::CalculateGrindTrajData`
- `0x82D6A168` `TrajectorySelector::FindBestGrind`
- `0x82D6A398` `TrajectorySelector::ConsiderGrindPrimitive`
- `0x82D6A840` `TrajectorySelector::AnalyzeAndAdjustTrajectory`
- `0x82D712E0` `GrindAirAdjust::UpdateGrindAdjust`
- `0x82D71430` `GrindAirAdjust::ProjectPoints`
- `0x82D71F40` `GrindAirAdjust::CalculateAngleBetweenDeckZandGrind`
- `0x82D72B40` `GrindAirAdjust::InitTargets`
- `0x82D41100` `PhysState_Grind_Boardslide::Enter`
- `0x82DEF1C8` `PhysOutConditioner_Grinds::NameGrind`
- `0x82D8A318` `GrindManager` constructor

`FindBestGrind` traverses a candidate container and selects a minimum scalar
candidate subject to a configured threshold, copies a result block, marks the
result valid, and removes the selected candidate. The scalar's semantic name
and result layout remain unresolved.

`NameGrind` exposes the six-field grind chromosome composition:

| Field | Observed labels |
|---|---|
| approach | `A-FS`, `A-BS` |
| board end | `NOSE`, `TAIL` |
| alignment | `TWST`, `STRT` |
| height | `HI`, `LO` |
| travel/rotation | `FOR`, `BAK`, `F180`, `B180`, `UNK` |
| contact family | `5050`, `BOARD`, `TIP`, `5_O`, `BACKSLASH`, `NA` |

The function computes an index from these six fields and looks up the final
canonical name in a static table. This is evidence that grind recognition
must be ported as a data-driven chromosome classifier, not a handful of
angle if-statements.

## Required telemetry

Before implementation of physical manuals or grinds, capture:

- raw and conditioned `Manual`, `ManualBrake`, `ManualEngageTime`,
  `manual_angle`, `balance`, and `spin`;
- configured manual-angle point graph and live angle limits;
- wheel/contact state and the exact `PhysicsWantsManualExit` reason;
- every six-field grind chromosome plus selected canonical name;
- every considered grind primitive, rejection reason, candidate scalar, and
  selected result;
- grind spline/primitive identity, projected points, tangent, deck alignment,
  contact points, velocity, and `GrindBalanceX`;
- concrete animation leaves and weights behind all virtual `B_*` resources.

## Port order

1. Recover manual point graph, angle limits, and manual-exit physics.
2. Extract physical manual leaves and implement tail/nose graph timing.
3. Add deterministic manual flat-pad fixtures.
4. Instrument the six-field grind chromosome and candidate selector.
5. Build a deterministic straight rail and ledge map.
6. Port 50-50, boardslide, 5-0, and nosegrind physics first.
7. Expand through the data-driven catalog, grabs, dark grinds, and trick-outs.

No manual/grind physics constants should be tuned from visual appearance.
