# Skate 3 TU3 onboard structural gap register

This register keeps the current Bevy implementation separate from behavior
that has actually been recovered from TU3. A matching-looking flat-ground
trajectory is not treated as proof of the underlying system.

## Evidence scope

The function identities below are observed in the authorized TU3 research
database/recompilation artifacts. Their relationships to the proposed work
packages are derived from call sites and state ownership. Unresolved constants
and structures remain evidence tasks rather than implementation defaults.

## Ground and surface provider

Observed functions:

- `0x82C02840` `Skateboard::CalculateGroundPos`
- `0x82D76F80` `SurfaceQuery::GetResult`
- `0x82D85D08` `SurfacePhysics`
- `0x82D8C8F0` ground-state reckoning

Current gap: the Bevy port forces flat world height and therefore cannot
reproduce four-wheel contact, sloped riding, seams, banks, transition loss, or
retail landing classification.

Required evidence-backed output:

- query origin/direction/range semantics;
- hit point, normal, material/surface identity, and validity lifetime;
- loss/reacquisition behavior;
- how the board ground position is aggregated from wheel/deck queries.

## Skateboard body construction

Observed functions:

- `0x82C09290` `CreateTriangleDeck`
- `0x82C0A6F8` `CreateTrucks`
- `0x82C0AA78` `CreateWheels`
- `0x82C0B770` `CreateDrives`
- `0x82C0C268` `CreateJoints`
- `0x82C0CF60` `CreateWheelDrives`
- `0x82C08968` `AverageWheelCompressions`

Current gap: the port presents deck/truck/wheel transforms but does not yet
model the retail rigid deck, independent wheel contacts, joint constraints, or
drive state. The existing counter-articulation is presentation scaffolding,
not evidence that wheel contact has been reproduced.

Required evidence-backed output:

- body count, shapes, local pivots, masses/inertias, and collision filtering;
- joint axes, limits, drive targets, spring/damping, and force limits;
- wheel radius/contact and compression aggregation;
- board pose source before and after physics.

## Riding force and heading pipeline

Observed functions:

- `0x82C03EF0` `AddSkateboardForce`
- `0x82C02138` `UpdatePostPhysics`
- `0x82C05988` `PostPhysics_AdjustHeading`
- `0x82D8A828` `CalculateHeadingAdjustFactor`
- `0x82BC74A8` `SettingBodyTilt`
- `0x82BC7408` `ApplyingBodyTilt`

Current gap: the port has captured flat-ground response curves but still
integrates a planar approximation. Those curves remain useful fixtures; they
must not be mistaken for the retail force/contact architecture.

Required evidence-backed output:

- force application positions, axes, and tick ordering;
- heading correction inputs and output ownership;
- longitudinal/lateral tire response and energy loss;
- deck/truck result consumed by body-tilt attributes;
- slope, bank, seam, and partial-contact behavior.

## Push pipeline

Observed functions:

- `0x82BAD7A8` `ComputeFirstPushStrength::Update`
- `0x82BADCD0` and `0x82BADE38` push-cycle stages
- `0x82BAE210` push-out stage
- `0x82DEFF38` `SetPushCoefs::Ramp`
- `0x82E311A8` `ComputeRepushDeadline::End`
- `0x82BAD258` recovered target-coefficient solver

The target-coefficient solver and the verified retail leaves in
`src/retail_push.rs` are high-confidence recovered behavior. Remaining work is
to attach their animation/contact phases to the physical board force pipeline,
then verify tap, hold, repush, regular, mongo, low/high strength, and speed-band
transitions against synchronized retail telemetry.

## Powerslide pipeline

Observed functions:

- `0x82BC01C0` `PowerSliding::Update`
- `0x82BB31B0` `PowerSlideDecel`
- `0x82BB33C8` `PowerSlideSpin`
- `0x82BB2F60` `CreateSlide`

The current entry negatives and measured flat-ground response are fixtures.
Pending recovery includes exact contact/force ownership, slide creation and
exit state, speed-band animation tree coordinates, and behavior on banks or
incomplete wheel contact.

## Riding animation tree

Current exported coverage contains only seven HCOM/LCOM/ride leaves and does
not constitute the full retail riding graph. Required recovery includes:

- HCOM, LCOM, and RIDE coordinates and conditioning;
- speed, stance, switch/fakie, board-physics, and terrain attributes;
- virtual-resource-to-concrete-leaf resolution;
- fixed-clock local time, playback rate, and transition weights.

## Integration order

1. Ground provider with deterministic level/slope/bank/seam fixtures.
2. Retail board body and independent wheel manifold.
3. Riding force, heading correction, and physical body-tilt outputs.
4. Push and powerslide force attachment.
5. Full onboard action/motion graph and riding animation blend tree.
6. Presentation transforms driven only by the selected authority.
7. Synchronized retail/Bevy matrix on flat, slope, bank, seam, and ramp maps.

The integration gate for every work package is automated determinism and
captured telemetry. Human visual verification remains a later checkpoint.
