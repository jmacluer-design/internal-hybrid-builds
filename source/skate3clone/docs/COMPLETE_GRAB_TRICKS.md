# Complete authored grab-trick slice

This slice routes controller input to decoded Skate 3 OnBoard ABIN actions. It
does not synthesize reach poses or replace the recovered action/motion graph.
The current unified private Bevy asset contains 2,580 actions, including 138 authored
advanced grab-family leaves from catalog intervals 477–512, 551–623, 645–680,
and 694–699 alongside the complete merged Flickit, landing, and locomotion bank.

## Controller routes

The current unmirrored controller route preserves the visually validated basic
mapping: LT owns the same left-hand/FS graph family as the prior slice and RT
owns the opposite family. The existing mirrored identity boundary swaps the
corresponding stance side and horizontal tweak direction. Publishing the
character's final regular/goofy stance flag remains outside this slice, so this
document does not relabel the validated trigger-to-hand mapping.

| Input | Result |
| --- | --- |
| LT / RT / LT+RT | FS / BS / double grab |
| Hold trigger, then RS up/down/left/right | authored grab tweak |
| RS up, then LT / RT | tail grab / seatbelt |
| RS down, then LT / RT | crail / nose grab |
| RS right, then LT / RT | stalefish / mute |
| RS down, then LT+RT | rocket air |
| LT+B / RT+B | no-foot air / Christ air |
| LT+RT+B | Superdude |
| Tail or nose route + B | tailwalk / airwalk |
| LT+A / LT+X | Frigid air / FS one-foot air |
| RT+X / RT+A | Judo / one-foot air |
| Nose route + X / A | Dog Piss / Judo nose grab |
| Tail route + A / X | one-foot tail grab / Benihana |
| LT+RT+A+X | Coffin |

For Nose, Tail, Crail, and Seatbelt, moving RS horizontally after admission
selects the authored FS/BS shifty family. Mute and Stale retain their authored
nosebone, tailbone, and tuck-knee/Japan endpoints. A stick held before trigger
admission selects a family; it must return to neutral before it is armed as a
post-admission tweak. This preserves the recovered `RS > trigger` versus
`trigger + RS` distinction.

Post-admission cardinal tweak changes retain the current repeating-cycle phase.
FS/BS, double, mute, and stale endpoint crossfades follow their recovered
`FilterMotionGraphIntent` response (`blend=0.116`, `blendOut=0.133`,
`clampVel=0.1`). The canonical recurrence remains on the authored 30 Hz
grab-graph clock, but the mixer receives an exact 60 Hz temporal resample:
each odd sample is the midpoint to the next canonical state and each even
sample is that canonical state. This doubles visual smoothness without
shortening the response. Nose/tail/crail/seatbelt shifties retain their
separate board-adjust response (`blend=0.25`, `blendOut=0.08`,
`clampAcc=0.03`, `clampVel=0.2`). Neither path restarts the target cycle at
frame zero.

The Bevy physical-leaf clock consumes each decoded Into action once at its
native authored duration. Reapplying the virtual MotionGraph state's
family-specific speed to the already decoded physical action caused the normal
FS/BS and double reaches to expire early. The recovered graph speed constants
remain recorded at the virtual-graph boundary rather than being silently
discarded.

Releasing during a filtered tweak preserves every live source leaf and its
weight while the authored Out leaf blends in. The OnBoard hand constraint
fades by that same recovered `PlayAnimation` source contribution, preventing
the solved arm from disappearing on the CYC-to-OUT frame.

Airborne body-spin overlays mask all four compact OnBoard contact targets:
both toe targets and both hand targets. This keeps the grab action's authored
deck contact authoritative while the spin clip animates the torso and free
arm, after which the existing hand IK solve runs against the unchanged board
target.

## Evidence boundary

Proven locally:

- trigger actions, BoardAdjust angle sectors, graph routes, physical ABIN clip
  names and frame counts, into/cycle/out phases, board authority, hand
  ownership, and released-foot selection;
- grounded grabs remain in the grounded graph and do not create pop;
- ordinary airborne grabs retain animation board authority; Coffin and
  Superdude use the graph's physics authority;
- the generated GLB, manifest, and root-motion action sets are exactly 437.

Corroborated externally:

- the published Skate 3 air-trick list and its regular/goofy input ordering.

Still unresolved:

- the upstream TU3 analog trigger publication threshold (the port retains the
  documented XInput raw threshold already used by the validated basic slice);
- continuous diagonal tweak interpolation between authored cardinal endpoints;
- unfinished forward/fakie stance timing outside this slice.

Awaiting visual verification:

- aesthetic hand/board contact and limb silhouette across every character pose,
  especially one-foot and two-foot dismount families.
