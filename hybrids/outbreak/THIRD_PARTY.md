# THIRD_PARTY: code, data and fonts Outbreak borrows from

Private, non-commercial build for the owner's own PC (Rockstar mod guidelines: no Rockstar characters, story, voice lines or third-party IP; nothing here
comes from game dumps, ripped assets or reverse-engineered code). Copyleft notes: GPL-3.0 and LGPL-3.0 blocks are used under the "private build" rule
of BORROW-RULES.md; the owner re-cleans (replace or relicense) before ever sharing the resource. MIT / Apache-2.0 blocks keep their notices (bottom of
this file and the header comment next to each block).

Six libraries were cloned (shallow, `git clone`) into `/home/user/<owner>/<repo>` and read: RottenV, TP-Advanced-Zombies, 7_popmanager, ox_lib, ox_inventory,
fivem-rust-gamemode. Where a row says "pattern" the idea and layout are borrowed and the code is written here (the languages differ: React/TSX and
server-side Lua cannot be pasted into a vanilla NUI page); where it says "port" the Lua was adapted line by line (renamed, reorganised, our config/pool).

## Borrowed blocks (one row per block)

| # | Source repo | Path in source | Licence | Kind | Used for | Where in ours |
|---|---|---|---|---|---|---|
| 1 | Blumlaut/RottenV | `client/spawners/zombiespawner.lua` (ped setup, lines 525-575: `SetPedSeeingRange` 20/40, `SetPedHearingRange` 65, combat attributes 16/17/46/5, config flags 100/33, drunk `SetPedMovementClipset`, `ApplyPedDamagePack` x3 at 570-572, `SetPedDiesWhenInjured(false)`) | MIT (c) 2021 Blumlaut | port | zombie ped configuration recipe and the walker / runner / brute / screamer presets | `fivem/outbreak/client/zombies.lua` `configure()`, `KINDS`, `DAMAGE_PACKS` |
| 2 | Blumlaut/RottenV | `client/spawners/zombiespawner.lua` (lines 742-745: `Wait(math.random(5000,15000))` then `DeleteEntity`) | MIT | port | corpses linger a few seconds, then are deleted | `client/zombies.lua` `report_death`, `Z.dead`, `Z.sweep_dead` |
| 3 | Blumlaut/RottenV | `client/spawners/zombiespawner.lua` (lines 478-481: `AddRelationshipGroup("zombeez")`, `SetRelationshipBetweenGroups(5, ...)` against PLAYER) | MIT | port | hostile zombie relationship group | `client/relations.lua` `R.setup` |
| 4 | Blumlaut/RottenV | `client/gameplay/nopeds.lua` (lines 60-70: the per-frame `*DensityMultiplierThisFrame(0.0)` loop; scenario type switches) and `client/missions/power_c.lua` (`SetBlackout(not state)`) | MIT | port | ambient population off so the ped pool is ours; blackout during an outage | `client/world.lua` `W.frame`, `W.setup_population`, `ctx.on("set_power")` |
| 5 | TitansProductions/TP-Advanced-Zombies | `tp-advancedzombies/config.lua` `Zombies.DistanceAttackData` (Crouching 10, Walking, Sprinting 45) and `client/tp-client_main.lua` lines 95-115 (`StartHuntingPlayerOnDistance`: distance by stance, `TaskGoToEntity` chase) and 207-223 (stumble melee `misscarsteal4@actor` / `stumble`, re-issued chase) | Apache-2.0 | port (changed) | zombie perception, chase, attack cadence, per-kind health / damage | `client/zombies.lua` `detect_radius`, `nearest_target`, `chase`, `attack`; radii in `shared/config.lua` `Config.client.detect` |
| 6 | squarerootof49/7_popmanager | `client.lua` (scenario type list, `SetPedPopulationBudget`, `SetVehiclePopulationBudget`, `EnableDispatchService(1..15, false)`, `SetMaxWantedLevel`, restore block on resource stop) | GPL-3.0 | port | population / dispatch suppression and its exact restore on stop | `client/world.lua` `SCENARIOS`, `W.setup_population`, `W.restore_population`, `W.cleanup` |
| 7 | overextended/ox_lib | `imports/streamingRequest/client.lua`, `imports/requestModel/client.lua`, `imports/requestAnimDict/client.lua`, `imports/requestAnimSet/client.lua` | LGPL-3.0 | port | "request, poll `HasXLoaded` with a timeout, invalid-model check" streaming helpers, without the `lib` table | `client/pool.lua` `wait_loaded`, `Pool.request_model`, `Pool.request_anim_dict`, `Pool.request_anim_set` |
| 8 | overextended/ox_lib | `imports/raycast/client.lua` | LGPL-3.0 | port | `StartShapeTestLosProbe` then poll `GetShapeTestResult` each frame; rotation to forward-vector formula | `client/camera.lua` `Cam.ground_at`; `shared/raymath.lua` `M.basis` |
| 9 | overextended/ox_lib | `web/src/features/notifications/NotificationWrapper.tsx` (+ theme) | LGPL-3.0 | pattern | toast layout: icon chip, title / description, stacked at an edge, auto-dismiss with a progress rule | `fivem/outbreak/ui/js/toasts.js`, `.toast` rules in `ui/css/screens.css` |
| 10 | overextended/ox_inventory | `web/src/components/inventory/{InventoryGrid,InventorySlot,InventoryControl,SlotTooltip,LeftInventory,RightInventory}.tsx` | GPL-3.0 | pattern | square-slot grid (6 columns), weight header meter, count top-right and label bar at the bottom of a slot, drop target highlight, drag preview, hover-delay tooltip, ctrl = one / shift = half / double-click = use, right-click menu | `ui/js/inventory.js`, inventory rules in `ui/css/screens.css` |
| 11 | Paradigm-MP/fivem-rust-gamemode | `inventory/src/js/SurvivalHUD.js` | GPL-3.0 | pattern | survival HUD content and grouping (vitals cluster, status chips, weight bar); re-done as radial gauges | `ui/js/hud.js`, `ui/css/hud.css` |
| 12 | wasmoon 1.16.0 (npm, by Gabriel Francisco) | built files `dist/index.js` and `dist/glue.wasm` | MIT | vendored build | Lua 5.4 compiled to WebAssembly: runs the real sim in the browser preview, offline | `preview/vendor/wasmoon.js`, `preview/vendor/glue.wasm`, licence `preview/vendor/wasmoon.LICENSE` |
| 13 | @fontsource/inter (Inter, rsms) | latin 400/500/600/700 woff2 | SIL OFL 1.1 | vendored font | UI text | `ui/fonts/inter-latin-*.woff2`, licence `ui/fonts/LICENSE-Inter-OFL.txt` |
| 14 | @fontsource/barlow-condensed (Barlow, jpt) | latin 500/600/700 woff2 | SIL OFL 1.1 | vendored font | display numerals and headings | `ui/fonts/barlow-condensed-latin-*.woff2`, licence `ui/fonts/LICENSE-BarlowCondensed-OFL.txt` |
| 15 | citizenfx/fivem | `ext/natives/natives_stash/gta_universal.lua`, `ext/native-decls/**/*.md`, `data/shared/citizen/scripting/lua/scheduler.lua` (read at test time, not copied or redistributed); `codegen_out_lua.lua` name rule (SNAKE_CASE to PascalCase, 1 line re-implemented) | Rockstar Games Creator Platform licence / mixed (see that repo's LICENSE) | data source, read only | the list of real natives and which side (client / server) each exists on | `fivem/tools/native_check.lua` (the repo is read through `FIVEM_SRC`, default `/home/user/citizenfx/fivem`) |
| 16 | this repo (own code) | `hybrids/outbreak/tests/tinytest.lua`, `tests/hash_check.lua` | repo-own | reuse | test harness and the cross-runtime hash runs | `fivem/tests/run.lua` requires `tinytest`; `preview/glue.lua` `P_hash_runs` mirrors `hash_check.lua` |

Not borrowed (so nothing to list): no code or art from RimWorld, Project Zomboid or any Rockstar content. Colony-manager rules, the Director, UI art, the 85
inline-SVG icons, item / blueprint / event names are original. The data-visualisation palette (blue #3987e5, orange #d95926, aqua #199e70) comes from the
dataviz skill's validated reference palette (a colour list, not code).

## What the six libraries were considered for and not used

| Candidate | Why it was not used |
|---|---|
| ox_lib `lib.zones` / `lib.points` | the sim already owns all spatial state; client points are not needed |
| ox_lib `lib.callback`, `lib.cron` | the adapter uses plain net events and `Wait` loops; one fewer dependency |
| ox_inventory server / hotbar / crafting / shops | its item model is its own (slots, metadata, SQL); our inventory is the sim's container model, so only the UI pattern fits |
| ox_inventory React/TS source | the UI is vanilla JS with no build step and no CDN (a NUI page that must run offline), so patterns were re-implemented |
| RottenV needs / hunger / temperature | the survival body reuses the sim's own `needs` rules (`shared/survival.lua`), which are tested under both runtimes; RottenV's are tied to its SQL profile |
| RottenV zombie spawner / population logic | spawning is decided by the sim (`spawn_horde`, `max_materialized`), so only the ped recipe was taken |
| TP-Advanced-Zombies zones / traffic adjuster / statistics | not applicable to a sim-driven horde |
| 7_popmanager `SetPedNonCreationArea` / `AddScenarioBlockingArea` | needs map coordinates that are unverified here (see README); the scenario and density switches do the job without them |
| fivem-rust-gamemode inventory React code | same reason as ox_inventory; only the HUD content was a reference |

## Licence notices (MIT and Apache-2.0 blocks above)

### Blumlaut/RottenV: MIT License

Copyright (c) 2021 Blumlaut

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

### TitansProductions/TP-Advanced-Zombies: Apache License 2.0

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the
License at http://www.apache.org/licenses/LICENSE-2.0. Unless required by applicable law or agreed to in writing, software distributed under the License is
distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing
permissions and limitations under the License. The source LICENSE carries no named copyright holder (the template line is unfilled). Changes: the borrowed ideas
and numbers were re-implemented in `client/zombies.lua` for a sim-driven horde model; this is stated in that file's header.

### wasmoon: MIT License

Copyright (c) 2023 Gabriel Francisco. The licence text is `preview/vendor/wasmoon.LICENSE` (same MIT terms as above). wasmoon embeds the Lua 5.4 interpreter
(MIT, PUC-Rio), compiled to WebAssembly.

### Inter and Barlow Condensed: SIL Open Font License 1.1

Full text in `fivem/outbreak/ui/fonts/LICENSE-Inter-OFL.txt` and `LICENSE-BarlowCondensed-OFL.txt`.
