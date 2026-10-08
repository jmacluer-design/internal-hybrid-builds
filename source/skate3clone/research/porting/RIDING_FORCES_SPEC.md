# TU3 Riding Force and Heading Port

## Scope

`src/riding_forces.rs` ports the portions of Skate 3 TU3's onboard
riding-force pipeline that are currently reproducible from static evidence:

- the exact 48-byte queued-force record and 21-record admission gate;
- the top-level three-way `UpdatePostPhysics` branch and queue lifetime;
- the mode-change counter and active-time input to
  `CalculateHeadingAdjustFactor`;
- `ApplyingBodyTilt`'s enable/disable commands;
- `SettingBodyTilt`'s signed-target, two-stage clamped discrete conditioner.

It does **not** synthesize the still-unresolved force solver, heading
quaternion construction, point-graph samples, runtime clamp attributes, or
physics-object field meanings. Those dependencies are typed evidence inputs
in the Rust API.

## Reference identity

- Executable:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\TitleUpdateStage\default.xex`
- Skate 3 TU3 / community symbol identity:
  `skate3-tu3-1.05-community`
- Size: 6,615,040 bytes
- SHA-256:
  `1DB39496585C521D17A2137804F42CF73EBED2B32CAC166EC42DBF772F4DCF7F`

Primary generated recompilation artifacts:

| Artifact | SHA-256 |
| --- | --- |
| `skate3_animation_research_recomp.72.cpp` | `AAE7A98DE678461D79A975A6E7B54938884DD78E88C4D73087D9FCA5F33006EC` |
| `skate3_animation_research_recomp.75.cpp` | `D8C3ADDBD8CB3E9C266068099204EC0350DAB0E337856EE9D29B3A714A27D260` |
| `skate3_animation_research_recomp.90.cpp` | `EB8F900B847879F44C40A76BCB0380D7859E32AA266E8EA97EFE9D78A2E0C627` |

Addresses below are guest executable addresses for that build. IDA Pro
9.3.26.0213 was used read-only; the database was closed without saving.

## Evidence ledger

### `AddSkateboardForce` — `0x82C03EF0`

Observed:

- Queue count is `(end - begin) / 48`.
- A count greater than or equal to 21 causes an immediate return.
- The record stores the raw force type at byte `0`, one 16-byte vector at
  byte `16`, and a second 16-byte vector at byte `32`.
- Appending advances `end` by 48 bytes.

Port:

- `SkateboardForce` is `repr(C, align(16))` and statically asserted to be
  48 bytes.
- `SkateboardForceQueue` accepts exactly 21 records, preserves order, and
  leaves the queue unchanged when a 22nd record is rejected.
- Numeric `eSkateboardForceType` variants and both vector meanings remain
  raw because they are not recovered.

### `UpdatePostPhysics` — `0x82C02138`

Observed:

1. A precheck result is written to object byte `+291`.
2. If the call ending at `0x82C02168` returns true:
   - object byte `+289` is set;
   - heading adjustment receives the physics-block vector at `+64`;
   - result code `2` is returned.
3. Otherwise, a second path requires all of:
   - the first tested component 1 is greater than zero;
   - physics-block `+400` component 1 is less than zero;
   - object byte `+290` is clear.
   This path adjusts heading from physics-block `+128`, clears one body
   channel, and returns code `1`.
4. The normal path submits the queued data through the consumer called at
   `0x82C02348`, runs the finalizer at `0x82C02350`, and returns code `0`.
5. Every path resets the force-vector begin/end pointers to the empty position
   and restores the capacity pointer to `begin + 1008` (`21 * 48`).

Port:

- `plan_post_physics` preserves this branch priority and produces an explicit
  operation plan.
- Result enum members are called `Variant0/1/2`; semantic labels would be
  speculative.
- `complete_force_queue` distinguishes records submitted on the normal path
  from records discarded when either early path resets the queue.

Unresolved:

- the precheck call's gameplay meaning;
- body-channel identity;
- the force consumer at `0x82C07D20`;
- all contact/impulse behavior behind those calls.

### `PostPhysics_AdjustHeading` — `0x82C05988`

Observed:

- The function consumes the selected heading vector and board transform block
  at physics-block offset `+752`.
- Static constants include `2π` (`0x82139A50`) and `1/(2π)`
  (`0x82139A60`).
- It transforms and normalizes a direction, derives an angle, performs a
  bounded angular adjustment, constructs updated transform data, and submits
  it through `0x82C0B2C8`.

Unresolved and therefore not ported:

- the exact axis/angle convention behind `0x8296EC98`;
- semantic identities of the transform rows;
- the live maximum-adjustment-rate source;
- the final physics write's structure contract.

`UNRESOLVED_HEADING_ADJUSTMENT` keeps these omissions explicit. No planar yaw
approximation is presented as retail parity.

### `CalculateHeadingAdjustFactor` — `0x82D8A828`

Observed:

- Raw primary mode changes in the inclusive range 400–404 add:
  - `400`: 50
  - `401`: 0
  - `402`: 50
  - `403`: 20
  - `404`: 50
- The counter then decays by one without going below zero.
- The byte written at object offset `+477` is true when the decayed counter is
  at or below 151.
- A float at `+468` accumulates fixed delta from owner field `+2604` while
  secondary mode is 400 or primary mode is 701; otherwise it resets to zero.
- That float is passed into the point-graph sampler at `0x82481E10`, and its
  result is stored at object offset `+440`.

Port:

- `HeadingAdjustFactorState::step` reproduces the mode switch, decay,
  threshold flag, and curve abscissa.
- `HeadingFactorCurveRequest` requires a separately resolved retail curve
  sample. The point graph's live data is not in the static snapshot.
- Constructor defaults are caller-supplied through `from_retail_snapshot`
  because the relevant retail initialization was not recovered.

### `ApplyingBodyTilt` and `SettingBodyTilt`

Constructor evidence:

- `ApplyingBodyTilt`: `0x82BC7408`, vtable `0x8231F814`
- `SettingBodyTilt`: `0x82BC74A8`, vtable `0x8231F850`

The vtables expose the behavior methods:

- `ApplyingBodyTilt` begin `0x82BA8800`: invokes the physics toggle with `1`.
- `ApplyingBodyTilt` end `0x82BA8850`: invokes the physics toggle with `0`.
- `SettingBodyTilt` state-data constructor `0x82BA8B40`: initializes value,
  first difference, and active flag to zero.
- `SettingBodyTilt` update `0x82BA88A0`:
  1. reads the physics application-enabled predicate;
  2. on a false-to-true edge, resets value and first difference to zero;
  3. if disabled, emits no setter call;
  4. selects a signed board-transform scalar;
  5. multiplies it by a point-graph sample evaluated from the absolute
     physics scalar at field `+204`;
  6. clamps `(target - value)` symmetrically by the first selected limit;
  7. clamps `(clamped_error - first_difference)` by the second selected limit;
  8. adds that result to first difference, then adds first difference to value;
  9. submits the new value through the physics setter.

The selected limit pair comes from runtime attribute offsets `1896/1900` when
the raw physics state equals `2`, otherwise `1888/1892`. Their live values and
semantic names are unresolved.

Port:

- `ApplyingBodyTiltCommand` represents only the observed enable writes.
- `BodyTiltState::step` ports the exact per-update conditioner and rising-edge
  reset.
- Point-graph samples, sign predicates, board scalar, and clamp pairs are
  explicit inputs. `BodyTiltFrameEvidence::Unresolved` returns a typed error
  instead of silently selecting placeholder values.
- No `dt` multiplier is added because the recovered conditioner has none.

## Automated verification

The module contains focused tests for:

- 48-byte/aligned force layout;
- 21-record queue admission and non-mutating rejection;
- post-physics branch priority and all gate terms;
- queue reset on all three result paths;
- exact mode-transition additions and counter decay;
- active-time accumulation/reset conditions;
- body-tilt rising-edge reset, sign selection, both clamp stages, discrete
  integration, disabled behavior, and unresolved-input rejection.

No game, renderer, emulator, or visual session is launched by these tests.
