# Skate 3 TU3 grind graph port boundary

`src/grind_graph.rs` is a deterministic port of the recovered grind
MotionGraph/ActionGraph slice. It is not a port of grind-contact discovery or
grind physics.

## Evidence

Primary TU3 XML files and SHA-256:

- `MotionGraphIncludes\Grinds\Grinds.xml`
  `89042598DC9BCAC397E7CF43DFEBE37E1C452EE42062029E53BE5A6459B5029E`
- `MotionGraphIncludes\Grinds\T_Grind.xml`
  `57AE0ADF724FEE1C0FBA0C2E157F227FA5514AE7154042B2A9A10AA8E4AECDFC`
- `MotionGraphIncludes\Grinds\T_GrindWithGrabs.xml`
  `13BE73CBAA94162E71B410A265151CD3B190644CD97B7174F0E27CB3B11F8021`
- `MotionGraphIncludes\Grinds\T_GrindWithAGrab.xml`
  `BB697A076B765CE216CACF5CB4B71AED278323514A0A94798E8695C91B8C5765`
- `MotionGraphIncludes\Grinds\T_GrindGrabs.xml`
  `EB03028E2CD6EB9928C82F3585CD7672D68B7CAA960B6724E7951E963411D560`
- `MotionGraphIncludes\Grinds\T_BoardGrind.xml`
  `A842821E6B587427D870E13BE980BC4F444DFDBD8F3508B3A059B42027217B18`
- `MotionGraphIncludes\Grinds\T_BoardGrabs.xml`
  `2DAD3CFA4C40C059E8F061D1D5B7322BB4CE90BCC2B86F0434D02C39FAF51785`
- `MotionGraphIncludes\Grinds\T_BoardDoubleGrabs.xml`
  `DB609265C8757DEFA822C1CA800ACA6D493D6637788B68A13661775862BCD991`
- `MotionGraphIncludes\Grinds\T_BluntGrind.xml`
  `A862C557ABFD36B96ABDCE42F477DD298DE110B6BD23F67ACB18C80E28BAA7F3`
- `MotionGraphIncludes\Grinds\T_BluntGrindGrab.xml`
  `1B5215F73078DF2522192EA33809F7EA5ADBF18FF75365C2B8DE7D47910EC24F`
- `MotionGraphIncludes\Grinds\T_DarkGrind.xml`
  `21EC3FB82084D435519DCB226FCCF5937F5AB0220AC348E81E8D2227F4310787`
- `ActionGraphIncludes\grinding.xml`
  `523B3AC16FC0D186A6B348B79EC3DBC8BB440E81EDB787E4368C782FF4653C2D`

All are rooted at:

`C:\Users\Daddy\Documents\Skate3Research\research\reverse-engineering\VerifyCustomAnimation\data\state`

Relevant static binary identities remain:

- `0x82D69F80` `TrajectorySelector::CalculateGrindTrajData`
- `0x82D6A168` `TrajectorySelector::FindBestGrind`
- `0x82D6A398` `TrajectorySelector::ConsiderGrindPrimitive`
- `0x82D6A840` `TrajectorySelector::AnalyzeAndAdjustTrajectory`
- `0x82D712E0` `GrindAirAdjust::UpdateGrindAdjust`
- `0x82D71430` `GrindAirAdjust::ProjectPoints`
- `0x82D71F40` deck-Z/grind-angle calculation
- `0x82D72B40` `GrindAirAdjust::InitTargets`
- `0x82D41100` `PhysState_Grind_Boardslide::Enter`
- `0x82DEF1C8` `PhysOutConditioner_Grinds::NameGrind`
- `0x82D8A318` `GrindManager` constructor

## Ported observed behavior

- The grind parent uses `FORCE_PHYSICS_SKATEBOARD`.
- The 54 unique instantiated canonical names route through the recovered tail,
  nose, sideways, and square ActionGraph groups.
- A base grind state requests its cycle resource with a 0.3-second
  current-frame blend. There is no separate generic base-grind Into clip.
- `GrindControlFade` binds `DistToCog`, `twist`, and `GrindBalanceX` with
  `mTime=2.5`.
- Grab Into/Cycle/Out animation blend values are 0.3/0.1/0.1 seconds.
- Grab Into enters cycle at `WillExpire 0.01`.
- Standard `T_GrindGrabs` applies an explicit 0.05-second blend on that edge.
  Board, board-double, and blunt templates do not; the port reports inherited
  behavior instead of substituting 0.05.
- Direct-to-cycle edges use a 0.3-second blend.
- Board-double Out returns at `WillExpire 0.01`. Other Out templates have no
  explicit expiry predicate, so completion is an external resolved signal.
- Grab states expose `Grabbing=1.0` and
  `PhysGrindGrabMinHeight=0.2`.
- Air channel blends are 0.3 seconds normally, 1.0 for the one-grab template,
  and 1.5 for dark grinds.

## Typed external and unresolved inputs

- Rail/ledge candidate discovery, rejection, and selected contact.
- Trajectory projection and correction.
- The six-field chromosome and canonical-name table lookup.
- `IsCrouchedEnoughForBlendToGrabCycle` threshold and current-grab
  arbitration. The runtime accepts the resulting Into/DirectCycle decision.
- Blunt backslash/rail and dark approach resource selection.
- Exact completion semantics for grab-Out templates lacking `WillExpire`.
- Concrete physical leaves, playback rates, weights, and normalized times
  behind every virtual MotionGraph resource.
- Trick-out routing after the ActionGraph target and dark-trick animation
  authority.

The module accepts canonical names through `AsRef<str>`, so a separately
recovered `grind_chromosome` result can feed it without introducing a second
classifier or a compile-time dependency.
