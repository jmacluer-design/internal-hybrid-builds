# Wave 2 WP1 Ground Provider Specification

## Scope

This work package supplies a deterministic, synchronous analytic surface
provider for later board-physics integration. It does not integrate with
`main.rs`, `sim.rs`, or `board.rs`, and it does not define rigid-body response,
friction, restitution, wheel suspension, release hysteresis, or retail timing.

The implementation is `src/ground_provider.rs`. It deliberately has no Bevy
dependency, allowing direct focused compilation while the module remains
unwired.

## Reference identity

The analyzed executable is:

- path:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\TitleUpdateStage\default.xex`
- project identity: Skate 3 TU3 / community symbol-map label
  `skate3-tu3-1.05-community`
- size: 6,615,040 bytes
- SHA-256:
  `1DB39496585C521D17A2137804F42CF73EBED2B32CAC166EC42DBF772F4DCF7F`

`C:\Users\Daddy\Documents\Skate3Recomp\game\default.xex` has the same SHA-256.
Addresses below are guest executable addresses from that build.

Read-only IDA data checks used IDA Pro 9.3.26.0213 and
`Skate3TU3_dump.i64`. The database was closed without saving. Existing IDA
decompile JSON for `0x82C02840` and `0x82D85D08` reports “no function at
target”; it is retained as negative evidence rather than treated as a
decompilation.

## Evidence ledger

| Identity | Symbol | Primary static artifact | Corroborating artifact |
| --- | --- | --- | --- |
| `0x82C02840` | `Skateboard::CalculateGroundPos` | `skate3_animation_research_recomp.75.cpp`, `sub_82C02840` | community map; native read-only caller in `skate3_native_collision.cpp`; XML coverage |
| `0x82D76F80` | `SurfaceQuery::GetResult` | `skate3_animation_research_recomp.89.cpp`, `sub_82D76F80` | community map; caller `HandPlantTrajectorySelector::Update` at `0x82D66948`; `PredictionResults` accessors |
| `0x82D85D08` | `SurfacePhysics::SurfacePhysics` | `skate3_animation_research_recomp.90.cpp`, `sub_82D85D08` | community map; XML coverage; read-only IDA data values |
| `0x82D8C8F0` | `Reckoning::UpdateGroundStatesFixedHeading` | `skate3_animation_research_recomp.90.cpp`, `sub_82D8C8F0` | community map; repeated crouch/ollie XML coverage |
| `0x82D2D988` | `PredictionResults::GetContactPosition` | `skate3_animation_research_recomp.85.cpp`, `sub_82D2D988` | community map; call sites in the surface-query consumer |
| `0x82D2D9E8` | `PredictionResults::GetGroundNormal` | `skate3_animation_research_recomp.85.cpp`, `sub_82D2D9E8` | community map; call sites in the surface-query consumer |

Relevant artifact roots:

- symbols:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\symbols`
- generated recompilation:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\generated`
- IDA artifacts:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering`
- XML coverage:
  `C:\Users\Daddy\Documents\Skate3Research\harness\results`

The CLIXML coverage sets record function-entry coverage, not arguments,
returns, or per-frame field values. For example,
`block-crouch-vs-ollie.xml` includes `0x82C02840` and `0x82D8C8F0` in all five
crouch/ollie pairs. `0x82D85D08` appears in selected idle/ollie/control runs.
None of the inspected XML sets includes `0x82D76F80`, so no runtime-value claim
is made for `SurfaceQuery::GetResult`.

## Observed behavior

### `Skateboard::CalculateGroundPos` at `0x82C02840`

- The ABI uses a hidden vector return pointer in `r3` and `Skateboard*` in
  `r4`. The native collision observer independently calls it that way and
  reads three finite `f32` values from the return buffer.
- The function obtains a transform/basis through `Skateboard + 292`, then an
  additional `+752`.
- Four nested candidate vectors are read through object offsets
  `+76`, `+172`, `+268`, and `+364`; each final vector load is at an additional
  `+16`.
- The four transformed candidates are summed and multiplied by the scalar at
  guest address `0x820C6D98`.
- A read-only IDA data read proves that scalar is exactly `0.25f`.
- One component of the averaged local value is clamped using zero and selected
  candidate-component values before the final transform is written to the
  return vector.
- `PhysicalPlayerHiLOD::Update1_ProcessInput` at `0x82DB4048` calls the
  function and stores the resulting vector at a player-state offset.

The four nested objects have not been typed. Calling them four wheels, four
contact patches, or four suspension points would exceed the evidence.

### `SurfaceQuery::GetResult` at `0x82D76F80`

The observed output contract is:

- `SurfaceQuery + 240` is tested first as a completion/availability byte.
- The embedded prediction payload begins at `SurfaceQuery + 16`.
- A vector at embedded-payload offset `+48` is compared component-wise against
  zero. The all-nonnegative result controls payload validity.
- When complete and valid:
  - output `+0` receives
    `PredictionResults::GetContactPosition(this + 16)`;
  - output `+16` receives the 16-byte vector at `SurfaceQuery + 32`;
  - output `+32` receives the 32-bit value at `SurfaceQuery + 148`;
  - output `+36` receives byte `1`;
  - the function returns Boolean true.
- When complete but invalid, both output vectors and the 32-bit value are
  zeroed, output `+36` is zero, and the function still returns Boolean true.
- When incomplete, the same output fields are zeroed, output `+36` is zero,
  and the function returns Boolean false.

`HandPlantTrajectorySelector::Update` at `0x82D66948` corroborates the
two-level state: it first checks the Boolean return, then separately checks
output byte `+36`.

`PredictionResults::GetContactPosition` independently tests the same
all-nonnegative sentinel at payload offset `+48`, returning payload vector
`+0` when valid and zero otherwise.

The output vector at `+16` is suitable for a contact-normal slot in the port,
but its exact retail field name is not proven. Notably,
`PredictionResults::GetGroundNormal` validates with the same sentinel and
returns payload vector `+32`, not payload vector `+16`. The distinction between
those two retail vectors remains unresolved.

### `SurfacePhysics::SurfacePhysics` at `0x82D85D08`

- Constructor `r3` is the destination object, `r4` is `PhysOut const*`, and
  `r5` is `ProcessedPhysIn*`.
- It stores those pointers at object offsets `+0` and `+4`.
- It constructs six 16-byte helper/query-like fields at offsets
  `+8`, `+24`, `+40`, `+56`, `+72`, and `+88`, each with a different opaque
  64-bit selector.
- It initializes five three-float groups at offsets `+104`, `+116`, `+128`,
  `+140`, and `+152`.
- Read-only IDA data reads prove the initial triplet is
  `(0.5f, 0.30000001192092896f, 0.4000000059604645f)`.
- The third float of each group is subsequently replaced by a value obtained
  through an opaque shared selector/config lookup.
- The first two floats of the five groups are then copied from offsets
  `+224/+228` of five constructed helper objects.

No evidence identifies these floats as friction, restitution, damping, probe
length, or wheel constants. The analytic provider therefore carries only a
surface identity and does not expose the triplet as physics parameters.

### `Reckoning::UpdateGroundStatesFixedHeading` at `0x82D8C8F0`

- The symbol signature is
  `Reckoning::UpdateGroundStatesFixedHeading(Vector3 const&, Vector3 const&)`.
- The function normalizes multiple vectors and has explicit zero-length
  selection paths.
- It invokes:
  - `SpeedWobble::CalculateSpeedWobble` at `0x82D8BF58`;
  - `PointGraphEval::Evaluate` at `0x82481E10`;
  - `Math::AngleBetweenVectors` at `0x8296EBB0` multiple times;
  - `PhysicsUtility::ClampVectorWithinMaxLength` at `0x82BD3D90`.
- It copies source vectors from input offsets `+16..+44` into reckoning fields
  around `+1376` and `+1472`, and publishes computed vectors around `+1392`
  and `+1488`.
- It does not call `SurfaceQuery::GetResult` in its recovered body.

This supports treating reckoning as a downstream consumer/filter of ground
state and heading, not as the collision provider itself.

## Derived port requirements

The evidence supports these requirements without importing a rigid-body
model:

1. A consumable query state must be separate from contact validity.
2. A valid contact needs a finite point, a finite normalized contact normal,
   and stable surface identity.
3. Finite surfaces are needed for contact loss; infinite planes alone cannot
   represent edge departure.
4. Triangle queries need deterministic boundary behavior so crossing a shared
   seam does not produce an artificial miss.
5. Ground tracking must preserve the last state while a query is pending.
6. A completed miss must be able to release contact, and a later valid result
   must be able to reacquire it.

## Inferred implementation contract

These choices are port-side behavior and are not retail claims:

- `GroundVec3` is a dependency-free three-float type.
- `GroundProbe` is a normalized finite ray segment with a maximum distance.
- `GroundProbe::downward` uses negative Y because the current project is Y-up.
- Planes and triangles are queried analytically and two-sided.
- Returned normals are oriented against the probe direction.
- Möller-Trumbore triangle intersection is used with an implementation-only
  `1.0e-6` floating-point guard.
- Degenerate triangles and zero/non-finite normals are rejected.
- The nearest nonnegative hit wins.
- Exact-distance ties retain the earliest inserted primitive.
- Synchronous provider results are always complete; a miss is complete with
  no contact.
- `GroundStateTracker` changes state immediately on completed results. It has
  no grace frames, distance hysteresis, or velocity-dependent release rule.
- Accepted zero-distance hits are canonicalized to positive IEEE zero for
  bitwise repeatability.

## Public module surface

`src/ground_provider.rs` exposes:

- `GroundVec3`
- `SurfaceId` and `PrimitiveId`
- `GroundProbe`
- `AnalyticPlane`, `AnalyticTriangle`, and `AnalyticSurface`
- `SurfaceContact`
- `SurfaceQueryResult`
- `GroundProvider`
- `GroundStateTracker` and `ContactTransition`

`GroundProvider::calculate_ground_position` is a narrow later-integration
helper. It returns the nearest analytic contact point and does not reproduce
the four-candidate internal `Skateboard::CalculateGroundPos` object walk.

## Validation

The module was formatted with Rust 2024 `rustfmt` and compiled directly,
without changing `Cargo.toml`:

```powershell
rustc --edition 2024 --test src\ground_provider.rs -o $env:TEMP\skate3_ground_provider_tests.exe
& $env:TEMP\skate3_ground_provider_tests.exe --nocapture
```

Eight tests pass:

1. level-ground point, distance, normal, and identity;
2. positive and negative 5-degree and 15-degree slopes;
3. 15-degree bank;
4. coplanar triangle seam crossing;
5. contact loss, pending preservation, and reacquisition;
6. invalid geometry rejection and normal validity;
7. 4,096 bitwise-repeat queries plus exact tie ordering;
8. origin contact with canonical positive-zero distance.

The crate-wide Cargo test target does not compile this module yet because no
central module declaration was added, as required by work-package ownership.

## Unresolved retail items

- Exact class/field identities of the four candidates used by
  `Skateboard::CalculateGroundPos`.
- Exact semantic name of `SurfaceQueryResult + 16`, and its relationship to
  `PredictionResults::GetGroundNormal` returning payload `+32`.
- Meaning of the 32-bit `SurfaceQueryResult + 32` value beyond stable surface
  or query identity.
- Producer and scheduling path that sets `SurfaceQuery + 240`.
- Meaning of the six `SurfacePhysics` helper selectors.
- Meaning of the five `SurfacePhysics` float triplets.
- Retail plane/triangle sidedness and tie ordering.
- Retail contact-loss distance, grace frames, reacquisition threshold, and
  any velocity/heading conditions.
- How the reckoning outputs at `+1392/+1488` map to later board and skeleton
  consumers.
- Dynamic value traces for `SurfaceQuery::GetResult`; inspected XML coverage
  did not execute that entry point.
