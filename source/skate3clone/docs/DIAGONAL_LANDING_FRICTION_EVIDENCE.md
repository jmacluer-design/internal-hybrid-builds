# Diagonal landing friction evidence

## Scope and build identity

This note covers physical planar velocity response only. Landing quality,
clean/sketchy animation selection, and landing graph routing are intentionally
outside this branch.

- Retail target: Skate 3 1.05 / Title Update 3 `default.xex`
- XEX size: 6,615,040 bytes
- XEX SHA-256:
  `1DB39496585C521D17A2137804F42CF73EBED2B32CAC166EC42DBF772F4DCF7F`
- Disposable IDA database used for this pass:
  `work/diagonal-friction-analysis.i64`
- Disposable IDA database SHA-256:
  `16576BF5F7DBA4BB41C470C6B772AF67A04D62F3D05357953E36CC29ED62067F`
- Community TU3 symbol-map SHA-256:
  `63BBC43685C87769BA8F58791029543232117AB13938FFBE2B710FC7EAA3EFB4`

The symbol names are hypotheses corroborated below by the executable's
operations and existing project fixtures. Addresses are guest/module-relative
TU3 addresses.

## Proven observations

1. Normal post-physics is wheel-contact gated.
   `Skateboard::UpdatePostPhysics`'s normal finalizer at `0x82C02388` reads the
   touching-wheel byte at skateboard-body offset `+0x365`
   (`0x82C023B8`) and exits when it is zero (`0x82C023C4`).

2. The normal path consumes a side-speed-shaped graph.
   With wheel contact present it reads the physics scalar at `+0xA60`
   (`0x82C025F0`), takes its absolute value, divides by a runtime attribute,
   evaluates an eight-point graph (`0x82C02684..0x82C0269C`), and uses the
   result in the following vector response.

3. Heading adjustment is a separate board-transform operation.
   `PostPhysics_AdjustHeading` at `0x82C05988..0x82C05D78` measures an angle,
   computes sine/cosine, reads the existing body transform, composes a new
   transform, and calls `SkateboardBody::SetTransform`. It does not normalize
   or restore linear speed.

4. Powerslide friction is separate from normal contact.
   `ToolKit_CalcSlideFriction` at `0x82D92970..0x82D92B58` evaluates three
   point graphs and emits a `SkateboardForce`. Existing fitted slide fixtures
   own this path; diagonal rolling touchdown must not route through it merely
   because board and travel headings differ.

5. Wheel, deck, and surface contact are distinct state.
   `src/skateboard_solver.rs` preserves four wheel channels, three deck/truck
   channels, touching-wheel count, weighted dominant surface class, and the
   deck/truck normal fallback. A deck-only contact is not evidence that the
   normal rolling-wheel side constraint is active.

6. The removed Bevy normalization added energy.
   The recovered rolling force form is
   `a_lateral = -board_right * lateral_speed * rate`. Its instantaneous power
   is `force dot velocity = -k * lateral_speed^2`, which cannot be positive.
   The former `normalize() * old_speed` step restored exactly the speed that
   this force removed and had no matching retail operation.

## Derived response implemented here

For wheel contact, velocity is decomposed into board-local longitudinal and
lateral components. The already established normal-contact rate removes the
lateral component continuously without reversing it. Longitudinal rolling
resistance remains independent. Therefore, after side slip settles:

`settled speed ~= abs(touchdown speed * cos(board/travel angle))`

minus ordinary rolling resistance accumulated during settling.

This simultaneously produces speed loss and redirects travel toward the board
heading. Loss increases with misalignment and touchdown speed because the
removed lateral component is `speed * sin(angle)`.

The implementation keeps the following mechanisms separate:

- one-shot touchdown delta: zero because no independent impulse has been
  recovered;
- continuing wheel side-slip friction: the existing captured 18 s^-1
  normal-contact composite;
- ordinary rolling/braking resistance: existing independent scalars;
- powerslide friction: the existing speed-shaped slide graph; and
- deck-only contact: telemetry-visible but force-unresolved.

Surface identity is carried through telemetry. No surface multiplier is
applied because no per-surface side-friction table has been recovered.

## Automated evidence

`src/contact_friction.rs` includes deterministic fixtures for:

- airborne and deck-only no-force boundaries;
- touchdown versus continuing contact (no invented one-shot delta);
- rolling side-slip sign, dissipation, and longitudinal preservation;
- 45-degree settled-speed projection; and
- powerslide path separation.

`src/sim.rs` includes integration fixtures proving that:

- diagonal touchdown loses speed without creating or selecting a landing
  animation; and
- continuing wheel friction settles to the projected longitudinal speed.

`src/parity_recording.rs` records path, contact, surface, touchdown, speed,
lateral components, one-shot delta, and continuing delta. A regression test
ensures telemetry header and row widths remain equal.

## Confidence boundary

### Inferred

- The existing 18 s^-1 normal-contact rate remains the best available
  composite for continuing wheel side slip. It was previously fitted from
  matched flat-ground carve telemetry and is not changed by this branch.
- Treating the flat ground provider as four-wheel contact is the current Bevy
  integration seam. The isolated API already accepts an exact wheel count for
  a future per-wheel backend.

### Unresolved

- Any per-surface multiplier for normal wheel side friction.
- Whether one, two, three, and four touching wheels scale the composite rate
  continuously or only gate the response.
- Deck-only scrape friction and collision impulse.
- A separately authored one-tick touchdown impulse, if one exists outside the
  recovered normal finalizer.

### Awaiting human visual verification

- Perceived speed loss for roughly 20-, 35-, and 50-degree landings.
- Whether travel redirects quickly enough without looking like a snap.
- Whether near-straight landings remain visually indistinguishable from the
  previous behavior.
- Whether powerslides still retain their established looser slide response.

No new SK8 capture was used after the project-wide no-harness workflow update.
The in-progress attempt ended before game capture because the Bevy build
initially lacked worktree-relative research junctions.
