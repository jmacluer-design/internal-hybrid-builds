-- shared/view.lua : READ-ONLY view models of the sim state for the NUI (colony UI, inventory, HUD, summary).
-- Pure Lua, no game calls, never writes to the world: the same file feeds the FiveM server (-> client -> SendNUIMessage) and the
-- browser preview (wasmoon). Everything it returns is plain data that is msgpack-safe and JSON-friendly (checked by the tests).
-- Per API.md: "w.s is the plain-data state (read it for UI). Do not write to it from the adapter."
local U = require("shared.util")
local SU = require("sim.util")
local TUNING = require("data.tuning")
local ITEMS = require("data.items")
local BP = require("data.blueprints")
local TRAITS = require("data.traits")
local THOUGHTS = require("data.thoughts")
local DISTRICTS = require("data.districts")
local FACTIONS = require("data.factions")
local EVENTS = require("data.events")
local clock = require("sim.clock")
local items = require("sim.items")
local mood = require("sim.mood")
local needs = require("sim.needs")
local skills = require("sim.skills")
local traits = require("sim.traits")
local colonist = require("sim.colonist")
local stockpile = require("sim.stockpile")
local blueprints = require("sim.blueprints")

local V = {}
V.VERSION = 1

local r1, r2, floor = U.r1, U.r2, math.floor
local keys = SU.keys

-- ---------------------------------------------------------------------------------------------------------------------
-- static catalog (sent once)
-- ---------------------------------------------------------------------------------------------------------------------
local ITEM_CAT_ORDER = { "food", "drink", "medical", "weapon", "ammo", "material", "fuel", "tool", "valuable", "ingredient" }
local BP_CAT_ORDER = { "structure", "defense", "furniture", "production", "power", "storage", "water", "utility" }

local function sorted_ids_by(order, defs, key)
	local rank = {}
	for i, c in ipairs(order) do rank[c] = i end
	local ids = keys(defs)
	table.sort(ids, function(a, b)
		local ra, rb = rank[defs[a][key]] or 99, rank[defs[b][key]] or 99
		if ra ~= rb then return ra < rb end
		return (defs[a].name or a) < (defs[b].name or b)
	end)
	return ids
end

function V.catalog()
	local it = {}
	for _, id in ipairs(keys(ITEMS)) do
		local d = ITEMS[id]
		local e = { name = d.name, cat = d.cat, w = d.w, stack = d.stack, value = d.value }
		if d.food then e.food = { hunger = d.food.hunger or 0, thirst = d.food.thirst or 0 } end
		if d.med then e.med = { kind = d.med.kind, power = d.med.power } end
		if d.weapon then e.weapon = { kind = d.weapon.kind, power = d.weapon.power, ammo = d.weapon.ammo, noise = d.weapon.noise } end
		if d.fuel_l then e.fuel_l = d.fuel_l end
		if d.burn_min then e.burn_min = d.burn_min end
		it[id] = e
	end
	local bps = {}
	for _, id in ipairs(keys(BP)) do
		local d = BP[id]
		local tags = {}
		for _, t in ipairs(keys(d.tags)) do tags[#tags + 1] = t end
		bps[id] = { name = d.name, cat = d.cat, materials = SU.copy(d.materials), work = d.work, skill_min = d.skill_min, needs = d.needs and SU.copy(d.needs) or {},
			max = d.max or 0, hp = d.hp, power_use = d.power_use or 0, power_gen = d.power_gen or 0, defense = d.defense or 0, value = d.value,
			size = { d.size[1], d.size[2] }, tags = tags, storage_g = d.storage_g or 0, tank_l = d.tank_l or 0 }
	end
	local tr = {}
	for _, id in ipairs(keys(TRAITS)) do tr[id] = { name = TRAITS[id].name, desc = TRAITS[id].desc } end
	local th = {}
	for _, id in ipairs(keys(THOUGHTS)) do th[id] = { label = THOUGHTS[id].label, value = THOUGHTS[id].value } end
	local dist = {}
	for _, id in ipairs(keys(DISTRICTS)) do
		local d = DISTRICTS[id]
		dist[#dist + 1] = { id = id, name = d.name, kind = d.kind, x = d.x, y = d.y, radius = d.radius, danger = d.danger, travel = d.travel, zombies = d.zombies }
	end
	local facs = {}
	for _, id in ipairs(FACTIONS.order) do
		local d = FACTIONS.defs[id]
		facs[#facs + 1] = { id = id, name = d.name, kind = d.kind, blurb = d.blurb }
	end
	local evs = {}
	for _, id in ipairs(EVENTS.order) do evs[#evs + 1] = { id = id, cat = EVENTS[id].cat, desc = EVENTS[id].desc } end
	local directors = require("sim.director")
	return {
		v = V.VERSION, items = it, item_cats = ITEM_CAT_ORDER, item_order = sorted_ids_by(ITEM_CAT_ORDER, ITEMS, "cat"),
		blueprints = bps, blueprint_cats = BP_CAT_ORDER, blueprint_order = sorted_ids_by(BP_CAT_ORDER, BP, "cat"),
		traits = tr, thoughts = th, skills = SU.copy(skills.list), work = SU.copy(colonist.WORK), districts = dist, factions = facs, events = evs,
		profiles = SU.copy(directors.PROFILES),
		tuning = {
			map = SU.copy(TUNING.map), base = { x = TUNING.base.x, y = TUNING.base.y, radius = TUNING.base.radius, build_radius = TUNING.base.build_radius,
				alert_radius = TUNING.base.alert_radius, min_spacing = TUNING.base.min_spacing, garage = SU.copy(TUNING.base.garage) },
			player = SU.copy(TUNING.player), colonist_slots = TUNING.colonist.slots, max_colonists = TUNING.colonist.max_count,
			r_materialize = TUNING.horde.R_materialize, r_dematerialize = TUNING.horde.R_dematerialize, max_materialized = TUNING.horde.max_materialized,
			mood_break = SU.copy(TUNING.mood.break_levels),
		},
	}
end

-- ---------------------------------------------------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------------------------------------------------
local JOB_LABELS = {
	["goto"] = "Walking", haul = "Hauling", deliver = "Delivering materials", unload = "Stocking supplies", build = "Building", repair = "Repairing",
	cook = "Cooking", craft = "Crafting", tend = "Tending a patient", medicate = "Giving medicine", amputate = "Operating", feed = "Feeding a patient",
	guard = "Standing guard", scavenge = "On a scavenging run", refuel = "Refuelling", eat = "Eating", drink = "Drinking", sleep = "Sleeping",
	rest = "Resting", binge = "Binge eating", wander = "Wandering off", draft = "Drafted", equip = "Equipping", idle = "Idle",
}

local function job_label(w, c)
	local j = c.job
	if c.state == "away" then return "Away on an expedition", "away" end
	if c.downed then return "Down (needs care)", "downed" end
	if not j then return c.drafted and "Drafted" or "Idle", c.drafted and "draft" or "idle" end
	local base = JOB_LABELS[j.kind] or j.kind
	local t = j.target
	if t and t.kind == "building" and t.id then
		local b = w:building(t.id)
		if b and BP[b.bp] then base = base .. " " .. BP[b.bp].name:lower() end
	elseif t and t.kind == "colonist" and t.id then
		local o = w:colonist(t.id)
		if o then base = base .. ": " .. o.name:gsub(' ".*"$', "") end
	end
	return base, j.kind
end

local function mood_name(m)
	if m >= 65 then return "Content" elseif m >= 45 then return "Okay" elseif m >= 30 then return "Uneasy" elseif m >= 20 then return "Stressed" end
	return "Breaking"
end

local function visible_infection(c)
	local st = c.inf and c.inf.stage or "none"
	if st == "incubating" then return "none" end
	return st
end

local function cont_weight_kg(g) return r2((g or 0) / 1000) end

-- per-colonist compact row (roster, map, priorities)
local function colonist_row(w, c, now)
	local label, jk = job_label(w, c)
	local pr = {}
	for _, wt in ipairs(colonist.WORK) do pr[wt] = colonist.priority(c, wt) end
	local sk = {}
	for _, sname in ipairs(skills.list) do sk[sname] = skills.level(c, sname) end
	return {
		id = c.id, name = c.name, state = c.state, job = jk, job_label = label, hp = r1(c.hp), hp_max = c.hp_max, hunger = r1(c.hunger), thirst = r1(c.thirst),
		fatigue = r1(c.fatigue), pain = r1(needs.perceived_pain(c, now)), bleeding = r2(needs.bleeding(c)), infection = visible_infection(c), mood = r1(c.mood),
		mood_break = c.mbreak and c.mbreak.kind or nil, downed = c.downed, drafted = c.drafted, maimed = c.maimed,
		x = r1(c.pos.x), y = r1(c.pos.y), weapon = (colonist.best_weapon(c)), prio = pr, skill = sk, inv_w = c.inv.w, inv_cap = c.inv.cap,
		blocked = (function()
			local b = {}
			for _, wt in ipairs(colonist.WORK) do if not colonist.can_work(c, wt) then b[wt] = true end end
			return b
		end)(),
		traits = SU.copy(c.traits),
	}
end

-- full detail card for one colonist
function V.card(w, c)
	if not c then return nil end
	local now = w.s.t
	local row = colonist_row(w, c, now)
	local th = {}
	for i = 1, #c.thoughts do
		local e = c.thoughts[i]
		local val = mood.entry_value(e, now)
		if val ~= 0 then
			local d = THOUGHTS[e.id]
			th[#th + 1] = { id = e.id, label = d and d.label or e.id, value = r1(val), left = floor(e.dur - (now - e.t0)) }
		end
	end
	table.sort(th, function(a, b)
		local aa, bb = math.abs(a.value), math.abs(b.value)
		if aa ~= bb then return aa > bb end
		return a.id < b.id
	end)
	local sk = {}
	for _, sname in ipairs(skills.list) do
		local s = c.skills[sname] or { l = 0, xp = 0 }
		local cur, nxt = skills.xp_for_level(s.l), skills.xp_for_level(s.l + 1)
		local pct = (s.l >= skills.max_level()) and 1 or ((nxt > cur) and (s.xp - cur) / (nxt - cur) or 0)
		sk[#sk + 1] = { id = sname, level = s.l, pct = r2(U.clamp(pct, 0, 1)), speed = r2(skills.speed(c, sname)) }
	end
	local tr = {}
	for _, id in ipairs(c.traits) do
		local d = TRAITS[id]
		tr[#tr + 1] = { id = id, name = d and d.name or id, desc = d and d.desc or "" }
	end
	local wounds = {}
	for i = 1, #c.wounds do
		local wd = c.wounds[i]
		wounds[#wounds + 1] = { part = wd.part, kind = wd.kind, bleed = r2(wd.bleed), age = floor(wd.age or 0) }
	end
	local inv = {}
	for _, it in ipairs(items.list(c.inv)) do
		local d = ITEMS[it.id]
		inv[#inv + 1] = { id = it.id, n = it.n, name = d.name, cat = d.cat, w = d.w * it.n }
	end
	local m = c.mood
	local mt = TUNING.mood
	local brk
	if c.mbreak then brk = { kind = c.mbreak.kind, level = c.mbreak.level, left = floor(c.mbreak.until_t - now) } end
	local card = row
	card.age = c.age
	card.str = c.str
	card.kills = floor(c.kills or 0)
	card.joined_day = clock.day(c.joined or 0)
	card.sched = c.sched
	card.allow_amputation = c.allow_amputation and true or false
	card.mood_name = mood_name(m)
	card.mood_parts = { base = mt.base + traits.add(c, "mood_base"), thoughts = r1(mood.thoughts_total(c, now)), needs = r1(mood.needs_total(c, now)) }
	card.mood_break_info = brk
	card.thoughts = th
	card.skills = sk
	card.trait_info = tr
	card.wounds = wounds
	card.items = inv
	card.work_speed = r2(needs.work_speed(c, now))
	card.carry = { w = c.inv.w, cap = c.inv.cap, slots = c.inv.slots, used = c.inv.s }
	card.sched_now = colonist.schedule_at(c, clock.hour(now))
	return card
end

-- horizontal threat summary around the player (or the base when the player position is unknown)
local function threat_summary(w, ppos)
	local s = w.s
	local base = TUNING.base
	local origin = ppos or { x = base.x, y = base.y }
	local alert_r = base.alert_radius
	local level, nearest = 0, nil
	local function consider(kind, id, x, y, size, name)
		local dx, dy = x - origin.x, y - origin.y
		local dist = math.sqrt(dx * dx + dy * dy)
		local bdx, bdy = x - base.x, y - base.y
		local bdist = math.sqrt(bdx * bdx + bdy * bdy)
		local prox = U.clamp(1 - math.min(dist, bdist) / alert_r, 0, 1)
		level = level + prox * (kind == "raid" and size / 8 or size / 30)
		if prox > 0 and (not nearest or dist < nearest.dist) then
			nearest = { kind = kind, id = id, dist = r1(dist), bearing = floor(U.bearing(origin, { x = x, y = y }) + 0.5) % 360, size = size, name = name }
		end
	end
	for i = 1, #s.hordes do local h = s.hordes[i]; consider("horde", h.id, h.x, h.y, h.size) end
	for i = 1, #s.raids do
		local r = s.raids[i]
		local fd = FACTIONS.defs[r.faction]
		consider("raid", r.id, r.x, r.y, r.count, fd and fd.name or r.faction)
	end
	if s.alert > 0 then level = math.max(level, 0.35) end
	level = U.clamp(level, 0, 1)
	local label = "Quiet"
	if level >= 0.85 then label = "Critical" elseif level >= 0.6 then label = "High" elseif level >= 0.3 then label = "Elevated" elseif level > 0.05 then label = "Low" end
	return { level = r2(level), label = label, nearest = nearest }
end

-- ---------------------------------------------------------------------------------------------------------------------
-- colony state
-- ---------------------------------------------------------------------------------------------------------------------
local function category_totals(w, tot)
	local c = { food = 0, drink = 0, medical = 0, ammo = 0, fuel = 0, material = 0, weapon = 0 }
	local food_pts, drink_pts = 0, 0
	for _, id in ipairs(keys(tot)) do
		local d = ITEMS[id]
		local n = tot[id]
		if c[d.cat] ~= nil then c[d.cat] = c[d.cat] + n end
		if d.food then
			food_pts = food_pts + (d.food.hunger or 0) * n
			drink_pts = drink_pts + (d.food.thirst or 0) * n
		end
	end
	return c, food_pts, drink_pts
end

-- opts: { select = colonist id, speed = n, paused = bool, scale = n, player = {x,y} }
function V.state(w, opts)
	opts = opts or {}
	local s = w.s
	local now = s.t
	local n = #s.colonists
	local snap = w:snapshot()
	local tot = stockpile.totals(s.zones)
	local cats, food_pts, drink_pts = category_totals(w, tot)
	local daily = math.max(1, n) * TUNING.needs.hunger_per_min * 1440
	local ppos = (opts.player or s.player.pos)
	local power = s.grid.power
	local water = s.grid.water

	local cols = {}
	for i = 1, n do cols[i] = colonist_row(w, s.colonists[i], now) end

	local hordes = {}
	for i = 1, math.min(#s.hordes, 40) do
		local h = s.hordes[i]
		hordes[#hordes + 1] = { id = h.id, x = r1(h.x), y = r1(h.y), size = h.size, mix = SU.copy(h.mix), state = h.state, hx = r2(h.hx), hy = r2(h.hy),
			mat = h.mat and h.mat.count or 0, src = h.src, cx = h.cx, cy = h.cy }
	end
	local raids = {}
	for i = 1, #s.raids do
		local r = s.raids[i]
		local fd = FACTIONS.defs[r.faction]
		raids[#raids + 1] = { id = r.id, faction = r.faction, name = fd and fd.name or r.faction, x = r1(r.x), y = r1(r.y), count = r.count, state = r.state }
	end
	local bs = {}
	for i = 1, #s.buildings do
		local b = s.buildings[i]
		local d = BP[b.bp]
		local e = { id = b.id, bp = b.bp, x = r1(b.pos.x), y = r1(b.pos.y), state = b.state, hp = r1(b.hp), hp_max = b.hp_max, powered = b.powered and true or false,
			enabled = b.enabled ~= false, pct = (d.work > 0) and floor(b.progress / d.work * 100) or 0 }
		if b.state == "planned" then
			local miss = blueprints.missing(b)
			if next(miss) then e.missing = miss end
		end
		if b.fuel_min then e.fuel_min = floor(b.fuel_min) end
		bs[#bs + 1] = e
	end
	local piles = {}
	for i = 1, #s.piles do
		local p = s.piles[i]
		piles[#piles + 1] = { id = p.id, x = r1(p.pos.x), y = r1(p.pos.y), w = p.items.w, n = items.total_count(p.items) }
	end
	local zones = {}
	for i = 1, #s.zones do
		local z = s.zones[i]
		local cats_list
		if z.filter.cats then
			cats_list = {}
			for _, c in ipairs(keys(z.filter.cats)) do if z.filter.cats[c] then cats_list[#cats_list + 1] = c end end
		end
		local top = {}
		local lst = items.list(z.items)
		table.sort(lst, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.id < b.id end)
		for k = 1, math.min(5, #lst) do top[k] = { id = lst[k].id, n = lst[k].n } end
		zones[#zones + 1] = { id = z.id, name = z.name, x = r1(z.pos.x), y = r1(z.pos.y), tiles = z.tiles, prio = z.prio, main = z.main and true or false,
			cats = cats_list, w = z.items.w, cap = z.items.cap, stacks = z.items.s, top = top }
	end
	local stock = {}
	for _, id in ipairs(keys(tot)) do stock[#stock + 1] = { id = id, n = tot[id] } end

	local exps = {}
	for i = 1, #s.exped do
		local x = s.exped[i]
		exps[#exps + 1] = { id = x.id, district = x.district, state = x.state, mode = x.mode, crew = SU.copy(x.crew), vehicle = x.vehicle, want = x.want_crew,
			deadline = x.state == "forming" and floor(x.form_deadline - now) or nil }
	end
	local vehicles = {}
	for i = 1, #s.vehicles do vehicles[i] = { id = s.vehicles[i].id, kind = s.vehicles[i].kind, hp = s.vehicles[i].hp, state = s.vehicles[i].state } end
	local caravans = {}
	for i = 1, #s.caravans do
		local c = s.caravans[i]
		local fd = FACTIONS.defs[c.faction]
		local stk = {}
		for _, it in ipairs(items.list(c.stock)) do stk[#stk + 1] = { id = it.id, n = it.n } end
		caravans[#caravans + 1] = { id = c.id, faction = c.faction, name = fd and fd.name or c.faction, leave_in = floor(c.leave_t - now), stock = stk,
			x = r1(TUNING.base.garage.x + 10), y = r1(TUNING.base.garage.y + 15) }
	end
	local facs = {}
	for i = 1, #s.factions do
		local f = s.factions[i]
		local fd = FACTIONS.defs[f.id]
		facs[#facs + 1] = { id = f.id, name = fd and fd.name or f.id, kind = fd and fd.kind or "gang", goodwill = r1(f.goodwill), truce_left = math.max(0, floor((f.truce_until or 0) - now)),
			raids = f.raids, trades = f.trades }
	end

	local d = s.director
	local dlog = {}
	local from = math.max(1, #d.log - 39)
	for i = #d.log, from, -1 do
		local e = d.log[i]
		dlog[#dlog + 1] = { t = e.t, day = e.day, event = e.event, cat = e.cat, cost = r1(e.cost), before = r1(e.budget_before), after = r1(e.budget_after), detail = e.detail }
	end
	local D = TUNING.director
	local director = {
		profile = d.profile, budget = r1(d.budget), cap = r1(d.rate * 1440 * D.budget_cap_days), rate_day = r1(d.rate * 1440), spent = r1(d.spent),
		accrued = r1(d.accrued), threat_events = d.threat_events, next_threat_in = math.max(0, floor(d.next_threat_t - now)),
		next_boon_in = math.max(0, floor(d.next_boon_t - now)), log = dlog, fired = SU.copy(d.fired),
		grace_left = math.max(0, floor(clock.at(1 + D.start_grace_days, 0, 0) - now)),
	}
	local hist = {}
	for i = math.max(1, #s.history - 39), #s.history do
		local h = s.history[i]
		hist[#hist + 1] = { day = h.day, colonists = h.colonists, mood = r1(h.mood), food = h.food, water = h.water, wealth = r1(h.wealth), budget = r1(h.budget or 0) }
	end
	local dead = {}
	for i = math.max(1, #s.dead - 19), #s.dead do
		local x = s.dead[i]
		dead[#dead + 1] = { id = x.id, name = x.name, cause = x.cause, day = x.day, turns = x.turns, left = x.left and true or false }
	end

	local out = {
		v = V.VERSION, t = now, day = snap.day, hour = clock.hour(now), minute = clock.minute(now), clock = string.format("%02d:%02d", clock.hour(now), floor(clock.minute(now))),
		daylight = r2(clock.daylight(now)), night = clock.is_night(now), season = clock.season(now), weather = { kind = s.grid.weather.kind, left = math.max(0, floor(s.grid.weather.until_t - now)) },
		profile = s.profile, seed = s.seed, over = s.over, speed = opts.speed or 1, paused = opts.paused and true or false, scale = opts.scale,
		base = { x = TUNING.base.x, y = TUNING.base.y, radius = TUNING.base.radius, build_radius = TUNING.base.build_radius, alert_radius = TUNING.base.alert_radius },
		player = ppos and { x = r1(ppos.x), y = r1(ppos.y) } or nil,
		res = { colonists = n, max_colonists = TUNING.colonist.max_count, mood = r1(snap.mood), hurt = snap.hurt, food = snap.food, drink = snap.drink, food_days = r1(food_pts / daily),
			bottled = tot.water_bottle or 0, medical = cats.medical, ammo = cats.ammo, fuel = tot.fuel_can or 0, material = cats.material, weapons = cats.weapon, wealth = r1(snap.wealth),
			defense = r1(snap.defense), enclosure = r2(snap.enclosure), water_tank = r1(water.tank), tank_cap = r1(require("sim.grid").tank_cap(w)),
			power_supply = power.supply, power_demand = power.demand, power_ok = power.ok and true or false, mains_power = power.mains_on and true or false,
			water_ok = water.ok and true or false, mains_water = (not water.mains_dead and now >= water.outage_until), vehicles = #s.vehicles,
			stock_g = (function() local g = 0 for i = 1, #s.zones do g = g + s.zones[i].items.w end return g end)(),
			stock_cap = (function() local g = 0 for i = 1, #s.zones do g = g + (s.zones[i].items.cap or 0) end return g end)() },
		alert = s.alert, threat = threat_summary(w, ppos), hordes = hordes, raids = raids, horde_total = snap.horde_size,
		colonists = cols, buildings = bs, piles = piles, zones = zones, stock = stock, expeditions = exps, vehicles = vehicles, caravans = caravans,
		factions = facs, director = director, history = hist, dead = dead, stats = SU.copy(s.stats),
		beds = blueprints.beds(w),
	}
	if opts.select then
		local c = w:colonist(opts.select)
		if c then out.card = V.card(w, c) end
	end
	return out
end

-- ---------------------------------------------------------------------------------------------------------------------
-- inventory
-- ---------------------------------------------------------------------------------------------------------------------
local function stacks_of(cont)
	local list = items.list(cont)
	local rank = {}
	for i, c in ipairs(ITEM_CAT_ORDER) do rank[c] = i end
	table.sort(list, function(a, b)
		local da, db = ITEMS[a.id], ITEMS[b.id]
		local ra, rb = rank[da.cat] or 99, rank[db.cat] or 99
		if ra ~= rb then return ra < rb end
		if da.name ~= db.name then return da.name < db.name end
		return a.id < b.id
	end)
	local out = {}
	for _, it in ipairs(list) do
		local d = ITEMS[it.id]
		local left = it.n
		while left > 0 do
			local take = math.min(left, d.stack)
			out[#out + 1] = { id = it.id, n = take, w = d.w * take }
			left = left - take
		end
	end
	return out
end

local function cont_view(kind, id, label, cont)
	return { kind = kind, id = id, label = label, w = cont.w, cap = cont.cap, slots = cont.slots, used = cont.s, stacks = stacks_of(cont) }
end

-- spec = { other = { kind = "zone"|"colonist"|"pile"|"container", id = "..." } }
function V.inventory(w, spec)
	spec = spec or {}
	local s = w.s
	local out = { player = cont_view("player", "player", "You", s.player.inv), nearby = {} }
	local pp = s.player.pos or { x = TUNING.base.x, y = TUNING.base.y }
	for i = 1, #s.zones do
		local z = s.zones[i]
		out.nearby[#out.nearby + 1] = { kind = "zone", id = z.id, label = z.name, dist = r1(U.dist2d(pp, z.pos)) }
	end
	for i = 1, #s.piles do
		local p = s.piles[i]
		out.nearby[#out.nearby + 1] = { kind = "pile", id = p.id, label = "Ground pile", dist = r1(U.dist2d(pp, p.pos)) }
	end
	for i = 1, #s.colonists do
		local c = s.colonists[i]
		out.nearby[#out.nearby + 1] = { kind = "colonist", id = c.id, label = c.name, dist = r1(U.dist2d(pp, c.pos)) }
	end
	for _, k in ipairs(keys(s.containers)) do
		local c = s.containers[k]
		out.nearby[#out.nearby + 1] = { kind = "container", id = k, label = (c.ctype or "container"):gsub("^%l", string.upper), dist = 0 }
	end
	table.sort(out.nearby, function(a, b) if a.dist ~= b.dist then return a.dist < b.dist end return a.id < b.id end)
	local o = spec.other
	if o and o.kind and o.id then
		local cont, label
		if o.kind == "zone" then local z = w:zone(o.id); cont, label = z and z.items, z and z.name
		elseif o.kind == "pile" then local p = w:pile(o.id); cont, label = p and p.items, "Ground pile"
		elseif o.kind == "colonist" then local c = w:colonist(o.id); cont, label = c and c.inv, c and c.name
		elseif o.kind == "container" then local c = s.containers[o.id]; cont, label = c and c.items, c and (c.ctype or "Container") end
		if cont then out.other = cont_view(o.kind, o.id, label or o.id, cont) end
	end
	return out
end

-- ---------------------------------------------------------------------------------------------------------------------
-- survival HUD
-- ---------------------------------------------------------------------------------------------------------------------
-- body: the player's survival body (shared/survival.lua view) or nil
function V.hud(w, body, opts)
	opts = opts or {}
	local s = w.s
	local now = s.t
	local inv = s.player.inv
	local b = body or {}
	local pp = s.player.pos
	local threat = threat_summary(w, pp)
	return {
		v = V.VERSION, hp = r1(b.hp or 100), hp_max = b.hp_max or 100, hunger = r1(b.hunger or 0), thirst = r1(b.thirst or 0), fatigue = r1(b.fatigue or 0),
		pain = r1(b.pain or 0), bleeding = r2(b.bleeding or 0), infection = b.infection or "none", downed = b.downed and true or false,
		weight = cont_weight_kg(inv.w), weight_max = cont_weight_kg(inv.cap), slots_used = inv.s, slots_max = inv.slots,
		day = clock.day(now), hour = clock.hour(now), minute = floor(clock.minute(now)), clock = string.format("%02d:%02d", clock.hour(now), floor(clock.minute(now))),
		daylight = r2(clock.daylight(now)), night = clock.is_night(now), season = clock.season(now), weather = s.grid.weather.kind,
		power_ok = s.grid.power.ok and true or false, water_ok = s.grid.water.ok and true or false, alert = s.alert, threat = threat,
		colonists = #s.colonists, over = s.over, base_bearing = pp and floor(U.bearing(pp, { x = TUNING.base.x, y = TUNING.base.y }) + 0.5) % 360 or nil,
		base_dist = pp and r1(U.dist2d(pp, { x = TUNING.base.x, y = TUNING.base.y })) or nil, speed = opts.speed, paused = opts.paused and true or false,
	}
end

-- ---------------------------------------------------------------------------------------------------------------------
-- collapse / summary
-- ---------------------------------------------------------------------------------------------------------------------
function V.summary(w)
	local s = w.s
	local st = s.stats
	local causes = {}
	for i = 1, #s.dead do
		local d = s.dead[i]
		causes[d.cause] = (causes[d.cause] or 0) + 1
	end
	local hist = {}
	for i = 1, #s.history do
		local h = s.history[i]
		hist[#hist + 1] = { day = h.day, colonists = h.colonists, mood = r1(h.mood), food = h.food, wealth = r1(h.wealth) }
	end
	local dead = {}
	for i = 1, #s.dead do dead[#dead + 1] = { id = s.dead[i].id, name = s.dead[i].name, cause = s.dead[i].cause, day = s.dead[i].day, turns = s.dead[i].turns } end
	local peak = 0
	for i = 1, #s.history do if s.history[i].wealth > peak then peak = s.history[i].wealth end end
	local director = s.director
	return {
		over = s.over, day = clock.day(s.t), survived_days = clock.day(s.t) - 1, profile = s.profile, seed = s.seed, stats = SU.copy(st), causes = causes,
		history = hist, dead = dead, wealth_peak = r1(peak), threat_events = director.threat_events, fired = SU.copy(director.fired),
		alive = #s.colonists, colonists_ever = #s.colonists + #s.dead,
	}
end

return V
