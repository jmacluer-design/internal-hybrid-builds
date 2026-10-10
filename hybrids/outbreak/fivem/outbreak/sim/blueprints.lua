-- blueprints.lua : placing, supplying, building, damaging and repairing structures.
-- A building is plain data in w.s.buildings:
--   { id, bp, pos, state = "planned" | "built", hp, hp_max, progress, delivered = <container>,
--     placed, built_t, fuel_min (generators), powered (bool), pct (last reported 25% step) }
-- Prerequisites (`needs` in the data) are checked when a blueprint is PLACED: the listed
-- buildings must already be finished. Materials are delivered by haul jobs, then consumed
-- (destroyed in the ledger as "construct") when the last unit of work lands.
local U = require("sim.util")
local TUNING = require("data.tuning")
local DEFS = require("data.blueprints")
local items = require("sim.items")

local M = {}
M.defs = DEFS

local ALL
function M.ids()
	if not ALL then ALL = U.keys(DEFS) end
	return ALL
end

function M.def(id)
	local d = DEFS[id]
	if not d then error("unknown blueprint: " .. tostring(id), 2) end
	return d
end

-- count buildings of a kind (planned + built, or only built)
function M.count(w, id, built_only)
	local n = 0
	local bs = w.s.buildings
	for i = 1, #bs do
		local b = bs[i]
		if b.bp == id and (not built_only or b.state == "built") then n = n + 1 end
	end
	return n
end

function M.list_built(w, id)
	local out = {}
	local bs = w.s.buildings
	for i = 1, #bs do
		if bs[i].bp == id and bs[i].state == "built" then out[#out + 1] = bs[i] end
	end
	return out
end

function M.list_tag(w, tag, built_only)
	local out = {}
	local bs = w.s.buildings
	for i = 1, #bs do
		local b = bs[i]
		if DEFS[b.bp].tags[tag] and (not built_only or b.state == "built") then out[#out + 1] = b end
	end
	return out
end

-- why a blueprint cannot be placed (nil when it can): reason string
function M.why_not(w, id, pos)
	local d = DEFS[id]
	if not d then return "unknown_blueprint" end
	local base = TUNING.base
	if U.dist2(pos.x, pos.y, base.x, base.y) > base.build_radius then return "too_far" end
	if d.needs then
		for _, need in ipairs(U.keys(d.needs)) do
			if M.count(w, need, true) < d.needs[need] then return "prereq:" .. need end
		end
	end
	if d.max and M.count(w, id, false) >= d.max then return "max_reached" end
	local bs = w.s.buildings
	for i = 1, #bs do
		if U.dist2(bs[i].pos.x, bs[i].pos.y, pos.x, pos.y) < base.min_spacing then return "blocked" end
	end
	return nil
end

function M.can_place(w, id, pos)
	local why = M.why_not(w, id, pos)
	return why == nil, why
end

-- place a blueprint site. Returns building or nil, reason.
function M.place(w, id, pos)
	local why = M.why_not(w, id, pos)
	if why then return nil, why end
	local d = DEFS[id]
	local b = {
		id = w:new_id("b"), bp = id, pos = U.pos_copy(pos), state = "planned", hp = 0, hp_max = d.hp,
		progress = 0, delivered = items.new(), placed = w.s.t, pct = 0, powered = false,
	}
	if d.power_gen then b.fuel_min = 0 end
	w:add_building(b)
	w:emit({ type = "place_blueprint", id = b.id, bp = id, pos = U.pos_copy(b.pos), materials = U.copy(d.materials), work = d.work })
	return b
end

function M.missing(b)
	local d = DEFS[b.bp]
	local out = {}
	for item, n in pairs(d.materials) do -- order-free
		local have = b.delivered.items[item] or 0
		if have < n then out[item] = n - have end
	end
	return out
end

function M.is_supplied(b) return next(M.missing(b)) == nil end

function M.work_total(b) return DEFS[b.bp].work end

-- add work (already scaled by the worker's speed). Returns true when the building is finished.
function M.add_work(w, b, amount)
	if b.state ~= "planned" or not M.is_supplied(b) then return false end
	local d = DEFS[b.bp]
	b.progress = U.min(d.work, b.progress + amount)
	local pct = math.floor(b.progress / d.work * 100)
	if pct >= b.pct + 25 and pct < 100 then
		b.pct = pct - pct % 25
		w:emit({ type = "construction_progress", id = b.id, bp = b.bp, pct = b.pct })
	end
	if b.progress >= d.work then
		M.complete(w, b)
		return true
	end
	return false
end

function M.complete(w, b)
	local d = DEFS[b.bp]
	for _, item in ipairs(U.keys(d.materials)) do
		w:destroy(b.delivered, item, d.materials[item], "construct")
	end
	b.state = "built"
	b.hp = b.hp_max
	b.progress = d.work
	b.pct = 100
	b.built_t = w.s.t
	if d.power_gen then b.fuel_min = 0 end
	w:building_changed(b, "built")
	w:emit({ type = "construction_done", id = b.id, bp = b.bp, pos = U.pos_copy(b.pos) })
end

-- cancel a site (or demolish a finished building): delivered materials go to a pile at its position
function M.cancel(w, id)
	local b = w:building(id)
	if not b then return false, "no_such_building" end
	local pile
	if not items.is_empty(b.delivered) then
		pile = w:pile_for(b.pos)
		for _, it in ipairs(items.list(b.delivered)) do items.transfer(b.delivered, pile.items, it.id, it.n) end
	end
	w:remove_building(b)
	return true
end

-- damage a finished building. Returns true when it was destroyed.
function M.damage(w, b, amount)
	if b.state ~= "built" or amount <= 0 then return false end
	b.hp = b.hp - amount
	if b.hp <= 0 then
		w:emit({ type = "building_destroyed", id = b.id, bp = b.bp, pos = U.pos_copy(b.pos) })
		w:remove_building(b)
		return true
	end
	return false
end

function M.repair(b, amount)
	if b.state ~= "built" then return end
	b.hp = U.min(b.hp_max, b.hp + amount)
end

-- spread `amount` of wall damage over the defensive structures, weakest-first is NOT used: damage
-- is shared in proportion to hp so the result is order-independent.
function M.damage_defenses(w, amount)
	if amount <= 0 then return 0 end
	local list, total = {}, 0
	local bs = w.s.buildings
	for i = 1, #bs do
		local b = bs[i]
		local d = DEFS[b.bp]
		if b.state == "built" and d.defense then list[#list + 1] = b; total = total + b.hp end
	end
	if total <= 0 then return 0 end
	local destroyed = 0
	for i = 1, #list do
		local b = list[i]
		local share = amount * b.hp / total
		if M.damage(w, b, share) then destroyed = destroyed + 1 end
	end
	return destroyed
end

-- defense score (hp weighted), total structure hp, perimeter enclosure 0..1
function M.defense(w)
	local score, hp, perim = 0, 0, 0
	local bs = w.s.buildings
	for i = 1, #bs do
		local b = bs[i]
		if b.state == "built" then
			local d = DEFS[b.bp]
			local f = b.hp / b.hp_max
			if d.defense then score = score + d.defense * f; hp = hp + b.hp end
			if d.perimeter then perim = perim + d.perimeter * f end
		end
	end
	local enclosure = U.min(1, perim / TUNING.base.perimeter_needed)
	return score, hp, enclosure
end

function M.beds(w)
	local out = {}
	local bs = w.s.buildings
	for i = 1, #bs do
		local b = bs[i]
		if b.state == "built" and DEFS[b.bp].tags.bed then out[#out + 1] = b end
	end
	return out
end

-- extra storage capacity (grams) from finished crates
function M.storage_bonus(w)
	local g = 0
	local bs = w.s.buildings
	for i = 1, #bs do
		local b = bs[i]
		if b.state == "built" and DEFS[b.bp].storage_g then g = g + DEFS[b.bp].storage_g end
	end
	return g
end

-- wealth of finished buildings
function M.wealth(w)
	local v = 0
	local bs = w.s.buildings
	for i = 1, #bs do
		if bs[i].state == "built" then v = v + DEFS[bs[i].bp].value end
	end
	return v
end

-- validate data: materials are real items etc. Returns ok, err.
function M.validate()
	for _, id in ipairs(M.ids()) do
		local d = DEFS[id]
		for item, n in pairs(d.materials) do -- order-free
			if not items.exists(item) then return false, id .. ": unknown material " .. item end
			if n <= 0 or n ~= math.floor(n) then return false, id .. ": bad material count" end
		end
		if d.needs then
			for need in pairs(d.needs) do -- order-free
				if not DEFS[need] then return false, id .. ": unknown prerequisite " .. need end
				if need == id then return false, id .. ": requires itself" end
			end
		end
		if d.work <= 0 or d.hp <= 0 then return false, id .. ": bad work/hp" end
	end
	return true
end

return M
