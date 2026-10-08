# Skate 3 TU3 manual-balance conditioner and exit inputs

## Scope and result

This work package recovers the `SetManualAngle` conditioner, its retail point
graph and limits, the negative-only powerslide attachment, the Manual and
ManualBrake intent producer, and the observable manual-out/physics-exit input
paths. The implementation is isolated in `src/manual_balance.rs`; no state
graph, simulation, manifest, or visual integration was changed.

The conditioner, curve, clamps, and intent thresholds are statically proven.
The physical causes that write the final `PhysicsWantsManualExit` byte are not
yet proven, so the implementation accepts that value as a typed external input
instead of inventing physics rules. Timer-provider virtual methods are recorded
but are not modeled beyond the proven active test and XML duration.

No game process or visualization was launched for this work package. IDA was
opened read-only through idalib and closed with `save=False`. VLT extraction was
performed into a temporary directory.

## Evidence identities

Primary executable evidence:

- TU3 XEX:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\TitleUpdateStage\default.xex`
  - SHA-256:
    `1DB39496585C521D17A2137804F42CF73EBED2B32CAC166EC42DBF772F4DCF7F`
- Loaded-memory image:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\XexDump\default_82000000_011B0000.bin`
  - SHA-256:
    `F4AA113EB541BFBA03DBC108CF5AB43F58C965B20FA3B82F9C40938A0AD841C4`
- Disposable community-symbol IDA database:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\XexDump\disposable\Skate3TU3_dump.community-disposable.i64`
  - SHA-256:
    `C15ADE171038CEE5E00B7C5FFE4E7FBD21EECEE2C6FF1EEC676E792408DFDF8B`

Retail VLT evidence:

- `runtime\game\data\big\db.big`
  - SHA-256:
    `B5C5967A2B31B28B4A03B1232061228D3D2C5A84DFC3E27E19E28F8DA53BA87A`
- `data\db\skaterschema.vlt`
  - SHA-256:
    `63B9E652B7918D811EC135915B926E687727B98511A3D47D38A0381A34406B9C`
- `data\db\skaterschema.bin`
  - SHA-256:
    `DFEEDB74A430CFA9A1BEC2DD1D456D624EBCF95C962D254F5F874722A40081B4`
- `data\db\skatercollections.vlt`
  - SHA-256:
    `3B7DBD062BB1C906A085514355AFFF35CFA22F486AE70820C5AD1A42A7AAB25B`
- `data\db\skatercollections.bin`
  - SHA-256:
    `FDCF291B497BAA38BA2BA7C1280086B193B69368710A1C4978C8C035606C2E91`
- Attribulator name table `Keys\Keys.txt`
  - SHA-256:
    `01D62C182BF1F2D31F45C6D7CF971C25B3DB2D965370DE14C0DF5CC30B91480C`
- Generated diagnostic export
  `Collections\anim_motion\manual.xml`
  - SHA-256:
    `B68CD9720E67CE9147BD60CB353A27946C485FD46488F4A2953A200CAE7E7A72`
  - This XML is a lossless diagnostic rendering of the identified VLT/BIN
    pair, not a separately authoritative game input.

Authoritative state XML evidence under
`research\reverse-engineering\VerifyCustomAnimation\data\state`:

- `MotionGraphIncludes\ground.xml`
  - SHA-256:
    `8947045346B81235A3A9A7D043A473D0388A0CDA2AA63F16FD485CFD63FB4FF9`
- `MotionGraphIncludes\Manual\NoseManual.xml`
  - SHA-256:
    `6CAD7008AC169B7B1A93F29EF822B09D9CD25D48F0DB68312410BE0100DE6EA3`
- `MotionGraphIncludes\Manual\TailManual.xml`
  - SHA-256:
    `39BFAAD4FA388C1898FE1CCB0E284084EA58FED427D38C21923D69A6A24001A8`
- `ActionGraphIncludes\onboardgeneral.xml`
  - SHA-256:
    `4AA7470AEF5227D2C546EC760B0B67BB18E7C1C54F957CAE0B0F790CC0FE4EA4`

## Observed executable behavior

### SetManualAngle construction and lifecycle

- Constructor: `0x82BC95F0`
  - Allocates 48 bytes.
  - Installs vtable `0x8231F88C`.
  - Stores the `manual_angle` FastString in the definition at `+0x1C`.
- Vtable `0x8231F88C`:
  - slot 12: `0x82BA8C48`, Begin
  - slot 13: `0x82BA8C60`, Update
- Begin, `0x82BA8C48`:
  - Writes exact `+0.0f` to instance payload `+0x08`.
  - Writes exact `+0.0f` to instance payload `+0x0C`.
  - Update proves these fields are current angle and current velocity,
    respectively.
- Retail state ownership:
  - `TailManual.xml` instantiates the behaviour only in
    `Cycle/RollingBackwards`, under strict local skate Z `< -0.5`.
  - `NoseManual.xml` instantiates it only in
    `Holding/Cycle/RollingForwards`, under strict local skate Z `> 0.5`.
  - Nose INTO, both LOW speed children, Brake, OUT, and Revert do not own or
    update this behaviour. Re-entering an owning child therefore runs Begin
    again instead of retaining a conditioner charged by another state.
- Saved target trace
  `20260815T230727813Z-sandbox-push-nose-manual-hold-5e09be07/result.json`
  records `0x82BA8C60` once per active StateGraph frame (`1113..1165`,
  subject to observer loss), alongside the once-per-frame intent producer.
  The port executes the per-update clamps on the recovered 60 Hz animation
  clock, not on every 120 Hz physics step.

### SetManualAngle update

At `0x82BA8C60`:

1. Manual is queried through `HasIntent`.
2. The active animation-motion configuration is reached through global
   `0x830CFDA4`, then `+0x160`, then `+0x04`.
3. `PointGraphEval::Evaluate` at `0x82481E10` is called with:
   - count `8`
   - X values at configuration `+0x4C0`
   - Y values at configuration `+0x4E0`
   - input `abs(Manual)`
4. The graph result is signed with the Manual input. PPC `fsel` treats both
   `+0.0` and `-0.0` as the non-negative branch.
5. Per-update velocity clamp is read at configuration `+0x708`.
6. Per-update acceleration clamp is read at configuration `+0x70C`.
7. New velocity is stored at payload `+0x0C`, new angle at payload `+0x08`,
   and the angle is published as `manual_angle`.

The directly observed arithmetic is:

```text
target = sign_like_manual(graph(abs(manual)))
desired_velocity = clamp(target - angle, -max_velocity, +max_velocity)
acceleration = clamp(
    desired_velocity - velocity,
    -max_acceleration,
    +max_acceleration
)
velocity = velocity + acceleration
angle = angle + velocity
```

There is no delta-time load or multiply in this behavior. Both limits are
per-Update values.

### PointGraphEval

`0x82481E10` observes these endpoint and interpolation rules:

- input below the first X returns the first Y;
- input greater than or equal to the last X returns the last Y;
- otherwise, find the first upper point whose X is greater than the input;
- interpolate as
  `((upper_y - lower_y) / (upper_x - lower_x)) *
  (input - lower_x) + lower_y`;
- the retail evaluator returns the upper Y when the selected X span is
  non-positive.

The port requires strictly increasing configured X values, so malformed or
duplicate points fail validation rather than depending on the final fallback.

### PowerSlideManualAtt

- Update: `0x82BB34D8`
- Vtable: `0x82320418`, slot 13
- It queries Manual and publishes the same value as `balance` only when:
  - the intent is present, and
  - `Manual < 0.0f` is true.
- Exactly `-0.0f`, `+0.0f`, and every positive value produce no write.

### Manual and ManualBrake intent producer

- Caller:
  `Sk8::Skater::ActionGraphInputListener::Fill`, `0x825999F0`
- Call site: `0x8259A9D4`
- Producer: `0x8259BA28`
- Inputs at the call:
  - `f1`: upstream conditioned magnitude from caller stack `+0x84`
  - `r4 + 0x0C`: signed axis used to choose nose/tail sign
  - `r5`: flags; integer bit 9 is tested by
    `extrwi ..., 1, 22`
  - `r6`: output `Sk8::Intents`

Observed output rules for finite producer inputs:

```text
if suppression bit 9 is clear:
    if signed_axis > 0: Manual = +conditioned_magnitude
    if signed_axis < 0: Manual = -conditioned_magnitude
    if signed_axis == 0: Manual is absent

    if conditioned_magnitude > 0.9:
        unsigned_brake = (conditioned_magnitude - 0.9) * 9.999998
        ManualBrake = +unsigned_brake when signed_axis > 0,
                      -unsigned_brake otherwise
```

Constants and identities:

- threshold load at `0x8259BA50`:
  `0x820997B8 = 0x3F666666 = 0.9f`
- gain load at `0x8259BA60`:
  `0x822F9274 = 0x411FFFFE = 9.999998f`
- Manual FastString global: `0x830BE900`
- ManualBrake FastString global: `0x830BE468`
- dynamic initializers:
  - Manual: `0x82F84D18`
  - ManualBrake: `0x82F84D30`

`ActionGraphIncludes\onboardgeneral.xml` then transports:

- AG Manual to MG Manual;
- AG ManualBrake to MG ManualBrake;
- AG Manual duration to MG ManualEngageTime.

The computation that produces the caller's conditioned magnitude and signed
axis is outside the recovered helper and remains a separate input-conditioning
question.

## Observed retail configuration

The VLT export identifies the fields as:

- `manual_balance`, `Sk8::PointGraphData8`
- `manual_clamp_vel`, float
- `manual_clamp_acc`, float

For `anim_motion/manual`, raw VLT values are:

```text
manual_balance X:
  00000000 3E000000 3E800000 3EC00000
  3F000000 3F200000 3F4E0ADF 3F800000

manual_balance Y:
  00000000 00000000 00000000 00000000
  00000000 00000000 00000000 3F800000

manual_clamp_vel = 3D23D70A = 0.04f
manual_clamp_acc = 3CA3D70A = 0.02f
```

Decoded graph points:

| X | Y |
|---:|---:|
| `0.0` | `0.0` |
| `0.125` | `0.0` |
| `0.25` | `0.0` |
| `0.375` | `0.0` |
| `0.5` | `0.0` |
| `0.625` | `0.0` |
| `0.8048534` (`0x3F4E0ADF`) | `0.0` |
| `1.0` | `1.0` |

The exported collection locations corroborate the runtime offsets:

- graph begins at VLT location `0x0003FEB8`;
- velocity clamp is at `0x00040100`, exactly `0x248` bytes later;
- runtime `+0x708 - +0x4C0` is also `0x248`;
- acceleration follows both at `+4` bytes.

## Manual-out timer and physics-exit paths

### Registration and XML placement

- `RegisteredManualOutTimerIsActive`
  - registration initializer near `0x82F87E50`
  - evaluator `0x82BA78B0`
  - evaluator vtable `0x8231F534`, slot 12
- `PhysicsWantsManualExit`
  - registration initializer near `0x82F87E90`
  - evaluator `0x82BA7930`
  - evaluator vtable `0x8231F568`, slot 12
- `SetManualOutTimer`
  - registration initializer `0x82F898C0`
  - constructor `0x82BCA058`
  - vtable `0x8232090C`
- `UpdateManualOutTimer`
  - registration initializer `0x82F89900`
  - constructor `0x82BCA128`
  - vtable `0x82320948`

Authoritative `ground.xml` placement:

- Riding owns `UpdateManualOutTimer`.
- Manual owns `SetManualOutTimer length="0.1"`.
- Therefore the active graph explicitly configures
  `0x3DCCCCCD = 0.1f`.

The SetManualOutTimer constructor contains a separate compiled parser default
near `0x822F95D8` (`0.1659999937f`), but the active XML does not use that
fallback.

### Timer provider calls

The owner reached from the behavior context stores the timer provider at
`+0x708`.

- `RegisteredManualOutTimerIsActive`, `0x82BA78B0`
  - calls provider vslot `+0x9C`;
  - returns strictly `remaining > 0.0f`.
- `SetManualOutTimer` slot 14 callback, `0x82BB9158`
  - loads parsed length from behavior definition `+0x1C`;
  - tail-calls provider vslot `+0xA4` with that float.
  - Comparison with the SetManualAngle vtable identifies slot 14 as the
    behavior's end/exit callback.
- `UpdateManualOutTimer` slot 13 callback, `0x82BB91A8`
  - calls provider vslot `+0x5C`;
  - when false, invokes the state/behavior callback reached through its context
    and then provider vslot `+0xA8`.
- `UpdateManualOutTimer` slot 14 callback, `0x82BB9260`
  - tail-calls provider vslot `+0xA0`.

The exact semantic names of provider vslots `+0x5C`, `+0x9C`, `+0xA0`,
`+0xA4`, and `+0xA8`, beyond their observed call/return behavior above, are not
assigned without telemetry or a concrete provider type.

### PhysicsWantsManualExit input

At `0x82BA7930`:

1. Reach the physics-exit provider at owner `+0x710`.
2. Call provider vslot `+0x5C`.
3. Read a pointer at returned object `+0x38`.
4. Return the byte at nested object `+0xA8`.

This is the exact boolean consumed by state XML:

- Nose Manual Out activates when this byte is true **or** Manual is not
  strictly positive.
- Tail Manual Cycle and Brake require this byte to be false.
- ManualBrake is independently used by both nose and tail brake states.

The writer of the nested `+0xA8` byte and the physical conditions represented
by it have not been recovered. The port therefore exposes
`physics_wants_manual_exit: bool` and does not infer wheel contact, pitch,
speed, or timeout causes.

## Derived behavior

The following conclusions are derived directly from multiple observed
instructions or from executable/XML/VLT alignment:

- Payload `+0x08` is the conditioned manual angle and `+0x0C` its velocity:
  Begin zeros both, Update reads/writes both, and Update publishes `+0x08`.
- Runtime configuration `+0x4C0/+0x4E0/+0x708/+0x70C` maps to
  `manual_balance`, `manual_clamp_vel`, and `manual_clamp_acc`: field spacing,
  graph width, VLT names, and VLT locations all agree.
- SetManualOutTimer's slot 14 callback runs on behavior/state exit: the slot
  position matches the recovered Begin/Update/End layout, and Manual owns the
  behavior in XML.
- Conditioner results depend on the number and order of Updates, not elapsed
  seconds. Partitioning an identical ordered update stream into batches cannot
  change its result.

## Inferred or deliberately unresolved

- The human-readable names of timer-provider virtual methods are inferred only
  at a broad lifecycle level; exact names are withheld.
- The physical meaning and writer set for the final physics-exit byte are
  unresolved.
- The upstream formula that supplies `conditioned_magnitude`, the signed-axis
  structure, and suppression bit 9 to `0x8259BA28` is unresolved.
- PPC unordered/NaN behavior is not claimed. The port rejects non-finite
  configuration and intent inputs, while all recovered retail data is finite.
- No generalized tail-manual Out predicate is introduced: the authoritative
  tail graph uses physics-exit and ManualBrake gates differently from the
  explicit Nose Manual Out state.

## Telemetry still required

Minimal runtime telemetry to close the remaining questions:

1. During an active manual, record the live configuration pointer and the raw
   bits at `+0x4C0..+0x4FF`, `+0x708`, and `+0x70C` to corroborate which
   `anim_motion` collection is selected at runtime.
2. Watch writes to the object returned by provider `+0x5C`, nested
   `+0x38 -> +0xA8`, and record contact, board pitch, speed, and manual state at
   each edge. This is required before implementing physics-exit causes.
3. Trace provider vslots `+0x9C`, `+0xA0`, `+0xA4`, and `+0xA8` across entry,
   exit, and several update ticks to recover timer units, decrement source, and
   cleanup semantics.
4. At the `0x8259A9D4` producer call, record `f1`, `r4+0x0C`, and `r5` together
   with raw controller samples to recover the upstream magnitude/axis
   conditioner and suppression-bit producer.

None of these unresolved items is replaced by a guessed curve or coefficient
in `src/manual_balance.rs`.
