# THIRD_PARTY (MTA:SA adapter): code, data and fonts the MTA resource borrows from

Private, non-commercial build for the owner's own PC and server. Rules followed: `BORROW-RULES.md` (search first and port; MIT / BSD / Zlib / Apache-2.0 / CC0 may be copied with the notice kept;
LGPL / GPL / CC BY-SA allowed for this private build with a `borrowed:` mark in the code; nothing from commercial or reverse-engineered game dumps; names and art stay original).
Nothing here comes from game dumps, ripped assets or reverse-engineered code. Copyleft notes: GPL / LGPL material is touched only under the "private build" rule, so the owner re-cleans
(replace or relicense) before ever sharing the resource. This file is the MTA adapter's own; the sim, the FiveM adapter and the vanilla UI that this resource reuses are listed in
`../THIRD_PARTY.md` (that list applies here too: it covers `sim/`, `data/`, the shared host modules, the UI and the fonts).

Reference repositories were cloned (`git clone`, shallow or sparse) into `/home/user/<owner>/<repo>` and **read**; nothing was cloned into the project repository:

| Clone | Licence | Used as |
|---|---|---|
| `multitheftauto/mtasa-resources` (commit 11677963, 2026-09-30) | MIT, (c) 2008-2020 mtasa-resources contributors | code pattern + data read at test time |
| `rxi/json.lua` (commit dbf4b2dd) | MIT, (c) 2020 rxi | code (decode half) |
| `multitheftauto/mtasa-blue` (sparse: `Client|Server|Shared .../luadefs`, `Client|Server .../lua`, `CClientGame.cpp`, `CGame.cpp`; commit 46d8fb2c) | GPL-3.0 | **read only**: names of functions and events, Lua sandbox rules |
| `NullSystemWorks/mtadayz` (commit 954fa6b8) | custom, see below | **read only** (technique, facts) |
| `mta-resources/deadwalkers` (commit 22c7d665) | none stated (all rights reserved) | **read only** (technique) |

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

## Read only, nothing copied (and why)

| Source | What was learned | Why nothing was copied |
|---|---|---|
| `multitheftauto/mtasa-blue` (GPL-3.0) | **Names only**: which of 1289 client / 874 server / 90 shared Lua functions exist on which side, 136 / 97 built-in events, the Lua sandbox (`CLuaMain.cpp`: opened libraries, disabled globals), that `engineSetPoolCapacity` cannot resize the ped pool | GPL-3.0 and only names are needed; `tools/mta_defs.lua` re-reads the clone, it does not contain GPL text. Without the clone `function_check` says so and exits 2 |
| `NullSystemWorks/mtadayz` (custom: the authors keep the code and allow modification by "collaborators" but forbid replicating and distributing it) | the DayZ-style split "server decides, the syncer client executes" (slothbot), that zombies are ordinary peds with `setPedWalkingStyle` / `setPedAnimation`, an airfield coordinate list | the licence forbids redistributing the code. **Facts used** (not code): the idea; one coordinate pair (`origin` 235.30, 2430.10, 16.85, Verdant Meadows airfield, **unverified**); animation identifiers, all of which were then re-checked against the MIT freeroam animation list (row 5) |
| `mta-resources/deadwalkers` (no licence file) | the same technique from a second implementation | no licence means all rights reserved |

## What could have been borrowed but was not

* **A ready-made zombie behaviour for MTA.** `mtadayz` (slothbot, DayZ zombies) and `deadwalkers` are exactly this shape and would have been the fastest route to a working `client/driver.lua` and `server/zombies.lua`.
  Not usable: custom no-redistribution terms and no licence. `client/driver.lua` and `server/zombies.lua` are therefore written from the technique plus the MIT race_ghost pattern (row 3).
  If the owner accepts the private-use risk, those two files are the ones to replace first.
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
