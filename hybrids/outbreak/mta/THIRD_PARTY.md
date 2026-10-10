# THIRD_PARTY (MTA:SA adapter): code, data and fonts the MTA resource borrows from

Private, non-commercial build for the owner's own PC and server. Rules followed: `BORROW-RULES.md` (search first and port; MIT / BSD / Zlib / Apache-2.0 / CC0 may be copied with the notice kept;
LGPL / GPL / CC BY-SA allowed for this private build with a `borrowed:` mark in the code; nothing from commercial or reverse-engineered game dumps; names and art stay original).
Nothing here comes from game dumps, ripped assets or reverse-engineered code. One exception to the licence rule, by the owner's explicit decision (private fun project, risk accepted): code ported from two UNLICENSED repositories, kept apart in the section "PRIVATE USE ONLY (no licence upstream)" and marked `BORROWED-PRIVATE` in the code. Copyleft notes: GPL / LGPL material is touched only under the "private build" rule, so the owner re-cleans
(replace or relicense) before ever sharing the resource. This file is the MTA adapter's own; the sim, the FiveM adapter and the vanilla UI that this resource reuses are listed in
`../THIRD_PARTY.md` (that list applies here too: it covers `sim/`, `data/`, the shared host modules, the UI and the fonts).

Reference repositories were cloned (`git clone`, shallow or sparse) into `/home/user/<owner>/<repo>` and **read**; nothing was cloned into the project repository:

| Clone | Licence | Used as |
|---|---|---|
| `multitheftauto/mtasa-resources` (commit 11677963, 2026-09-30) | MIT, (c) 2008-2020 mtasa-resources contributors | code pattern + data read at test time |
| `rxi/json.lua` (commit dbf4b2dd) | MIT, (c) 2020 rxi | code (decode half) |
| `multitheftauto/mtasa-blue` (sparse: `Client|Server|Shared .../luadefs`, `Client|Server .../lua`, `CClientGame.cpp`, `CGame.cpp`; commit 46d8fb2c) | GPL-3.0 | **read only**: names of functions and events, Lua sandbox rules |
| `NullSystemWorks/mtadayz` (commit 954fa6b8) | custom: the authors keep the code; modification by collaborators allowed, distribution as your own forbidden | **ported for PRIVATE USE ONLY** (section below) |
| `mta-resources/deadwalkers` (commit 22c7d665) | none stated (all rights reserved) | **read for comparison only** (its `slothbot/` is an older copy of the same Slothbot code; its own gamemode has no zombie logic) |

Also fetched (not shipped): two raw `.cpp` files of mtasa-blue (`CPerPlayerEntity.cpp`, `CPlayerCamera.cpp`) from raw.githubusercontent.com for reading, and `lua-5.1.5.tar.gz` from lua.org (md5 checked) to build a
test interpreter, `tools/build_lua51.sh` (PUC-Rio Lua is MIT; the binary lives under `~/.cache`, not in the resource).

## Borrowed blocks (one row per block)

| # | Source repo | Path in source | Licence | Kind | Used for | Where in ours |
|---|---|---|---|---|---|---|
| 1 | rxi/json.lua | `json.lua` v0.1.2, the decode half (lines 141 to 388: `parse`, `parse_string`, `parse_number`, `parse_array`, `parse_object`, `codepoint_to_utf8`, error reporting) | MIT | port (changed) | decoding the JSON strings the browser page posts through `mta.triggerEvent`; changes: encode half removed, `max_len` / `max_depth` limits added (the text comes from a page), errors raised with `error` | `outbreak/shared/json_decode.lua` (notice kept in the file header) |
| 2 | multitheftauto/mtasa-resources | `[gameplay]/webbrowser/client.lua`, `WebBrowserGUI.lua` | MIT | pattern | the browser life cycle (`guiCreateBrowser` / `createBrowser`, wait for `onClientBrowserCreated`, `loadBrowserURL`, `onClientBrowserDocumentReady`), `showCursor` + `guiSetInputMode`, and the `isBrowserDomainBlocked` / `requestBrowserDomains` flow; re-done without its GUI window and OOP classes | `outbreak/client/ui.lua` `UI.create`, `load_page`, `UI.update_focus` |
| 3 | multitheftauto/mtasa-resources | `[gamemodes]/[race]/[addons]/race_ghost/playback_client.lua` (lines 162 to 199) and `playback_server.lua` (lines 131 to 138) | MIT | pattern | proof and shape of "server creates the ped, a client script sets its control states with `setPedControlState`, and clears every control name on reset" | `outbreak/client/driver.lua` `clear_controls` (written here over our own control list) |
| 4 | multitheftauto/mtasa-resources | `[editor]/editor_main/server/getObjectNameFromModel.lua` | MIT | data, **read at test time, not copied** | the table of SA object model id to name (14308 names) that every prop id in `shared/mta_config.lua` is checked against | `tests/config_test.lua` (path overridable with `MTA_RES_SRC`) |
| 5 | multitheftauto/mtasa-resources | `[gameplay]/freeroam/data/animations.xml` | MIT | data, **read at test time, not copied** | the list of animation blocks and names that every animation of the colonists is checked against (all 18 entries exist) | `tests/config_test.lua` |
| 6 | TitansProductions/TP-Advanced-Zombies | `tp-advancedzombies/config.lua` `Zombies.DistanceAttackData` (crouching 10, walking 35, sprinting 45) and `client/tp-client_main.lua` (distance by stance, chase, melee cadence); same blocks the FiveM adapter ported | Apache-2.0 | port (changed) | zombie perception radii and attack cadence; changes: decisions run on the MTA server and the chase is an intent for the client driver | `outbreak/server/zombies.lua`, numbers in `outbreak/shared/mta_config.lua` `peds.detect`, `attack_range`, `attack_cooldown_ms` |
| 7 | Blumlaut/RottenV | `client/spawners/zombiespawner.lua` (walker / runner / brute / screamer presets; corpses linger 5 to 15 s then are deleted; hearing range 65) | MIT | port (changed) | zombie kinds (health, damage, speed, detection multiplier) and corpse lifetime, as numbers | `outbreak/shared/mta_config.lua` `zombie_kinds`, `outbreak/server/peds.lua` corpse sweep, `server/zombies.lua` `hear` |
| 8 | overextended/ox_lib | `imports/raycast/client.lua` (rotation to forward-vector formula) | LGPL-3.0 | port, **via the FiveM adapter** | the camera ray maths for picking colonists under the cursor; reused byte-identically from the adapter | `outbreak/shared/raymath.lua` (copied by `tools/sync_shared.sh`), used by `client/camera.lua` |

Reused from this repository (own code, not third party): `sim/` and `data/` (`tools/sync_sim.sh`), `shared/{host,protocol,view,survival,util,json,raymath,placement}.lua` (`tools/sync_shared.sh`),
the vanilla NUI (`tools/sync_ui.sh`, byte-identical; fonts Inter and Barlow Condensed under the SIL OFL 1.1, licence files shipped in `outbreak/ui/fonts/`), `hybrids/outbreak/tests/tinytest.lua` (test harness).

## PRIVATE USE ONLY (no licence upstream)

**WARNING: the blocks below were ported from repositories that carry NO licence (mtadayz: "you are not allowed to replicate the code and distribute ... credits are not to be removed";
deadwalkers: nothing). The owner decided to accept that risk for a private, non-commercial build that runs only on the owner's own server and PC. NEVER share, publish or redistribute
the resource while any of these blocks is in it.** Credit: Slothman (Slothbot 2.7, the zombie AI that MTA DayZ ran on public servers) and the MTA DayZ authors (Marwin W., L, CiBeR96, 1B0Y).

Every block is wrapped in `-- BORROWED-PRIVATE (unlicensed upstream, private use only): <repo>/<path>` ... `-- END BORROWED-PRIVATE` in the code. `mta/tools/list_private_blocks.sh` lists them with file and
line numbers (`--check` exits 1 while any exists) and prints how to strip them. The tests pin the behaviour of each block (`tests/client_test.lua` driver tests, `tests/peds_test.lua`).
Where the same code is also in `mta-resources/deadwalkers/slothbot/` (an older copy: its `sbclient.lua` has the sprint lines commented out) the row says so.

| # | Source (repo/path, function) | What it is | Where in ours | Changes made |
|---|---|---|---|---|
| P1 | NullSystemWorks/mtadayz `slothbot/sbclient.lua` `chase_move`, `hunt_move` (also deadwalkers `slothbot/sbclient.lua`) | the facing angle `(360 - deg(atan2(dx, dy))) % 360` | `client/driver.lua` `heading` | none (a one-line formula) |
| P2 | mtadayz `slothbot/sbclient.lua` `Bforward`, `Bstop` (deadwalkers: same, sprint commented out) | movement = the `forwards` control plus `sprint`; stop releases them | `client/driver.lua` `move_controls`, `stop_moving` | `walk` modifier for speed 1 added |
| P3 | mtadayz `slothbot/sbclient.lua` `chase_move` | `isLineOfSightClear(px, py, pz+.6, tx, ty, tz+.6, true, false, false, true, false, false, false)`: which things block sight | `client/driver.lua` `in_sight` | none |
| P4 | mtadayz `slothbot/sbserver.lua` `chase_move` | how far a ped with a weapon of each SLOT walks before it stands and shoots (pistol 14, shotgun 10, submachine 7, assault 14, rifle 22, heavy 12, special 2) | `client/driver.lua` `STOP_BY_SLOT` | table only; used on the client |
| P5 | mtadayz `slothbot/sbclient.lua` `chase_shoot` | per weapon id: engagement distance, burst length (random 2000 to 5500 ms or fixed), pause after / cycle | `client/driver.lua` `WEAPONS`, `ranged_fire` | the broadcast through the server (`pedShootTrigger` -> `onGunShoot`) is dropped: the owner is the only client |
| P6 | mtadayz `slothbot/sbclient.lua` `meleeShoot`, `chase_shoot` | the melee swing: `fire` on at 0, 800, 1400 ms for 300 ms each, `forwards` released for 2000 ms, next swing after 2300 ms, reach 2 m | `client/driver.lua` `SWING`, `D.swing_state` and the melee branch of `drive_one` | timers replaced by a pure function of elapsed time (testable) |
| P7 | mtadayz `slothbot/sbserver.lua` `chase_move`, `hunt_move` | what a stuck ped (moved < 1 m / 1.2 m in 600 ms) does: seeing its target it jumps; otherwise `math.random(1, 7)`: 1 give up, 2 to 3 jump, 4 to 7 turn to a random angle and keep walking for 1.2 s (`1, 13` and 7 to 13 when walking a path) | `client/driver.lua` `D.stuck_decision`, `stuck_check` | runs on the client (where the positions are); limits scaled by 0.35 for walkers |
| P8 | mtadayz `slothbot/sbserver.lua` `chase_move` | with a melee (slot 1) or heavy (slot 7) weapon: `setPedWeaponSlot(ped, 0)`, jump, restore the slot after 850 ms; `bot_Jump` releases the jump control after 800 ms | `client/driver.lua` `jump`, `release_timers` | timers replaced by deadlines checked in the step |
| P9 | mtadayz `slothbot/sbclient.lua` `Streamin`, `sbserver.lua` `SetBotWeapon` ("StreamWeapon") | when a bot streams in: `setPedVoice(ped, "PED_TYPE_DISABLED", "")`, and the server gives its weapon again after 300 ms ("unstreamed peds lose all but 1 bullet") | `client/driver.lua` `D.on_stream_in`; `server/peds.lua` `give_weapon`, `restore_weapon`; `server/net.lua` the `outbreak:stream` handler | trust checks added (owner, `source == resourceRoot`, our ped); at most 5 re-gives per ped |
| P10 | mtadayz `slothbot/sbclient.lua` `aidamage`, `stopTeamDamage`; `sbserver.lua` `onBotFindEnemy` / `assigntarget` | a bot that gets hit turns on the shooter; `cancelEvent()` on damage between friendly bots | `client/driver.lua` `D.on_ped_damage`; `client/survival.lua` `on_damage`; `server/zombies.lua` `Z.on_hit`; `server/net.lua` the `outbreak:hit` handler | the sim stays authoritative: the zombie's fist damage is cancelled (the server scripts it), the hit is a validated request with a rate limit |
| P11 | mtadayz `slothbot/sbserver.lua` `assigncontroller` | the controller of a bot is its `getElementSyncer`, else the closest player; slothbot never calls `setElementSyncer` | `server/peds.lua` `assign_controller`, `assign_all`, `syncer_count` | element data `controller` not written (one client) |
| P12 | mtadayz `slothbot/sbserver.lua` `setBotChase`, `chase_move` | a chase has an ELEMENT as its target; the client faces it while it is in sight and runs to the last seen spot when not | `server/zombies.lua` `chase` (attack intent with `tgt`); `client/driver.lua` `drive_one` | per-ped timer chains replaced by one step loop; the target position is also sent as a hint |
| P13 | mtadayz `DayZ/tables/table_zombies.lua` `ZombiePedSkins` | the 26 SA skin ids MTA DayZ's zombies wear | `shared/mta_config.lua` `peds.zombie_models` (minus 56, which colonists wear) | data only |

What these ports are NOT: no DayZ gameplay code (loot, blood, jobs, login), no models / textures / sounds, no path-node system (`pathpoint` elements, `findPath`), no guard / follow / team modes of slothbot, no
`DayZ` damage numbers. Still ours: the intent protocol, the sim authority (counts, positions, damage, deaths), the caps (60 hostile, 96 total), persistence, the colony.

## Read only, nothing copied (and why)

| Source | What was learned | Why nothing was copied |
|---|---|---|
| `multitheftauto/mtasa-blue` (GPL-3.0) | **Names only**: which of 1289 client / 874 server / 90 shared Lua functions exist on which side, 136 / 97 built-in events, the Lua sandbox (`CLuaMain.cpp`: opened libraries, disabled globals), that `engineSetPoolCapacity` cannot resize the ped pool | GPL-3.0 and only names are needed; `tools/mta_defs.lua` re-reads the clone, it does not contain GPL text. Without the clone `function_check` says so and exits 2 |
| `NullSystemWorks/mtadayz` (also read, not ported) | the airfield coordinate list | one coordinate pair (`origin` 235.30, 2430.10, 16.85, Verdant Meadows airfield, **unverified**); a fact, not code |
| `mta-resources/deadwalkers` | its `slothbot/` is an older copy of Slothbot (compared with mtadayz's to see which lines are optional: the sprint toggles); the rest of the gamemode has no zombie logic | nothing copied from it that is not also in mtadayz |

## What could have been borrowed but was not

* **A ready-made zombie behaviour for MTA.** `mtadayz` (slothbot, DayZ zombies) and `deadwalkers` are exactly this shape. They carry no usable licence, so the first version of `client/driver.lua` and
  `server/zombies.lua` was written fresh; on the owner's decision (private use) the slothbot rules were then ported (section "PRIVATE USE ONLY"). Not ported even so: the path-node system, guard / follow / team modes,
  the DayZ loot / blood / job code (none of it fits a sim-driven colony).
* **`mtasa-resources/[editor]/freecam`** (MIT, `freecam.lua`): a free-flying camera. Not used: the colony camera is a top-down camera with a locked focus (pan / zoom / rotate by the page's keys and picking), which is the FiveM adapter's own `camera.lua` on MTA functions.
* **The whole `webbrowser` resource** (MIT): only its flow was taken (row 2); its window UI is irrelevant to a full-screen game page.
* **rxi/json.lua's encode half**: not needed, `shared/json.lua` (own code from the FiveM adapter) already encodes.
* **No MTA zombie, DayZ or ped-AI code exists in `mtasa-resources`** (searched for `zombie`, `setPedControlState`, `createPed`, `setPedAimTarget`: only the race_ghost playback, the stealth gadgets, `realdriveby` and the editor use them), so nothing else MIT / BSD was available for the ped brain.
* **Graphics mods** (ENB, ReShade, SilentPatch, SkyGfx, HD packs): none is bundled, see README section 8.

## Written from scratch for the MTA adapter

`bootstrap_mta.lua`, `server/*` (main, ctx, net, inject, peds, zombies (brain structure), raiders, colonists, buildings, props, world, ground, store, commands), `client/*` (main, ctx, ui, camera (on the adapter's structure), placement, noise,
survival, driver, ground, world, props, colonists_view), `shared/{mta_config,mta_net,selftest,selftest_data}.lua`, `ui/mta-bridge.js`, `tools/{mta_defs,function_check,gen_meta,gen_selftest}.lua`, the sync and build scripts,
and all of `tests/` (the mock MTA, the Playwright test, the replay). Names, art, icons and the colony rules are original.

## Licence notices

### rxi/json.lua: MIT License

Copyright (c) 2020 rxi

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject
to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH
THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

### multitheftauto/mtasa-resources: MIT License

Copyright (c) 2008-2020 mtasa-resources contributors. Same MIT terms as above (the file `LICENSE` of that repository). Changes: the browser flow and the control-state pattern were re-implemented
(rows 2 and 3); the editor model table and the animation list are read at test time and not redistributed.

### Blumlaut/RottenV: MIT License

Copyright (c) 2021 Blumlaut. Same MIT terms as above. Changes: the numbers (rows 7) were adapted to a sim-driven horde and MTA peds.

### TitansProductions/TP-Advanced-Zombies: Apache License 2.0

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at
http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License. The source LICENSE carries no named copyright holder.
Changes: the distances and cadence were re-implemented in `server/zombies.lua` (row 6); stated in that file's header.

### overextended/ox_lib: LGPL-3.0

The direction-vector formula reached this resource through `shared/raymath.lua` of the FiveM adapter (row 8), kept under the private-build rule; see `../THIRD_PARTY.md` row 8 for the exact block.

### multitheftauto/mtasa-blue: GPL-3.0

Read only. No text of it is included in this resource.

### Inter and Barlow Condensed: SIL Open Font License 1.1

Full text in `outbreak/ui/fonts/LICENSE-Inter-OFL.txt` and `LICENSE-BarlowCondensed-OFL.txt` (shipped with the resource).
