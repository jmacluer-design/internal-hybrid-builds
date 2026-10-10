-- shared/config.lua : every knob of the FiveM adapter in one table. Defaults here; the server and the client override
-- them from convars through Config.apply(getter) (see README "Convars"). Nothing in here calls a game native.
--
-- Spaces: the sim works in "sim space" (base = origin, units ~ metres). Game space = sim space + Config.origin.
-- The z of sim positions is always 0: the client resolves the real ground height itself.
local U = require("shared.util")

local C = {}

C.RESOURCE_FALLBACK = "outbreak"
C.VERSION = "0.2.0-pass2"

-- where the sim origin (the base centre) sits in the GTA map. UNVERIFIED default: open ground near Sandy Shores.
-- Change it with `setr outbreak_origin "x,y,z"` to any flat spot you like.
C.origin = { x = 1850.0, y = 3700.0, z = 34.0 }

-- ----- server ------------------------------------------------------------------------------------------------------
C.server = {
	seed = 0,                  -- 0 = pick one from the clock
	profile = "escalating",    -- calm | escalating | chaos
	colonists = 4,             -- starting survivors
	time_scale = 30,           -- game SECONDS per real second at speed 1 (30 = GTA default: 1 game minute per 2 s)
	tick_ms = 500,             -- real ms between host updates (fixed-step accumulator below)
	max_catchup_min = 30,      -- never advance more than this many sim minutes in one update (spiral guard)
	autoload = true,           -- load the latest save on start
	autosave_s = 120,          -- real seconds between autosaves (0 = off)
	owner_admin = true,        -- the colony owner may use /outbreak_* commands
	debug = false,
	ui_hz = 1,                 -- full UI state pushes per second while the owner has a colony screen open
	hud_hz = 2,                -- survival HUD pushes per second
	max_events_per_msg = 60,   -- OUT events per network message (larger batches are split)
	max_in_per_sec = 150,      -- IN events accepted per second from the owner (flood guard)
	max_horde_per_sec = 4,
}

-- ----- client ------------------------------------------------------------------------------------------------------
C.client = {
	max_peds = 48,             -- hard ceiling for peds this resource owns (zombies + raiders + colonists + traders)
	pool_guard = 150,          -- refuse to create peds while the game's CPed pool holds this many (see README: unverified size)
	max_objects = 400,         -- ceiling for props (blueprint ghosts + buildings)
	spawn_min_dist = 40.0,     -- materialize at least this far from the player ...
	spawn_max_dist = 90.0,     -- ... and at most this far (hordes are placed on a ring around their sim position)
	spawn_per_tick = 2,        -- peds created per 250 ms step (spreads the cost)
	despawn_dist = 220.0,      -- zombies this far from the player are recycled even if the sim keeps the horde
	ai_ms = 400,               -- zombie perception step
	ai_batch = 12,             -- zombies thought about per step
	noise_min_gap_ms = 700,    -- per noise kind
	colony_key = "F6",
	inventory_key = "I",
	model_timeout_ms = 3000,   -- give up on a model that does not stream in
	ground_timeout_ms = 800,
	grid = 2.0,                -- blueprint placement snap (sim units)
	cam_height = 60.0, cam_min_h = 15.0, cam_max_h = 200.0, cam_pan_speed = 40.0, edge_pan = 0.02,
	-- zombie perception (TP-Advanced-Zombies distances, metres): crouching / walking / sprinting
	detect = { crouch = 10.0, walk = 35.0, sprint = 45.0 },
	snap_grace_ms = 4000,      -- a colonist ped that has not arrived this long after the sim's own walking time is snapped to the destination
	snap_max_ms = 60000,       -- ... and never waits longer than this
	attack_range = 1.4,
	attack_cooldown_ms = 1100,
	hear_gunshot = 140.0,      -- materialized zombies within loudness*0.5 metres investigate a noise
	ragdoll_chance = 0.35,
	-- models (UNVERIFIED names: they come from public lists; the client skips any that IsModelInCdimage rejects)
	zombie_models = { "a_m_m_skidrow_01", "a_m_m_tramp_01", "a_m_m_salton_01", "a_m_y_methhead_01", "a_m_m_hillbilly_01",
		"a_f_m_tramp_01", "a_m_m_farmer_01", "a_m_y_salton_01", "a_f_y_hipster_01", "a_m_m_fatlatin_01", "u_m_y_zombie_01" },
	brute_models = { "a_m_m_polynesian_01", "a_m_m_og_boss_01" },
	colonist_models = { "a_m_y_hiker_01", "a_f_y_hiker_01", "a_m_m_farmer_01", "a_f_y_fitness_01", "a_m_y_runner_01", "a_f_y_runner_01",
		"a_m_m_hillbilly_02", "a_f_o_genstreet_01" },
	faction_models = {
		rustjaw = { "g_m_y_lost_01", "g_m_y_lost_02", "g_m_y_lost_03" },
		hollow_choir = { "a_m_m_acult_01", "a_m_o_acult_01", "a_m_y_acult_01" },
		tallow = { "g_m_y_korean_01", "g_m_y_korean_02" },
		cinder = { "g_m_y_armgoon_02", "g_m_m_armgoon_01" },
		lantern = { "a_m_m_hillbilly_01", "a_f_y_hiker_01" },
	},
}

-- weapon hashes are looked up by name on the client; raiders / colonists get these by sim item id
C.weapons = {
	pistol = "WEAPON_PISTOL", shotgun = "WEAPON_PUMPSHOTGUN", rifle = "WEAPON_SNIPERRIFLE",
	baseball_bat = "WEAPON_BAT", crowbar = "WEAPON_CROWBAR", machete = "WEAPON_MACHETE",
}
C.raider_weapons = {
	rustjaw = { "WEAPON_CROWBAR", "WEAPON_PISTOL" }, hollow_choir = { "WEAPON_MACHETE", "WEAPON_KNIFE" },
	tallow = { "WEAPON_PISTOL", "WEAPON_SMG" }, cinder = { "WEAPON_CARBINERIFLE", "WEAPON_PUMPSHOTGUN" }, lantern = { "WEAPON_PISTOL" },
}

-- noise loudness (sim guide in API.md: footsteps 8, melee 20, vehicle 45, gunshot 110, shotgun 140, rifle 150, explosion 200)
C.noise = {
	sprint = 8, melee = 20, vehicle = 45, siren = 70, horn = 60, gunshot = 110, shotgun = 140, rifle = 150, explosion = 200,
	suppressed_mult = 0.35,
}

-- blueprint id -> candidate GTA prop models (first one the game accepts wins). UNVERIFIED names; see README.
C.props = {
	floor = { "prop_conslift_base", "prop_pallettruck_01", "prop_boxpile_07d" },
	wall = { "prop_fncwood_16a", "prop_fncwood_16d", "prop_barrier_work06a" },
	door = { "prop_fncwood_16b", "prop_fncwood_16c" },
	barricade = { "prop_barrier_work06a", "prop_mp_barrier_02b", "prop_barrier_work05" },
	bed = { "v_res_mbbed", "prop_mattress_01", "prop_rub_matress_1" },
	campfire = { "prop_beach_fire", "prop_bbq_1" },
	workbench = { "prop_toolchest_05", "prop_tool_bench02", "prop_cs_cardbox_01" },
	stove = { "prop_bbq_3", "prop_bbq_4", "prop_bbq_1" },
	generator = { "prop_generator_03b", "prop_generator_02a", "prop_generator_01a" },
	watchtower = { "prop_scafold_xbrace_01", "prop_scafold_03a", "prop_ld_container" },
	crate = { "prop_cratepile_07a", "prop_box_wood02a", "prop_boxpile_07d" },
	rain_collector = { "prop_barrel_01a", "prop_barrel_02a" },
	water_tank = { "prop_watertower03", "prop_gas_tank_02a", "prop_barrel_01a" },
	medical_bed = { "v_med_bed1", "v_med_bed2", "prop_mattress_01" },
	lamp = { "prop_worklight_03b", "prop_worklight_01a", "prop_worklight_04a" },
	radio_mast = { "prop_radiomast01", "prop_radiomast02" },
	_fallback = { "prop_box_wood02a", "prop_boxpile_07d" },
	_pile = { "prop_cs_cardbox_01", "prop_box_wood02a" },
	_marker = { "prop_mp_cone_03", "prop_roadcone02a" },
}

-- scenarios / animations per colonist step (names are strings, UNVERIFIED against the game)
C.scenarios = {
	build = "WORLD_HUMAN_HAMMERING", repair = "WORLD_HUMAN_HAMMERING", guard = "WORLD_HUMAN_GUARD_STAND",
	cook = "PROP_HUMAN_BBQ", craft = "WORLD_HUMAN_WELDING", tend = "CODE_HUMAN_MEDIC_TEND_TO_DEAD",
	medicate = "CODE_HUMAN_MEDIC_TEND_TO_DEAD", amputate = "CODE_HUMAN_MEDIC_TEND_TO_DEAD", feed = "CODE_HUMAN_MEDIC_TEND_TO_DEAD",
	eat = "WORLD_HUMAN_SEAT_WALL_EATING", drink = "WORLD_HUMAN_DRINKING", rest = "WORLD_HUMAN_STAND_IMPATIENT",
	sleep = "WORLD_HUMAN_SUNBATHE_BACK", binge = "WORLD_HUMAN_SEAT_WALL_EATING", wander = "WORLD_HUMAN_STAND_MOBILE",
	idle = "WORLD_HUMAN_STAND_IMPATIENT", refuel = "WORLD_HUMAN_HAMMERING",
}

-- convar names -> where they land. `get(name, default)` is supplied by the caller (GetConvar* wrappers or a test table).
local function b(v) return v == true or v == 1 or v == "1" or v == "true" end

function C.apply(get)
	local s, c = C.server, C.client
	s.seed = math.floor(U.num(get("outbreak_seed", s.seed), s.seed))
	s.profile = tostring(get("outbreak_profile", s.profile))
	s.colonists = U.clamp(math.floor(U.num(get("outbreak_colonists", s.colonists), s.colonists)), 1, 12)
	s.time_scale = U.clamp(U.num(get("outbreak_timescale", s.time_scale), s.time_scale), 1, 3600)
	s.tick_ms = U.clamp(math.floor(U.num(get("outbreak_tick_ms", s.tick_ms), s.tick_ms)), 100, 5000)
	s.autoload = b(get("outbreak_autoload", s.autoload and "1" or "0"))
	s.autosave_s = U.clamp(math.floor(U.num(get("outbreak_autosave", s.autosave_s), s.autosave_s)), 0, 3600)
	s.owner_admin = b(get("outbreak_owner_admin", s.owner_admin and "1" or "0"))
	s.debug = b(get("outbreak_debug", s.debug and "1" or "0"))
	c.max_peds = U.clamp(math.floor(U.num(get("outbreak_max_peds", c.max_peds), c.max_peds)), 4, 200)
	c.pool_guard = U.clamp(math.floor(U.num(get("outbreak_pool_guard", c.pool_guard), c.pool_guard)), 20, 500)
	c.max_objects = U.clamp(math.floor(U.num(get("outbreak_max_objects", c.max_objects), c.max_objects)), 20, 1400)
	local o = U.parse_vec3(get("outbreak_origin", ""))
	if o then C.origin = o end
	return C
end

return C
