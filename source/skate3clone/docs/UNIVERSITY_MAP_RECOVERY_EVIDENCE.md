# University map recovery evidence

This integration consumes the user's existing preservation-first SK8 Engine
University work. It does not reinterpret the retail archive or approximate the
district from screenshots.

## Authoritative inputs

Observed offline on 2026-09-01:

- retail archive:
  `C:\Users\Daddy\Documents\Skate3Recomp\game\data\content\worldDIST_University.big`;
- archive identity: 798,165,184 bytes, SHA-256
  `37D6A4517BD0A5E25F493F18409EDFBD3B3D74229F12F1AB6C15598AA3240091`;
- extraction/tool lineage:
  `C:\Users\Daddy\Documents\Skate3CustomEngineLayer-UniversityFullFidelity\Source`;
- authoritative tool commit:
  `0dafeb138973d48f67c7be6df1d9f9d6e7c3c5a4`
  (`codex/university-full-fidelity`);
- authoritative SKATE v15 package:
  `tools\vanilla_map_extraction\intermediate\university_full_fidelity\University.full-fidelity.v15.skate`;
- package identity: 243,409,335 bytes, SHA-256
  `1E3FC631E00855A5E9B5514BF26FD2C297283F5A5CCE759A8D278CE8F9E19F55`.

The staged package under
`out\university-visual-check\prepared\owned_maps\University.skate` has the
same byte count and hash. The staged manifest independently records the same
package hash and the embedded exact-collision archive hash.

The older
`C:\Users\Daddy\Documents\Skate3CustomEngineLayer-Clean\VanillaMapExtraction`
tree is useful historical evidence but is not the final contract. Its Blender
scene and first extraction cache predate the v15 object ownership, collision
identity, and exact-collision embedding work.

## Exact district and dependency set

Observed in the full-fidelity branch documentation and extracted stream tree:

- level: official base-game `DIST_University`;
- one source archive: `data/content/worldDIST_University.big`;
- extracted archive: 647 files, 798,135,872 bytes;
- twelve district index files:
  `DIST_University_{Pres,Sim,Tex}.{xst,xsm,xss,xmm}`;
- global payloads: `cPres_Global.xsf` and `cSim_Global.xsf`;
- spatial payloads: 231 presentation, 230 simulation, and 172 texture cells.

No neighbouring district archive is required for the shipped static
University presentation. `worlddmo.big` was inspected in the prior work; its
decoded templates do not form a proven University `InstanceData` pair, so it
is not added as an invented dependency.

The complete cell inventory is retained in the source full-fidelity document
`tools/vanilla_map_extraction/UNIVERSITY_FULL_FIDELITY.md`. The tracked
machine-readable acceptance values for this port are in
`university/university_expected.json`.

## Preserved data

The ignored source package remains the preservation boundary. It contains:

- 1,645,617 visual triangles, 2,120,046 indexed vertices, normals, base UVs,
  exact secondary/lightmap UVs, decal UVs, and packed tangent frames;
- 8,729 materials, 8,546 retail draw definitions, all 40,663 named texture
  bindings, all 67,475 parameter entries, retail shader identities, alpha
  modes, culling policy, and presentation depth layers;
- 2,046 embedded textures and every known diffuse, transparent, normal,
  normal2, specular, lightmap, detail, macro-overlay, decal, environment, and
  noise binding;
- 1,270 selected byte-exact lightmap pages bound to 8,489 mesh parts;
- 1,133,643 portable collision triangles with packed Skate audio, physics,
  and pattern surface channels plus native edge/corner codes;
- a compressed `RWCM` extension containing all 301 untouched retail
  `ClusteredMesh` payloads and an `RCID` identity table;
- 4,201 retail grind rails and all 27,008 native cubic segment payloads;
- 12,993 named editable owners, source ranges, collision ownership, inferred
  grind ownership, and 5,027 retained `InstanceData` records in extraction
  metadata;
- original bounds, map environment, generated spawn, source stream/cell
  provenance, and unknown retained metadata extensions.

Extracted binaries, converted textures, geometry caches, and the source SKATE
package are always written under ignored `assets/private/university`.

## Coordinate, material, and lighting contract

Observed:

- retail/runtime coordinates are metres, right-handed, Y-up;
- the extraction manifest's runtime-to-Blender conversion is
  `(x, -z, y)` and flips texture V during the Blender import;
- SKATE v15 is already back in runtime Y-up coordinates. Bevy therefore
  consumes package positions without another axis swap or scale;
- the package's UVs and packed images are an owned-world pair and must not be
  independently flipped;
- colour textures in the exact SK8 world path are sampled unsigned and
  linearized as `encoded * encoded`;
- Skate 3 lightmaps use the same `encoded²` decode, bilinear clamp sampling,
  and mip level zero;
- University package lightmap strength is `0.25`, cancelling the generic
  owned renderer's `*4` path so the net lightmap energy remains `encoded²`;
- normal/specular and other data maps are linear;
- material alpha has 6,572 opaque, 2,118 mask, and 39 blend variants;
- University requests dynamic lighting off by default so retained baked
  lighting is authoritative.
- the local Skate 3 retail model set contains `DIST_skybox.rx2` (SHA-256
  `0f828116c1661a24e7fb1717fa3130b844bf2ae9536ba295e3977de394893dae`)
  with 230 vertices/380 triangles and `DIST_skybox_Textures.rx2` (SHA-256
  `bee4275f7097f7fe41e6cdc83b6255864e7a15f304b2518a468b2c65a6c0431b`);
- texture index 1 in that retail sky texture set is the complete 2048x256
  panorama (decoded SHA-256
  `e09bb4122569885fc4867bbd5a1ba9453ea9e5dd0f743b496c4770e78e58381d`);
- the recovered SK8 world sampler uses anisotropic mip sampling for ordinary
  material textures, while the lightmap path explicitly uses bilinear clamp
  at mip level zero.

The Bevy adapter decodes the package's colour and lightmap samples into linear
half-float `encoded²` pixels before handing them to Bevy, avoiding an 8-bit
re-quantization. Stock Bevy lightmaps then multiply that decoded value by
diffuse colour with mip-zero sampling. Bevy also applies the active physical
camera exposure after lightmap multiplication, so the University camera uses
EV100 `-0.2630344` to produce the recovered unit multiplier. Bevy's default
EV100 9.7 produces approximately 0.001 and is not part of the SK8 equation.
Generic sun and point lights remain disabled for University. This avoids
rebaking and avoids using a guessed directional source as a substitute.

At the user's visual-check request, the Bevy adapter adds a derived
cool-neutral ambient fill with brightness `0.22`. It affects lightmapped
meshes so dark foliage receives a minimum readable contribution and also
lights the non-lightmapped skater. This is not represented as recovered
retail lighting. No directional or point-light substitute is added.

## Derived data

- The configured spawn `(330, 133.0059814453125, -710)` with heading
  `-pi/2` was generated by the SK8 conversion through a deterministic
  collision raycast near the intended Super Ultra Mega Park deck. It is
  evidence-backed and collision-validated but is not claimed as a decoded
  retail `LocationDescData` record. The converter intentionally placed its
  marker one metre above the chosen surface; Bevy retains that marker and
  starts the simulation root on the exact collision hit.
- The Bevy collision broadphase is a deterministic XZ grid over unchanged
  portable collision triangles. Grid membership is derived; triangle
  positions, winding, surfaces, materials, and edge codes are preserved.
- Presentation sector roots come from retained source-stream names. A spatial
  fallback is used only when a material has no parseable source cell, and is
  labeled derived in the generated cache manifest.
- Rail ownership in v15 is itself a prior deterministic spatial inference
  because no retail rail-to-instance foreign key exists.

## Unresolved or unsupported at this checkpoint

- authoritative packed retail normals for mesh parts outside the 3,121
  source-frame set (the retained UTT geometry-derived normals remain);
- cube-map face/array shape and some exact environment/reflection families;
- 64 retained but undecoded irradiance sections;
- DMO dynamic props, AI routes, hinged doors, and local lights;
- a decoded retail `LocationDescData` default spawn;
- active rail acquisition thresholds. The Rust grind classifier explicitly
  marks those thresholds/providers unresolved, so this map adapter preserves
  and indexes every rail without inventing engagement constants.

These limitations are not hidden by loader or hash success. Visual
confirmation remains a user checkpoint, and no live SK8/Skate 3 harness was
used for this work.
