# Powerslide parity evidence

## Scope and build identity

This recovery targets the TU3 / 1.05 Xbox 360 retail build represented by:

- `C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\XexDump\default_82000000_011B0000.bin`
- Size: `18,546,688` bytes
- SHA-256: `F4AA113EB541BFBA03DBC108CF5AB43F58C965B20FA3B82F9C40938A0AD841C4`
- Symbol index: `research\reverse-engineering\symbols\skate3-tu3-1.05-community.index.json`
- Recompiled code: `research\reverse-engineering\generated\skate3_animation_research_recomp.*.cpp`

No live SK8 or retail Skate 3 process was launched for this work. Analysis used
the static dump/recompilation, retail state XML, decoded animation resources,
and existing telemetry/fixtures.

## Observed retail behavior

### State predicates and their concrete producer

`CanEnterSlide` resolves through condition vtable `0x8231F324` to TU3
`0x82BA6FE0`.

- It rejects physics state enum `102`.
- It reads the condition's `right` parameter and XORs that selection with the
  SkaterAnim `0x20000000` mirror bit returned by `0x82B970D8`.
- It selects returned offset `+12` when that result is true, or `+4` when
  false.
- `rlwinm ...,1,31,31` extracts the source word's `0x80000000` bit.

`ShouldLeaveSlide` resolves through condition vtable `0x8231F358` to TU3
`0x82BA7130`.

- It reads returned offset `+16`, uses that word's sign bit to optionally
  invert the XML `right` side, selects returned `+4` or `+12`, then uses
  `rlwinm ...,2,31,31` to extract `0x40000000`.

The complete pointer chain is now statically resolved:

1. `Sk8::Actor::Actor` (`0x82590DC0`) constructs `SkaterMotionGraph` through
   `0x8258F488`.
2. Actor `+1800` receives `SkaterMotionGraph +2684`.
3. Its virtual slot `+60` resolves through vtable `0x82300700` to
   `0x8258F7E8`, exactly `addi r3,r3,3204; blr`.
4. The returned address is therefore `SkaterMotionGraph +5888`, which the
   recovered contiguous layout identifies as `DerivedControllerInput +68`.

The selected words are whole IEEE-754 timer floats, not separately OR-written
flags:

| Condition offset | Concrete field | Whole-word writer | Observed meaning |
|---|---:|---:|---|
| returned `+4` | derived input `+72` | `stfs` at `0x82599444` | time since the latest rising edge of raw packed flag `0x40000000` |
| returned `+12` | derived input `+80` | `stfs` at `0x825994C0` | accumulated time while processed action ID `80` is active; zero otherwise |
| returned `+16` | derived input `+84` | `stfs` at `0x825994FC` | accumulated time while processed action ID `81` is active; zero otherwise |

`DerivedControllerInput::Update` is `0x825992D8`. Its observed order is:

1. copy seven current raw-input words into the previous-input block;
2. run `RawControllerInput::Update` (`0x82598FE0`);
3. update trigger-zero timers `+56/+60`;
4. update packed-button edge timers `+64/+68/+72/+76`;
5. query processed actions `80/81/78/79` and update hold timers
   `+80/+84/+88/+92`;
6. update separate stick-magnitude threshold timers `+96/+100`.

The `ShouldLeaveSlide` mask first becomes set at the positive float value
`2.0`. This is a raw exponent-bit test, not a floating-point comparison; it
remains set through the ordinary `[2, 8)` range and is not monotonic for
unbounded floats. Treating it as a universal `timer >= 2.0` predicate would
therefore overstate the evidence unless the timer lifecycle/range is also
proved.

The more important state-machine conclusion remains firm: `CanEnterSlide` is
not re-evaluated as the active-state continuation predicate. The old Bevy
route did exactly that every fixed tick, so a modest stick edit dropped the
slide immediately. Retail uses the separate `ShouldLeaveSlide` route.

There is a static inconsistency that is intentionally not hidden:
`CanEnterSlide` tests the sign bit of timers whose recovered normal positive-
delta update writes zero or positive values. No negative sentinel,
initialization, or alternate writer has yet been found. Consequently the
lower-level entry producer and true native entry/dead-zone threshold are not
claimed byte-identical here.

`InCandidateSlidingState` is also distinct. Its registered factory is
`0x82BC93D0`, with update method `0x82BB35E8`; that update ORs `0x40000000`
into offset `+16` of a separate graph/physics owner returned by a virtual
method. It is not the per-side `CanEnterSlide` word. This corrects the earlier
project comment that conflated the owner marker with the entry predicate.

`IsPowerSliding` is registered by factory `0x82BC9470`; its condition method
is `0x82BACD20` and queries the skateboard owner through virtual slot `+112`
with argument `1`.

### Processed input and persistent control state

`Sk8::Behaviours::PowerSliding::Update` is TU3 `0x82BC01C0`.

- It reads two already-processed controller values from provider offsets
  `+496` and `+500`; it does not read XInput directly.
- The second/lateral channel is negated when the stance/mirroring provider is
  true.
- The behavior owns persistent fields at runtime offsets `+8`, `+12`, `+16`,
  `+24`, `+28`, `+32`, and a boolean latch at `+36`.
- It bounds and conditions both channels, stores the conditioned pair at
  `+28/+32`, publishes them as animation attributes, and passes them together
  to a skateboard/physics virtual call at slot `+252`.
- The `+36` latch is enabled by an external state check, after more than 80
  updates, or when two queried values are both strictly inside `0.1`
  (`0x820641A8` in the pinned dump). Once enabled, the two output channels are
  filtered together.

This proves that an established slide has persistent, continuously updated
control state. It does not restart the state graph for each stick sample.
Only this processed pair appears in the behavior; no second stick pair is read
there. The current fixtures identify it with the left-stick slide sweep, but
the lower input-map registration linking the numeric action IDs to canonical
`GP_*` names remains unresolved.

The exact five-value tuning block used by `PowerSliding::Update` is reached
through a runtime-initialized global pointer. Its concrete values are not
present in the static snapshot, so they remain unresolved rather than being
invented.

### Retail state tree and update ordering

Pinned graph resources:

- `NewRightSlide.xml`, SHA-256
  `34575DEAB01A7232C195D3D60D5F3E29BA16D621559209B49B51B85CD60B206A`
- `NewLeftSlide.xml`, SHA-256
  `24617F96F72777086EB586BC4FD77F094437819BF2EE26428AEEACBC68EF9A55`

Both graphs show:

1. Parent precondition `CanEnterSlide` (left passes `right="false"`).
2. Parent behaviors `SetScoreAugmentation`, `CreateSlide`, and
   `PowerSlideDecel`.
3. Non-interruptable `Into` and `Cyc` children.
4. `Into` plays `SL_FS_INTO` / mirrored `SL_BS_INTO` with `time="0.2"`.
5. `Into -> Cyc` uses `WillExpire`, `InTime="0.05"`, and
   `waitForTransitions="false"`.
6. `Cyc` uses `time="0.1"`.
7. Parent `Into -> Out` requires both `InParentStateForTime greater="0.3"`
   and `ShouldLeaveSlide`.
8. OUT selects Early (`earlyout`), Mid (`midout`), or Default, runs
   `PowerSlideSpin`, forwards `decel` from `lastAnim`, and plays with
   `time="0.2"`, `transitionUnder="true"`, and
   `blendWithCurrentFrame="true"`.
9. OUT hands to Manual at `WillExpire 0.1` or Idle at `WillExpire 0.05`;
   the push hook has a one-second channel blend.

Related behavior addresses:

- `CreateSlide::Update`: `0x82BB2F60`
- `PowerSlideDecel::Update`: `0x82BB31B0`
- `PowerSlideSpin::Begin`: `0x82BB33C8`

The onboard parent registers `PowerSliding`; `ground.xml` registers
`PowerSlideManualAtt`, `IsPowerSliding`, then the left/right slide states.

### Authored animation leaves

Decoded source:

- `OnBoard.abin`
- Size: `10,783,864` bytes
- SHA-256: `30AA324D6D7C51C325D53E9268C1AD91783B0154D21BBEF5DC5A61EAE8333BD7`

The decoded report contains FS/BS, LSP/HSP leaves for INTO, CYC, Early/Mid,
and 000/090/180 OUT. INTO has 23 source samples at 30 Hz and CYC has 48.
The Bevy tree continues to use those extracted leaves and its existing
`decel` blend; no procedural body animation was added.

The prepared private manifest independently confirms all 28 extracted
`R_SLIDE_{FS,BS}_{LSP,HSP}_*` actions, including INTO, CYC, EARLYOUT, MIDOUT,
and every 000/090/180 OUT leaf. Corresponding root-motion entries are present
in `assets\private\skater_push.root_motion.json`.

### Prior native engine layer

The older Godot native layer was inspected at
`C:\Users\Daddy\Documents\Skate3Research\godot\native\src\native_skate_core.cpp`.
Its `step_ground` recomputes a local `powersliding` boolean every tick directly
from raw entry thresholds, immediately changes state back to rolling when that
boolean becomes false, multiplies yaw by raw `steer`, and folds slide drag into
a generic longitudinal-drag expression. Its header constants (`0.78`, `0.20`,
`0.88`, and fixed yaw/drag values) conflict with the newer TU3 state-bit and
matched-fixture evidence. That implementation documents the cancellation-prone
failure mode; none of those obsolete constants or its generic force folding
were copied into the Bevy fix.

### Existing matched fixture

`retail-motion-signals.csv`:

- SHA-256: `08EAB12773E9D5188E5B176EE4ED6EA1B4381B342432AA5416ACB519727F1F73`
- 115-sample active-plus-OUT fit:
  `work\identified-turning-controller-with-out.json`

The three tracked turning-controller reports and their generator now record
the owner marker separately from the `CanEnterSlide` and `ShouldLeaveSlide`
timer-word masks, plus the resolved derived-input base. Their previous single
`candidate_state_bit` label—and the intermediate description of these masks
as independent side flags—were statically disproven.

Recovered/identified values retained by the implementation:

- candidate down start: `0.57`
- strict entry down: `0.88`
- strict minimum slide speed: `0.84 m/s`
- active yaw response: `0.035 s`
- OUT yaw response: `0.13 s`

In the fixture the stick remains held through the active slide while the
physical route exits at the strict low-speed boundary. This is why the
candidate curve remains an entry/continuous-control signal and is not reused
as active-state cancellation.

## Derived implementation mapping

- The slide side is latched at entry and is not recomputed from every stick
  sample.
- Entry still uses the established broad downward-side sector and strict
  speed gate.
- After entry, the same captured down curve drives a continuous intent target
  without its entry-only lateral/speed gates. Both processed channels use the
  already fitted `0.035 s` response. The lateral channel continuously scales
  physical yaw through zero relative to its measured entry value; that changes
  board-local slip and the existing authored LSP/HSP `decel` blend without
  restarting or swapping the latched FS/BS graph leaf.
- The retail `greater="0.3"` parent guard is preserved.
- Strict low speed and lost contact request OUT independently of entry.
- Leaving the measured continuous down sector (`-Y <= 0.57`) is the Bevy
  deliberate-release integration. This reuses the captured continuation
  boundary instead of adding a guessed second dead zone or misapplying the
  unresolved timer word as a slide-local stopwatch. Crossing lateral sides
  while still down remains a smooth adjustment.
- Ground contact is required at admission; an airborne held input cannot
  create an INTO/OUT loop.
- Stance mirroring is implemented at the powerslide-control boundary by
  mirroring the lateral channel before side selection and continuous control.
  The live simulation owns an explicit `slide_control_mirrored` provider,
  deliberately separate from forward/fakie ownership so this work does not
  conflict with the independent fakie route.
- INTO overlays the outgoing riding/carve pose over the authored `0.2 s`.
  INTO -> CYCLE advances the outgoing INTO clip during the authored `0.1 s`
  handoff. CYCLE -> OUT alone uses the XML's `blendWithCurrentFrame`, freezing
  the outgoing pose while the selected OUT tree blends over `0.2 s`. OUT
  expiry creates a final `0.2 s` pose handoff to riding, preventing a one-frame
  default/riding flash.
- Phase overshoot is carried through INTO -> CYCLE and OUT -> riding instead
  of reset, keeping playback and blend state stable across frame partitions.
- Board yaw, dedicated powerslide friction, board lean, and animation signals
  remain separate states. The diagonal landing-friction route remains in
  `contact_friction` and is not folded into powerslide.

## Inferred integration details and unresolved native inputs

- The timer-word producer chain and exact masks are recovered, but the
  `CanEnterSlide` sign-bit path is inconsistent with its normal nonnegative
  writers. Lower-level input-map dead zones, any negative sentinel, and the
  authoritative action-ID names remain unresolved. Bevy's measured
  down-sector release plus strict low-speed/contact gates are therefore
  integration mappings, not falsely labeled byte-identical native predicates.
- The observed `0x40000000` timer-word mask is recorded and tested in the
  evidence fixtures, but it is not implemented as an arbitrary two-second
  slide-local timer: the selected timer's reset event/action mapping to the
  slide control has not been proved.
- The exact runtime tuning block consumed by `PowerSliding::Update` remains
  unresolved. Existing measured response values are used; no replacement
  constants were fitted in this change.
- Early/Mid OUT graph attributes exist in retail, but their native attribute
  producers are unresolved. The current evidence-backed 000/090/180 default
  OUT selection remains unchanged.
- Forward/fakie/switch ownership is intentionally not introduced here. The
  stance-local API and tests cover mirroring without competing with the
  separate fakie worktree.

## Deterministic validation coverage

The test matrix covers:

- valid downward entry angles and invalid sectors;
- strict speed entry;
- continued slide after modest stick movement;
- smooth intent/control adjustment without side changes or animation restart;
- deliberate neutral/forward release, lateral-side crossing continuation,
  strict speed, and contact leave gates;
- no airborne admission;
- the retail `>0.3 s` parent guard;
- INTO -> CYCLE phase continuity and its `0.1 s` authored blend;
- CYCLE -> OUT transition-under and OUT -> riding pose handoff;
- stance mirroring;
- frame-partition invariance across INTO -> CYCLE, including sample clocks;
- dedicated powerslide contact-friction routing;
- diagonal landing-friction and push-cadence regressions.

Human visual parity remains the final checkpoint; use
`LAUNCH POWERSLIDE VISUAL TEST.bat` after automated validation.
