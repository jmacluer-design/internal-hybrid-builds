# Outbreak for MTA:SA (private build)

Zombie survival plus colony manager for **Multi Theft Auto: San Andreas**, on the same pure-Lua sim, protocol and vanilla NUI as the finished FiveM adapter
(`../fivem/`). Private, non-commercial, for your own PC and your own server.

> **Status, said plainly: this resource has never run inside a real MTA client or server.** It was written against the MTA wiki and the real MTA source
> (function and event lists, Lua sandbox rules), and tested against a mock MTA plus real Chromium, real Lua 5.1.5, LuaJIT and Lua 5.4. Section 10 is the list of things
> only your PC can settle. Expect a first-run session of fixing, not a first-run finished game.

Contents: 1 [What was found out about MTA](#1-what-was-found-out-about-mta-and-changes-the-design) / 2 [Install](#2-install) / 3 [Tailscale](#3-tailscale) / 4 [Controls](#4-controls)
/ 5 [Settings](#5-settings) / 6 [Commands and ACL](#6-commands-and-acl) / 7 [How it works](#7-how-it-works) / 8 [Graphics](#8-graphics) / 9 [Tests](#9-tests-and-what-the-mocks-cannot-prove)
/ 10 [Unverified until it runs in the game](#10-unverified-until-it-runs-in-the-real-game) / 11 [Every MTA function used](#11-every-mta-function-used) / 12 [Deviations](#12-deviations-from-the-brief)
/ 13 [Debugging](#13-debugging-and-troubleshooting) / 14 [Licences](#14-licences)

## 1. What was found out about MTA (and changes the design)

**MTA's server cannot steer a ped.** The brief assumed the server could walk, turn and shoot peds (`setPedControlState`, `setPedAimTarget`, ...). The real source
(`multitheftauto/mtasa-blue`, `Server/.../luadefs` versus `Client/.../luadefs`, read by `tools/mta_defs.lua`) shows these are **client-only**:
`setPedControlState`, `setPedAimTarget`, `getPedMoveState`, `getGroundPosition`, `processLineOfSight`, `isLineOfSightClear`, `getCursorPosition`, `getKeyState`.
The server has `createPed`, `setPedAnimation`, `setPedWalkingStyle`, `setPedStat`, `setElementSyncer`, `giveWeapon`, `killPed`, `spawnPlayer`, but no way to make a ped walk.

So the work is split the way the DayZ gamemodes do it (technique read, nothing copied: see THIRD_PARTY.md):

* **Server = brain.** The server creates every ped and object, owns the sim, and decides (zombie sees you, raider charges the wall, colonist walks to the workbench).
* **Owner's client = legs.** The server sends batched *intents* (`outbreak:drive`: `{ped, mode, x, y, speed, radius, target}`) and the owner's client
  (`client/driver.lua`, the ped's *syncer*) turns them into control states: face the target, hold forwards / walk / sprint, jump when stuck, aim and fire in bursts.
* **Ground heights** exist only on the client too, so `client/ground.lua` samples the ground under what it sees and `server/ground.lua` keeps a coarse height map to seat new spawns.

Other facts taken from the source and wiki and relied on (each is a checked fact, not a guess):

* MTA's Lua is **5.1** with `base, math, string, table, debug, utf8, os` opened, and `dofile, loadfile, require, loadlib, getfenv, newproxy` plus `os.execute/rename/remove/exit/getenv/tmpname/setlocale`
  disabled (`CLuaMain.cpp`). There is no `require`: `bootstrap_mta.lua` defines one over `fileOpen` + `loadstring` so the shared sim loads unchanged. `\x` string escapes do **not** exist in 5.1
  (a real finding of running the suite on PUC Lua 5.1.5; the resource uses none).
* The ped pool (about 140) **cannot be resized**: `engineSetPoolCapacity` only accepts the building and pointer-single-link pools
  (`CLuaEngineDefs.cpp`, "Can not change this pool capacity" for the rest). Hence the ped budget in section 7.
* `mta.triggerEvent` (CEF to Lua) only passes simple values, only works for local pages, and the event's `source` is the browser element (wiki). The bridge sends JSON as one string.
* `createBrowser` is asynchronous (wait for `onClientBrowserCreated`), `executeBrowserJavascript` needs `onClientBrowserDocumentReady` (wiki); both are respected in `client/ui.lua`.

## 2. Install

**What you need**

* A legitimate copy of **GTA San Andreas for PC** (MTA does not include the game) and the **MTA:SA client** from <https://www.multitheftauto.com/> (the resource asks for 1.5.8 or newer;
  the wiki's 1.6 changelog is the newest page that could be read: [Changes in 1.6](https://wiki.multitheftauto.com/wiki/Changes_in_1.6)).
* A server: either the one in the Windows MTA install (Start menu, "MTA Server") on the same PC, or a **Linux server** (recommended for the appdev2 box):

```sh
# from https://wiki.multitheftauto.com/wiki/Installing_and_Running_MTASA_Server_on_GNU_Linux (read 2026-10)
wget https://linux.multitheftauto.com/dl/multitheftauto_linux_x64.tar.gz
tar -xf multitheftauto_linux_x64.tar.gz
wget https://linux.multitheftauto.com/dl/baseconfig.tar.gz && tar -xf baseconfig.tar.gz     # new installs only: it overwrites the config
mv baseconfig/* multitheftauto_linux_x64/mods/deathmatch
cd multitheftauto_linux_x64 && ./mta-server64                                                 # first run, check it starts (libtinfo.so.5 symlink hint on the wiki page)
```

**Install the resource** (server side)

1. Copy the folder `mta/outbreak/` to `<server>/mods/deathmatch/resources/outbreak/`. Nothing else is needed: the sim, data, shared modules and the UI are all inside it
   (`tools/sync_sim.sh`, `sync_shared.sh`, `sync_ui.sh` keep the copies identical to `hybrids/outbreak/{sim,data}` and `fivem/outbreak/{shared,ui}`; `tests/run.sh` checks them).
2. In `mods/deathmatch/mtaserver.conf` add `<resource src="outbreak" startup="1" protected="0"/>` (or type `start outbreak` in the server console). The server console prints
   `[outbreak] ...` lines; with the default `selftest=1` it logs `selftest OK` about 1.5 s after start.
3. Optional: edit the `<settings>` block in `outbreak/meta.xml` (section 5; its defaults come from `shared/mta_config.lua`) and `restart outbreak`. `meta.xml` is generated by `tools/gen_meta.lua`
   (MTA has no wildcards): re-run `luajit mta/tools/gen_meta.lua` after adding a file, and put setting changes in `shared/mta_config.lua`, not only in `meta.xml`, or the generator will overwrite them.
4. Give yourself admin rights (section 6) or just play as the owner (the first player to join becomes the colony owner and may use every command, `owner_admin=1`).
5. Saves go to `outbreak/save/` (file backend) or `mods/deathmatch/databases/outbreak.db` (`store=sqlite`). A `save/README.txt` placeholder exists so the folder is created even if
   `fileCreate` does not create directories (unverified, section 10).

**Connect and play:** start MTA, connect to the server (section 3), wait for the download of the resource's client files (31 UI files and 19 Lua modules), you spawn at the base. Press **F6**.

## 3. Tailscale

The server only needs to be reachable from your PC; nothing needs to be on the public internet.

* Both machines on the same tailnet. On the server: `tailscale ip -4` (a `100.x.y.z` address); MagicDNS name works too.
* MTA needs **UDP 22003** (game; `<serverport>`) and **TCP 22005** (the built-in resource download server; `<httpport>`, used because `<httpdownloadurl>` is empty). Allow them
  on the server's `tailscale0` interface and in your tailnet ACLs. Per the wiki, `<serverip>` defaults to `auto`; leave it unless the server has several interfaces.
* Keep it private: set `<ase>0</ase>` (no server-browser listing) and `<donotbroadcastlan>1</donotbroadcastlan>` in `mtaserver.conf`
  ([Server mtaserver.conf](https://wiki.multitheftauto.com/wiki/Server_mtaserver.conf)).
* On the PC: MTA main menu, **Quick Connect**, enter `100.x.y.z:22003`, or open `mtasa://100.x.y.z:22003`. If the resource download stalls, the TCP 22005 path is the first suspect.
* The wiki does not cover Tailscale; that this works exactly like a LAN is expected, not verified.

## 4. Controls

| Key / action | Where | What it does |
|---|---|---|
| **F6** (also `Tab` when no screen is open) | game / page | toggle colony view (overhead camera, cursor, UI) |
| **I** | game / page | inventory screen (survival view) |
| **E** | game | open the loot pile near you in the inventory page |
| `W A S D` / arrow keys, `Shift` = fast | colony view | pan the camera |
| `Q` / `E` | colony view | rotate the camera |
| mouse wheel | colony view | zoom (height 15 to 200 m) |
| mouse at the screen edge | colony view | pan |
| left click | colony view | select the colonist under the cursor (ray from the camera); `Shift` adds |
| left drag | colony view | box-select colonists |
| right click | colony view | order the selection to walk to the ground point |
| `B` `Z` `L` `C` | colony view | dock tabs: build, zones, director, colonist card |
| `P` / `M` | colony view | work-priority grid / map screen |
| `Space`, `1` `2` `3` `4` | colony view | pause, speeds 1x 2x 4x 8x |
| `R` | colony view | draft / release the selection |
| left click / right click / `Esc` | placing a blueprint | commit at the ghost / cancel |
| `Esc` | page | close the open screen, else the menu |
| `/outbreak_colony`, `/outbreak_client` | chat | toggle colony view, client counters |

While a colony screen is open the browser has the keyboard and mouse (`showCursor`, `focusBrowser`, `guiSetInputMode`, `toggleAllControls(false)`); closing it hands everything back.
The keys are the vanilla page's (unchanged UI) plus `F6` / `I` / `E` bound in `client/main.lua` with `bindKey` (values in `shared/mta_config.lua` `client`: `colony_key`, `inventory_key`, `interact_key`).

## 5. Settings

`<settings>` in `outbreak/meta.xml` (generated from `shared/mta_config.lua`; the server reads them with `get`). Restart the resource after changing one.

| Setting | Default | Meaning |
|---|---|---|
| `seed` | 0 | world seed, 0 = from the clock |
| `profile` | escalating | director profile: calm, escalating, chaos |
| `colonists` | 4 | starting survivors (1 to 12) |
| `timescale` | 30 | game seconds per real second at speed 1 |
| `tick_ms` | 500 | real ms between host updates |
| `autoload` | 1 | load the newest save on start |
| `autosave` | 120 | seconds between autosaves, 0 = off |
| `owner_admin` | 1 | the colony owner may use the `/outbreak_*` commands |
| `owner_name` | (empty) | when set, only the player with this name can become the owner |
| `debug` | 0 | extra checks and logs (payload safety, `debug_*` UI actions) |
| `selftest` | 1 | run the determinism self-test 1.5 s after start and warn loudly on mismatch |
| `spawn_player` | 1 | spawn the owner at the base without needing a spawn manager |
| `store` | file | save backend: `file` (`fileCreate`) or `sqlite` (`dbConnect`) |
| `max_materialized` | 60 | zombies and raiders that may exist as peds at once (the rest of a horde stays abstract) |
| `max_peds` | 96 | hard ceiling for peds this resource owns |
| `pool_guard` | 120 | refuse to create peds while the server knows this many ped elements (all resources) |
| `max_objects` | 400 | ceiling for building, pile and marker objects |
| `origin` | `235.30,2430.10,16.85` | where the sim origin (base centre) sits in San Andreas (default is the Verdant Meadows airfield, **unverified**; any flat empty spot works) |
| `ui_mode` | gui | `gui` = `guiCreateBrowser` (the engine routes mouse and keyboard), `dx` = `createBrowser` drawn with `dxDrawImage` and fed `injectBrowserMouse*` |

## 6. Commands and ACL

Commands are registered unrestricted at the engine level and gated by `server/commands.lua`: allowed for the server console, for the colony owner when `owner_admin=1`, and for any player
whose ACL group has the right `command.<name>`.

| Command | What it does |
|---|---|
| `/outbreak_status` | colony status line (day, colonists, hordes, hash, owner) |
| `/outbreak_save` `/outbreak_load` | save now / load the newest save |
| `/outbreak_new [seed] [calm\|escalating\|chaos]` | new colony |
| `/outbreak_pause` `/outbreak_speed 0\|1\|2\|4\|8\|16` | clock control |
| `/outbreak_profile calm\|escalating\|chaos` | director profile |
| `/outbreak_horde [size] [distance]` | spawn a horde |
| `/outbreak_event <id>` | trigger a director event (for example `caravan`) |
| `/outbreak_give <item> [n]` | add an item to the owner |
| `/outbreak_day <hour> [minute] [day]` | set the time |
| `/outbreak_autopilot on\|off` | the sim's own AI plays the colony |
| `/outbreak_ff <minutes>` | fast-forward (sliced over timers, MTA aborts long-running scripts) |
| `/outbreak_hash` `/outbreak_audit` | state hash / item conservation check |
| `/outbreak_peds` | ped and object budget, counters, ground samples |
| `/outbreak_selftest` | rerun the determinism self-test |
| `/outbreak_colony` `/outbreak_client` | (client) toggle colony view / client counters |

ACL snippet for `mods/deathmatch/acl.xml` (a group of accounts that may use every command; add the accounts you log in with):

```xml
<acl name="Outbreak">
	<right name="command.outbreak_status" access="true"/>
	<right name="command.outbreak_save" access="true"/>
	<right name="command.outbreak_load" access="true"/>
	<right name="command.outbreak_new" access="true"/>
	<right name="command.outbreak_pause" access="true"/>
	<right name="command.outbreak_speed" access="true"/>
	<right name="command.outbreak_profile" access="true"/>
	<right name="command.outbreak_horde" access="true"/>
	<right name="command.outbreak_event" access="true"/>
	<right name="command.outbreak_give" access="true"/>
	<right name="command.outbreak_day" access="true"/>
	<right name="command.outbreak_autopilot" access="true"/>
	<right name="command.outbreak_ff" access="true"/>
	<right name="command.outbreak_hash" access="true"/>
	<right name="command.outbreak_audit" access="true"/>
	<right name="command.outbreak_peds" access="true"/>
	<right name="command.outbreak_selftest" access="true"/>
</acl>
<group name="OutbreakAdmin">
	<acl name="Outbreak"/>
	<object name="user.YourAccountName"/>
</group>
```

(`tests/readme_test.lua` fails if a command in `server/commands.lua` is missing from this block or the table above.)

## 7. How it works

```
 page (CEF, unchanged vanilla NUI + mta-bridge.js) <--executeBrowserJavascript / mta.triggerEvent--> client Lua <--triggerServerEvent / triggerClientEvent--> server Lua --> shared sim
 camera, picking, ghost, noise, survival fx, ped driver, ground sampler                                          sim, peds, objects, persistence, commands, trust checks
```

* **Server** (`server/`): `main.lua` loads the sim through `bootstrap_mta.lua` and runs a fixed-step `setTimer` tick; `net.lua` batches OUT events to the owner (one `triggerClientEvent` per tick) and
  validates every incoming event; `peds.lua` is the only place that creates or destroys peds (tracked, capped, destroyed on stop); `zombies.lua`, `raiders.lua`, `colonists.lua` are the brains
  (perception radii from TP-Advanced-Zombies, presets from RottenV, see THIRD_PARTY.md); `buildings.lua` and `props.lua` own the objects; `world.lua` the clock, weather, team and the owner's body;
  `store.lua` the save backend; `commands.lua` the admin commands; `ground.lua` the height map.
* **Client** (`client/`): `ui.lua` the browser bridge; `camera.lua` colony camera and picking (`getWorldFromScreenPosition`, `processLineOfSight`, `getScreenFromWorldPosition`); `placement.lua` the translucent
  ghost; `noise.lua` gunshot / explosion / siren / sprint detection; `survival.lua` damage reports, sprint lock and limp; `driver.lua` the ped driver; `ground.lua`; `world.lua` HUD hiding, outage dimming, alert sounds; `props.lua` the E key.
* **Trust model** (`server/net.lua`): remote events exist only because they are registered with `addEvent(name, true)`; a handler requires `client` to be a real player (that value cannot be forged),
  `client == owner`, **and `source == resourceRoot`** (a spoofer controls `source` and could otherwise pick any element, for example one of our peds); payloads go through `shared/protocol.lua` sanitizers; token buckets
  limit orders, UI actions and ground samples; the browser-to-client event `outbreak:ui` is local-only (`addEvent(name, false)`) and accepted only from our own browser element. Tests spoof each of these.
* **Persistence:** `shared/host.lua` writes a versioned, checksummed payload to two rotating slots plus a meta pointer; `set` raises on failure so a failed write never flips the pointer. Autosave, save on owner quit, save on stop.
* **Graceful stop:** every module registers a cleanup. On `onResourceStop` the server saves, kills its timers, destroys every ped, object and the team, restores weather and minute duration; on
  `onClientResourceStop` the client destroys the browser and ghost, restores controls, cursor, camera, HUD components and walking style. `tests/lifecycle_test.lua` checks that nothing alive and no timer is left.
* **Ped budget (MTA's ped pool is about 140 and fixed):** 60 hostile peds + 16 colonists + 4 traders + the players + up to 12 waiting corpses = 96, which leaves ambient and other-resource headroom.
  `max_peds` (96) is the hard ceiling, `pool_guard` (120) refuses creation when the server already sees that many ped elements, `max_objects` (400) of about 1200 object slots.
  The sim's own horde abstraction means a 200-zombie horde is mostly numbers; only the ones near you become peds.
* **Determinism self-test:** `shared/selftest.lua` replays a 2-day seeded colony and compares its state hash with `shared/selftest_data.lua` (`449ba8f9380b6128`, identical on LuaJIT, Lua 5.4 and PUC Lua 5.1.5).
  If MTA's Lua (for instance a 32-bit `long` in `string.format("%d")` on Windows) ever disagrees, the server warns loudly at start.
* **UI:** `tools/sync_ui.sh` copies the vanilla NUI **byte-identically** (`check` mode verifies; `mta.html` is generated by inserting one line, `<script src="mta-bridge.js"></script>`, before `js/core.js`).
  `ui/mta-bridge.js` turns the page's `fetch('https://outbreak/<name>')` into `mta.triggerEvent('outbreak:ui', name, '<json>')`; the Lua client decodes it with `shared/json_decode.lua` (size and depth limited)
  and answers with the same `ready / order / ui / mode / mouse / key / focus / place / screen / close` callbacks the FiveM adapter has.
  CEF requirements: MTA 1.5.8+, "Enable CEF" in the client settings (default on); the page is local (`http://mta/local/ui/mta.html`), so *Enable remote websites* is not needed; every UI file is a `<file>` in `meta.xml`.

## 8. Graphics

MTA renders through GTA SA's DirectX 9 pipeline, so the usual San Andreas graphics options apply, with the caveat of MTA's anti-cheat. Research done 2026-10 with web searches and the MTA wiki;
**anything marked "unconfirmed" could not be established and needs a test on your PC.**

* **MTA's own, supported route: shaders and the engine functions.** `dxCreateShader` (HLSL `.fx`), `engineApplyShaderToWorldTexture`, `dxCreateScreenSource` (post-processing), `engineImportTXD` / `engineReplaceModel`
  (texture and model replacement from a resource), and the world settings `setFarClipDistance`, `setFogDistance`, `setSkyGradient`, `setCloudsEnabled`, `setHeatHaze`, `setSunSize`, `setWaterColor`,
  `setColorFilter`, `setBlurLevel` all exist in the real mtasa-blue Lua definitions (checked against the source). The wiki says shader creation is not guaranteed unless the effect has a fallback technique that works on every PC
  ([dxCreateShader](https://wiki.multitheftauto.com/wiki/DxCreateShader)); `dxCreateTexture` warns that loading too many textures can crash the client ([dxCreateTexture](https://wiki.multitheftauto.com/wiki/DxCreateTexture)).
  This resource does **not** ship any shader yet: a night-time colour grade and fog for the outbreak mood would be the first candidates, written as a resource-side `.fx`.
  The only `.fx` files in the MIT mtasa-resources clone are `[gameplay]/gps/overlay.fx` and `[gameplay]/visualiser/texreptransform.fx` (small, not a post-processing pack).
* **Video options in MTA's settings:** high-detail vehicles and peds change the LOD reset values (500 versus 70/150 for vehicles, 500 versus 60 for peds; [resetVehiclesLODDistance](https://wiki.multitheftauto.com/wiki/ResetVehiclesLODDistance),
  [resetPedsLODDistance](https://wiki.multitheftauto.com/wiki/ResetPedsLODDistance)); turn **High detail peds** on for zombies seen from the overhead camera. Anisotropic filtering has been in the video tab since 1.2
  (a fan-site changelog; no official page found for the other options).
* **ENB:** ENB works through a replacement `d3d9.dll`. MTA's anti-cheat has an optional special detection, **SD #12 "Disallow custom D3D9.DLL (this will break certain GTA mods like ENB)"**, enabled per server
  through `<enablesd>`; the wiki's server config page gives the default as `31,32`, i.e. **12 is off**, and the anti-cheat page says most servers should leave the setting blank
  ([Anti-cheat guide](https://wiki.multitheftauto.com/wiki/Anti-cheat_guide), [mtaserver.conf](https://wiki.multitheftauto.com/wiki/Server_mtaserver.conf)). On your own server that means ENB is not blocked by the server; whether
  the **client** side of MTA still blocks or mishandles a proxy `d3d9.dll` in 2026 is **unconfirmed** (no source found). "ENB partially compatible with MTA" is folk knowledge: test it.
* **ReShade:** the only evidence found is a ReShade forum thread from about 2016 in which a ReShade developer says MTA's anti-cheat stops ReShade from loading and that depth-based effects are disabled for online games
  ([forum thread](https://reshade.me/forum/troubleshooting/1781-mta-san-andreas?rCH=2); the page returned HTTP 429 when re-read, so this is the search snippet). Treat ReShade as **blocked until proven otherwise**; the shader route above is the safe substitute.
* **SilentPatch and SkyGfx:** SilentPatch (fixes for the PC versions of GTA 3 / VC / SA) and SkyGfx (PS2 / Xbox look: dual-pass world, night vertex colours) are ASI plugins that need an ASI loader
  ([SkyGfx 2.9a notes on the overlap with SilentPatch](https://libertycity.net/files/gta-san-andreas/96044-skygfx-sa-2.9a.html), [SilentPatch 2026 update listing](https://libertycity.net/files/240483-silentpatch-2026-gncellemesi.html)).
  The SkyGfx 3.6 changelog lists compatibility with **SA-MP**, which is a different multiplayer mod. Whether MTA loads ASI plugins from the GTA folder, and whether its anti-cheat (`VF #8`, "unauthorized mods") objects, is **unconfirmed**.
* **HD texture and vehicle packs:** local replacement of `gta3.img` / `gta_int.img` is what anti-cheat AC #18 ("modified game files") and optional SD #20 ("non-standard gta3.img / gta_int.img", server-enabled, off by default) look at.
  Resource-delivered replacements (`engineImportTXD`, `engineReplaceModel`) are the supported way and need no local file changes. Your own server decides: leave `<disableac>` and `<enablesd>` at their defaults and test, or
  disable the specific codes you trip over. No source was found on which community packs work with MTA 1.6 in 2026: **unconfirmed**.
* **The Take-Two takedown (December 2025):** the `mtasa-blue` repository was disabled after a DMCA notice, the MTA team filed a counter-notice on 22 December 2025 and GitHub restored it in early January 2026
  ([TorrentFreak](https://torrentfreak.com/?p=275921), [Korben](https://korben.info/en/multi-theft-auto-returns-github-take-two-failed-dmca.html)); coverage notes Take-Two could still sue, as it did over re3 / reVC. Practical consequences for this project:
  the MTA client and server come from multitheftauto.com, the checks in `tools/` read a local, **read-only** clone of mtasa-blue (GPL-3.0, nothing copied), and the clone should be kept in case the repository goes away again.
* **Performance, from the mock (not from a GPU):** one screen of the colony UI is about 170 KB of JavaScript pushes per 40 s; the CEF page is only drawn while a screen is open
  (`setBrowserRenderingPaused` when MTA is minimised; the wiki warns the call has a low-RAM caveat).

## 9. Tests and what the mocks cannot prove

```sh
mta/tests/run.sh                  # everything: copy checks, Lua suite on LuaJIT + Lua 5.4 (+ PUC Lua 5.1.5), function check, browser test, Lua replay of the browser's calls
mta/tests/run.sh --no-browser     # without Playwright
mta/tests/run.sh --with-sim       # also the sim's own suite and the FiveM adapter's suite
mta/tools/build_lua51.sh          # builds PUC-Rio Lua 5.1.5 (md5-checked) into ~/.cache; then  LUA51=<path>/src/lua mta/tests/run.sh
```

| Layer | Proves | Does **not** prove |
|---|---|---|
| `tests/mock_mta.lua` + `mock_natives.lua`: a fake MTA | the real server and client Lua run end to end on it: handshake, events with `addEvent(name, true)` and `client` / `source` semantics, spoofing rejected, timers, the file API, elements and destroy, peds that only move when streamed in and synced, collision-less server, a browser that follows the create / load / ready order; per-side function sets taken from the real source; strict globals; Lua 5.1 library set; leak, lifecycle, failure-injection and call-budget checks | that real MTA behaves like the mock: every mock rule comes from the wiki or source, so a wrong reading of the wiki is wrong in both |
| `tools/function_check.lua` | every global, function and event name the resource uses exists on the side that runs it, according to the real mtasa-blue definitions; no leaked globals; every remote event registered | argument order and types, return values, behaviour |
| LuaJIT, Lua 5.4 **and PUC Lua 5.1.5** (the interpreter MTA embeds) | identical results and sim hash; all 77 files compile as 5.1 (found the `\x` escape difference in a test) | MTA's builds of Lua (patches, 32-bit `long` on Windows) |
| `tests/ui_bridge_test.mjs` (Playwright, real Chromium) | the unchanged page loads from `http://mta/local/` using only files `meta.xml` ships, the bridge exists before `core.js`, clicks and keys become the right `mta.triggerEvent('outbreak:ui', name, json)` calls with simple argument types, the state / HUD / events the **real Lua client** pushed render, a priority click sends the right order, junk does not crash the page | that CEF in MTA provides `window.mta` identically, local-origin rules, focus, GPU use, frame rate |
| `tests/replay_ui_calls.lua` | those recorded browser calls, byte for byte, through `json_decode`, `client/ui.lua`, the server, the host and into the sim (c1's cook priority ends where the page showed) | the real transport |
| `tests/config_test.lua` | every prop model id exists and has the name we think in MTA's own editor name table (MIT, 14308 names); every animation block / name exists in MTA's freeroam animation list | that it looks right, has collision or plays |
| `tests/readme_test.lua` | README and THIRD_PARTY.md match the code: every command, ACL right, setting, event, key and MTA function is documented, the budget numbers are the configured ones, every `borrowed:` mark has a row | that the prose is right |

**What a mock can never prove:** that the engine agrees with the wiki (ped pool behaviour, `createPed` model validity, `setElementSyncer` on peds, collision, streaming distances); animation names and how
skins and objects look; how fast any of it runs; CEF focus, cursor and transparency; the timing and ordering of the real network; anti-cheat; timer precision; whether MTA's script-timeout watchdog trips.

## 10. Unverified until it runs in the real game

A checklist for the first session on the PC. Each line says what to look at and which knob to turn.

1. **Does `createPed` + `setElementSyncer(ped, owner)` + client `setPedControlState` actually walk the peds?** (the whole zombie design). Watch `/outbreak_peds`; `/outbreak_client` shows `drive intents` / `driven` / `stuck`.
   If `driven` stays 0 while intents arrive, `isElementSyncer` is false or the peds are not streamed in (the server sets the syncer on ready and on creation).
2. **Streaming in colony view.** The camera is placed with `setCameraMatrix` and may leave the player; whether MTA streams elements and collision around the **camera** or around the **player ped** is unconfirmed.
   If peds freeze when the camera is far from you (`not streamed in`), keep the camera within about 200 m, or move the frozen anchor ped with the focus.
3. **`getGroundPosition` returns 0 where collision is not loaded.** The client treats 0 as "no sample"; a base on flat ground near the origin is assumed. Objects or peds floating or sinking: `/outbreak_peds` ground counters.
4. **Origin.** `235.30,2430.10,16.85` (Verdant Meadows airfield, from a coordinate list in the mtadayz gamemode) is unverified. Use `origin` to move it.
5. **Prop models.** Every id's *name* is checked against MTA's editor table, but whether walls look like walls and objects have collision is not (`shared/mta_config.lua` `props`, first model the game accepts wins).
6. **Animations** (`anims` in `shared/mta_config.lua`: BOMBER/BOM_Plant, FOOD/EAT_Burger, VENDING/VEND_Drink2_P, BEACH/ParkSit_M_loop, RYDER/RYD_Die_PT1, SCRATCHING/sclng_r, FIGHT_B/FightB_1, CARRY/crry_prtial). The names exist in MTA's own animation list (checked by `tests/config_test.lua` against the freeroam resource's catalog); whether they *look* right for each job, and whether `setPedAnimation` on a server ped plays for the syncer, is unverified. Same for **walking styles** (119 / 120 / 124 / 125 / 126 per the wiki).
7. **Skins.** Appearance of the model ids in `peds` config is unverified; `getValidPedModels()` filters invalid ids at start, no story characters are used.
8. **Heading convention** in `driver.lua` (`0` = north, positive turns left, from the wiki) and the `stuck_ms` unstick behaviour against real fences and walls.
9. **`setMinuteDuration`** limits and whether `setTime` / `setWeatherBlended` fight the sim clock; weather ids (0 / 16 / 8) and the alert sound ids are guesses.
10. **`fileCreate` creating directories**, and `dbConnect("sqlite", "outbreak.db")` placement.
11. **CEF.** `guiCreateBrowser` transparency and input routing (`ui_mode=gui`); if the page steals keys or looks wrong try `ui_mode=dx`. `isBrowserDomainBlocked` for a local URL; whether the local origin is exactly `http://mta/local/ui/mta.html`.
12. **`meta.xml`:** `type="gamemode"` (it may stop another gamemode), `min_mta_version 1.5.8`, `download="false"` on server files, and the client downloads 31 UI files and 19 Lua modules.
13. **Numbers:** the 32-bit `long` risk (`selftest` reports it at start), memory and frame time with 60 peds, the ped pool (`engineGetPoolUsedCapacity("ped")` is client-only and not used yet; a client-side guard would be the next safety).
14. **ACL / owner logic** with a second player, `owner_name`, reconnects.
15. **Graphics** items in section 8 marked unconfirmed (ENB, ReShade, SilentPatch / SkyGfx, texture packs).

## 11. Every MTA function used

Generated by `lua5.4 mta/tools/function_check.lua --markdown` from the code itself (`tests/readme_test.lua` fails if this table and the code disagree). **111** distinct functions;
all verified to exist on the listed side in the mtasa-blue definitions. "both" means the function exists in both the client and server definitions.

<!-- functions:begin (generated by tools/function_check.lua --markdown) -->
| function | side | first used in |
|---|---|---|
| `addCommandHandler` | both | client/main.lua |
| `addEvent` | both | client/driver.lua |
| `addEventHandler` | both | client/ctx.lua |
| `bindKey` | client | client/main.lua |
| `cancelEvent` | client | client/survival.lua |
| `createBrowser` | client | client/ui.lua |
| `createObject` | both | client/placement.lua |
| `createPed` | server | server/peds.lua |
| `createTeam` | server | server/world.lua |
| `dbConnect` | server | server/store.lua |
| `dbExec` | server | server/store.lua |
| `dbPoll` | server | server/store.lua |
| `dbQuery` | server | server/store.lua |
| `destroyElement` | both | client/placement.lua |
| `dxDrawImage` | client | client/ui.lua |
| `dxDrawLine3D` | client | client/camera.lua |
| `dxDrawRectangle` | client | client/world.lua |
| `executeBrowserJavascript` | client | client/ui.lua |
| `fadeCamera` | server | server/world.lua |
| `fileClose` | both | bootstrap_mta.lua |
| `fileCreate` | server | server/store.lua |
| `fileDelete` | server | server/store.lua |
| `fileExists` | both | bootstrap_mta.lua |
| `fileGetSize` | both | bootstrap_mta.lua |
| `fileOpen` | both | bootstrap_mta.lua |
| `fileRead` | both | bootstrap_mta.lua |
| `fileWrite` | server | server/store.lua |
| `focusBrowser` | client | client/ui.lua |
| `get` | server | server/main.lua |
| `getCameraMatrix` | client | client/main.lua |
| `getControlState` | client | client/noise.lua |
| `getElementData` | client | client/colonists_view.lua |
| `getElementHealth` | server | server/colonists.lua |
| `getElementPosition` | both | client/camera.lua |
| `getElementType` | both | client/driver.lua |
| `getElementVelocity` | client | client/noise.lua |
| `getElementsByType` | both | client/colonists_view.lua |
| `getGroundPosition` | client | client/camera.lua |
| `getMinuteDuration` | server | server/world.lua |
| `getPedMoveState` | client | client/noise.lua |
| `getPedOccupiedVehicle` | client | client/noise.lua |
| `getPedWeaponSlot` | client | client/noise.lua |
| `getPlayerName` | server | server/commands.lua |
| `getResourceName` | client | client/ui.lua |
| `getScreenFromWorldPosition` | client | client/camera.lua |
| `getThisResource` | client | client/ui.lua |
| `getTickCount` | both | client/camera.lua |
| `getTime` | server | server/world.lua |
| `getValidPedModels` | server | server/peds.lua |
| `getVehicleSirensOn` | client | client/noise.lua |
| `getWeather` | server | server/world.lua |
| `getWorldFromScreenPosition` | client | client/camera.lua |
| `giveWeapon` | server | server/colonists.lua |
| `guiCreateBrowser` | client | client/ui.lua |
| `guiGetBrowser` | client | client/ui.lua |
| `guiGetScreenSize` | client | client/camera.lua |
| `guiSetInputMode` | client | client/ui.lua |
| `hasObjectPermissionTo` | server | server/commands.lua |
| `injectBrowserMouseDown` | client | client/ui.lua |
| `injectBrowserMouseMove` | client | client/ui.lua |
| `injectBrowserMouseUp` | client | client/ui.lua |
| `injectBrowserMouseWheel` | client | client/ui.lua |
| `isBrowserDomainBlocked` | client | client/ui.lua |
| `isElement` | both | client/driver.lua |
| `isElementStreamedIn` | client | client/driver.lua |
| `isElementSyncer` | client | client/driver.lua |
| `isPedDead` | both | client/colonists_view.lua |
| `isPedDucked` | server | server/zombies.lua |
| `isPedInVehicle` | both | client/noise.lua |
| `isTimer` | both | client/ctx.lua |
| `killPed` | server | server/colonists.lua |
| `killTimer` | both | client/ctx.lua |
| `loadBrowserURL` | client | client/ui.lua |
| `outputChatBox` | both | client/main.lua |
| `outputDebugString` | client | client/ctx.lua |
| `outputServerLog` | server | server/commands.lua |
| `playSoundFrontEnd` | client | client/world.lua |
| `processLineOfSight` | client | client/camera.lua |
| `removeEventHandler` | client | client/ctx.lua |
| `requestBrowserDomains` | client | client/ui.lua |
| `setBrowserRenderingPaused` | client | client/ui.lua |
| `setCameraMatrix` | client | client/camera.lua |
| `setCameraTarget` | both | client/camera.lua |
| `setElementAlpha` | both | client/placement.lua |
| `setElementCollisionsEnabled` | both | client/placement.lua |
| `setElementData` | server | server/colonists.lua |
| `setElementFrozen` | both | client/camera.lua |
| `setElementHealth` | server | server/colonists.lua |
| `setElementPosition` | both | client/placement.lua |
| `setElementSyncer` | server | server/peds.lua |
| `setMinuteDuration` | server | server/world.lua |
| `setPedAimTarget` | client | client/driver.lua |
| `setPedAnimation` | server | server/colonists.lua |
| `setPedControlState` | client | client/driver.lua |
| `setPedRotation` | client | client/driver.lua |
| `setPedStat` | server | server/zombies.lua |
| `setPedWalkingStyle` | both | client/survival.lua |
| `setPlayerHudComponentVisible` | client | client/world.lua |
| `setPlayerTeam` | server | server/world.lua |
| `setTeamFriendlyFire` | server | server/world.lua |
| `setTime` | server | server/world.lua |
| `setTimer` | both | client/ctx.lua |
| `setWeather` | server | server/world.lua |
| `setWeatherBlended` | server | server/world.lua |
| `showCursor` | client | client/ui.lua |
| `spawnPlayer` | server | server/world.lua |
| `tocolor` | client | client/camera.lua |
| `toggleAllControls` | client | client/ui.lua |
| `toggleControl` | client | client/survival.lua |
| `triggerClientEvent` | server | server/net.lua |
| `triggerServerEvent` | client | client/camera.lua |
<!-- functions:end -->

Remote events (all `addEvent(name, true)`): `outbreak:ready`, `outbreak:in`, `outbreak:order`, `outbreak:ui_action`, `outbreak:ground` (client to server);
`outbreak:hello`, `outbreak:events`, `outbreak:state`, `outbreak:hud`, `outbreak:clock`, `outbreak:catalog`, `outbreak:uimsg`, `outbreak:drive` (server to client). Local only: `outbreak:ui` (browser to client).
Built-in events handled: `onResourceStart`, `onResourceStop`, `onPlayerQuit`, `onPlayerWasted`, `onPedWasted`, `onClientResourceStart`, `onClientResourceStop`, `onClientRender`, `onClientPreRender`, `onClientMinimize`,
`onClientRestore`, `onClientBrowserCreated`, `onClientBrowserDocumentReady`, `onClientPlayerDamage`, `onClientPlayerWeaponFire`, `onClientPedWeaponFire`, `onClientExplosion`, and in `ui_mode=dx` only `onClientClick`, `onClientCursorMove`, `onClientKey` (checked against `CClientGame.cpp` / `CGame.cpp`).

## 12. Deviations from the brief

* **Ped steering is on the client** (section 1): the brief had the server drive peds; the server cannot.
* **Buildings, sites and loot piles are server objects**, not client-side: the brief wrote client-side placement; only the blueprint **ghost** is client-side. A server object persists, streams to everyone and cannot be
  diverged by a client, and the server already owns the sim's building list.
* **`outbreak:uimsg` replaces the FiveM `ui` event name** for server-to-client UI results, because `outbreak:ui` is the browser-to-client local event in MTA.
* **Browser creation waits for the server's `hello`** (owner only), so the mode (`ui_mode`) is the server's choice and a second player never loads a UI.
* **Rotating save slots and the checksum come from the shared host**, so the "versioned persistence" is the FiveM adapter's, on MTA's file or sqlite API.

## 13. Debugging and troubleshooting

* Server console / `/outbreak_status`, `/outbreak_peds`, `/outbreak_selftest`; client `/outbreak_client`. Set `debug=1` for payload-safety checks and `debug_*` UI actions.
* `F8` (MTA's debug console) shows `outputDebugString` lines tagged `[outbreak]`; Lua errors are caught per module and counted (not silent): the first and every 100th repeat is logged.
* No colony UI: the page is local; check the F8 console for a browser error and that all `ui/` files downloaded. A blank cursor but no page: try `ui_mode=dx`.
* `selftest FAILED`: the sim is not deterministic on MTA's Lua; saves still work on this machine but do not move them between runtimes until it is understood.
* The mock harness is the debugger of first resort: reproduce with `tests/mock_mta.lua` (see `tests/lifecycle_test.lua` for how to script a session) before changing code.

## 14. Licences

See `THIRD_PARTY.md` (one row per borrowed block, what was read but not copied, and what could not be borrowed). GPL / LGPL material is used only under the private-build rule of `BORROW-RULES.md`; re-clean before sharing.
