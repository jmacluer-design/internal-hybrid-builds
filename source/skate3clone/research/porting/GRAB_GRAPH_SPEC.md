# Skate 3 TU3 airborne grab graph

## Scope

This specification covers the ActionGraph selector and the core
`OnBoard.InAir.GrabsTweaks` MotionGraph branches for FS, BS, double, mute, stale,
Coffin, and Superman grabs. Board-adjust tip grabs, one-foot air, finger flips,
footplants, landing IK, and physical contact response remain separate systems.

## Source identity

| SHA-256 | Retail state source |
|---|---|
| `672871717605A2AD6D592FD24C5270E462493507B01EBF5F7D443B8494B2F7F0` | `MotionGraphIncludes/air.xml` |
| `4E499BFC027D414CA3C2C9CAF7F2D6BF378168D84666C68521361B41F5D2589F` | `MotionGraphIncludes/GrabsTweaks/T_FSBSGrab.xml` |
| `95B2BD0170C81B1CD11CF8DD158DC02BB0FCA694FDC0EA35394348736804A88F` | `MotionGraphIncludes/GrabsTweaks/DBLGrab.xml` |
| `042FE27BB156A749D428A745513A64F545BB3360122FA4E4DE2DFD23201C215A` | `MotionGraphIncludes/GrabsTweaks/T_MuteStaleGrab.xml` |
| `86C551BF0F66ADA9D4BC425A41986EC9B4453000F8EA93BC4C4375EA3A5A9BEB` | `MotionGraphIncludes/GrabsTweaks/Superman.xml` |
| `19E049F9826D91A5F70329671F5F4F8F2B255501862646960C4AC836CFEAC788` | `ActionGraphIncludes/air.xml` |
| `9B187C4FB32A7B1CEC0517FDFBD133510003DD9C99A4B6259288A159318C04E2` | `ActionGraphIncludes/T_Grab.xml` |
| `DE4A43C07771DAAFB90A67B4798B400F14C3FAE1BF57059395D33F09BD48711B` | `ActionGraphIncludes/StaleMuteGrab.xml` |

The TU3 community symbol names below are corroborated by exact generated
function presence. Names remain community hypotheses; the XML behavior and
constants are the primary semantic evidence.

| Address | Generated function |
|---|---|
| `0x82BB12C8` | `FilterMotionGraphIntent` constructor |
| `0x82BBEA50` | `ScoringGrabs` constructor |
| `0x82BBEF60` | `ScoringGrabs::Create` |
| `0x82BC9510` | `TweakProject` constructor |
| `0x82F88C40` | `RegisteredSetGrabType` initializer |
| `0x82F890C0` | `RegisteredEndGesture` initializer |
| `0x82F89100` | `RegisteredHandBusy` initializer |

## Observed behavior

- A single left/right air-grab input maps to FS/BS and swaps when mirrored.
- Both air-grab inputs publish `DBLGrab`; both push inputs additionally select
  Coffin, while a newly pressed and held dismount selects Superman.
- Ordinary airborne grab branches inherit `FORCE_ANIM_SKATEBOARD`.
  Coffin and Superman explicitly request `FORCE_PHYSICS_SKATEBOARD`.
- FS/BS Into uses a `0.1` blend at playback speed `2.0`; double uses speed
  `3.0`; mute/stale use speed `1.25`.
- Core Into-to-next and Out-to-air edges use `WillExpire InTime=0.01`.
- Tweak filters use blend `0.116`, blend-out `0.133`, and clamp velocity `0.1`.
- Static recovery of `FilterMotionGraphIntent::Update` at `0x82BB17D0` proves
  `delta = blend * (target-current)`, followed by optional acceleration and
  velocity clamps. The coefficient is applied once per behaviour update and
  is not multiplied by the accumulated delta time stored alongside it.
- FS/BS, double, and mute/stale contact wipeout thresholds are respectively
  `0.4`, `0.8`, and `0.2`.
- FS/BS/double release uses `HasTweak < 0.2`; mute/stale release uses absolute
  filtered `TweakY < 0.2`.
- FS/BS transition to and from double through the four named transition
  resources represented by `GrabPhase::ToDouble` and `FromDouble`.

## Typed unresolved boundaries

- Every `BLEND_*` and `B_*` resource remains a virtual MotionGraph resource
  until retail selected-leaf telemetry or a verified deterministic resolver
  supplies a physical ABIN leaf.
- Sibling arbitration among finger flip, varial, shuv, one-foot, Christ,
  board-adjust, landing, and dismount branches is represented by a typed
  external branch selection.
- `TweakProject` projection and a synchronized runtime trace of the
  MotionGraph caller cadence remain unresolved. The port derives its canonical
  30 Hz filter cadence from the pinned native OnBoard grab stream and emits an
  exact midpoint-resampled 60 Hz mixer signal. Every second mixer sample
  remains identical to the canonical trajectory, so this does not accelerate
  the recovered filter.
- Hand IK, board contact, grab attachment transforms, scoring, pump suppression,
  landing routing, and Coffin exit-hand arbitration are external.
- No visual, timing, or random-choice constants were inferred.
