# Transition physics evidence ledger

This ledger is the evidence gate for transition traversal in the main
University build.
It does not treat a visually plausible controller as Skate 3 parity.

## Baseline reset

The rejected transition controller was removed in commits `1823068`,
`87a0060`, and `cab9a83`. It had directly snapped the skater root to a sampled
surface, projected velocity onto an analytic tangent every update, teleported
through the lip boundary, and reused the flat-ground Ollie gravity fit as world
gravity. None of those operations was present in the recovered retail path.

The former Blender-authored mini-park is not shipped or loaded as a playable
map. Its 314 collision triangles remain only as a `#[cfg(test)]` deterministic
fixture in `assets/transition/two_quarter_pipe_transition_test.collider.json`.
`src/transition_test_terrain.rs` converts those triangles to the recovered TU3
sphere/triangle face layout for regression tests. Main runtime traversal uses
University's decoded collision provider directly. Edge/vertex metadata remains
deliberately poisoned in the fixture until those retail branches are recovered.

The project-owned custom-map loader preserves native RenderWare collision
surface channels on each authored material. Its established skateable default
is audio surface `3`, physics surface `1` (`Smooth`), and pattern `0`;
`EncodeRwSurfaceId` packs those channels as `131`. The transition collider now
carries and validates that raw ID per triangle. This is an existing map-format
convention, not proof that every custom surface should use that profile. The
game-side contact-material combiner itself is recovered: static friction uses
`max(A,B)`, dynamic friction uses `min(A,B)`, and restitution uses `min(A,B)`.

## Observed in Skate 3 TU3

The authoritative executable for these observations is the local TU3 Xbox 360
dump with SHA-256
`F4AA113EB541BFBA03DBC108CF5AB43F58C965B20FA3B82F9C40938A0AD841C4`.
No retail process or SK8 harness was launched for this pass.

The recovered attribute database is
`runtime/game/data/big/db.big`, SHA-256
`B5C5967A2B31B28B4A03B1232061228D3D2C5A84DFC3E27E19E28F8DA53BA87A`.
It was decoded statically with the local Attribulator against
`data/db/skaterschema.vlt` and `data/db/skatercollections.vlt`. The generated
recompiler sources used to verify instruction addresses have SHA-256
`D8C3ADDBD8CB3E9C266068099204EC0350DAB0E337856EE9D29B3A714A27D260`
for part 75 and
`5A0660F8D39A41A4BA7704EA07756982BD8E9C4F2CB885833A1B24F717F93A17`
for part 76. The contact-generation block is in part 34, SHA-256
`26AC861ABFB1D9BB6E34A6F9356A9B1E9ED0BF7A94221B3F4837EB680F3B6F06`.

Two public, independently recovered type sources were used only to name TU3
layouts already confirmed in the executable:

- Skate Modding Team's `Quick and Dirty IDA Export.h` from `sk82_na_zd.xex`,
  commit `28d7bea995ef5a8b8855b2de0ce8f57ad6ae2cb8`;
- Burnout Paradise's EA/RenderWare SDK DWARF declarations, commit
  `cf54260646d0650fd72d79faf85229ed63a15ca4`.

The latter exposes original `rw::physics` member and accessor names; it is not
used as a substitute for Skate 3 instructions. Every solver statement below
is cross-checked against TU3's generated PPC translation.

- `SkateboardBody::CreateWheels` (`0x82C0AA78`) creates four sphere collision
  volumes and four distinct rigid parts.
- The complete board consists of four wheel bodies, two truck bodies, and one
  deck body. `SkateboardBody::SetTransform` (`0x82C0B2C8`) writes the requested
  deck transform, applies the common deck delta to bodies 0 through 5, and then
  writes the requested transform to the auxiliary body.
- `SkateboardBody::UpdatePostPhysics` (`0x82C07D20`) reduces 96-byte collision
  records into seven body-contact channels. Wheel contact count, not a
  quarter-pipe mode flag, owns the airborne clock.
- The contact-state filter at `0x82DE5BA0` adds frame hysteresis after that
  physical wheel count. Established air enters ground on the fourth
  consecutive family-200 frame with contact evidence. Established ground
  enters air only after the family-200 counter exceeds three and the
  frames-since-special counter exceeds nine. Raw state 201 reacquisition
  requires contact evidence, a clear veto, and a family-200 counter greater
  than five. The airborne clock itself is not a threshold input to this
  filter.
- The wheel-normal acceptance threshold in that function is no longer
  unresolved. At `0x82C084BC` it resolves
  `physics_reckoning.MaxAllowedGroundNormalFromUp = 80 degrees`, multiplies by
  the retail binary32 degrees-to-radians constant `0x3C8EFA35`, and calls
  TU3's `XMVectorCos` polynomial at `0x82473930`. Replaying the recovered
  binary32 operation order gives `0x3E31D0D9`
  (`0.17364825308322906`) as the exact threshold used by the contact bridge.
- `Skateboard::AddSkateboardForce` (`0x82C03EF0`) appends at most 21 records of
  48 bytes. Byte zero stores a producer-side type, payload zero begins at byte
  16, and payload one begins at byte 32.
- The queue consumer is `0x82C03718`. It runs immediately before the
  RenderWare rigid-body step, walks every record with a 48-byte stride, and
  never reads or branches on the type at byte zero. Every queued record enters
  the same force-and-torque accumulation path on the deck rigid part.
- The second payload is combined with
  `physicsdeck/default.DeckForceYOffset = 0.05`, then transformed by the
  deck's `Ri/Up/At` basis to produce the world torque arm. The first payload
  is the world force. `RigidBody +0x7c` is the inverse-mass field: the consumer
  multiplies force by inverse mass, computes `arm cross force`, applies the
  body's world inverse inertia, accumulates both accelerations, and clears the
  body's cool-down. `src/retail_rigid_body.rs` now ports this operation.
- `0x82C04F68`, called by the grounded update at `0x82D38800`, is the
  consumer of `physics_speed_conservation`. It returns a normal
  `SkateboardForce`: payload zero is a force along a board-derived direction
  and payload one is zero. The force magnitude is assembled from total
  physical-board mass, the selected conservation amount, a correction scalar,
  and the fixed delta. It is not a position correction, a velocity
  replacement, or an adhesion constraint.
- The speed-conservation consumer reads its active surface collection through
  `ProcessedPhysIn +2544` and the active `physics_mode` collection through
  `ProcessedPhysIn +2548`. The latter accesses exactly `MotorTopSpeed` at
  collection offset `+40` and `MotorEnabled` at `+44`. Normal mode has
  `MotorEnabled = false` and `MotorTopSpeed = 0`.
- The consumer's other collection dependencies are exact:
  `physics_friction` supplies `FrictionVsSpeed_NoInput` at `+128`,
  `FrictionVsSpeed_Manual` at `+208`, and `NoInputTime` at `+356`;
  `physics_manual` supplies `SpinCorrectiveForce` at `+180`,
  `MinSpeedForCorrection` at `+212`, and `MaxSpeedForCorrection` at `+220`;
  `physics_surfaces` supplies `FrictionVsSpeedNew` at `+80` and
  `Friction_MaxSpeedChange` at `+260`.
- Ground queues Pumping as raw type 8. `Pumping::Update` (`0x82D8F228`) calls
  `0x82D8F470`, which the community map incorrectly labels
  `TrajectorySelector::AdjustStartingVelOnVerts`. Executable dataflow proves
  that this routine is Pumping's compression/curve scalar producer. Ground
  later converts Pumping offset `0x30` into an ordinary deck force through
  `0x82D933D0`, `0x82D436E8`, `AddSkateboardForce`, and the common force
  consumer at `0x82C03718`.
- `Pumping::Update` is recovered through its complete static call path. Its
  first call after reset only primes history. Later calls condition the
  positive change in `dot(C,B)`, evaluate the exact eight-point
  Pump-vs-time/Pump-vs-velocity graphs, select the decoded `physics_mode`
  scale, and clamp the result against that mode's per-step lower/upper rates.
  The force builder converts the scalar to
  `(total skateboard mass * scalar) / dt` along the prepared deck `At`
  channel and queues local point zero. The common consumer therefore applies
  it to the deck at only the recovered `DeckForceYOffset`; it is not wheel
  adhesion.
- The actual trajectory-copy starting-velocity modifier is `0x82D67D08`.
  It changes only `TrajectorySelector+0x800`, not live rigid-body velocity.
  For prediction velocity `v`, normal `n`, and decoded
  `NaturalAirOffVertsScalar = 0.4`, it preserves the tangent component and
  scales the prediction's normal component:
  `v' = v + (0.4 - 1) * n * dot(v,n)`.
- KnownAir copies a selected trajectory's predicted apex, contact position,
  contact time, and tangent heading into animation/NavRig state. The target
  heading is produced by finite-differencing the ballistic prediction at the
  exact `0.016666668` step and is accepted only above
  `MinTargetHeadingVel = 1`. This path drives heading/body-spin and grind pose
  assistance. It does not write live linear velocity, add a target-derived
  force, project airborne velocity, or attract the board toward the landing.
- The community-map label `Reckoning::UpdateAirStates` at `0x82E27F90` is
  disproven. Static callers and field dataflow identify that function as a
  LivingWorld pedestrian head-look update. No transition implementation may
  cite that address as skateboard evidence.
- The ordinary state graph does establish authority even though the physical
  Reckoning equation remains unresolved: ground executes
  `FORCE_PHYSICS_SKATEBOARD`; the first filtered air state and established
  ordinary air execute `FORCE_ANIM_SKATEBOARD`. `FOLLOW_ANIMATION_DATA` is not
  part of ordinary natural air unless a separate trick subtree selects it.
- TU3's per-body `rw::physics::Simulation::BatchIntegrator` is
  `0x82AE6590`. It first integrates accumulated linear/angular acceleration,
  converts those candidate rates to frame displacements, and adds four
  solver-owned correction vectors indexed by the rigid body's reaction ID.
  Correction lanes 0 and 2 contribute to both pose and reconstructed
  velocity; lanes 1 and 3 correct position and orientation only.
- The integrator advances the center of mass from those displacements and
  advances/normalizes the quaternion from the angular and
  orientation-correction lanes. It then reconstructs `Ri/Up/At` and the world
  inverse inertia. It never reads terrain normals and contains no
  surface-tangent velocity projection, root-to-surface snap, lip branch, or
  airborne target.
- Linear and angular velocity are reconstructed from their frame
  displacements with
  `max(Simulation.m_Frequency - Inertia.mLinearDrag, 0)` and
  `max(Simulation.m_Frequency - Inertia.mAngularDrag, 0)`, then capped by
  `mMaxVelocity` and `mMaxOmega`. The energy scalar is
  `linear_speed_squared + mSpherical * inverse_mass *
  angular_speed_squared`; that scalar drives the exact cool-down branch.
  Finally, the four correction lanes are cleared, force resets to simulation
  gravity, and torque resets to zero.
- The VMX128 quaternion permutations resolve to RenderWare's public
  `(x,y,z,w)` lanes as
  `q += 0.5 * Quaternion(angular_displacement, 0) * q`, followed by
  normalization. This is left multiplication: its vector derivative is
  `angular_displacement*q.w + angular_displacement cross q.xyz`, and its
  scalar derivative is `-dot(angular_displacement, q.xyz)`. The function then
  rebuilds the `Ri/Up/At` basis and transforms `Inertia.mInvTens` into world
  inverse inertia. The complete pose/rate branch is now ported and
  deterministically tested in `src/retail_rigid_body.rs`.

## Recovered retail data relevant to the first vertical loop

- `physics/default`: world gravity `(0, -9.8, 0)`, triangle-edge culling
  tolerance `1`, simulation padding `0.1`, RenderWare maximum iterations `25`,
  physics update frequency `1`, mass factor `1`, floor static friction `0.5`,
  and floor restitution `0`.
- The `ProcessedPhysIn` constructor at `0x82BF9EF0` initializes its fixed delta
  at `+2604` to the exact binary constant `0.016666668`. This is a 60 Hz
  game-physics input; the Bevy project's existing 120 Hz Ollie carrier must
  not silently be reinterpreted as this retail force step.
- `physics_speed_conservation/default` is a 28-byte layout:
  `NegativeGeneralAmount = 0.25` at `+0`, `MinSpeed = 2` at `+4`,
  `MaxGravityAcceleration = 7` at `+8`, `MaxFrictionAcc = 1.2` at `+12`,
  `Gravity = 9.8` at `+16`, `GeneralAmount = 0.25` at `+20`, and
  `CoffinAcceleration = -0.4` at `+24`.
- `physics_world/default.SkateboardMassFactor` is `5`. `CreateTriangleDeck`,
  `CreateTrucks`, and `CreateWheels` multiply their per-part mass attributes by
  this value before calling `ComputeMassProperties`. The physical RenderWare
  masses are therefore deck `6.0`, each truck `1.95`, and each wheel `0.415`;
  the unscaled attribute values are `1.2`, `0.39`, and `0.083`.
- Static execution of complete `InitializeTransforms` (`0x82C0ADF0`) and
  `Part::SetTransform` (`0x82BD4318`) separates authored part transforms from
  live rigid-body center-of-mass frames. Wheels and trucks have identity local
  mass frames. The aggregate deck's recovered local mass frame is inverted by
  `Part::SetTransform`, producing a distinct live deck basis, quaternion, and
  center. `src/retail_drive_frames.rs` retains both boundaries and their exact
  oracle bits; it does not reuse `CalculateTruckTransforms` as live
  initialization.
- `physicsdeck/default`: mass attribute `1.2`, dynamic/static friction `0.1`,
  restitution `0`, mid length `0.59`, width `0.24`, thickness `0.015`,
  front size/angle `0.13` / `13 degrees`, back size/angle `0.165` /
  `12.5 degrees`, force Y offset `0.05`.
- `CreateTriangleDeck` (`0x82C09290`) creates a 15-slot collision aggregate,
  not one generic triangle mesh. Slot 0 is a rounded box with exact
  half-extents `(0.113249995, 0.0007500001, 0.28825)` and radius `0.00675`.
  Slots 1 and 2 are longitudinal capsules at lateral coordinates
  `+/-0.1125`, extending from `+0.295` to `-0.295`, with radius `0.0075`.
  Slots 3 and 4 are radius-`0.035` spheres centered at
  `(0, -0.02, +/-0.235)`. Slots 5 through 14 are two five-triangle end fans.
  The root and triangle flags use `DeckEnableDeckVolumeCollisions`; the side
  capsules use `DeckEnableEndVolumeCollisions`. The executable reads
  `DeckEndCapsules = 5` as its tessellation loop count and does not read the
  separate `DeckEndTriangles` field in this function. The ten default triangle
  vertices are encoded bit-for-bit after replaying the two fan loops with
  TU3's `XMVectorSin` (`0x824531C8`) and `XMVectorCos` (`0x82473930`)
  polynomials. As an independent operation-order check, that same cosine port
  reproduces the known 80-degree contact threshold `0x3E31D0D9`.
- `physicstrucks/default`: mass attribute `0.39`, dynamic friction `0`, static friction
  `0.9`, restitution `0`, truck angle `14 degrees`, rotation axis
  `31 degrees`, `RadiusScalar = 0.5375`, `HalfHeightScalar = 1.35`, and the
  database flag named `DebugHaveJoints` enabled.
- `physicswheels/default`: sphere radius `0.031`, mass
  attribute `0.083`, dynamic/static friction `0.7` / `0.8`, restitution `0`, lateral
  distance `0.095`, capsule length `0`, and `UseWheelDrives = false`.
- `CreateTrucks` resolves the hashed fields `WheelRadius`, `WheelXDist`, and
  `SkateboardMassFactor`. It creates a `CapsuleVolume` with radius
  `WheelRadius * RadiusScalar * 0.5 = 0.00833125` and half-height
  `WheelXDist * HalfHeightScalar * 0.5 = 0.064125`. These are now exact
  collision dimensions, not unresolved truck-shape tuning.
- `ComputeMassProperties` (`0x82AE7770`) writes `1 / supplied_mass` to its
  inertia record. `0x82C06F58` sums `1 / part[+0x7C]`, proving that this board
  helper returns total physical mass rather than a guessed aggregate scalar.
- `physics_surfaces` contains six named collections. Their scalar contact data
  is:

  | collection | wheel static | wheel dynamic | max speed change | braking |
  | --- | ---: | ---: | ---: | ---: |
  | `default` | 0 | 0 | 0 | 0 |
  | `rough` | 0.85 | 0.75 | 0.2 | 1.2 |
  | `slippery` | 0.7 | 0.5 | 0.7 | 0.5 |
  | `slow` | 0.9 | 0.8 | 0.1 | 2 |
  | `smooth` | 0.8 | 0.7 | 0.3 | 1 |
  | `veryslow` | 1 | 0.99 | 0.4 | 2 |

  Each non-default collection also has a distinct 80-byte
  `FrictionVsSpeedNew` point graph. The current University transition bridge
  does not yet resolve each decoded surface to one of those collections, so
  choosing a profile remains unresolved.
- `CreateDrives` (`0x82C0B770`) calls
  `rw::physics::Simulation::AddDrive` (`0x82AE64F8`) twice with ordered pairs
  `(deck 6, truck 4)` and `(deck 6, truck 5)`.
  `CreateWheelDrives` (`0x82C0CF60`) calls the same API with ordered pairs
  `(truck 4, wheel 0)`, `(truck 4, wheel 1)`, `(truck 5, wheel 2)`, and
  `(truck 5, wheel 3)`. `AddDrive` stores its second body argument at
  `Drive+0x10` (`m_bodyA`) and its first at `Drive+0x14` (`m_bodyB`).
  `DriveJacobian::Build` pairs the first 32-byte frame with internal `m_bodyA`
  and the second frame with internal `m_bodyB`. The Rust topology therefore
  records internal pairs `(truck,deck)` and `(wheel,truck)`, not the reversed
  API call spelling.
- The community symbol names `0x82C0C268` as
  `SkateboardBody::CreateJoints`. Observed dataflow proves that it populates
  storage owned through `this+0x1c`: six 64-byte parameter records, six
  80-byte frame records, and twelve body indices. The unrolled body-pair order is
  `(6,4)`, `(6,5)`, `(4,0)`, `(4,1)`, `(5,2)`, `(5,3)`. The deck/truck
  records use `DeckMidLength` and truck fields; wheel records use
  `WheelXDist` and `WheelSwingLimit`.
- Registration is indirect but proven. The skateboard constructor allocates
  the live assembly and passes the definition directly to assembly
  initialization at `0x82ADFAF8`; the generic
  `PhysicsUtility::CreateAssembly` wrapper (`0x82E0AC58`) reaches that same
  initializer but is not the skateboard call site. The initializer delegates
  record materialization to `0x82ADFBB8`. Its joint-count loop reads the
  definition's body-index pairs, 80-byte frames, and 64-byte limits, then
  writes one live 20-byte embedded joint per record. This is why
  `0x82C0C268` does not call `Simulation::AddJoint`: the six joints belong to
  the assembled board resource and are materialized in one generic assembly
  pass.
- Assembly activation reverses each definition pair when it initializes the
  live joint fields. At `0x82ADFE5C..0x82ADFF40`, definition body 0 is loaded
  first and ultimately written to live `Joint+0x14` (`m_bodyB`), while
  definition body 1 is written to live `Joint+0x10` (`m_bodyA`). The live
  solver pairs are therefore `(4,6)`, `(5,6)`, `(0,4)`, `(1,4)`, `(2,5)`,
  `(3,5)`. The 80-byte frame pointer is passed through unchanged:
  frame A follows definition body 1 and frame B follows definition body 0.
  This is the exact live ABI; the resulting initial anchor mismatch is
  characterized below rather than corrected by reinterpretation.
- There is no hidden body-index permutation. `SkateboardBody`'s descriptor
  ranges, the seven `AssemblyDefinition` body records, the seven materialized
  `Assembly::Part` records, and the returned rigid-body handles all preserve
  indices `0..6`. The live wheel/truck solver pairs are exactly
  `(wheel 0,truck 4)`, `(wheel 1,truck 4)`, `(wheel 2,truck 5)`, and
  `(wheel 3,truck 5)`.
- Joint-frame word 14 is local Z, not a VMX-swizzled X lane.
  `JointJacobian::Build` loads frame B's words 12 through 15 at `0x82AE3EDC`,
  splats word 14 at `0x82AE3F30`, and multiplies it by body B's third basis
  vector at `0x82AE3FA4`.
- The initial wheel/truck anchors are genuinely noncoincident in TU3's
  constructor pose. The world-space B-minus-A residuals are
  `(+0.095,0,+0.095)`, `(-0.095,0,-0.095)`,
  `(+0.189999998,0,approximately 0)`, and
  `(-0.189999998,0,approximately 0)` for wheel records 0 through 3.
  Reinterpreting frame lanes, swapping bodies, or substituting
  `CalcTruckTransforms` merely to force those anchors together would be a
  non-retail alteration.
- Static execution of the complete `0x82C0C268` function resolves every
  default payload bit. The deck/truck 64-byte parameter payload ends in
  `[0x42B453D1, 0, 0, 0x3E7A35DD, 0x3F800000, 0x3F78654D, 0, 1]`;
  each wheel payload ends in
  `[0, 0x497FA9D8, 0, 0, 0x3F800000, 0x3F800000, 3, 0]`.
  The complete 80-byte frame records and ordered body pairs are retained in
  `src/retail_joint_records.rs` without translating them to Bevy joints.
- The original Burnout-era `rw::physics` SDK declarations independently name
  the 80-byte input as `JointFrames` (`mQuatA`, `mPosA`, `mQuatB`, `mPosB`,
  `mQuatL`) and the 64-byte input as `JointLimits`. TU3
  `JointJacobian::Build` (`0x82AE3BC8`) consumes those exact fields and emits
  one fixed 384-byte record containing three linear and three angular rows.
- The six embedded records feed the generic joint batch. All three translation
  rows are equality constraints. The two deck/truck records encode locked
  swing plus a twist arc and the four truck/wheel records encode axle swing
  plus locked twist.
  Free or inactive angular rows are represented by infinite bounds rather
  than by changing the generic record's row count.
- `Simulation::JointBatchBuild` (`0x82AE39D0`) emits active joints in intrusive
  list order. The shared solver at `0x82AE27D0` performs sequential
  Gauss-Seidel in the exact per-iteration order contact, joint, drive for each
  of the 25 outer iterations. Joint reactions update the same body reaction
  vectors immediately consumed by following constraints.
- The truck-drive dynamics records are 32 bytes. The default branch writes
  the exact raw words `[100000.0, 0.0015625, 359999.97, 1,
  TruckTwistAngle*59.999996, TruckStaticFriction,
  TruckTwistLimit*3599.9995, 2]`. With the default truck attributes, the
  attribute-derived terms are `14*59.999996`, `0.9`, and
  `86.1*3599.9995`. The `UseSoftDrives` alternate branch changes the first
  four words to
  `[5999.9995, 0, 359999.97, 2]`.
- `SkateboardBody` construction (`0x82C06298`) clears all eight words in the
  wheel-drive dynamics record. The default `CreateWheelDrives` branch then
  writes the exact raw words `[3600, 60, 35999.996, 1]` into words 0-3; the
  alternate `physicsdeck.UseHardDrives` branch writes
  `[5999.9995, 0, 359999.97, 2]`. `DrivenPair::Initialize` (`0x82AE6A98`)
  copies all eight words, so the exact records end in `[0, 0, 0, 0]`.
- `physicswheels/default.UseWheelDrives` is false. The skateboard constructor
  tests that decoded flag before calling `CreateWheelDrives`, so the four
  wheel-drive records above are supported alternatives but are not present in
  the default retail assembly. The default constraint set contains six
  embedded joints and only the two deck/truck drives.
- The 32 bytes are now structurally resolved as the original
  `rw::physics::DriveDynamics`: a 16-byte linear `Params` record followed by a
  16-byte angular record. Each record is
  `[spring-or-max-velocity, damping, max-strength, type]`; `DriveType` is
  `NO_DRIVE=0`, `SOFT_DRIVE=1`, and `HARD_DRIVE=2`. The original API exposes
  word zero through `GetSpring` for soft drives and `GetMaxVelocity` for hard
  drives. This also corrects the misleading branch labels: Skate 3's default
  truck linear record is type 1/soft, its truck angular record is type 2/hard,
  the default wheel linear record is type 1/soft, and the alternate wheel
  linear record is type 2/hard.
- TU3 `DriveJacobian::Build` (`0x82AE1AE8`) independently confirms those
  meanings. It loads the linear type at dynamics `+0x0c`, angular type at
  `+0x1c`, and the simulation timestep at `Simulation +0xa0`. Type 1 builds
  its coefficients from `dt*dt*spring`, `dt*damping`, and
  `dt*dt*max-strength`. Type 2 clamps translational or angular correction
  magnitude against `dt*max-velocity` before assembling the Jacobian. This is
  evidence for the retail constraint math, not permission to copy the values
  into a generic engine's spring joint.
- Static execution of TU3 `DriveJacobian::Build` and the shared iterative
  solver now resolves the drive equations themselves. Each drive owns three
  linear and three quaternion-component rows. Soft rows use
  `1 + dt*damping + dt^2*spring`, retain
  `(1 + dt*damping)/denominator` of the previous correction, and precondition
  the positional/rate/acceleration target by the same denominator. Hard rows
  clamp the three-component correction magnitude to `dt*max-velocity`, then
  divide it by `1 + dt*damping`. Active soft and hard rows clamp each
  accumulated component to
  `dt^2*max-strength*inverse-effective-mass`; `NO_DRIVE` clamps to zero.
- The angular rows are not an orthogonal Euler or axis-angle basis. For
  relative quaternion `(x,y,z,w)`, TU3 normalizes the three raw axes
  `(w,z,-y)`, `(-z,w,x)`, and `(y,-x,w)` independently and uses component
  errors `2*x/length(axis0)`, `2*y/length(axis1)`, and
  `2*z/length(axis2)`. Static arbitrary-axis probes and global-rotation probes
  match this scalar reconstruction. The solver applies all three local
  components together, includes off-center linear torque before the angular
  rows, and writes only velocity-producing reaction lanes.
- The TU3 drive builder clears three 128-byte cache lines (384 bytes) for each
  drive Jacobian, reads the drive's frames, dynamics, parent/child bodies, and
  current rigid-body inverse inertia, then writes the solver rows and the
  source drive pointer. The generated function spans
  `0x82AE1AE8..0x82AE27d0`; IDA's missing VMX128 decoding had previously hidden
  most of this path.
- Each `DriveFrames` object passed to `AddDrive` is exactly 64 bytes:
  `SetTruckDriveFrames` stores truck frames at object offsets `6768` and
  `6832`, while `CreateWheelDrives` stores wheel frames at `7344`, `7408`,
  `7472`, and `7536`. `DrivenPair::Initialize` copies those 64 bytes to its
  own offsets `0x10..0x4f`. This disproves the earlier placeholder shape of
  two 64-byte affine matrices.
- `SetDriveFrames2` (`0x82C0C088`) calls helpers `0x82BD3A10` and
  `0x82BD3BD0`. Generated PPC operations show that each helper converts one
  affine basis to a four-lane quaternion and copies the affine vector at
  offset `0x30` as a four-lane translation. The 64-byte record is therefore
  two consecutive 32-byte body frames:
  `[quaternion lanes, translation lanes]` for body A followed by the same
  pair for body B. Static TU3 execution now resolves the quaternion convention
  as `(x,y,z,w)` and proves `SetDriveFrames2` emits identity for body A plus
  `transpose(A.basis)*B.basis` and
  `transpose(A.basis)*(B.translation-A.translation)` for body B. The retail
  helper uses its trace conversion directly and produces non-finite quaternion
  lanes at an exact 180-degree relative rotation; the scalar port deliberately
  preserves that behavior instead of substituting a generic robust converter.
  Static execution of `CalculateTruckTransforms` (`0x82C0BC90`) also resolves
  both truck affine transforms. With the default database values
  `DeckMidLength = 0.59`, `TruckZPosFront/Back = -0.052`, and
  `TruckYPos = -0.0565`, and `TruckRotationAxisAngle = 31 degrees`, object
  offsets `+0x1e20/+0x1e60` have translations
  `(0, -0.0565, -0.242999986)` and `(0, -0.0565, 0.242999986)`. Their complete
  bases retain the TU3 `XMVectorSinCos` residuals and VMX operation order; all
  meaningful basis/translation lanes are encoded by raw bits in
  `src/retail_drive_frames.rs`. The slots are deliberately named by offset and
  physical group because front/rear naming is not established by these stores
  alone. Static execution of `SetTruckDriveFrames` with its constructor-zeroed
  runtime angles resolves exact deck/truck quaternions at `+0x1a70/+0x1ab0`.
  `CreateWheelDrives` resolves the four wheel frames as identity plus second
  translations `+WheelXDist`, `-WheelXDist`, `+WheelXDist`,
  `-WheelXDist`. All six default drive frames are now encoded and tested in
  `src/retail_drive_frames.rs`.
- `SkateboardBody::InitializeTransforms` (`0x82C0ADF0`) writes all seven
  initial rigid-body transforms before any external deck transform is applied.
  The deck is identity. Wheel bodies 0 through 3 use identity bases and exact
  translations `(-0.095, -0.0565, +0.242999986)`,
  `(+0.095, -0.0565, +0.242999986)`,
  `(-0.095, -0.0565, -0.242999986)`, and
  `(+0.095, -0.0565, -0.242999986)`. Truck body 4 uses the identity basis at
  the positive longitudinal station. Truck body 5 uses the exact +90-degree
  Y basis at the negative station, with quaternion words
  `[0,0x3F3504F3,0,0x3F3504F3]`. Wheels and trucks have no hidden local
  mass-frame conversion before `AddRigidBody`; `CalcTruckTransforms` later
  writes only cached drive/reference matrices. `src/retail_drive_frames.rs`
  preserves these exact live transforms. For the deterministic flat fixture,
  deck-center height `WheelRadius - TruckYPos = 0.0875` is derived solely from
  those recovered transforms so all four wheel spheres begin at Y=0; it is not
  a suspension or contact tuning value.
- The original `rw::physics::Contact` layout is 256 bytes. Its first 96 bytes
  are position-on-A/body-A, position-on-B/body-B, a three-axis contact frame
  (`Ri`, `Up`, `At`), restitution, static friction, dynamic friction, relative
  velocity, and tag; ten trailing 16-byte vectors pad the solver record.
  TU3 `ContactBatchBuild` (`0x82AE10C8`) reads the active contact count from
  `Simulation +0x64`, uses the timestep at `+0xa0`, and builds one in-place
  256-byte contact Jacobian per contact.
- TU3 contains two complete collision-to-contact record blocks at
  `0x8277A828..0x8277AA88` and `0x8277BFAC..0x8277C21C`. Both clear the two
  128-byte halves, write the contact points and body IDs, compute each point
  velocity as `linearVelocity + angularVelocity cross contactArm`, and store
  B-minus-A relative velocity.
- Those blocks do not choose a tangent from world up. They first use
  `relativeVelocity cross normal`. If its squared length is below the exact
  vector constant `0x00800000`, they select either the projected X axis or
  negated projected Z axis using `0.5 - normal.x^2 >= -0.0`. Tangent one is
  then `normal cross tangentZero`. The Xbox swizzle/sign tables at
  `0x821C3250` confirm that operation order.
- The ten trailing contact vectors are not unused padding before the batch
  build. They snapshot alternating A/B body vectors:
  `mCom/mId`, `mIfull/mInvm`, `mIsplt/mState`, `mForce/mKine`, and
  `mTorque/mCool`. These exact member names and body offsets are preserved in
  the EA SDK DWARF and match TU3's VMX loads field-for-field.
- The wheel/terrain adapter ordering is exact. The dynamic wheel is Contact
  body A with the sphere point at `mPosA`; static terrain is body B with the
  triangle point at `mPosB`. The collision result stores the negation of the
  internal sphere-to-triangle separator as `Contact.normal`, so level-ground
  contact normal is world-up and a positive normal reaction supports body A.
  Any deterministic transition fixture must preserve this ordering rather
  than use an algebraically similar swapped pair.
- The packed symmetric world inverse-inertia layout is now resolved.
  Preserved Skate-era SDK code inlined into Burnout
  `ExternallySimulatedBody::WriteTransformIntoRenderware`
  (`0x0068ACB4..0x0068AFE4`) computes the two vectors in
  `RigidBody::InertiaDynamicUpdate`. Six independent one-hot inputs passed
  through the static TU3 `ContactBatchBuild` oracle prove the lane mapping:
  `mIfull = (Ixx, Ixy, Ixz)` and `mIsplt = (Izz, Iyy, Iyz)`.
  `src/retail_rigid_body.rs` now ports both packing and multiplication, with
  the exact oracle responses retained as deterministic tests.
- `src/retail_contact.rs` ports this complete record construction. The
  material scalars are accepted as already combined. The game-side helper at
  `0x82763078`, called immediately before both recovered contact writers, is
  now also ported: it combines static friction with `max(A,B)`, dynamic
  friction with `min(A,B)`, and restitution with `min(A,B)`. The helper writes
  those values in that order to its 12-byte result; the contact writers map
  them to contact offsets `+0x3c`, `+0x4c`, and `+0x2c`.
- `src/retail_contact_solver.rs` now ports the scalar meaning of TU3
  `ContactBatchBuild` and the contact branch of the iterative solver at
  `0x82AE27D0`. Each contact has normal, tangent-zero, and tangent-one rows.
  A body contributes only when `(mState & 4) == 4`; each row denominator is
  inverse mass plus `cross(arm, axis) dot inverseInertia(cross(arm, axis))`
  from both active bodies.
- The built target for every row contains contact-point separation, one
  timestep of relative point velocity, and one squared timestep of relative
  point acceleration. Restitution multiplies only a positive normal relative
  velocity. The fourth accumulated lane is the position-only normal
  correction.
- The contact solver is sequential across contacts for each retail iteration.
  It clamps accumulated normal impulse to nonnegative. Each tangent component
  keeps a candidate inside `staticFriction * previousNormalImpulse`;
  otherwise it clamps that component to
  `dynamicFriction * previousNormalImpulse`. The use of the previous normal
  lane, including zero tangent impulse on the first iteration, is directly
  visible in the TU3 solver trace.
- The call adapter at `0x82DC30A8` passes three count/array pairs from
  `Simulation` into the shared solver at `0x82AE27D0`, followed by
  `Simulation+0xb0` as the iteration count. Static tracing resolves the three
  families and the inner order as contacts, joints, then drives. The shared
  solver advances all three inside each outer iteration; it does not converge
  one family for 25 passes before starting the next. The Rust ports expose
  one-pass entry points so the owning world can preserve this ordering.
- Static-floor, two-active-body, high-slip, restitution, nonzero-arm, and
  nonzero-inertia fixtures have been run through the extracted TU3 builder
  and 25-iteration solver as a static oracle. The Rust row targets,
  accumulated impulses, and all four reaction vectors match those outputs.
- TU3 `PrimitivePairIntersect` is the legacy RenderWare Collision path at
  `0x82AD3CD8`. It calls `0x82AD3AF0`, which dispatches through the
  36-entry separating-direction table at `0x82FD56F0`. The generic table
  entry is `0x82ACF070`; the box/triangle and triangle/box specializations are
  `0x82ACE968` and `0x82ACF950`.
- The legacy `PrimitivePairIntersectResult` layout is independently named by
  both the Skate 3 type export and the pinned Burnout SDK DWARF. In addition
  to the final normal, points, distance, and up to 16 contact pairs, it owns
  two `Feature` records plus `sepDir` and `sepDist`. TU3
  `FindFeatureIntersectionPrism` (`0x82ACE190`) consumes those features.
- The public Skate-era type export names TU3's complete
  `TriangleFeatureType` values: face `0`, edge 0 `1`, edge 1 `2`, vertex 1
  `3`, edge 2 `4`, vertex 0 `5`, and vertex 2 `6`. The classifier at
  `0x82AD2A50` is now ported. Its exact in-plane simplification threshold is
  `0x3D4CCCCD` (`0.05`), while `FixUpTriangleResult` uses
  `0x3F7FF62B` (`0.9998499751091003`) for the face-normal gate.
- The sphere/triangle pair uses the generic separating-direction entry
  `0x82ACF070`. A sphere has no face normals or edge directions, so this pair
  tests the triangle face normal only. For a wheel above a terrain triangle,
  the resulting normal points from the sphere towards the triangle; there is
  no attraction axis, surface tangent replacement, or lip impulse.
- The face branch of `GPTriangle::GetMaximumFeature` (`0x82ADDD68`) is now
  ported with its exact `0x3F733333` (`0.949999988079071`) gate, edge order,
  winding-dependent region, and `Feature::BuildEdgePlanes` call. The
  point/face feature-prism helper at `0x82ACC160` and
  `FeatureEdge::constrain_point` at `0x82AC6EE8` are also ported. The helper
  orthogonally projects along the separating direction, chooses the greatest
  positive edge-plane violation, and clamps only to that finite edge.
- Combining those recovered pieces gives a complete deterministic
  wheel-sphere/terrain-triangle contact producer, including primitive
  fatness, minimum-separation rejection, final signed distance, one-sided face
  rejection, and face-region updates. Region `8` is the observed face
  interior. Every other region has crossed an edge and requires the still
  unrecovered edge/vertex fixup. The first transition world therefore admits
  only region-8 contacts; this prevents an unrecovered vertical edge plane
  from extending above the lip and recreating magnetic sticking.
- The available RenderWare Collision 6.14 source is not the implementation
  compiled into Skate 3. Its `PrimitivePairIntersect` source explicitly marks
  `sepDir` as an ignored legacy argument and routes directly to the newer
  `EA::Collision::ComputeContacts` family; its volume method tables mark
  `GetMaximumFeature` as formerly used. TU3 still calls the old separating
  direction, maximum-feature, and feature-prism path. The 6.14 code may
  corroborate type meanings, but copying its triangle/sphere closest-point
  routine would not be a retail-exact Skate 3 port.
- `physics_airstates/default`: NaturalAirTime `0.2`,
  SpeedToAlignToGround_PhysAir `0.1`, MaxSpinSpeed `600`,
  MaxHeadingAdjust `90`, and grind-air-assist frame count `16`.
- `physics_reckoning/default` contains separate ground and air tilt graphs,
  speed-dependent up-vector smoothing/max-delta graphs, air up-vector
  smoothing `0.5`, up-vector speed damping `0.75`, and the vertical-jump
  alignment fields. These data prove a conditioned visual orientation path,
  not an instantaneous world-up snap.
- All decoded `physics_reckoning/default` and
  `physics_airstates/default` graph payloads are preserved bit-for-bit in
  `src/retail_transition_profiles.rs`: 17 Reckoning graphs, six AirStates
  graphs (including the still-unhashed
  `Hash_AA79C93673533C5B` attribute graph), the three 16-byte Reckoning
  controller records, and both collections' scalar attributes. The module
  deliberately exposes raw words only; graph interpolation and state
  ownership are not inferred from field names.

## Derived implementation constraints

- A playable quarter pipe must be terrain triangles contacting board bodies;
  it must not be a special movement state that owns position.
- Gravity remains world-down. A ramp redirects motion through collision
  impulses and constrained wheel/deck bodies; code must not continuously
  replace velocity with a tangent projection.
- Ground contact must feed solver correction displacements into the retail
  rigid-body integrator. Presentation code may consume the resulting physical
  orientation, but cannot write a sampled ramp normal back into board pose.
- Lip takeoff is contact loss. No hidden launch impulse or target-position
  attraction has been found.
- Pumping is an applied force generated by the recovered Pumping conditioner.
  It cannot be approximated as extra adhesion.
- Grounded orientation and airborne visual orientation need separate,
  conditioned ownership. Holding the last ramp normal freezes the character;
  snapping to world-up breaks continuity.
- No seven-body traversal result is currently accepted. An earlier fixture
  appeared stable only after reversing a recovered body order. That reversal
  contradicted the TU3 joint/drive ABI and has been rejected; its coast,
  launch, and ballistic assertions are not evidence. A later isolated
  prototype with the correct live order conserved horizontal assembly
  momentum while airborne and stayed finite on flat contact, but exposing
  TU3's genuinely noncoincident constructor anchors directly produced a
  contact-coupled rolling startup transient. That prototype is not wired to
  gameplay or accepted as a playable result.

## Unresolved and therefore not eligible to guess

- A seven-body runtime start state remains blocked on the retail lifecycle
  between the constructor's proven noncoincident joint pose and the first
  player-controlled physics frame, plus the lip edge/vertex path. The
  definition-to-live body/frame conversion and its noncoincident anchors are
  now proven. No evidence yet authorizes pre-settling for an arbitrary number
  of ticks, zeroing the resulting assembly velocity, or replacing the authored
  anchors with a hand-built equilibrium pose.
- The non-face branches of TU3 triangle maximum-feature construction and
  triangle edge/vertex fixup. The complete wheel sphere/triangle face path is
  ported, but capsule/triangle, box/triangle, deck-fan/terrain, and contacts
  whose separating normal classifies to an edge or vertex are not yet eligible
  for runtime use. The available 6.14 successor implementation is evidence of
  an API replacement, not permission to substitute its algorithm.
- Bit-identical replication of VMX128 reciprocal/reciprocal-square-root
  estimates and fused operation rounding. The governing quaternion,
  world-inertia, displacement, drag, speed-cap, energy, cool-down, and
  accumulator-reset equations are ported, but host `f32` arithmetic is not
  claimed bit-identical to Xenon VMX128.
- Coping stalls, grinds, handplants, and advanced transition tricks.
- The physical consumer and exact orientation equations behind
  `FORCE_ANIM_SKATEBOARD` in ordinary natural air. Authority selection is
  observed, but replacing a vertical launch pose with a guessed world-up
  interpolation would still violate the evidence gate.
- Any physical in-air “target lock.” Current evidence supports trajectory
  prediction/landing assistance, not direct steering suppression or magnetic
  attraction.

These unresolved items must stay explicit in code and tests. A later pass may
resolve them from static data or authorized telemetry; they are not tuning
slots.

## Provisional playable bridge authorized after the evidence gate

On 2026-09-01 the user explicitly authorized temporary assumptions where the
TU3 evidence remains incomplete. `src/transition.rs` supplies that isolated
point-carrier bridge for the main University collision provider. It does not
claim that its unresolved pieces are retail-exact.

The bridge retains the proven boundaries:

- decoded collision triangles are the only runtime support geometry; no
  analytic quarter pipe, lip plane, or target collider exists;
- grounded motion uses world gravity `(0,-9.8,0)` and carries momentum between
  adjacent authored face normals;
- the face probe cannot extend beyond a triangle edge, so passing the open lip
  immediately loses physical contact;
- airborne motion integrates gravity only. Landing prediction may condition
  the visual up vector, but it never writes X/Z velocity or applies a
  target-derived force;
- re-entry requires a swept segment to cross a real triangle face while moving
  into its normal. Restitution is the recovered zero value;
- the recovered fourth-frame established-air reacquisition predicate owns the
  public grounded flag after physical contact resumes;
- ordinary push, Ollie carriers, contact friction, trick graphs,
  animation buffering, and camera coefficients remain on their prior paths.

The following pieces are provisional and named as such in code:

- one point at the skater root represents the unresolved initialized
  seven-body assembly;
- a `0.14 m` previous-normal support window combines retail's recovered
  `0.1 m` simulation padding with a `0.04 m` carrier allowance;
- adjacent support normals must have dot product at least `0.5`; this admits
  the subdivided ramps and bank faces but rejects the 90-degree lip-to-deck
  corner as continuous ground;
- the recovered Pumping direction and default mode factor `18` are driven by a
  right-stick/curvature proxy scaled by `1/24`, standing in for the unresolved
  animated-COM caller operands;
- grounded visual alignment uses `0.1 s`, matching the decoded
  `SpeedToAlignToGround_PhysAir` value as a time assumption; natural air uses
  the recovered `NaturalAirTime = 0.2 s` as its orientation response;
- on transition geometry, an Ollie keeps the measured anticipation and
  launch-speed provider but gives world motion to the ballistic transition
  carrier. Touchdown is collision-driven rather than forced at the measured
  flat-ground carrier frame.

Deterministic coverage uses the retained test-only collider fixture for
sub-lip coast and reversal, contact continuity, bounded mechanical energy,
open-lip release,
absence of airborne target locking, bounded pumping energy, swept deck
landing, four-frame contact filtering, transition Ollie launch/landing,
orthonormal visual orientation, and camera-frame non-inversion. Visual
verification remains required for presentation quality and provisional tuning.

## Transition High-camera integration

Recovered `cameragraph_high.xml` proves that the High graph uses
`bl_high_chase` for grounded forward riding. Air with predicted duration over
`0.1 s` enters a separate hierarchy: ordinary and short re-entry air use
`bl_high_air`, while sufficiently large frontside/backside re-entry can select
`bl_reentry_fs` or `bl_reentry_bs`. `low_ollie` is limited by launch incline,
predicted airtime, predicted maximum height, and predicted landing height; it
is not the universal airborne shot.

The earlier Bevy camera only consumed board-root position, world yaw, speed,
and the filtered grounded bit. It therefore aimed at a fixed world-Y point
above the board even while the authored skater root rotated onto a vertical
transition. It also assigned all air the captured `low_ollie` pitch and
`0.60` vertical response. The supplied 2026-09-01 visual capture showed both
failures: the horizontal skater extended into the camera on the wall, then
natural lip air outran the slow low-Ollie vertical follow.

`src/camera.rs` now preserves the measured flat-map path unchanged and adds an
isolated transition-map bridge:

- `TransitionPhase::Airborne` selects `HighAir` unless a pop remains on a
  provisionally classified shallow surface;
- the focus point follows the conditioned visual-up axis, so it remains on the
  torso as the authored body rotates through vertical;
- the measured High chase distance and height remain unchanged;
- transition High air reuses the existing grounded follow response instead of
  the inapplicable captured low-Ollie lag;
- when an approaching transition's conditioned visual-up Y falls below the
  provisional `0.95` boundary, the existing measured yaw spring begins
  orbiting toward the inward surface-normal view. This provides enough lead
  time to stay on the playable side of both opposing vertical walls;
- a deterministic segment query keeps the camera on the focus side of authored
  collision geometry with a provisional `0.10 m` clearance.

The graph selection and its named shots are proven. The visual-up focus,
45-degree shallow/steep split, High-air spatial response, and camera-clearance
application are authorized provisional assumptions because the native
`bl_high_air`/`bl_reentry_*` shot-position payloads have not been recovered.
Those assumptions are transition-map-only and are covered by deterministic
shot-selection, vertical-body framing, geometry-clearance, two-wall traversal,
bounded camera-step, orthonormality, and no-flip tests.
