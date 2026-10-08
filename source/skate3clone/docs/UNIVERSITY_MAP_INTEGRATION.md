# University map integration

## Launch

Run `LAUNCH LATEST MAIN.bat` from the repository root.
The launcher:

1. finds and hashes the authoritative SK8 v15 University package;
2. rebuilds or verifies ignored `assets/private/university` caches;
3. selects `University District`;
4. builds and runs this exact worktree.

Use:

```bat
"LAUNCH LATEST MAIN.bat" --headless
```

for the no-window acceptance path. It validates all source/cache hashes,
package and render inventories, visual vertex/index integrity, lightmap UV
bounds and binding count, collision triangles and packed classifications,
the collision-backed spawn, and all native rail records. It exits only after
the verifier process has ended. Neither mode launches SK8.

The cache generator requires the user's existing Python 3.14 installation
because the proven v15 analyzer uses Python's standard Zstandard decoder.
Missing or stale sources produce a hash-specific error and list the supported
environment overrides:

- `SKATE3_UNIVERSITY_SK8_SOURCE`
- `SKATE3_UNIVERSITY_PACKAGE`
- `SKATE3_UNIVERSITY_RETAIL_ARCHIVE`

## Runtime boundary

University is the normal no-argument game map. `SKATE3_LEVEL=university` or
`--level=university` remains supported for explicit launchers. The existing
flat parity fixture remains available for deterministic diagnostics through
`SKATE3_LEVEL=flat` or `--level=flat`; headless gameplay replays continue to
construct their fixture directly and do not load University.

The adapter changes map data only:

- exact portable collision enters `GroundProvider` through a deterministic
  16-metre XZ broadphase;
- packed retail audio/physics/pattern classification is exposed as the
  gameplay surface ID, while source mesh ID, material ID, and edge codes stay
  attached to collision contacts;
- the existing four-metre fixed-step contact probe and all skating constants
  are unchanged;
- all native rail cubics are decoded and retained as a resource, but active
  grind acquisition remains disabled until its retail thresholds are proven;
- reset returns to the selected level's collision-backed spawn.

The package spawn marker is `(330, 133.0059814453125, -710)` at heading
`-pi/2`. The upstream converter intentionally authored that marker one metre
above its collision raycast hit. The Bevy simulation root stands on the exact
hit at approximately `y=132.005`; the marker, clearance, and provenance remain
in the manifest.

## Rendering

The 1,645,617 triangles are batched into 8,546 contiguous recovered retail
draw groups. Package positions are consumed unchanged in right-handed,
Y-up metres. UVs are not flipped.

Colour and lightmap texels are converted from the proven SK8 unsigned sample
to linear half-float `encoded²` values, avoiding an 8-bit re-quantization.
Lightmaps use UV1, bilinear clamp, mip level zero, and Bevy's multiplicative
lightmap path at net exposure 1. The University camera uses EV100
`-0.2630344`, which cancels Bevy's physical-camera multiplier
(`exp2(-EV100) / 1.2 = 1`); leaving Bevy's default EV100 9.7 in place would
attenuate the recovered lightmaps to roughly 0.001 and render the map as
silhouettes. University has no generic sun or point-light substitute. A
user-requested low-energy Bevy ambient fill (`0.22`) lights the non-baked
skater and lifts black foliage; it is explicitly derived rather than claimed
as a retail frame constant. Normal/ORM data stays byte-exact linear.
Alpha mode, cutoff, culling, base UV addressing, normals, and reconstructed
tangent handedness are retained by the stock material adapter.

Ordinary colour and data textures receive deterministic full mip chains and
8x anisotropic sampling. Retail lightmaps remain the deliberate exception:
bilinear clamp at mip level zero, matching the recovered SK8 shader. This
separation removes the moving high-frequency shimmer without bleeding
neighboring lightmap atlas cells.

The camera-relative sky uses the retail Skate 3 `DIST_skybox.rx2` dome
(230 vertices/380 triangles) and the byte-verified 2048x256 panorama from
`DIST_skybox_Textures.rx2`. These copyrighted inputs and their cache remain
ignored. The panorama and dome are preserved; the retail sun-ramp frame
constants are unresolved and are not invented.

The active character now uses one generated private asset:
`default_skate3_skater.glb` supplies the ten textured retail visual materials
and the complete 2,580-action animation bank. This replaced the older split
layout where `skater_push.glb` supplied 643 clips. The generated GLB remains an
ignored private asset. The University launcher checks all 2,580 animation
clips, all ten textured visual primitives, the 35-node runtime contract, and
embedded base-colour/normal texture coverage before starting Bevy.

University also adds a derived 450-lumen cool-neutral fill at the follow
camera. The University camera and the skater's complete scene hierarchy use
both the world and character-fill layers; without the fill layer on the
camera, Bevy excludes the point light during clustered-light assignment.
University geometry remains on the world layer with baked lightmaps, and the
fill has `affects_lightmapped_mesh_diffuse` disabled, so it does not replace
or brighten the retail baked diffuse result. Unlightmapped special-family
draws are already explicitly unlit. The skater stays on both layers so the
existing parity fixture's ordinary world lights continue to affect it.

The preservation manifest keeps every named binding, parameter, shader
family, unsupported channel, decal UV, object/source record, and exact package
block. Stock Bevy materials do not yet reproduce secondary-albedo blends,
family-specific water/environment/decal equations, or the 64 undecoded
irradiance sections. Unlightmapped special-family draws use an explicit unlit
fallback so they remain inspectable without a fabricated dynamic light.

## Visual checkpoint

The user-run checkpoint should inspect:

- default spawn and heading on the Mega Park deck;
- map orientation, metre scale, and world extents;
- continuous collision on flats, slopes, banks, stairs, and ramps;
- rail/ledge alignment without claiming active grind acquisition;
- diffuse, normal, specular/roughness, emissive, cutout, blend, and decal
  appearance;
- lightmap energy and colour in direct sun, shadow, and interiors;
- character readability, dark tree coverage, and retail sky orientation;
- texture stability while moving across grazing-angle ground and hills;
- UV/lightmap seams, transparent edges, and double-sided surfaces;
- missing chunks, props, vegetation, or distant presentation;
- draw distance and any sector-transition visibility;
- startup time, frame time, memory use, warnings, and error-log health.

Visual correctness is deliberately not claimed by automated verification.
