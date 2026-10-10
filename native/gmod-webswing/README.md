# Web Swing (gmod-webswing)

Web-swing traversal for Garry's Mod that works next to **SkateGM**: swing between buildings and props
with the **Web Shooters** SWEP, zip up ledges, dive, and drop onto the board with your speed. While you
skate you can fire the web from the board too.

Private build for the owner's PC (Windows, Garry's Mod **x86-64 branch**). Singleplayer and multiplayer
(listen or dedicated server; every player needs the addon).

> **Honest status: not run in Garry's Mod yet.** It was written and tested in a sandbox with no game.
> What was checked, and what was not, is spelled out in [What is verified](#what-is-verified). The
> [5-minute test](#5-minute-in-game-test) at the end is the first thing to do.

## Install

1. Copy this folder to `garrysmod/addons/gmod-webswing` (so that
   `garrysmod/addons/gmod-webswing/lua/autorun/webswing_init.lua` exists).
   Typical path: `C:\Program Files (x86)\Steam\steamapps\common\GarrysMod\garrysmod\addons\gmod-webswing`.
2. Start Garry's Mod (x86-64 branch). For a dedicated server put the same folder on the server too.
3. Open the console and run `ws_selftest`. It checks the stock assets, convars, your player model's
   hand, and SkateGM's API, and prints OK / MISSING lines.

You do not need to touch SkateGM. If it is not installed, Web Swing works on its own (foot mode only).

## Use it

Get the weapon: Spawn menu (Q) > Weapons > **Web Swing** > Web Shooters, or in singleplayer type
`ws_give` (admins can too). The SkateGM *gamemode* strips weapons: there you only have board mode below.

### Foot mode (holding the Web Shooters)

| Input | Does |
|---|---|
| Hold **Mouse 1** | Fire a web where you aim and swing. If the aim hits sky or is out of range, the **attach-point assist** looks in a cone for a building/prop surface up and ahead. The crosshair is green (aim hit), amber (assist found one) or dim red (nothing). |
| Release Mouse 1 | Let go with a **slingshot boost**, bigger the faster you are and the more the rope was off the vertical (peak around 45 degrees, none at the bottom or above the anchor). A web held under 0.3 s earns no boost and it is full from 0.7 s, so tap-spamming cannot ratchet your speed up. |
| **Mouse 2** | **Zip** to the web you hang on, or to the ledge/roof/wall you aim at, and vault over the edge. |
| Hold **R** (reload) in the air | **Dive**: fall fast, steer with W/A/S/D, release to pull up. |
| **Space** while attached | Let go and hop. |
| **Ctrl** (crouch) while attached | Reel the rope in (keeps most of your angular momentum). |
| **W** / **A D** while attached | Pump along the arc / steer sideways. |
| `ws_board` (bind it: `bind b ws_board`) | **Drop onto the SkateGM board.** Your swing speed is handed to the skater. `bind j skategm_toggle` does the same if you swung in the last 4 seconds. |

### Board mode (SkateGM Skater mode is on)

SkateGM runs the skater on your client and takes over the keyboard, so the SWEP cannot be used. Instead:

| Input | Does |
|---|---|
| Hold **left mouse button** | Fire the web from the board (aimed with the Skate camera's centre), swing, release for the boost. |
| **Right mouse button** | Zip to a ledge / the web. |
| Hold **G** | Dive (air only). Change with `ws_key_dive <key code>`. |
| Hold **V** | Reel in. Change with `ws_key_reel <key code>`. |
| Controller (experimental, `ws_board_pad 1`) | **Back/View** held = web, **left-stick click** held = reel. Skate 3 may also use Back. Steam Input has to stay off for SkateGM, so pad buttons cannot be remapped to the keys above. |

None of these keys are in SkateGM's keyboard layout (W A S D Space Shift F Z C I K U O Enter Q E arrows
Alt R L Ctrl Backspace); the mouse buttons are not used by SkateGM at all (the mouse only moves its free
camera). The web needs the skater **riding or in the air**: SkateGM's engine refuses velocity changes on
foot, in a bail and on grinds, so in those states the web lets go after a third of a second.
Others see your web (drawn from the skater's right hand).

### Console

`ws_status` (client), `ws_status_sv` (server), `ws_selftest`, `ws_release` (let go of everything),
`ws_give`, `ws_board`.

### Convars

Server (replicated, saved). `ws_enabled 0` switches everything off.

| Convar | Default | Meaning |
|---|---|---|
| `ws_enabled` | 1 | Master switch |
| `ws_max_dist` | 2800 | Web range, units |
| `ws_assist` | 1 | Attach-point assist on/off |
| `ws_assist_cone` | 48 | Assist half-width, degrees |
| `ws_boost` | 1 | Release boost multiplier (0 = none) |
| `ws_gravity_scale` | 1.6 | Gravity multiplier while on a web (1 = the map's) |
| `ws_pump` / `ws_steer` | 670 / 510 | Pump and steer acceleration, units/s^2 |
| `ws_reel_speed` / `ws_min_rope` | 590 / 120 | Reel rate and shortest rope |
| `ws_zip_speed` / `ws_zip_range` | 2200 / 3000 | Zip |
| `ws_dive_gravity` | 2440 | Extra pull while diving |
| `ws_max_speed` | 3400 | Speed cap (engine's `sv_maxvelocity` is 3500) |
| `ws_ground_hop` | 260 | Kick when firing from the ground |
| `ws_attach_players` | 0 | Webs may attach to players |
| `ws_prop_reaction` | 1 | The rope pulls on the prop it hangs on |
| `ws_no_fall_damage` | 1 | No fall damage for 5 s after web/zip/dive |
| `ws_snap_time` | 0.7 | Seconds a web may be blocked by the world before it snaps (0 = never) |
| `ws_sounds` | 1 | Sounds |
| `ws_board_enabled` | 1 | Board-mode webs allowed |
| `ws_board_hop` | 2.5 | m/s hop when firing from the board on the ground |
| `ws_board_wait` | 0.08 | Seconds between rope corrections in board mode (raise if the rope feels violent) |
| `ws_board_gain` | 0.85 | Share of the needed correction per pulse |
| `ws_board_lag` | 0.025 | Age of the skater's polled position, seconds |
| `ws_board_max_dv` | 700 | Largest single correction, units/s |

Client (saved): `ws_hud`, `ws_hud_board`, `ws_hud_speed`, `ws_rope_width`, `ws_rope_sag`,
`ws_rope_wobble`, `ws_board_mouse`, `ws_board_pad`, `ws_key_dive`, `ws_key_reel`, `ws_board_handoff`
(fraction of swing speed kept when dropping onto the board, 0 = off), `ws_debug`.

## How it composes with SkateGM

Read from `source/SkateGM` (version 7.01); these are the facts the design rests on.

* **There is no Move/SetupMove hook and no board entity.** The Skate 3 simulation is a Rust DLL
  (`gm_skategm`, global `skategm`) stepped on the client every frame
  (`addon/skategm/lua/autorun/client/skategm_cl.lua`, "Simulation pump" Think hook ~line 1406). The
  server only hides the real player, sets `MOVETYPE_NOCLIP`, and moves it with `SetPos` from the
  client's `skategm_pos` messages (`lua/autorun/server/skategm_sv.lua`: `Enter()`, line 47;
  `skategm_pos`, line 91).
* While skating, SkateGM's `CreateMove` clears the usercmd's buttons and movement (`skategm_cl.lua`
  line 447) and its `PlayerBindPress` hook swallows every bind except a short list
  (`lua/skategm/cl_water.lua` lines 353-362). So the SWEP, `+attack`, and `+commands` cannot work on the
  board. Web Swing therefore **polls the mouse and two free keys directly** in board mode.
* The public client API (`SkateGM.API`, end of `skategm_cl.lua`, line 1894) is what board mode uses:
  `IsSkating`, `IsLoading`, `State`, `SkaterPos`, `Velocity`, `Tick`, `View`, `PoseOf`, `IsFrozen`,
  `StartSkating`, `CanSkate`, `LastError`, `Pad`, and `Launch(vel)`. `Launch` calls `skategm.Push`
  (`gm_skategm/src/lib.rs` ~line 1642), which adds velocity to the board and the skater **only while
  riding or in the air** (`engine/crates/skate-host/src/physics/bridge.rs` line 87: it checks the state
  names `PhysicsGround`, `SlideGround`, `RevertGround`, `Air`). It is asynchronous: the sim thread applies it
  and the next `Poll` shows it a frame or two later.
* Server side: `ply.SkateGM` (true while skating), `ply:GetNW2Bool("SkateGMSkating")`, the
  `SkateGMEnter` hook, `SkateGM.API.IsSkating(ply)`, and `ply.SkateGMHips` (the skater's last reported
  hips, used to sanity-check board webs).
* Optional internals used with a fallback if missing: `SkateGM.loadedScale`, `SkateGM.renderP` (the
  interpolated pose the skater is drawn with), `SkateGM.ToAbs/FromAbs` (infinite-map frame),
  `SkateGM.InputBlockWanted`, `SKATEGM_UI.open`.

What Web Swing does about it (`lua/webswing/skategm_compat.lua`):

* **Detection**: `rawget(_G, "SkateGM").API`, re-evaluated on every call (load order is not guaranteed).
  Not installed means every board entry point returns immediately.
* **Foot mode stays out of the way** while skating (`IsSkating`): it never touches the movedata of the
  hidden noclipping player, and `SkateGMEnter` releases a running foot web. Nothing is applied twice:
  foot mode only runs for non-skaters, board mode only for skaters.
* **Board physics vs the rope** is a control problem, because `Launch` is asynchronous and the pose you
  read is old. A rope that corrects what it sees every frame corrects the same excess again and again
  before the first push shows up; the mock test reproduced exactly that with the first version of this code
  (repeated unseen ~600 u/s pushes, speed 780 -> 2360 u/s). So the rope works in **pulses with one push in flight**: nothing is pushed until
  `ws_board_wait` (and at least 2.5 frames, and 2 engine ticks) after the last push; each pulse asks for
  the velocity that keeps the skater inside the rope until the next pulse can act, from a position
  extrapolated by the pose's age; it applies a fraction (`ws_board_gain`) capped at `ws_board_max_dv`;
  and a skater more than 15% over `ws_max_speed` has the web cut. Corrections only remove outward speed,
  so a wrong latency makes the rope bounce, not launch you. The rope is therefore *soft* (about 12
  pulses a second) compared with foot mode.
* **Drop onto the board**: on any start of Skater mode within 4 seconds of using a web, the swing's
  velocity is remembered and handed to the skater with `Launch` as soon as the engine accepts it (it
  retries for 2.5 s; it cannot while the skater is still standing up).
* **Never breaks SkateGM**: every hook of this addon runs under `pcall` (an error in a GMod hook stops
  every other hook of that event). If anything in board mode throws, or the API lacks `Launch`, board mode
  switches itself off once with one console line (`ws_status` shows why).

## How the tricky parts work

* **Prediction and jitter.** The rope is applied in the predicted `SetupMove` hook on the server (every
  usercmd) and on the client (the local player's predicted usercmds), with the same buttons and view angles,
  so both realms compute the same velocity: no teleporting, no client-side position fixing, so no
  rubber-banding from the rope itself. The hook reads the movedata's origin/velocity, adds the forces,
  and asks `WebSwing.Math.constrain` for the velocity that lands the next position on the rope, then
  the engine does its normal gravity, air movement and collision. When the server's correction makes the
  client replay commands, state changes (timers, rope length, attach, release) only happen on
  `IsFirstTimePredicted()`; replays just re-apply the forces. The client's predicted web is compared with
  the server's (NW2 vars); a mismatch only counts after `0.3 s + 2 x ping`, then the server wins. The
  local web is timed on the frame clock so it leaves the hand the instant you click. In singleplayer, where
  the client may not predict, the client draws the server's state.
* **The rope maths** (`sh_swing.lua`) is position-based and, importantly, corrects **along the current
  rope direction**: pulling along the predicted direction instead leans against the motion and loses about
  1% of the swing's energy a second at 66 Hz. Along the current direction the drift is second order in dt
  (0.0095% over 20 s in the test; it falls 4x when dt halves).
* **Ground friction while attached.** Source applies friction while `FL_ONGROUND`. Firing from the floor
  kicks you up (`ws_ground_hop`); while the rope is working and you touch the floor with speed, an upward
  velocity of 160 keeps you off it (the engine treats z velocity above 140 as leaving the ground).
* **Early-outs** (`EnvOK`): dead, not `MOVETYPE_WALK` (noclip, ladder, observer...), in a vehicle, in
  water (2 or more), frozen, or the skater of SkateGM: no web starts and a running one is dropped.
* **Death, respawn, holster, strip.** `PlayerDeath`, `PlayerSilentDeath`, `PlayerSpawn`,
  `PlayerDisconnected` clear the state and what other clients see; the SWEP's `Holster`, `OnRemove`,
  `OnDrop` do too, and the tick itself drops the web as soon as the Web Shooters are not the active weapon
  (SkateGM puts weapons away with `SetActiveWeapon(NULL)`, which may skip `Holster`).
* **Props and NPCs.** The anchor is stored in the entity's **local space** (`WorldToLocal`) and
  re-evaluated every tick (`LocalToWorld`), so a moving prop carries the rope; if the entity is removed the
  server drops the web. Clients that cannot see the entity keep the last known point and obey the server.
  Other clients draw from the NW2 entity + local point. Static props count as world.
* **Multiplayer ownership.** The server is authoritative (its own predicted run is the truth); anchors are
  never on players unless `ws_attach_players 1`; the rope's pull on a physics prop is a server-side
  impulse opposite to the one the rope gave you, capped by the prop's mass, never applied to players/NPCs,
  and skipped if a prop-protection addon exposing `CPPICanPhysgun` says you could not physgun it. Board webs are
  reported by the client (SkateGM simulates it) and the server only checks that the claim is finite,
  rate-limited (30/s), from a real skater, near the skater's last reported hips, and expires it if the
  client goes quiet for 1.6 s or stops skating.
* **Hot path.** `SetupMove` returns after three cheap calls for anyone not holding the SWEP and not on a
  web; traces reuse one options table; the math takes and returns plain numbers.

## Stock assets used (nothing is shipped)

View model `models/weapons/c_arms.mdl` (the stock Fists hands; no world model), sequence `fists_draw`;
materials `cable/rope`, `sprites/light_glow02_add`; sounds `weapons/slam/throw.wav`,
`weapons/crossbow/hit1.wav`, `weapons/crossbow/fire1.wav`, `ambient/wind/windgust.wav`,
`physics/metal/metal_solid_impact_soft1.wav`; player-model attachment `anim_attachment_RH` / bone
`ValveBiped.Bip01_R_Hand` for where the rope leaves the hand. `ws_selftest` checks they exist; a missing
sound is just silent.

## Known limits

* Board webs only work while the skater is riding or in the air; no rope on foot, in a bail or on a grind.
* Board rope is soft and tuned for up to about 80 ms between `Launch` and seeing it in the pose. Beyond that
  (the mock at 100-150 ms) it stretches 3-6% and can add speed (700 -> 1300 u/s, bounded by the runaway
  guard). Raise `ws_board_wait` if it feels violent.
* `skategm_world_scale` other than 1 is untested (the rope uses the engine's map units, so it should hold).
* Infinite maps (InfMap): anchors are converted with `SkateGM.ToAbs/FromAbs` for the network only; untested.
* The rope does not wrap around corners (it snaps if the world blocks it for `ws_snap_time`). No wall-run.
* Foot mode is not available in the SkateGM gamemode (it gives no weapons); use board mode there.
* Aim in board mode is the screen centre of SkateGM's camera.
* `ws_` convars could collide with another addon using the same prefix.

## 5-minute in-game test

Do these in order on a flat map with some tall buildings (`gm_construct` or `gm_bigcity`). Console first:
`ws_selftest` (everything should be OK), `developer 0`.

1. **Foot, attach and swing.** `ws_give`. Aim at a building 30 degrees up, hold Mouse 1: a white rope flies
   to the wall, you swing, the crosshair was green. No rubber-banding. Let go on the up-swing: you shoot
   out faster.
2. **Assist.** Look at the sky above a building ahead and click: amber crosshair, the web should still find
   a wall or roof ahead of you.
3. **Jump / reel / pump.** While swinging: Space hops off; Ctrl shortens the rope; W speeds the arc.
4. **Zip.** Aim at a wall just under a roof edge, right-click: you fly up and hop over the edge.
5. **Dive.** Jump off a roof, hold R, then let go: you plunge, then pull up.
6. **Props.** Spawn a barrel, web it from a distance and walk away: the rope follows it and drags it
   slightly. Delete the barrel: the web drops.
7. **Safety.** Swing, then switch weapon (rope drops), swing, `kill` (rope drops after respawn), swing into
   water (drops), noclip (drops).
8. **SkateGM board.** `bind b ws_board`, swing, press B near the ground: you land on the board with
   speed. Then hold the left mouse button on the board while riding or airborne, aiming at a building:
   the rope should hold you in an arc and release with a boost. If it jerks or gains speed, run
   `ws_board_wait 0.12` and `ws_board_gain 0.6`.
9. **Multiplayer (if you have a second client).** Both see each other's ropes, including from the board.
10. `ws_status` and `ws_status_sv` print the state; `ws_debug 1` logs reconciliation.

## What is verified

Verified here (sandbox, no game):
* Every `.lua` file loads under LuaJIT 2.0, 2.1, Lua 5.1 (and the pure math under 5.2/5.3/5.4).
* `tests/run.lua`: 97 tests, all passing, see below.
* A hand audit of every GMod API call and its realm, from my knowledge of the GMod API (there was no
  wiki access in the sandbox, so a wrong function name or realm is still possible).

NOT verified (needs the game): all real engine behaviour, the real SkateGM, networking, feel, stock asset
names, rendering. The mock is a sandbox, not Garry's Mod.

### Running the tests

```
luajit tests/run.lua            (any cwd; also lua5.1, or SkateGM's harness\win\luajit.exe tests\run.lua)
luajit tests/run.lua swing      (only the pure maths)
```

* `tests/swing_test.lua` tests `lua/webswing/sh_swing.lua` (pure maths, scalars only, no Vector needed):
  energy and angular momentum conserved by the rope, rope never longer than L, a rope with 1500 u/s^2 of
  engine noise stays within 0.5 unit, release boost monotonic in speed and shaped by the swing angle,
  assist picks the nearer higher surface (with and without the swing simulation), zip converges without
  overshoot (arrives in 0.15 / 0.92 / 1.38 s from 300 / 2000 / 3000 units), dive terminal speed, reel
  keeps angular momentum.
* `tests/glue_test.lua` loads the whole addon in a mock GMod (`tests/gmock.lua`: strict globals, hook/net/
  convar/trace mocks, Source-like movement integrator, mock SkateGM with latency) in the server and client
  realms: no leaked globals, hook ids, convars, attach/swing/release/zip/dive/jump/reel, server and
  client end in the same place, replay safety, early-outs, death/holster cleanup, props (local space,
  removal, reaction, CPPI), the SkateGM board mode across Launch latencies 0-8 ticks and 30/60/144 fps, the
  server relay and its checks, handoff, error isolation, drawing and HUD smoke tests, tap-spam limits,
  and two fuzz tests (8 seeds each, thousands of random inputs/states: no error, no NaN, speed bounded).

## Files

```
addon.json
lua/autorun/webswing_init.lua   loader, convars, tuning, net string, error guard
lua/weapons/weapon_webswing.lua the Web Shooters
lua/webswing/sh_swing.lua       pure maths (rope, assist, release, zip, dive)
lua/webswing/sh_core.lua        state, anchor finding, the predicted SetupMove hook
lua/webswing/sv_swing.lua       cleanup, fall damage, prop reaction, console
lua/webswing/cl_swing.lua       reconcile, rope drawing, hand position, ws_status/ws_selftest
lua/webswing/cl_hud.lua         crosshair, speed, tension bar
lua/webswing/skategm_compat.lua detection, server relay, board mode
tests/                          run.lua, tinytest.lua, gmock.lua, swing_test.lua, glue_test.lua
```
