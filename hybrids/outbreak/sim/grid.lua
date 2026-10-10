-- grid.lua : power + water networks, outage timers, generator fuel, weather.
--
-- s.grid = {
--   power = { dies_t, mains_dead, outage_until, supply, demand, mains_on, gens_running },
--   water = { dies_t, mains_dead, outage_until, tank, ok },
--   weather = { kind = "clear" | "rain" | "storm", until_t } }
-- Power: the city mains (until it dies for good, or during an outage) plus fuel generators cover
-- the demand of powered buildings; a shortfall sheds the lowest-priority consumers first.
-- Water: a tank filled by rain collectors (and the mains while it lasts) that colonists drink from.
local U = require("sim.util")
local TUNING = require("data.tuning")
local BP = require("data.blueprints")
local items = require("sim.items")
local clock = require("sim.clock")

local M = {}
local G = TUNING.grid

function M.init(w)
	local rng = w:rng("grid")
	w.s.grid = {
		power = { dies_t = clock.at(rng:int(G.mains_power_dies_day[1], G.mains_power_dies_day[2]), rng:int(0, 23), 0),
			mains_dead = false, outage_until = 0, supply = 0, demand = 0, mains_on = true, gens_running = 0 },
		water = { dies_t = clock.at(rng:int(G.mains_water_dies_day[1], G.mains_water_dies_day[2]), rng:int(0, 23), 0),
			mains_dead = false, outage_until = 0, tank = G.tank_start_l, ok = true },
		weather = { kind = "clear", until_t = 0 },
	}
end

function M.mains_power_on(w)
	local p = w.s.grid.power
	return (not p.mains_dead) and w.s.t >= p.outage_until
end

function M.mains_water_on(w)
	local p = w.s.grid.water
	return (not p.mains_dead) and w.s.t >= p.outage_until
end

function M.tank_cap(w)
	local cap = G.tank_base_l
	local bs = w.s.buildings
	for i = 1, #bs do
		local b = bs[i]
		if b.state == "built" and BP[b.bp].tank_l then cap = cap + BP[b.bp].tank_l end
	end
	return cap
end

function M.start_power_outage(w, minutes)
	local p = w.s.grid.power
	local until_t = w.s.t + minutes
	if until_t > p.outage_until then p.outage_until = until_t end
	w.rt.grid_dirty = true
end

function M.start_water_outage(w, minutes)
	local p = w.s.grid.water
	local until_t = w.s.t + minutes
	if until_t > p.outage_until then p.outage_until = until_t end
	w.rt.grid_dirty = true
end

function M.set_weather(w, kind, minutes)
	local wt = w.s.grid.weather
	wt.kind = kind
	wt.until_t = w.s.t + minutes
	w:emit({ type = "weather", kind = kind, minutes = minutes })
end

function M.weather(w) return w.s.grid.weather.kind end

-- generator refuel: add runtime minutes from litres. Returns litres accepted.
function M.add_fuel(b, litres)
	local d = BP[b.bp]
	if not d.power_gen then return 0 end
	local room_min = d.fuel_cap_min - b.fuel_min
	local accept_min = U.min(room_min, litres * G.gen_min_per_l)
	if accept_min <= 0 then return 0 end
	b.fuel_min = b.fuel_min + accept_min
	return accept_min / G.gen_min_per_l
end

-- drink from the water network. Returns litres actually drawn.
function M.draw_water(w, litres)
	local wa = w.s.grid.water
	if M.mains_water_on(w) then return litres end
	if wa.tank >= litres then wa.tank = wa.tank - litres; return litres end
	local got = wa.tank
	wa.tank = 0
	return got
end

function M.water_available(w, litres)
	local wa = w.s.grid.water
	return M.mains_water_on(w) or wa.tank >= (litres or G.drink_l)
end

function M.power_status(w)
	local p = w.s.grid.power
	return { supply = p.supply, demand = p.demand, mains = p.mains_on, gens_running = p.gens_running }
end

function M.fuel_minutes(w)
	local m = 0
	local bs = w.s.buildings
	for i = 1, #bs do
		local b = bs[i]
		if b.state == "built" and BP[b.bp].power_gen then m = m + b.fuel_min end
	end
	return m
end

-- advance one step of dt minutes
function M.step(w, dt)
	local s = w.s
	local g = s.grid
	local now = s.t
	local rng = w:rng("grid")

	-- weather
	local wt = g.weather
	if wt.kind ~= "clear" and now >= wt.until_t then
		wt.kind = "clear"
		w:emit({ type = "weather", kind = "clear", minutes = 0 })
	elseif wt.kind == "clear" then
		local si = clock.season_index(now)
		if rng:chance(G.rain_per_hour[si] / 60 * dt) then
			M.set_weather(w, "rain", rng:int(G.rain_minutes[1], G.rain_minutes[2]))
		end
	end

	-- mains failing for good
	if not g.power.mains_dead and now >= g.power.dies_t then
		g.power.mains_dead = true
		w:notify("warn", "The city power grid has failed for good. Generators are the only power now.")
	end
	if not g.water.mains_dead and now >= g.water.dies_t then
		g.water.mains_dead = true
		w:notify("warn", "The city water supply has stopped for good. Collect rain or find bottled water.")
	end

	-- water
	local wa = g.water
	local cap = M.tank_cap(w)
	local rate = 0
	local rain_mult = (wt.kind == "storm" and G.storm_collect_mult) or (wt.kind == "rain" and G.rain_collect_mult) or G.dew_factor
	local bs = s.buildings
	for i = 1, #bs do
		local b = bs[i]
		if b.state == "built" and BP[b.bp].water_collect then rate = rate + BP[b.bp].water_collect * rain_mult * (b.hp / b.hp_max) end
	end
	if M.mains_water_on(w) then rate = rate + G.mains_water_fill end
	wa.tank = U.clamp(wa.tank + rate * dt, 0, cap)
	local wok = M.mains_water_on(w) or wa.tank > G.drink_l
	if wok ~= wa.ok then
		wa.ok = wok
		w:emit({ type = "set_water", on = wok, tank = wa.tank, mains = M.mains_water_on(w) })
	end

	-- power
	local p = g.power
	local mains_on = M.mains_power_on(w)
	local demand_list = {}
	local demand = 0
	for i = 1, #bs do
		local b = bs[i]
		local d = BP[b.bp]
		if b.state == "built" and d.power_use and b.enabled ~= false then
			demand_list[#demand_list + 1] = b
			demand = demand + d.power_use
		end
	end
	local supply = mains_on and TUNING.grid.mains_cap_w or 0
	local gens_running = 0
	-- generators cover what the mains cannot; they only burn fuel while needed
	local gens = {}
	for i = 1, #bs do
		local b = bs[i]
		if b.state == "built" and BP[b.bp].power_gen and b.fuel_min > 0 then gens[#gens + 1] = b end
	end
	local need = demand - supply
	for i = 1, #gens do
		local b = gens[i]
		if need > 0 then
			gens_running = gens_running + 1
			supply = supply + BP[b.bp].power_gen * (b.hp / b.hp_max)
			need = need - BP[b.bp].power_gen
			b.fuel_min = U.max(0, b.fuel_min - dt)
			b.running = true
		else
			b.running = false
		end
	end
	p.mains_on, p.supply, p.demand, p.gens_running = mains_on, supply, demand, gens_running
	-- allocate by priority (lower number = served first), ties by building id
	U.sort(demand_list, function(a, b2)
		local pa, pb = G.power_prio[a.bp] or 9, G.power_prio[b2.bp] or 9
		if pa ~= pb then return pa < pb end
		return a.id < b2.id
	end)
	local remaining = supply
	local changed
	for i = 1, #demand_list do
		local b = demand_list[i]
		local use = BP[b.bp].power_use
		local on = remaining >= use
		if on then remaining = remaining - use end
		if b.powered ~= on then
			b.powered = on
			changed = changed or {}
			changed[#changed + 1] = { id = b.id, bp = b.bp, powered = on }
		end
	end
	-- buildings that no longer demand power (disabled / destroyed) are unpowered
	for i = 1, #bs do
		local b = bs[i]
		if b.powered and (b.state ~= "built" or not BP[b.bp].power_use or b.enabled == false) then
			b.powered = false
			changed = changed or {}
			changed[#changed + 1] = { id = b.id, bp = b.bp, powered = false }
		end
	end
	local pok = (demand == 0) or supply >= demand
	if changed or pok ~= p.ok then
		local was_ok = p.ok
		p.ok = pok
		w:emit({ type = "set_power", on = supply > 0, supply = supply, demand = demand, mains = mains_on, buildings = changed or {} })
		if was_ok == true and pok == false then w:on_power_lost() end
	end
end

return M
