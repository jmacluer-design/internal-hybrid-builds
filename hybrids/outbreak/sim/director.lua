-- director.lua : the storyteller.
--
-- threat points per day = mult(profile, day) * (base + colonist_k*colonists + wealth_k*sqrt(wealth) + day_k*(day-1))
-- accrue into a BUDGET (capped); threat events can only fire when the budget covers their cost and then SPEND it,
-- so threat never outruns what the colony has earned. Pacing profiles ("calm", "escalating", "chaos") change the
-- multiplier curve, the gap between threat-channel events, how much of the budget one event spends, surge chance,
-- and event weights. Boons (caravan, supply drop, refugees) run on their own timer and cost nothing.
-- (Idea only: the generic colony-sim "storyteller" pattern; the formula and tables here are original.)
local U = require("sim.util")
local TUNING = require("data.tuning")
local EV = require("data.events")
local clock = require("sim.clock")
local stockpile = require("sim.stockpile")
local blueprints = require("sim.blueprints")
local horde = require("sim.horde")
local factions = require("sim.factions")
local grid = require("sim.grid")
local needs = require("sim.needs")
local loot = require("sim.loot")
local items = require("sim.items")

local M = {}
local D = TUNING.director
local floor, sqrt = math.floor, math.sqrt

M.PROFILES = { "calm", "escalating", "chaos" }

function M.profile(name)
	local p = D.profiles[name]
	if not p then error("unknown pacing profile: " .. tostring(name), 2) end
	return p
end

local function progress(now)
	return U.clamp((clock.day(now) - 1) / 29, 0, 1)
end

function M.mult(profile_name, now)
	local p = M.profile(profile_name)
	return U.lerp(p.mult0, p.mult1, progress(now))
end

function M.wealth(w)
	return stockpile.wealth(w.s.zones) + blueprints.wealth(w)
end

-- threat points earned per in-game day right now
function M.points_per_day(w)
	local s = w.s
	local d = s.director
	local day = clock.day(s.t)
	local n = #s.colonists
	local raw = D.base_pts + D.colonist_k * n + D.wealth_k * sqrt(M.wealth(w)) + D.day_k * (day - 1)
	return M.mult(d.profile, s.t) * raw
end

local function gap_days(w, rng, channel)
	local d = w.s.director
	local p = M.profile(d.profile)
	local lo, hi
	if channel == "boon" then
		lo, hi = p.boon_gap[1], p.boon_gap[2]
	else
		local f = progress(w.s.t)
		lo = U.lerp(p.threat_gap[1], p.threat_gap_late[1], f)
		hi = U.lerp(p.threat_gap[2], p.threat_gap_late[2], f)
	end
	local g = rng:range(lo, hi)
	if channel ~= "boon" and rng:chance(p.surge_chance) then g = g * D.surge_gap_mult end
	return g
end

function M.init(w, profile)
	M.profile(profile) -- validate
	local s = w.s
	local rng = w:rng("director")
	local d = {
		profile = profile, budget = 0, accrued = 0, spent = 0, last_eval = s.t, rate = 0,
		cooldowns = {}, log = {}, by_day = {}, fired = {}, threat_events = 0, next_threat_t = 0, next_boon_t = 0,
	}
	s.director = d
	d.next_threat_t = s.t + floor((D.start_grace_days + gap_days(w, rng, "threat")) * 1440)
	d.next_boon_t = s.t + floor((D.start_grace_days + gap_days(w, rng, "boon")) * 1440)
end

local function day_key(t) return string.format("d%d", clock.day(t)) end

local function note_day(d, now, cat)
	local k = day_key(now)
	local row = d.by_day[k]
	if not row then
		row = { threat = 0, hazard = 0, boon = 0 }
		d.by_day[k] = row
		-- prune old days so the state stays bounded on long games
		local keys = U.keys(d.by_day)
		if #keys > D.by_day_keep then
			U.sort(keys, function(a, b) return tonumber(a:sub(2)) < tonumber(b:sub(2)) end)
			for i = 1, #keys - D.by_day_keep do d.by_day[keys[i]] = nil end
		end
	end
	row[cat] = row[cat] + 1
end

local function log_event(w, id, cat, cost, before, after, detail)
	local s = w.s
	local d = s.director
	local entry = { t = s.t, day = clock.day(s.t), event = id, cat = cat, cost = cost, budget_before = before, budget_after = after, detail = detail or "" }
	d.log[#d.log + 1] = entry
	if #d.log > D.log_cap then table.remove(d.log, 1) end
	d.fired[id] = (d.fired[id] or 0) + 1
	d.cooldowns[id] = s.t
	note_day(d, s.t, cat)
	if cat == "threat" then d.threat_events = d.threat_events + 1 end
	w:emit({ type = "director_log", event = id, cat = cat, cost = cost, budget_before = before, budget_after = after, detail = entry.detail, day = entry.day })
end

-- ---------------------------------------------------------------------------------------------
-- handlers: return a detail string on success, nil when the event cannot happen right now
-- ---------------------------------------------------------------------------------------------
local H = {}

H.horde_wave = function(w, ev, cost, rng)
	local mix = horde.mix_for_points(cost)
	local h = horde.spawn_wave(w, mix)
	if not h then return nil end
	w:notify("warn", string.format("A horde of about %d is moving toward the base.", h.size))
	return string.format("horde %s size %d from cell %d,%d", h.id, h.size, h.cx, h.cy)
end

H.gang_raid = function(w, ev, cost, rng)
	local r, why = factions.plan_raid(w, cost)
	if not r then return nil end
	return string.format("raid %s by %s, %d raiders", r.id, r.faction, r.count)
end

H.infection_outbreak = function(w, ev, cost, rng)
	local cands = {}
	for i = 1, #w.s.colonists do
		local c = w.s.colonists[i]
		if not c.dead and c.inf.stage == "none" then cands[#cands + 1] = c end
	end
	if #cands == 0 then return nil end
	local victims = 1 + floor(cost * D.infection_victims_per_cost)
	if victims > 3 then victims = 3 end
	if victims > #cands then victims = #cands end
	rng:shuffle(cands)
	local names = {}
	for i = 1, victims do
		needs.infect(cands[i], rng, rng:pick(needs.PARTS))
		names[#names + 1] = cands[i].id
	end
	w:notify("warn", "A sickness is going around the camp. Watch for fever.")
	return "infected " .. table.concat(names, ",")
end

H.helicopter_flyover = function(w, ev, cost, rng)
	local b = { x = TUNING.base.x, y = TUNING.base.y, z = TUNING.base.z }
	local hit = w:noise(b, TUNING.horde.noise.helicopter, "helicopter")
	w:emit({ type = "play_alert", kind = "helicopter" })
	w:notify("warn", "A helicopter passes overhead. The noise carries for miles.")
	w:add_thought_all("helicopter_hope")
	return string.format("noise reached %d hordes", hit)
end

H.power_outage = function(w, ev, cost, rng)
	local m = rng:int(ev.minutes[1], ev.minutes[2])
	grid.start_power_outage(w, m)
	w:notify("warn", string.format("Power outage (about %d minutes).", m))
	return string.format("power out %d min", m)
end

H.water_outage = function(w, ev, cost, rng)
	local m = rng:int(ev.minutes[1], ev.minutes[2])
	grid.start_water_outage(w, m)
	w:notify("warn", string.format("Water outage (about %d minutes).", m))
	return string.format("water out %d min", m)
end

H.storm = function(w, ev, cost, rng)
	local m = rng:int(ev.minutes[1], ev.minutes[2])
	grid.set_weather(w, "storm", m)
	local built = {}
	for i = 1, #w.s.buildings do if w.s.buildings[i].state == "built" then built[#built + 1] = w.s.buildings[i] end end
	local n = U.min(D.storm_buildings, #built)
	rng:shuffle(built)
	for i = 1, n do blueprints.damage(w, built[i], rng:range(D.storm_damage[1], D.storm_damage[2])) end
	w:notify("warn", string.format("A storm hits for about %d minutes.", m))
	return string.format("storm %d min, %d buildings damaged", m, n)
end

H.caravan = function(w, ev, cost, rng)
	local cands = {}
	for i = 1, #w.s.factions do
		local f = w.s.factions[i]
		if f.goodwill >= TUNING.factions.caravan_min_goodwill then
			local present = false
			for k = 1, #w.s.caravans do if w.s.caravans[k].faction == f.id then present = true end end
			if not present then cands[#cands + 1] = { f = f, w = U.max(1, f.goodwill + 50) } end
		end
	end
	local pick = rng:weighted(cands, "w")
	if not pick then return nil end
	local c = factions.spawn_caravan(w, pick.f.id)
	if not c then return nil end
	return "caravan " .. c.id .. " from " .. pick.f.id
end

H.supply_drop = function(w, ev, cost, rng)
	local b = TUNING.base
	local dv = horde.DIRS[rng:int(1, #horde.DIRS)]
	local dist = rng:range(D.supply_drop_dist[1], D.supply_drop_dist[2])
	local pos = { x = b.x + dv[1] * dist, y = b.y + dv[2] * dist, z = b.z }
	local pile = w:pile_for(pos)
	local bundle = loot.roll(w:rng("loot"), "military", { danger = 3, rolls = rng:int(D.supply_drop_rolls[1], D.supply_drop_rolls[2]) })
	local made = {}
	for _, id in ipairs(U.keys(bundle)) do
		local n = w:create(pile.items, id, bundle[id], "supply_drop")
		if n > 0 then made[id] = n end
	end
	w:emit({ type = "loot_spawn", container = "pile:" .. pile.id, items = made, source = "supply_drop", pos = U.pos_copy(pos) })
	w:emit({ type = "play_alert", kind = "supply_drop" })
	local hit = w:noise(pos, TUNING.horde.noise.supply_drop, "supply_drop")
	w:notify("info", "A supply crate has dropped near the base. The noise may draw company.")
	return string.format("drop at %d,%d (noise reached %d hordes)", floor(pos.x), floor(pos.y), hit)
end

H.refugee_arrival = function(w, ev, cost, rng)
	if #w.s.colonists >= TUNING.colonist.max_count then return nil end
	local c = w:add_refugee()
	if not c then return nil end
	return "refugee " .. c.id
end

-- extra eligibility checks beyond day/cooldown/budget
local function can_fire(w, ev)
	if ev.id == "refugee_arrival" and #w.s.colonists >= TUNING.colonist.max_count then return false end
	if ev.id == "infection_outbreak" and #w.s.colonists < 2 then return false end
	if ev.id == "horde_wave" and horde.total_size(w) >= TUNING.horde.max_total then return false end
	return true
end

local function radio_on(w)
	local masts = blueprints.list_tag(w, "radio", true)
	for i = 1, #masts do if masts[i].powered then return true end end
	return false
end

-- one threat-channel attempt (threat + hazard events). Returns true if something fired.
local function try_threat(w, rng)
	local s = w.s
	local d = s.director
	local p = M.profile(d.profile)
	local day = clock.day(s.t)
	local cands = {}
	for i = 1, #EV.order do
		local ev = EV[EV.order[i]]
		if ev.cat ~= "boon" and day >= ev.min_day and can_fire(w, ev) then
			local last = d.cooldowns[ev.id]
			local ready = (last == nil) or (s.t - last >= ev.cooldown_days * 1440)
			local need = ev.min_cost or ev.fixed_cost or 0
			if ready and d.budget >= need then
				cands[#cands + 1] = { ev = ev, w = ev.weight * (p.weights[ev.id] or 1) }
			end
		end
	end
	local pick = rng:weighted(cands, "w")
	if not pick then return false end
	local ev = pick.ev
	local cost
	if ev.fixed_cost then
		cost = ev.fixed_cost
	else
		local frac = rng:range(p.spend_frac[1], p.spend_frac[2])
		cost = U.max(ev.min_cost, U.min(ev.max_cost, d.budget * frac))
	end
	if cost > d.budget then cost = d.budget end
	local detail = H[ev.id](w, ev, cost, rng)
	if not detail then
		d.cooldowns[ev.id] = s.t - ev.cooldown_days * 1440 + D.retry_minutes -- try something else, retry this one later
		return false
	end
	local before = d.budget
	d.budget = d.budget - cost
	d.spent = d.spent + cost
	log_event(w, ev.id, ev.cat, cost, before, d.budget, detail)
	return true
end

local function try_boon(w, rng)
	local s = w.s
	local d = s.director
	local p = M.profile(d.profile)
	local day = clock.day(s.t)
	local radio = radio_on(w)
	local cands = {}
	for i = 1, #EV.order do
		local ev = EV[EV.order[i]]
		if ev.cat == "boon" and day >= ev.min_day and can_fire(w, ev) then
			local last = d.cooldowns[ev.id]
			if last == nil or s.t - last >= ev.cooldown_days * 1440 then
				local wt = ev.weight * (p.weights[ev.id] or 1)
				if radio and (ev.id == "caravan" or ev.id == "refugee_arrival") then wt = wt * D.radio_mult end
				cands[#cands + 1] = { ev = ev, w = wt }
			end
		end
	end
	local pick = rng:weighted(cands, "w")
	if not pick then return false end
	local ev = pick.ev
	local detail = H[ev.id](w, ev, 0, rng)
	if not detail then
		d.cooldowns[ev.id] = s.t - ev.cooldown_days * 1440 + D.retry_minutes
		return false
	end
	log_event(w, ev.id, ev.cat, 0, d.budget, d.budget, detail)
	return true
end

-- Fire one event now, outside the schedule (debug tools, tests, scripted scenarios). Threat/hazard events still pay
-- from the budget: it must cover `cost` (default: the event's own minimum). Returns the detail string or nil, reason.
function M.force(w, id, cost)
	local ev = EV[id]
	if not ev then return nil, "unknown_event" end
	local d = w.s.director
	local rng = w:rng("director")
	if ev.cat == "boon" then
		if not can_fire(w, ev) then return nil, "not_possible" end
		local detail = H[id](w, ev, 0, rng)
		if not detail then return nil, "not_possible" end
		log_event(w, id, ev.cat, 0, d.budget, d.budget, detail)
		return detail
	end
	if not can_fire(w, ev) then return nil, "not_possible" end
	cost = cost or ev.fixed_cost or ev.min_cost
	if cost > d.budget then return nil, "over_budget" end
	local detail = H[id](w, ev, cost, rng)
	if not detail then return nil, "not_possible" end
	local before = d.budget
	d.budget = d.budget - cost
	d.spent = d.spent + cost
	log_event(w, id, ev.cat, cost, before, d.budget, detail)
	return detail
end

-- advance dt minutes
function M.step(w, dt)
	local s = w.s
	local d = s.director
	local p = M.profile(d.profile)
	-- accrue budget
	local cap = d.rate * 1440 * D.budget_cap_days
	local earn = d.rate * dt
	d.accrued = d.accrued + earn
	d.budget = d.budget + earn
	if cap > 0 and d.budget > cap then d.budget = cap end
	if s.t - d.last_eval < D.eval_interval then return end
	d.last_eval = s.t
	d.rate = M.points_per_day(w) / 1440
	if clock.day(s.t) < 1 + D.start_grace_days then return end
	local rng = w:rng("director")
	if s.t >= d.next_threat_t then
		if try_threat(w, rng) then
			d.next_threat_t = s.t + floor(gap_days(w, rng, "threat") * 1440)
		end
	end
	if s.t >= d.next_boon_t then
		if try_boon(w, rng) then
			d.next_boon_t = s.t + floor(gap_days(w, rng, "boon") * 1440)
		end
	end
end

-- summary for tests / reports: { threat_days, quiet_days, events_per_day }
function M.stats(w, days)
	local d = w.s.director
	local threat_days, hazard_days, events = 0, 0, 0
	for i = 1, days do
		local row = d.by_day[string.format("d%d", i)]
		if row then
			if row.threat > 0 then threat_days = threat_days + 1 end
			events = events + row.threat + row.hazard + row.boon
		end
	end
	return { threat_days = threat_days, quiet_days = days - threat_days, events = events }
end

return M
