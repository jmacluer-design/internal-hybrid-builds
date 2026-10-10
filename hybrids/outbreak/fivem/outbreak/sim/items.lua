-- items.lua : item definitions + containers (weight cap, optional slot cap, stacks).
--
-- A container is plain data:  { items = { [item_id] = count }, w = grams, s = stacks_used,
--                               cap = max_grams | nil, slots = max_stacks | nil }
-- All counts are positive integers; zero entries are deleted. Every mutation goes through
-- add / remove / transfer so the cached `w` and `s` always agree with the contents
-- (check() recomputes them from scratch for the tests).
local U = require("sim.util")
local DEFS = require("data.items")

local M = {}
M.defs = DEFS

local floor = math.floor

function M.exists(id) return DEFS[id] ~= nil end

function M.def(id)
	local d = DEFS[id]
	if not d then error("unknown item id: " .. tostring(id), 2) end
	return d
end

function M.weight_of(id, n) return M.def(id).w * n end
function M.value_of(id, n) return M.def(id).value * n end
function M.cat(id) return M.def(id).cat end

-- sorted array of every item id (deterministic order for iteration)
local ALL
function M.all_ids()
	if not ALL then ALL = U.keys(DEFS) end
	return ALL
end

function M.new(cap, slots)
	return { items = {}, w = 0, s = 0, cap = cap, slots = slots }
end

local function stacks_for(id, n)
	if n <= 0 then return 0 end
	local st = DEFS[id].stack
	return floor((n + st - 1) / st)
end

local function check_int(n, what)
	if type(n) ~= "number" or n ~= n or n < 0 or n ~= floor(n) then
		error(string.format("%s must be a non-negative integer (got %s)", what or "count", U.fmt_num(n == n and n or 0)), 3)
	end
end

function M.count(c, id) return c.items[id] or 0 end
function M.weight(c) return c.w end

function M.total_count(c)
	local n = 0
	for _, v in pairs(c.items) do n = n + v end -- order-free
	return n
end

function M.is_empty(c) return next(c.items) == nil end

function M.free_g(c)
	if not c.cap then return 1e12 end
	return c.cap - c.w
end

-- how many of `id` could still be added right now
function M.can_add(c, id)
	local d = M.def(id)
	local room = 1e12
	if c.cap then
		room = floor((c.cap - c.w) / d.w)
		if room < 0 then room = 0 end
	end
	if c.slots then
		local have = c.items[id] or 0
		local free_slots = c.slots - c.s
		local fit = (stacks_for(id, have) + free_slots) * d.stack - have
		if fit < 0 then fit = 0 end
		if fit < room then room = fit end
	end
	return room
end

-- add up to n (partial when it does not fit); returns how many were actually added
function M.add(c, id, n)
	check_int(n, "add count")
	if n == 0 then return 0 end
	local fit = M.can_add(c, id)
	if fit < n then n = fit end
	if n <= 0 then return 0 end
	local have = c.items[id] or 0
	c.items[id] = have + n
	c.w = c.w + DEFS[id].w * n
	c.s = c.s + stacks_for(id, have + n) - stacks_for(id, have)
	return n
end

-- remove up to n; returns how many were actually removed
function M.remove(c, id, n)
	check_int(n, "remove count")
	local have = c.items[id] or 0
	if n > have then n = have end
	if n <= 0 then return 0 end
	local left = have - n
	c.items[id] = (left > 0) and left or nil
	c.w = c.w - DEFS[id].w * n
	c.s = c.s + stacks_for(id, left) - stacks_for(id, have)
	return n
end

-- move up to n from src to dst. Atomic: removes exactly what dst accepted, so nothing is
-- created or lost. Returns the number moved.
function M.transfer(src, dst, id, n)
	check_int(n, "transfer count")
	local have = src.items[id] or 0
	if n > have then n = have end
	if n <= 0 then return 0 end
	local fit = M.can_add(dst, id)
	if fit < n then n = fit end
	if n <= 0 then return 0 end
	M.remove(src, id, n)
	M.add(dst, id, n)
	return n
end

-- sorted [{id=, n=}] snapshot
function M.list(c)
	local out = {}
	for _, id in ipairs(U.keys(c.items)) do out[#out + 1] = { id = id, n = c.items[id] } end
	return out
end

function M.value(c)
	local v = 0
	for id, n in pairs(c.items) do v = v + DEFS[id].value * n end -- order-free (integer sums)
	return v
end

-- count of items of a category
function M.count_cat(c, cat)
	local n = 0
	for id, k in pairs(c.items) do if DEFS[id].cat == cat then n = n + k end end -- order-free
	return n
end

-- first id (sorted order) in the container satisfying pred(id, def) -> id or nil
function M.find(c, pred)
	for _, id in ipairs(U.keys(c.items)) do
		if pred(id, DEFS[id]) then return id end
	end
	return nil
end

-- add every item of a plain { id = n } map; returns the map of what was actually added
function M.add_map(c, map)
	local added = {}
	for _, id in ipairs(U.keys(map)) do
		local k = M.add(c, id, map[id])
		if k > 0 then added[id] = k end
	end
	return added
end

-- do all of `need` ({id=n}) exist in the container?
function M.has_all(c, need)
	for id, n in pairs(need) do if (c.items[id] or 0) < n then return false end end -- order-free
	return true
end

-- remove all of `need` or nothing (returns true on success)
function M.take_all(c, need)
	if not M.has_all(c, need) then return false end
	for _, id in ipairs(U.keys(need)) do M.remove(c, id, need[id]) end
	return true
end

-- Recompute weight/stacks from scratch and verify every invariant. Returns ok, err.
function M.check(c)
	local w, s = 0, 0
	for id, n in pairs(c.items) do -- order-free
		local d = DEFS[id]
		if not d then return false, "unknown item " .. tostring(id) end
		if type(n) ~= "number" or n ~= n or n <= 0 or n ~= floor(n) then
			return false, "bad count for " .. id
		end
		w = w + d.w * n
		s = s + stacks_for(id, n)
	end
	if w ~= c.w then return false, string.format("weight cache %d != %d", c.w, w) end
	if s ~= c.s then return false, string.format("stack cache %d != %d", c.s, s) end
	if c.cap and w > c.cap then return false, "over weight cap" end
	if c.slots and s > c.slots then return false, "over slot cap" end
	return true
end

-- rebuild the caches after a deserialize (counts are authoritative)
function M.rebuild(c)
	local w, s = 0, 0
	for id, n in pairs(c.items) do -- order-free
		w = w + DEFS[id].w * n
		s = s + stacks_for(id, n)
	end
	c.w, c.s = w, s
	return c
end

return M
