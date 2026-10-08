# Basic held-grab slice: evidence boundary

This slice was implemented without launching Skate 3 or the SK8 harness.

## Proven locally

- `ActionGraphIncludes/onground.xml` and `T_GroundGrab.xml` route left
  ground-grab to FS in regular stance and BS when mirrored; right ground-grab
  is the inverse. Both held inputs route to `GroundDBLGrab`.
- `ActionGraphIncludes/air.xml` uses the same single-hand stance routing and
  preserves the simultaneous-input `DBLGrab` route.
- `GroundGrabs/FSGrab.xml`, `BSGrab.xml`, and `DBLGrab.xml` define held cycles,
  authored single-to-double and double-to-single transitions, release states,
  and direct cycle handoffs between ground and `InAir.GrabsTweaks`.
- The ground graph uses 0.1-second into/transition blends, 0.2-second held
  cycle blends, and 0.05-second out transitions. The air graph uses
  0.1-second blends, 2x FS/BS into speed, 3x double into speed, and 2x out
  speed.
- `skate3_onboard_clips.csv` and `OnBoard.abin` contain the exact physical
  into/cycle/out and single/double transition families selected by this slice.
  The source SHA-256 values remain pinned in `src/grab_animation.rs`.
- Static `SkeletonIK::Init` findings establish compact OnBoard parts 0/1 as
  toe targets 32/33 and parts 2/3 as hand targets 34/35. Direct ABIN decoding
  confirms all selected grab actions animate channels 32 through 35.
- An offline Blender probe across the selected ground/air FS, BS, and double
  clips proves that the exported RX2 deform-hand labels use the opposing
  handedness convention from the compact target labels. Cross-paired active
  hands remain within 1--23 mm of their authored targets; matching labels are
  0.7--1.2 m apart and physically unreachable by the arm chain.
- The grab implementation was first validated in a 643-action merged-bank
  checkpoint containing all 26 selected basic grab leaves plus 138 authored
  advanced grab-family leaves. That historical GLB SHA-256 was
  `58204B5E3688E9AAD1CDB4D93DA73833B526661978DEAAC8ACBBA87A963AA0B1`.
  The current build packages those same authored leaves in the unified
  2,580-action `default_skate3_skater.glb`.
- The pinned ABIN catalog records the selected grab leaves at 30 Hz, while the
  private asset builder explicitly exports its Blender preview at 60 Hz.
  Therefore every live grab leaf converts authored sample position from 30 Hz
  to the private 60 Hz timeline; using elapsed retail seconds directly makes
  an advanced grab visibly finish its entry pose about twice too quickly.
- The recovered per-state `PlayAnimation` values are family-specific rather
  than a generic air-grab multiplier: FS/BS Into is 2.0, double Into is 3.0,
  mute/stale Into is 1.25, crail/seatbelt Into is 1.2, and all other advanced
  Into clips currently routed by the controller use the default 1.0.
- Those values belong to the virtual MotionGraph states. The physical Bevy
  adapter now consumes each decoded Into action once at its native duration;
  applying the virtual state multiplier again to the physical leaf made the
  normal reach expire 2x--3x early. This adapter placement is covered by
  duration-boundary tests but still awaits visual parity confirmation.
- FS/BS, double, mute, and stale cycle states filter both tweak axes with
  `blend=0.116`, `blendOut=0.133`, and `clampVel=0.1`. The recovered
  `FilterMotionGraphIntent::Update` at TU3 `0x82BB17D0` applies the selected
  blend coefficient to the raw/current difference, then clamps acceleration
  and velocity before publishing the filtered value. The update contains no
  delta-time multiplier. Tweak endpoint crossfades retain the running cycle
  clock instead of restarting a clip.
- Nose/tail/crail/seatbelt board-adjust trees use their distinct recovered
  filter (`blend=0.25`, `blendOut=0.08`, `clampAcc=0.03`, `clampVel=0.2`);
  these values are not replaced by the ordinary grab-tweak response.
- The supplied 60 fps Bevy recording shows the discontinuity on the first
  CYC-to-OUT frame. Source inspection proves that the previous adapter reduced
  a live multi-leaf tweak to one full-weight source and disabled hand IK at
  that same boundary. Release now carries all evaluated source leaves into the
  authored Out blend and fades the old hand solve by the exact transition
  source weight.
- Offline inspection of both decoded `IA_BODYSPIN_OLLIE_*_0_N` actions proves
  that they animate the compact `RIGHTHAND_REPARENTED` and
  `LEFTHAND_REPARENTED` channels, including target translations spanning more
  than one metre. Those channels are board-contact data, not upper-body pose
  output. The body-spin animation mask now preserves both hand targets
  alongside the already-masked board root and toe targets; post-animation IK
  therefore solves the grabbing arm against the active grab action's deck
  contact instead of a blended body-spin target.

## Strongly inferred adapter choices

- The recovered ground resources are virtual left/neutral/right blends.
  With no directional grab modifier in this first slice, their neutral
  `_N_..._0_` physical family members are used. Catalog adjacency and naming
  support this mapping, but selected-leaf runtime telemetry has not been
  captured.
- Air held cycles use the neutral zero-tweak physical leaves adjacent to the
  graph-named into/out families. The authored cardinal tweak endpoints are now
  routed discretely; continuous diagonal blend weights remain unresolved.
- `FilterMotionGraphIntent` is update-count based. The adapter preserves its
  canonical recurrence at the authored OnBoard cadence of 30 Hz, matching the
  pinned ABIN leaves and compact target channels. It temporally resamples that
  curve to the 60 Hz animation publisher: the midpoint is emitted on the
  intervening sample and every second output exactly equals the original 30 Hz
  state. This preserves the proven response duration without exposing 30 Hz
  stepping to the renderer. Static code proves the update equation and lack of
  delta scaling; a synchronized retail caller trace remains unavailable.
- The live project currently publishes regular stance only. Grab state stores
  mirroring separately and selector tests prove regular/switch hand mapping so
  a future stance publisher can connect without changing the state machine.

## Unresolved

- TU3 `cInputMap` bytecode that converts analog trigger bytes into the held
  `Left/RightGroundGrab` and `Left/RightAirGrab` actions has not been recovered.
  The Bevy hardware adapter therefore uses the documented XInput digital
  trigger boundary (strictly greater than raw byte 30) and does not claim that
  value as a recovered Skate 3 graph constant.
- Ground virtual blend weights for non-neutral body tilt and air tweak blend
  leaf selection are not implemented.
- Fakie timing is not published by the current simulation. Domain and stance
  are independent fields so that work can merge without replacing grab
  routing.

## Awaiting visual verification

The deterministic suite proves routing, timing, persistence, transition
selection, release, boundary carry-through, and no direct mutation of
velocity/heading/pop state. The one-click Bevy smoke test proves all 2,580
clips load and leaves no process running. Final hand placement, penetration, and
transition aesthetics still require the supplied in-game visual checklist.
