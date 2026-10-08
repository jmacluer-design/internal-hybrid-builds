# TU3 non-basic airborne flip/shuv graph

This specification covers the normal and nollie/nose forms of kickflip,
heelflip, pop shuvit, FS pop shuvit, varial kickflip, varial heelflip,
hardflip, inward heelflip, 360 pop shuvit, FS 360 pop shuvit, 360 flip,
laserflip, 360 hardflip, and 360 inward heelflip.

## Build and evidence

The authorized TU3 dump used by this project has SHA-256
`F4AA113EB541BFBA03DBC108CF5AB43F58C965B20FA3B82F9C40938A0AD841C4`.

| Artifact | SHA-256 |
|---|---|
| `MotionGraph_OnBoard.xml` | `3D22018FBA263212A52681453D5AC3A19982B7DF66A188DB3E555B915223C8FA` |
| `ActionGraph_OnBoard.xml` | `B8CA3C220833D8DCD8E0F397F967ACA9E776D7687C1DA95BB3A22FCF40FC1B24` |
| `MotionGraphIncludes/Tricks/Tricks.xml` | `1309813FA9D8075858D57BA035E05947E07847CA784C8BD15907C28123B5EFF4` |
| `MotionGraphIncludes/Tricks/T_Trick.xml` | `F0A46D02B1F5E404152AEDBD5A8A8E47A4BA37563AA5A81BD018B19B076AD8E6` |
| `MotionGraphIncludes/Tricks/T_Kickflip.xml` | `8C0F59FA05AF01A7DF829AC6056FDEBD1E15BF89C008B868CFF280E50DEA5063` |
| `T_TrickWithUnderflip.xml` | `4849908C082AF64569F2FDB9BE38332F1430231B92970C6C8368A09419CCA834` |
| `T_TrickWithDarkCatch.xml` | `2B3917F38B540627F921E9644F3DFA38131F6E02618FA486C2D7F2F09E39253A` |
| `gesture-trick-mapping-records.json` | `06D352ACC6D8726ECEA6AEF29177150DC150BD4B1EDAF751BDFF6949B0006056` |
| `skate3_onboard_clips.csv` | `7B2041D3E8FC305D589A05B65B72B5181319197B4CF4FC6C410C8BDDAA131D10` |
| `OnBoard.abin` | `30AA324D6D7C51C325D53E9268C1AD91783B0154D21BBEF5DC5A61EAE8333BD7` |
| TU3 symbol index | `97F0EE8934AA82E4CE9168B0F2CD434676285E2DB95E32A813382A1FF51B1D29` |

Relevant generated-code/symbol addresses are:

- `WillExpire` constructor: `0x82BA6620`
- `SetTrickHeight` constructor: `0x82BAED78`
- `PlayAnimation` constructor/begin/update: `0x82BB4B38`,
  `0x82BB5188`, `0x82BB5670`
- `HasAnimAttribute` constructor: `0x82BC2B38`
- `RegisteredTimeToLand` initializer: `0x82F87C50`
- `RegisteredIsBodyFlipping` initializer: `0x82F87C90`
- `RegisteredForcePhysics` initializer: `0x82F88700`
- `RegisteredIsDoingTrick` initializer: `0x82F8A1C0`

These addresses identify the retail implementation sites. The XML remains the
direct evidence for the state topology and parameter values represented in the
Rust module.

## Observed graph behavior

`Tricks.xml` instantiates 28 identities: 14 tail-pop and 14 nose-pop variants.
The ActionGraph changes the intent names for switch/mirror handling before the
MotionGraph receives them; nose versus tail is still represented by the
`N_` intent/resource family.

All trick states sit under a parent `ForcePhysics
force="FOLLOW_ANIMATION_DATA"` behavior. The common air parent changes this to
`FORCE_ANIM_SKATEBOARD`; landing and ground change it back to
`FORCE_PHYSICS_SKATEBOARD`.

The common sequence template (`T_Trick.xml`) does this:

1. Play virtual `$ANIM_NAME$_G`.
2. Transition when `WillExpire InTime="0.05"`.
3. Play virtual `$ANIM_NAME$_A` as a sequence, blending from the previous
   animation by `TrickHeight`.
4. At the same 0.05-second expiry window, route to the externally selected
   `InAir`, `Land`, or `OnBoard` parent state.

Pop shuvit and FS pop shuvit use the same sequence plus an optional underflip
branch. The four 360-flip families use the same sequence plus an optional dark
catch branch. Varials, hardflip/inward and both 360-shuv families use the plain
sequence.

Kickflip and heelflip use `T_Kickflip.xml`:

1. `B_*_IN_G` then `B_*_IN_A`.
2. At `_IN_A` expiry, release to `OUT1` when the hold is absent,
   `TimeToLand < 0.525`, or the body is flipping; otherwise enter `CYC1`.
3. At `CYC1` expiry, release to `OUT2` when the hold is absent,
   `TimeToLand < 0.8`, or the body is flipping; otherwise enter `CYC2`.
4. At `CYC2` expiry, release to `OUT3` when the hold is absent or the body is
   flipping; otherwise enter `CYC3`.
5. `CYC3` expires to `OUT4`.
6. Every out leaf routes to `InAir`, `Land`, or `OnBoard` at the 0.05-second
   expiry window.

The comparisons are strict `less`, so values exactly `0.525` and `0.8` remain
held. The graph exposes doubled, tripled and quadrupled scoring names. An
authored `underflipwindowend` animation attribute controls the higher scoring
state in cycles 2 and 3.

The live controller now supplies `$TRICK_NAME$Hold` from the selected retail
PatternNode's own final-coordinate contact. Holding within that pattern's
authored tolerance continues the graph; leaving it releases the graph. The
measured ollie carrier supplies `TimeToLand` without changing gravity or pop.
All four normal/nollie kickflip/heelflip identities resolve to their extracted
IN, CYC1-3, and OUT1-4 physical actions; exact mappings and evidence confidence
are recorded in `FLICKIT_MULTI_FLIP_SPEC.md`.

Entry behavior is also preserved:

- anticipation/manual: play `_G` with 0.05 seconds;
- drop-in: 0.05-second blend and fixed `TrickHeight=0.6`;
- grind: 0.85-second channel blend and fixed `TrickHeight=0.5`;
- lip/board/feeble/smith/willy grind-out assist: 0.75-second channel blend from
  `GRIND_OUT_TAIL` or `GRIND_OUT_NOSE`, then `_A` with 0.1 seconds and fixed
  `TrickHeight=1.0`.

## ABIN corroboration

The OnBoard catalog contains physical low/high `_G` and `_A` leaves for all
covered families at 60 Hz. Examples include:

- `KICKFLIP_IN_LOW_G` 13 samples, `KICKFLIP_IN_LOW_A` 11;
- `N_KICKFLIP_IN_HIGH_G` 13, `N_KICKFLIP_IN_HIGH_A` 17;
- `POPSHUVIT_LOW_G` 13, `POPSHUVIT_LOW_A` 24;
- `VARIALKICKFLIP_HIGH_G` 13, `VARIALKICKFLIP_HIGH_A` 30;
- `HARDFLIP_HIGH_G` 13, `HARDFLIP_HIGH_A` 33;
- `N_360FLIP_HIGH_G` 13, `N_360FLIP_HIGH_A` 29;
- `360INWARDHEELFLIP_HIGH_G` 13, `_A` 38.

Several virtual resources have multiple physical candidates. For example,
tail FS pop shuvit has `D` and `CARR` leaves, tail varial heelflip has `D` and
`DILL` leaves, and tail 360 flip has `D`, `GONZ`, and `HSU` leaves. The XML and
catalog alone do not prove the runtime selector, so the Rust graph emits typed
virtual requests and does not choose one.

## Explicitly unresolved

- `TrickHeight` continuous blend curve and exact physical-leaf weights.
- Runtime selector for multi-candidate virtual resources.
- Animation expiry calculation after rate changes and transition overlap.
- Board flip/shuv axes, angular rates, impulses, damping, completion
  thresholds, and catch corrections.
- Physics jump impulse and `JumpInto` behavior.
- Underflip and dark-catch subgraphs.
- Landing classification and arbitration among `InAir`, `Land`, and
  `OnBoard`.
- Body-spin animation composition and physical body-spin completion.
- Concrete Bevy clips for virtual `B_*` requests outside the live mappings
  documented in `FLICKIT_MULTI_FLIP_SPEC.md` and the one-shot recovery.

Each unresolved item is represented by an external signal, a virtual animation
request, or `UnresolvedReason`; no fallback value is supplied.
