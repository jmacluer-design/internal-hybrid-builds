# Research sources (reference only, private use)

Shallow clones live OUTSIDE this repo (never committed). Re-pull with e.g.
`GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 https://github.com/<owner>/<repo> /home/user/<owner>/<repo>`

| Repo | Commit | License | What we mine it for |
|---|---|---|---|
| [n64decomp/sm64](https://github.com/n64decomp/sm64) | 9921382 (2023-08-17) | `LICENSE.md` (decompilation; assets come from your own ROM) | `src/game/mario_actions_moving.c`, `mario_actions_airborne.c`, `mario_step.c`, `camera.c`: the real SM64 movement constants and state machine |
| [sm64js/sm64js](https://github.com/sm64js/sm64js) | 04c1a98 (2025-02-02) | WTFPL | `src/game/Mario*.js`, `Camera.js`: the same movement as readable JavaScript (easiest to port into the browser heroes) |
| [mohsenheydari/three-fps](https://github.com/mohsenheydari/three-fps) | 625a18c (2022-05-22) | `LICENSE` (MIT per its README) | three.js + ammo.js FPS: entity-component layout, FPS controller, NPC state machine (`src/FiniteStateMachine.js`, `src/entities/`) |
| [Prashanna135/Souls-Like-Controller](https://github.com/Prashanna135/Souls-Like-Controller) | 39ca644 (2026-09-25) | permissive per README (no license file) | Godot 4: lock-on, dodge roll, combat state machines, boss health bar (`scripts/`) |

## Found, not pulled (verify before relying on)
- Mari0 mod: [alesan99/mari0_ae](https://github.com/alesan99/mari0_ae) (WTFPL, LÖVE, no longer developed)
- Curated lists: [bobeff/open-source-games](https://github.com/bobeff/open-source-games) (Xonotic, Cube 2, Red Eclipse, Liblast, Surreal Engine, OpenGOAL, SRB2, OpenMW, Veloren, SuperTuxKart, Zelda TP decomp...)
- GTA-style bases: OpenLiberty ([openfw-game](https://github.com/openfw-game), Godot, needs your GTA data), re3-gd, GTA7 (three.js vertical slice)
- Swing prototype: GabrielGameDev/SpiderMan2DWebSwing (Unity, 2D; linked from its itch.io page, unopened)
- No open-source repo found for: web-swing city traversal, Flick-It skating, colossus climbing.

## VR / Quest (Oculus)
- **WebXR in the Quest Browser (our path)**: our games are three.js, so VR is an "Enter VR" layer, not a port. Meta open-sourced [Project Flowerbed](https://github.com/meta-quest/ProjectFlowerbed) (three.js, three-mesh-ui/bvh, 72 Hz, teleport) and Above Par-adowski (three.js + A-Frame + PhysX WASM, 90 Hz) per [UploadVR](https://uploadvr.com/project-flowerbed-webxr-minigolf-open-source-demos/). Tutorial: meta-quest/webxr-first-steps. Framework: [facebook/immersive-web-sdk](https://github.com/facebook/immersive-web-sdk) + `@iwsdk/locomotor` (thumbstick/teleport locomotion).
- **PC VR injection (native games)**: UEVR injects VR into Unreal 4.8-5.4 games (community test: >90% of 255 games worked); it runs on a PC, not on the headset. Luke Ross has an Elden Ring VR mod.
- **QuestBridge** ([Junior37534/QuestBridge](https://github.com/Junior37534/QuestBridge), MIT, Fabric): a local WebXR page in the Quest Browser captures controller input and forwards it by websocket to Java Minecraft running on the headset (flat, not VR).
- **Testing without a headset**: Meta's IWER (`iwer`, MIT) emulates a Quest in any browser; verified here in headless Chromium (see `tools/test/xr-smoke.mjs`).
- Not found: any confirmed Quest passthrough mashup of Skyrim/Spider-Man; "Minecraft in Elden Ring" is the creator's own unreleased claim.
