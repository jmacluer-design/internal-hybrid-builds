# THIRD_PARTY: games/shatterworld-next.html (Shatterworld pass A: skill gems, Star Power, character classes)

Single-file build; three.js comes through the page importmap (no vendored copy, no network at runtime). Everything not listed below is original code / data written for this pass
(item names, gem names and numbers, class data, VFX, sounds, procedural art). Per the borrow rules: nothing was copied from commercial or reverse-engineered game dumps.

## Borrowed / ported blocks

| # | Source (repo + path) | Licence | What it is used for | Where it lives in `shatterworld-next.html` |
|---|---|---|---|---|
| 1 | `games/colossus.html` (this repo, our own earlier build): `Ribbon` class (camera-facing triangle-strip trail) and `setBeam` (unit cylinder stretched between two points) | ours (internal) | Star Power rainbow trail + Gust / Rewind dash trails (`GRibbon`), Sunbeam and the dash streak beams (`fxBeam`) | `// ---- VFX toolkit` block: `class GRibbon`, `ribbonMat`, `fxBeam`, `updateGBeams` (re-written for our pooling rules: no per-frame allocation, additive shader with a rainbow mode) |
| 2 | `games/shatterworld.html` (this repo, the shipped merged flat + VR + RPG build): hero rig `buildPlumber` / `part` / `poseTo` / `applyPose`, shard-collect + local-shatter machinery, cube ground (`C`, `WC`, `WV` wave), `<rpg-core>` / `<rpg-game>` / `<vr-rpg>` layers, VR panel + haptic scheduler (`vrPanel`, `RV_HP`, `vrHapPlay`), `rpgSigil` item-icon approach | ours (internal) | the base everything is built on. Class models are style functions on the existing rig (`CLASS_MODELS`); skills / Star use the existing shatter + particle systems; gem icons use the same canvas-icon approach; the VR gem UI reuses the RPG panel + hot-region protocol | whole file (unchanged parts) + `// <gem-game>` (wrappers re-bind base functions from the outside) |
| 3 | three.js r169 (`three`, `three/addons/utils/BufferGeometryUtils.js`: `mergeGeometries`) | MIT | baking the six character-select figurines into 1 body mesh + 1 outline mesh each (VR draw-call budget); instanced meshes / ring / cylinder / octahedron geometries as plain API use | importmap in the page; used in `gvFlatten`, `gvFigBuild`, `PJM` projectile meshes |
| 4 | three.js r169 example pattern: toon-outline back-face hull (`outlineMat`, already in the base build) | MIT | outlines on the class models / figurines | base build, `part()` |

## Read for ideas only (no code, data or assets copied)

| Source | Licence | What was taken (concept only) |
|---|---|---|
| `pathofbuildingcommunity/pathofbuilding` (`src/Data/Skills`, gem / support data model) | MIT code, but its data tables are derived from a commercial game's extracted data, so NOT copied | the general *structure* of a socket / link / support-gem build (items carry coloured sockets, links form groups, supports modify the skill in their group, gems level with use). Our gems, supports, numbers, formulas and names are all original (`<gem-core>`), checked by `gem-unit.mjs` |
| `flareteam/flare-game` (`mods/*/powers`, GPL / CC BY-SA content) | GPL / CC BY-SA | reference for the data-driven "power" idea (a skill is a table row + trigger + effects). No file, text or number used; our `GEM_SKILLS` / `SK` table is original |
| `noidexe/top-down-action-rpg-template` (Godot, MIT) | MIT | looked at its hotbar / ability-slot pattern. Not portable to a three.js single file, nothing copied |
| `alesan99/mari0_ae`, `sm64js/sm64js`, `n64decomp/sm64` | reverse-engineered / commercial dumps: READ ONLY | the *feel* targets of a collectable star power-up (short invulnerability, trail, enemies knocked away). Our Star Power is written from scratch with original art / audio / numbers |

## Could have borrowed but did not

* Path of Building gem / skill tables: derived from commercial game data, not allowed.
* Flare engine power code: C++ / GPL, nothing to port into a browser single file.
* No audio / art / font assets: every sound is a scheduled WebAudio note (start / stop scheduled), every icon / model is procedural.
