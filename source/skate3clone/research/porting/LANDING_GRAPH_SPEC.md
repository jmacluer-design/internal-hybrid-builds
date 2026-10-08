# Skate 3 TU3 landing graph specification

## Scope

This specification covers the recovered native landing-quality producer, the
deterministic selector, and the authored `Land` / `LandingOnBoard` MotionGraph
boundaries. Contact admission, tilt/runout production, landing adjustment, and
IK remain separate provider boundaries.

The Rust implementation is:

- `C:\Users\Daddy\Documents\skate3clone\src\landing_graph.rs`

## Build and source identity

Analyzed TU3 mapped dump:

- `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\XexDump\default_82000000_011B0000.bin`
- SHA-256:
  `F4AA113EB541BFBA03DBC108CF5AB43F58C965B20FA3B82F9C40938A0AD841C4`
- mapped base: `0x82000000`

Authored graph sources:

| File | SHA-256 |
|---|---|
| `MotionGraphIncludes\Landing.xml` | `A1B7B4C6FA6BE8E1AA64B42543398A5B95DC67C038E0FD386292D437D460D602` |
| `MotionGraphIncludes\onboard.xml` | `DECB3D47FFBA18DBF317AE8612BD4C903DBDDFFD7DD2AED273DB41DCBC45AD26` |
| `MotionGraphIncludes\air.xml` | `672871717605A2AD6D592FD24C5270E462493507B01EBF5F7D443B8494B2F7F0` |

## Landing type selector

### Observed

`HasLandingType` constructor:

- `0x82BC5198..0x82BC52B0`
- 280 bytes
- SHA-256:
  `AA31EF8B78AB6B1C82DE86AE67C20D246F36F438447D2B3DA498B34AE18970F7`
- runtime vtable: `0x8231F42C`
- object field: selected type at `+28`

The constructor reads attribute `landingType` and writes:

| XML value | stored word |
|---|---:|
| `straight` or unrecognized | 0 |
| `sketchy` | 1 |
| `spin` | 2 |

The code arrives at this mapping through exact string comparisons against the
mapped strings at `0x8231D47C`, `0x8231D488`, `0x8231D494`, and
`0x8231D49C`.

`HasLandingType` evaluator:

- `0x82BA7450..0x82BA74D8`
- 136 bytes
- SHA-256:
  `918C43D8DBFC252D7BAAD4178FC5EF29B6D84B1AA73255148504209D3FFE69D0`

Its dataflow is:

1. `BehaviorContext+4 -> actor`
2. `actor+1808 -> SkaterAnim provider`
3. provider vtable slot `+92`
4. returned object `+56`
5. landing-type word `+96`
6. compare with condition word `+28`

`Landing.xml` tests `spin`, then `sketchy`, then has an unconditional
`Straight` child. Therefore the implemented selector maps provider code 2 to
Spin, 1 to Sketchy, and every other observed word to the authored Straight
fallback. Code 3 from the native classifier therefore routes to Straight.

### Native producer

The air-to-ground classifier is `0x82DE61D0`. It runs only when the filtered
conditioner changes from Air to Ground, projects approach velocity and
board-forward onto the contact plane, and publishes:

| PhysOut_Animation field | Value |
|---:|---|
| `+80` | combined error |
| `+84` | absolute lateral approach speed |
| `+88` | absolute raw alignment dot |
| `+92` | error signed by completed rotation |
| `+96` | landing-type code |
| `+167` | valid byte |

Exact gates and authored curve inputs:

- projected-vector length product below `1e-5`: code 0;
- approach speed below `2.0`: code 0;
- completed rotation branch: strict `abs(rotation) > 0.1`;
- Twist input: `(abs(rotation) - 0.1) * 0.14492753`;
- SideSpeed input: `(absolute lateral speed - 0.1) * 0.1010101`;
- near-straight gate: `abs(heading sine) < 0.2`;
- straight gate: `abs(heading sine) < 0.05`;
- provisional Spin survives the near-straight gate only when
  `abs(combined error) > 0.3`.

The point coordinates are recorded in
`docs/LANDING_QUALITY_EVIDENCE.md` and sampled by retail's piecewise-linear
function at `0x82481E10`. The orientation byte at SkateboardMotion `+273`
reverses the normalized board/cross tests. The implementation preserves every
strict comparison at its native boundary.

### Derived

The Spin state uses the resource named `B_LAND_NICE`; this is not renamed to a
different physical classification in the port. `LandingQuality::Spin`
preserves the XML state identity and its animation plan preserves the resource.

## Land admission and wipeout boundary

### Observed

The authored `Land` state requires:

```text
PhysFilteredState == ground
AND NOT HasTiltToLargeForPreland
```

The urgent `WipeOut` transition inside `Land` requires
`PhysicsWantsRunout`.

Verified provider boundaries from prior project evidence:

- `CanLandOnBoard`
  - initializer `0x82F87A50`
  - factory `0x82BC4FB8`
  - vtable `0x8231EED0`
  - evaluator `0x82BA5D30`
  - result is provider-child byte `+316`
- `HasTiltToLargeForPreland`
  - initializer `0x82F87B50`
  - factory `0x82BC52B0`
  - vtable `0x8231F1E0`
  - evaluator `0x82BA69F0`
  - delegates to actor interface `+1800`, vtable slot `+28`
- `IsLandingOnBoard`
  - initializer `0x82F86938`
  - factory `0x82BC2598`
  - vtable `0x8231E53C`
  - evaluator `0x82BA16F0`
  - compares the physics-state word with 503
- on-board `IsLanding`
  - initializer `0x82F89200`
  - factory `0x82BC8DE0`
  - vtable `0x8231FB28`
  - evaluator `0x82BACBE0`
  - actor interface `+1800`, slot `+88`, mode 1
- alternate landing mode
  - evaluator `0x82BACC30`
  - actor interface `+1800`, slot `+88`, mode 0
- `PhysicsWantsRunout`
  - initializer `0x82F86D78`
  - factory `0x82BC3078`
  - vtable `0x8231E99C`
  - evaluator `0x82BA44B8`
  - reads provider result `+28`, byte `+78`

These wrappers expose retail contact-admission, tilt, and runout decisions.
Their producer internals remain external. Landing type itself is now produced
by the recovered numeric classifier described above.

## Authored landing graph

### Observed common Land behaviours

- create `PlayingLanding`
- score augmentation `Landing`
- `IsLanding`
- force `FORCE_PHYSICS_SKATEBOARD`
- attach `FakieTurn` as `turn`
- `SetLandingData`
- `SetDistComToBoard attribute="disttocog" adjustForVel="true"`
- disable tricks for exactly 0.3 seconds

### Observed quality states

| State | Type precondition | Random behaviour | Animation | Blend | Crouch early-exit gate |
|---|---|---|---|---:|---:|
| Spin | type 2 / `spin` | none | `B_LAND_NICE` | 0.15 s | parent time > 0.3 s |
| Sketchy | type 1 / `sketchy` | `ChooseRandomLanding(5)` | `B_LAND_SKETCH` | 0.15 s | parent time > 0.4 s |
| Straight | fallback | `ChooseRandomLanding(3)` | `BLEND_LAND` | 0.15 s | parent time > 0.2 s |

Every crouch early exit targets riding idle with a 1.0-second channel blend
and `useChannelFromWeights=true`.

### Authored animation trees

`OnBoard.abin` type-7 records recover the complete nested animation topology:

```text
B_LAND_NICE / B_LAND_SKETCH
  SPIN: Frontside(-1) <-> BLEND_LAND(0) <-> Backside(+1)
each side:
  DISTTOCOG: LCOM <-> HCOM
HCOM:
  AVGVELY: LIMP(2.6800000667) <-> HIMP(6.0)
```

`BLEND_LAND` uses the same `DISTTOCOG` then `AVGVELY` nesting. Physical clip
records contain the exact coordinates used to sort and interpolate every
child. `SetLandingData` at `0x82BB0180` supplies signed `SPIN` from child `+92`
and `DISTTOCOG` from child `+72`.

Type-8 records recover the random-sequence topology. Straight has three
variants and Sketchy has five. A selector value with no authored record loads
the first/default child; it is not clamped or reduced modulo by the animation
tree. The separate player-owned `ChooseRandomLanding` behaviour supplies the
bounded value for Straight and Sketchy.

Other authored exits:

| Target | Gate | Transition override |
|---|---|---|
| Grinding | target eligibility | inherited |
| Trick | target eligibility | inherited |
| Push | parent time > 0.1 s and target eligibility | 1.0 s channel blend |
| Anticipation | target eligibility and no `absorbLand` | 0.8 s channel blend |
| Sliding | target eligibility | 0.5 s channel blend |
| Ground user dismount | parent time > 0.1 s and target eligibility | inherited |
| OnBoard | `WillExpire InTime="0.1"` | inherited |

The XML does not assign a relative priority among these default-priority child
and parent exits. The implementation selects a sole eligible exit, but returns
a typed competing-transition result if several are eligible in one evaluation.
It does not invent document-order arbitration.

## LandingOnBoard preland

### Observed

Entry requires:

```text
CanLandOnBoard
AND OBTimeToLand > 0.05
```

The comparison is strict. While active:

- losing `CanLandOnBoard` has an authored high-priority WipeOut transition;
- the normal target is `Land`;
- the default animation is `B_AIR_CYC`, blend 0.2 seconds,
  `transitionUnder=true`;
- animation blend input is `from="lastAnim" attribute="disttocog"`;
- `OffboardBodyTweakBlend`, `LandOnBoard`, `ControlAirLegExtension`, and
  `ApplyingBodyTilt` run as behaviours.

The physical leg-extension distance, body tweak, IK attachment, and landing
offset writes are not implemented here because their exact ABI and constants
remain unrecovered.

## Landing-adjust functions

The following exact functions were inspected as transform/adjustment
boundaries:

| Function | Range | Bytes | SHA-256 |
|---|---:|---:|---|
| `UpdateLandingAdjust` | `0x82BD9028..0x82BD9878` | 2128 | `5FAAC4BA6FCEA39B5CDF9567DF75DD64B8709213564573FBEECA8826C2EFEA7D` |
| `UpdateLandingOnSkateboardAdjust` | `0x82BDCC28..0x82BDCFB0` | 904 | `2DBB3E8D7450DA9ED76E81FA8040A469BA40B13685FFD626678C123C93636F8E` |
| `UpdateSkateboardOffsetTransform` | `0x82BDD630..0x82BE2798` | 20840 | `095802524FE2907ABC599019F7874DDC7FCE97E503A9E76431243F7BADC7B635` |

### Observed

These functions consume actor/provider state, configured floats, transforms,
and stored adjustment fields. `UpdateLandingAdjust` writes the adjustment
block around skeleton offsets `+16520..+16544`;
`UpdateLandingOnSkateboardAdjust` writes stored landing-on-board values around
`+16392/+16400`; `UpdateSkateboardOffsetTransform` consumes those fields and
updates the offset-transform path.

### Unresolved

- semantic names and units for all adjustment-block fields;
- exact matrix/vector convention at the Bevy boundary;
- provider object layouts beyond the directly observed accesses;
- contact manifold ABI;
- IK targets and offsets;
- semantic name of SetLandingData's orientation-interface boolean;
- inclined-surface `DISTTOCOG` production;
- numeric physics thresholds behind CanLandOnBoard,
  HasTiltToLargeForPreland, and runout.

No provisional 34/42-degree gates from older owned-engine work are promoted to
TU3 values. They are absent from this module.
