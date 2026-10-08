# TU3 Skateboard Body Topology and Post-Physics Spec

## Scope

This is the Wave 3 WP2 evidence ledger for the standalone implementation in
`src/skateboard_body.rs`. It describes only body identity, joint/drive
connectivity, wheel-compression aggregation, reflected truck placement, and
authority-safe pose publication. It does not specify a collision solver,
contact generation, forces, mass properties, or presentation integration.

## Build identity and evidence

The executable evidence is the TU3 Xbox 360 memory dump:

- File:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\XexDump\default_82000000_011B0000.bin`
- Mapped base: `0x82000000`
- Size: `18,546,688` bytes
- SHA-256:
  `F4AA113EB541BFBA03DBC108CF5AB43F58C965B20FA3B82F9C40938A0AD841C4`

The function map and instruction behavior were checked in a read-only,
in-memory IDA 9.3 session using a private temporary copy of the community
database. The shared database was not saved or modified. PPC/VMX instructions
were corroborated against:

- Generated recompilation:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\generated\skate3_animation_research_recomp.76.cpp`
- Symbol index:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\symbols\skate3-tu3-1.05-community.index.json`

The community database input was:

- File:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\XexDump\disposable\Skate3TU3_dump.community-disposable.i64`
- SHA-256:
  `C15ADE171038CEE5E00B7C5FFE4E7FBD21EECEE2C6FF1EEC676E792408DFDF8B`

The extracted presentation rig used only to resolve physical left/right/front/
back naming was:

- File: `assets/private/skater_push.glb`
- SHA-256:
  `50FD4FF6300A7EA49B135E6B1AD110EB9101CC4472B87471C87358FB90B14EE3`

## Exact function ranges

| Function | TU3 range |
| --- | --- |
| `SkateboardBody::UpdatePostPhysics` | `0x82C07D20..0x82C08968` |
| `CalculateAverageWheelCompressions` | `0x82C08968..0x82C08C28` |
| `CreateTriangleDeck` | `0x82C09290..0x82C0A2A0` |
| `AddTriangle` | `0x82C0A2A0..0x82C0A6F8` |
| `CreateTrucks` | `0x82C0A6F8..0x82C0AA78` |
| `CreateWheels` | `0x82C0AA78..0x82C0ADF0` |
| `InitializeTransforms` | `0x82C0ADF0..0x82C0B2C8` |
| `CreateDrives` | `0x82C0B770..0x82C0B9C0` |
| `SetTruckDriveFrames` | `0x82C0B9C0..0x82C0BC90` |
| `CalcTruckTransforms` | `0x82C0BC90..0x82C0C088` |
| `SetDriveFrames2` | `0x82C0C088..0x82C0C268` |
| `CreateJoints` | `0x82C0C268..0x82C0CF60` |
| `CreateWheelDrives` | `0x82C0CF60..0x82C0D330` |

## Observed

### Bodies and transform records

- Part transform records have a `0x60`-byte stride.
- There are seven initialized transforms.
- The transform/body indices are:

| Index | Body |
| ---: | --- |
| `0` | right-front wheel |
| `1` | left-front wheel |
| `2` | right-back wheel |
| `3` | left-back wheel |
| `4` | front truck |
| `5` | back truck |
| `6` | deck |

`CreateWheels` iterates descriptor offsets `0`, `160`, `320`, and `480`,
producing exactly four wheels. `CreateTrucks` produces exactly two truck
descriptors at offsets `640` and `800`. `CreateTriangleDeck` creates one
configuration-driven triangle deck and calls `AddTriangle` while walking an
external profile. The profile count, points, and all physical dimensions
remain external.

`InitializeTransforms` issues seven `SetTransform` calls: deck index 6 first,
then wheels 0 through 3, then trucks 4 and 5.

### Wheel placement signs

`InitializeTransforms` applies the same magnitude with these local signs:

| Wheel index | Lateral sign | Longitudinal placement |
| ---: | ---: | --- |
| `0` | negative | front |
| `1` | positive | front |
| `2` | negative | back |
| `3` | positive | back |

The executable observation proves the sign pattern and axle grouping. The
human-readable right/left labels are the geometry-derived part described
below.

### Joint connectivity

`CreateJoints` writes six consecutive body-index pairs into a 48-byte integer
array. The values are direct data-flow observations:

| Pair byte offset | Body indices | Module identity |
| ---: | --- | --- |
| `0x00` | `(6, 4)` | deck ↔ front truck |
| `0x08` | `(6, 5)` | deck ↔ back truck |
| `0x10` | `(4, 0)` | front truck ↔ right-front wheel |
| `0x18` | `(4, 1)` | front truck ↔ left-front wheel |
| `0x20` | `(5, 2)` | back truck ↔ right-back wheel |
| `0x28` | `(5, 3)` | back truck ↔ left-back wheel |

The joint type and the meaning of the associated `0x50`-byte frame/config
records are not resolved. The implementation therefore preserves the six
links but requires joint kind, frames, limits, spring, damping, and force
limit externally.

### Drive connectivity and storage

`CreateDrives` makes two `Simulation::AddDrive` calls:

- truck 4 handle at object offset `0x1CC` to deck 6 handle at `0x28C`
- truck 5 handle at object offset `0x22C` to deck 6 handle at `0x28C`

Their frame records begin at object offsets `0x1A70` and `0x1AB0`, with a
`0x40`-byte stride.

`CreateWheelDrives` makes four more `Simulation::AddDrive` calls:

- wheel 0 handle `0x4C` to truck 4 handle `0x1CC`
- wheel 1 handle `0xAC` to truck 4 handle `0x1CC`
- wheel 2 handle `0x10C` to truck 5 handle `0x22C`
- wheel 3 handle `0x16C` to truck 5 handle `0x22C`

The four wheel-drive frame records are at `0x1CB0`, `0x1CF0`, `0x1D30`, and
`0x1D70`, again with a `0x40`-byte stride. The returned wheel-drive handles
are stored at `0x1DE8`, `0x1DEC`, `0x1DF0`, and `0x1DF4`.

The numeric drive dynamics loaded by both constructors are configuration/
global values whose meaning and ABI are unresolved. No numeric replacement is
provided in the module.

### Truck transforms

`SetTruckDriveFrames` calls `SetDriveFrames2` twice using outputs from
`CalcTruckTransforms`. `CalcTruckTransforms` stores two 4×4 records at object
offsets `0x1E20` and `0x1E60`. Its front/back calculations use sign reflection
and the exact float `0.5` loaded from `0x8209975C`.

The implementation exposes the observed front/back translation reflection.
It does not assign a basis because the source configuration fields and matrix
axis convention have not been fully identified.

### Average wheel compression

`CalculateAverageWheelCompressions`:

1. reads the deck transform at index 6 and computes its inverse;
2. reads wheel transforms 0, 1, 2, and 3;
3. converts their translations to deck-local space;
4. writes front compression at object offset `0x20B4`;
5. writes back compression at object offset `0x20B8`.

With `p[i]` denoting the relevant deck-local wheel-axis component and `r` the
reference at object offset `0x20BC`, the observed equations are:

```text
front = 0.5 * (p[0] + p[1]) - r
back  = 0.5 * (p[2] + p[3]) - r
```

The `0.5` constant is the float at `0x8209975C`. For already-relative
per-wheel compressions `c[i]`, the exact four-way aggregate used by the
standalone state is:

```text
all = 0.25 * (c[0] + c[1] + c[2] + c[3])
```

No clamp, dead zone, spring, damping, or force conversion is added.

### Post-physics ordering

At entry, `UpdatePostPhysics` iterates the physics parts and calls the part
post-physics helper at `0x82ADF7B8`. It then calls
`CalculateAverageWheelCompressions` at `0x82C08968`. The remainder performs
additional collision/contact/event processing which is not completely
recovered and is not ported here.

The standalone update consequently does only three things:

1. copies four independent caller-owned contact/compression samples;
2. computes front, back, and four-way compression aggregates;
3. returns caller-owned body poses only when the caller declares physics pose
   authority.

It does not apply forces, mutate presentation state, or infer an authority
transition.

## Derived and corroborated

The extracted `SkateBoard_6` presentation mesh has these dominant-bone centers:

- front truck: longitudinal `+0.23712158203125`
- back truck: longitudinal `-0.2376708984375`
- left-front wheel: lateral `+0.0948486328125`, longitudinal
  `+0.24285888671875`
- right-front wheel: lateral `-0.094970703125`, longitudinal
  `+0.24285888671875`
- left-back wheel: lateral `+0.0948486328125`, longitudinal
  `-0.243408203125`
- right-back wheel: lateral `-0.094970703125`, longitudinal
  `-0.243408203125`

This establishes that negative lateral is right, positive lateral is left,
positive longitudinal is front, and negative longitudinal is back for this
asset. Combined with the executable sign pattern, it derives the module's
wheel names:

```text
0 right-front, 1 left-front, 2 right-back, 3 left-back
```

The GLB skin list alone must not be used as physics order: its two back-wheel
bones are enumerated left then right, unlike the physical body order.

The presentation deck bounds are approximately:

```text
low  = [-0.1121826171875, 0.05952148512005806, -0.45220947265625]
high = [ 0.11224365234375, 0.12794189155101776,  0.44989013671875]
```

These are visual-mesh measurements and are not used as collision dimensions,
mass, or inertia.

## Inferred policy

- `BodyPoseSet` is copied into output only for `PoseAuthority::Physics`.
  This is an authority-safety policy required by the parity architecture, not
  a recovered TU3 ABI.
- Contact point, normal, and surface key are pass-through state fields. Their
  exact retail contact-record ABI is not claimed.
- The monotonic `step` value is caller-owned and exists for deterministic
  publication; it is not claimed to be a retail object field.

## Unresolved ABI and constants

- The full `SkateboardBody` class layout and vtable.
- The complete `UpdatePostPhysics` signature ABI beyond the symbol's apparent
  `this`, `float`, and `const Vector3&` parameters.
- Triangle-deck source profile, segment count, winding policy, and collision
  material.
- Truck and wheel collision primitive types and dimensions, including wheel
  radius and width.
- Per-body mass, center of mass, and inertia tensors.
- Joint primitive kind, axes, frames, limits, springs, damping, and force caps.
- Drive frame axis convention, limits, springs, damping, force caps, and all
  associated global/configuration field meanings.
- The exact basis reflection constructed by `CalcTruckTransforms`.
- The relevant local-axis component's semantic name in
  `CalculateAverageWheelCompressions`.
- Contact manifold ABI, event flags, collision filtering, and the remainder
  of `UpdatePostPhysics` after compression aggregation.

Every unresolved physical field has a corresponding typed
`UnresolvedParameter` in the Rust module. Supplying one is an explicit
integration action; the standalone topology never substitutes a tuned value.
