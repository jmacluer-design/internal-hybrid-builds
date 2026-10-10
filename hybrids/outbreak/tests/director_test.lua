-- director: budgets, cooldowns, min-day gates, pacing profiles, event handlers.
local T = ...
package.path = T.root .. "/?.lua;" .. T.root .. "/tests/?.lua;" .. package.path
local H = require("helpers").init(T.root)
local U = require("sim.util")
local TUNING = require("data.tuning")
local EV = require("data.events")
local director = require("sim.director")
local runner = require("sim.runner")
local horde = require("sim.horde")
local factions = require("sim.factions")
local grid = require("sim.grid")
local clock = require("sim.clock")
local items = require("sim.items")
local needs = require("sim.needs")
local blueprints = require("sim.blueprints")
local World = require("sim.world")

local D = TUNING.director

T.group("director")

T.test("event table has every required event with weights, cooldowns and min days", function()
	local required = { "horde_wave", "gang_raid", "caravan", "supply_drop", "power_outage", "water_outage", "storm",
		"infection_outbreak", "refugee_arrival", "helicopter_flyover" }
	for _, id in ipairs(required) do
		local e = EV[id]
		T.truthy(e, "event " .. id)
		T.truthy(e.weight > 0 and e.min_day >= 1 and e.cooldown_days > 0, id .. " weight/min_day/cooldown")
		T.truthy(e.cat == "threat" or e.cat == "hazard" or e.cat == "boon", id .. " category")
		if e.cat == "threat" and not e.fixed_cost then T.truthy(e.min_cost and e.max_cost >= e.min_cost, id .. " cost range") end
	end
	T.eq(#EV.order, 10)
	for _, p in ipairs({ "calm", "escalating", "chaos" }) do
		local prof = director.profile(p)
		for _, id in ipairs(EV.order) do T.truthy(prof.weights[id] and prof.weights[id] > 0, p .. " weight for " .. id) end
	end
	T.throws(function() director.profile("nightmare") end)
	T.throws(function() World.new({ profile = "nightmare" }) end)
end)

T.test("threat points grow with colonists, wealth and days; profiles scale them", function()
	local w = H.world()
	w.s.t = clock.at(5, 12, 0)
	local base = director.points_per_day(w)
	H.colonist(w)
	local one = director.points_per_day(w)
	T.gt(one, base, "more colonists -> more threat")
	H.stock(w, { jewelry = 20, radio_set = 4 })
	local rich = director.points_per_day(w)
	T.gt(rich, one, "more wealth -> more threat")
	w.s.t = clock.at(25, 12, 0)
	T.gt(director.points_per_day(w), rich, "later -> more threat")
	-- sub-linear in wealth (square root): 100x the wealth is not 100x the points
	local w2 = H.world()
	w2.s.t = clock.at(5, 12, 0)
	H.colonist(w2)
	local p0 = director.points_per_day(w2)
	H.stock(w2, { jewelry = 40 })
	local p1 = director.points_per_day(w2)
	H.stock(w2, { jewelry = 100 })
	local p2 = director.points_per_day(w2)
	T.lt(p2 - p0, (p1 - p0) * 100 / 40 * 0.9, "diminishing returns on wealth")
	-- profile multipliers at the same state
	local pts = {}
	for _, prof in ipairs(director.PROFILES) do
		local wp = H.world({ profile = prof })
		wp.s.t = clock.at(20, 12, 0)
		H.colonist(wp)
		pts[prof] = director.points_per_day(wp)
	end
	T.gt(pts.chaos, pts.calm)
	T.gt(pts.escalating, pts.calm)
	T.gt(director.mult("escalating", clock.at(30, 0, 0)), director.mult("escalating", clock.at(1, 0, 0)) * 2, "escalating really escalates")
end)

T.test("grace period: nothing happens on the first day", function()
	for _, prof in ipairs(director.PROFILES) do
		local w = H.world({ profile = prof, seed = 4 })
		for i = 1, 4 do H.colonist(w) end
		H.stock(w, { jewelry = 30 })
		local evs = H.run(w, 1440 - 8 * 60 - 1, function() H.keep_fed(w) end)
		T.eq(H.count(evs, "director_log"), 0, prof .. ": no events before day 2")
	end
end)

-- run whole 30-day games and collect every director_log (cached: several tests share the same games)
local cache = {}
local function collect(profile, seed, days, step)
	local key = profile .. "/" .. string.format("%d/%d/%d", seed, days or 30, step or 5)
	if cache[key] then return cache[key].res, cache[key].logs end
	local logs = {}
	local res = runner.run({ seed = seed, profile = profile, days = days or 30, max_dt = step or 5, on_events = function(evs)
		for i = 1, #evs do if evs[i].type == "director_log" then logs[#logs + 1] = evs[i] end end
	end })
	cache[key] = { res = res, logs = logs }
	return res, logs
end

T.test("budget accounting: threat never exceeds budget, costs are within bounds, spend <= accrued, budget never negative", function()
	for _, prof in ipairs(director.PROFILES) do
		for seed = 1, 4 do
			local res, logs = collect(prof, seed, 30, 5)
			local d = res.world.s.director
			T.ge(d.budget, 0, "budget never negative")
			T.le(d.budget + d.spent, d.accrued + 1e-6, "spent + remaining cannot exceed what was earned")
			local cap_ok = true
			for _, e in ipairs(logs) do
				if e.cat ~= "boon" then
					if e.cost > e.budget_before + 1e-9 then cap_ok = false end
					if math.abs(e.budget_before - e.cost - e.budget_after) > 1e-6 then cap_ok = false end
					if e.budget_after < -1e-9 then cap_ok = false end
					local ev = EV[e.event]
					if ev.min_cost then
						if e.cost < ev.min_cost - 1e-9 and e.cost < e.budget_before then cap_ok = false end
						if e.cost > ev.max_cost + 1e-9 then cap_ok = false end
					end
					if ev.fixed_cost and math.abs(e.cost - ev.fixed_cost) > 1e-9 then cap_ok = false end
				else
					if e.cost ~= 0 or e.budget_before ~= e.budget_after then cap_ok = false end
				end
			end
			T.truthy(cap_ok, prof .. " seed " .. seed .. ": every logged event paid within the budget")
		end
	end
end)

T.test("budget cap: accrual stops at budget_cap_days of income", function()
	local w = H.world({ profile = "calm" })
	for i = 1, 4 do H.colonist(w) end
	local d = w.s.director
	d.next_threat_t, d.next_boon_t = 1e9, 1e9 -- no events: pure accrual
	w:tick(1500)
	d.budget = d.rate * 1440 * 40
	w:tick(10)
	T.le(d.budget, d.rate * 1440 * D.budget_cap_days + 1e-6)
	T.gt(d.budget, 0)
end)

T.test("cooldowns and min_day gates are honoured in every game", function()
	for _, prof in ipairs(director.PROFILES) do
		for seed = 1, 4 do
			local res, logs = collect(prof, seed, 30, 5)
			local last = {}
			for _, e in ipairs(logs) do
				local ev = EV[e.event]
				T.truthy(e.day >= ev.min_day, string.format("%s fired on day %d before its min_day %d", e.event, e.day, ev.min_day))
				if last[e.event] then
					T.truthy(e.t - last[e.event] >= ev.cooldown_days * 1440 - 1e-6, string.format("%s %s seed %d fired twice inside its cooldown", prof, e.event, seed))
				end
				last[e.event] = e.t
				T.truthy(e.day >= 2, "no events on day 1")
			end
		end
	end
end)

-- The director in isolation: a colony that cannot die (threats are cleared and everyone healed every step), so the
-- profile statistics measure the storyteller, not the colony's survival.
local function isolated(profile, seed, days)
	local w = H.world({ profile = profile, seed = seed, max_dt = 30 })
	for i = 1, 5 do H.colonist(w) end
	H.stock(w, { canned_beans = 20, jewelry = 10, scrap_wood = 20 })
	local logs = {}
	local end_t = clock.at(days + 1, 0, 0)
	while w.s.t < end_t do
		local evs = w:tick(30)
		for i = 1, #evs do if evs[i].type == "director_log" then logs[#logs + 1] = evs[i] end end
		w.s.hordes, w.s.raids, w.s.caravans = {}, {}, {}
		for _, c in ipairs(w.s.colonists) do c.hp, c.hunger, c.thirst, c.fatigue, c.inf = c.hp_max, 5, 5, 5, { stage = "none", t = 0, part = "", speed = 1 } end
		while #w.s.colonists < 5 do H.colonist(w) end
	end
	return w, logs
end

T.test("profiles differ measurably: chaos hits harder and more often, calm leaves more quiet days, escalating ramps up", function()
	local stats = {}
	local n = 30
	for _, prof in ipairs(director.PROFILES) do
		local spent, quiet, threats, early, late, all = 0, 0, 0, 0, 0, 0
		for seed = 1, n do
			local w, logs = isolated(prof, 700 + seed, 30)
			spent = spent + w.s.director.spent
			quiet = quiet + director.stats(w, 30).quiet_days
			for _, e in ipairs(logs) do
				all = all + 1
				if e.cat == "threat" then
					threats = threats + 1
					if e.day <= 15 then early = early + 1 else late = late + 1 end
				end
			end
		end
		stats[prof] = { spent = spent / n, quiet = quiet / n, threats = threats / n, early = early / n, late = late / n, events = all / n }
		T.note("%-10s points spent/run %5.0f  quiet days %4.1f  threat events/run %4.1f (days 1-15: %4.1f, 16-30: %4.1f)  all events/day %.2f", prof,
			stats[prof].spent, stats[prof].quiet, stats[prof].threats, stats[prof].early, stats[prof].late, stats[prof].events / 30)
	end
	T.gt(stats.calm.quiet, stats.chaos.quiet + 4, "calm gives clearly more quiet days than chaos")
	T.gt(stats.calm.quiet, stats.escalating.quiet)
	T.gt(stats.chaos.threats, stats.calm.threats * 1.8, "chaos fires far more threats")
	T.gt(stats.chaos.spent, stats.calm.spent * 2, "and spends far more threat budget")
	T.gt(stats.escalating.late, stats.escalating.early * 1.5, "escalating gets worse over time")
	T.gt(stats.escalating.late, stats.calm.late, "late escalating is harsher than calm")
	T.lt(stats.escalating.early, stats.chaos.early, "early escalating is gentler than chaos")
	T.gt(stats.calm.events / 30, 0.2, "calm is quiet, not dead: boons still arrive")
end)

T.test("deterministic: same seed and profile give the same event log; different seeds differ", function()
	local _, a = collect("escalating", 21, 20, 5)
	local _, b = collect("escalating", 21, 20, 5)
	local _, c = collect("escalating", 22, 20, 5)
	local function sig(l) local t = {} for i = 1, #l do t[i] = l[i].event .. "@" .. string.format("%d", l[i].t) end return table.concat(t, ",") end
	T.eq(sig(a), sig(b))
	T.ne(sig(a), sig(c))
	T.gt(#a, 3)
end)

T.test("log ring stays bounded", function()
	local res = collect("chaos", 3, 30, 5)
	T.le(#res.world.s.director.log, D.log_cap)
	local keys = U.count(res.world.s.director.by_day)
	T.le(keys, D.by_day_keep)
end)

-- individual events through director.force ---------------------------------------------------
local function forced_world(seed)
	local w = H.world({ seed = seed or 2, profile = "chaos" })
	w.s.t = clock.at(6, 12, 0)
	w.s.director.budget = 500
	return w
end

T.test("force: unknown events and over-budget events are refused and change nothing", function()
	local w = forced_world()
	T.eq(select(2, director.force(w, "meteor")), "unknown_event")
	w.s.director.budget = 3
	local b = w.s.director.budget
	T.eq(select(2, director.force(w, "horde_wave", 50)), "over_budget")
	T.eq(w.s.director.budget, b)
	T.eq(#w.s.director.log, 0)
end)

T.test("horde wave: spawns a horde sized by the points it paid", function()
	local w = forced_world()
	local n0 = #w.s.hordes
	local detail = director.force(w, "horde_wave", 60)
	T.truthy(detail and detail:find("horde"))
	T.eq(#w.s.hordes, n0 + 1)
	local h = w.s.hordes[#w.s.hordes]
	T.eq(h.src, "wave")
	T.near(require("sim.combat_abstract").mix_power(h.mix), 60, 10)
	T.near(w.s.director.budget, 440, 1e-9)
	local e = H.find(w:flush_events(), "director_log")
	T.eq(e.event, "horde_wave")
	T.eq(e.cost, 60)
	T.near(e.budget_before - e.budget_after, 60, 1e-9)
end)

T.test("gang raid: plans a raid from a hostile faction", function()
	local w = forced_world()
	T.truthy(director.force(w, "gang_raid", 40))
	T.eq(#w.s.raids, 1)
	T.truthy(factions.get(w, w.s.raids[1].faction))
	T.ne(w.s.raids[1].faction, "lantern")
end)

T.test("infection outbreak: infects colonists silently (incubating), up to three", function()
	local w = forced_world()
	for i = 1, 5 do H.colonist(w) end
	T.truthy(director.force(w, "infection_outbreak", 90))
	local n = 0
	for i = 1, #w.s.colonists do
		if w.s.colonists[i].inf.stage == "incubating" then n = n + 1 end
	end
	T.truthy(n >= 1 and n <= 3, "between one and three victims")
	local w1 = forced_world()
	H.colonist(w1)
	T.eq(select(2, director.force(w1, "infection_outbreak", 10)), "not_possible", "needs at least two colonists")
	T.eq(w1.s.colonists[1].inf.stage, "none")
end)

T.test("helicopter: loud noise at the base draws nearby hordes and lifts spirits", function()
	local w = forced_world()
	local h = horde.spawn(w, { x = 400, y = 0, mix = { walker = 12 } })
	local c = H.colonist(w)
	T.truthy(director.force(w, "helicopter_flyover"))
	T.eq(h.state, "seek")
	local evs = w:flush_events()
	T.truthy(H.find(evs, "play_alert", function(e) return e.kind == "helicopter" end))
	T.truthy(require("sim.mood").has(c, "helicopter_hope", w.s.t))
end)

T.test("power / water outages and storms change the networks and weather", function()
	local w = forced_world()
	H.force_build(w, "workbench", { x = 40, y = 0, z = 0 })
	T.truthy(director.force(w, "power_outage"))
	T.gt(w.s.grid.power.outage_until, w.s.t)
	T.falsy(grid.mains_power_on(w))
	T.truthy(director.force(w, "water_outage"))
	T.falsy(grid.mains_water_on(w))
	H.force_build(w, "wall", { x = 0, y = 40, z = 0 })
	T.truthy(director.force(w, "storm"))
	T.eq(grid.weather(w), "storm")
	local damaged = 0
	for i = 1, #w.s.buildings do if w.s.buildings[i].hp < w.s.buildings[i].hp_max then damaged = damaged + 1 end end
	T.gt(damaged, 0, "storms damage structures")
	T.eq(w.s.stats.attacks_repelled, nil)
end)

T.test("caravan, supply drop and refugee are boons: free, and they create what they promise", function()
	local w = forced_world()
	local b = w.s.director.budget
	T.truthy(director.force(w, "caravan"))
	T.eq(#w.s.caravans, 1)
	T.truthy(director.force(w, "supply_drop"))
	T.eq(#w.s.piles, 1)
	T.gt(items.total_count(w.s.piles[1].items), 0)
	T.eq(w.s.ledger.reasons["+supply_drop"], items.total_count(w.s.piles[1].items))
	local n = #w.s.colonists
	T.truthy(director.force(w, "refugee_arrival"))
	T.eq(#w.s.colonists, n + 1)
	T.eq(w.s.director.budget, b, "boons cost nothing")
	local evs = w:flush_events()
	T.truthy(H.find(evs, "colonist_joined"))
	T.truthy(H.find(evs, "loot_spawn", function(e) return e.source == "supply_drop" end))
	T.truthy(H.find(evs, "play_alert", function(e) return e.kind == "supply_drop" end))
	H.audit_ok(T, w, "after boons")
	-- the colony size limit stops refugees
	local full = forced_world()
	for i = 1, TUNING.colonist.max_count do H.colonist(full) end
	T.eq(select(2, director.force(full, "refugee_arrival")), "not_possible")
end)

T.test("refugees: new colonists arrive with items; some arrive silently infected", function()
	local infected = 0
	for seed = 1, 120 do
		local w = H.world({ seed = seed })
		local c, inf = w:add_refugee()
		T.truthy(c.inv.w > 0)
		T.eq(c.state, "idle")
		if inf then infected = infected + 1; T.eq(c.inf.stage, "incubating") end
	end
	T.near(infected / 120, D.refugee_infected_chance, 0.09)
end)
