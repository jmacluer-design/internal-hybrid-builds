# Flickit kickflip/heelflip multi-flip recovery

## Scope

This specification covers `Kickflip`, `Heelflip`, `N_Kickflip`, and
`N_Heelflip`, including their single, double, triple, and quad exits. It does
not alter ollie/nollie carriers, generic landing classification, touchdown
friction, push behavior, underflips, or dark catches.

## Evidence classes

- **Proven / graph-authored:** state topology, hold predicates,
  `TimeToLand` boundaries, sequence transitions, `transitionUnder`, and the
  0.05-second `WillExpire` handoff come directly from the pinned retail
  `T_Kickflip.xml`.
- **Proven / matcher-authored:** gesture coordinates and tolerance come from
  the embedded authorized retail `joystick/skater.pat`.
- **Observed / catalog:** physical action names, order, frame counts, 60 Hz
  rate, and eight-part layout come from the decoded OnBoard ABIN catalog.
- **Observed / runtime:** existing isolated normal kickflip/heelflip traces
  recorded the ordinary `OUT1` low/high trees and their overlap into general
  air.
- **Derived:** the matching selected PatternNode remains the trick's `*Hold`
  while the latest processed stick sample is within the authored final-node
  tolerance. This follows the recovered selected-pattern hold/release
  producer; no extra hold deadzone is introduced.
- **Inferred:** the four catalog groups below are the physical children of the
  corresponding cycle/out resources by exact tail/nose, kick/heel, low/high,
  and CYC/OUT naming and ordering. New harness use was not authorized.
- **Awaiting human visual verification:** perceived body/board parity,
  especially unequal-duration low/high blends and catches after OUT2-OUT4.

## Exact Flickit paths and hold region

Coordinates are normalized PatternNode matcher space. Raw controller Y is the
negative of the displayed Y.

| Winner | Tolerance | Matcher path | Hold target |
| --- | ---: | --- | --- |
| `Kickflip` | 0.40 | `(-0.028571,0.691429) -> (0.908571,-0.417143)` | `(0.908571,-0.417143)` |
| `Heelflip` | 0.40 | `(-0.291429,0.622857) -> (-0.680000,-0.714286)` | `(-0.680000,-0.714286)` |
| `N_Kickflip` | 0.40 | `(-0.017143,-0.691429) -> (0.714286,0.668571)` | `(0.714286,0.668571)` |
| `N_Heelflip` | 0.40 | `(0.005714,-0.691429) -> (-0.737143,0.645714)` | `(-0.737143,0.645714)` |

A quick flick may leave the final radius after recognition; that clears the
hold and selects `OUT1`. Keeping the stick within the final 0.40 radius keeps
the selected pattern held. Existing regular/switch identity remapping occurs
before graph routing, so the resolved winner name—not a separately guessed
screen direction—is compared with the active trick.

## Authored graph sequence

1. Play the physical retail `IN_G` leaf, followed by its physical `IN_A` leaf.
2. At `IN_A` expiry:
   - release to `OUT1` if hold is absent, `TimeToLand < 0.525`, or the body is
     flipping;
   - otherwise enter `CYC1`.
3. At `CYC1` expiry:
   - release to `OUT2` if hold is absent, `TimeToLand < 0.8`, or the body is
     flipping;
   - otherwise enter `CYC2`.
4. At `CYC2` expiry, release to `OUT3` if hold is absent or the body is
   flipping; otherwise enter `CYC3`.
5. `CYC3` always expires to `OUT4`.
6. Every OUT begins its `InAir`, `Land`, or `OnBoard` handoff at
   `WillExpire InTime="0.05"`.

The `TimeToLand` comparisons are strict. Exactly 0.525 and 0.8 seconds remain
eligible to continue. The first two gates prevent an extra flip when the
current measured carrier cannot accommodate it; the carrier and gravity are
unchanged.

## Physical animation mapping

The decoded IN streams are local transform deltas, like every physical ABIN
clip. The standard importer applies AddBindPose/AddSQT against `RIG_TPOSE`
once, producing the complete physical `KICKFLIP_IN_*`, `HEELFLIP_IN_*`, and
nollie actions requested directly by `T_Kickflip.xml`. They must not then be
composed over an already-complete ollie/nollie pose. The measured ollie/nollie
carrier remains responsible for trajectory; it is not a second skeletal
animation layer. Cycle and out actions are likewise exported directly. Counts
below are authored samples at 60 Hz, listed as high / low.

| Family | IN G/A low | IN G/A high | CYC1/2/3 high / low | OUT1/2/3/4 high / low |
| --- | --- | --- | --- | --- |
| Tail kick | 13 / 11 | 13 / 14 | `12,29,27 / 13,27,27` | `12,27,28,27 / 17,27,27,31` |
| Tail heel | 13 / 12 | 13 / 12 | `13,28,29 / 13,28,29` | `16,28,28,29 / 13,28,28,29` |
| Nose kick | 13 / 17 | 13 / 17 | `13,25,27 / 13,25,27` | `13,25,25,30 / 17,25,26,30` |
| Nose heel | 13 / 14 | 13 / 14 | `11,22,24 / 11,22,24` | `13,29,30,23 / 13,29,30,23` |

The final 0.05 seconds of OUT remain visible underneath the existing
0.2-second general-air blend. This is the authored `WillExpire` plus
`transitionUnder` catch seam already recovered for 360 Flip, not arbitrary
pose smoothing.

## Deterministic coverage

Tests protect:

- exact selected-pattern held/released behavior at the final matcher radius;
- routing of all four normal/nollie identities to their matching IN poses;
- physical low/high mapping for all 12 cycle and 16 out resources;
- release after each hold window selecting OUT1, OUT2, OUT3, or OUT4;
- retention of each selected OUT tail under the general-air catch blend;
- 60 Hz exported-timeline addressing for physical IN and raw loop actions;
- all existing one-shot Flickit and ollie/nollie tests through the full suite.

The offline launcher check requires every runtime-selected physical IN,
cycle, and out action and validates both foot targets and the rider-axis
upright invariant without starting Bevy or SK8. The unified private bank
contains 643 actions because it also includes the complete grab slice and the
disproven `COMBINED_*` actions retained as negative-control artifacts; no
runtime route selects those generated actions. The
validated generated
`skater_push.single-rotation-candidate.glb` has SHA-256
`BD5ECF0D6CB76AB3914A9A251F914E114975A40DBEAC8A8D1260E5E8DFFA334D`;
all 56 cycle/out actions remained within the existing 0.05 m toe-target bound
(measured maximum 0.03555517311 m).

## First-phase deformation diagnosis

**Observed:** in `2026-09-01 01-46-08.mp4`, the skater deforms during
`takeoff_ground` and `left_ground_air` while the overlay reports
`COMBINED_HEELFLIP_*`. The rider immediately returns to a coherent pose on
entry to `T_*_HEEL_CYC1`; later cycles, OUT, catch, and landing remain coherent.
Both live foot-IK errors report `0.00 mm`, excluding foot-target correction as
the source of this first-phase failure.

**Derived from the exported GLB:** the 16 direct physical IN actions have
maximum head-to-feet rider-axis tilts from `15.44°` to `30.26°`. The 16
double-composed negative controls range from `71.23°` to `132.37°`, including
the sideways/upside-down body orientation visible in the recording.

**Proven by graph and importer evidence:** `T_Kickflip.xml` requests the
physical `$ANIM_NAME$_G` then `$ANIM_NAME$_A` leaves directly. The ABIN
importer's AddBindPose contract already turns each decoded delta stream into a
complete physical pose. Selecting those actions directly therefore follows
the graph and avoids applying the local transforms twice.

**Awaiting human visual verification:** perceived parity of the corrected
physical IN-to-CYC1 transition for quick single flips and held multi-flips.
