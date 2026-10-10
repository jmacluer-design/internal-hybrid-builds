-- stockpile.lua : storage zones with item filters and priorities.
-- A zone is plain data: { id, name, pos, tiles, prio (1..5, higher fills first), main (bool),
--                         filter = { cats = {cat=true}|nil (nil = every category), items = {id=true}, deny = {id=true} },
--                         items = <container> }
local U = require("sim.util")
local TUNING = require("data.tuning")
local items = require("sim.items")

local M = {}

M.G_PER_TILE = 20000 -- default capacity per tile

function M.new(id, name, pos, tiles, prio, filter, cap_extra)
	return {
		id = id, name = name, pos = U.pos_copy(pos), tiles = tiles, prio = prio or 3, main = false,
		filter = filter or {},
		items = items.new(tiles * M.G_PER_TILE + (cap_extra or 0)),
	}
end

function M.accepts(zone, item_id)
	local f = zone.filter
	if f.deny and f.deny[item_id] then return false end
	if f.items and f.items[item_id] then return true end
	if not f.cats then return true end
	return f.cats[items.cat(item_id)] == true
end

function M.free_g(zone) return items.free_g(zone.items) end

-- recompute caps: the main zone also gets the storage of every finished crate
function M.set_cap(zone, tiles, extra)
	zone.tiles = tiles
	zone.items.cap = tiles * M.G_PER_TILE + (extra or 0)
end

-- best zone to put `item_id` into: accepted, has room for at least one, highest prio, then nearest, then id
function M.find_dest(zones, item_id, from_pos)
	local best, bkey
	local d = items.def(item_id)
	for i = 1, #zones do
		local z = zones[i]
		if M.accepts(z, item_id) and items.free_g(z.items) >= d.w then
			local dist = from_pos and U.dist(from_pos, z.pos) or 0
			-- lower key wins: higher prio first, then nearer
			local key = (6 - z.prio) * 1e7 + dist
			if not bkey or key < bkey or (key == bkey and z.id < best.id) then best, bkey = z, key end
		end
	end
	return best
end

-- zone holding `item_id` closest to from_pos (ties by id); returns zone, count
function M.find_source(zones, item_id, from_pos)
	local best, bd, bn
	for i = 1, #zones do
		local z = zones[i]
		local n = z.items.items[item_id]
		if n and n > 0 then
			local dist = from_pos and U.dist(from_pos, z.pos) or 0
			if not bd or dist < bd or (dist == bd and z.id < best.id) then best, bd, bn = z, dist, n end
		end
	end
	return best, bn
end

function M.total(zones, item_id)
	local n = 0
	for i = 1, #zones do n = n + (zones[i].items.items[item_id] or 0) end
	return n
end

-- all zones' contents merged: { id = n }
function M.totals(zones)
	local t = {}
	for i = 1, #zones do
		for id, n in pairs(zones[i].items.items) do t[id] = (t[id] or 0) + n end -- order-free (integer sums)
	end
	return t
end

function M.cat_total(zones, cat)
	local n = 0
	for i = 1, #zones do n = n + items.count_cat(zones[i].items, cat) end
	return n
end

function M.wealth(zones)
	local v = 0
	for i = 1, #zones do v = v + items.value(zones[i].items) end
	return v
end

-- first food/drink item satisfying pred across zones (sorted ids, zones in array order)
function M.find_item(zones, pred, from_pos)
	local best_id, best_zone, best_score
	for i = 1, #zones do
		local z = zones[i]
		for _, id in ipairs(U.keys(z.items.items)) do
			local d = items.defs[id]
			local score = pred(id, d)
			if score and (not best_score or score > best_score) then
				best_id, best_zone, best_score = id, z, score
			end
		end
	end
	return best_id, best_zone
end

return M
