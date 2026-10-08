# Default Skate 3 skater recovery

This document records the evidence and reproducible boundary for the private
default-skater asset used by the Bevy parity project. No extracted retail mesh,
texture, recipe, animation, or generated GLB is tracked by Git.

## Result

The integrated preset is the Xbox 360 retail male fallback Create-a-Skater:

```text
SavedRecipeFallbackMale.bin
SHA-256 FDE81E75125250266EE3118705ACB921B6A89F903810683BF91190FC1C13237E
payload offset 0x10
recipe cas_db
type CreateACharacter (3)
gender byte 1
```

It is assembled from ten selected LOD0 modules:

| Slot | Retail catalogue entry | Asset ID | LOD0 model | Material |
|---|---|---|---|---|
| Arm | `male_arms_shoulderdown` | `af71f8ae8ef28d10` | `00000dce03e38811` | `0000557b03e38817` |
| Feet | default shoes | `85b73da337acc9ce` | `2c7f381100170192` | `2c7f381700171aa8` |
| Hair | default male hair | `bab72a34fa64163b` | `00000de203e38811` | `00000c4c03e38817` |
| Organ | light-brown eyes | `b278a4bfb3d6c4bc` | `00000e1a03e38811` | `00000c6203e38817` |
| OuterTorso | `tanktop` | `a3a732c5dd7e7e2c` | `00000ec603e38811` | `0000129b03e38817` |
| Pants | `denim_straight_leg_pants_male` | `d92b14a037b78985` | `2c7f381100170177` | `2c7f3817001719cd` |
| Rostral | `head_mesh` | `9461df2eb3d482dc` | `00000ee803e38811` | `2c7f3817001715dc` |
| SkateBoard | default board | `a841a65d5c4dd593` | `0000157803e38811` | `000044e603e38817` |
| SkateTruck | default trucks | `c6f01c93097b7fb5` | `0000157a03e38811` | `000048e603e38817` |
| SkateWheel | default wheels | `87d0fa0ea0366b23` | `0000157c03e38811` | `00004acc03e38817` |

The complete IDs, low-LOD pairs, texture channels, colors, and source hashes
are in `tools/default_skater_retail_manifest.json`.

## Why this means "default"

### Proven

- Retail initialization calls `CACPartDB::GetDefaultPartID` for all 26
  character slots. `CASPlayerInitializer::InitializePlayer` is
  `sub_8253D470` / community symbol `0x8253D470`;
  `CACPartDB::GetDefaultPartID` is `0x82DDBBB8`.
- The retail data contains explicit fallback recipe files named
  `SavedRecipeFallbackMale.bin` and `SavedRecipeFallbackFemale.bin`.
- The male fallback parses as a full `cas_db` Create-a-Skater recipe and
  resolves every selected model, material, texture, and low-LOD partner in
  `createacharacter.big`.
- The catalogue XML independently names the selected models and records the
  tank top's required `shoulder` arm model and the pants' `low waist pant`
  wear style.
- The fallback body values are skinniness `0`, fatness `0`, and `0.25` for all
  17 face controls. Its hair color is `(0.02, 0.01, 0.01)` and its head/arm
  skin color is `(0.72, 0.57, 0.49)`.
- The user's current `SKATER.P` is a later customized helmet/long-sleeve
  outfit. It is not used by this build.

### Platform/profile alternatives

The Xbox 360 retail data has at least two gender-specific fallback presets:

```text
male   FDE81E75125250266EE3118705ACB921B6A89F903810683BF91190FC1C13237E
female D8F0227F5B93C688CE7093A6694BFFB2455C8FF643D7F6FE61F6A2317281C8F5
```

The male preset is selected because the existing SK8/Bevy work uses the male
compact skater proportions and Xbox 360 RX2/ABIN data. This is not an arbitrary
wardrobe choice. No claim is made that another platform uses byte-identical
fallback files; only the local authorized Xbox 360 retail data is in scope.

## Character normal-map encoding

The retail character normal textures are DXT5nm maps, not conventional RGB
normal maps. The recovered character shader samples `.ag`: tangent X is stored
in alpha, tangent Y in green, and positive Z is reconstructed before the
normal is normalized. Passing the decoder's grayscale RGB representation
directly to a glTF normal texture produces invalid near-horizontal normals and
harsh black/white mottling across the character.

The private-asset build now deterministically converts each selected normal:

```text
x = alpha * 2 - 1
y = green * 2 - 1
z = sqrt(max(0, 1 - x*x - y*y))
```

Out-of-disc quantization values are normalized in XY with Z set to zero,
matching the retail shader's saturated reconstruction followed by
normalization. Extraction, material, and GLB validation reports identify this
path as `dxt5nm-ag-to-gltf-rgb-v1`, so a stale private GLB is rebuilt instead
of silently passing verification.

## Character UV convention

RX2 texture coordinates use the retail Direct3D/top-left convention. Blender
UV layers use a bottom-left convention, and Blender's glTF exporter performs
another conversion when serializing `TEXCOORD_0`. The character material
postprocessor therefore writes `(u, 1-v)` into Blender so the final GLB
contains the original RX2 `(u, v)` values. Writing raw RX2 UVs into Blender
causes a vertical texture mirror: pants details move upside down, shoe panels
swap vertically, facial features move across the scalp and mouth, and the
hair/neck regions exchange positions.

The material and GLB validators identify this conversion as
`rx2-top-left-to-blender-bottom-left-v1` and assert each exported primitive's
first UV against its source RX2 value.

## Recipe tint export

The fallback recipe's skin tint `(0.72, 0.57, 0.49)` and hair tint
`(0.02, 0.01, 0.01)` are linear shader multipliers. Blender's legacy
`MixRGB` node previews the multiplication but its glTF exporter does not
serialize that node as a factor. The material builder now uses the exporter's
recognized RGBA Multiply form, producing exact glTF `baseColorFactor` values.
Validation asserts every component's exported factor against the recipe and
identifies this path as `gltf-linear-base-color-factor-v1`.

## Hair alpha cutout

The selected hair material has a separate A8-like retail mask. Its decoded
values intentionally include partially covered texels, but the retail
material uses those values as a hard cutout rather than translucent surface
opacity. A direct image-alpha connection made Blender 5 export
`alphaMode: BLEND`, which caused the visible hair shell to render like tinted
glass in Bevy.

The material graph now contains an explicit `alpha > 0.5` operation recognized
by Blender's glTF exporter. The final material is `alphaMode: MASK`; glTF's
default `alphaCutoff` is `0.5`. Validation identifies this path as
`gltf-mask-retail-alpha-v1` and rejects transparency on every non-hair module.

## Fallback face and body morph assembly

The selected LOD0 head RX2 contains 19 named dense blend-shape streams:
`fat`, `thin`, and 17 `local_*` facial controls. The facial names exactly
match the fallback recipe's 17 serialized face values, including
`local_chin_length`, `local_jaw_chiseled`, `local_jaw_depth`, mouth, eye,
brow, and nose controls. The fallback stores `0.25` for every facial control
and zero for both body controls.

The prior export decoded only the base vertex stream. That omitted the
fallback's saved face assembly and left the jaw/chin at the raw authoring
base. The private build now decodes the shipped 16-byte dense delta streams
and bakes:

```text
position = base + sum(retail_delta[target] * recipe_weight[target])
```

No hand-authored vertex correction is used. The 17 active head targets carry
position deltas only; the unused clothing fat/thin targets can carry normal
deltas but remain unapplied because their recipe weights are exactly zero.
The build rejects target-name/order changes, unexpected stream layouts,
non-unit per-vertex factors, or an active normal-delta stream it cannot
faithfully represent.

The final head assembly moves 933 of 1,395 source head vertices, with a
maximum combined source-space displacement of `0.0153988476 m`. Its stable
source-position hash is
`B61AAE1DB41C914A07707F8C496F43A86079CDD9BA6BB7BBDE66BEC21B6013C8`.
Material and GLB validation identify this path as
`rx2-dense-position-delta-direct-weight-v1` and assert the exported first
vertex against the reconstructed source result.

## Authorized source boundary

The deterministic build accepts only these exact retail identities:

```text
createacharacter.big
bytes 472328128
SHA-256 B87E9E01D446DF37D707D0F2AC2AB872BAF29BBA91EEAE5FD08997C7D475D4EB

SavedRecipeFallbackMale.bin
bytes 157948
SHA-256 FDE81E75125250266EE3118705ACB921B6A89F903810683BF91190FC1C13237E
```

The public build uses the source decoders vendored under `tools/vendor` and the
owned-game extractor under `tools/owned_game`. A user supplies a legally owned
Xbox 360 ISO; extraction and generated outputs go under ignored
`work/private-assets` and `assets/private`. No external research checkout is
required.

The build reuses the user's proven local tooling:

- `UTT-1.1.7/assets/bigfile.exe` for the retail BIG extraction;
- `UTT-1.1.7/rx2_parser.py` for Xenos tiled texture decode;
- the vendored `tools/vendor/skate3_anim/rx2_skeleton.py` for RX2 geometry, skin,
  inverse-bind, UV, tangent, binormal, and normal recovery;
- the vendored `tools/vendor/skate3_anim/blender_rx2_abin_export.py` for the
  established RX2-to-ABIN bone-name mapping. The earlier character work passed
  through 407-action and 643-action checkpoints; current main generates one
  authoritative 2,580-action bank.

The reverse-engineering audit also found the later native CAC implementation
in `Skate3CustomEngineLayer-Clean/Source/src/skate3_multiplayer_assets.cpp` and
the full 131-channel CAC skeleton:

```text
cac_skeleton.json
bones 131
SHA-256 29199C2013441880D1FDE75EDFC5381046A55CCA69B8BED442D80F8CD9ACF34A
```

## Geometry, rig, and visibility

The selected retail source geometry is modular and remains independently
identified through material primitives:

```text
parts       10
vertices    9415
triangles   14584
RX2 bones   110 unique names including board hardware
```

No synthetic body mesh is placed beneath the outfit. The fallback has no
selected `InnerTorso`, `Leg`, `Hat`, `Glasses`, `Accessory`, `Jewellery`,
`Sock`, or `WristItem` module. This is the retail visibility/masking result:
the tank top uses the shoulder-arm model and the pants provide the visible leg
surface, so duplicate placeholder torso/leg geometry is not exported.

The shipped RX2 vertex weights are consumed directly. The build does not
generate, heat-map, mirror, or hand-paint replacement weights. For the Bevy
runtime, bone names are mapped into the existing compact OnBoard/OffBoard
carrier. Helper and finger channels absent from that compact animation bank
resolve to their nearest retail ancestor. This preserves all source influences
that have compact counterparts while retaining the existing gameplay-facing
33-joint skin. Current main drives the textured character directly from the
unified 2,580-action `default_skate3_skater.glb`.

The full 131-channel CAC bind evidence is validated offline, but replacing the
runtime animation carrier with the offboard CAC gesture rig is not part of
this change. Those rigs have different bind bases; copying local rotations
between them would be incorrect and would regress the established animation
bank.

## Materials

All 33 texture references from the fallback are hash-checked and decoded.
Diffuse, normal, hair alpha, specular, blur-mask, decal, decal2, and
environment maps remain available in the ignored private material tree.

Runtime materials use:

- selected diffuse maps as sRGB base color;
- recipe hair/skin tint multiplication;
- selected normal maps as non-color tangent-space inputs;
- inverse selected specular maps as roughness equivalents for skin/head;
- metallic/roughness equivalents for trucks and wheels;
- hair cutout alpha;
- back-face culling.

`decal` and `decal2` are not blindly baked into base color. The fallback has no
active graphic URL, and these channels point to generic shader templates.
Unconditional compositing produces false face markings and logos. The maps are
preserved for future reconstruction of the retail decal projection shader.
The eye environment map and skin blur masks are also preserved but have no
direct Bevy StandardMaterial equivalent.

## Deterministic validation

The private build currently proves:

```text
actions at early character checkpoint 407
actions at merged-bank checkpoint      643
actions in current unified bank       2580
source modular parts                 10
source vertices                    9415
source triangles                  14584
runtime skin joints                  33
glTF material primitives             10
glTF materials                       10
embedded images/textures             22 / 22
maximum weight-sum error       9.40636e-8
maximum ABIN pose error        9.53674e-6
maximum sampled deformation    8.64000e-6 m
maximum root anchor travel      1.68095e-8 m
maximum toe-target error        3.60608e-6 m
```

The exported GLB expands vertices at UV/normal/material seams and discards two
degenerate source triangles. Source topology counts remain asserted before
export.

Representative deformation validation samples first/middle/last frames of:

- riding;
- deep ollie anticipation;
- ollie air;
- high 360 flip air;
- offboard walk;
- mount;
- dismount into run.

It rejects non-finite bone matrices, non-finite vertices, collapsed bounds,
and exploded bounds. Existing foot-target and 360-flip physical-pose checks
also run unchanged.

## Reproduction

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File tools/build_default_skater_assets.ps1 -ForceRebuild
```

Read-only reconstruction/asset verification:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File tools/build_default_skater_assets.ps1 -VerifyOnly
```

One-click headless verification:

```text
LAUNCH LATEST MAIN.bat --headless
```

The launcher never starts SK8.

## Evidence classification at handoff

### Proven

- preset file identity and complete selected component/material/texture IDs;
- exact fallback body values and all 19 selected head blend-shape identities;
- retail model/texture hashes;
- exact modular geometry and source skin data;
- preservation of the authored animation coverage from the 407-action and
  643-action checkpoints inside the current unified 2,580-action runtime bank;
- runtime joint/bind integrity, finite deformation, and physical foot/board
  target checks;
- no duplicate placeholder body modules.

### Derived

- Bevy roughness equivalents derived by inverting retail specular maps;
- PBR metallic/roughness constants for material families without a direct
  Skate 3 shader equivalent;
- compact-carrier influence resolution for native channels absent from the
  existing 36-channel animation hierarchy.
- baking the retail dense position deltas with the serialized recipe values
  into the static fallback-head base geometry.

### Inferred

- Xbox 360 male fallback is the intended match for the user's existing male
  SK8/Bevy character work. The fallback filename, serialized gender, component
  IDs, and current project provenance support this choice.

### Unresolved

- exact Bevy equivalents for the retail blur-mask/environment/decal projection
  shader stages;
- platform-specific fallback differences outside the authorized local Xbox 360
  data;
- whether non-default presets with active clothing fat/thin streams require
  additional normal-delta reconstruction;
- animation of fingers and facial helpers on the compact runtime carrier.

### Awaiting human visual verification

- recognizable face and complete default outfit identity;
- texture color/normal orientation under the Bevy lighting setup;
- clothing/body clipping in deep crouches, tricks, and pushes;
- elbow, knee, ankle, and hair cutout appearance;
- shoe/foot/board alignment;
- offboard locomotion and mount/dismount appearance.

Automated checks prove structure and deformation stability. They do not claim
visual parity.
