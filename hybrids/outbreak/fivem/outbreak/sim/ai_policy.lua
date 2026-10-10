-- ai_policy.lua : a simple default "player" for headless runs (bin/sim-run.lua, bin/balance.lua, the soak test).
-- It issues exactly the orders a human would through the adapter contract (world:handle{type="order", ...}):
-- build plan, work priorities, schedules, drafting when a threat is close, expeditions when stocks run low,
-- equipping weapons, medical policy, and trading with caravans.
-- It is NOT part of the sim state: it only reads w.s and sends orders. Deterministic given the world.
local U = require("sim.util")
local TUNING = require("data.tuning")
local DISTRICTS = require("data.districts")
local BP = require("data.blueprints")
local items = require("sim.items")
local clock = require("sim.clock")
local colonist = require("sim.colonist")
local skills = require("sim.skills")
local traits = require("sim.traits")
local stockpile = require("sim.stockpile")
local blueprints = require("sim.blueprints")
local horde = require("sim.horde")
local factions = require("sim.factions")
local expedition = require("sim.expedition")
local combat = require("sim.combat_abstract")

local M = {}
local floor = math.floor

M.CFG = {
	period = 10,            -- minutes between policy runs
	draft_radius = 420,     -- hordes closer than this (and big enough) get everyone to arms
	max_open_sites = 3,
	reserve_wood = 6, reserve_metal = 4,
	exped_cooldown = 120,
	food_days_low = 4,
	build_plan = {
		{ "bed", "per_colonist" },
		{ "wall", 4 }, { "barricade", 3 }, { "rain_collector", 1 }, { "door", 1 }, { "wall", 8 }, { "crate", 1 },
		{ "watchtower", 1 }, { "barricade", 6 }, { "generator", 1 }, { "wall", 12 }, { "watchtower", 2 },
		{ "stove", 1 }, { "lamp", 2 }, { "medical_bed", 1 }, { "water_tank", 1 }, { "watchtower", 2 },
		{ "rain_collector", 2 }, { "crate", 2 }, { "lamp", 3 }, { "radio_mast", 1 }, { "workbench", 2 },
		{ "bed", "extra" },
	},
}

local function order(w, sink, id, kind, target)
	local evs = w:handle({ type = "order", id = id, kind = kind, target = target })
	if sink then for i = 1, #evs do sink[#sink + 1] = evs[i] end end
	for i = 1, #evs do
		if evs[i].type == "order_result" then return evs[i] end
	end
	return nil
end

local function total(w, id) return stockpile.total(w.s.zones, id) end

local function stock_ok(w, bp_id, keep)
	local d = BP[bp_id]
	for item, n in pairs(d.materials) do -- order-free (boolean AND)
		local reserve = 0
		if item == "scrap_wood" then reserve = M.CFG.reserve_wood elseif item == "scrap_metal" then reserve = M.CFG.reserve_metal end
		if total(w, item) < n + (keep and reserve or 0) then return false end
	end
	return true
end

local function count_open_sites(w)
	local n = 0
	for i = 1, #w.s.buildings do if w.s.buildings[i].state == "planned" then n = n + 1 end end
	return n
end

local function build_pos(w, k)
	local b = TUNING.base
	local dir = horde.DIRS[(k * 5) % 16 + 1]
	local radius = 22 + 5 * floor(k / 16) + (k % 3) * 3
	return { x = b.x + dir[1] * radius, y = b.y + dir[2] * radius, z = b.z }
end

-- ---------------------------------------------------------------------------------------------
local function plan_builds(w, sink)
	local s = w.s
	if count_open_sites(w) >= M.CFG.max_open_sites then return end
	local n_col = #s.colonists
	local have = {}
	for i = 1, #s.buildings do have[s.buildings[i].bp] = (have[s.buildings[i].bp] or 0) + 1 end
	local want_total = {}
	for _, step in ipairs(M.CFG.build_plan) do
		local id, n = step[1], step[2]
		if n == "per_colonist" then n = n_col elseif n == "extra" then n = n_col + 2 end
		want_total[id] = (want_total[id] or 0) + ((type(n) == "number") and n or 0)
		-- cumulative target for this id up to this plan step
		local target = want_total[id]
		if (have[id] or 0) < target then
			if stock_ok(w, id, true) and select(1, blueprints.can_place(w, id, build_pos(w, #s.buildings + 1))) then
				local pos = build_pos(w, #s.buildings + 1)
				local res = order(w, sink, "colony", "place_blueprint", { bp = id, pos = pos })
				if res and res.ok then return end
			end
			-- not affordable / blocked: do not skip ahead to cheaper things past a defensive core step
			if id == "wall" or id == "watchtower" or id == "generator" then return end
		end
	end
end

-- ---------------------------------------------------------------------------------------------
local function assign_roles(w, sink)
	local s = w.s
	local cs = s.colonists
	local n = #cs
	if n == 0 then return end
	-- rank by skill for each role
	local function best(skill, taken)
		local bi, bv
		for i = 1, n do
			local c = cs[i]
			if not taken[c.id] then
				local v = skills.level(c, skill) * 10 + (10 - i * 0.01)
				if not bv or v > bv then bi, bv = i, v end
			end
		end
		return bi
	end
	local taken = {}
	local doctor_i = best("medicine", taken); if doctor_i then taken[cs[doctor_i].id] = "doctor" end
	local builder_i = best("construction", taken); if builder_i then taken[cs[builder_i].id] = "builder" end
	local cook_i = (n >= 4) and best("cooking", taken) or nil; if cook_i then taken[cs[cook_i].id] = "cook" end
	-- night guards: the best shooters (not pacifists), about a third of the colony
	local guards = {}
	local order_list = {}
	for i = 1, n do order_list[#order_list + 1] = cs[i] end
	U.sort(order_list, function(a, b)
		local va = skills.level(a, "shooting") + skills.level(a, "melee")
		local vb = skills.level(b, "shooting") + skills.level(b, "melee")
		if va ~= vb then return va > vb end
		return a.id < b.id
	end)
	local want_guards = math.max(1, floor(n / 3 + 0.5))
	for i = 1, #order_list do
		if #guards < want_guards and colonist.can_work(order_list[i], "guard") then guards[#guards + 1] = order_list[i].id end
	end
	local gset = U.set(guards)
	for i = 1, n do
		local c = cs[i]
		local role = taken[c.id]
		local pr = {}
		pr.doctor = (role == "doctor") and 1 or 3
		pr.build = (role == "builder") and 1 or 3
		pr.cook = (role == "cook") and 1 or 3
		pr.craft = (role == "builder") and 2 or 3
		pr.haul = 2
		pr.guard = gset[c.id] and 1 or 3
		pr.scavenge = (not gset[c.id] and role ~= "doctor") and 2 or 4
		for k, lvl in pairs(pr) do -- order-free (independent orders)
			if c.prio[k] ~= lvl and colonist.can_work(c, k) then order(w, sink, c.id, "priority", { work = k, level = lvl }) end
		end
		local want = gset[c.id] and "night" or "day"
		local have = traits.schedule_pref(c)
		-- traits that pin a schedule keep it; everyone else follows the role
		local sched = colonist.default_schedule(have ~= "day" and have or want)
		if c.sched ~= sched then order(w, sink, c.id, "schedule", sched) end
	end
end

-- ---------------------------------------------------------------------------------------------
local function threat_close(w)
	local s = w.s
	local b = TUNING.base
	local R = M.CFG.draft_radius
	for i = 1, #s.hordes do
		local h = s.hordes[i]
		if h.size >= 8 and U.dist2(h.x, h.y, b.x, b.y) <= R and (h.tx or h.state == "assault") then return true end
	end
	for i = 1, #s.raids do
		local r = s.raids[i]
		if U.dist2(r.x, r.y, b.x, b.y) <= R * 1.5 then return true end
	end
	return false
end

local function manage_draft(w, sink, st)
	local s = w.s
	local close = threat_close(w)
	if close and not st.drafted then
		st.drafted = true
		for i = 1, #s.colonists do
			local c = s.colonists[i]
			if not c.dead and not c.downed and c.state ~= "away" and colonist.can_work(c, "guard") and c.inf.stage ~= "terminal" then
				order(w, sink, c.id, "draft", true)
			end
		end
	elseif (not close) and st.drafted then
		st.drafted = false
		order(w, sink, "all", "draft", false)
	end
end

-- ---------------------------------------------------------------------------------------------
local function food_count(w)
	local tot = stockpile.totals(w.s.zones)
	local n = 0
	for id, k in pairs(tot) do -- order-free
		local d = items.defs[id]
		if d.food and (d.food.hunger or 0) >= 8 then n = n + k * ((d.food.hunger >= 40) and 1.4 or 1) end
	end
	return n
end

local function pick_district(w, crew_n, needs_list, max_travel)
	local danger_cap = (crew_n >= 4 and 4) or (crew_n >= 3 and 3) or 2
	local armed = 0
	for i = 1, #w.s.colonists do
		local _, _, usable = colonist.best_weapon(w.s.colonists[i])
		if usable then armed = armed + 1 end
	end
	if armed >= 5 then danger_cap = 5 end
	local best, bscore
	for _, id in ipairs(U.keys(DISTRICTS)) do
		local d = DISTRICTS[id]
		if d.danger <= danger_cap and (not max_travel or d.travel <= max_travel) then
			local match = 0
			for i = 1, #needs_list do
				local nd = needs_list[i]
				local t = d.loot
				local m = 0
				if nd == "food" and (t == "rural" or t == "residential" or t == "commercial") then m = m + 3 end
				if nd == "food" and t == "rural" then m = m + 1 end
				if nd == "meds" and t == "medical" then m = m + 4 end
				if nd == "meds" and (t == "residential" or t == "commercial") then m = m + 1 end
				if nd == "fuel" and (t == "industrial" or t == "garage" or t == "rural") then m = m + 3 end
				if nd == "fuel" and t == "garage" then m = m + 1 end
				if nd == "materials" and t == "industrial" then m = m + 4 end
				if nd == "materials" and (t == "garage" or t == "rural") then m = m + 1 end
				if nd == "ammo" and (t == "military" or t == "police") then m = m + 3 end
				if nd == "general" then m = m + 1 end
				match = match + m / i -- earlier (more urgent) needs weigh more
			end
			local score = match * 2 - d.danger * 0.9 - d.travel / 45
			if not bscore or score > bscore then best, bscore = id, score end
		end
	end
	return best
end

local function manage_expeditions(w, sink, st)
	local s = w.s
	local now = s.t
	if #s.exped > 0 then return end
	if now - (st.last_exped or -1e9) < M.CFG.exped_cooldown then return end
	if s.alert > 0 or clock.is_night(now) or clock.hour(now) >= 19 then return end
	local n = #s.colonists
	if n < 2 then return end
	-- what do we need?
	local needs_list = {}
	local food_days = food_count(w) / (n * 3.3)
	if food_days < M.CFG.food_days_low then needs_list[#needs_list + 1] = "food" end
	if total(w, "bandage") < 4 or total(w, "antibiotics") < 1 then needs_list[#needs_list + 1] = "meds" end
	if total(w, "fuel_can") < 3 then needs_list[#needs_list + 1] = "fuel" end
	local defense = blueprints.defense(w)
	if total(w, "scrap_wood") < 18 or total(w, "scrap_metal") < 10 or (defense < 70 + 5 * clock.day(now) and total(w, "scrap_wood") < 40) then
		needs_list[#needs_list + 1] = "materials"
	end
	if total(w, "ammo_9mm") + total(w, "ammo_shell") + total(w, "ammo_rifle") < 40 then needs_list[#needs_list + 1] = "ammo" end
	if #needs_list == 0 then
		if clock.day(now) % 2 == 1 then return end
		needs_list[1] = "general"
	end
	local crew_n = U.clamp(floor(n / 2), 1, 4)
	local district = pick_district(w, crew_n, needs_list)
	if not district then return end
	-- open sign-up: volunteers come from the `scavenge` work type
	local res = order(w, sink, "colony", "expedition", { district = district, size = crew_n })
	if (not res or not res.ok) and res and (res.reason == "no_fuel" or res.reason == "no_vehicle" or res.reason == "vehicle_damaged") then
		-- no fuel / no usable vehicle: go on foot to somewhere close
		local near = pick_district(w, crew_n, needs_list, 30)
		if near then res = order(w, sink, "colony", "expedition", { district = near, size = crew_n, mode = "foot" }) end
	end
	if res and res.ok then st.last_exped = now end
end

-- ---------------------------------------------------------------------------------------------
local function manage_equipment(w, sink)
	local s = w.s
	for i = 1, #s.colonists do
		local c = s.colonists[i]
		if not c.dead and c.state ~= "away" and (not c.job or c.job.class < 4) and not (c.orders and #c.orders > 0) then
			local id, d, usable = colonist.best_weapon(c)
			if colonist.can_work(c, "guard") then
				if not id or d.weapon.kind == "melee" or not usable then
					-- look for a gun with ammo in stock
					for _, gun in ipairs({ "rifle", "shotgun", "pistol" }) do
						local ammo = items.defs[gun].weapon.ammo
						if total(w, gun) > 0 and total(w, ammo) >= 10 then
							order(w, sink, c.id, "equip", { item = gun })
							break
						end
					end
				elseif d.weapon.kind == "ranged" then
					local have = c.inv.items[d.weapon.ammo] or 0
					if have < 20 and total(w, d.weapon.ammo) >= 10 then order(w, sink, c.id, "equip", { item = d.weapon.ammo }) end
				end
			end
		end
	end
end

local function manage_medical(w, sink)
	local want = (total(w, "antibiotics") == 0 and total(w, "surgical_kit") > 0)
	for i = 1, #w.s.colonists do
		local c = w.s.colonists[i]
		if c.allow_amputation ~= want then order(w, sink, c.id, "amputation", want) end
	end
end

-- ---------------------------------------------------------------------------------------------
-- trading: sell surplus for what we are short of
local SURPLUS = { "jewelry", "radio_set", "toolbox", "soda_can", "sandbag", "concrete_bag", "crowbar", "wire", "electronics", "duct_tape", "cloth_scrap", "canned_fruit" }
local KEEP = { electronics = 6, wire = 6, cloth_scrap = 18, duct_tape = 3, soda_can = 2, canned_fruit = 2, sandbag = 0, concrete_bag = 0, toolbox = 0, jewelry = 0, radio_set = 0, crowbar = 1 }

local function try_trade(w, sink, caravan)
	-- wants in priority order with target stock levels
	local goals = {
		{ "antibiotics", 4 }, { "bandage", 10 }, { "ammo_9mm", 90 }, { "ration_pack", 8 }, { "canned_beans", 14 }, { "canned_veg", 14 },
		{ "fuel_can", 5 }, { "water_bottle", 18 }, { "first_aid_kit", 2 }, { "scrap_metal", 14 }, { "ammo_shell", 20 },
	}
	local take, tv = {}, 0
	for _, g in ipairs(goals) do
		local have = total(w, g[1])
		local avail = caravan.stock.items[g[1]] or 0
		local want = g[2] - have
		if want > 0 and avail > 0 then
			local n = U.min(want, avail)
			if n > 0 then take[g[1]] = n end
		end
	end
	if U.is_empty(take) then return end
	-- build the give list from surplus, most valuable first
	local give, gv = {}, 0
	local _, need_v = factions.quote(w, caravan.id, {}, take)
	local cands = {}
	for _, id in ipairs(SURPLUS) do
		local extra = total(w, id) - (KEEP[id] or 0)
		if extra > 0 then cands[#cands + 1] = { id = id, extra = extra, v = items.defs[id].value } end
	end
	U.sort(cands, function(a, b) if a.v ~= b.v then return a.v > b.v end return a.id < b.id end)
	for _, c in ipairs(cands) do
		if gv >= need_v then break end
		for n = 1, c.extra do
			if gv >= need_v then break end
			give[c.id] = n
			local g = factions.quote(w, caravan.id, give, {})
			gv = g
		end
	end
	if gv < need_v then
		-- shrink the shopping list to what the surplus can pay for
		local keys = U.keys(take)
		for i = #keys, 1, -1 do
			if gv >= select(2, factions.quote(w, caravan.id, {}, take)) then break end
			take[keys[i]] = nil
		end
		if U.is_empty(take) then return end
	end
	local g2, t2 = factions.quote(w, caravan.id, give, take)
	if g2 and t2 and g2 >= t2 and next(give) ~= nil then
		order(w, sink, "colony", "trade", { caravan = caravan.id, give = give, take = take })
	end
end

local function manage_trade(w, sink, st)
	local cs = w.s.caravans
	for i = 1, #cs do
		if not (st.traded and st.traded[cs[i].id]) then
			st.traded = st.traded or {}
			st.traded[cs[i].id] = true
			try_trade(w, sink, cs[i])
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- state: policy-private table (kept by the caller). sink: optional array receiving every event the orders produced.
function M.new() return { last_roster = "", last_hour = -1 } end

function M.step(w, st, sink)
	local s = w.s
	if s.over then return end
	manage_draft(w, sink, st)
	local hour_key = floor(s.t / 60)
	if hour_key ~= st.last_hour then
		st.last_hour = hour_key
		local roster = {}
		for i = 1, #s.colonists do roster[#roster + 1] = s.colonists[i].id end
		local rk = table.concat(roster, ",")
		if rk ~= st.last_roster then
			st.last_roster = rk
			assign_roles(w, sink)
		end
		plan_builds(w, sink)
		manage_expeditions(w, sink, st)
		manage_equipment(w, sink)
		manage_medical(w, sink)
		manage_trade(w, sink, st)
	end
end

return M
