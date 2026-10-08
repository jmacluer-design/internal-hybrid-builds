# TU3 push-to-FlickIt anticipation handoff

This note covers the flat-ground transition from an active push into tail or
nose anticipation. It records the recovered retail route, the narrow source
port, and what still requires a human visual checkpoint. It does not claim
visual parity.

## Evidence identity

| Artifact | SHA-256 |
|---|---|
| TU3 loaded image `default_82000000_011B0000.bin` | `F4AA113EB541BFBA03DBC108CF5AB43F58C965B20FA3B82F9C40938A0AD841C4` |
| `MotionGraphIncludes/ground.xml` | `8947045346B81235A3A9A7D043A473D0388A0CDA2AA63F16FD485CFD63FB4FF9` |
| `skate3_onboard_clips.csv` | `7B2041D3E8FC305D589A05B65B72B5181319197B4CF4FC6C410C8BDDAA131D10` |
| Decoded private `skater_push.glb` | `78701FA920F1AA8DF54AFAD953DD5CBD3BFF961F69D262DED82A94DEBD7432B2` |

The XML and ABIN catalog are under the authorized
`C:\Users\Daddy\Documents\Skate3Research` tree. Static addresses below refer
to the pinned TU3 loaded image.

## Proven retail behavior

The `Push` parent in `ground.xml` explicitly groups anticipation transitions
among the routes which break out of a push. Both tail and nose routes are
stance/current-state gated.

- Push to tail anticipation targets `Anticipation.AnticInto.AnticTail`.
- Push to nose anticipation targets `Anticipation.AnticInto.AnticNose`.
- When `MongoPushFootToFar` is true, the graph runs the `MongoPushToAntic`
  hook with physical leaf `MONGO_PUSH_TO_ANTIC` or
  `MONGO_PUSH_TO_NANTIC`.
- When `MongoPushFootToFar` is false, the graph transitions directly to the
  anticipation target.
- Every route invokes `OverideNextAnimTransitionHook` with blend time `0.2`.

The ABIN catalog proves that both bridge leaves contain 13 samples at 60 Hz.
Twelve sample intervals at 60 Hz span exactly 0.2 seconds, matching the graph
override.

`MongoPushFootToFar` is constructed at `0x82BC5A40`; its evaluator is
`0x82BA6378`. The constructor resolves the exact strings `push_contact`,
`RightToeBase`, and `LeftToeBase`. The evaluator uses the IEEE-754 literal
`0xBF000000` (`-0.5`) while comparing the active toe/contact transform.
`MongoPushToAntic` is registered by the initializer at `0x82F89B80`, using
factory `0x82BCA830`; its behavior method is `0x82BBBBB8`.

These facts prove a moving leg-return branch and an ordinary pose-blend branch.
They also prove the duration. They do not yet prove the matrix coordinate
convention needed to reproduce `MongoPushFootToFar` from source data.

## Reproduced source failure

The deterministic `parity/replays/dual-push-ollie.json` replay showed the old
arbitration defect:

- fixed tick 151: push contact owns action weight `1.0`;
- fixed tick 152: `begin_anticipation` deletes push immediately and the new
  anticipation owns only `0.041666668`;
- the remaining weight falls through to riding, producing the one-frame
  stiffness/lock described by the user.

The old code also built the anticipation-to-trick handoff from anticipation
alone. A flick completed before the push exit blend had finished therefore
discarded the outgoing push/leg-return composite a second time.

## Implemented source contract

`PushAnticipationHandoff` owns the narrow transition seam:

1. Capture the current push action before clearing push gameplay state.
2. Preserve total action ownership at `1.0` throughout the exact 0.2-second
   push-to-anticipation interval.
3. For the bridge route, advance the authored bridge clip from 0.0 to 0.2
   seconds while its weight falls from 1.0 to 0.0.
4. For the direct route, preserve the current push pose while its weight falls
   over the same interval.
5. Blend the selected tail/nose anticipation leaves from 0.0 to 1.0.
6. If FlickIt resolves a trick before the interval completes, carry the whole
   bridge-plus-anticipation composite into the existing 0.05-second
   anticipation-to-trick handoff.

After the change, the same replay reports:

- fixed tick 152: `MONGO_PUSH_TO_ANTIC` weight `0.958333`, seek `0.008333`,
  anticipation weight `0.041667`, total action weight `1.0`;
- fixed tick 163: bridge and anticipation each own `0.5`, total action weight
  remains `1.0`;
- fixed ticks 164-168: the quick ollie blends from the preserved composite
  into `OLLIE_LOW_G`; total action weight remains `1.0`;
- fixed tick 169: `OLLIE_LOW_G` owns action weight `1.0`.

The private asset build contains exactly 275 validated actions, including both
13-frame bridge leaves. Existing action names, root-motion records, and the
GLB animation table are checked as exact sets by
`tools/build_private_assets.ps1`.

## Inferred and unresolved

The source sim does not yet expose the post-animation active-toe transform and
native `push_contact` provider in the same coordinate space. The implemented
bridge gate is therefore deliberately bounded: the dedicated bridge is used
only for the regular/right-foot `MONGO` animation family during Push Contact
or Push Cycle. Other push phases and the opposite-foot family use the proven
direct 0.2-second blend.

That mapping is inferred from the authored clip family and graph placement; it
is not a claimed translation of the native `-0.5` transform test. Recovering
the exact provider/matrix convention remains unresolved. Stance mirroring,
the perceived leg-return shape, crouch continuity, and all normal/mongo
combinations await the owner's visual checkpoint.
