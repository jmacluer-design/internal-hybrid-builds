-- data/tuning.lua : THE tuning table. Every balance number in the sim lives in this file
-- (items, blueprints, loot, traits, thoughts and events have their own data/*.lua).
-- Units: time = in-game minutes, distance = world units (~metres), weights = grams,
-- rates are "per minute" unless the name says otherwise. Higher need values are WORSE
-- (hunger 100 = starving). Tests read this table, so keep the key names stable.
local TUNING = {}

-- simulation stepping ----------------------------------------------------------------------
TUNING.sim = {
	max_dt = 1,               -- largest internal step in minutes (tick(n) is split into steps of <= max_dt)
	state_report_min = 30,    -- colonist_state heartbeat for continuous stats (discrete changes report at once)
	log_cap = 160,            -- director log ring size (bounded state growth)
	ledger_reasons = true,    -- keep per-reason item flow counters
}

-- clock ------------------------------------------------------------------------------------
TUNING.clock = {
	start_hour = 8,           -- a new world starts on day 1 at this hour
	night_start = 21,         -- hour (inclusive) night begins
	night_end = 5,            -- hour (exclusive) night ends
	dawn_start = 5, dawn_end = 7,   -- daylight ramps 0 -> 1
	dusk_start = 19, dusk_end = 21, -- daylight ramps 1 -> 0
	season_len_days = 20,     -- 4 seasons: spring, summer, autumn, winter
}

-- abstract map (sim origin = base centre; the adapter adds its own offset) ------------------
TUNING.map = {
	min_x = -2400, min_y = -2400, max_x = 2400, max_y = 2400,
	cell = 200,               -- coarse grid cell edge for hordes / noise / districts
}

TUNING.base = {
	x = 0, y = 0, z = 0,
	radius = 70,              -- inside this radius a group is "at the base"
	perimeter_needed = 10,    -- wall-like segments for a closed perimeter (enclosure = built / needed)
	build_radius = 160,       -- blueprints must be placed within this distance of the base centre
	min_spacing = 1.2,        -- two buildings closer than this are considered overlapping
	alert_radius = 700,       -- hordes / raids inside this radius raise the base alert
	garage = { x = 30, y = -20, z = 0 },
}

TUNING.player = {
	carry_g = 30000, slots = 30,
}

-- colonists ----------------------------------------------------------------------------------
TUNING.colonist = {
	hp_max = 100,
	carry_base_g = 16000, carry_per_str = 2200, slots = 14,
	walk_speed = 80,          -- world units per minute
	start_count = 4,
	max_count = 40,
	work_types = { "doctor", "guard", "build", "cook", "craft", "haul", "scavenge" }, -- tie-break order
	default_priority = { doctor = 3, guard = 2, build = 3, cook = 3, craft = 3, haul = 3, scavenge = 3 },
	schedule_default = "WWWWWWWWAAAAAAAAAAAAAAAA", -- overwritten per colonist; see colonist.default_schedule
	sleep_hours = 8,
}

-- needs ----------------------------------------------------------------------------------------
TUNING.needs = {
	hunger_per_min = 0.0833333333,   -- 100 points in 20 h
	thirst_per_min = 0.1388888889,   -- 100 points in 12 h
	fatigue_awake_per_min = 0.0925925926, -- 100 points in 18 h awake
	fatigue_sleep_per_min = 0.2380952381, -- recover 100 points in 7 h of good sleep
	fatigue_work_mult = 1.15,        -- hard work tires faster
	starve_hp_per_min = 0.03,        -- hp lost per minute at hunger 100
	dehydrate_hp_per_min = 0.07,     -- hp lost per minute at thirst 100
	regen_hp_per_min = 0.02,         -- natural healing when fed + hydrated + not bleeding
	regen_rest_mult = 2.5,           -- multiplier while sleeping / resting
	clot_below = 0.04,               -- wounds bleeding slower than this stop on their own
	bleed_decay = 0.9985,            -- per minute multiplicative clotting of every wound
	pain_decay_per_min = 0.06,
	pain_cap = 100,
	downed_hp = 12,                  -- hp at or below this -> downed (cannot act)
	wounds_cap = 6,                  -- per colonist (oldest merges)
	collapse_fatigue = 100,
	-- action thresholds
	eat_at = 55, drink_at = 55, sleep_at = 75,
	emergency_hunger = 90, emergency_thirst = 90, emergency_fatigue = 96,
	-- speed penalties (work_speed multiplier floor/ceiling)
	speed_floor = 0.2,
	-- wound kinds: bleed range (hp/min), pain, infection chance
	wounds = {
		bite    = { bleed_min = 0.10, bleed_max = 0.45, pain = 18, infect = 0.55 },
		scratch = { bleed_min = 0.02, bleed_max = 0.10, pain = 5,  infect = 0.10 },
		cut     = { bleed_min = 0.05, bleed_max = 0.30, pain = 10, infect = 0.02 },
		bullet  = { bleed_min = 0.20, bleed_max = 0.65, pain = 22, infect = 0.00 },
		blunt   = { bleed_min = 0.00, bleed_max = 0.00, pain = 9,  infect = 0.00 },
		fall    = { bleed_min = 0.00, bleed_max = 0.00, pain = 12, infect = 0.00 },
		fire    = { bleed_min = 0.00, bleed_max = 0.05, pain = 25, infect = 0.01 },
		explosion = { bleed_min = 0.15, bleed_max = 0.50, pain = 30, infect = 0.00 },
	},
	infection = {
		incubate = { 480, 1100 },    -- min..max minutes (random) before symptoms
		symptomatic = { 600, 1100 }, -- minutes of fever before the terminal stage
		terminal = { 120, 300 },     -- minutes from terminal to death
		rest_slow = 0.75,            -- progress speed while sleeping/resting
		symptom_speed = 0.7,         -- work speed multiplier when symptomatic
		symptom_hp_per_min = 0.004,
		terminal_hp_per_min = 0.05,
		cure = { incubating = 0.90, symptomatic = 0.55, terminal = 0.12 }, -- antibiotics success (before skill)
		cure_per_skill = 0.025,
		cure_cap = 0.97,
		amputate_base = 0.80, amputate_per_skill = 0.02, amputate_hp_cost = 22, amputate_pain = 45,
		amputate_work_min = 25,
		maim_speed = 0.9,            -- work speed multiplier per amputation
		turn_delay = { 3, 12 },      -- minutes between death and reanimation
	},
	painkiller_pain = 40, painkiller_minutes = 240, painkiller_mood = 6,
	bandage_stop = 0.9,        -- chance a bandage stops a wound
	kit_stop = 1.0,
}

-- mood -------------------------------------------------------------------------------------
TUNING.mood = {
	base = 50,
	eval_interval = 5,           -- minutes between full mood recomputations
	-- need-derived contributions
	hunger_mid = 55, hunger_bad = 80,   -- thresholds -> penalties
	hunger_mid_pen = -6, hunger_bad_pen = -16,
	thirst_mid = 55, thirst_bad = 80,
	thirst_mid_pen = -6, thirst_bad_pen = -18,
	fatigue_mid = 60, fatigue_bad = 85,
	fatigue_mid_pen = -5, fatigue_bad_pen = -14,
	pain_pen_per_point = -0.18,   -- times pain level
	infection_pen = { incubating = 0, symptomatic = -12, terminal = -25 },
	maimed_pen = -6,
	-- breaks
	break_levels = { minor = 30, major = 20, extreme = 10 },
	break_per_hour = { minor = 0.04, major = 0.10, extreme = 0.25 },
	break_minutes = { 45, 150 },
	break_cooldown = 480,
	break_relief = 8,            -- thought value after a break ends
	binge_items = 3,
	wander_leave_chance = 0.08,  -- extreme break: chance the colonist never comes back
	max_thoughts = 24,
}

-- skills -------------------------------------------------------------------------------------
TUNING.skills = {
	max_level = 10,
	xp_unit = 60,                 -- total xp to reach level L = xp_unit * L*(L+1)/2
	speed_base = 0.6, speed_per_level = 0.1,
	xp_per_work_min = 1.0,        -- xp per minute of the matching work
	xp_per_kill = 4,
	start_level_max = 4,
}
-- expeditions (abstract scavenging trips by vehicle) -------------------------------------------------
TUNING.expedition = {
	vehicles = {
		van = { name = "Cargo van", speed = 1.0, trunk_g = 120000, hp = 100 },
		pickup = { name = "Pickup truck", speed = 1.15, trunk_g = 60000, hp = 80 },
	},
	start_vehicles = { "van" },
	crew_min = 1, crew_max = 4,
	fuel_min_per_can = 90,       -- round-trip minutes one fuel can covers (cans = ceil(round trip / this))
	loot_minutes = { 30, 70 },   -- time spent searching (scaled by district radius)
	loot_rolls = { 4, 8 },       -- base weighted rolls per run
	loot_per_scav_levels = 3,    -- +1 roll per this many total scavenging levels in the crew
	trip_variance = { 0.85, 1.2 },
	-- ambush chance per leg (travel there / looting / travel back share one roll set) by district danger 1..5
	risk = { 0.10, 0.17, 0.27, 0.38, 0.52 },
	night_risk_mult = 1.5,
	skill_risk_cut = 0.025,      -- risk reduction per crew shooting+scavenging level (avg), floored at 30% of base
	zombies_per_danger = 0.7,    -- fraction of district.zombies met in an ambush (random 0.4..1.0 of it)
	runner_share = 0.20, brute_share = 0.04, screamer_share = 0.03, -- mix shares at danger >= 3 / 4 / 3
	lost_chance = { 0.0, 0.01, 0.03, 0.06, 0.10 }, -- per surviving crew member after a bad ambush
	vehicle_ambush_damage = { 4, 14 },
	breakdown_chance = 0.06, breakdown_minutes = { 20, 45 },
	cache_chance = 0.08, cache_rolls = 3,
	vehicle_lost_if_wiped = 0.6,
	vehicle_repair_per_min = 0.01,
	log_keep = 12,
}

-- jobs ---------------------------------------------------------------------------------------------
TUNING.jobs = {
	board_interval = 5,        -- minutes between job-board rebuilds
	reeval_interval = 10,      -- a busy colonist re-checks for better / urgent jobs this often
	aging_minutes = 300,       -- an unserved job gains one priority step per this many minutes (starvation bound)
	guard_shift_min = 240,
	guard_posts_night = 2, guard_posts_alert = 3, guard_ready_alarm = 0.6, -- see jobs.guards_wanted
	gate_radius = 45,          -- virtual guard posts sit on a ring this far from the base centre
	pickup_min = 1, drop_min = 1, eat_min = 4, drink_min = 2, take_min = 1,
	tend_min = 4, medicate_min = 3,
	wake_fatigue = 6,          -- sleepers wake at/below this fatigue
	floor_rest_quality = 0.6,
	repair_hp_per_min = 4,     -- hp restored per work minute (before speed)
	repair_per_item_hp = 60,   -- hp repaired per scrap item consumed
	repair_below = 0.7,        -- buildings under this hp fraction get repair jobs
	personal_ammo = 40,        -- rounds a colonist keeps (not hauled away)
	keep_bandages = 0,
	treat_bleed_urgent = 0.15, -- bleeding hp/min above which tending is an emergency
	medicate_cooldown = 600,   -- minutes before the same patient gets another antibiotic dose
	binge_min = 20,
	wander_radius = 160,
	sign_up_minutes = 60,      -- how long an expedition waits for volunteers
}

-- power / water grid + weather --------------------------------------------------------------------
TUNING.grid = {
	mains_cap_w = 1400,         -- what the (failing) city grid can supply
	mains_power_dies_day = { 7, 13 },  -- city power fails for good on a random day in this range
	mains_water_dies_day = { 4, 9 },   -- city water stops for good on a random day in this range
	gen_min_per_l = 25,         -- generator runtime minutes per litre of fuel
	tank_base_l = 60,           -- water storage with no tanks built
	tank_start_l = 40,
	mains_water_fill = 3.0,     -- L/min added to the tank while the water mains are up
	dew_factor = 0.04,          -- rain collectors still give this fraction of their rate when dry
	drink_l = 0.45,             -- litres per drink (-45 thirst)
	drink_points = 45,
	power_prio = { medical_bed = 1, stove = 2, lamp = 3, workbench = 4, radio_mast = 5 }, -- brownout shedding order
	-- weather: per-hour chance of rain by season index (spring, summer, autumn, winter)
	rain_per_hour = { 0.07, 0.03, 0.08, 0.05 },
	rain_minutes = { 120, 360 },
	storm_minutes = { 90, 240 },
	rain_collect_mult = 1.0, storm_collect_mult = 2.0,
}

-- abstract combat (off-screen skirmishes) --------------------------------------------------------
TUNING.combat = {
	types = { -- power = threat per head; ranged attackers shoot instead of bite
		walker = { power = 1.0 }, runner = { power = 1.8 }, brute = { power = 6.0 }, screamer = { power = 0.8 },
		raider = { power = 2.6, ranged = true },
	},
	order = { "walker", "runner", "brute", "screamer", "raider" }, -- deterministic iteration order
	rounds = 6,               -- rounds per resolve() call (about 2 game minutes each)
	k_kill = 0.30,            -- attacker power removed per defender power per round
	k_damage = 0.45,          -- defender hp lost per attacker power per round (before walls)
	var_lo = 0.6, var_hi = 1.4, -- per-round randomness band (idea: CDDA's 0.6..1.4 skill roll band)
	hit_hp = 9,               -- one "hit" is about this much hp
	bite_share = 0.5,         -- share of zombie hits that are bites (rest scratches)
	barrier_k = 18,           -- wall_mult = 1 / (1 + barrier / barrier_k)
	wall_wear = 0.30,         -- barrier hp lost per attacker power per round
	ranged_wall_bonus = 0.35, -- shooters fire over walls: kill bonus * enclosure
	ammo_per_round = 2,       -- rounds fired per ranged defender per round
	out_of_ammo = 0.4,        -- ranged defender without ammo fights at this fraction
	guard_factor = 1.0,       -- readiness of colonists on guard / drafted
	awake_factor = 0.55,      -- readiness of awake colonists who are working
	sleep_factor = 0.30,      -- readiness of sleeping colonists
	downed_factor = 0.0,
}
return TUNING
