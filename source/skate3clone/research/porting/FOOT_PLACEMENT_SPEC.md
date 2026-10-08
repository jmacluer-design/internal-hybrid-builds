# TU3 foot-placement coordination specification

## Scope

This specification covers the coordination boundary between Skate 3 TU3's
animation graph, compact OnBoard toe targets, SkeletonIK part weights, and
ground-contact ownership. It supports:

- planted feet during onboard idle;
- the same authored target path during carving;
- push-foot release, ground contact, and replant without guessed timing;
- offboard stand/walk/run/sprint contacts driven by recovered external markers.

It does not claim to recover the complete leg solver, raycast ABI, foot-bone
indices for the Bevy rig, sole offsets, or clip-event times. Those values remain
typed inputs in `src/foot_placement.rs`.

No visual session, Computer Use session, or runtime debugger attachment was
used for this work package. Blender 5.1 was used in background mode only to
measure exported target registration.

## Build and artifact identity

| Artifact | SHA-256 |
|---|---|
| TU3 loaded image `default_82000000_011B0000.bin` | `F4AA113EB541BFBA03DBC108CF5AB43F58C965B20FA3B82F9C40938A0AD841C4` |
| Community disposable IDA database | `C15ADE171038CEE5E00B7C5FFE4E7FBD21EECEE2C6FF1EEC676E792408DFDF8B` |
| `MotionGraphIncludes/Push.xml` | `AFB7BA9281F2A8883E76B8F80394DA8D4CDAE36396E96093EEDC750ADB593532` |
| `MotionGraphIncludes/offboard.xml` | `4E1C238A574BBEBAC1DD50088067232C1E045CD47A8F93166874F2F23F4042D8` |
| exported Bevy GLB | `50FD4FF6300A7EA49B135E6B1AD110EB9101CC4472B87471C87358FB90B14EE3` |
| exported root-motion sidecar | `885C80DABE7F778F3589B7A28594EEE13225852CC8FABC7DDDB64C85319BDD05` |
| Blender source used for the target probe | `4FF0BE811B0229B51F04F1B13B5A1D87D4041ECFA265E5E226FA036A4D9E61F4` |

The retail XEX identity recorded by the wider project is
`1DB39496585C521D17A2137804F42CF73EBED2B32CAC166EC42DBF772F4DCF7F`.

## Static-analysis evidence

Exact loaded-image ranges and hashes:

| Function/range | Address range | Bytes | Range SHA-256 |
|---|---:|---:|---|
| `SkeletonIK::Init` | `0x82BED688..0x82BED780` | 248 | `892C09EA9CCF33C8011765418606591982ADA80D79A4DC5480E9A9E511369416` |
| SkeletonIK mode update | `0x82BEDCF8..0x82BEDF08` | 528 | `D41212BA0961E1DD114CA80E6D2896F8592A7CDFA65E973815A6D7A93BAC0D78` |
| SkeletonIK target preparation | `0x82BEDF08..0x82BEE390` | 1160 | `4D462B8BF35787CD2060B8D739FF769258497ECA88B8BEF2647794A37B020C8E` |
| SkeletonIK weight update | `0x82BEEC00..0x82BEEEB8` | 696 | `F0FCFA148419CDFE42FE2D28B39503432058F1A8B43D0F3E1C77490ED4813E46` |
| `SkeletonIK::BlendTransforms` | `0x82BEEEB8..0x82BEFC80` | 3528 | `BEE607A321AB5A9B9DDEAE98F9A61DCE2BC1434D6A076225855A10120E74CCB1` |
| `Skeleton::ProcessAnimAttributes` | `0x82BDA0D0..0x82BDCC28` | 11096 | `CDD75EB51D2D6CB684BC4879F318EEF6AFBAAEB9DE42AF17BE7E4D30D61294D9` |
| `SkeletonIK::CalculateInitialPartTransforms` | `0x82D633B0..0x82D63A38` | 1672 | `AE3638C345D783F913F3F7D2EACEB078559628BBE8EF85F3DF04CC17FEC80FB4` |
| `FootPlantManager::StartFootPlantGround` | `0x82D704B0..0x82D70CE0` | 2096 | `D3CFFF5257E7AA4E525E6C2D76C10C84CA1A5291CC250FACFF81A3F9C2D20557` |
| `FootPlantManager::CalculateLanding` | `0x82D93618..0x82D93DF0` | 2008 | `584ABA610D0AC7B5A7978F0D588A5C55AD5C1E9B33A6CF377C8A0182265ADE7A` |

### Observed part order and target lookup

`SkeletonIK::Init` resolves four named targets in this order:

1. `LeftToeBase_Reparented`
2. `RightToeBase_Reparented`
3. `LeftHand_Reparented`
4. `RightHand_Reparented`

It stores their hierarchy indices at object offsets `+0x34C`, `+0x350`,
`+0x354`, and `+0x358`.

The compact OnBoard hierarchy and matched runtime target traces establish:

| SkeletonIK part | Compact channel | Exported target |
|---:|---:|---|
| 0 | 33 | left reparented toe |
| 1 | 32 | right reparented toe |
| 2 | 34 | left reparented hand |
| 3 | 35 | right reparented hand |

Only parts 0 and 1 are represented by this module.

### Observed per-part state

`SkeletonIK::BlendTransforms` runs a four-iteration loop. In each iteration it
reads:

- primary part weight from object `+0x1D4 + part * 4`;
- transition part weight from object `+0x1E4 + part * 4`;
- raw mode from object `+0x1F4 + part * 4`;
- the prepared part matrices using a 64-byte part stride.

The mode updater at `0x82BEDCF8` reads and writes the same weight/mode arrays.
The four raw modes are values 0 through 3. The code proves transitions between
these modes and separate per-part weights, but current evidence does not assign
complete human-readable semantics to every state or recover all rate inputs.
`RawSkeletonIkMode` therefore preserves the numeric identity without inventing
names.

The blend path explicitly compares the primary weight against zero and uses
`1.0 - weight`. `IkWeight` rejects non-finite values and values outside
`[0, 1]`; it does not clamp caller input.

### Observed data flow

`Skeleton::ProcessAnimAttributes` builds a 432-byte SkeletonIK input record,
copies it through `DataIn::operator=` at `0x82BD7128`, then calls the
SkeletonIK preparation, weight update, blend, and output stages. The existing
Bevy `foot_ik.rs` is the downstream leg-solve adapter. The Wave 4 module does
not duplicate that solver; it produces a typed target/weight/contact command
for it.

## Animation and graph evidence

### Onboard authored targets

Channels 32 and 33 are board-parented compact OnBoard animation channels. They
are animated in idle and push leaves rather than being fixed deck coordinates.
This is why the port must consume the actual channel matrices during carving
and pushing instead of selecting generic nose/tail foot positions.

A background Blender probe measured toe-to-target translation distance at
every exported frame:

| Action | Frames at 60 Hz | Left min/max (m) | Right min/max (m) |
|---|---:|---:|---:|
| `R_IDLE_HCOM_000` | 1..101 | `0.000304415 / 0.003539299` | `0.000994283 / 0.004220677` |
| `R_PUSHLSP_HSTR_N_0_INTO` | 1..41 | `0.000179724 / 0.005974031` | `0.000614838 / 0.006932661` |
| `R_PUSHLSP_HSTR_N_0_CYC1` | 1..13 | `0.001467597 / 0.005837130` | `0.001784642 / 0.006178682` |
| `R_PUSHLSP_HSTR_N_0_CYC2` | 1..55 | `0.001146410 / 0.007629174` | `0.000615879 / 0.008032484` |
| `R_PUSH_H_N_OUT_MIDFRONT` | 1..21 | `0.001218705 / 0.005779599` | `0.000422114 / 0.007171270` |
| `R_PUSHLSP_HSTR_MONGO_0_INTO` | 1..33 | `0.000823398 / 0.006280074` | `0.000855393 / 0.007891974` |
| `R_PUSHLSP_HSTR_MONGO_0_CYC1` | 1..9 | `0.000534919 / 0.005015967` | `0.002987680 / 0.005988097` |
| `R_PUSHLSP_HSTR_MONGO_0_CYC2` | 1..55 | `0.000334466 / 0.007140803` | `0.000871253 / 0.010323000` |
| `R_PUSH_H_M_N_OUT_MIDFRONT` | 1..19 | `0.001453825 / 0.007268572` | `0.001991281 / 0.010908740` |

These measurements are evidence that both authored target channels continue
through the push sequence. They are not a contact-height classifier.

### Push graph

`MotionGraphIncludes/Push.xml` proves these graph phases:

- `PushStart`
- `PushContact`
- `PushCycle`
- `PushEnd`

Start, Contact, and Cycle use sequence transitions with `WillExpire
InTime="0.01"`. PushEnd returns to Idle with `WillExpire InTime="0.1"`.
PushEnd also invokes `PushOut` with an explicit `isRightFoot` Boolean.

Those values are graph transition windows, not proven push-foot release or
replant events. `foot_placement.rs` exposes them as documentation constants but
never converts them into contact transitions.

`MongoPushFootToFar` is constructed at `0x82BC5A40`. Its exact runtime
distance test is not yet recovered, so it is not used as a replant threshold.

### Carving

Carving remains in the OnBoard animation/physics ownership path and continues
to use the compact toe targets. The module distinguishes Idle and Carving for
telemetry, but both consume the supplied left/right target matrices and
observed SkeletonIK values directly. It applies no procedural board-space
offset.

### Offboard gait

`MotionGraphIncludes/offboard.xml` applies `BipedCadence` in non-stand
locomotion and `MatchCadence` while entering stand. The graph selects forward
walk, run, and sprint cycle families across flat, ramp, stair, and thin-ground
states.

The XML does not expose foot-contact event times. Current ABIN/telemetry work
also has not proven the native FootPlantManager's exact event markers,
ray length, sole offset, acquire/release hysteresis, or weight curves.
Offboard contacts are therefore event-driven external inputs. The coordinator
does not infer contacts from the cadence quarter, foot height, or animation
normalized time.

## Port contract

`FootPlacementCoordinator::step` is atomic and deterministic:

- ticks must strictly increase;
- Onboard Idle/Carving require both correctly mapped compact targets;
- the non-pushing support foot remains on its authored board target;
- the push foot keeps receiving its authored target matrix each frame, while
  release/surface/replant ownership changes only on an external marker;
- changing Push Start/Contact/Cycle/End phase or OffBoard gait does not discard
  an existing contact; only a role change or external event changes ownership;
- PushEnd reports `PushReplantMarker` as unresolved until a proven
  `ReplantBoard` event arrives;
- offboard feet begin unresolved and require independent contact markers;
- surface targets must be declared world-space and already contain any proven
  sole offset;
- marker sequences must strictly increase per foot;
- maintaining a surface cannot silently switch surface identity;
- invalid input leaves coordinator state unchanged.

The output includes, per foot:

- selected target matrix and explicit target space;
- primary and transition weights;
- optional raw SkeletonIK mode;
- board, surface, released, or unresolved contact ownership;
- last external marker.

## Evidence classification

### Observed

- Compact channel 33 maps to the left reparented toe target and channel 32 to
  the right.
- SkeletonIK target lookup and part iteration order.
- Four raw per-part modes.
- Primary and transition weight arrays and their object offsets.
- Four push graph phases and their `WillExpire` windows.
- BipedCadence and MatchCadence placement in the offboard graph.
- Both exported toe-target channels remain authored throughout the measured
  idle, regular-push, and mongo-push actions.

### Derived

- The Bevy coordination boundary can preserve target matrices, weights, raw
  modes, and contact ownership independently of the downstream two-bone solve.
- Carving and pushing must update from the current compact-channel sample
  rather than a fixed board-space foot anchor.
- A surface identity change requires a new acquire event to keep telemetry and
  lifecycle semantics unambiguous.

### Inferred port policy

- Strictly increasing tick and event-sequence validation.
- Atomic rejection of malformed frame input.
- Explicit `Unresolved` ownership when retail contact evidence is missing.
- World-space declaration for caller-resolved surface targets.

These are conservative port contracts, not claimed retail thresholds.

## Unresolved work

- Bevy bone/entity mapping for left/right upper leg, lower leg, foot, toe, and
  target entities.
- Exact runtime matrix convention adapter between the TU3 row-vector target
  basis and Bevy transforms.
- Native FootPlantManager raycast/query ABI.
- Foot sole offsets and orientation alignment to surface normals.
- Push-foot release, ground-strike, and board-replant clip-event markers.
- The complete semantics of SkeletonIK raw modes 0..3.
- Live per-part weight-rate inputs and any frame-rate dependence.
- Offboard walk/run/sprint contact markers, slope variants, stair contacts,
  acquire/release hysteresis, and audible-step coupling.
- Final-matrix comparison of Bevy's two-bone solve against
  `SkeletonIK::BlendTransforms`.
