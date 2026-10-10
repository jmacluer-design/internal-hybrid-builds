# Outbreak sim: adapter contract (API.md)

This is the interface between the game-agnostic simulation in `sim/` and whatever hosts it (the FiveM adapter, a test
harness, `bin/sim-run.lua`). The sim never calls the game. The host calls the sim, and everything the sim wants done
in the world comes back as **OUT events**; everything the game knows that the sim needs goes in as **IN events**.

Status: written against a mock only. Nothing here has run inside GTA V / FiveM. The test suite (`tests/`) parses this file and
checks it against the events the sim really emits and accepts (`tests/contract_test.lua`), so the field tables below cannot
silently drift from the code.

## 1. Conventions

* **Runtime**: plain Lua 5.1-semantics-compatible code, verified under LuaJIT 2.1 and Lua 5.4 (FiveM runs 5.4). No globals are created.
  Modules are loaded with `require("sim.world")`; the host must make `sim/` and `data/` reachable by `require`. Where there is no `package.path`
  (FiveM resources), `sim/bootstrap.lua` defines a `require` over a file reader:
  `local boot = load(LoadResourceFile(res, "sim/bootstrap.lua"), "@sim/bootstrap.lua")(); boot.install(function(p) return LoadResourceFile(res, p) end)`.
  `tests/loader_test.lua` loads the whole sim that way in a fresh process, with the standard search path disabled, and checks that it reproduces the normal run's state hash.
* **Positions** are plain tables `{x = number, y = number, z = number}` in *sim space* (base = origin, units are roughly metres).
  The adapter adds a fixed offset to convert to game coordinates (the `TUNING.base` / `TUNING.map` numbers are in sim space).
* **Time** is an integer number of game minutes since day 1 00:00 (`clock.day(t) = floor(t/1440)+1`). Every event carries `t`.
  The sim advances only when told: `world:tick(minutes)`. A new world starts on day 1 at 08:00.
* **Ids** are strings with a one-letter prefix: `c` colonist, `b` building, `h` horde, `r` raid group, `x` expedition, `k` caravan,
  `p` ground pile, `z` stockpile zone, `v` vehicle. Ids are never reused within a world.
* **Events are plain data and copies**: every event is a fresh table; the host may keep, mutate or discard them without affecting the sim.
* **No game handles in sim state.** The only host-owned field is `colonist.ref` (set with the `colonist_ref` IN event). It must be a
  serializable plain value (string/number/table of those); the sim stores it, saves it, and never looks inside.
* **Items** are identified by string ids from `data/items.lua` (`canned_beans`, `pistol`, `fuel_can` ...). Weights are integer grams.
  Item maps in events are `{ item_id = count }`.
* **Order of events**: `world:tick` and `world:handle` return arrays in emission order; timestamps never go backwards.
  Handle events in array order.

## 2. Driving the sim

```lua
local World = require("sim.world")
local save  = require("sim.save")

local w = World.new{ seed = 1234, profile = "escalating" }   -- "calm" | "escalating" | "chaos"
apply(w:flush_events())              -- setup events (colonist_joined, place_blueprint/construction_done for the starting base)

-- every game tick (or every N ms) the adapter forwards what happened, then advances sim time:
for _, ev in ipairs(inbox) do apply(w:handle(ev)) end        -- IN events; handle() returns OUT events
apply(w:tick(minutes))                                       -- OUT events for these game minutes (integer >= 0)

local blob = save.save(w)                 -- string; store in KVP / file
local w2, err = save.load(blob)           -- nil, "reason" on a damaged or too-new save
```

* `tick(n)` runs `n` one-minute steps (optionally split into larger `max_dt`-minute steps: `World.new{max_dt=}`, `w:set_max_dt(n)`,
  `save.load(blob, {max_dt = n})`; the step size is configuration, not saved state); call it with the real game minutes elapsed.
  Calling `tick(1)` once per in-game minute is the reference setup (0.1 ms per call on LuaJIT with 30 colonists, see `tests/bench.lua`).
* The sim is **authoritative for time and jobs**: colonist tasks complete after walking time + work time computed from the sim's own
  `walk_speed`. The adapter animates and may snap peds into place; it does not report task completion.
* The sim is **deterministic**: the same seed and the same sequence of `tick` / `handle` calls give the same state hash
  (`w:hash()`) on LuaJIT and Lua 5.4.
* `w.s` is the plain-data state (read it for UI). Do not write to it from the adapter; use `handle`.
* Helpers: `w:snapshot()` (one-table colony summary for HUDs: day, colonists, mood, food, wealth, alert, hordes, defense, power ...), `w:flush_events()` (events produced outside
  `tick`/`handle`, e.g. at construction), `w:hash()` (state identity, 16 hex chars), `w:audit()` (item-conservation check; `true` or `false, {problems = {...}}`; for debugging).
* A world is created with `World.new{seed, profile, colonists = n, ambient = n, max_dt = n, scenario = "default" | "empty"}`; `"empty"` has no colonists, zones or hordes (tests).

## 3. OUT events (sim -> game)

### OUT `colonist_joined`
A colonist exists. Emitted for every starting colonist (via `flush_events`) and for every arrival (refugees). Create / bind a ped.

| field | type | meaning |
|---|---|---|
| `id` | string | colonist id (`c1`) |
| `name` | string | display name |
| `pos` | pos | where to spawn the ped |
| `traits` | string[] | trait ids (`data/traits.lua`) |
| `start` | boolean | true for the starting roster, false for arrivals |

```lua
{ type = "colonist_joined", t = 480, id = "c1", name = 'Cleo "Ash"', pos = { x = 4.1, y = -3.0, z = 0 }, traits = { "iron_gut", "lucky" }, start = true }
```

### OUT `colonist_state`
Current stats of a colonist. Sent when something changed (at most one per 3 minutes per colonist) and as a 30-minute heartbeat. Drive the colony UI and ped health/animation from it. Incubating infections are **hidden**
(`infection` stays `"none"` until symptoms show).

| field | type | meaning |
|---|---|---|
| `id` | string | colonist id |
| `name` | string | display name |
| `state` | string | `idle`, `working`, `sleeping`, `guarding`, `drafted`, `downed`, `away` (on an expedition) |
| `job` | string? | current job kind (see `colonist_task`) |
| `hp` | number | current health |
| `hp_max` | number | maximum health |
| `hunger` | number | 0 (full) .. 100 (starving) |
| `thirst` | number | 0 .. 100 |
| `fatigue` | number | 0 .. 100 |
| `pain` | number | perceived pain 0 .. 100 |
| `bleeding` | number | hp lost per minute |
| `infection` | string | `none`, `symptomatic`, `terminal` |
| `mood` | number | 0 .. 100 |
| `mood_break` | string? | `refuse`, `binge` or `wander` while on a mental break |
| `downed` | boolean | cannot act; needs feeding / treatment |
| `drafted` | boolean | under direct player control |
| `maimed` | number | number of amputations |
| `pos` | pos | the sim's idea of where the colonist is |
| `weapon` | string? | best weapon item id carried |

```lua
{ type = "colonist_state", t = 612, id = "c2", name = "Rue", state = "working", job = "build", hp = 100, hp_max = 100, hunger = 31.5,
  thirst = 22.0, fatigue = 40.2, pain = 0, bleeding = 0, infection = "none", mood = 52.0, downed = false, drafted = false, maimed = 0,
  pos = { x = 12.0, y = 8.5, z = 0 }, weapon = "machete" }
```

### OUT `colonist_task`
A colonist starts a job or a new step of one. Walk the ped to `pos` and play something suitable for `kind` / `step`.
`kind = "idle"` means the colonist has nothing to do. The sim does not wait for the ped.

| field | type | meaning |
|---|---|---|
| `id` | string | colonist id |
| `kind` | string | `goto`, `haul`, `deliver`, `unload`, `build`, `repair`, `cook`, `craft`, `tend`, `medicate`, `amputate`, `feed`, `guard`, `scavenge`, `refuel`, `eat`, `drink`, `sleep`, `rest`, `binge`, `wander`, `draft`, `equip`, `idle` |
| `target` | table | `{kind, id}`: what it is about (`pile`, `building`, `colonist`, `post`, `expedition`, `bed`, `self`, `item`, `pos`) |
| `pos` | pos | where to be for this step |
| `step` | string? | the step action: `take_zone`, `pickup_pile`, `drop_zone`, `drop_site`, `build`, `repair`, `make`, `tend`, `medicate`, `amputate`, `feed_tank`, `feed_apply`, `guard`, `join`, `fuel`, `consume`, `drink_tank`, `sleep`, `stand`, `noop`, `binge_take`, `binge_eat`, `wander` |
| `class` | number | 0 idle, 1 ordinary work, 2 need (eat/drink/sleep), 3 urgent, 4 forced by the player |

```lua
{ type = "colonist_task", t = 700, id = "c3", kind = "haul", target = { kind = "pile", id = "p2" }, pos = { x = -10.0, y = 12.5, z = 0 }, step = "pickup_pile", class = 1 }
```

### OUT `colonist_died`
A colonist died. Kill / ragdoll the ped. If `turns` is true a `colonist_turned` event follows a few minutes later.

| field | type | meaning |
|---|---|---|
| `id` | string | colonist id |
| `name` | string | display name |
| `cause` | string | `zombies`, `bled_out`, `starved`, `dehydrated`, `infection`, `wounds`, or the `cause` string the adapter sent |
| `turns` | boolean | will reanimate |
| `pos` | pos | where they fell (belongings are in a ground pile there) |

```lua
{ type = "colonist_died", t = 3100, id = "c4", name = "Hale", cause = "infection", turns = true, pos = { x = 3.0, y = 4.0, z = 0 } }
```

### OUT `colonist_turned`
Informational: a dead infected colonist rose. The sim has already added a one-zombie horde (`src = "turned"`) at `pos`; it
materializes through the normal `spawn_horde` path. Do **not** spawn a second zombie for this event.

| field | type | meaning |
|---|---|---|
| `id` | string | the dead colonist's id |
| `name` | string | display name |
| `pos` | pos | where |

```lua
{ type = "colonist_turned", t = 3112, id = "c4", name = "Hale", pos = { x = 3.0, y = 4.0, z = 0 } }
```

### OUT `colonist_left`
A colonist is gone without dying (wandered off during an extreme mental break, or was separated on an expedition). Delete the ped.

| field | type | meaning |
|---|---|---|
| `id` | string | colonist id |
| `name` | string | display name |
| `why` | string | `wandered_off` or `lost_on_run` |

```lua
{ type = "colonist_left", t = 5000, id = "c2", name = "Rue", why = "wandered_off" }
```

### OUT `spawn_horde`
Turn (part of) an abstract horde into real zombie peds, because an observer (the player) is within `R_materialize`.
Spawn `count` peds with the composition `mix` near `pos` (outside the player's view if you can) and keep them associated with `id`.
A repeated event with the same `id` and `top_up = true` adds more peds to the same group. Report each death with
`ped_died{id = <horde id>, zkind = ...}`. At most `TUNING.horde.max_materialized` peds are ever requested at once (horde and raiders together).

| field | type | meaning |
|---|---|---|
| `id` | string | horde id (`h5`) |
| `cell` | table | `{x, y}` coarse grid cell of the horde |
| `pos` | pos | horde centre |
| `count` | number | peds to spawn now |
| `mix` | table | `{walker=, runner=, brute=, screamer=}` counts that sum to `count` |
| `heading` | table | `{x, y}` unit vector the group is drifting along |
| `top_up` | boolean | true when this adds to an already materialized group |

```lua
{ type = "spawn_horde", t = 1500, id = "h5", cell = { x = 14, y = 11 }, pos = { x = 410.2, y = -90.5, z = 0 }, count = 17,
  mix = { walker = 12, runner = 4, brute = 1 }, heading = { x = 0.92, y = 0.38 }, top_up = false }
```

### OUT `despawn_horde`
Remove the real peds of horde `id`: the player is beyond `R_dematerialize` (or the horde was removed). The survivors (`count`, `mix`)
live on abstractly; nothing is lost.

| field | type | meaning |
|---|---|---|
| `id` | string | horde id |
| `count` | number | peds that were alive in the world |
| `mix` | table | their composition |
| `reason` | string | `far` or `removed` |

```lua
{ type = "despawn_horde", t = 1560, id = "h5", count = 15, mix = { walker = 11, runner = 3, brute = 1 }, reason = "far" }
```

### OUT `spawn_raiders`
A raid group came within `R_materialize` of the player. Spawn `count` hostile armed peds of gang `faction` at `pos`, heading for `target`
(the base). Report deaths with `ped_died{id = <raid id>}`; when the last one dies the raid is repelled.

| field | type | meaning |
|---|---|---|
| `id` | string | raid id (`r2`) |
| `faction` | string | gang id (`rustjaw`, `hollow_choir`, `tallow`, `cinder`) |
| `name` | string | gang display name |
| `count` | number | raiders to spawn |
| `pos` | pos | spawn point |
| `target` | pos | where they are going (the base) |

```lua
{ type = "spawn_raiders", t = 9000, id = "r2", faction = "cinder", name = "Cinder Union", count = 9, pos = { x = 600.0, y = 0.0, z = 0 }, target = { x = 0, y = 0, z = 0 } }
```

### OUT `despawn_raiders`
Remove the real peds of raid `id` (player moved away, or the raid ended).

| field | type | meaning |
|---|---|---|
| `id` | string | raid id |
| `faction` | string | gang id |
| `count` | number | raiders that were alive in the world |
| `reason` | string | `far` or `removed` |

```lua
{ type = "despawn_raiders", t = 9100, id = "r2", faction = "cinder", count = 7, reason = "far" }
```

### OUT `place_blueprint`
A construction site was planned (by an order or the starting base). Show the ghost / site at `pos`.

| field | type | meaning |
|---|---|---|
| `id` | string | building id (`b7`) |
| `bp` | string | blueprint id (`wall`, `bed`, ...) |
| `pos` | pos | location |
| `materials` | table | `{item = n}` still to be delivered |
| `work` | number | work units to build (about minutes at average skill) |

```lua
{ type = "place_blueprint", t = 700, id = "b7", bp = "wall", pos = { x = 10.0, y = 23.0, z = 0 }, materials = { scrap_wood = 3, scrap_metal = 1, nails = 1 }, work = 30 }
```

### OUT `construction_progress`
Build progress passed 25 / 50 / 75 %.

| field | type | meaning |
|---|---|---|
| `id` | string | building id |
| `bp` | string | blueprint id |
| `pct` | number | 25, 50 or 75 |

```lua
{ type = "construction_progress", t = 720, id = "b7", bp = "wall", pct = 50 }
```

### OUT `construction_done`
The building is finished: replace the ghost with the real object.

| field | type | meaning |
|---|---|---|
| `id` | string | building id |
| `bp` | string | blueprint id |
| `pos` | pos | location |

```lua
{ type = "construction_done", t = 745, id = "b7", bp = "wall", pos = { x = 10.0, y = 23.0, z = 0 } }
```

### OUT `building_destroyed`
A finished building was destroyed (siege, storm). Remove / wreck the object.

| field | type | meaning |
|---|---|---|
| `id` | string | building id |
| `bp` | string | blueprint id |
| `pos` | pos | location |

```lua
{ type = "building_destroyed", t = 2200, id = "b7", bp = "wall", pos = { x = 10.0, y = 23.0, z = 0 } }
```

### OUT `set_power`
The power network changed (outage, generator on/off, brownout). Switch lights / props accordingly.

| field | type | meaning |
|---|---|---|
| `on` | boolean | any power at all |
| `supply` | number | watts available |
| `demand` | number | watts requested by enabled consumers |
| `mains` | boolean | the city grid is up |
| `buildings` | table[] | `{id, bp, powered}` for every consumer whose state just changed |

```lua
{ type = "set_power", t = 2000, on = false, supply = 0, demand = 150, mains = false, buildings = { { id = "b2", bp = "workbench", powered = false } } }
```

### OUT `set_water`
Water supply flipped between available and dry.

| field | type | meaning |
|---|---|---|
| `on` | boolean | water is available |
| `tank` | number | litres in the tank |
| `mains` | boolean | the city water is up |

```lua
{ type = "set_water", t = 2100, on = false, tank = 0.2, mains = false }
```

### OUT `weather`
Weather changed. `kind` is `clear`, `rain` or `storm`; `minutes` is the expected duration (0 for `clear`).

| field | type | meaning |
|---|---|---|
| `kind` | string | `clear`, `rain`, `storm` |
| `minutes` | number | duration |

```lua
{ type = "weather", t = 2300, kind = "storm", minutes = 180 }
```

### OUT `loot_spawn`
Items to put into the world. For `source = "container"` the `container` is the adapter's own ref (answer to `container_opened`): fill that
container with `items`. For `container = "pile:<id>"` spawn a physical pile / crate of those items at `pos` (expedition returns,
supply drops, trade goods); the pile's contents live in the sim and colonists will haul them to the stockpile.

| field | type | meaning |
|---|---|---|
| `container` | string | adapter ref, or `pile:<id>` (or `none` when nothing came back) |
| `items` | table | `{item = n}` |
| `source` | string | `container`, `expedition`, `supply_drop`, `trade` |
| `pos` | pos? | for `pile:` containers: where the pile is |
| `ctype` | string? | for `source = "container"`: the type you sent |
| `danger` | number? | for `source = "container"`: 1..5 district danger used for the roll |
| `expedition` | string? | for `source = "expedition"`: expedition id |
| `district` | string? | for `source = "expedition"` |
| `faction` | string? | for `source = "trade"` |

```lua
{ type = "loot_spawn", t = 1900, container = "fridge:77", items = { canned_beans = 3, water_bottle = 1 }, source = "container", ctype = "fridge", danger = 2 }
```

### OUT `container_contents`
Answer to re-opening an already generated container: what is left in it (no new roll).

| field | type | meaning |
|---|---|---|
| `container` | string | adapter ref |
| `items` | table | `{item = n}` currently inside |

```lua
{ type = "container_contents", t = 1950, container = "fridge:77", items = { water_bottle = 1 } }
```

### OUT `caravan`
A trade caravan arrived (`phase = "arrive"`) or left (`"leave"`). Place / remove the traders; trading is done with the `trade` order.

| field | type | meaning |
|---|---|---|
| `phase` | string | `arrive` or `leave` |
| `id` | string | caravan id (`k1`) |
| `faction` | string | faction id |
| `name` | string? | faction display name (arrive) |
| `leave_t` | number? | minute they depart (arrive) |
| `stock` | table? | `{item = n}` they bring (arrive) |
| `pos` | pos? | where they set up (arrive) |

```lua
{ type = "caravan", t = 4000, phase = "arrive", id = "k1", faction = "tallow", name = "Tallow Syndicate", leave_t = 4360, stock = { bandage = 3 }, pos = { x = 25.0, y = 25.0, z = 0 } }
```

### OUT `expedition`
Scavenging trip milestones. Abstract (no peds are required); use it for map markers and UI. The crew's `colonist_state.state` is `away` between
`depart` and `return`.

| field | type | meaning |
|---|---|---|
| `phase` | string | `depart`, `arrive`, `return`, `lost` |
| `id` | string | expedition id (`x1`) |
| `district` | string | district id (`data/districts.lua`) |
| `vehicle` | string? | vehicle id, empty for foot trips (depart) |
| `mode` | string? | `vehicle` or `foot` (depart) |
| `crew` | string[]? | colonist ids (depart, return) |
| `eta` | number? | minute they are expected back (depart) |
| `pos` | pos? | district centre (depart, arrive) |
| `loot` | table? | `{item = n}` brought home (return) |

```lua
{ type = "expedition", t = 800, phase = "depart", id = "x1", district = "orchard", vehicle = "v1", mode = "vehicle", crew = { "c1", "c3" }, eta = 880, pos = { x = 520, y = 300, z = 0 } }
```

### OUT `notify`
A line for the player's message log / toast.

| field | type | meaning |
|---|---|---|
| `level` | string | `info`, `good`, `warn`, `bad` |
| `text` | string | English text, no markup |

```lua
{ type = "notify", t = 900, level = "warn", text = "A horde of about 34 is moving toward the base." }
```

### OUT `play_alert`
Play a sound / UI sting.

| field | type | meaning |
|---|---|---|
| `kind` | string | `horde_near`, `raid_incoming`, `caravan`, `helicopter`, `supply_drop` |
| `faction` | string? | for `raid_incoming` and `caravan` |

```lua
{ type = "play_alert", t = 1400, kind = "raid_incoming", faction = "rustjaw" }
```

### OUT `director_log`
The storyteller fired an event (storyteller log panel). `cost` is the threat budget spent (0 for boons).

| field | type | meaning |
|---|---|---|
| `event` | string | `horde_wave`, `gang_raid`, `infection_outbreak`, `helicopter_flyover`, `power_outage`, `water_outage`, `storm`, `caravan`, `supply_drop`, `refugee_arrival` |
| `cat` | string | `threat`, `hazard`, `boon` |
| `cost` | number | budget points spent |
| `budget_before` | number | budget before |
| `budget_after` | number | budget after |
| `detail` | string | human-readable detail |
| `day` | number | in-game day |

```lua
{ type = "director_log", t = 3000, event = "horde_wave", cat = "threat", cost = 32.5, budget_before = 51.0, budget_after = 18.5, detail = "horde h9 size 28 from cell 3,40", day = 3 }
```

### OUT `day_start`
Midnight passed.

| field | type | meaning |
|---|---|---|
| `day` | number | the new day number |

```lua
{ type = "day_start", t = 1440, day = 2 }
```

### OUT `order_result`
Answer to every `order`. `ok = false` carries a machine-readable `reason`. Some orders add extra fields (listed under each order kind).

| field | type | meaning |
|---|---|---|
| `id` | string? | the order's `id` |
| `kind` | string? | the order's `kind` |
| `ok` | boolean | accepted |
| `reason` | string | `ok`, `clamped`, or an error such as `no_such_colonist`, `unknown_order`, `bad_target`, `prereq:workbench` |
| `level` | number? | priority orders: the level actually set |
| `count` | number? | draft orders: how many colonists changed |
| `building` | string? | place_blueprint: new building id |
| `expedition` | string? | expedition: new expedition id |
| `zone` | string? | zone_create: new zone id |
| `give_value` | number? | trade: value of what we gave |
| `take_value` | number? | trade: value of what we took |

```lua
{ type = "order_result", t = 600, id = "colony", kind = "place_blueprint", ok = true, reason = "ok", building = "b9" }
```

### OUT `item_result`
Answer to `item_moved`.

| field | type | meaning |
|---|---|---|
| `item` | string? | item id |
| `n` | number? | requested count |
| `ok` | boolean | something moved |
| `moved` | number | how many actually moved |
| `reason` | string? | `ok`, `bad_item`, `bad_location`, `nothing_moved` |

```lua
{ type = "item_result", t = 610, item = "canned_beans", n = 3, ok = true, moved = 3, reason = "ok" }
```

### OUT `game_over`
The last colonist is gone. Further ticks are safe but nothing can happen.

| field | type | meaning |
|---|---|---|
| `reason` | string | `all_colonists_lost` |
| `day` | number | day reached |

```lua
{ type = "game_over", t = 20000, reason = "all_colonists_lost", day = 14 }
```

### OUT `error`
An IN event was malformed or unknown. Never raised as a Lua error.

| field | type | meaning |
|---|---|---|
| `reason` | string | `bad_event` or `unknown_event` |
| `event` | string? | the offending `type` for `unknown_event` |

```lua
{ type = "error", t = 600, reason = "unknown_event", event = "teleport" }
```

## 4. IN events (game -> sim)

Send them with `world:handle(event)`; the return value is the array of OUT events they caused. Invalid fields never raise: they are
ignored or answered with `error` / `order_result{ok=false}`.

### IN `noise`
Something loud happened. Hordes whose position is within `loudness x TUNING.horde.noise_radius_per_loud` (gunshot about 110 gives a 330 unit radius)
start heading for it; materialized hordes are not moved by the sim (the game's own AI handles those).

| field | type | meaning |
|---|---|---|
| `pos` | pos | where |
| `loudness` | number | 1..400 (capped). Guide: footsteps 8, melee 20, vehicle 45, gunshot 110, shotgun 140, rifle 150, explosion 200 |
| `kind` | string? | label for the UI log |

```lua
{ type = "noise", pos = { x = 410.0, y = -95.0, z = 0 }, loudness = 110, kind = "gunshot" }
```

### IN `ped_damage`
A colonist took damage in the game. The sim turns it into a wound (bleeding, pain, bite infection chance) and resolves
downed / death. Damage to zombies, raiders and the player is not tracked (report deaths instead).

| field | type | meaning |
|---|---|---|
| `id` | string | colonist id |
| `amount` | number | hp lost (positive) |
| `kind` | string | `bite`, `scratch`, `cut`, `bullet`, `blunt`, `fall`, `fire`, `explosion` |
| `part` | string? | `arm`, `leg`, `torso`, `head` (random if absent) |

```lua
{ type = "ped_damage", id = "c2", amount = 12, kind = "bite", part = "arm" }
```

### IN `ped_died`
A ped died in the game. `id` is a colonist id, a horde id (`h5`, with `zkind`), a raid id (`r2`) or `"player"`.

| field | type | meaning |
|---|---|---|
| `id` | string | colonist / horde / raid id, or `player` |
| `cause` | string? | free text for colonists (`zombies` makes an infected victim turn) |
| `zkind` | string? | for horde ids: `walker`, `runner`, `brute`, `screamer` |

```lua
{ type = "ped_died", id = "h5", zkind = "runner", cause = "player" }
```

### IN `player_state`
The player's position (and optionally needs). The player is the **observer** that decides which hordes / raids materialize.
Send it whenever the player moved more than about 20 units, and at least once per in-game minute.

| field | type | meaning |
|---|---|---|
| `pos` | pos | player position in sim space |
| `needs` | table? | optional `{hunger, thirst, fatigue, hp, infection}` (numbers or strings), stored for the UI |

```lua
{ type = "player_state", pos = { x = 12.0, y = 30.5, z = 0 }, needs = { hunger = 30, thirst = 20 } }
```

### IN `order`
A player-issued command. `id` is a colonist id or `"colony"` (or `"all"` for draft). Always answered with an `order_result`.
`target` depends on `kind`:

| field | type | meaning |
|---|---|---|
| `id` | string | colonist id, `colony`, or `all` |
| `kind` | string | one of the kinds below |
| `target` | any | see each kind |

#### order `priority`
Set a work priority: `target = {work, level}`. `work` is `doctor`, `guard`, `build`, `cook`, `craft`, `haul`, `scavenge`; `level` 0 (never) .. 4 (lowest),
1 is highest. Out-of-range levels are clamped (`reason = "clamped"`); work blocked by a trait stays 0. Result extra: `level`.

```lua
{ type = "order", id = "c1", kind = "priority", target = { work = "build", level = 1 } }
```

#### order `draft`
`target = true | false`. Drafted colonists hold position at full combat readiness and ignore chores. `id = "all"` drafts everyone. Result extra: `count`.

```lua
{ type = "order", id = "all", kind = "draft", target = true }
```

#### order `goto`
Walk to `target = pos` (forced, highest class).

```lua
{ type = "order", id = "c1", kind = "goto", target = { x = 20.0, y = 5.0, z = 0 } }
```

#### order `equip`
Fetch an item from the stockpile: `target = {item}` a weapon, or ammo up to the personal ammo carry.

```lua
{ type = "order", id = "c1", kind = "equip", target = { item = "pistol" } }
```

#### order `place_blueprint`
`id = "colony"`, `target = {bp, pos}`. Fails with the reason string (`unknown_blueprint`, `prereq:<building>`, `max_reached`, `blocked`, `too_far`). Result extra: `building`.

```lua
{ type = "order", id = "colony", kind = "place_blueprint", target = { bp = "wall", pos = { x = 30.0, y = 30.0, z = 0 } } }
```

#### order `cancel_blueprint`
`target = {id}` a building id (planned or finished). Delivered materials go to a ground pile.

```lua
{ type = "order", id = "colony", kind = "cancel_blueprint", target = { id = "b9" } }
```

#### order `expedition`
`target = {district, size?, crew?, vehicle?, mode?}`. Without `crew` the trip is open for volunteers (colonists with `scavenge` priority) for 60 minutes;
with `crew` (colonist ids) it leaves at once. `mode = "foot"` needs no fuel (nearby districts only). Result extra: `expedition`.
Failures: `unknown_district`, `no_vehicle`, `vehicle_damaged`, `no_fuel`, `too_far_on_foot`, `no_crew`.

```lua
{ type = "order", id = "colony", kind = "expedition", target = { district = "orchard", size = 2 } }
```

#### order `cancel_expedition`
`target = {id}`. Only possible while the trip is still forming.

```lua
{ type = "order", id = "colony", kind = "cancel_expedition", target = { id = "x1" } }
```

#### order `schedule`
`target` is `"day"`, `"night"`, `"early"` or a 24-character string over `S` (sleep) `W` (work) `A` (anything) `J` (joy, no work), one per hour from 00:00.

```lua
{ type = "order", id = "c1", kind = "schedule", target = "night" }
```

#### order `zone_create`
`id = "colony"`, `target = {pos, name?, tiles?, prio?, cats?}`: a new stockpile zone. `cats` is a list of item categories it accepts
(`food`, `drink`, `medical`, `ammo`, `weapon`, `material`, `fuel`, `tool`, `valuable`, `ingredient`); omit for everything. Result extra: `zone`.

```lua
{ type = "order", id = "colony", kind = "zone_create", target = { name = "Armoury", pos = { x = 20.0, y = 20.0, z = 0 }, tiles = 2, prio = 5, cats = { "weapon", "ammo" } } }
```

#### order `zone_set`
`target = {id, prio?, cats?}` change a zone's priority (1..5, higher fills first) or filter.

```lua
{ type = "order", id = "colony", kind = "zone_set", target = { id = "z1", prio = 4 } }
```

#### order `trade`
`target = {caravan, give, take}`, `give` = items from our stockpile, `take` = items from the caravan. Accepted when the value we give covers what we take.
Atomic: a rejected deal changes nothing. Reasons: `no_such_caravan`, `offer_too_low`, `not_enough:<item>`, `caravan_lacks:<item>`, `bad_item`. Result extras: `give_value`, `take_value`.
Taken goods arrive as a `loot_spawn` (`source = "trade"`).

```lua
{ type = "order", id = "colony", kind = "trade", target = { caravan = "k1", give = { jewelry = 2 }, take = { bandage = 3 } } }
```

#### order `gift`
`target = {faction, give}`: items are destroyed, goodwill rises (capped per gift).

```lua
{ type = "order", id = "colony", kind = "gift", target = { faction = "tallow", give = { canned_beans = 4 } } }
```

#### order `truce`
`target = {faction, give}`: pay a hostile gang for a ceasefire (3 days with no raids from them) if the value is enough (`offer_too_low` otherwise).

```lua
{ type = "order", id = "colony", kind = "truce", target = { faction = "rustjaw", give = { fuel_can = 2 } } }
```

#### order `amputation`
`target = true | false`: allow doctors to amputate this colonist's infected limb when no antibiotics are left (needs a surgical kit).

```lua
{ type = "order", id = "c1", kind = "amputation", target = true }
```

#### order `toggle_building`
`target = {id, enabled}`: switch a powered building off / on.

```lua
{ type = "order", id = "colony", kind = "toggle_building", target = { id = "b2", enabled = false } }
```

#### order `set_profile`
`target = "calm" | "escalating" | "chaos"`: change the storyteller pacing profile for the rest of the game.

```lua
{ type = "order", id = "colony", kind = "set_profile", target = "chaos" }
```

### IN `item_moved`
An item moved in the game (inventory UI, looting, dropping). Keeps the sim's item ledger exact. Locations are `{kind, id}` with `kind` one of
`player`, `colonist` (id), `zone` (id), `pile` (id), `container` (adapter ref, created on first use) or `void` (outside the sim:
moving *from* `void` creates items, moving *to* `void` destroys them; the ledger records both as `adapter`).
Moves are clamped by the destination's capacity; the answer says how many moved.

| field | type | meaning |
|---|---|---|
| `from` | table | source location |
| `to` | table | destination location |
| `item` | string | item id |
| `n` | number | positive integer |

```lua
{ type = "item_moved", from = { kind = "container", id = "fridge:77" }, to = { kind = "player" }, item = "canned_beans", n = 2 }
```

### IN `container_opened`
The player opened a world container (fridge, locker, crate). The first open rolls loot for `ctype` (`house`, `store`, `warehouse`, `clinic`, `bunker`, `farm`, `garage`, `police`,
`kitchen`, `fridge`, `pantry`, `crate`, `locker` ...; unknown types use a residential table) using the danger of the nearest district, and answers with `loot_spawn`.
Later opens answer with `container_contents`. An emptied container refills after a week. Opening is slightly noisy.

| field | type | meaning |
|---|---|---|
| `container` | string | the adapter's stable ref for this container |
| `ctype` | string | container type |
| `pos` | pos | location (picks the district / danger) |
| `danger` | number? | override the district danger (1..5) |

```lua
{ type = "container_opened", container = "fridge:77", ctype = "fridge", pos = { x = 500.0, y = 300.0, z = 0 } }
```

### IN `time_set`
Synchronise the clock with the game: sets the time of day (and optionally the day). Moving time backwards delays timers that were scheduled
in absolute minutes; prefer forward jumps.

| field | type | meaning |
|---|---|---|
| `hour` | number | 0..23 |
| `minute` | number? | 0..59 |
| `day` | number? | day number (default: keep) |

```lua
{ type = "time_set", hour = 22, minute = 30 }
```

### IN `horde_report`
Optional: where the materialized group of horde `id` actually is now (its centroid). Keeps the abstract position in sync so a later despawn
leaves the survivors in the right place.

| field | type | meaning |
|---|---|---|
| `id` | string | horde id |
| `pos` | pos | centroid |

```lua
{ type = "horde_report", id = "h5", pos = { x = 400.0, y = -80.0, z = 0 } }
```

### IN `raid_report`
Same as `horde_report` for a raid group.

| field | type | meaning |
|---|---|---|
| `id` | string | raid id |
| `pos` | pos | centroid |

```lua
{ type = "raid_report", id = "r2", pos = { x = 120.0, y = 10.0, z = 0 } }
```

### IN `colonist_ref`
Bind the adapter's opaque handle to a colonist (saved with the game; use a plain value such as a network id or model hash).

| field | type | meaning |
|---|---|---|
| `id` | string | colonist id |
| `ref` | any | plain value owned by the adapter |

```lua
{ type = "colonist_ref", id = "c1", ref = { netid = 4711 } }
```

## 5. Adapter responsibilities

1. **Spawn and despawn peds** only on `colonist_joined` / `spawn_horde` / `spawn_raiders` (and remove on the matching despawn / death / left events). The sim bounds the number of
   peds it asks for (`TUNING.horde.max_materialized`, default 40) but cannot see the engine's own ped pool: pick the cap for your machine.
2. **Report what the game decides**: damage to colonists (`ped_damage`), every death (`ped_died`), noise (`noise`, at least gunshots and explosions), the player's position (`player_state`),
   item moves and container opens. The sim never asks the game for anything.
3. **Do not wait** for task completion: jobs run on sim time. Snap or teleport peds to `colonist_task.pos` if they lag.
4. **Persistence**: store `save.save(world)` (a string) and the adapter's own ped-to-id map. `World` state is plain data; `save.load` rebuilds all caches and verifies a checksum and version header.
5. **Treat every OUT event as read-only data** and handle unknown event types by ignoring them (new ones may be added; the field tables here only grow).
6. Positions: keep one fixed `origin` offset between sim space and game space and apply it in both directions.

## 6. Tuning knobs the adapter may want to override (`data/tuning.lua`)

`horde.R_materialize` (220) / `horde.R_dematerialize` (380): the hysteresis band; `horde.max_materialized` (40); `horde.per_horde_max` (28); `horde.observe_colonists` (false: only the player observes);
`sim.state_report_min` (30); `base.*` (base centre, radius, garage position); `map.*`. They are plain numbers in a shared table: set them before creating a world.
