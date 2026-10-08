# Flat-ground push response

This note separates recovered retail facts from the remaining candidate
behavior in the Bevy port. It does not claim visual parity.

## Evidence identity

- TU3 loaded image `default_82000000_011B0000.bin` SHA-256:
  `F4AA113EB541BFBA03DBC108CF5AB43F58C965B20FA3B82F9C40938A0AD841C4`.
- Runtime `default.xex` SHA-256:
  `1DB39496585C521D17A2137804F42CF73EBED2B32CAC166EC42DBF772F4DCF7F`.
- `OnBoard.abin` SHA-256:
  `30AA324D6D7C51C325D53E9268C1AD91783B0154D21BBEF5DC5A61EAE8333BD7`.
- Private decoded GLB SHA-256:
  `78701FA920F1AA8DF54AFAD953DD5CBD3BFF961F69D262DED82A94DEBD7432B2`.
  Its validation manifest reports 275 actions; the push leaves retain native
  60 Hz sample counts.
- `MotionGraphIncludes/Push.xml` SHA-256:
  `AFB7BA9281F2A8883E76B8F80394DA8D4CDAE36396E96093EEDC750ADB593532`.
- IDA strength-map decompilation SHA-256:
  `016CDA12F6341ACACDADAE9832AADACCB50B6A4BA31FAF31ACD32E5CBC0323AC`.
- IDA first-strength update decompilation SHA-256:
  `12BAFC980A45404FF667FACE7D94AB1552EB122208F425F4BCDE6092DAAAC5E4`.

## Proven

### Native strength state

`ComputeFirstPushStrength::Update` at TU3 `0x82BAD7A8` reads `NewPush`,
evaluates the result through `0x82BAD658`, and retains the maximum result in
the shared push state. When the intent is released, the result stops
increasing. `0x82BAD658` divides the accumulated intent value by a
speed-dependent point graph, clamps it to `[0, 1]`, then evaluates a second
point graph.

`PushCycle::Begin` (`0x82BADCD0`) and `PushCycle::Update` (`0x82BADE38`)
separately track a later `NewPush`/foot-intent press and release. This proves
that first-push strength and buffered re-push strength are separate state, not
animation elapsed time.

The two point-graph payloads live in the runtime attribute object (offsets
`+576/+608` and `+656/+688`). An authorized, read-only runtime capture on
2026-08-31 followed the loaded attribute pointer and recovered both arrays:

| Output input | Push delta (m/s) |
|---:|---:|
| 0.0000000 | 0.750000 |
| 0.2416999 | 1.044643 |
| 0.3426295 | 1.430357 |
| 0.4196547 | 2.041071 |
| 0.5152723 | 2.523214 |
| 0.7675963 | 2.973214 |
| 0.8844622 | 3.503571 |
| 1.0000000 | 4.500000 |

The normalizer graph is `(speed, value)`:

`(0,0.2267857), (0.3239329,0.25), (1.038274,0.25),
(2.878486,0.25), (4.616866,0.25), (5.553785,0.25),
(6.671315,0.25), (8.477424,0.25)`.

This proves that the result of `0x82BAD658` is a push delta velocity, not a
normalized strength scalar. The old candidate incorrectly multiplied a
normalized delivery profile by a separate gain equation.

### Requested velocity and animation coordinates

`src/retail_push.rs` is a direct translation of
`ComputeTargetCoefsFromSpeedAndStrength` at TU3 `0x82BAD258`. The CYC1
duration, `Vel_B`, and `Vel_E` values come from `OnBoard.abin`; they are not
tuned values.

The function's third input is the resolved push strength. It is not the
speed-cap-limited velocity still available to the board. The port now keeps
those values separate: requested physical delta may approach zero at the
8.5 m/s cap while a held repeat continues to drive the HSTR animation
coordinate. Previously, the animation incorrectly fell toward LSTR after a
few repeats as physical headroom disappeared.

### State cadence

The recovered XML establishes:

1. `PushStart`: `INTO`, 0.3-second transition, exit at `WillExpire 0.01`.
2. `PushContact`: `CYC1`, exit at `WillExpire 0.01`.
3. `PushCycle`: `CYC2`, exit at `WillExpire 0.01`; a continuing/new push
   returns to `PushContact` without replaying `INTO`.
4. `PushEnd`: authored `OUT`, exit at `WillExpire 0.1`.
5. Riding receives a 0.2-second entry blend.

Phase duration remains coefficient-dependent because the synchronized child
clips have different authored lengths. The deterministic fixtures therefore
measure the actual blended result rather than replacing it with a fixed
cadence constant.

## Derived candidate implemented here

Three synchronized, fresh-start captures used identical 60 Hz input packets.
Robust nonzero retail speed medians after the drive were approximately
`1.97`, `2.97`, and `4.64 m/s` for one, six, and eighteen held frames.
The latter two align with exact recovered output points `2.973214` and
`4.5`; the one-frame trajectory aligns with the `2.041071` point. Before this
correction the Bevy maxima were `0.104776`, `1.389751`, and `4.564708 m/s`.

The implemented rest mapping therefore converts the observed hold anchors
back to the native `NewPush` intent domain using the recovered zero-speed
normalizer:

| Hold | Native coordinate | Frozen push delta |
|---:|---:|---:|
| 1 frame (0.016667 s) | 0.4196547 | 2.041071 m/s |
| 6 frames (0.100000 s) | 0.7675963 | 2.973214 m/s |
| 18 frames (0.300000 s) | 1.0000000 | 4.500000 m/s |

Between measured hold anchors the candidate linearly interpolates in
`NewPush` intent space, then evaluates the exact native output graph. For a
moving push it divides that intent by the exact speed-dependent normalizer
before evaluating the output. The 6f-to-18f intent slope is continued only
until intent `0.25`, allowing a sufficiently long moving hold to reach the
native full-strength endpoint. That final continuation is derived, not a
directly observed hold sample.

The pre-existing five-point profile
`(0,0), (0.14,0.058), (0.50,0.517), (0.86,0.962), (1,1)` is retained solely
for frame-by-frame acceleration delivery. It no longer selects push strength.
The board receives no push acceleration when the push state starts.

The first-drive interval is source time `0.300..0.483` in the measured
31-sample regular-push reference `INTO`, or push-state time `0.600..0.783`
after the 0.3-second entry transition. The synchronized low-strength neutral
`N` leaf used by the X/mongo action has only 11 samples. Applying the
reference's absolute source times to that leaf allowed `WillExpire` to end the
state after only 13.7% of the drive, despite correctly selecting
`R_PUSHLSP_LSTR_N_0_INTO`.

For an `INTO` tree whose coefficient-weighted source duration is shorter than
the reference drive end, the candidate now preserves the measured reference
fractions (`0.300/0.500` through `0.483/0.500`) and clamps completion to the
recovered `WillExpire 0.01` boundary. This duration adaptation is derived from
the exact ABIN sample counts and measured regular-push window; it is not a
direct retail contact event. Longer trees retain the absolute measured
`0.300..0.483` source interval.

Repeated held pushes deliver their next gain over the following `CYC1`. A
separately tapped buffer retains and activates its own strength and cannot
start until the current `CYC2` expires.

Headless fixture results from rest:

- one-frame tap: maximum observed speed `2.040779 m/s`, then one clean
  `PushContact -> PushCycle -> PushEnd`;
- one-frame X/mongo tap: low-strength neutral `N` INTO leaf, full drive
  progress, maximum observed speed `2.040779 m/s` (previously `0.23 m/s` and
  13.7% drive progress);
- six-frame hold: maximum observed speed `2.972922 m/s`;
- eighteen-frame hold: maximum observed speed `4.499708 m/s`.

The three regular-foot hold fixtures remain at zero until the first authored
drive sample at push-state time `0.608333`; they reach the frozen target at
`0.783333`. The small difference between requested and maximum fixture speed
is the existing rolling update that runs later in the same fixed step.

In the held-repeat fixture, repeats at the cap retain strength `4.5`,
`Vel_E = 1.0`, and the `HSTR` CYC1/CYC2 leaves while cap-limited physical
delta falls to `0.031814 m/s`. This is the deterministic regression check for
the previously stiff later pushes.

## Unresolved

- Exact `NewPush` intent values between the synchronized one-, six-, and
  eighteen-frame hold anchors, especially the post-0.3-second moving-speed
  continuation.
- Exact `ComputeRepushDeadline` value and emergency-exit threshold. The
  community symbol at `0x82E311A8` is not accepted as evidence.
- Collision-authored foot release, ground contact, drive, and replant markers.
  The decoded clips prove source motion and timing but do not contain a
  trustworthy contact-classification event. `src/foot_placement.rs` therefore
  remains unchanged.
- Human confirmation that the derived short-leaf duration adaptation makes
  the one-frame X/mongo pose read as the intended ultra-slow push rather than
  merely completing its numerically correct drive.
- Final-matrix and perceived-cadence parity. These await the user's visual
  checkpoint.
