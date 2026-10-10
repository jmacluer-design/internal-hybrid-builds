# Outbreak: FiveM resource (pass 2)

Zombie survival + overhead colony manager for a private, local FiveM server. The simulation (`outbreak/sim`, `outbreak/data`) is the pure-Lua core from pass 1;
this folder is the GTA adapter around it, its NUI, and the test benches.

> **Status, stated plainly.** Nothing in here has ever run inside GTA V or FiveM. The game-facing Lua (`outbreak/server`, `outbreak/client`) was written blind against
> the public native docs and the FiveM source in `/home/user/citizenfx/fivem`, and tested only against a mock FiveM (`tests/mock.lua`). The NUI was tested in
> headless Chromium against the real sim running in WebAssembly (`../preview`). Section "What the mocks cannot prove" lists what only your PC can settle.

## Folder map

| Path | What |
|---|---|
| `outbreak/` | the resource: `fxmanifest.lua`, `shared/` (host core, protocol, view models, config, placement and ray maths), `server/main.lua`, `client/*.lua`, `ui/` (NUI), `sim/` + `data/` (byte-identical copies of the sim core, see below) |
| `tools/native_check.lua` | verifies every native the Lua calls against the FiveM native definitions, per side |
| `tools/sync_sim.sh` | copies `../sim` and `../data` into the resource (`sync_sim.sh check` verifies they are identical) |
| `tests/` | mock-FiveM harness and the adapter tests (`run.sh` runs both runtimes) |
| `../preview/` | browser bench: real sim in wasmoon + the real NUI page (see its own header comments) |
| `../THIRD_PARTY.md` | every borrowed block with source, licence, and where it lives |
| `../screenshots/` | scripted screenshots of the NUI (preview, not GTA) |

## Install on the host PC (Windows, GTA V + FiveM, local only)

1. Install GTA V on the PC (the open question below: Legacy or Enhanced) and the FiveM client from fivem.net; start FiveM once so it finishes its setup.
2. Download a recent FXServer ("server" artifacts for Windows) from https://runtime.fivem.net/artifacts/fivem/build_server_windows/master/ and unzip it, for example to `C:\fx\server`.
3. Get the stock server data (the `cfx-server-data` repo: `mapmanager`, `spawnmanager`, `chat`, `sessionmanager`, `basic-gamemode`, ...) into `C:\fx\server-data` (resources go in `C:\fx\server-data\resources`).
4. Copy the folder `fivem/outbreak` (the WHOLE folder, including `sim/`, `data/`, `ui/`) to `C:\fx\server-data\resources\[local]\outbreak`. If you changed the sim, run `sh fivem/tools/sync_sim.sh` first.
5. `server.cfg` (a minimum; `sv_licenseKey` is the free key from https://portal.cfx.re, whether it is required together with `sv_lan 1` is one of the open questions):
   ```
   endpoint_add_tcp "127.0.0.1:30120"
   endpoint_add_udp "127.0.0.1:30120"
   sv_lan 1
   sv_hostname "Outbreak (local)"
   sv_maxclients 2
   sv_licenseKey "YOUR_KEY"
   set sv_scriptHookAllowed 0

   ensure mapmanager
   ensure chat
   ensure spawnmanager
   ensure sessionmanager
   ensure basic-gamemode
   ensure hardcap

   # Outbreak (all optional; defaults in outbreak/shared/config.lua)
   setr outbreak_origin "1850.0,3700.0,34.0"
   set outbreak_profile "escalating"
   set outbreak_colonists 4
   ensure outbreak
   ```
6. Start `FXServer.exe +exec server.cfg`, then in the FiveM client press F8 and `connect 127.0.0.1:30120`. The first client to load becomes the colony owner.
7. Press **F6** (colony view) once you stand on the ground. If anything misbehaves: server console `outbreak_status`, client console (F8) `outbreak_client`, and `set outbreak_debug 1`.

## Convars (server.cfg)

| Convar | Default | Meaning |
|---|---|---|
| `outbreak_seed` | 0 | world seed (0 = from the clock; a saved game ignores it) |
| `outbreak_profile` | escalating | Director pacing: calm, escalating, chaos |
| `outbreak_colonists` | 4 | starting colonists (1-12) |
| `outbreak_timescale` | 30 | game seconds per real second at speed 1 (30 = one game minute per 2 s, GTA's own clock); speed 2/4/8/16 multiply it |
| `outbreak_tick_ms` | 500 | real ms between host updates (fixed-step accumulator, catch-up capped at 30 sim minutes per update) |
| `outbreak_autoload` / `outbreak_autosave` | 1 / 120 | load the latest save on start / autosave every N real seconds (0 = off) |
| `outbreak_owner_admin` | 1 | the colony owner may use the `/outbreak_*` commands and the NUI debug actions |
| `outbreak_debug` | 0 | extra logging, payload checks, debug actions for the owner |
| `outbreak_max_peds` | 48 | hard ceiling of peds this resource owns (zombies + raiders + colonists + traders) |
| `outbreak_pool_guard` | 150 | refuse to create a ped while the game's CPed pool holds this many (UNVERIFIED pool size, see below) |
| `outbreak_max_objects` | 400 | ceiling for props (blueprint ghosts, buildings, crates) |
| `outbreak_origin` | 1850,3700,34 | where the sim origin (the base centre) sits on the GTA map; use `setr` or `set` (UNVERIFIED default: open ground near Sandy Shores) |

Admin commands (server console, a player with ace `outbreak.admin`, or the owner while `outbreak_owner_admin` is 1): `/outbreak_status`, `_save`, `_load`, `_new [seed] [profile]`,
`_pause`, `_speed 0|1|2|4|8|16`, `_profile`, `_horde [size] [distance]`, `_event <id>`, `_give <item> [n]`, `_day <hour> [min] [day]`, `_autopilot on|off`, `_ff <minutes>`, `_hash`, `_audit`.
Client: `/outbreak_client` prints ped / object counts and caps. Saves live in the resource KVP (two rotating slots + a pointer, checksummed, versioned).

## Keybinds

Registered with `RegisterKeyMapping` (rebindable in the FiveM key-binding settings): **F6** colony view on / off, **I** inventory, **E** open the nearest pile / drop.
In colony view the NUI page owns the keyboard and the mouse (NUI focus): W A S D / arrows pan (Shift = faster), Q E rotate, wheel zooms, screen edge pans, left click selects,
drag box-selects, right click gives a move order, **B** build, **Z** stock zones, **L** Director, **C** colonist card, **P** priorities grid, **M** tactical map, **R** draft, **Space** pause,
**1-4** speed 1x/2x/4x/8x, **. ,** next / previous colonist, **Ctrl+A** select all, **Esc** menu. All of it is in the in-game Controls tab.

## How it fits together

* **Server** (`server/main.lua` + `shared/host.lua`) owns the sim, runs the fixed-step clock, batches OUT events to the owner (msgpack-safe plain tables), validates every IN event
  and order (`shared/protocol.lua`; token bucket, whitelist, clamps), serves UI view models (`shared/view.lua`) and persists. `shared/host.lua` never calls a native: the same file also
  runs in the browser preview and in the mock harness.
* **Client** (`client/`): `pool.lua` is the only place that creates entities (caps, pool guard, streaming timeouts, release on stop); `zombies.lua`, `raiders.lua`, `colonists.lua`, `props.lua`
  materialize what the sim says; `noise.lua` turns gunshots / explosions / sirens / sprinting / melee into `noise` events; `camera.lua` + `build.lua` are the colony camera and blueprint placement;
  `world.lua` suppresses ambient population and syncs clock, weather and blackout; every module registers a cleanup so `onResourceStop` leaves nothing behind.
* **Sim time is authoritative.** Peds animate the sim's `colonist_task` positions and are snapped to them when they lag (`Config.client.snap_*`, scaled by the time scale); the sim never waits for a ped.
* **Single owner.** All peds are local (`isNetwork = false`): only the owner's client sees them. Other clients get `hello{owner=false}` and nothing else.
* Contract notes found while building the adapter: the sim emits no event when a blueprint is cancelled or a ground pile appears / empties, so the host synthesizes `building_destroyed{cancelled=true}`
  and `piles_sync{piles}` (props follow them). Both are in `shared/host.lua`.

## Verification, honestly

Run everything: `sh fivem/tests/run.sh` (add `--with-sim` for the sim's own suite) and, for the browser side, `node preview/tests/ui_test.mjs`, `node preview/tests/hash_test.mjs`.

| Claim | Evidence | Status |
|---|---|---|
| every native used exists, on the side that calls it | `tools/native_check.lua` over `gta_universal.lua`, `native-decls/**`, `scheduler.lua`: 163 distinct natives, exit 0 (and its own tests prove it FAILS on an unknown or wrong-side native) | verified against the docs, not against the game |
| the resource's Lua runs identically under Lua 5.4 and LuaJIT | `tests/run.lua` under both: 129 tests, 2711 assertions each | verified (mock) |
| sim copies in the resource are the canonical files | `tools/sync_sim.sh check` | verified |
| browser sim == native sim | `preview/tests/hash_test.mjs`: wasmoon, lua5.4 and luajit print byte-identical hashes for 4 colonies x 30 days | verified |
| NUI behaves | `preview/tests/ui_test.mjs`: 124 checks (priority click -> order, keyboard, build flow, JS placement rule == sim on 500 random placements, inventory drag, Director, no console errors, no overflow at 1080p / 1440p / 4K, UI update cost at 30 colonists median 0.5-1.4 ms, p95 under 4 ms) | verified in Chromium; CEF in FiveM not tested |
| adapter against FiveM natives | mock only | **unverified** |

### What the mocks cannot prove (only the PC can)

`tests/mock.lua` + `mock_natives.lua` prove sequencing, bookkeeping, caps, cleanup, protocol and payload safety: call order, streaming before creation (the mock throws if a model is used before it loaded),
stale-handle use (counted), leak-free stop (peds, props, blips, cameras, relationship groups, population / clock / weather / blackout / NUI focus restored, threads end), order round trips,
save / load / resync, failure injection (missing models, slow streaming, failing `CreatePed`, no ground, hostile events), and a native-calls-per-frame budget (about 65 per frame with 46 peds).
They do NOT prove that the real natives behave as the mock does: pathfinding and `TaskGoToCoordAnyMeans` over real terrain, collision / ground probing, streaming times, animation and scenario names,
model availability, ragdoll, relationship-group AI, ped pool size, camera feel, NUI focus and mouse semantics, the shape-test flags, `SetBlackout` / lights, how FiveM's weather and time sync interact with
`SetWeatherTypeNowPersist` and `NetworkOverrideClockTime`, and CEF's CSS / JS support (the UI avoids anything newer than about Chrome 99; `roundRect` has a fallback).

### Known unverified assumptions (each is a one-line fix in `shared/config.lua` or the named file)

1. **Origin** `1850, 3700, 34` is open ground near Sandy Shores: not checked for flatness or obstacles (`outbreak_origin`).
2. **Ped pool size**: `pool_guard 150` and `max_peds 48` are guesses from forum anecdotes; the object ceiling (about 1500 script objects) likewise.
3. **Model names** (zombies, colonists, gang peds, every prop in `Config.client` / `Config.props`) come from public lists; the client skips any that `IsModelInCdimage` rejects and falls back to a crate prop.
4. **Scenario, animation and clipset names** (`WORLD_HUMAN_*`, `anim@heists@box_carry@`, `misscarsteal4@actor`, `move_m@drunk@*`) and **weapon-group hashes** in `client/noise.lua`.
5. **Alert sound names** in `client/world.lua` (a wrong name is simply silent).
6. `SetEntityDrawOutline` (placement ghost tint), `SetFocusArea` (stream under the camera), `GetScreenCoordFromWorldCoord` (box select) and `StartShapeTestLosProbe` flags `(1, 0, 4)` (ground pick).
7. `SetBlackout` dims the whole world; the base's own light comes from `DrawLightWithRange` on lamp props.
8. Non-networked peds (`isNetwork=false`) are never migrated or culled by the engine's own cleanup (`SetEntityAsMissionEntity` is set).
9. **Natives that were missing in this snapshot** and replaced: `SetArtificialLightsState` (-> `SetBlackout`), `SetFocusPosAndVel` (-> `SetFocusArea`). `GetPedSourceOfDamage` is server-only, so colonist damage kinds are guessed by proximity.
10. A second player is not supported (single-owner colony); `sv_maxclients 2` only lets a spectator connect.

### Open questions for the PC (from PLAN.md, plus what this pass added)

* Does the FiveM client need a Cfx.re login / internet / Rockstar launcher login with `sv_lan`? Does FXServer start without `sv_licenseKey` when `sv_lan 1`?
* GTA V Legacy ped pool size under FiveM (forum anecdote only) and the object budget.
* Whether any Rockstar account action applies to local-only FiveM use.
* Is GTA V owned on PC, and is it Legacy or Enhanced? (FiveM runs on Legacy; this resource assumes it.)
* New: do the origin, model, scenario and animation lists above work? (run `/outbreak_horde 20 120`, `/outbreak_give pistol`, press F6: peds appear, ghosts are translucent, WASD pans.)
* New: does `NetworkOverrideClockTime` fight another resource's time sync (cfx `weather` / `vSync` style resources must NOT be running)?

## Natives used (163, exact; all verified present by `tools/native_check.lua`)

Client and server runtime / CFX natives: `DeleteResourceKvp`, `GetConvar`, `GetCurrentResourceName`, `GetGamePool`, `GetResourceKvpString`, `IsPlayerAceAllowed`, `LoadResourceFile`, `RegisterCommand`, `RegisterKeyMapping`,
`SetEntityDrawOutline`, `SetEntityDrawOutlineColor`, `SetMillisecondsPerGameMinute`, `SetNuiFocus`, `SetResourceKvp`. All others are GTA natives from `gta_universal.lua`:

AddBlipForCoord, AddRelationshipGroup, AddTextComponentSubstringPlayerName, ApplyPedDamagePack, AttachEntityToEntity, BeginTextCommandSetBlipName, ClearEntityLastDamageEntity, ClearFocus,
ClearPedBloodDamage, ClearPedTasks, ClearWeatherTypePersist, CreateCam, CreateObjectNoOffset, CreatePed, DeleteEntity, DestroyCam, DetachEntity, DisablePedPainAudio, DoesAnimDictExist, DoesEntityExist,
DrawLightWithRange, DrawMarker, EnableDispatchService, EndTextCommandSetBlipName, FreezeEntityPosition, GetAspectRatio, GetCurrentPedWeapon, GetEntityCoords, GetEntityHealth, GetEntitySpeed, GetFrameTime,
GetGameTimer, GetGameplayCamRot, GetGroundZFor_3dCoord, GetHashKey, GetPedBoneIndex, GetPedSourceOfDeath, GetPedStealthMovement, GetScreenCoordFromWorldCoord, GetShapeTestResult, GetVehiclePedIsIn,
GetWeapontypeGroup, GiveWeaponToPed, HasAnimDictLoaded, HasAnimSetLoaded, HasEntityBeenDamagedByAnyPed, HasModelLoaded, HideHudAndRadarThisFrame, IsEntityDead, IsExplosionInSphere, IsHornActive,
IsModelInCdimage, IsModelValid, IsPedCurrentWeaponSilenced, IsPedDeadOrDying, IsPedDucking, IsPedFalling, IsPedInAnyVehicle, IsPedInMeleeCombat, IsPedRagdoll, IsPedShooting, IsPedSprinting,
IsVehicleSirenOn, NetworkClearClockTimeOverride, NetworkOverrideClockTime, NetworkResurrectLocalPlayer, PauseClock, PlaceObjectOnGroundProperly, PlaySoundFrontend, PlayerId, PlayerPedId, RemoveBlip,
RemoveRelationshipGroup, RenderScriptCams, RequestAnimDict, RequestAnimSet, RequestCollisionAtCoord, RequestModel, ResetEntityAlpha, SetBlackout, SetBlipAsShortRange, SetBlipColour, SetBlipScale,
SetBlipSprite, SetBlockingOfNonTemporaryEvents, SetCamActive, SetCamCoord, SetCamFov, SetCamRot, SetCreateRandomCops, SetCreateRandomCopsNotOnScenarios, SetCreateRandomCopsOnScenarios,
SetCurrentPedWeapon, SetDispatchCopsForPlayer, SetEntityAlpha, SetEntityAsMissionEntity, SetEntityCollision, SetEntityCoordsNoOffset, SetEntityHealth, SetEntityInvincible, SetEntityMaxHealth,
SetFocusArea, SetGarbageTrucks, SetMaxWantedLevel, SetModelAsNoLongerNeeded, SetNumberOfParkedVehicles, SetParkedVehicleDensityMultiplierThisFrame, SetPedAccuracy, SetPedAlertness,
SetPedCombatAttributes, SetPedCombatMovement, SetPedCombatRange, SetPedConfigFlag, SetPedDensityMultiplierThisFrame, SetPedDiesWhenInjured, SetPedDropsWeaponsWhenDead, SetPedFleeAttributes,
SetPedHearingRange, SetPedKeepTask, SetPedMaxHealth, SetPedMoveRateOverride, SetPedMovementClipset, SetPedPopulationBudget, SetPedRagdollBlockingFlags, SetPedRelationshipGroupHash, SetPedSeeingRange,
SetPedSuffersCriticalHits, SetPedToRagdoll, SetPlayerHealthRechargeMultiplier, SetPlayerSprint, SetRandomBoats, SetRandomTrains, SetRandomVehicleDensityMultiplierThisFrame,
SetRelationshipBetweenGroups, SetScenarioPedDensityMultiplierThisFrame, SetScenarioTypeEnabled, SetVehicleDensityMultiplierThisFrame, SetVehiclePopulationBudget, SetWeatherTypeNowPersist,
ShakeGameplayCam, StartShapeTestLosProbe, StopPedSpeaking, TaskCombatHatedTargetsAroundPed, TaskGoToCoordAnyMeans, TaskGoToEntity, TaskPlayAnim, TaskSmartFleePed, TaskStartScenarioInPlace,
TaskWanderStandard.

Runtime globals (not natives): `Wait`, `CreateThread`, `SetTimeout`, `AddEventHandler`, `RegisterNetEvent`, `TriggerEvent`, `TriggerServerEvent`, `TriggerClientEvent`, `SendNUIMessage`, `RegisterNUICallback`, `json`, `print`.

## NUI and the preview

`outbreak/ui/` is vanilla HTML / CSS / JS (no CDN, fonts vendored; layout in rem so it scales from 1080p to 4K; dark glass). Screens: survival HUD, inventory grid, colony view (top bar, roster, card,
tactical map, minimap), work priorities grid (click cycles 0-4, right click back, digits, arrows), build menu with placement, stockpile zones, expeditions, Director log + threat meter, toasts,
pause / settings / controls, collapse summary. The page talks to Lua with `SendNUIMessage` (boot, catalog, state, hud, compass, events, mode, screen, selection, inventory, toast, place, settings, summary)
and NUI callbacks (ready, order, ui, mode, mouse, key, place, focus, screen, close).
`../preview/index.html` (serve `hybrids/outbreak/` with any static server, for example `cd hybrids/outbreak && python3 -m http.server 8000`, and open `http://127.0.0.1:8000/preview/`; a `file://` open is not supported because the wasm module is fetched) runs the real host in wasmoon and the real page:
play / pause / speed, profile picker, seed, spawn horde, trigger event, give item, autopilot, fast-forward. It is labelled "Preview, no GTA" and is a UI bench, not the game.
Screenshots: `node preview/tools/shots.mjs <dir>` (8 required scenes at 1920x1080 and 2560x1440; the committed PNGs in `../screenshots/` are quantised to 5-6 bits per channel to stay under 400 KB).
