-- shared/mta_config.lua : every knob of the MTA:SA adapter in one table (the FiveM adapter's shared/config.lua is GTA V specific: model names, natives, convars).
-- The `server` table has the same keys shared/host.lua reads (it is passed to Host.new as `cfg`), so the game-agnostic server core is reused unchanged.
-- Defaults live here; the server overrides them from the resource settings in meta.xml through Config.apply(get) (see README "Settings").
--
-- Spaces: the sim works in "sim space" (base = origin, units ~ metres). Game space = sim space + Config.origin. The sim's z is always 0: the server keeps a coarse
-- ground-height map (server/ground.lua) fed by the client, because MTA's server has no collision world (getGroundPosition is client-only).
local U = require("shared.util")

local C = {}

C.VERSION = "0.1.0-mta"

-- where the sim origin (the base centre) sits in San Andreas. UNVERIFIED default: the Verdant Meadows airfield (flat, empty, desert north of Las Venturas);
-- the coordinates come from a location list in the mtadayz gamemode (read only). Change it with the `origin` setting ("x,y,z") to any flat spot.
C.origin = { x = 235.3, y = 2430.1, z = 16.85 }

-- ----- server ------------------------------------------------------------------------------------------------------
C.server = {
	seed = 0,                  -- 0 = pick one from the clock
	profile = "escalating",    -- calm | escalating | chaos
	colonists = 4,             -- starting survivors
	time_scale = 30,           -- game SECONDS per real second at speed 1 (30 = 1 game minute per 2 s)
	tick_ms = 500,             -- real ms between host updates (fixed-step accumulator in shared/host.lua)
	max_catchup_min = 30,      -- never advance more than this many sim minutes in one update (spiral guard)
	autoload = true,           -- load the latest save on start
	autosave_s = 120,          -- real seconds between autosaves (0 = off)
	owner_admin = true,        -- the colony owner may use the admin commands
	owner_name = "",           -- when set, only the player with this name can become the owner
	debug = false,
	ui_hz = 1,                 -- full UI state pushes per second while the owner has a colony screen open
	hud_hz = 2,                -- survival HUD pushes per second
	max_events_per_msg = 60,   -- OUT events per network message (larger batches are split)
	max_in_per_sec = 150,      -- IN events accepted per second from the owner (flood guard)
	max_ui_per_sec = 60,       -- orders + UI actions accepted per second from the owner
	max_horde_per_sec = 4,
	store = "file",            -- save backend: "file" (fileCreate / fileOpen) or "sqlite" (dbConnect)
	selftest = true,           -- on start, run a short seeded colony and compare its state hash with the value recorded under LuaJIT and Lua 5.4
	spawn_player = true,       -- spawn the owner at the base when they have no live ped (needs no spawnmanager)
	respawn_ms = 6000,         -- delay before a dead owner respawns at the base
	-- the sim's `TUNING.horde.max_materialized` (ped budget for horde + raiders). MTA's ped pool has about 140 slots and cannot be resized: see README "Ped budget".
	max_materialized = 60,
	-- the phone companion (server/phone.lua): a phone browser shows the colony and gives orders over MTA's HTTP port. Needs an MTA account with the ACL right resource.outbreak.http (README "Phone").
	phone = true,              -- off: phoneApi answers "switched off" (the HTTP page is still served to accounts that may see it)
	phone_sessions = 6,        -- phone pages kept at once (the least recently used one is evicted)
	phone_session_s = 60,      -- a phone page that has not called for this long is forgotten (it just signs in again)
}

-- ----- peds (server side) --------------------------------------------------------------------------------------------
C.peds = {
	max_peds = 96,             -- hard ceiling for peds this resource owns (zombies + raiders + colonists + traders + corpses waiting for deletion)
	pool_guard = 120,          -- refuse to create peds while the server knows this many ped elements (all resources): the game's pool is ~140
	max_colonist_peds = 16,    -- colonists beyond this stay abstract (no ped)
	max_objects = 400,         -- ceiling for building / ghost objects (the game's object pool is ~1200)
	spawn_min_dist = 40.0,     -- materialize at least this far from the player ...
	spawn_per_tick = 2,        -- peds created per spawn step (spreads the cost)
	spawn_ms = 250,            -- real ms between spawn steps
	brain_ms = 250,            -- real ms between zombie / raider decision steps
	brain_batch = 20,          -- peds thought about per decision step
	colonist_ms = 500,         -- real ms between colonist upkeep steps
	despawn_dist = 220.0,
	noise_min_gap_ms = 700,    -- per noise kind (client side)
	corpse_ms = 8000,          -- dead peds are destroyed after this long
	-- zombie perception (TP-Advanced-Zombies distances, metres): crouching / walking / sprinting
	detect = { crouch = 10.0, walk = 35.0, sprint = 45.0 },
	attack_range = 1.6,
	attack_cooldown_ms = 1100,
	hear_gunshot = 140.0,      -- materialized zombies within loudness*0.5 metres investigate a noise
	snap_grace_ms = 4000,      -- a colonist ped that has not arrived this long after the sim's own walking time is placed at the destination
	snap_max_ms = 60000,
	-- movement speeds the client driver understands: 0 stand, 1 walk, 2 jog, 3 sprint
	-- models: SA skin ids (UNVERIFIED appearances; getValidPedModels() filters invalid ids at start). No story characters (0, 1, 2, 265-272, 290-299).
	-- the skin ids that MTA DayZ's zombies wear on public servers (all standard SA skins), minus 56 which the colonists wear
	-- BORROWED-PRIVATE (unlicensed upstream, private use only): NullSystemWorks/mtadayz/DayZ/tables/table_zombies.lua (ZombiePedSkins)
	zombie_models = { 67, 68, 69, 70, 92, 97, 105, 107, 108, 126, 127, 128, 152, 162, 167, 188, 195, 209, 212, 229, 230, 258, 264, 277, 280 },
	-- END BORROWED-PRIVATE
	brute_models = { 162, 200 },
	colonist_models = { 26, 27, 20, 44, 46, 47, 48, 54, 19, 56 },
	faction_models = {
		rustjaw = { 100, 247, 248 },
		hollow_choir = { 34, 35, 36 },
		tallow = { 117, 118, 120 },
		cinder = { 287, 285, 191 },
		lantern = { 26, 27 },
	},
	trader_models = { 16, 17 },
}

-- per zombie kind: health as a fraction of full health, walking style, speed mode, damage, detection multiplier. Numbers adapted from the FiveM adapter (RottenV / TP-Advanced-Zombies).
-- walk = setPedWalkingStyle id from the MTA wiki list (119 MOVE_SHUFFLE, 124 MOVE_FATMAN, 125 MOVE_JOGGER, 126 MOVE_DRUNKMAN), stat24 = max-health stat (569 = 100 hp, 1000 = about 176 hp; UNVERIFIED)
C.zombie_kinds = {
	walker = { hp = { 60, 100 }, walk = 126, speed = 1, dmg = { 6, 12 }, detect = 1.0 },
	runner = { hp = { 40, 70 }, walk = 125, speed = 2, dmg = { 5, 9 }, detect = 1.25 },
	brute = { hp = { 150, 176 }, walk = 124, speed = 1, dmg = { 14, 24 }, detect = 1.0, stat24 = 1000, boss = true },
	screamer = { hp = { 40, 60 }, walk = 119, speed = 2, dmg = { 4, 8 }, detect = 1.6, screams = true },
}

-- SA weapon ids: sim item id -> weapon id
C.weapons = { pistol = 22, shotgun = 25, rifle = 33, baseball_bat = 5, crowbar = 6, machete = 8 }
C.raider_weapons = { rustjaw = { 5, 22 }, hollow_choir = { 8, 4 }, tallow = { 22, 28 }, cinder = { 30, 25 }, lantern = { 22 } }
C.weapon_ammo = { colonist = 120, raider = 240 }

-- noise loudness (sim guide in API.md: footsteps 8, melee 20, vehicle 45, gunshot 110, shotgun 140, rifle 150, explosion 200)
C.noise = { sprint = 8, melee = 20, vehicle = 45, siren = 70, horn = 60, gunshot = 110, shotgun = 140, rifle = 150, explosion = 200, scream = 90, suppressed_mult = 0.35 }
-- SA weapon id -> noise kind (client/noise.lua); 23 is the silenced pistol
C.weapon_noise = { [22] = "gunshot", [23] = "gunshot", [24] = "gunshot", [25] = "shotgun", [26] = "shotgun", [27] = "shotgun", [28] = "gunshot", [29] = "gunshot", [32] = "gunshot",
	[30] = "rifle", [31] = "rifle", [33] = "rifle", [34] = "rifle", [35] = "explosion", [36] = "explosion", [37] = "gunshot", [38] = "rifle" }
C.silenced = { [23] = true }

-- blueprint id -> candidate SA object model ids (the first one the game accepts wins). Every id and its name was checked against the MTA editor's model-name table
-- (multitheftauto/mtasa-resources, MIT) by mta/tests/config_test.lua; whether they LOOK right and have collision is UNVERIFIED until it runs in the game.
C.props = {
	floor = { 1685, 1462 },                -- blockpallet, DYN_woodpile
	wall = { 1407, 1408, 1419, 1459 },     -- DYN_F_R_WOOD_1, DYN_F_WOOD_2, DYN_F_IRON_1, DYN_ROADBARRIER_6
	door = { 1495, 1496 },                 -- Gen_doorEXT01, Gen_doorSHOP02
	barricade = { 2060, 1459, 1422 },      -- CJ_SANDBAG, DYN_ROADBARRIER_6, DYN_ROADBARRIER_5
	bed = { 1800, 1793 },                  -- LOW_BED_1, LOW_BED_2
	campfire = { 1370, 918 },              -- CJ_FLAME_Drum
	workbench = { 937, 936 },              -- CJ_DF_WORKTOP, CJ_DF_WORKTOP_2
	stove = { 1481, 914, 1777 },           -- DYN_BAR_B_Q, GRILL, CJ_COOKER1
	generator = { 929, 943 },              -- GENERATOR, GENERATOR_LOW
	watchtower = { 1426, 1464 },           -- DYN_SCAFFOLD, DYN_SCAFFOLD_3
	crate = { 1448, 964 },                 -- DYN_CRATE_1, CJ_METAL_CRATE
	rain_collector = { 1218, 1217 },       -- barrel1, barrel2
	water_tank = { 3632, 935 },            -- imoildrum_LAS, CJ_Drum
	medical_bed = { 1745, 1799 },          -- MED_BED_3, MED_BED_4
	lamp = { 2196, 1290 },                 -- WORK_LAMP1, lamppost2
	radio_mast = { 3763 },                 -- CE_radarmast3
	_fallback = { 1448, 1224 },            -- DYN_CRATE_1, woodenbox
	_pile = { 1271, 1224 },                -- gunbox, woodenbox
	_marker = { 1238 },                    -- trafficcone
}

-- colonist step -> animation { block, name, loop } (names harvested from working MTA scripts; UNVERIFIED which look right). A missing entry = just stand.
C.anims = {
	build = { "BOMBER", "BOM_Plant", true }, repair = { "BOMBER", "BOM_Plant", true }, craft = { "BOMBER", "BOM_Plant", true },
	tend = { "BOMBER", "BOM_Plant", true }, medicate = { "BOMBER", "BOM_Plant", true }, amputate = { "BOMBER", "BOM_Plant", true }, feed = { "BOMBER", "BOM_Plant", true },
	refuel = { "BOMBER", "BOM_Plant", true },
	eat = { "FOOD", "EAT_Burger", false }, binge = { "FOOD", "EAT_Burger", false }, drink = { "VENDING", "VEND_Drink2_P", false },
	rest = { "BEACH", "ParkSit_M_loop", true }, sleep = { "RYDER", "RYD_Die_PT1", true },
	idle = { "SCRATCHING", "sclng_r", true }, wander = { "SCRATCHING", "sclng_r", true },
	cook = { "FOOD", "EAT_Burger", false },
	attack = { "FIGHT_B", "FightB_1", false },
}
C.limp_walk = 120 -- MOVE_OLDMAN for a badly hurt player
C.carry_anim = { "CARRY", "crry_prtial", true }

-- sim weather kind -> SA weather id (UNVERIFIED mapping: 0 extra sunny, 16 rainy, 8 thunderstorm)
C.weather = { clear = 0, rain = 16, storm = 8 }
-- play_alert kind -> frontend sound id (UNVERIFIED: a wrong id is simply a different beep)
C.alert_sounds = { horde_near = 4, raid_incoming = 5, caravan = 1, helicopter = 2, supply_drop = 3 }

-- ----- client ------------------------------------------------------------------------------------------------------
C.client = {
	ui_mode = "gui",           -- "gui": guiCreateBrowser (CEGUI handles the mouse) | "dx": createBrowser + dxDrawImage + injectBrowserMouse*
	ui_url = "http://mta/local/ui/mta.html",
	colony_key = "F6",
	inventory_key = "i",
	interact_key = "e",
	cam_height = 60.0, cam_min_h = 15.0, cam_max_h = 200.0, cam_pan_speed = 40.0, edge_pan = 0.02, cam_fov = 60.0,
	grid = 2.0,                -- blueprint placement snap (sim units)
	noise_min_gap_ms = 700,
	drive_ms = 100,            -- ped driver step (client-side locomotion, see client/driver.lua)
	turn_ms = 700,             -- a chasing / walking ped re-faces its target this often (slothbot: 700 ms)
	ground_ms = 1000,          -- ground sample step
	ground_batch = 12,
	stuck_ms = 600,            -- a ped that moved less than a metre in this time is stuck (slothbot checks every 600 ms)
}

-- resource settings -> where they land. `get(name, default)` is supplied by the caller (the server wraps MTA's get(), the tests pass a table).
local function b(v) return v == true or v == 1 or v == "1" or v == "true" end

function C.apply(get)
	local s, p = C.server, C.peds
	s.seed = math.floor(U.num(get("seed", s.seed), s.seed))
	s.profile = tostring(get("profile", s.profile))
	s.colonists = U.clamp(math.floor(U.num(get("colonists", s.colonists), s.colonists)), 1, 12)
	s.time_scale = U.clamp(U.num(get("timescale", s.time_scale), s.time_scale), 1, 3600)
	s.tick_ms = U.clamp(math.floor(U.num(get("tick_ms", s.tick_ms), s.tick_ms)), 100, 5000)
	s.autoload = b(get("autoload", s.autoload and "1" or "0"))
	s.autosave_s = U.clamp(math.floor(U.num(get("autosave", s.autosave_s), s.autosave_s)), 0, 3600)
	s.owner_admin = b(get("owner_admin", s.owner_admin and "1" or "0"))
	s.owner_name = tostring(get("owner_name", s.owner_name) or "")
	s.debug = b(get("debug", s.debug and "1" or "0"))
	s.selftest = b(get("selftest", s.selftest and "1" or "0"))
	s.spawn_player = b(get("spawn_player", s.spawn_player and "1" or "0"))
	local st = tostring(get("store", s.store))
	s.store = (st == "sqlite") and "sqlite" or "file"
	s.max_materialized = U.clamp(math.floor(U.num(get("max_materialized", s.max_materialized), s.max_materialized)), 4, 120)
	s.phone = b(get("phone", s.phone and "1" or "0"))
	s.phone_sessions = U.clamp(math.floor(U.num(get("phone_sessions", s.phone_sessions), s.phone_sessions)), 1, 20)
	s.phone_session_s = U.clamp(math.floor(U.num(get("phone_session_s", s.phone_session_s), s.phone_session_s)), 10, 3600)
	p.max_peds = U.clamp(math.floor(U.num(get("max_peds", p.max_peds), p.max_peds)), 8, 130)
	p.pool_guard = U.clamp(math.floor(U.num(get("pool_guard", p.pool_guard), p.pool_guard)), 20, 140)
	p.max_objects = U.clamp(math.floor(U.num(get("max_objects", p.max_objects), p.max_objects)), 20, 1100)
	local o = U.parse_vec3(get("origin", ""))
	if o then C.origin.x, C.origin.y, C.origin.z = o.x, o.y, o.z end -- in place: other modules hold a reference to the table
	C.client.ui_mode = (tostring(get("ui_mode", C.client.ui_mode)) == "dx") and "dx" or "gui"
	return C
end

return C
