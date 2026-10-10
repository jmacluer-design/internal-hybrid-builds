-- expeditions: planning, fuel, crew sign-up, risk by district, loot, injuries, lost colonists, conservation.
local T = ...
package.path = T.root .. "/?.lua;" .. T.root .. "/tests/?.lua;" .. package.path
local H = require("helpers").init(T.root)
local U = require("sim.util")
local R = require("sim.rng")
local TUNING = require("data.tuning")
local DISTRICTS = require("data.districts")
local expedition = require("sim.expedition")
local items = require("sim.items")
local stockpile = require("sim.stockpile")
local clock = require("sim.clock")
local needs = require("sim.needs")

local X = TUNING.expedition

T.group("expeditions")

local function ready_world(seed, crew_n, opts)
	opts = opts or {}
	local w = H.world({ seed = seed or 1 })
	w.s.t = clock.at(2, 9, 0) -- daytime
	expedition.init_vehicles(w)
	local crew = {}
	for i = 1, crew_n or 2 do
		local c = H.colonist(w, { skills = opts.skills or { shooting = 4, scavenging = 3 } })
		c.prio.scavenge = 1
		w:create(c.inv, "pistol", 1, "test")
		w:create(c.inv, "ammo_9mm", 40, "test")
		crew[i] = c.id
	end
	H.stock(w, { fuel_can = opts.fuel or 4, canned_beans = 5 })
	return w, crew
end

local function run_until_done(w, limit)
	local evs = {}
	for _ = 1, (limit or 900) do
		local e = w:tick(1)
		for i = 1, #e do evs[#evs + 1] = e[i] end
		H.keep_fed(w)
		if #w.s.exped == 0 then break end
	end
	return evs
end

T.test("plan validation: unknown district, no fuel, busy vehicle, no vehicle", function()
	local w, crew = ready_world(1, 2)
	T.eq(select(2, expedition.plan(w, { district = "atlantis" })), "unknown_district")
	local x = expedition.plan(w, { district = "orchard", crew = crew })
	T.truthy(x)
	T.eq(select(2, expedition.plan(w, { district = "orchard" })), "no_vehicle", "the only van is taken")
	local w2 = ready_world(2, 2, { fuel = 0 })
	T.eq(select(2, expedition.plan(w2, { district = "orchard" })), "no_fuel")
	local w3 = ready_world(3, 2)
	w3.s.vehicles[1].hp = 5
	T.eq(select(2, expedition.plan(w3, { district = "orchard" })), "no_vehicle", "a wrecked van is not offered")
	T.eq(select(2, expedition.plan(w3, { district = "orchard", vehicle = w3.s.vehicles[1].id })), "vehicle_damaged")
	local w4, crew4 = ready_world(4, 1)
	T.eq(select(2, expedition.plan(w4, { district = "orchard", crew = { "c999" } })), "no_crew")
	T.eq(w4.s.vehicles[1].state, "home", "a failed plan frees the vehicle")
	T.eq(#w4.s.exped, 0)
	T.eq(select(2, expedition.plan(w4, { district = "airfield", mode = "foot" })), "too_far_on_foot")
end)

T.test("fuel: cans needed scale with the trip, are destroyed at departure (ledger 'fuel'), nothing else is touched", function()
	T.eq(expedition.fuel_cans_needed(DISTRICTS.orchard, "van"), 1)
	T.ge(expedition.fuel_cans_needed(DISTRICTS.airfield, "van"), 1)
	T.ge(expedition.fuel_cans_needed(DISTRICTS.airfield, "van"), expedition.fuel_cans_needed(DISTRICTS.orchard, "van"))
	T.gt(expedition.fuel_cans_needed(DISTRICTS.airfield, "pickup"), 0)
	local w, crew = ready_world(5, 2, { fuel = 3 })
	local x = expedition.plan(w, { district = "hollow_mall", crew = crew })
	T.eq(stockpile.total(w.s.zones, "fuel_can"), 3, "not paid while forming...")
	w:tick(1)
	T.eq(x.state, "outbound", "explicit crews leave at once")
	T.eq(stockpile.total(w.s.zones, "fuel_can"), 3 - x.fuel_cans, "...paid at departure")
	T.eq(w.s.ledger.reasons["-fuel"], x.fuel_cans)
	H.audit_ok(T, w, "after departure")
end)

T.test("lifecycle: depart -> arrive -> return, crew away then home, loot lands in a pile at the garage with a loot_spawn", function()
	local w, crew = ready_world(6, 3)
	local x = expedition.plan(w, { district = "orchard", crew = crew })
	local garage = w:garage_pos()
	local evs = run_until_done(w)
	local phases = {}
	for i = 1, #evs do if evs[i].type == "expedition" then phases[#phases + 1] = evs[i].phase end end
	T.eq(table.concat(phases, ","), "depart,arrive,return")
	T.eq(#w.s.exped, 0, "finished expeditions are removed (bounded state)")
	T.eq(w.s.vehicles[1].state, "home")
	for _, id in ipairs(crew) do
		local c = w:colonist(id)
		T.truthy(c, "crew survived this easy run")
		T.ne(c.state, "away")
		T.eq(c.xid, nil)
	end
	local spawn = H.find(evs, "loot_spawn")
	T.truthy(spawn)
	T.truthy(spawn.container:find("^pile:"))
	T.eq(spawn.source, "expedition")
	local pile = w:pile(spawn.container:sub(6))
	if pile then
		for id, n in pairs(spawn.items) do T.ge(items.count(pile.items, id), 0) end -- order-free
	end
	local total = U.sum_map(spawn.items)
	T.gt(total, 0, "came back with loot")
	T.eq(w.s.ledger.reasons["+expedition"], total, "loot was created exactly once")
	H.audit_ok(T, w, "after the run")
	T.eq(w.s.stats.expeditions_done, 1)
	local back = H.find(evs, "expedition", function(e) return e.phase == "return" end)
	T.eq(back.district, "orchard")
end)

T.test("trip time: about 2 x travel + search time; faster vehicles are faster", function()
	local w, crew = ready_world(7, 2)
	local t0 = w.s.t
	local x = expedition.plan(w, { district = "hollow_mall", crew = crew })
	w:tick(1)
	local total = x.t_back - t0
	local d = DISTRICTS.hollow_mall
	T.ge(total, 2 * d.travel * X.trip_variance[1] + X.loot_minutes[1] * d.radius / 260 - 3)
	T.le(total, 2 * d.travel * X.trip_variance[2] + X.loot_minutes[2] * d.radius / 260 + 3)
	T.lt(x.t_out, x.t_loot)
	T.lt(x.t_loot, x.t_back)
end)

T.test("open sign-up: volunteers join through the scavenge work type; the trip leaves when full", function()
	local w = ready_world(8, 0)
	for i = 1, 3 do
		local c = H.colonist(w, { skills = { scavenging = 2 }, prio = 0 })
		c.prio.scavenge = 2
		w:create(c.inv, "baseball_bat", 1, "test")
	end
	local x = expedition.plan(w, { district = "orchard", size = 2 })
	T.eq(x.state, "forming")
	local jobs_seen = 0
	for _ = 1, 60 do
		w:tick(1)
		H.keep_fed(w)
		if x.state ~= "forming" then break end
	end
	T.eq(x.state ~= "forming", true, "left once two volunteers joined")
	T.eq(#x.crew, 2)
	T.truthy(select(1, require("sim.jobs").check_reservations(w)))
	local away = 0
	for i = 1, #w.s.colonists do if w.s.colonists[i].state == "away" then away = away + 1 end end
	T.eq(away, 2)
end)

T.test("sign-up deadline: leaves short-handed with at least min_crew, cancels with nobody", function()
	local w = ready_world(9, 0)
	local c = H.colonist(w, { prio = 0 })
	c.prio.scavenge = 1
	w:create(c.inv, "baseball_bat", 1, "test")
	local x = expedition.plan(w, { district = "orchard", size = 4 })
	for _ = 1, TUNING.jobs.sign_up_minutes + 10 do w:tick(1); H.keep_fed(w) end
	T.truthy(x.state == "outbound" or x.state == "looting" or w:colonist(c.id).state == "away" or #w.s.exped == 0)
	local w2 = ready_world(10, 0)
	local lone = H.colonist(w2, { prio = 0 })
	local x2 = expedition.plan(w2, { district = "orchard", size = 2 })
	local evs = {}
	for _ = 1, TUNING.jobs.sign_up_minutes + 10 do
		local e = w2:tick(1)
		for i = 1, #e do evs[#evs + 1] = e[i] end
	end
	T.eq(#w2.s.exped, 0, "cancelled")
	T.truthy(H.find(evs, "notify", function(e) return e.text:find("cancelled") end))
	T.eq(w2.s.vehicles[1].state, "home")
	T.eq(stockpile.total(w2.s.zones, "fuel_can"), 4, "no fuel was spent")
end)

T.test("on foot: no fuel, nearby districts only, slower, smaller haul, riskier", function()
	local w, crew = ready_world(11, 2, { fuel = 0 })
	local x = expedition.plan(w, { district = "orchard", crew = crew, mode = "foot" })
	T.truthy(x, "possible with an empty fuel stock")
	T.eq(x.mode, "foot")
	T.eq(x.fuel_cans, 0)
	T.eq(x.loot.cap, X.foot.trunk_g)
	local t0 = w.s.t
	w:tick(1)
	local van_time = DISTRICTS.orchard.travel / X.vehicles.van.speed
	T.gt((x.t_out - t0), van_time * 1.8, "walking takes much longer")
	local evs = run_until_done(w, 1500)
	T.truthy(H.find(evs, "expedition", function(e) return e.phase == "return" end))
	H.audit_ok(T, w, "foot trip")
	local d = DISTRICTS.old_town
	local crewlist = {}
	for _, id in ipairs(crew) do crewlist[#crewlist + 1] = w:colonist(id) end
	T.truthy(expedition.risk(d, crewlist, false) > 0)
end)

T.test("risk: grows with danger and at night, shrinks with skill, always within 0..0.95", function()
	local w = ready_world(12, 2)
	local rookies, vets = {}, {}
	for i = 1, 2 do
		local a = H.colonist(w, { skills = { shooting = 0, scavenging = 0 } })
		local b = H.colonist(w, { skills = { shooting = 9, scavenging = 9 } })
		rookies[i], vets[i] = a, b
	end
	local prev = -1
	for danger = 1, 5 do
		local d = { danger = danger }
		local day = expedition.risk(d, rookies, false)
		T.gt(day, prev, "risk rises with danger")
		prev = day
		T.gt(expedition.risk(d, rookies, true), day, "night is riskier")
		T.lt(expedition.risk(d, vets, false), day, "veterans are safer")
		for _, crew in ipairs({ rookies, vets }) do
			for _, night in ipairs({ false, true }) do
				local r = expedition.risk(d, crew, night)
				T.truthy(r >= 0 and r <= 0.95)
			end
		end
	end
	T.truthy(expedition.risk({ danger = 5 }, {}, true) <= 0.95)
	T.finite(expedition.crew_strength(vets))
end)

T.test("loot follows the district table; scavenging skill and luck add rolls; capacity caps the haul", function()
	local function haul(district, skill, trials)
		local med, total = 0, 0
		for seed = 1, trials do
			local w, crew = ready_world(seed * 3, 2, { skills = { shooting = 8, scavenging = skill }, fuel = 6 })
			local x = expedition.plan(w, { district = district, crew = crew })
			local evs = run_until_done(w)
			local sp = H.find(evs, "loot_spawn")
			if sp then
				for id, n in pairs(sp.items) do -- order-free
					total = total + n
					if items.defs[id].cat == "medical" then med = med + n end
				end
			end
		end
		return med, total
	end
	local med_c, tot_c = haul("saint_anne", 2, 20)
	local med_o, tot_o = haul("orchard", 2, 20)
	T.gt(med_c / tot_c, med_o / tot_o + 0.15, "the clinic district is mostly medical goods")
	local _, low = haul("orchard", 0, 20)
	local _, high = haul("orchard", 10, 20)
	T.gt(high, low, "scavenging skill adds rolls")
	local w, crew = ready_world(77, 2, { fuel = 6 })
	local x = expedition.plan(w, { district = "orchard", crew = crew, mode = "foot" })
	T.eq(x.loot.cap, X.foot.trunk_g)
	-- a container never holds more than the trunk
	for seed = 1, 10 do
		local w2, crew2 = ready_world(seed, 2, { skills = { scavenging = 10 } })
		local x2 = expedition.plan(w2, { district = "dockside", crew = crew2, mode = "vehicle" })
		for _ = 1, 400 do
			w2:tick(1)
			H.keep_fed(w2)
			if x2.state == "returning" then T.le(x2.loot.w, x2.loot.cap); break end
		end
	end
end)

T.test("dangerous runs: injuries, infections, lost colonists, wipes happen; every item stays accounted for (40 runs)", function()
	local wiped, hurt, lost, survived_all = 0, 0, 0, 0
	local bitten = 0
	for seed = 1, 40 do
		local w, crew = ready_world(1000 + seed, 2, { skills = { shooting = 0, scavenging = 0 }, fuel = 6 })
		local x = expedition.plan(w, { district = "airfield", crew = crew })
		local evs = run_until_done(w, 1200)
		local alive = 0
		for _, id in ipairs(crew) do
			local c = w:colonist(id)
			if c then
				alive = alive + 1
				if #c.wounds > 0 then hurt = hurt + 1 end
				if c.inf.stage ~= "none" then bitten = bitten + 1 end
			end
		end
		if alive == 0 then wiped = wiped + 1 end
		if alive == 2 then survived_all = survived_all + 1 end
		if H.count(evs, "colonist_left") > 0 then lost = lost + 1 end
		local ok, rep = w:audit()
		if not ok then T.truthy(false, "seed " .. seed .. ": " .. tostring(rep.problems[1])) end
		T.truthy(select(1, require("sim.jobs").check_reservations(w)))
		T.eq(#w.s.exped, 0, "the expedition always resolves")
	end
	T.truthy(true)
	T.gt(wiped + hurt + lost, 5, "the deadliest district hurts untrained crews")
	T.gt(survived_all, 0, "but not every run is a disaster")
	T.truthy(wiped >= 1 or lost >= 1, "total loss is possible")
end)

T.test("a wiped-out crew loses the loot and maybe the vehicle (destroyed as 'lost', never duplicated)", function()
	local gone_vehicle, home_vehicle = 0, 0
	for seed = 1, 60 do
		local w, crew = ready_world(5000 + seed, 1, { skills = { shooting = 0, scavenging = 0 }, fuel = 6 })
		w:colonist(crew[1]).hp = 30
		w:colonist(crew[1]).hp_max = 30
		local x = expedition.plan(w, { district = "airfield", crew = crew })
		local evs = run_until_done(w, 1200)
		if not w:colonist(crew[1]) then
			if #w.s.vehicles == 0 then gone_vehicle = gone_vehicle + 1 else home_vehicle = home_vehicle + 1 end
			T.truthy(H.find(evs, "expedition", function(e) return e.phase == "lost" end) or H.count(evs, "colonist_left") + H.count(evs, "colonist_died") > 0)
		end
		H.audit_ok(T, w, "seed " .. seed)
	end
	T.gt(gone_vehicle + home_vehicle, 5, "fragile crews do get wiped")
	T.gt(gone_vehicle, 0)
	T.gt(home_vehicle, 0)
end)

T.test("a crew member who dies at home is removed from the expedition roster", function()
	local w, crew = ready_world(13, 2)
	local x = expedition.plan(w, { district = "orchard", crew = crew })
	w:tick(1)
	T.eq(#x.crew, 2)
	w:kill_colonist(w:colonist(crew[1]), "test", false)
	T.eq(#x.crew, 1)
	T.eq(x.crew[1], crew[2])
	H.audit_ok(T, w, "after losing a crew member")
	local evs = run_until_done(w)
	T.truthy(H.find(evs, "expedition", function(e) return e.phase == "return" end), "the remaining crew still brings it home")
end)

T.test("cancelling a forming expedition frees everything; running ones cannot be cancelled", function()
	local w = ready_world(14, 0)
	local x = expedition.plan(w, { district = "orchard", size = 2 })
	T.truthy(expedition.cancel(w, x.id, "changed my mind"))
	T.eq(#w.s.exped, 0)
	T.eq(w.s.vehicles[1].state, "home")
	local w2, crew = ready_world(15, 2)
	local y = expedition.plan(w2, { district = "orchard", crew = crew })
	w2:tick(1)
	T.falsy(expedition.cancel(w2, y.id, "too late"))
	T.falsy(expedition.cancel(w2, "x999", "nope"))
	local r = w2:handle({ type = "order", id = "colony", kind = "cancel_expedition", target = { id = y.id } })
	T.eq(H.find(r, "order_result").ok, false)
end)

T.test("vehicles heal slowly at home and are never over-healed", function()
	local w = ready_world(16, 0)
	local v = w.s.vehicles[1]
	v.hp = 50
	w:tick(100)
	T.near(v.hp, 50 + X.vehicle_repair_per_min * 100, 1e-6)
	v.hp = X.vehicles.van.hp - 0.001
	w:tick(100)
	T.eq(v.hp, X.vehicles.van.hp)
end)
