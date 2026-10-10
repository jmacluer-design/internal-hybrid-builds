# Outbreak for MTA:SA (private build)

Zombie survival plus colony manager for **Multi Theft Auto: San Andreas**, on the same pure-Lua sim, protocol and vanilla NUI as the finished FiveM adapter
(`../fivem/`). Private, non-commercial, for your own PC and your own server.

> **PRIVATE USE ONLY. NEVER REDISTRIBUTE THIS RESOURCE.** The zombie and ped-driver logic (`client/driver.lua`, parts of `server/zombies.lua`, `server/peds.lua`, `server/net.lua`, the zombie skin list)
> was ported from the MTA DayZ "slothbot" code in repositories that have **no licence** (`NullSystemWorks/mtadayz`, `mta-resources/deadwalkers`), on the owner's decision for a private fun project.
> Every such block is wrapped in `-- BORROWED-PRIVATE (unlicensed upstream, private use only): <repo>/<path>` ... `-- END BORROWED-PRIVATE`.
> `mta/tools/list_private_blocks.sh` lists them (`--check` exits 1 while any exists) and says how to strip them; `THIRD_PARTY.md` has one row per block. Do not publish, share, sell or deploy
> this resource for anyone else while those blocks are in it.

> **Status, said plainly: the server half has run on the real MTA 1.6 Linux server, the client half has never run in a real MTA client.** `tools/real_server_smoke.sh` runs the resource on the official
> server headless and PASSES (section 9: load, self-test, audit, 60 test zombies under the caps, save, restart, cleanup). Everything that needs a client (peds walking, streaming, the CEF page) is
> verified only against the wiki, the real MTA source lists, a mock MTA, real Chromium and real Lua 5.1.5 / LuaJIT / Lua 5.4. Section 10 is the list of things only your PC can settle.
> Expect a first-run session of fixing, not a first-run finished game.
>
> **The phone companion (section 3a) is the exception worth knowing about:** it needs no GTA client, and `tools/phone_e2e.sh` runs it against the real 1.6 server with a mobile-emulated Chromium (touch,
> login, live colony, a priority and a blueprint changed by touch and read back from the server's console). It has never run on a physical phone.

Contents: 1 [What was found out about MTA](#1-what-was-found-out-about-mta-and-changes-the-design) / 2 [Install](#2-install) / 3 [Tailscale](#3-tailscale) / 3a [Phone](#3a-phone-the-colony-in-a-phone-browser-no-gta-client) / 4 [Controls](#4-controls)
/ 5 [Settings](#5-settings) / 6 [Commands and ACL](#6-commands-and-acl) / 7 [How it works](#7-how-it-works) / 8 [Graphics](#8-graphics) / 9 [Tests](#9-tests-and-what-the-mocks-cannot-prove)
/ 10 [Unverified until it runs in the game](#10-unverified-until-it-runs-in-the-real-game) / 11 [Every MTA function used](#11-every-mta-function-used) / 12 [Deviations](#12-deviations-from-the-brief)
/ 13 [Debugging](#13-debugging-and-troubleshooting) / 14 [Licences](#14-licences)

## 1. What was found out about MTA (and changes the design)

**MTA's server cannot steer a ped.** The brief assumed the server could walk, turn and shoot peds (`setPedControlState`, `setPedAimTarget`, ...). The real source
(`multitheftauto/mtasa-blue`, `Server/.../luadefs` versus `Client/.../luadefs`, read by `tools/mta_defs.lua`) shows these are **client-only**:
`setPedControlState`, `setPedAimTarget`, `getPedMoveState`, `getGroundPosition`, `processLineOfSight`, `isLineOfSightClear`, `getCursorPosition`, `getKeyState`.
The server has `createPed`, `setPedAnimation`, `setPedWalkingStyle`, `setPedStat`, `setElementSyncer`, `giveWeapon`, `killPed`, `spawnPlayer`, but no way to make a ped walk.

So the work is split the way the DayZ gamemodes do it, and since the owner's decision the movement rules are **the DayZ "slothbot" ones, ported** (private use only: see the warning at the top):

* **Server = brain.** The server creates every ped and object, owns the sim, and decides (zombie sees you, raider charges the wall, colonist walks to the workbench). It tags each ped with element data
  (`ob` = its kind), reads who controls it (`getElementSyncer`, else the nearest player: slothbot's `assigncontroller`; **it never forces a syncer** with `setElementSyncer`, slothbot does not either) and
  gives weapons through `Peds.give_weapon`, which can give them again when a client reports the ped streamed in.
* **Owner's client = legs.** The server sends batched *intents* (`outbreak:drive`: `{ped, mode, x, y, speed, radius, tgt}`) and the owner's client (`client/driver.lua`) turns them into control states with
  slothbot's rules: face the target every 700 ms (the element itself while `isLineOfSightClear`, else the spot it was last seen at, and give up there), hold `forwards` (+ `walk` / `sprint`), stand still and
  jab with the `fire` control in the 2300 ms melee swing, walk to the weapon's firing distance and shoot in its bursts, and when stuck (less than a metre in 600 ms) roll the die (give up / jump / turn to a
  random heading for 1.2 s). It sets the control states on every ped that is streamed in, with **no syncer check** (only the syncer's states move the ped, which is why slothbot needs none).
  A zombie the player hits turns on the player (`outbreak:hit`); a ped that streams in is silenced (`setPedVoice`) and asks for its weapon again (`outbreak:stream`).
* **The sim stays authoritative.** Counts (`spawn_horde` becomes peds, never more than 60 hostile / 96 total), noise (`noise` attracts materialized zombies), damage (a zombie's fists are cancelled in
  `onClientPedDamage` / `onClientPlayerDamage`: the damage is scripted on the server and reaches the sim as `player_damage` / `ped_damage`) and deaths (`onPedWasted` becomes `ped_died`) all go through the sim.
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

**Fastest path on a Linux x86-64 server (for example appdev2): one command.** From a checkout of this repo:

```sh
bash hybrids/outbreak/mta/tools/install_server_linux.sh            # installs into ~/mta-server; re-run after every git pull to update the resource (saves are kept)
tmux new -s mta 'cd ~/mta-server/multitheftauto_linux_x64 && ./mta-server64'
```

It downloads the official MTA:SA server, makes the config private (no browser listing, no LAN broadcast, only `outbreak` starts), installs the resource and prints the exact fix for any missing library.
`install_server_linux.sh --check` reports the state without changing anything.

**Verified on the REAL MTA:SA 1.6 server (64-bit Linux, Ubuntu 24.04), 2026-10-10, no client attached:** `Resources: 1 loaded, 0 failed`; the in-game self-test reproduced the recorded sim hash
`449ba8f9380b6128` inside MTA's own Lua engine (the same hash as LuaJIT, Lua 5.4 and PUC 5.1.5); a scripted console session (`outbreak_autopilot on`, `outbreak_speed 16`, `outbreak_horde`, `outbreak_ff 1440`)
ran about two game days with zero errors or warnings: buildings grew 4 to 20, `outbreak_audit` printed `audit OK` twice, real `createPed` / `createObject` calls succeeded (peds 2/96, objects 10/400),
saves written on command and on resource stop. NOT covered (needs a real client): peds walking, camera, CEF UI, streaming, anything in section 10.


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

**One command instead (Linux x86-64, e.g. appdev2):** `bash mta/tools/install_server_linux.sh [dest]` downloads the official server and base config if they are missing, makes the config private (no browser
listing, no LAN broadcast, only `outbreak` auto-starts), copies the resource (keeping `save/`) and checks the shared libraries; re-run it after a `git pull` to update the resource. Then run the smoke test
below (`mta/tools/real_server_smoke.sh --quick`, about 30 s).

**Install the resource** (server side, by hand)

1. Copy the folder `mta/outbreak/` to `<server>/mods/deathmatch/resources/outbreak/`. Nothing else is needed: the sim, data, shared modules and the UI are all inside it
   (`tools/sync_sim.sh`, `sync_shared.sh`, `sync_ui.sh` keep the copies identical to `hybrids/outbreak/{sim,data}` and `fivem/outbreak/{shared,ui}`; `tests/run.sh` checks them).
2. In `mods/deathmatch/mtaserver.conf` add `<resource src="outbreak" startup="1" protected="0"/>` (or type `start outbreak` in the server console). The server console prints
   `[outbreak] ...` lines; with the default `selftest=1` it logs `selftest OK` about 1.5 s after start.
3. Optional: edit the `<settings>` block in `outbreak/meta.xml` (section 5; its defaults come from `shared/mta_config.lua`) and `restart outbreak`. `meta.xml` is generated by `tools/gen_meta.lua`
   (MTA has no wildcards): re-run `luajit mta/tools/gen_meta.lua` after adding a file, and put setting changes in `shared/mta_config.lua`, not only in `meta.xml`, or the generator will overwrite them.
4. Give yourself admin rights (section 6) or just play as the owner (the first player to join becomes the colony owner and may use every command, `owner_admin=1`).
5. Saves go to `outbreak/save/` (file backend) or `mods/deathmatch/databases/outbreak.db` (`store=sqlite`). A `save/README.txt` placeholder exists so the folder is created even if
   `fileCreate` does not create directories (unverified, section 10).

**Connect and play:** start MTA, connect to the server (section 3), wait for the download of the resource's client files (38 UI files and 19 Lua modules), you spawn at the base. Press **F6**.

## 3. Tailscale

The server only needs to be reachable from your PC; nothing needs to be on the public internet.

* Both machines on the same tailnet. On the server: `tailscale ip -4` (a `100.x.y.z` address); MagicDNS name works too.
* MTA needs **UDP 22003** (game; `<serverport>`) and **TCP 22005** (the built-in resource download server; `<httpport>`, used because `<httpdownloadurl>` is empty). Allow them
  on the server's `tailscale0` interface and in your tailnet ACLs. Per the wiki, `<serverip>` defaults to `auto`; leave it unless the server has several interfaces.
* Keep it private: set `<ase>0</ase>` (no server-browser listing) and `<donotbroadcastlan>1</donotbroadcastlan>` in `mtaserver.conf`
  ([Server mtaserver.conf](https://wiki.multitheftauto.com/wiki/Server_mtaserver.conf)).
* On the PC: MTA main menu, **Quick Connect**, enter `100.x.y.z:22003`, or open `mtasa://100.x.y.z:22003`. If the resource download stalls, the TCP 22005 path is the first suspect.
* The wiki does not cover Tailscale; that this works exactly like a LAN is expected, not verified.

## 3a. Phone: the colony in a phone browser (no GTA client)

Three ways to look after the colony from a phone (the third is in [`PHONE.md`](PHONE.md)):

| | You see | Needs | State |
|---|---|---|---|
| **1. The game on a PC** (section 4) | the 3D world, the colony UI over it | GTA + MTA client on a PC | never run in a real client |
| **2. Phone companion** (this section) | the same colony UI, its map is the 2D tactical map; **live from the real MTA server** | a phone browser on your tailnet; **no GTA at all** | verified on the real 1.6 server with a mobile-emulated Chromium (`tools/phone_e2e.sh`); never on a physical phone |
| **3. Stream the PC** (Sunshine + Moonlight, [`PHONE.md`](PHONE.md)) | the real game picture | a Windows PC with GTA and Sunshine | not run (the host kit is research only) |

### Set it up (on appdev2, once)

1. **Update the resource and restart the server:** `git pull && bash mta/tools/install_server_linux.sh` (keeps your saves), then restart `mta-server64`.
2. **Allow the phone logins in the ACL:** `bash mta/tools/phone_acl.sh ~/mta-server/multitheftauto_linux_x64/mods/deathmatch/acl.xml` (idempotent, keeps a backup `acl.xml.bak-outbreak`), or paste the block below
   by hand. **Restart the server** (MTA reads `acl.xml` at start; there is no reload command).
3. **Create the accounts in the server console** (the tmux window): `addaccount phone <a long password>` and, if you want a login that can only look, `addaccount phoneview <another password>`.
   Change one with `chgpass phone <new password>`, remove it with `delaccount phone`. Other names: change the `user.phone` / `user.phoneview` objects in the two groups.
4. **On the phone** (it is on Tailscale): open **`http://<tailscale-ip>:22005/outbreak/`** (`tailscale ip -4` on appdev2; the HTTP port is the same TCP 22005 the game download uses, section 3). The browser asks
   for the user name and password (HTTP Basic). The trailing slash matters: `/outbreak/` is the resource's default page; `/outbreak/phone/` does not exist (checked on the real server).
5. **Add it to the home screen:** iOS Safari: Share, then *Add to Home Screen*; Android Chrome: menu, then *Add to Home screen* / *Install app*. The page has a manifest and icons (`ui/phone-manifest.json`,
   `ui/phone-icon-*.png`) and starts full-screen. **Unverified:** whether iOS keeps the Basic login in a home-screen app (if it asks again every time, use a Safari tab or bookmark instead).
6. **Optional HTTPS** (a second layer on top of Tailscale's own encryption, and no `http://` warning): on appdev2 `tailscale serve --bg 22005`, then open `https://<machine>.<tailnet>.ts.net/outbreak/`
   (`tailscale serve --help` shows the exact syntax of your version; unverified here; the Windows version of the same idea is `hostkit/windows/03-tailscale-serve.ps1`). The login header passes through the proxy.

ACL block (`tools/acl_phone_snippet.xml`; `tests/readme_test.lua` fails if this copy and the file differ):

```xml
	<!-- Outbreak phone companion (mta/README.md "Phone"). Two logins: `phone` may look and give orders, `phoneview` may only look. Add the accounts you create with
	     `addaccount <name> <password>` to the two groups below (rename the user.* objects). MTA checks resource.outbreak.http itself (HTTP login + page + API); server/phone.lua
	     checks phone_view / phone_control for what an account may do. Everyone else keeps the default (general.http denied): they get a 401. -->
	<group name="OutbreakPhone">
		<acl name="OutbreakPhone"/>
		<object name="user.phone"/>
	</group>
	<group name="OutbreakPhoneView">
		<acl name="OutbreakPhoneView"/>
		<object name="user.phoneview"/>
	</group>
	<acl name="OutbreakPhone">
		<right name="resource.outbreak.http" access="true"/>
		<right name="resource.outbreak.phone_view" access="true"/>
		<right name="resource.outbreak.phone_control" access="true"/>
	</acl>
	<acl name="OutbreakPhoneView">
		<right name="resource.outbreak.http" access="true"/>
		<right name="resource.outbreak.phone_view" access="true"/>
	</acl>
```

### What the phone can and cannot do, compared with the in-game UI

| | In game (section 4) | Phone companion |
|---|---|---|
| Colonist roster, card (needs, mood, skills, gear, health), work priorities, draft, schedules | yes | yes: the same code (`ui/`), laid out by `css/mobile.css` + `js/touch.js` as bottom sheets / side drawers |
| Build (ghost placement), stockpile zones, expeditions, Director, inventory moves, save / load / new colony, speed, pause | yes | yes: they go through the same server handlers as the in-game page |
| The map | the 3D world (client camera, peds) | the 2D tactical map: pinch to zoom, drag to pan, **Select** (drag a box), **Order** (then tap the destination), long-press = right-click menu |
| The survival HUD (vitals, compass), the player ped, noise from your own gunshots, camera, sound | yes | **no**: the phone has no player; those belong to the GTA client |
| Keyboard shortcuts | yes | no (taps and long-presses; the Menu's *Controls* tab lists them) |
| Works while nobody is connected in GTA | the sim runs on the server regardless | yes: that is the point; the phone and the GTA client can be connected together, each keeps its **own selection and open container** |

Not a goal: seeing ped movement. The sim is authoritative on the server, but colonists only *walk* in the world where a GTA client drives the peds (section 1); on the phone you see the sim's own positions.

### Security and privacy

* **Who gets in.** MTA's HTTP server does the login (HTTP Basic against MTA accounts) and the ACL check: only accounts with the right `resource.outbreak.http` may open the page or call the API; everyone else, including a
  wrong password and an account that exists but has no such right, gets **401** (the server's default denies `general.http` for everyone; checked on the real server). The right is for *this resource only*: it does not
  give access to any other resource's pages. Inside the call `server/phone.lua` then checks `resource.outbreak.phone_control` (orders, UI actions, save / load / new colony) or `resource.outbreak.phone_view`
  (look only). A guest account is refused whatever the ACL says. `debug_*` UI actions are refused over the phone unless `debug=1`.
* **Cross-site requests.** Basic credentials are sent by the browser automatically, so a malicious web page could try to post to the API. Every call needs the custom header `X-Outbreak-Phone: 1` (a cross-site page cannot
  send one without a CORS preflight the server never answers) and an `Origin`, if present, must equal the `Host`.
* **Plain HTTP carries the password in every request (base64).** Inside your tailnet WireGuard encrypts it; do not open TCP 22005 to the internet with these accounts, or put `tailscale serve` HTTPS in front. Use
  long, unique passwords (MTA throttles wrong passwords and has an HTTP flood guard; neither replaces that). **Do not put a phone account in the `Admin` group** (MTA's authorized-serial protection would then
  also apply, and an admin login on a phone is the wrong risk).
* **What MTA serves without a login, and what we did about it.** MTA's HTTP server hands out **every `<file>` listed in `meta.xml` to anyone who can reach the port, without a login, even with `download="false"`**
  (found on the real server). That is how GTA clients download the UI and client scripts, so those stay public: they hold no secrets. The server-only code (`server/`, `sim/`, `data/`, the host and view
  modules, saves) used to be listed with `download="false"` and was therefore public too; it is **no longer listed** (the server reads unlisted files with `fileOpen`, verified) and answers 404 over HTTP.
  `tools/phone_e2e.sh` asserts both. The phone page itself (`ui/phone.html`, an `<html>` item) and the API are behind the login.
* **Nothing leaves the box.** No CDN, no analytics, no third-party request. The page keeps a random session id in `sessionStorage` and your UI settings in `localStorage`; the server keeps sessions in memory only
  (expire after `phone_session_s`, at most `phone_sessions`). `phone=0` switches the API off. `save` / `load` / `new_game` from a phone are logged with the account name; `/outbreak_phone` shows the counters and the refusals.
* **Reachable from the phone = everything in the colony.** A control login can start a new colony over the current one (the Menu's *Start new colony*), exactly like the in-game owner. Use `phoneview` for a login you
  would hand to someone else.

### How it works (short)

`ui/phone.html` is generated from the vanilla `index.html` by `tools/sync_ui.sh` (the vanilla files stay byte-identical): the same page with `ui/phone-bridge.js` in front of `js/core.js` and everything inlined (MTA's HTTP
server labels `.css` as `application/octet-stream`, which browsers refuse as a stylesheet). The bridge implements the page's host contract over **HTTP polling**: the page's `fetch('https://outbreak/<name>')` callbacks
(`order`, `ui`, `place` commit) become `POST /outbreak/call/phoneApi` with a JSON array body `["cb", sid, name, data]`, one at a time and in order; the server's answer carries the same `{action, data}` messages the NUI
gets (`boot`, `mode`, `catalog`, `state` = the view model of `shared/view.lua`, `events` = the sim's OUT events, `inventory` / `summary` on request) which the bridge dispatches as `message` events. MTA's call interface
answers synchronously (a request cannot be held open), so the page polls: about every 500 ms while visible, every 5 s while hidden, back-off after errors, an immediate poll after a callback. `server/phone.lua` keeps a ring
buffer of the OUT events (filled in `Net.send`, before the owner check, so no GTA client is needed), computes each phone's `state` itself (so a phone's selected colonist never moves the owner's), and sends orders to the SAME
functions the in-game page's remote events use (`Net.do_order`, `Net.do_ui`), each caller with its own flood bucket.

| URL (`http://<host>:22005`) | Login | What |
|---|---|---|
| `/outbreak/` | yes (`resource.outbreak.http`) | the phone page (default `<html>` item) |
| `POST /outbreak/call/phoneApi` | yes + `phone_view` / `phone_control` + header | `["ready", sid]`, `["poll", sid, seq, gen]`, `["cb", sid, name, data]`, `["status", sid]` |
| `/outbreak/ui/js/*.js`, `css/*.css`, `fonts/*`, `phone-*.png`, `phone-manifest.json` | no (client files) | public like every client file of every MTA resource |
| `/outbreak/server/*`, `sim/*`, `data/*`, `shared/host.lua`, `save/*`, `meta.xml` | n/a | 404 |

Tests: `tests/phone_test.lua` (server half on the mock: rights, messages, same handlers, guards, 20 tests), `preview/tests/mobile_test.mjs` (phone layout and touch flows), `tools/phone_e2e.sh` (the real server; section 9).
If it does not work: 401 = the account has no ACL group or you did not restart after `phone_acl.sh`; "switched off" = `phone=0`; a page without styling = an old resource copy (re-run the installer); `Connection flood` in the
server log = more than ~20 new TCP connections in a short time from one address (the page reuses one connection; a broken proxy that opens one per request does not).

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
| `phone` | 1 | the phone companion API (section 3a); 0 = `phoneApi` answers "switched off" |
| `phone_sessions` | 6 | phone pages kept at once (the least recently used one is evicted; it signs in again) |
| `phone_session_s` | 60 | a phone page that has not called for this many seconds is forgotten |
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
| `/outbreak_prio <colonist id> [work]` | what the **sim** holds as work priorities (the phone e2e reads a phone's change back with it) |
| `/outbreak_phone` | phone companion status: sessions (control / view), calls, polls, orders, refusals by reason, ring buffer |
| `/outbreak_selftest` | rerun the determinism self-test |
| `/outbreak_spawn [n] [walker\|runner\|brute\|screamer]` | **test hook**: create n zombies at the base through the real spawn path (never beyond `max_materialized` hostile peds) and print what the engine says about them (model, tag, syncer, health). The real-server smoke test uses it: a server with no client has no observer, so the sim never materializes a horde there |
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
	<right name="command.outbreak_prio" access="true"/>
	<right name="command.outbreak_phone" access="true"/>
	<right name="command.outbreak_selftest" access="true"/>
	<right name="command.outbreak_spawn" access="true"/>
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
  validates every incoming event; `peds.lua` is the only place that creates or destroys peds (tracked, tagged, capped, destroyed on stop; controller lookup and weapon re-give); `zombies.lua`, `raiders.lua`, `colonists.lua` are the brains
  (perception radii from TP-Advanced-Zombies, presets from RottenV, the chase / hit-alert rules from slothbot, see THIRD_PARTY.md); `buildings.lua` and `props.lua` own the objects; `world.lua` the clock, weather, team and the owner's body;
  `store.lua` the save backend; `commands.lua` the admin commands; `ground.lua` the height map.
* **Client** (`client/`): `ui.lua` the browser bridge; `camera.lua` colony camera and picking (`getWorldFromScreenPosition`, `processLineOfSight`, `getScreenFromWorldPosition`); `placement.lua` the translucent
  ghost; `noise.lua` gunshot / explosion / siren / sprint detection; `survival.lua` damage reports, sprint lock and limp; `driver.lua` the ped driver (slothbot's movement, chase, swing, shooting and stuck rules, stream-in and damage handling); `ground.lua`; `world.lua` HUD hiding, outage dimming, alert sounds; `props.lua` the E key.
* **Trust model** (`server/net.lua`): remote events exist only because they are registered with `addEvent(name, true)`; a handler requires `client` to be a real player (that value cannot be forged),
  `client == owner`, **and `source == resourceRoot`** (a spoofer controls `source` and could otherwise pick any element, for example one of our peds); payloads go through `shared/protocol.lua` sanitizers; token buckets
  limit orders, UI actions, hits and ground samples (`outbreak:hit` and `outbreak:stream` also require the ped to be one of ours); the browser-to-client event `outbreak:ui` is local-only (`addEvent(name, false)`) and accepted only from our own browser element. Tests spoof each of these.
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
* **Performance, from the mock (not from a GPU):** with 60 zombies and the colony view open the client makes about 5000 MTA function calls per second (the driver's control-state cache brought it down from about 10000) and the page
  receives about 170 KB of JavaScript pushes per 40 s. The page is paused when MTA is minimised (`setBrowserRenderingPaused`; the wiki warns the call has a low-RAM caveat). Frame rate, memory and CEF cost are unmeasured.

## 9. Tests and what the mocks cannot prove

```sh
mta/tests/run.sh                  # everything: copy checks, Lua suite on LuaJIT + Lua 5.4 (+ PUC Lua 5.1.5), function check, browser test, Lua replay of the browser's calls
mta/tests/run.sh --no-browser     # without Playwright
mta/tests/run.sh --with-sim       # also the sim's own suite and the FiveM adapter's suite
mta/tests/run.sh --with-server    # also the real-server smoke test (quick variant) and the phone e2e (about 45 s)
mta/tools/phone_e2e.sh            # the phone companion against the real MTA 1.6 server, curl + a mobile-emulated Chromium: see below
mta/tools/real_server_smoke.sh [--quick]   # the real MTA 1.6 server, headless: see below
mta/tools/list_private_blocks.sh  # the unlicensed (private use only) blocks
mta/tools/build_lua51.sh          # builds PUC-Rio Lua 5.1.5 (md5-checked) into ~/.cache/lua-5.1.5; then  LUA51=$HOME/.cache/lua-5.1.5/lua-5.1.5/src/lua mta/tests/run.sh
```

| Layer | Proves | Does **not** prove |
|---|---|---|
| `tests/mock_mta.lua` + `mock_natives.lua`: a fake MTA | the real server and client Lua run end to end on it: handshake, events with `addEvent(name, true)` and `client` / `source` semantics, spoofing rejected, timers, the file API, elements and destroy, peds that only move when streamed in and synced, collision-less server, a browser that follows the create / load / ready order; per-side function sets taken from the real source; strict globals; Lua 5.1 library set; leak, lifecycle, failure-injection and call-budget checks | that real MTA behaves like the mock: every mock rule comes from the wiki or source, so a wrong reading of the wiki is wrong in both |
| `tools/function_check.lua` | every global, function and event name the resource uses exists on the side that runs it, according to the real mtasa-blue definitions; no leaked globals; every remote event registered | argument order and types, return values, behaviour |
| LuaJIT, Lua 5.4 **and PUC Lua 5.1.5** (the interpreter MTA embeds) | identical results and sim hash; all 77 files compile as 5.1 (found the `\x` escape difference in a test) | MTA's builds of Lua (patches, 32-bit `long` on Windows) |
| `tests/ui_bridge_test.mjs` (Playwright, real Chromium) | the unchanged page loads from `http://mta/local/` using only files `meta.xml` ships, the bridge exists before `core.js`, clicks and keys become the right `mta.triggerEvent('outbreak:ui', name, json)` calls with simple argument types, the state / HUD / events the **real Lua client** pushed render, a priority click sends the right order, junk does not crash the page | that CEF in MTA provides `window.mta` identically, local-origin rules, focus, GPU use, frame rate |
| `tests/replay_ui_calls.lua` | those recorded browser calls, byte for byte, through `json_decode`, `client/ui.lua`, the server, the host and into the sim (c1's cook priority ends where the page showed) | the real transport |
| `tests/config_test.lua` | every prop model id exists and has the name we think in MTA's own editor name table (MIT, 14308 names); every animation block / name exists in MTA's freeroam animation list | that it looks right, has collision or plays |
| `tests/client_test.lua` driver tests | slothbot's rules pinned one by one: the swing timeline (fire at 0 / 800 / 1400 ms, still for 2000 ms, cycle 2300 ms), the stuck dice (1 in 7 give up, 2-3 jump, 4-7 turn; 1 in 13 on a path), the jump with a melee weapon (fists for 850 ms), the last-seen spot, per-weapon stop distance and bursts, stream-in (voice, weapon request), damage cancel and hit report | that the real engine moves a ped the way the mock does |
| `tests/peds_test.lua` | server side: tags, controllers (read, never forced), `outbreak:hit` / `outbreak:stream` with spoofing, the weapon re-give cap, `/outbreak_spawn` under the caps | the real ped pool |
| `tools/real_server_smoke.sh` | on the real MTA 1.6 server: the resource loads (`Resources: 1 loaded, 0 failed`), the self-test hash matches, audits pass, 40 + 20 test zombies are real peds with a config model, the tag and no forced syncer, the caps hold (60 hostile, 62 ped elements), `restart outbreak` leaves none and loads the save, no ERROR / WARNING line | anything that needs a client |
| `tests/phone_test.lua` | the phone companion's server half on the mock: the login rights (guest, no right, view-only, control), the CSRF header and Origin checks, exactly the NUI's messages with no GTA client connected, orders reaching the same `host:on_order` as the owner's remote event, per-phone selection and inventory, the flood bucket, resync after a new game / a ring overflow / eviction, `phone=0`, the console commands | MTA's HTTP server, Basic auth and the ACL file (that is `phone_e2e.sh`) |
| `preview/tests/mobile_test.mjs` | the **phone / tablet layout** (390x844 and 844x390 at DPR 3, 820x1180) in Chromium mobile emulation with real CDP touch events: nothing scrolls, every control is at least 44 px, type is at least 10 px, safe-area insets, and the touch flows (select, order, drag-select, priority cell, blueprint ghost + Place / Cancel, Director, pan + pinch, long-press menus); the desktop layout is checked to be untouched | a physical phone's browser chrome, touch latency, haptics |
| `tools/phone_e2e.sh` | on the real MTA 1.6 server: the login (401 without / wrong password / account without the ACL right), the page and the API with curl, a mobile-emulated Chromium with `httpCredentials` that renders the live colony and changes a priority and a blueprint by touch, compared with `outbreak_status` / `outbreak_hash` / `outbreak_prio` in the server console; the sim and server code answer 404; no ERROR / WARNING line; no flood | a physical phone, iOS Safari / Firefox, Tailscale |
| `tests/readme_test.lua` | README and THIRD_PARTY.md match the code: every command, ACL right, setting, event, key and MTA function is documented, the budget numbers are the configured ones, every `borrowed:` mark has a row | that the prose is right |

**What a mock can never prove:** that the engine agrees with the wiki (ped pool behaviour, whether a client really moves a ped with `setPedControlState`, collision, streaming distances); animation names and how
skins and objects look; how fast any of it runs; CEF focus, cursor and transparency; the timing and ordering of the real network; anti-cheat; timer precision; whether MTA's script-timeout watchdog trips.

### The phone e2e (`mta/tools/phone_e2e.sh [dest]`)

Same install-and-run harness as the smoke test (own directory `~/mta-phone`, own ports `MTA_PHONE_PORT` 22983 / 22985, wipes only its saves and accounts), plus `tools/phone_acl.sh`, accounts made with `addaccount` on the
console, and `<http_dos_exclude>127.0.0.1</http_dos_exclude>` for curl only: the browser uses `127.0.0.2`, which is **not** excluded, so the server's default HTTP flood guard is in force for the real polling (it never
fires). The sim is paused (`outbreak_speed 0`) so the hash cannot move. The scenario: curl (401s, the page, the API, header / Origin refusals, a look-only account's refusals, what is public), then Playwright
(portrait: the UI's colonist count, day, clock and the state hash equal the console's; a priority tapped in the Priorities screen; a wall placed with the ghost and *Place*; the Director; landscape; the look-only login
taps a priority cell and is told it is read-only; a browser without a login gets 401), then the console again (`outbreak_prio` shows the new level, `outbreak_status` one more building, the hash changed and equals the
one the phone sees, the look-only target unchanged) and an order from curl. Screenshots of the live phone UI: `screenshots/mobile/live-*.png`. About 45 s; exit 0 / 1 / 2 like the smoke test.

### The real-server smoke test (the 30-second check)

`mta/tools/real_server_smoke.sh [dest] [--quick]` installs (or reuses) the official MTA:SA 1.6 Linux server through `tools/install_server_linux.sh` (`MTA_SERVER_TGZ` / `MTA_BASECONFIG_TGZ` point at tarballs
you already have), gives it its own ports (`MTA_SMOKE_PORT`, default 22993 / 22995: it never collides with your real server) and its own directory (default `~/mta-smoke`; it wipes only ITS saves), starts
`./mta-server64 -n` headless and types this scenario on the console: `outbreak_status`, `outbreak_autopilot on`, `outbreak_speed 16`, wait, `outbreak_status`, `outbreak_hash`, `outbreak_audit`, `outbreak_peds`,
`outbreak_horde 30 120`, `outbreak_spawn 40`, `outbreak_spawn 200`, `outbreak_peds`, `outbreak_ff 1440`, `outbreak_status`, `outbreak_audit`, `outbreak_save`, `restart outbreak`, `outbreak_peds`,
`outbreak_status`, `outbreak_audit`, `shutdown`. It then asserts from the server's own log (its stdout is block-buffered, so the script polls `logs/server.log`) and prints PASS or FAIL per check:
`Resources: 1 loaded, 0 failed`; `selftest OK` with the recorded hash at start and after the restart; `audit OK` at least twice and never FAILED; the sim clock advanced; the 40 test zombies are real ped
elements with a model from the config, the `ob` tag and no forced syncer; `outbreak_spawn 200` stops at `max_materialized` (60 hostile, 62 ped elements); after `restart outbreak` zero zombies and only the
colonists' peds (nothing leaked) and the saved day loaded again; no ERROR / WARNING / failed / abort / timeout line (the `owner_email_address` warning is ignored); the server exits with status 0.
Exit status 0 = PASS, 1 = a check failed (the end of the log is printed), 2 = it could not run. Full scenario about 50 s, `--quick` about 30 s.

**Run it on the server box (appdev2) after every `git pull`:** `bash mta/tools/real_server_smoke.sh --quick`. It cannot show anything that needs a client (peds walking, streaming, the CEF page): section 10.

## 10. Unverified until it runs in the real game

A checklist for the first session on the PC. Each line says what to look at and which knob to turn.

1. **Does `createPed` + client `setPedControlState` actually walk the peds?** (the whole zombie design; the real server already proved the server half: peds are created, tagged, capped and cleaned up).
   Watch `/outbreak_peds` (`syncers N`: how many of our peds MTA has a syncer for; 0 with nobody connected is normal) and `/outbreak_client` (`drive intents` / `driven` / `stuck`). The driver does **not** check
   `isElementSyncer` (slothbot does not): if peds stand still with `driven` > 0, MTA has given the ped to nobody (not streamed in, or out of the ~100 m syncing range): keep the player within that range.
   The server never forces a syncer; if you want one, `setElementSyncer(ped, owner, true)` in `Peds.create` is the one-line experiment.
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
12. **`meta.xml`:** `type="gamemode"` (it may stop another gamemode), `min_mta_version 1.5.8`, the server-only files are deliberately **not listed** (MTA's HTTP server serves every listed `<file>` without a login; unlisted files are still readable with `fileOpen`, verified), and the client downloads 38 UI files and 19 Lua modules.
13. **Numbers:** the 32-bit `long` risk (`selftest` reports it at start), memory and frame time with 60 peds, the ped pool (`engineGetPoolUsedCapacity("ped")` is client-only and not used yet; a client-side guard would be the next safety).
14. **ACL / owner logic** with a second player, `owner_name`, reconnects.
15. **The ported slothbot behaviours in the real engine:** `isLineOfSightClear` with those flags against GTA's world (a zombie behind a fence should run to where it last saw you, then give up); the melee swing
    (`fire` with fists: do they jab, and does the cancelled `onClientPedDamage` / `onClientPlayerDamage` really stop the engine's own damage?); `setPedVoice(ped, "PED_TYPE_DISABLED", "")` accepted;
    `onClientElementStreamIn` seeing the `ob` / `obw` element data of a freshly streamed ped (if it does not, no voice mute and no weapon re-give); a pistol ped standing at 14 m and firing in 2 to 5 s bursts;
    the jump with fists swapped in (slots 1 and 7); the `walk` control for slow zombies (slothbot only uses `forwards` and `sprint`). The 600 ms / 1 m stuck test was tuned for jogging zombies (walkers use 0.35 of it).
16. **Graphics** items in section 8 marked unconfirmed (ENB, ReShade, SilentPatch / SkyGfx, texture packs).
17. **The phone companion on a real phone** (section 3a): iOS Safari and Firefox (only Chromium is tested; the page does not depend on any MIME type because everything is inlined), whether iOS keeps the Basic login in a
    home-screen app, the browser's URL-bar and safe-area behaviour (the CSS honours `env(safe-area-inset-*)` and the layout test overrides them), touch latency, battery use of 500 ms polling, `tailscale serve` in front of MTA's
    HTTP port, and the install prompt. The server side, the login and the touch flows are verified on the real 1.6 server with a mobile-emulated Chromium.

## 11. Every MTA function used

Generated by `lua5.4 mta/tools/function_check.lua --markdown` from the code itself (`tests/readme_test.lua` fails if this table and the code disagree). **117** distinct functions;
all verified to exist on the listed side in the mtasa-blue definitions. "both" means the function exists in both the client and server definitions.

<!-- functions:begin (generated by tools/function_check.lua --markdown) -->
| function | side | first used in |
|---|---|---|
| `addCommandHandler` | both | client/main.lua |
| `addEvent` | both | client/driver.lua |
| `addEventHandler` | both | client/ctx.lua |
| `bindKey` | client | client/main.lua |
| `cancelEvent` | client | client/driver.lua |
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
| `getAccountName` | server | server/phone.lua |
| `getCameraMatrix` | client | client/main.lua |
| `getControlState` | client | client/noise.lua |
| `getElementData` | both | client/colonists_view.lua |
| `getElementHealth` | server | server/colonists.lua |
| `getElementModel` | server | server/commands.lua |
| `getElementPosition` | both | client/camera.lua |
| `getElementSyncer` | server | server/commands.lua |
| `getElementType` | both | client/driver.lua |
| `getElementVelocity` | client | client/noise.lua |
| `getElementsByType` | both | client/colonists_view.lua |
| `getGroundPosition` | client | client/camera.lua |
| `getMinuteDuration` | server | server/world.lua |
| `getPedMoveState` | client | client/noise.lua |
| `getPedOccupiedVehicle` | client | client/noise.lua |
| `getPedWeapon` | client | client/driver.lua |
| `getPedWeaponSlot` | client | client/driver.lua |
| `getPlayerName` | server | server/commands.lua |
| `getResourceName` | both | client/ui.lua |
| `getScreenFromWorldPosition` | client | client/camera.lua |
| `getThisResource` | both | client/ui.lua |
| `getTickCount` | both | client/camera.lua |
| `getTime` | server | server/world.lua |
| `getValidPedModels` | server | server/peds.lua |
| `getVehicleSirensOn` | client | client/noise.lua |
| `getWeather` | server | server/world.lua |
| `getWorldFromScreenPosition` | client | client/camera.lua |
| `giveWeapon` | server | server/peds.lua |
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
| `isGuestAccount` | server | server/phone.lua |
| `isLineOfSightClear` | client | client/driver.lua |
| `isPedDead` | both | client/colonists_view.lua |
| `isPedDucked` | both | client/driver.lua |
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
| `setMinuteDuration` | server | server/world.lua |
| `setPedAimTarget` | client | client/driver.lua |
| `setPedAnimation` | server | server/colonists.lua |
| `setPedControlState` | client | client/driver.lua |
| `setPedRotation` | client | client/driver.lua |
| `setPedStat` | server | server/zombies.lua |
| `setPedVoice` | client | client/driver.lua |
| `setPedWalkingStyle` | both | client/survival.lua |
| `setPedWeaponSlot` | client | client/driver.lua |
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

Remote events (all `addEvent(name, true)`): `outbreak:ready`, `outbreak:in`, `outbreak:order`, `outbreak:ui_action`, `outbreak:ground`, `outbreak:stream`, `outbreak:hit` (client to server);
`outbreak:hello`, `outbreak:events`, `outbreak:state`, `outbreak:hud`, `outbreak:clock`, `outbreak:catalog`, `outbreak:uimsg`, `outbreak:drive` (server to client). Local only: `outbreak:ui` (browser to client).
Built-in events handled: `onResourceStart`, `onResourceStop`, `onPlayerQuit`, `onPlayerWasted`, `onPedWasted`, `onClientResourceStart`, `onClientResourceStop`, `onClientRender`, `onClientPreRender`, `onClientMinimize`,
`onClientRestore`, `onClientBrowserCreated`, `onClientBrowserDocumentReady`, `onClientPlayerDamage`, `onClientPedDamage`, `onClientElementStreamIn`, `onClientPlayerWeaponFire`, `onClientPedWeaponFire`, `onClientExplosion`, and in `ui_mode=dx` only `onClientClick`, `onClientCursorMove`, `onClientKey` (checked against `CClientGame.cpp` / `CGame.cpp`).

## 12. Deviations from the brief

* **Ped steering is on the client** (section 1): the brief had the server drive peds; the server cannot.
* **Buildings, sites and loot piles are server objects**, not client-side: the brief wrote client-side placement; only the blueprint **ghost** is client-side. A server object persists, streams to everyone and cannot be
  diverged by a client, and the server already owns the sim's building list.
* **`outbreak:uimsg` replaces the FiveM `ui` event name** for server-to-client UI results, because `outbreak:ui` is the browser-to-client local event in MTA.
* **Browser creation waits for the server's `hello`** (owner only), so the mode (`ui_mode`) is the server's choice and a second player never loads a UI.
* **The syncer is read, never forced.** The brief said "assign the syncer (`setElementSyncer`)"; slothbot (the proven code) only reads it (`getElementSyncer`) and MTA assigns peds to the nearest player itself.
  `setElementSyncer` is no longer used and the driver has no syncer check.
* **Zombie / ped-driver logic is ported from unlicensed upstream code** (slothbot), for private use only: see the warning at the top, `THIRD_PARTY.md` and `tools/list_private_blocks.sh`.
* **Rotating save slots and the checksum come from the shared host**, so the "versioned persistence" is the FiveM adapter's, on MTA's file or sqlite API.

## 13. Debugging and troubleshooting

* Server console / `/outbreak_status`, `/outbreak_peds`, `/outbreak_selftest`; client `/outbreak_client`. Set `debug=1` for payload-safety checks and `debug_*` UI actions.
* `F8` (MTA's debug console) shows `outputDebugString` lines tagged `[outbreak]`; Lua errors are caught per module and counted (not silent): the first and every 100th repeat is logged.
* The phone page does not load: section 3a ("If it does not work"); `/outbreak_phone` on the console shows what the server saw.
* No colony UI: the page is local; check the F8 console for a browser error and that all `ui/` files downloaded. A blank cursor but no page: try `ui_mode=dx`.
* `selftest FAILED`: the sim is not deterministic on MTA's Lua; saves still work on this machine but do not move them between runtimes until it is understood.
* On the server: `bash mta/tools/real_server_smoke.sh --quick` (about 30 s) tells you whether the resource still loads, passes its self-test and keeps its caps on the real MTA server; its log is `<dest>/smoke/server.log`.
* The mock harness is the debugger of first resort: reproduce with `tests/mock_mta.lua` (see `tests/lifecycle_test.lua` for how to script a session) before changing code.

## 14. Licences

**WARNING: never redistribute this resource.** It contains blocks ported from repositories with no licence (private use only, the owner's decision). `bash mta/tools/list_private_blocks.sh` lists every
`-- BORROWED-PRIVATE (unlicensed upstream, private use only): <repo>/<path>` block with file and line numbers and prints how to strip them; `--check` exits 1 while any exists. Strip them (and
re-run `mta/tests/run.sh`) before the resource is shared, published or deployed for anyone else.

See `THIRD_PARTY.md` (one row per borrowed block, the section "PRIVATE USE ONLY (no licence upstream)", what was read but not copied, and what could not be borrowed). GPL / LGPL material is used only under
the private-build rule of `BORROW-RULES.md`; re-clean before sharing.
