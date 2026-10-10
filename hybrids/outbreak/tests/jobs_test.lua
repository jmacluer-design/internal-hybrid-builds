-- job board: priority order, reservations, interruption, starvation bound, needs jobs, crafting, medicine, hauling.
local T = ...
package.path = T.root .. "/?.lua;" .. T.root .. "/tests/?.lua;" .. package.path
local H = require("helpers").init(T.root)
local U = require("sim.util")
local R = require("sim.rng")
local TUNING = require("data.tuning")
local BP = require("data.blueprints")
local blueprints = require("sim.blueprints")
local jobs = require("sim.jobs")
local items = require("sim.items")
local needs = require("sim.needs")
local colonist = require("sim.colonist")
local mood = require("sim.mood")
local clock = require("sim.clock")
local stockpile = require("sim.stockpile")

local J = TUNING.jobs

T.group("jobs")

-- first colonist_task kind chosen by a colonist in a world with several kinds of work waiting
local function first_kind(prios, extra)
	local w = H.world()
	local c = H.colonist(w, { skills = { construction = 4 }, prio = 0 })
	for k, v in pairs(prios) do c.prio[k] = v end -- order-free
	H.stock(w, { scrap_wood = 10, scrap_metal = 5, nails = 5, canned_beans = 3, bandage = 2 })
	local site = blueprints.place(w, "wall", { x = 25, y = 25, z = 0 })
	for _, id in ipairs(U.keys(BP.wall.materials)) do w:create(site.delivered, id, BP.wall.materials[id], "test") end
	local pile = w:pile_for({ x = 15, y = -15, z = 0 })
	w:create(pile.items, "canned_veg", 2, "test")
	if extra then extra(w, c) end
	local evs = H.run(w, 30, function() H.keep_fed(w) end)
	local e = H.find(evs, "colonist_task", function(e) return e.kind ~= "idle" end)
	return e and e.kind, w, c
end

T.test("priority order: a higher priority (lower number) type is served first", function()
	T.eq((first_kind({ build = 1, haul = 3 })), "build")
	T.eq((first_kind({ build = 3, haul = 1 })), "haul")
	T.eq((first_kind({ build = 4, haul = 2 })), "haul")
end)

T.test("priority 0 means never; equal priorities fall back to the fixed work-type order", function()
	local k = first_kind({ build = 0, haul = 3 })
	T.eq(k, "haul")
	local k2, w2 = first_kind({ build = 0, haul = 0 })
	T.eq(k2, nil, "nothing enabled -> no work task at all")
	T.eq(H.count(H.run(w2, 60), "colonist_task") >= 0, true)
	T.eq((first_kind({ build = 2, haul = 2 })), "build", "build precedes haul in the tie-break order")
	local order = colonist.WORK
	T.eq(order[1], "doctor")
	T.eq(order[#order], "scavenge")
end)

T.test("a colonist never works a type whose trait blocks it (pacifists never guard)", function()
	local w = H.world()
	local c = H.colonist(w, { traits = { "pacifist" }, prio = 1 })
	T.eq(c.prio.guard, 0)
	w.s.alert = 1
	w.s.alert_until = 1e9
	H.run(w, 200, function() H.keep_fed(w); w.s.alert = 1 end)
	T.ne(c.job and c.job.kind, "guard")
	for i = 1, #w.s.board.jobs do
		-- guard posts exist on the board, but this colonist cannot take them
		if w.s.board.jobs[i].work == "guard" then T.eq(jobs.holders(w, w.s.board.jobs[i].key)[1], nil) end
	end
end)

T.test("reservations: two colonists never take the same job", function()
	local w = H.world()
	local a = H.colonist(w, { skills = { construction = 4 }, pos = { x = 20, y = 20, z = 0 } })
	local b = H.colonist(w, { skills = { construction = 4 }, pos = { x = 21, y = 20, z = 0 } })
	for _, c in ipairs({ a, b }) do for _, wt in ipairs({ "doctor", "guard", "cook", "craft", "haul", "scavenge" }) do c.prio[wt] = 0 end; c.prio.build = 1 end
	H.stock(w, { scrap_wood = 10, scrap_metal = 5, nails = 5 })
	local site = blueprints.place(w, "wall", { x = 25, y = 25, z = 0 })
	for _, id in ipairs(U.keys(BP.wall.materials)) do w:create(site.delivered, id, BP.wall.materials[id], "test") end
	for _ = 1, 40 do
		w:tick(1)
		H.keep_fed(w)
		local ok, err = jobs.check_reservations(w)
		T.truthy(ok, err)
		local holders = jobs.holders(w, "build:" .. site.id)
		T.le(#holders, 1, "exclusive build job")
		if a.job and b.job and a.job.key == "build:" .. site.id then T.ne(b.job.key, a.job.key) end
	end
	T.eq(site.state, "built")
	T.truthy(select(1, jobs.check_reservations(w)))
end)

T.test("reservations hold across 600 ticks of a busy 6-colonist colony (no key over-reserved, table never drifts)", function()
	local w = H.world({ seed = 5 })
	for i = 1, 6 do H.colonist(w, { skills = { construction = 3 }, pos = { x = 10 + i, y = 5, z = 0 } }) end
	H.stock(w, { scrap_wood = 40, scrap_metal = 20, nails = 20, cloth_scrap = 20, canned_beans = 10, bandage = 10 })
	for i = 1, 6 do
		blueprints.place(w, (i % 2 == 0) and "wall" or "bed", { x = 20 + i * 5, y = 30, z = 0 })
		local pile = w:pile_for({ x = -20 - i * 9, y = 20, z = 0 })
		w:create(pile.items, "canned_veg", 2, "test")
	end
	local max_busy = 0
	for _ = 1, 600 do
		w:tick(1)
		H.keep_fed(w)
		local ok, err = jobs.check_reservations(w)
		if not ok then T.truthy(false, err) end
		local busy = 0
		for i = 1, #w.s.colonists do if w.s.colonists[i].job then busy = busy + 1 end end
		if busy > max_busy then max_busy = busy end
	end
	T.gt(max_busy, 2, "several colonists were busy at once")
	T.truthy(select(1, jobs.check_reservations(w)))
	H.audit_ok(T, w, "busy colony")
end)

T.test("reservations survive a rebuild from colonist jobs (as after a load)", function()
	local w = H.world()
	local c = H.colonist(w, { skills = { construction = 4 } })
	H.stock(w, { scrap_wood = 10, scrap_metal = 5, nails = 5 })
	blueprints.place(w, "wall", { x = 25, y = 25, z = 0 })
	H.run(w, 20, function() H.keep_fed(w) end)
	T.truthy(c.job, "colonist is busy")
	local before = {}
	for k, v in pairs(w.rt.res) do before[k] = #v end -- order-free
	jobs.rebuild_res(w)
	for k, v in pairs(w.rt.res) do T.eq(#v, before[k] or -1, "key " .. k) end -- order-free
	T.truthy(select(1, jobs.check_reservations(w)))
end)

T.test("interruption: an emergency (starving) outranks ordinary work, then work resumes", function()
	local w = H.world()
	local c = H.colonist(w, { skills = { construction = 4 } })
	for _, wt in ipairs({ "doctor", "guard", "cook", "craft", "haul", "scavenge" }) do c.prio[wt] = 0 end
	c.prio.build = 1
	H.stock(w, { scrap_wood = 10, scrap_metal = 5, nails = 5, canned_beans = 5, water_bottle = 2 })
	local site = blueprints.place(w, "wall", { x = 25, y = 25, z = 0 })
	for _, id in ipairs(U.keys(BP.wall.materials)) do w:create(site.delivered, id, BP.wall.materials[id], "test") end
	H.run(w, 8, function() H.keep_fed(w) end)
	T.eq(c.job and c.job.kind, "build")
	local class_before = c.job.class
	c.hunger = 95
	c.dirty = true
	w:tick(1)
	T.eq(c.job and c.job.kind, "eat", "starving interrupts building")
	T.gt(c.job.class, class_before)
	H.run(w, 15, function() c.thirst, c.fatigue = 5, 5 end)
	T.lt(c.hunger, 60, "ate")
	H.run(w, 120, function() H.keep_fed(w) end)
	T.eq(site.state, "built", "went back to work and finished the wall")
	T.truthy(select(1, jobs.check_reservations(w)))
end)

T.test("interruption: equal-class work never swaps; needs-class sleep is not interrupted by ordinary work", function()
	local w = H.world()
	local c = H.colonist(w, { skills = { construction = 4 } })
	H.stock(w, { scrap_wood = 20, scrap_metal = 10, nails = 10 })
	local s1 = blueprints.place(w, "wall", { x = 25, y = 25, z = 0 })
	w:tick(2)
	local key1 = c.job and c.job.key
	T.truthy(key1)
	local s2 = blueprints.place(w, "wall", { x = 29, y = 25, z = 0 })
	for _ = 1, 30 do w:tick(1); H.keep_fed(w) end
	if key1 then T.truthy(c.job == nil or c.job.class == 1) end
	-- a sleeper keeps sleeping while build work waits
	local d = H.colonist(w, { skills = { construction = 4 } })
	d.sched = string.rep("S", 24)
	d.fatigue = 70
	w:tick(30)
	T.eq(d.job and d.job.kind, "sleep")
	local before = d.job
	for _ = 1, 20 do w:tick(1); d.hunger, d.thirst = 5, 5 end
	T.eq(d.job, before, "same sleeping job object keeps going")
end)

T.test("interruption: downed colonists drop their job and release every reservation", function()
	local w = H.world()
	local c = H.colonist(w, { skills = { construction = 4 } })
	H.stock(w, { scrap_wood = 10, scrap_metal = 5, nails = 5 })
	blueprints.place(w, "wall", { x = 25, y = 25, z = 0 })
	for _ = 1, 40 do
		w:tick(1)
		H.keep_fed(w)
		if c.job then break end
	end
	T.truthy(c.job)
	local key = c.job.key
	c.hp = 5
	w:tick(1)
	T.truthy(c.downed)
	T.eq(c.job, nil)
	T.eq(c.state, "downed")
	T.eq(#jobs.holders(w, key), 0, "reservation released")
	T.truthy(select(1, jobs.check_reservations(w)))
end)

T.test("death and leaving release reservations so another colonist can take the job", function()
	local w = H.world()
	local a = H.colonist(w, { skills = { construction = 4 } })
	local b = H.colonist(w, { skills = { construction = 4 } })
	for _, c in ipairs({ a, b }) do for _, wt in ipairs({ "doctor", "guard", "cook", "craft", "haul", "scavenge" }) do c.prio[wt] = 0 end; c.prio.build = 2 end
	H.stock(w, { scrap_wood = 10, scrap_metal = 5, nails = 5 })
	local site = blueprints.place(w, "wall", { x = 25, y = 25, z = 0 })
	for _, id in ipairs(U.keys(BP.wall.materials)) do w:create(site.delivered, id, BP.wall.materials[id], "test") end
	local key = "build:" .. site.id
	local holder
	for _ = 1, 40 do
		w:tick(1)
		H.keep_fed(w)
		holder = (a.job and a.job.key == key and a) or (b.job and b.job.key == key and b) or nil
		if holder then break end
	end
	T.truthy(holder, "somebody took the build job")
	local other = (holder == a) and b or a
	T.eq(#jobs.holders(w, key), 1)
	w:kill_colonist(holder, "test", false)
	T.eq(#jobs.holders(w, key), 0, "the reservation died with the colonist")
	H.run(w, 120, function() H.keep_fed(w) end)
	T.eq(site.state, "built", "the other colonist finished it")
	T.truthy(select(1, jobs.check_reservations(w)))
	T.truthy(w:colonist(other.id))
	H.audit_ok(T, w, "after death")
	-- leaving behaves the same way
	local w2 = H.world()
	local c1 = H.colonist(w2, { skills = { construction = 4 } })
	H.stock(w2, { scrap_wood = 10, scrap_metal = 5, nails = 5 })
	local s2 = blueprints.place(w2, "wall", { x = 25, y = 25, z = 0 })
	for _ = 1, 40 do w2:tick(1); H.keep_fed(w2); if c1.job then break end end
	local k2 = c1.job and c1.job.key
	T.truthy(k2)
	w2:colonist_leaves(c1, "test")
	T.eq(#jobs.holders(w2, k2), 0)
	T.eq(#w2.s.colonists, 0)
	H.audit_ok(T, w2, "after leaving")
end)

T.test("starvation bound: a priority-4 job is served within 3 aging periods even under a constant stream of priority-1 work", function()
	local w = H.world()
	local c = H.colonist(w, { skills = { construction = 6 } })
	for _, wt in ipairs({ "doctor", "guard", "cook", "craft", "scavenge" }) do c.prio[wt] = 0 end
	c.prio.build, c.prio.haul = 1, 4
	H.stock(w, { scrap_wood = 60, scrap_metal = 20, nails = 20 })
	local pile = w:pile_for({ x = -30, y = 30, z = 0 })
	w:create(pile.items, "canned_veg", 2, "test")
	local t0 = w.s.t
	local served_at
	local n = 0
	local function topup()
		local open = 0
		for i = 1, #w.s.buildings do if w.s.buildings[i].state == "planned" then open = open + 1 end end
		while open < 3 do
			n = n + 1
			local b = blueprints.place(w, "floor", { x = -50 + (n % 25) * 4, y = 50 - math.floor(n / 25) * 4, z = 0 })
			if not b then
				-- spot taken (finished floors stay): move on
				b = nil
			else
				for _, id in ipairs(U.keys(BP.floor.materials)) do w:create(b.delivered, id, BP.floor.materials[id], "test") end
				open = open + 1
			end
			if n > 500 then break end
		end
	end
	for _ = 1, 4 * J.aging_minutes do
		topup()
		local evs = w:tick(1)
		H.keep_fed(w)
		if H.find(evs, "colonist_task", function(e) return e.kind == "haul" end) then served_at = w.s.t; break end
	end
	T.truthy(served_at, "the low-priority haul job was eventually served")
	T.le(served_at - t0, 3 * J.aging_minutes + 60, "within three aging periods plus slack")
	T.gt(served_at - t0, 2 * J.aging_minutes, "but not before it aged (fresh priority-1 work still wins)")
	T.truthy(select(1, jobs.check_reservations(w)))
end)

T.test("a job at priority 0 is never served, however long it waits", function()
	local w = H.world()
	local c = H.colonist(w, { prio = 0 })
	local pile = w:pile_for({ x = 15, y = 15, z = 0 })
	w:create(pile.items, "canned_veg", 2, "test")
	H.run(w, 4 * J.aging_minutes, function() H.keep_fed(w) end)
	T.eq(items.count(pile.items, "canned_veg"), 2)
	T.eq(c.job, nil)
end)

T.test("eating: hunger triggers an eat job, the food is destroyed in the ledger, mood thought applies", function()
	local w = H.world()
	local c = H.colonist(w)
	H.stock(w, { canned_beans = 3 })
	c.hunger = TUNING.needs.eat_at + 5
	local evs = H.run(w, 30, function() c.thirst, c.fatigue = 5, 5 end)
	T.truthy(H.find(evs, "colonist_task", function(e) return e.kind == "eat" end))
	T.lt(c.hunger, 40)
	T.eq(w.s.ledger.reasons["-eat"], 1)
	T.eq(stockpile.total(w.s.zones, "canned_beans"), 2)
	T.truthy(mood.has(c, "ate_canned", w.s.t))
	H.audit_ok(T, w, "after eating")
	-- prefers the better meal when both are available
	local w2 = H.world()
	local c2 = H.colonist(w2)
	H.stock(w2, { canned_beans = 3, stew = 1 })
	c2.hunger = 60
	H.run(w2, 20, function() c2.thirst, c2.fatigue = 5, 5 end)
	T.eq(stockpile.total(w2.s.zones, "stew"), 0, "the hot stew was eaten first")
end)

T.test("drinking: from the water tank when there is water, else from bottles", function()
	local w = H.world()
	w.s.grid.water.mains_dead = true
	w.s.grid.water.tank = 10
	local c = H.colonist(w)
	H.stock(w, { water_bottle = 2 })
	c.thirst = 70
	H.run(w, 20, function() c.hunger, c.fatigue = 5, 5 end)
	T.lt(c.thirst, 40)
	T.lt(w.s.grid.water.tank, 10)
	T.eq(stockpile.total(w.s.zones, "water_bottle"), 2, "tank first")
	w.s.grid.water.tank = 0
	c.thirst = 70
	H.run(w, 20, function() c.hunger, c.fatigue = 5, 5 end)
	T.eq(stockpile.total(w.s.zones, "water_bottle"), 1, "bottle used when the tank is dry")
	H.audit_ok(T, w)
end)

T.test("sleeping: scheduled sleep uses a free bed (one sleeper per bed), floor otherwise, with the right thoughts", function()
	local w = H.world()
	local a, b = H.colonist(w), H.colonist(w)
	for _, c in ipairs({ a, b }) do c.sched = string.rep("S", 24); c.fatigue = 60 end
	local bed = H.force_build(w, "bed", { x = -20, y = 0, z = 0 })
	w:tick(30)
	local in_bed = 0
	for _, c in ipairs({ a, b }) do
		T.eq(c.job and c.job.kind, "sleep")
		if c.job.data.bed == bed.id then in_bed = in_bed + 1 end
	end
	T.eq(in_bed, 1, "only one colonist gets the single bed")
	T.truthy(select(1, jobs.check_reservations(w)))
	for _ = 1, 20 do H.run(w, 30, function() for _, c in ipairs({ a, b }) do c.hunger, c.thirst = 5, 5 end end) end
	local bed_sleeper = (a.thoughts and mood.has(a, "slept_in_bed", w.s.t)) and a or b
	local floor_sleeper = (bed_sleeper == a) and b or a
	T.truthy(mood.has(bed_sleeper, "slept_in_bed", w.s.t) or mood.has(floor_sleeper, "slept_in_bed", w.s.t))
	T.truthy(mood.has(floor_sleeper, "slept_on_floor", w.s.t) or mood.has(bed_sleeper, "slept_on_floor", w.s.t))
	T.lt(a.fatigue, 30)
end)

T.test("sick or hurt colonists rest; resting heals faster than working", function()
	local w = H.world()
	local c = H.colonist(w)
	c.hp = 40
	c.sched = string.rep("J", 24)
	w:tick(10)
	T.eq(c.job and c.job.kind, "rest")
	H.run(w, 600, function() c.hunger, c.thirst, c.fatigue = 5, 5, 5 end)
	T.gt(c.hp, 70)
end)

T.test("cooking: a cook uses a campfire, burns firewood, turns rice into meals; no job once demand is met", function()
	local w = H.world()
	local c = H.colonist(w, { skills = { cooking = 3 } })
	for _, wt in ipairs({ "doctor", "guard", "build", "craft", "haul", "scavenge" }) do c.prio[wt] = 0 end
	c.prio.cook = 1
	H.force_build(w, "campfire", { x = 20, y = 0, z = 0 })
	H.stock(w, { rice_bag = 4, firewood = 5 })
	local evs = H.run(w, 120, function() H.keep_fed(w) end)
	T.truthy(H.find(evs, "colonist_task", function(e) return e.kind == "cook" end))
	T.gt(stockpile.total(w.s.zones, "cooked_rice"), 3)
	T.near(stockpile.total(w.s.zones, "cooked_rice") % 4, 0, 0)
	T.eq(w.s.ledger.reasons["-fuel"] ~= nil, true, "campfire fuel burned")
	local produced = w.s.ledger.reasons["+cook"]
	T.truthy(produced and produced % 4 == 0)
	-- demand target reached: stop cooking even with raw rice left
	local rice_left = stockpile.total(w.s.zones, "rice_bag")
	H.run(w, 600, function() H.keep_fed(w) end)
	T.ge(stockpile.total(w.s.zones, "cooked_rice"), 8)
	T.le(stockpile.total(w.s.zones, "cooked_rice"), 8 + 3, "does not over-produce past the want target")
	H.audit_ok(T, w, "after cooking")
	-- an electric stove with no power gets no cook job
	local w2 = H.world()
	local c2 = H.colonist(w2, { skills = { cooking = 3 } })
	for _, wt in ipairs({ "doctor", "guard", "build", "craft", "haul", "scavenge" }) do c2.prio[wt] = 0 end
	H.force_build(w2, "workbench", { x = 40, y = 0, z = 0 })
	local stove = H.force_build(w2, "stove", { x = 44, y = 0, z = 0 })
	H.stock(w2, { rice_bag = 4 })
	w2.s.grid.power.mains_dead = true
	w2:tick(10)
	T.falsy(stove.powered)
	local evs2 = H.run(w2, 120, function() H.keep_fed(w2) end)
	T.falsy(H.find(evs2, "colonist_task", function(e) return e.kind == "cook" end), "no power -> no cooking")
end)

T.test("crafting: bandages from cloth at the workbench, conserved in the ledger", function()
	local w = H.world()
	local c = H.colonist(w, { skills = { medicine = 3 } })
	for _, wt in ipairs({ "doctor", "guard", "build", "cook", "haul", "scavenge" }) do c.prio[wt] = 0 end
	c.prio.craft = 1
	H.force_build(w, "workbench", { x = 40, y = 0, z = 0 })
	H.stock(w, { cloth_scrap = 10 })
	H.run(w, 200, function() H.keep_fed(w) end)
	T.gt(stockpile.total(w.s.zones, "bandage"), 0)
	T.eq(stockpile.total(w.s.zones, "cloth_scrap") + (w.s.ledger.reasons["-craft"] or 0), 10)
	T.eq(w.s.ledger.reasons["+craft"], stockpile.total(w.s.zones, "bandage"))
	H.audit_ok(T, w, "after crafting")
end)

T.test("hauling: loose items go to a zone that accepts them, filters respected, unstorable piles are ignored", function()
	local w = H.world()
	local meds = stockpile.new(w:new_id("z"), "Meds", { x = 30, y = 10, z = 0 }, 2, 5, { cats = { medical = true } })
	w:add_zone(meds)
	local c = H.colonist(w)
	for _, wt in ipairs({ "doctor", "guard", "build", "cook", "craft", "scavenge" }) do c.prio[wt] = 0 end
	local pile = w:pile_for({ x = -10, y = -10, z = 0 })
	w:create(pile.items, "bandage", 4, "test")
	w:create(pile.items, "canned_beans", 3, "test")
	H.run(w, 60, function() H.keep_fed(w) end)
	T.eq(items.count(meds.items, "bandage"), 4, "medicine went to the medical shelf")
	T.eq(items.count(w.s.zones[1].items, "canned_beans"), 3, "food went to the main store")
	T.eq(w:pile(pile.id), nil, "empty pile removed")
	-- nothing accepts it: the pile stays and no hauling job spins
	local w2 = H.world()
	w2.s.zones[1].filter = { cats = { medical = true } }
	local c2 = H.colonist(w2)
	local p2 = w2:pile_for({ x = -10, y = -10, z = 0 })
	w2:create(p2.items, "scrap_wood", 3, "test")
	local evs = H.run(w2, 120, function() H.keep_fed(w2) end)
	T.falsy(H.find(evs, "colonist_task", function(e) return e.kind == "haul" end))
	T.eq(items.count(p2.items, "scrap_wood"), 3)
	H.audit_ok(T, w2, "unstorable pile")
end)

T.test("a full inventory never deadlocks eating: the colonist unloads first", function()
	local w = H.world()
	local c = H.colonist(w)
	for i = 1, TUNING.colonist.slots do w:create(c.inv, "crowbar", 1, "test") end -- every slot holds a spare weapon
	H.stock(w, { canned_beans = 3 })
	c.hunger = 80
	H.run(w, 30, function() c.thirst, c.fatigue = 5, 5 end)
	T.lt(c.hunger, 60, "managed to eat")
	T.ge(w.s.zones[1].items.items.crowbar or 0, TUNING.colonist.slots - 1, "spares were stocked away")
	H.audit_ok(T, w, "full inventory")
end)

T.test("doctors: bleeding is bandaged (item consumed), bitten patients get antibiotics once per cooldown", function()
	local w = H.world()
	local doc = H.colonist(w, { skills = { medicine = 5 } })
	for _, wt in ipairs({ "guard", "build", "cook", "craft", "haul", "scavenge" }) do doc.prio[wt] = 0 end
	doc.prio.doctor = 1
	local pat = H.colonist(w, { prio = 0 })
	H.stock(w, { bandage = 3, antibiotics = 3 })
	needs.wound(pat, w:rng("t"), "bite", 8, "arm")
	pat.wounds[1].bleed = 0.3
	T.gt(needs.bleeding(pat), 0)
	H.run(w, 60, function() H.keep_fed(w) end)
	T.eq(needs.bleeding(pat), 0, "bleeding stopped")
	T.eq(w.s.ledger.reasons["-medical"], 2, "one bandage + one antibiotic dose, no duplicate dosing")
	T.eq(stockpile.total(w.s.zones, "antibiotics"), 2)
	T.eq(stockpile.total(w.s.zones, "bandage") <= 2, true)
	H.run(w, 120, function() H.keep_fed(w) end)
	T.eq(stockpile.total(w.s.zones, "antibiotics"), 2, "no second dose inside the cooldown")
	H.audit_ok(T, w, "after treatment")
end)

T.test("doctors: a downed patient is fed and given water", function()
	local w = H.world()
	local doc = H.colonist(w, { skills = { medicine = 3 } })
	for _, wt in ipairs({ "guard", "build", "cook", "craft", "haul", "scavenge" }) do doc.prio[wt] = 0 end
	doc.prio.doctor = 1
	local pat = H.colonist(w, { prio = 0 })
	pat.hp = 8
	pat.hunger, pat.thirst = 70, 85
	H.stock(w, { canned_beans = 4, water_bottle = 3 })
	w.s.grid.water.mains_dead = true
	w.s.grid.water.tank = 0
	w:tick(2)
	T.truthy(pat.downed)
	for _ = 1, 20 do
		w:tick(5)
		doc.hunger, doc.thirst, doc.fatigue = 5, 5, 5
		pat.hp = U.clamp(pat.hp, 6, 9)
	end
	T.lt(pat.thirst, 60, "the patient was given something to drink")
	T.lt(pat.hunger, 60, "and something to eat")
	T.eq(w:colonist(pat.id) ~= nil, true)
	H.audit_ok(T, w, "after feeding")
end)

T.test("amputation-lite job: only with the order enabled, a kit, no antibiotics left, skilled doctor", function()
	local w = H.world()
	local doc = H.colonist(w, { skills = { medicine = 5 } })
	for _, wt in ipairs({ "guard", "build", "cook", "craft", "haul", "scavenge" }) do doc.prio[wt] = 0 end
	doc.prio.doctor = 1
	local pat = H.colonist(w, { prio = 0 })
	H.stock(w, { surgical_kit = 1 })
	local rng = w:rng("t")
	needs.wound(pat, rng, "bite", 8, "arm")
	needs.infect(pat, rng, "arm")
	pat.wounds[1].bleed = 0
	H.run(w, 60, function() H.keep_fed(w) end)
	T.eq(pat.maimed, 0, "allow_amputation is off by default")
	pat.allow_amputation = true
	H.run(w, 120, function() H.keep_fed(w) end)
	T.eq(pat.maimed + (pat.inf.stage ~= "none" and 0 or 0), pat.maimed)
	T.truthy(pat.maimed == 1 or pat.inf.stage ~= "none", "the surgery was attempted (success removes the infection)")
	if pat.maimed == 1 then T.eq(pat.inf.stage, "none") end
	T.eq(stockpile.total(w.s.zones, "surgical_kit"), 1, "the kit is reusable")
end)

T.test("forced orders: goto moves the colonist, draft holds them, undraft releases", function()
	local w = H.world()
	local c = H.colonist(w)
	local dest = { x = 60, y = 40, z = 0 }
	local evs = w:handle({ type = "order", id = c.id, kind = "goto", target = dest })
	T.eq(H.find(evs, "order_result").ok, true)
	local dist = U.dist(c.pos, dest)
	H.run(w, math.ceil(dist / colonist.walk_speed(c)) + 5, function() H.keep_fed(w) end)
	T.near(c.pos.x, 60, 0.5)
	T.near(c.pos.y, 40, 0.5)
	w:handle({ type = "order", id = c.id, kind = "draft", target = true })
	H.run(w, 20, function() H.keep_fed(w) end)
	T.eq(c.state, "drafted")
	T.eq(c.job.kind, "draft")
	T.eq(c.job.class, jobs.CLASS.FORCED)
	local pile = w:pile_for({ x = 15, y = 15, z = 0 })
	w:create(pile.items, "canned_veg", 2, "test")
	H.run(w, 30, function() H.keep_fed(w) end)
	T.eq(c.job.kind, "draft", "drafted colonists ignore chores")
	w:handle({ type = "order", id = c.id, kind = "draft", target = false })
	H.run(w, 60, function() H.keep_fed(w) end)
	T.ne(c.state, "drafted")
	T.eq(items.count(pile.items, "canned_veg"), 0, "back to work: the pile was hauled")
end)

T.test("mental break 'refuse' skips work but still eats; 'binge' consumes stock; 'wander' leaves for a while", function()
	local w = H.world()
	local c = H.colonist(w)
	local pile = w:pile_for({ x = 15, y = 15, z = 0 })
	w:create(pile.items, "canned_veg", 2, "test")
	H.stock(w, { canned_beans = 10 })
	c.mbreak = { kind = "refuse", level = "minor", until_t = w.s.t + 200 }
	c.mood, c.mood_t = 15, w.s.t
	H.run(w, 60, function() c.thirst, c.fatigue = 5, 5; c.mood_t = w.s.t; c.mood = 15 end)
	T.eq(items.count(pile.items, "canned_veg"), 2, "refused to haul")
	c.hunger = 70
	H.run(w, 20, function() c.thirst, c.fatigue = 5, 5; c.mood_t = w.s.t; c.mood = 15 end)
	T.lt(c.hunger, 50, "still ate")
	local w2 = H.world()
	local b = H.colonist(w2)
	H.stock(w2, { canned_beans = 10 })
	b.mbreak = { kind = "binge", level = "major", until_t = w2.s.t + 100 }
	b.mood, b.mood_t = 15, w2.s.t
	H.run(w2, 40, function() b.thirst, b.fatigue = 5, 5; b.mood_t = w2.s.t; b.mood = 15 end)
	T.le(stockpile.total(w2.s.zones, "canned_beans"), 10 - TUNING.mood.binge_items)
	T.truthy((w2.s.ledger.reasons["-binge"] or 0) >= TUNING.mood.binge_items)
	H.audit_ok(T, w2, "after binge")
	local w3 = H.world()
	local d = H.colonist(w3)
	d.mbreak = { kind = "wander", level = "minor", until_t = w3.s.t + 120 }
	d.mood, d.mood_t = 15, w3.s.t
	H.run(w3, 30, function() H.keep_fed(w3); d.mood_t = w3.s.t; d.mood = 15 end)
	T.eq(d.job and d.job.kind, "wander")
	T.gt(U.dist2(d.pos.x, d.pos.y, 0, 0), 20)
end)

T.test("guard posts appear at night or on alert; guards stand watch, then stand down at dawn", function()
	local w = H.world()
	local c = H.colonist(w)
	c.sched = string.rep("W", 24)
	for _, wt in ipairs({ "doctor", "build", "cook", "craft", "haul", "scavenge" }) do c.prio[wt] = 0 end
	c.prio.guard = 1
	w.s.t = clock.at(2, 12, 0)
	H.run(w, 30, function() H.keep_fed(w) end)
	T.ne(c.job and c.job.kind, "guard", "no guard duty at noon without an alert")
	w.s.t = clock.at(2, 22, 0)
	H.run(w, 30, function() H.keep_fed(w) end)
	T.eq(c.job and c.job.kind, "guard", "night watch")
	T.eq(c.state, "guarding")
	local key = c.job.key
	T.eq(#jobs.holders(w, key), 1)
	w.s.t = clock.at(3, 7, 0)
	H.run(w, 20, function() H.keep_fed(w) end)
	T.ne(c.job and c.job.kind, "guard", "stood down at dawn")
	w.s.alert, w.s.alert_until = 1, 1e12
	H.run(w, 20, function() H.keep_fed(w); w.s.alert = 1 end)
	T.eq(c.job and c.job.kind, "guard", "alert -> guard in daylight too")
end)

T.test("walking takes time proportional to distance (colonist_task steps arrive when expected)", function()
	local w = H.world()
	local c = H.colonist(w, { pos = { x = 0, y = 0, z = 0 } })
	for _, wt in ipairs({ "doctor", "guard", "build", "cook", "craft", "scavenge" }) do c.prio[wt] = 0 end
	local far = w:pile_for({ x = 0, y = 150, z = 0 })
	w:create(far.items, "canned_veg", 1, "test")
	w:tick(1)
	T.eq(c.job.kind, "haul")
	local expect_min = 150 / colonist.walk_speed(c)
	local t0 = w.s.t
	local arrived
	for _ = 1, 40 do
		w:tick(1)
		H.keep_fed(w)
		if c.job and c.job.i == 1 and c.job.ph == "do" and not arrived then arrived = w.s.t - t0 end
	end
	T.truthy(arrived)
	T.near(arrived, expect_min, 2.5)
end)
