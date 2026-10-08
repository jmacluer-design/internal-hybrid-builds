# Flickit one-shot trick recovery

## Scope and evidence boundary

This pass implements the 24 tail/nose one-shot identities in retail
`Tricks.xml` other than the four looping flip identities. `Kickflip`,
`Heelflip`, `N_Kickflip`, and `N_Heelflip` are outside this document's
one-shot scope:
`T_Kickflip` owns the retail `In -> Cyc1..3 -> Out1..4` multi-flip graph and
is specified separately in `FLICKIT_MULTI_FLIP_SPEC.md`. Existing Ollie,
Nollie, and 360 Flip behavior is preserved.

Evidence used:

- **Proven:** primary paths and tolerances are parsed from the authorized
  retail `joystick/skater.pat`; runtime tests feed that embedded database
  rather than a hand-maintained replacement.
- **Proven:** normal, `+90`, `-90`, airborne, and fingerflip patterns are
  separate retail files and separate gesture contexts. The recovered input
  update constructs and visits the context-selected pattern collection; it
  does not flatten all five right-stick files into one winner scan.
- **Proven:** trick identity, virtual G/A resources, graph template, and
  `WillExpire InTime="0.05"` sequence behavior come from retail `Tricks.xml`
  and the recovered graph trees.
- **Proven:** physical action names, sample counts, and frames come from the
  extracted OnBoard ABIN catalog.
- **Derived:** PatternNode reflects raw XInput Y once. Thus the exact hardware
  path is `(x, -y)` for every normalized matcher coordinate below.
- **Derived:** the deterministic four-node test moves one interior sample
  within the authored `0.40` radius when an exact sparse sample would complete
  a shorter rotated shuv first. This is a fixture sampling correction, not a
  replacement for the authored path.
- **Inferred:** where a physical family has named professional alternatives,
  the unqualified/default `D` family is selected. This matches the
  identity-round-tripped 360 Flip default, but no new live retail capture was
  authorized for this pass.
- **Awaiting human visual verification:** final perceived parity for all 24
  identities. No visual-parity claim is made here.

## Exact primary Flickit paths

Coordinates are normalized retail PatternNode matcher space. Read each row
left to right. To reproduce the raw controller input, negate every displayed
Y coordinate.

| Retail winner | Tolerance | Exact PatternNode path |
| --- | ---: | --- |
| `PopShuvit` | 0.35 | `(0.257143,0.942857) -> (0.862857,0.451429) -> (0.908571,-0.360000)` |
| `FSPopShuvit` | 0.35 | `(-0.200000,0.965714) -> (-0.851429,0.520000) -> (-0.942857,-0.280000)` |
| `VarialKickflip` | 0.40 | `(-0.702857,0.702857) -> (0.234286,0.954286) -> (0.851429,-0.508571)` |
| `VarialHeelflip` | 0.40 | `(0.725714,0.702857) -> (-0.131429,0.977143) -> (-0.497143,-0.840000)` |
| `Hardflip` | 0.40 | `(0.737143,0.668571) -> (-0.142857,0.988571) -> (0.600000,-0.771429)` |
| `InwardHeelflip` | 0.40 | `(-0.714286,0.714286) -> (0.211429,0.977143) -> (-0.737143,-0.645714)` |
| `360PopShuvit` | 0.35 | `(-0.874286,0.485714) -> (0.165714,0.988571) -> (0.954286,0.245714)` |
| `FS360PopShuvit` | 0.35 | `(0.862857,0.485714) -> (-0.165714,0.988571) -> (-0.965714,0.257143)` |
| `360Flip` | 0.40 | `(-0.965714,0.268571) -> (-0.497143,0.840000) -> (0.211429,0.988571) -> (0.908571,-0.405714)` |
| `Laserflip` | 0.40 | `(1.000000,0.177143) -> (0.657143,0.760000) -> (0.040000,0.988571) -> (-0.840000,-0.485714)` |
| `360Hardflip` | 0.40 | `(0.977143,0.177143) -> (0.577143,0.817143) -> (-0.120000,0.988571) -> (0.702857,-0.691429)` |
| `360InwardHeelflip` | 0.40 | `(-0.977143,0.177143) -> (-0.634286,0.760000) -> (0.051429,0.977143) -> (-0.497143,-0.828571)` |
| `N_PopShuvit` | 0.35 | `(0.268571,-0.965714) -> (0.931429,-0.371429) -> (0.840000,0.508571)` |
| `N_FSPopShuvit` | 0.35 | `(-0.222857,-1.000000) -> (-0.920000,-0.508571) -> (-0.920000,0.440000)` |
| `N_VarialKickflip` | 0.40 | `(-0.611429,-0.794286) -> (0.291429,-0.942857) -> (0.245714,0.817143)` |
| `N_VarialHeelflip` | 0.40 | `(0.691429,-0.714286) -> (-0.200000,-0.965714) -> (-0.440000,0.725714)` |
| `N_Hardflip` | 0.40 | `(0.680000,-0.725714) -> (-0.222857,-0.965714) -> (0.748571,0.577143)` |
| `N_InwardHeelflip` | 0.40 | `(-0.622857,-0.794286) -> (0.314286,-0.931429) -> (-0.760000,0.645714)` |
| `N_360PopShuvit` | 0.35 | `(-0.862857,-0.497143) -> (0.177143,-0.988571) -> (0.942857,-0.291429)` |
| `N_FS360PopShuvit` | 0.35 | `(0.954286,-0.588571) -> (-0.200000,-0.885714) -> (-1.000000,-0.280000)` |
| `N_360Flip` | 0.40 | `(-0.965714,-0.200000) -> (-0.554286,-0.840000) -> (0.097143,-0.977143) -> (0.851429,0.531429)` |
| `N_Laserflip` | 0.40 | `(0.954286,-0.268571) -> (0.508571,-0.862857) -> (-0.188571,-0.725714) -> (-0.737143,0.645714)` |
| `N_360Hardflip` | 0.40 | `(0.988571,-0.142857) -> (0.634286,-0.782857) -> (-0.200000,-0.977143) -> (0.748571,0.565714)` |
| `N_360InwardHeelflip` | 0.40 | `(-0.954286,-0.257143) -> (-0.485714,-0.862857) -> (0.234286,-0.965714) -> (-0.840000,0.520000)` |

The recognizer still applies retail stance/switch remapping after controller
normalization. These rows are the regular-stance primary definitions, not a
second guessed set of mirrored gestures.

## Pattern-context admission

The playable on-ground recognizer owns only the 78 patterns from
`skater.pat`. The 78 `skater90.pat` patterns, 78 `skaterN90.pat` patterns,
21 `skater_air.pat` patterns, and 14 `skater_fingerflip.pat` patterns remain
available through explicit typed contexts, but cannot compete in the normal
ground winner scan.

This separation fixes two deterministic failures without changing any retail
coordinate or tolerance:

- a smooth primary `360PopShuvit` path previously published
  `90_PopShuvit` first; the normal trick router then rejected that unrelated
  identity;
- the same cross-context competition affected smooth nose paths, making
  supported `N_*` one-shot tricks appear unavailable even though their
  physical animation routes were complete.

Regression coverage now interpolates every three-coordinate supported primary
path, including all eight three-coordinate `N_*` one-shot paths, and requires
the unprefixed `skater.pat` identity. Four-coordinate flip-plus-shove paths
retain their separately pinned interior fixtures because a shorter shuv in the
same legitimate context can complete at coordinate three.

## Animation graph and physical leaves

The shuvit pair uses `T_TrickWithUnderflip`; the 360 Flip, Laserflip,
360 Hardflip, and 360 Inward Heelflip families use
`T_TrickWithDarkCatch`; the remaining one-shot identities use `T_Trick`.
All sequence physical G into physical A, begin expiration 0.05 seconds before
the A endpoint, and retain that final A tail underneath the recovered
0.2-second `B_AIR_CYC` handoff. The implementation therefore generalizes the
evidence-backed 360 Flip catch seam instead of adding per-trick smoothing.

Each identity maps to its exact low/high G/A physical family:

| Tail family | Nose family |
| --- | --- |
| `POPSHUVIT_*` | `N_POPSHUVIT_*` |
| `FSPOPSHUVIT_D_*` | `N_FSPOPSHUVIT_*` |
| `VARIALKICKFLIP_*` | `N_VARIALKICKFLIP_*` |
| `VARIALHEELFLIP_D_*` | `N_VARIALHEELFLIP_*` |
| `HARDFLIP_*` | `N_HARDFLIP_*` |
| `INWARDHEELFLIP_*` | `N_INWARDHEELFLIP_*` |
| `360POPSHUVIT_*` | `N_360POPSHUVIT_*` |
| `FS360POPSHUVIT_*` | `N_FS360POPSHUVIT_*` |
| `360FLIP_D_*` | `N_360FLIP_*` |
| `LASERFLIP_*` | `N_LASERFLIP_*` |
| `360HARDFLIP_*` | `N_360HARDFLIP_*` |
| `360INWARDHEELFLIP_*` | `N_360INWARDHEELFLIP_*` |

`*` expands to `LOW_G`, `LOW_A`, `HIGH_G`, and `HIGH_A`. These are complete
physical retail poses. They are not recomposed as additive Ollie deltas.
