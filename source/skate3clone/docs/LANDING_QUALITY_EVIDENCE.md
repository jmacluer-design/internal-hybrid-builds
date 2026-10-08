# Landing quality and animation evidence

This checkpoint covers Skate 3 TU3 landing classification and authored landing
animation routing. It does not modify post-touchdown planar velocity or
friction.

## Proven

### Native landing-type producer

The TU3 air-to-ground classifier at `0x82DE61D0` runs when the filtered
conditioner changes from Air to Ground. It projects the approach velocity and
board-forward vector onto the collision plane and publishes:

| PhysOut_Animation field | Meaning |
|---:|---|
| `+80` | combined landing error |
| `+84` | absolute lateral approach speed |
| `+88` | absolute raw alignment dot |
| `+92` | landing error signed by completed rotation |
| `+96` | landing-type code |
| `+167` | result-valid byte |

The exact type gates are:

- approach speed below `2.0` produces code 0;
- a projected-vector length product below `1e-5` produces code 0;
- completed rotation uses a strict `abs(rotation) > 0.1` test;
- heading sine below `0.05` produces code 0 unless the retained Spin condition
  applies;
- heading sine from `0.05` through values below `0.2` produces code 3 unless
  the retained Spin condition applies;
- a provisional Spin is retained in that near-straight range only when the
  absolute combined error is strictly greater than `0.3`.

The remaining code-1/code-2 decision uses the signs of completed rotation,
heading cross product, and alignment dot. Its error is the maximum of the
authored Twist and SideSpeed point graphs when completed rotation exceeds
`0.1`; otherwise it uses SideSpeed.

The exact `physics_animation/default.xml` point graphs are:

```text
Twist input = (abs(rotation) - 0.1) * 0.14492753
x = 0, 0.26058629155, 0.5618891716, 1
y = 0, 0.50694441795, 0.8125, 1

SideSpeed input = (absolute lateral speed - 0.1) * 0.1010101
x = 0, 0.2286584973, 0.5518292785, 0.8338413835
y = 0, 0.2152778059, 0.81944441795, 1
```

Retail samples both with the piecewise-linear function at `0x82481E10`.
The orientation byte at SkateboardMotion `+273` reverses the normalized
board/cross tests.

### Graph routing

`HasLandingType` (`0x82BA7450`) obtains the child at provider `+56`, reads its
word at `+96`, and compares it with the requested code.

| Provider code | Landing.xml route | Animation |
|---:|---|---|
| 0 | Straight fallback | `BLEND_LAND` |
| 1 | Sketchy | `B_LAND_SKETCH` |
| 2 | Spin | `B_LAND_NICE` |
| 3 | Straight fallback | `BLEND_LAND` |

All three authored animations enter with a `0.15` second blend. Straight calls
`ChooseRandomLanding(3)`, Sketchy calls `ChooseRandomLanding(5)`, and Spin does
not call it.

### Authored animation tree

`OnBoard.abin` recovers the complete nested type-7/type-8 tree:

```text
B_LAND_NICE / B_LAND_SKETCH
  SPIN: Frontside(-1) <-> BLEND_LAND(0) <-> Backside(+1)

each side
  DISTTOCOG: LCOM <-> HCOM

HCOM
  AVGVELY: LIMP(2.6800000667) <-> HIMP(6.0)
```

`BLEND_LAND` has the same `DISTTOCOG` and `AVGVELY` nesting. The exact physical
clip coordinates are encoded in `src/landing_animation.rs`. Type-8 random
selectors use their first/default child when the current integer attribute has
no authored matching record; they do not clamp or modulo at that layer.

`SetLandingData` (`0x82BB0180`) writes the child `+92` value to `SPIN`, applying
the sign returned by its orientation query, and copies child `+72` to
`DISTTOCOG`. The 29 measured charge-sweep `+72` values are encoded as fixtures
in `src/sim.rs`. The recovered `AVGVELY` touchdown projection remains the third
tree input.

The OnBoard ABIN catalog proves six Nice physical leaves (indices 1315–1320)
and thirty Sketch physical leaves (1327–1356), all at 60 Hz. The private Bevy
export contains all 309 actions. Its GLB SHA-256 is
`2B7E452A38CF17A9CD13FACFAD223177DD078C1BFE613B6C551A8B536798BA19`.

## Inferred integration

- The clone's established positive body-spin convention is Backside-positive,
  matching the recovered physical tree's `BS=+1` coordinate. This is a
  source-level convention mapping, not a newly selected threshold.
- Integer charge-frame `DISTTOCOG` values are captured. Fractional charge
  positions use the project's existing adjacent-fixture interpolation.
- This integration supplies the recovered classifier on the existing regular,
  flat-ground carrier. Reversed-orientation and non-flat contact inputs are
  represented by the classifier API but are not yet supplied by that carrier.

## Unresolved

- The semantic name of the orientation-interface boolean read by
  `SetLandingData`; calling it “fakie” would exceed the evidence.
- `HasTiltToLargeForPreland`, `PhysicsWantsRunout`, and `CanLandOnBoard`
  producer internals.
- Inclined-surface `DISTTOCOG` production and non-flat collision-normal wiring.
- Landing-adjust transforms, board offsets, and IK attachment details.

## Awaiting human visual verification

- Forward landings above the native 2.0 m/s gate remain visibly Straight and
  do not snap to idle.
- A genuine board/velocity mismatch follows Sketchy rather than code-3
  Straight fallback.
- Deliberately completed Frontside and Backside rotations select the matching
  Nice/Sketch side of the SPIN tree.
- Low/high `DISTTOCOG` and `AVGVELY` mixtures remain continuous through the
  authored 0.15-second handoff, without foot, board, or root-pose discontinuity.

These checks are visual validation, not a claim of visual parity.
