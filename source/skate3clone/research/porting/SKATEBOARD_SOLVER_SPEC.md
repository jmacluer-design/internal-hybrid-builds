# TU3 Skateboard Contact and Post-Physics Bridge

## Scope

This specification covers the evidence-backed implementation in
`src/skateboard_solver.rs`. It ports the deterministic contact-record
reduction, per-wheel post-physics bridge, dominant-surface vote, contact-normal
fallback, airborne timer, and `SetTransform` write topology around the existing
`skateboard_body.rs` and `riding_forces.rs` seams.

It does not claim a recovered rigid-body impulse solver. In particular, static
data flow disproves the earlier working description of `0x82C07D20` as the
consumer of the 48-byte `AddSkateboardForce` queue: the call receives a
`SkateboardBody*`, fixed delta, and a vector. No queue pointer is passed at that
boundary. Raw force-type dispatch therefore remains evidence-gated.

## Build identity

Primary mapped TU3 image:

- Path:
  `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\XexDump\default_82000000_011B0000.bin`
- Mapped base: `0x82000000`
- Size: `18,546,688` bytes
- SHA-256:
  `F4AA113EB541BFBA03DBC108CF5AB43F58C965B20FA3B82F9C40938A0AD841C4`

Corroborating generated recompilation:

| Artifact | SHA-256 |
| --- | --- |
| `skate3_animation_research_recomp.75.cpp` | `D8C3ADDBD8CB3E9C266068099204EC0350DAB0E337856EE9D29B3A714A27D260` |
| `skate3_animation_research_recomp.76.cpp` | `5A0660F8D39A41A4BA7704EA07756982BD8E9C4F2CB885833A1B24F717F93A17` |

IDA 9.3 was used read-only against the disposable community database. The
database was closed without saving. Generated PPC recompilation was used as a
second representation of the same instruction stream.

## Function evidence

| Function/range | Bytes | SHA-256 |
| --- | ---: | --- |
| `Skateboard::UpdatePostPhysics` `0x82C02138..0x82C02388` | 592 | `7FCF2B02473D83AA5F44222470952DBD1173AA6ED07E80483BA77623AFB6307E` |
| `Skateboard::AddSkateboardForce` `0x82C03EF0..0x82C03F98` | 168 | `E383F71E9F9E2A7E81D92C3384AC1BD14FE0DE2A4D67840051B4D1704C031A45` |
| `SkateboardBody::UpdatePostPhysics` `0x82C07D20..0x82C08818` | 2,808 | `8065704C221ACBB0110B314975B5B0321923DC0D93D93B4265885CC964E3325A` |
| dominant-surface helper `0x82C08818..0x82C08968` | 336 | `8A7A159D263777EE06A2D2F3B2AEC15C0F94C2C5DEEEC0499B0C5138BE2A884F` |
| `SkateboardBody::SetTransform` `0x82C0B2C8..0x82C0B560` | 664 | `4518CF5599CA58B0B13ADEF4F7530F18C9617037A5EB1E6945825D85D365C12D` |

## Observed behavior

### High-level call boundary

The normal `Skateboard::UpdatePostPhysics` path:

1. obtains a `SkateboardBody*` through a virtual call ending at `0x82C0233C`;
2. loads fixed delta from owner field `+2604`;
3. copies one vector from the block at owner `+292`, offset `+1152`;
4. calls `SkateboardBody::UpdatePostPhysics` at `0x82C07D20`;
5. calls the normal finalizer at `0x82C02388`;
6. rewinds the 21×48-byte force queue.

The 48-byte queue is not passed to `0x82C07D20`. `plan_force_dispatch` therefore
preserves queue order while returning typed unresolved force semantics and an
unresolved backend. It is a safety boundary, not a claim that the retail force
consumer has been found.

### Contact-result records

The body update receives a begin/end pair from a virtual method at owner
`+884`, vtable slot `+96`. It walks records with a `96`-byte stride.

Observed fields:

| Record byte | Use |
| ---: | --- |
| `+16` | vector used for direction projections, component-1 ranking, and contact-normal reduction |
| `+32` | second copied vector |
| `+48` | third copied vector |
| `+64` | body index, used directly in the seven-body arrays |
| `+68` | packed classification/flags |
| `+80`, `+81` | raw boolean fields copied into temporary processing state |

For each body, the first record is retained and a later record replaces it only
when `vector_16.component[1]` is strictly greater. The three vectors are stored
in independent seven-entry arrays. A separate seven-byte array records whether
each body was touched during the current frame.

For body indices 4, 5, and 6, the packed word is decoded as:

```text
low_7  = raw & 0x7f
next_5 = (raw >> 7) & 0x1f
next_4 = (raw >> 12) & 0x0f
```

The pointer/peer branch at `0x82C07F30..0x82C080D4` can clear a persistent body
channel for two raw peer kinds. Pointer and peer-kind ABI are not proven, so
each `ContactRecord` carries a `Required<PeerChannelEffect>`. Unresolved peer
records are published in the output rather than silently treated as no-ops.

### Deck projection span

For deck records (body index 6), the update projects `vector_16` onto the
caller vector. The minimum starts at `+1.0`, the maximum at `-1.0`, and owner
field `+0x35C` receives:

```text
max(max_projection - min_projection, 0)
```

### Per-wheel no-contact bridge

After processing records, wheels 0 through 3 are handled independently.

- If no record touched a wheel and its scalar at owner `+0x2E0 + 4*i` is
  strictly less than `0.07`, a caller-owned fallback vector is copied into that
  wheel's selected-vector channel.
- If no record touched a wheel and the scalar is greater than or equal to
  `0.07`, the wheel's persistent channel byte is cleared.
- No clamp or interpolation is present at this branch.

Exact constants:

| Purpose | Address | Raw value |
| --- | --- | ---: |
| no-contact threshold | `0x821BCD64` | `0.07000000029802322` |
| touching wheel scalar | `0x82216FEC` | `0.03999999910593033` |
| non-touching wheel scalar | `0x82116288` | `0.006000000052154064` |
| downstream scale | `0x822F860C` | `59.999996185302734` |

The downstream physics field `+36` receives:

```text
(touching ? 0.04 : 0.006) * 59.999996
```

The meaning of that field is not assigned.

### Dominant surface class

The helper at `0x82C08818` allocates 16 counters. For each wheel whose class is
nonzero:

- a touching wheel adds 4;
- a non-touching wheel adds 1.

Only classes 1 through 13 are scanned. The comparison is strict `>`, so equal
weights preserve the lower class encountered first. Owner flag bit
`0x02000000` overrides the result to class 12. The Rust port rejects class
values outside the 16-counter table rather than reproducing an unsafe stack
index.

### Contact normal

The update chooses the body whose selected `vector_16.component[1]` first
strictly exceeds the running maximum, initially `-2.0`. A wheel contributes to
the primary sum only when all observed gates pass:

1. it was touched this frame;
2. its projection onto the caller vector is greater than a runtime
   `cos(attribute)` value;
3. its angle from the selected reference-body vector is strictly less than
   `π/4`.

The attribute behind gate 2 remains unrecovered and is represented as
`Required<f32>`.

If the eligible wheel sum has squared length greater than
`1.52587890625e-5`, it is normalized. Otherwise, touched deck, front-truck, and
back-truck vectors are summed. That fallback is normalized when its length is
greater than `0.01`; otherwise the exact vector at `0x82139A20`,
`[0, 1, 0, 0]`, is used.

The Rust implementation reproduces the branch arithmetic with deterministic
`f32` operations. Bit-identical Xenon VMX reciprocal-square-root refinement
rounding remains a separate `PpcVectorMathRounding` requirement.

### Counts and airborne clock

- Owner byte `+0x364` receives the number of touched bodies among all seven.
- Owner byte `+0x365` receives the number of touched wheels among the first
  four.
- If the wheel count is zero, owner float `+0x1E0C` accumulates fixed delta.
- Otherwise, that float resets to zero.

### `SetTransform` write topology

`0x82C0B2C8`:

1. reads the current deck transform;
2. prepares one common deck-delta affine transform;
3. writes the requested transform to body 6 (deck);
4. reads and delta-transforms bodies 0 through 5 in index order;
5. writes the requested transform to the auxiliary body reached through owner
   `+996`.

`set_transform_write_plan` ports this exact write order. The matrix storage and
multiplication convention remain `Required<AffineMatrixConvention>`; no
row/column or quaternion approximation is substituted.

## Derived

- The seven-body and four-wheel identities are imported from
  `SKATEBOARD_BODY_SPEC.md`; the solver preserves that ordering.
- Weighted voting is equivalent to giving a current wheel contact four times
  the influence of a retained non-contact class.
- The body selected as the normal reference is the first body to achieve the
  strict maximum component-1 value, matching instruction ordering rather than
  a later stable sort.

## Unresolved blockers

- Numeric and semantic identities of all `eSkateboardForceType` values.
- The actual consumer that converts queued 48-byte records into physics-world
  operations.
- Meanings of the two force payload vectors and their spaces.
- Contact-provider and peer-pointer ABI, including raw peer kinds and event
  flag side effects outside channel clearing.
- Complete meanings of contact vectors at bytes 16, 32, and 48.
- Runtime wheel-normal angle attribute and its owning point/config graph.
- Bit-identical Xenon VMX estimate/refinement rounding.
- Collision manifold generation, impulses, friction, restitution, mass,
  inertia, wheel dimensions, suspension, joint dynamics, and force caps.
- Affine matrix storage/multiplication convention used by `SetTransform`.

No value in this list is tuned or guessed by the module.

## Verification

The standalone test wrapper compiles `riding_forces.rs`,
`skateboard_body.rs`, and `skateboard_solver.rs` together with
`rustc --edition 2024 -D warnings --test`.

Tests cover:

- exact packed-bit extraction;
- strict per-body best-record selection;
- deck projection span;
- strict `0.07` no-contact boundary;
- exact touching/non-touching downstream scalar formulas;
- 4:1 surface voting, tie order, and class-12 override;
- airborne timer accumulation/reset;
- wheel, deck/truck, and up-vector normal paths;
- unresolved angle publication;
- ordered and unresolved force dispatch;
- exact eight-write `SetTransform` topology.

No game, emulator, renderer, Computer Use session, or visual check is launched.
