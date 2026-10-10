-- traits.lua : colonist traits (data in data/traits.lua). A colonist stores only ids: c.traits = { "iron_gut", ... }
local U = require("sim.util")
local DEFS = require("data.traits")

local M = {}
M.defs = DEFS

local ALL
function M.ids()
	if not ALL then ALL = U.keys(DEFS) end
	return ALL
end

function M.def(id)
	local d = DEFS[id]
	if not d then error("unknown trait: " .. tostring(id), 2) end
	return d
end

function M.has(c, id)
	local t = c.traits
	for i = 1, #t do if t[i] == id then return true end end
	return false
end

-- roll n distinct, mutually compatible traits
function M.roll(rng, n)
	local ids = U.copy(M.ids())
	local out, taken = {}, {}
	rng:shuffle(ids)
	for i = 1, #ids do
		if #out >= n then break end
		local id = ids[i]
		local ok = true
		local d = DEFS[id]
		for j = 1, #(d.excludes or {}) do if taken[d.excludes[j]] then ok = false end end
		if ok then
			out[#out + 1] = id
			taken[id] = true
		end
	end
	return out
end

-- can these traits coexist?
function M.compatible(list)
	local set = U.set(list)
	for i = 1, #list do
		local d = DEFS[list[i]]
		if not d then return false end
		for j = 1, #(d.excludes or {}) do if set[d.excludes[j]] then return false end end
	end
	return true
end

function M.mul(c, key)
	local m = 1
	local t = c.traits
	for i = 1, #t do
		local d = DEFS[t[i]]
		if d.mul and d.mul[key] then m = m * d.mul[key] end
	end
	return m
end

function M.add(c, key)
	local a = 0
	local t = c.traits
	for i = 1, #t do
		local d = DEFS[t[i]]
		if d.add and d.add[key] then a = a + d.add[key] end
	end
	return a
end

function M.skill_mul(c, skill)
	local m = 1
	local t = c.traits
	for i = 1, #t do
		local d = DEFS[t[i]]
		if d.skill_mul and d.skill_mul[skill] then m = m * d.skill_mul[skill] end
	end
	return m
end

function M.thought_mul(c, thought_id)
	local m = 1
	local t = c.traits
	for i = 1, #t do
		local d = DEFS[t[i]]
		if d.thoughts and d.thoughts[thought_id] then m = m * d.thoughts[thought_id] end
	end
	return m
end

function M.blocks(c, work)
	local t = c.traits
	for i = 1, #t do
		local d = DEFS[t[i]]
		if d.blocks then
			for j = 1, #d.blocks do if d.blocks[j] == work then return true end end
		end
	end
	return false
end

function M.schedule_pref(c)
	local t = c.traits
	for i = 1, #t do
		local d = DEFS[t[i]]
		if d.schedule then return d.schedule end
	end
	return "day"
end

return M
