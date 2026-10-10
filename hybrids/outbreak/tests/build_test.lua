-- blueprints, prerequisites, construction, defense, power + water networks.
local T = ...
package.path = T.root .. "/?.lua;" .. T.root .. "/tests/?.lua;" .. package.path
local H = require("helpers").init(T.root)
local U = require("sim.util")
local TUNING = require("data.tuning")
local BP = require("data.blueprints")
local blueprints = require("sim.blueprints")
local grid = require("sim.grid")
local items = require("sim.items")
local stockpile = require("sim.stockpile")
local jobs = require("sim.jobs")

T.group("blueprints+grid")

T.test("at least 12 blueprints including the required set, all with sane data", function()
	local need = { "wall", "door", "barricade", "floor", "bed", "stove", "generator", "workbench", "watchtower", "crate", "campfire", "rain_collector" }
	for _, id in ipairs(need) do T.truthy(BP[id], "blueprint " .. id) end
	T.ge(#blueprints.ids(), 12)
	for _, id in ipairs(blueprints.ids()) do
		local d = BP[id]
		T.truthy(d.name and d.cat and d.work > 0 and d.hp > 0 and next(d.materials) ~= nil, id .. " fields")
		T.truthy((d.power_use or 0) >= 0 and (d.power_gen or 0) >= 0, id .. " power")
	end
	T.gt(BP.stove.power_use, 0)
	T.gt(BP.generator.power_gen, 0)
	T.truthy(BP.stove.needs.workbench, "stove has a prerequisite")
	T.truthy(BP.watchtower.needs.wall, "tower needs walls")
end)

T.test("prerequisites are enforced at placement and unlock when the required building is finished", function()
	local w = H.world()
	local pos = { x = 30, y = 30, z = 0 }
	local ok, why = blueprints.can_place(w, "stove", pos)
	T.falsy(ok)
	T.eq(why, "prereq:workbench")
	T.eq(select(2, blueprints.can_place(w, "generator", pos)), "prereq:workbench")
	T.eq(select(2, blueprints.can_place(w, "door", pos)), "prereq:wall")
	T.eq(select(2, blueprints.can_place(w, "radio_mast", pos)), "prereq:generator")
	local wb = H.force_build(w, "workbench", { x = 40, y = 0, z = 0 })
	T.eq(wb.state, "built")
	T.truthy(blueprints.can_place(w, "stove", pos))
	T.truthy(blueprints.can_place(w, "generator", pos))
	-- a planned (unfinished) wall does not satisfy a prerequisite
	local site = blueprints.place(w, "wall", { x = 0, y = 40, z = 0 })
	T.eq(site.state, "planned")
	H.force_build(w, "wall", { x = 3, y = 40, z = 0 })
	T.eq(select(2, blueprints.can_place(w, "watchtower", { x = 50, y = 50, z = 0 })), "prereq:wall", "needs TWO finished walls")
	H.force_build(w, "wall", { x = 6, y = 40, z = 0 })
	T.truthy(blueprints.can_place(w, "watchtower", { x = 50, y = 50, z = 0 }))
	T.eq(select(2, blueprints.can_place(w, "medical_bed", pos)), "prereq:bed")
	H.force_build(w, "bed", { x = -30, y = 0, z = 0 })
	T.truthy(blueprints.can_place(w, "medical_bed", pos))
	T.eq(select(2, blueprints.can_place(w, "nonexistent", pos)), "unknown_blueprint")
end)

T.test("placement limits: max count, spacing, build radius", function()
	local w = H.world()
	H.force_build(w, "workbench", { x = 40, y = 0, z = 0 })
	H.force_build(w, "generator", { x = 60, y = 60, z = 0 })
	H.force_build(w, "radio_mast", { x = 0, y = -60, z = 0 })
	T.eq(select(2, blueprints.can_place(w, "radio_mast", { x = 70, y = 0, z = 0 })), "max_reached")
	T.eq(select(2, blueprints.can_place(w, "wall", { x = 40.5, y = 0.2, z = 0 })), "blocked")
	T.eq(select(2, blueprints.can_place(w, "wall", { x = 5000, y = 0, z = 0 })), "too_far")
	local b, why = blueprints.place(w, "wall", { x = 5000, y = 0, z = 0 })
	T.eq(b, nil)
	T.eq(why, "too_far")
	for i = 1, 8 do H.force_build(w, "crate", { x = -50 + i * 4, y = 80, z = 0 }) end
	T.eq(select(2, blueprints.can_place(w, "crate", { x = 90, y = 90, z = 0 })), "max_reached", "crates are capped at 8")
end)

T.test("a colonist hauls materials, builds, progress events fire at 25% steps, materials are consumed exactly", function()
	local w = H.world()
	local c = H.colonist(w, { skills = { construction = 4 } })
	for _, wt in ipairs({ "doctor", "guard", "cook", "craft", "scavenge" }) do c.prio[wt] = 0 end
	H.stock(w, { scrap_wood = 10, scrap_metal = 5, nails = 5 })
	local b = blueprints.place(w, "wall", { x = 25, y = 25, z = 0 })
	local before = stockpile.totals(w.s.zones)
	local events = H.run(w, 240, function() H.keep_fed(w) end)
	T.eq(b.state, "built", "wall finished")
	T.eq(b.hp, b.hp_max)
	local after = stockpile.totals(w.s.zones)
	for item, n in pairs(BP.wall.materials) do -- order-free
		T.eq(before[item] - after[item], n, "exactly the listed amount of " .. item .. " was consumed")
	end
	T.eq(H.count(events, "place_blueprint"), 1, "the placement event is delivered with the first tick")
	T.eq(H.count(events, "construction_done"), 1)
	local pcts = {}
	for i = 1, #events do if events[i].type == "construction_progress" then pcts[#pcts + 1] = events[i].pct end end
	T.eq(table.concat(pcts, ","), "25,50,75")
	T.eq(w.s.ledger.reasons["-construct"], 5, "destroyed in the ledger as 'construct'")
	H.audit_ok(T, w, "after construction")
end)

T.test("a colonist without the skill does not take a build job that needs it", function()
	local w = H.world()
	local c = H.colonist(w, { skills = { construction = 0 } })
	for _, wt in ipairs({ "doctor", "guard", "cook", "craft", "scavenge", "haul" }) do c.prio[wt] = 0 end
	c.prio.haul = 3
	H.stock(w, { scrap_wood = 10, scrap_metal = 5, nails = 5, electronics = 4, wire = 4 })
	H.force_build(w, "workbench", { x = 40, y = 0, z = 0 })
	local gen = blueprints.place(w, "generator", { x = 30, y = 30, z = 0 })
	-- deliver everything by hand so only the skill gates the work
	for _, id in ipairs(U.keys(BP.generator.materials)) do w:create(gen.delivered, id, BP.generator.materials[id], "test") end
	H.run(w, 200, function() H.keep_fed(w) end)
	T.eq(gen.state, "planned", "level 0 cannot build a skill-2 generator")
	c.skills.construction = { l = 2, xp = 0 }
	c.prio.build = 1
	H.run(w, 300, function() H.keep_fed(w) end)
	T.eq(gen.state, "built", "builds once skilled")
end)

T.test("cancelling a site returns delivered materials to a pile; nothing is lost", function()
	local w = H.world()
	local b = blueprints.place(w, "bed", { x = 20, y = 20, z = 0 })
	w:create(b.delivered, "scrap_wood", 2, "test")
	T.eq(blueprints.missing(b).cloth_scrap, 4)
	T.truthy(blueprints.cancel(w, b.id))
	T.eq(w:building(b.id), nil)
	T.eq(#w.s.piles, 1)
	T.eq(items.count(w.s.piles[1].items, "scrap_wood"), 2)
	H.audit_ok(T, w, "after cancel")
	T.eq(select(1, blueprints.cancel(w, "b999")), false)
end)

T.test("defense score, enclosure and structure damage / repair", function()
	local w = H.world()
	local s0, hp0, e0 = blueprints.defense(w)
	T.eq(s0, 0)
	T.eq(e0, 0)
	local walls = {}
	for i = 1, TUNING.base.perimeter_needed do walls[i] = H.force_build(w, "wall", { x = i * 4 - 20, y = 40, z = 0 }) end
	local s1, hp1, e1 = blueprints.defense(w)
	T.near(s1, 8 * TUNING.base.perimeter_needed, 1e-9)
	T.eq(e1, 1)
	T.eq(hp1, 220 * TUNING.base.perimeter_needed)
	blueprints.damage(w, walls[1], 110)
	local s2, _, e2 = blueprints.defense(w)
	T.lt(s2, s1)
	T.lt(e2, 1)
	blueprints.repair(walls[1], 1000)
	T.eq(walls[1].hp, walls[1].hp_max)
	-- destroying a wall removes it and tells the adapter
	w:flush_events()
	T.truthy(blueprints.damage(w, walls[2], 10000))
	T.eq(w:building(walls[2].id), nil)
	local evs = w:flush_events()
	T.eq(H.count(evs, "building_destroyed"), 1)
	-- damage is shared proportionally to structure hp
	local before = 0
	for i = 3, #walls do before = before + walls[i].hp end
	blueprints.damage_defenses(w, 90)
	local after = 0
	for i = 3, #walls do after = after + walls[i].hp end
	T.near(before - after, 90 * (before / (before + walls[1].hp)), 0.5, "damage split across all defensive structures")
end)

T.test("crates raise the main stockpile capacity", function()
	local w = H.world()
	w.s.zones[1].main = true
	local base_cap = w.s.zones[1].items.cap
	H.force_build(w, "crate", { x = 30, y = 0, z = 0 })
	T.eq(w.s.zones[1].items.cap, base_cap + BP.crate.storage_g)
	H.force_build(w, "crate", { x = 33, y = 0, z = 0 })
	T.eq(w.s.zones[1].items.cap, base_cap + 2 * BP.crate.storage_g)
end)

T.test("power: mains feeds consumers, outage cuts them, generator + fuel brings them back, fuel runs out", function()
	local w = H.world()
	local wb = H.force_build(w, "workbench", { x = 40, y = 0, z = 0 })
	local gen = H.force_build(w, "generator", { x = 50, y = 0, z = 0 })
	w:tick(1)
	T.truthy(wb.powered, "mains powers the workbench")
	T.eq(gen.fuel_min, 0)
	grid.start_power_outage(w, 600)
	local evs = w:tick(1)
	T.falsy(wb.powered, "outage: workbench off")
	local e = H.find(evs, "set_power")
	T.truthy(e, "set_power event emitted on change")
	T.eq(e.on, false)
	T.eq(e.buildings[1].powered, false)
	-- refuel: 1 litre = gen_min_per_l minutes
	local took = grid.add_fuel(gen, 2)
	T.eq(took, 2)
	T.eq(gen.fuel_min, 2 * TUNING.grid.gen_min_per_l)
	local evs2 = w:tick(1)
	T.truthy(wb.powered, "generator covers the demand")
	T.eq(H.find(evs2, "set_power").buildings[1].powered, true)
	local before = gen.fuel_min
	w:tick(10)
	T.near(before - gen.fuel_min, 10, 1e-9, "burns one minute of fuel per minute while needed")
	-- fuel cap
	local room_l = (BP.generator.fuel_cap_min - gen.fuel_min) / TUNING.grid.gen_min_per_l
	T.near(grid.add_fuel(gen, 1000), room_l, 1e-9, "tank limit")
	T.near(gen.fuel_min, BP.generator.fuel_cap_min, 1e-9)
	gen.fuel_min = 3
	w:tick(5)
	T.eq(gen.fuel_min, 0)
	T.falsy(wb.powered, "out of fuel: dark again")
	-- when the mains is on the generator does not burn fuel
	w.s.grid.power.outage_until = 0
	gen.fuel_min = 100
	w:tick(30)
	T.eq(gen.fuel_min, 100, "idle generator saves fuel")
end)

T.test("power: shortfall sheds the lowest-priority consumers first (brownout)", function()
	local saved = TUNING.grid.mains_cap_w
	TUNING.grid.mains_cap_w = 300
	local w = H.world()
	H.force_build(w, "workbench", { x = 40, y = 0, z = 0 })
	local stove = H.force_build(w, "stove", { x = 44, y = 0, z = 0 })
	local lamp = H.force_build(w, "lamp", { x = 48, y = 0, z = 0 })
	H.force_build(w, "bed", { x = -30, y = 0, z = 0 })
	local med = H.force_build(w, "medical_bed", { x = -34, y = 0, z = 0 })
	w:tick(1)
	TUNING.grid.mains_cap_w = saved
	T.truthy(med.powered, "medical bed has priority 1")
	T.truthy(lamp.powered, "the lamp is cheap and fits")
	T.falsy(stove.powered, "the stove (800 W) is shed")
	local wb = blueprints.list_built(w, "workbench")[1]
	T.falsy(wb.powered, "the workbench is shed")
	T.eq(w.s.grid.power.ok, false)
	-- disabling a building stops its demand and reports it off
	local stat = w.s.grid.power
	T.eq(stat.demand, 800 + 150 + 40 + 150)
end)

T.test("water: rain fills the tank through collectors; tank cap; drinking draws litres; outage", function()
	local w = H.world()
	local wa = w.s.grid.water
	wa.mains_dead = true
	wa.tank = 0
	local cap0 = grid.tank_cap(w)
	T.eq(cap0, TUNING.grid.tank_base_l)
	H.force_build(w, "rain_collector", { x = 30, y = 30, z = 0 })
	H.force_build(w, "water_tank", { x = 34, y = 30, z = 0 })
	T.eq(grid.tank_cap(w), cap0 + BP.water_tank.tank_l)
	-- dry weather: a trickle of dew
	w.s.grid.weather = { kind = "clear", until_t = 1e9 }
	local dry = BP.rain_collector.water_collect * TUNING.grid.dew_factor
	w:tick(10)
	T.near(wa.tank, dry * 10, 0.02, "dew only")
	grid.set_weather(w, "rain", 600)
	local t0 = wa.tank
	w:tick(10)
	T.near(wa.tank - t0, BP.rain_collector.water_collect * 10, 0.2, "rain collects at the full rate")
	grid.set_weather(w, "storm", 600)
	local t1 = wa.tank
	w:tick(10)
	T.near(wa.tank - t1, BP.rain_collector.water_collect * TUNING.grid.storm_collect_mult * 10, 0.2, "storms double it")
	wa.tank = grid.tank_cap(w) - 0.1
	w:tick(30)
	T.le(wa.tank, grid.tank_cap(w), "tank never overfills")
	wa.tank = 3
	T.near(grid.draw_water(w, 1), 1, 1e-9)
	T.near(wa.tank, 2 + 0, 0.05)
	wa.tank = 0.2
	T.near(grid.draw_water(w, 1), 0.2, 1e-9, "can only draw what is there")
	T.falsy(grid.water_available(w, 0.45) and wa.tank < 0.45)
	-- outage with the mains up: the mains stops, the tank is used
	wa.mains_dead = false
	wa.tank = 5
	T.truthy(grid.mains_water_on(w))
	grid.start_water_outage(w, 100)
	T.falsy(grid.mains_water_on(w))
	T.truthy(grid.water_available(w, 1))
end)

T.test("set_water event fires when the supply state flips", function()
	local w = H.world()
	local wa = w.s.grid.water
	wa.mains_dead = true
	wa.tank = 0
	w.s.grid.weather = { kind = "clear", until_t = 1e9 }
	local evs = w:tick(1)
	T.truthy(H.find(evs, "set_water"), "water just ran out")
	T.eq(H.find(evs, "set_water").on, false)
	wa.tank = 10
	local evs2 = w:tick(1)
	T.eq(H.find(evs2, "set_water").on, true)
end)

T.test("the city grid fails for good on its scheduled day and says so", function()
	local w = H.world()
	local dies = w.s.grid.power.dies_t
	T.truthy(dies >= 7 * 1440 - 1440 and dies < 14 * 1440)
	w.s.t = dies - 1
	local evs = w:tick(2)
	T.truthy(w.s.grid.power.mains_dead)
	T.truthy(H.find(evs, "notify", function(e) return e.text:find("power") end))
	T.falsy(grid.mains_power_on(w))
end)

T.test("fuel jobs: a colonist refuels the generator from the stockpile (cans destroyed as fuel, reserve kept)", function()
	local w = H.world()
	local c = H.colonist(w)
	for _, wt in ipairs({ "doctor", "guard", "cook", "craft", "scavenge", "build" }) do c.prio[wt] = 0 end
	H.force_build(w, "workbench", { x = 40, y = 0, z = 0 })
	local gen = H.force_build(w, "generator", { x = 50, y = 0, z = 0 })
	H.stock(w, { fuel_can = TUNING.jobs.fuel_reserve })
	H.run(w, 60, function() H.keep_fed(w) end)
	T.eq(gen.fuel_min, 0, "the last cans are reserved for expeditions")
	H.stock(w, { fuel_can = 2 })
	H.run(w, 90, function() H.keep_fed(w) end)
	T.gt(gen.fuel_min, 0, "a can was hauled to the generator")
	T.eq(w.s.ledger.reasons["-fuel"], 1)
	H.audit_ok(T, w, "after refuel")
end)
