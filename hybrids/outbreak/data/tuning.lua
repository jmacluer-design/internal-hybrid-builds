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
	sleep_hours = 8,
	maim_walk_mult = 0.85,     -- walking speed multiplier per amputation
	hurt_walk_below = 0.4, hurt_walk_mult = 0.8, -- limping when under this hp fraction
	-- combat power: weapon power x (skill_base + skill_per_level x skill); fists use melee skill
	combat = { unarmed = 1.2, unarmed_bonus = 1.5, skill_base = 0.5, skill_per_level = 0.1, dry_gun_score = 0.3 },
}

-- needs ----------------------------------------------------------------------------------------
TUNING.needs = {
	hunger_per_min = 0.0625,         -- 100 points in 26.7 h (about 2.6 meals a day)
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
		bite    = { bleed_min = 0.10, bleed_max = 0.45, pain = 18, infect = 0.30 },
		scratch = { bleed_min = 0.02, bleed_max = 0.10, pain = 5,  infect = 0.04 },
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
		amputate_symptomatic_pen = 0.15, amputate_fail_hp_mult = 1.5, amputate_min = 0.05, amputate_max = 0.97,
		fail_extend = 1.3,           -- a failed antibiotic course multiplies the time left by this
		maim_speed = 0.9,            -- work speed multiplier per amputation
		turn_delay = { 3, 12 },      -- minutes between death and reanimation
	},
	painkiller_pain = 40, painkiller_minutes = 240, painkiller_mood = 6,
	bandage_stop = 0.9,        -- chance a bandage stops a wound
	bandage_partial = 0.4,     -- a failed bandage still cuts the worst wound's bleed to this fraction
	kit_stop = 1.0,
	head_bite_to_arm = 0.5,    -- chance a bite rolled on the head lands on an arm instead (head bites are not amputable)
	wound_scale = { per_hp = 15, min = 0.4, max = 2.5 }, -- bleed / pain scale = damage / per_hp, clamped
	wound_heal_min = 2880,     -- a stopped wound leaves the list after this long (bites linked to an infection stay)
	recover_margin = 8,        -- hp above downed_hp needed to get back up
	-- work-speed penalties: speed *= 1 - (need - from) * k  for each need above its threshold
	speed = { hunger_from = 50, hunger_k = 0.004, thirst_from = 50, thirst_k = 0.006, fatigue_from = 60, fatigue_k = 0.006,
		pain_k = 0.004, terminal_mult = 0.45, hurt_below = 0.5, hurt_mult = 0.85, ceiling = 1.5 },
	-- how activity changes the base rates
	activity = { hunger_sleep = 0.55, hunger_rest = 0.75, hunger_work = 1.1, thirst_sleep = 0.6, rest_fatigue_frac = 0.35 },
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
	major_binge_chance = 0.5,    -- major break: binge (if food exists) instead of refusing
	extreme_wander = 0.6, extreme_binge = 0.2, -- extreme break kinds (the rest refuse)
	extreme_duration_mult = 1.3,
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
-- world setup + containers ----------------------------------------------------------------------------------------
TUNING.world = {
	start_items = { -- the starting stockpile (created in the ledger as "start")
		canned_beans = 12, canned_veg = 8, ration_pack = 4, rice_bag = 2, dried_meat = 4, energy_bar = 6,
		water_bottle = 16, soda_can = 6,
		bandage = 8, painkillers = 3, antibiotics = 4, surgical_kit = 1, cloth_scrap = 14,
		scrap_wood = 26, scrap_metal = 12, nails = 12, duct_tape = 3, wire = 3, electronics = 2,
		fuel_can = 5, firewood = 10, ammo_9mm = 60, ammo_shell = 24,
	},
	start_buildings = { { "campfire", 14, 8 }, { "workbench", 18, -6 }, { "bed", -12, 10 }, { "bed", -12, 14 } },
	main_zone = { x = 10, y = 10, tiles = 10, prio = 2 },
	med_zone = { x = 12, y = 4, tiles = 2, prio = 4 },
	container_respawn_days = 7,    -- an emptied adapter container refills after this many days
	pile_merge_dist = 6,
	noise_ping_gen = 30,
	refugee_items = { water_bottle = 1, canned_beans = 1 },
	refugee_armed_chance = 0.3,
	max_dead_kept = 40,
	med_bed_heal = 1.8, med_bed_heal_unpowered = 1.3, -- regeneration multipliers while resting in a medical bed
	secure_enclosure = 0.8,     -- enclosure at which the "walls hold" thought is granted each day
	hurt_frac = 0.7,            -- colonists below this hp fraction count as hurt in reports
	leave_grief = 0.5,          -- strength of the grief thought when a colonist leaves alive
}

-- director (storyteller) -----------------------------------------------------------------------------------
-- threat points per day = mult(profile, day) * (base_pts + colonist_k * colonists + wealth_k * sqrt(wealth) + day_k * (day - 1))
-- The budget accrues continuously (capped) and is SPENT by threat events: an event can only fire if the budget
-- covers its cost, so threat can never exceed what the colony's size, wealth and age have earned.
TUNING.director = {
	eval_interval = 30,
	base_pts = 8, colonist_k = 3.5, wealth_k = 1.2, day_k = 0.9,
	budget_cap_days = 2.5,       -- budget never exceeds this many days of accrual
	start_grace_days = 1.0,      -- no events at all during the first day
	log_cap = 160,
	by_day_keep = 60,
	surge_gap_mult = 0.25,       -- a surge shrinks the next threat gap to this fraction
	radio_mult = 1.5,            -- a powered radio mast multiplies caravan / refugee weights
	retry_minutes = 180,         -- an event that could not happen right now is retried after this long
	profiles = {
		calm = {
			desc = "Long quiet stretches, small threats, more help arriving.",
			mult0 = 0.50, mult1 = 1.15,               -- multiplier at day 1 / day 30 (linear in between)
			threat_gap = { 1.3, 2.8 }, threat_gap_late = { 1.2, 2.6 }, -- days between threat-channel events (day 1 / day 30)
			boon_gap = { 1.5, 3.0 },
			spend_frac = { 0.45, 0.80 },
			surge_chance = 0,
			weights = { horde_wave = 0.7, gang_raid = 0.5, infection_outbreak = 0.6, helicopter_flyover = 0.5, power_outage = 1.0, water_outage = 1.0,
				storm = 1.2, caravan = 1.5, supply_drop = 0.8, refugee_arrival = 1.3 },
		},
		escalating = {
			desc = "Gentle start, steadily rising pressure.",
			mult0 = 0.55, mult1 = 1.15,
			threat_gap = { 1.8, 3.2 }, threat_gap_late = { 0.35, 0.85 },
			boon_gap = { 2.0, 4.0 },
			spend_frac = { 0.55, 0.85 },
			surge_chance = 0.10,
			weights = { horde_wave = 1.0, gang_raid = 1.0, infection_outbreak = 1.0, helicopter_flyover = 1.0, power_outage = 1.0, water_outage = 1.0,
				storm = 1.0, caravan = 1.0, supply_drop = 1.0, refugee_arrival = 1.0 },
		},
		chaos = {
			desc = "Relentless: short gaps, big spikes, little rest.",
			mult0 = 0.8, mult1 = 1.05,
			threat_gap = { 0.25, 0.8 }, threat_gap_late = { 0.15, 0.55 },
			boon_gap = { 3.0, 6.0 },
			spend_frac = { 0.60, 0.95 },
			surge_chance = 0.30,
			weights = { horde_wave = 1.5, gang_raid = 1.4, infection_outbreak = 1.2, helicopter_flyover = 1.6, power_outage = 1.2, water_outage = 1.2,
				storm = 1.3, caravan = 0.6, supply_drop = 0.7, refugee_arrival = 0.6 },
		},
	},
	-- boon sizes
	supply_drop_rolls = { 4, 7 }, supply_drop_dist = { 60, 140 },
	refugee_infected_chance = 0.12,
	storm_damage = { 10, 28 }, storm_buildings = 3,
	infection_victims_per_cost = 0.05, -- extra victims per spent point (max 3 total)
}

-- factions: raids, caravans, trade, relations ----------------------------------------------------------------
TUNING.factions = {
	raid_speed = 110,           -- units per minute while approaching (vehicles)
	retreat_speed = 140,
	raiders_per_point = 1 / 2.6, -- raider count = points * raid_power * this
	raid_min = 2, raid_max = 16,
	steal_g_per_raider = 3500,
	rounds_before_retreat = 3,
	raid_spawn_dist = { 1100, 1700 },
	raid_goodwill_ceiling = 22,  -- factions friendlier than this rarely raid
	kill_goodwill = -0.4,        -- goodwill lost per raider killed
	goodwill_drift = 0.03,       -- fraction of the gap to the starting goodwill recovered per day
	caravan_stay = 360,          -- minutes a caravan waits at the base
	caravan_min_goodwill = -25,
	price_goodwill = 400,        -- price factor = 1 -/+ goodwill / this
	want_premium = 1.25,
	trade_goodwill_gain = 0.12, trade_goodwill_cap = 3,
	gift_goodwill_per_value = 0.35, gift_goodwill_cap = 12,
	truce_min_value = 25, truce_per_hostility = 0.5, truce_days = 3,
	raid_log_keep = 20,
	caravan_day_growth = 0.02,  -- caravan stock quantity multiplier = 1 + day x this
}

-- hordes (abstract groups on a coarse grid) -------------------------------------------------------------
TUNING.horde = {
	R_materialize = 220,       -- a horde within this distance of an observer becomes real peds
	R_dematerialize = 380,     -- ...and goes abstract again only beyond this (hysteresis margin = 160)
	min_dwell = 4,             -- minutes a materialized horde must stay real before it may despawn
	max_materialized = 40,     -- cap on peds alive at once (hordes + raiders): THE adapter performance knob
	per_horde_max = 28,        -- most peds one horde materializes
	top_up_min = 5,            -- minutes between top-up spawns while real peds were killed
	observe_colonists = false, -- also materialize near colonists (leave false: colonists far from the player stay abstract)
	speed = { walker = 55, runner = 120, brute = 70, screamer = 80 }, -- units per minute
	wander_mult = 0.06,        -- fraction of speed while drifting (hordes meander: ~1 km/day net)
	seek_mult = 0.8,           -- fraction of speed while heading for a noise / the base
	turn_chance_per_min = 0.02,
	arrive_radius = 30,
	linger_min = 25,           -- minutes spent at a noise before drifting again
	noise_radius_per_loud = 3, -- attraction radius = loudness * this
	noise_keep = 24,           -- noise log ring (for the UI)
	noise = { gunshot = 110, shotgun = 140, rifle = 150, melee = 20, vehicle = 45, explosion = 200, helicopter = 170, screamer = 90,
		alarm = 130, building = 25, footsteps = 8, loot = 15, supply_drop = 120, generator = 30 },
	generator_noise_every = 60, -- running generators ping this often
	base_target_chance = 0.02, -- per-hour chance a drifting horde near the alert radius heads for the base anyway
	assault_round_min = 10,    -- minutes between abstract assault rounds
	assault_radius = 90,       -- hordes this close to the base centre assault it
	assault_rounds = 6,        -- combat_abstract rounds per assault round
	max_hordes = 24, merge_dist = 90, merge_every = 15,
	dissipate_days = 6,        -- an ambient horde unseen this long loses members
	dissipate_frac = 0.04,
	min_size_to_keep = 3,
	max_total = 900,           -- abstract zombies in the whole world
	ambient_count = 6, ambient_size = { 4, 20 },
	ambient_mix = { runner_min_size = 12, runner_chance = 0.35, runner_share = 0.12, brute_min_size = 25, brute_chance = 0.3 },
	assault_leave_mult = 1.5,  -- an assaulting horde further than assault_radius x this gives up and wanders
	base_pull_mult = 1.6,      -- drifting hordes within alert_radius x this may be drawn to the (noisy) base
	spawn_dist = { 1500, 2200 }, -- waves appear this far from the base
	alert_min_size = 8, alert_hold = 30,
	-- composition of a wave by pacing/threat: shares of the point budget spent on each type
	wave_shares = { walker = 0.62, runner = 0.20, brute = 0.12, screamer = 0.06 },
}

-- expeditions (abstract scavenging trips by vehicle) -------------------------------------------------
TUNING.expedition = {
	vehicles = {
		van = { name = "Cargo van", speed = 1.0, trunk_g = 120000, hp = 100 },
		pickup = { name = "Pickup truck", speed = 1.15, trunk_g = 60000, hp = 80 },
	},
	start_vehicles = { "van" },
	foot = { speed = 0.4, trunk_g = 30000, max_travel = 30, risk_mult = 1.25 }, -- vehicle-less runs: no fuel, nearby districts only
	crew_min = 1, crew_max = 4,
	fuel_min_per_can = 150,      -- round-trip minutes one fuel can covers (cans = ceil(round trip / this))
	loot_minutes = { 30, 70 },   -- time spent searching (scaled by district radius)
	loot_rolls = { 7, 12 },      -- base weighted rolls per run
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
	risk_floor = 0.3, risk_cap = 0.95, -- crew skill never cuts risk below floor x base; any leg stays under the cap
	ambush_spread = { 0.4, 1.0 },      -- fraction of the district's zombies met in one ambush
	xp_shoot_mult = 0.5, xp_melee_mult = 0.3,
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
	min_speed = 0.1,           -- floor on any worker speed
	ban_min = 30,              -- a job that failed for a colonist is skipped for this long
	sleep_max_min = 600,       -- longest single sleep
	sched_sleep_fatigue = 20,  -- fatigue at which a scheduled sleep hour actually puts a colonist to bed
	wake_day_fatigue = 45,     -- sleepers wake outside sleep hours once below this fatigue
	sick_hp = 0.6,             -- under this hp fraction a colonist prefers a medical bed
	rest_hp = 0.55,            -- under this hp fraction (or with symptoms) colonists rest instead of working
	rest_done_hp = 0.85,       -- resting ends above this hp fraction
	med_bed_pref = 400,        -- distance credit that makes sick colonists choose a medical bed
	powered_craft_bonus = 1.25,
	guard_xp = 0.15, repair_xp_mult = 0.6,
	kit_bleed = 0.3, kit_wounds = 3, -- tending uses a first-aid kit instead of a bandage above these
	feed_drink_bias = 1.3,
	sign_up_minutes = 60,      -- how long an expedition waits for volunteers
	fuel_reserve = 2,          -- generators are only refuelled while the stock holds more than this many cans (expeditions first)
}

-- power / water grid + weather --------------------------------------------------------------------
TUNING.grid = {
	mains_cap_w = 1400,         -- what the (failing) city grid can supply
	mains_power_dies_day = { 7, 13 },  -- city power fails for good on a random day in this range
	mains_water_dies_day = { 4, 9 },   -- city water stops for good on a random day in this range
	gen_min_per_l = 50,         -- generator runtime minutes per litre of fuel (a 20 L can = 1000 min)
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
	k_kill = 0.90,            -- attacker power removed per defender power per round
	k_damage = 0.40,          -- defender hp lost per attacker power per round (before walls)
	var_lo = 0.6, var_hi = 1.4, -- per-round randomness band (idea: CDDA's 0.6..1.4 skill roll band)
	hit_hp = 9,               -- one "hit" is about this much hp
	bite_share = 0.3,         -- share of zombie hits that are bites (rest scratches)
	barrier_k = 18,           -- wall_mult = 1 / (1 + barrier / barrier_k)
	wall_wear = 0.30,         -- barrier hp lost per attacker power per round
	ranged_wall_bonus = 0.35, -- shooters fire over walls: kill bonus * enclosure
	ammo_per_round = 4,       -- rounds fired per ranged defender per round
	out_of_ammo = 0.4,        -- ranged defender without ammo fights at this fraction
	guard_factor = 1.0,       -- readiness of colonists on guard / drafted
	awake_factor = 0.55,      -- readiness of awake colonists who are working
	sleep_factor = 0.30,      -- readiness of sleeping colonists
	downed_factor = 0.0,
	alarm_bonus = 1.3,        -- awake colonists' readiness multiplier while the base is on alert (capped at guard_factor)
	barrier_enclosure_base = 0.4, -- barrier strength = defense x (this + (1 - this) x enclosure) x hp fraction left
	raider_bullet_share = 0.7, -- share of raider hits that are bullets (the rest behave like melee scratches)
	bite_enclosure_cut = 0.6, -- bite share is reduced by this x enclosure
	breach_hp_frac = 0.25,    -- barrier counts as breached once this fraction of its hp is left
	xp_shoot_mult = 0.5, xp_melee_mult = 0.4, -- kill xp: skills.xp_per_kill x this, shared among those who fought
}
return TUNING
