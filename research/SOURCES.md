# Research sources (reference only, private use)

Shallow clones live OUTSIDE this repo (never committed). Re-pull with e.g.
`GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 https://github.com/<owner>/<repo> /home/user/<owner>/<repo>`

| Repo | Commit | License | What we mine it for |
|---|---|---|---|
| [n64decomp/sm64](https://github.com/n64decomp/sm64) | 9921382 (2023-08-17) | `LICENSE.md` (decompilation; assets come from your own ROM) | `src/game/mario_actions_moving.c`, `mario_actions_airborne.c`, `mario_step.c`, `camera.c`: the real SM64 movement constants and state machine |
| [sm64js/sm64js](https://github.com/sm64js/sm64js) | 04c1a98 (2025-02-02) | WTFPL | `src/game/Mario*.js`, `Camera.js`: the same movement as readable JavaScript (easiest to port into the browser heroes) |
| [mohsenheydari/three-fps](https://github.com/mohsenheydari/three-fps) | 625a18c (2022-05-22) | `LICENSE` (MIT per its README) | three.js + ammo.js FPS: entity-component layout, FPS controller, NPC state machine (`src/FiniteStateMachine.js`, `src/entities/`) |
| [Prashanna135/Souls-Like-Controller](https://github.com/Prashanna135/Souls-Like-Controller) | 39ca644 (2026-09-25) | permissive per README (no license file) | Godot 4: lock-on, dodge roll, combat state machines, boss health bar (`scripts/`) |
| [meta-quest/ProjectFlowerbed](https://github.com/meta-quest/ProjectFlowerbed) | 403a4f4 (2024-05-10) | `LICENSE` | Meta's open-source three.js WebXR game: Quest-browser structure, 72 Hz budget, teleport locomotion, three-mesh-ui/bvh |
| [meta-quest/webxr-first-steps](https://github.com/meta-quest/webxr-first-steps) | 49ecf80 (2026-09-21) | `LICENSE` | Meta's WebXR + three.js tutorial project: session setup, controllers, hands |
| [facebook/immersive-web-sdk](https://github.com/facebook/immersive-web-sdk) | 0778f51 (2026-10-01) | `LICENSE` | Meta's Immersive Web SDK: locomotion (`@iwsdk/locomotor`), interactions, IWER dev integration |
| [praydog/UEVR](https://github.com/praydog/UEVR) | 4ee5c6b (2026-08-29) | `LICENSE` | How the universal Unreal VR injector hooks stereo rendering (for native PC VR on Quest via Link) |
| [Junior37534/QuestBridge](https://github.com/Junior37534/QuestBridge) | 00ba562 (2026-05-27) | MIT | Quest controller -> WebXR page -> websocket -> game input bridge |
| [alesan99/mari0_ae](https://github.com/alesan99/mari0_ae) | c75ae92 (2026-02-21) | WTFPL | Mari0 (Mario x Portal-style) entities/enemies/power-ups in LOVE/Lua, reference for a Mario base |
| [Ciken-taste/forbidden-flesh](https://github.com/Ciken-taste/forbidden-flesh) | 99069cf (2025-09-07) | GPL-3.0 | Godot 4.2 souls-like prototype (~1.5k lines GDScript): stamina, dodge/roll, health, enemy AI (`Objects/Player/player.gd`, `Objects/DemoEnemy/`). No boss or parry found |
| [KonstantinKolo/RiftBreakers](https://github.com/KonstantinKolo/RiftBreakers) | 7f80fe1 (2026-03-23) | MIT | Godot 4.5 3D action game: melee, patrol/chase AI, stamina bar, boss scripts (`scripts/`). 1.7 GB with assets |
| [noidexe/top-down-action-rpg-template](https://github.com/noidexe/top-down-action-rpg-template) | 525d133 (2024-01-08) | MIT | Godot top-down ARPG template; author calls it a starting point, not a solid foundation |
| [Reterics/another-try](https://github.com/Reterics/another-try) | 2be7017 (2025-12-08) | GPL-3.0 | three.js + Vite + Socket.IO multiplayer RPG skeleton (procedural terrain, chunk streaming, netcode). No combat yet |
| [diasurgical/devilution](https://github.com/diasurgical/devilution) | 9f01757 (2025-09-15) | Sustainable Use (non-commercial only) | Reverse-engineered Diablo 1 source: `Source/items.cpp` (item/affix generation), `monster.cpp`, `missiles.cpp`, `spells.cpp`, `drlg_l1-l4.cpp` (dungeon generation), `quests.cpp`, `player.cpp`. Needs your own DIABDAT.MPQ to run |
| [diasurgical/devilutionX](https://github.com/diasurgical/devilutionX) | bf574c9 (2026-10-08) | Sustainable Use (non-commercial only) | Modern SDL port of Diablo/Hellfire: engine cleanups, multi-platform build, `mods/hf`, tests |
| [d07RiV/diabloweb](https://github.com/d07RiV/diabloweb) | c61ef19 (2022-05-17) | none found at repo root (verify before reuse) | Diablo 1 in the browser via WASM (built from the d07RiV/devilution fork); shareware `spawn.mpq` runs without your files, full game needs your own DIABDAT.MPQ uploaded locally |
| [flareteam/flare-engine](https://github.com/flareteam/flare-engine) | 1969bae (2026-10-04) | GPL-3.0 (`COPYING`) | C++/SDL2 2D Diablo-style action RPG engine with INI-style moddable data; has an Emscripten HTML5 build |
| [PathOfBuildingCommunity/PathOfBuilding](https://github.com/PathOfBuildingCommunity/PathOfBuilding) | 16de4b8 (2026-09-08) | MIT | PoE build planner (Lua): `src/TreeData` (passive tree), `src/Data` (gems, bases, bosses, mods), `src/Modules` (damage calc). 1.1 GB |

## Found, not pulled (verify before relying on)
- Curated lists: [bobeff/open-source-games](https://github.com/bobeff/open-source-games) (Xonotic, Cube 2, Red Eclipse, Liblast, Surreal Engine, OpenGOAL, SRB2, OpenMW, Veloren, SuperTuxKart, Zelda TP decomp...)
- GTA-style bases: OpenLiberty ([openfw-game](https://github.com/openfw-game), Godot, needs your GTA data), re3-gd, GTA7 (three.js vertical slice)
- Diablo 2 / PoE: OpenDiablo2 (Go, GPL-3.0, archived 2021; successor [AbyssEngine](https://github.com/AbyssEngine), not playable), PoESkillTree (C#), poe-optimizer, poe2-toolkit (MIT, TypeScript passive-tree extraction), BYTEPATH (MIT arcade shooter with a huge skill tree). No open-source PoE clone game found.
- Action-RPG candidates not pulled: Veloren (GPL-3.0, official source on GitLab), Loot Master (GPL-3.0, GitLab), OpenMW / Daggerfall Unity / OpenEnroth (engine remakes; large)
- Swing prototype: GabrielGameDev/SpiderMan2DWebSwing (Unity, 2D; linked from its itch.io page, unopened)
- No open-source repo found for: web-swing city traversal, Flick-It skating, colossus climbing.

## VR / Quest (Oculus)
- **WebXR in the Quest Browser (our path)**: our games are three.js, so VR is an "Enter VR" layer, not a port. Meta open-sourced [Project Flowerbed](https://github.com/meta-quest/ProjectFlowerbed) (three.js, three-mesh-ui/bvh, 72 Hz, teleport) and Above Par-adowski (three.js + A-Frame + PhysX WASM, 90 Hz) per [UploadVR](https://uploadvr.com/project-flowerbed-webxr-minigolf-open-source-demos/). Tutorial: meta-quest/webxr-first-steps. Framework: [facebook/immersive-web-sdk](https://github.com/facebook/immersive-web-sdk) + `@iwsdk/locomotor` (thumbstick/teleport locomotion).
- **PC VR injection (native games)**: UEVR injects VR into Unreal 4.8-5.4 games (community test: >90% of 255 games worked); it runs on a PC, not on the headset. Luke Ross has an Elden Ring VR mod.
- **QuestBridge** ([Junior37534/QuestBridge](https://github.com/Junior37534/QuestBridge), MIT, Fabric): a local WebXR page in the Quest Browser captures controller input and forwards it by websocket to Java Minecraft running on the headset (flat, not VR).
- **Testing without a headset**: Meta's IWER (`iwer`, MIT) emulates a Quest in any browser; verified here in headless Chromium (see `tools/test/xr-smoke.mjs`).
- Not found: any confirmed Quest passthrough mashup of Skyrim/Spider-Man; "Minecraft in Elden Ring" is the creator's own unreleased claim.
