-- loot.lua : rolls item bundles from weighted tables (data/loot.lua).
-- Rare entries get a weight bonus with district danger; luck adds extra rolls. All randomness
-- comes from the rng passed in, so a (seed, table, danger) triple is reproducible.
local U = require("sim.util")
local DATA = require("data.loot")
local DISTRICTS = require("data.districts")
local items = require("sim.items")

local M = {}
M.tables = DATA.tables
M.DANGER_RARE_BONUS = 0.28 -- per danger level above 1: rare weight multiplier = 1 + bonus * (danger - 1)

function M.table_for_container(ctype) return DATA.container_types[ctype] end

function M.table_ids() return U.keys(DATA.tables) end

-- roll a bundle. opts = { danger = 1..5, luck = 0..1 (extra-roll chance), rolls = override count, mult = quantity mult }
-- returns { item_id = count }
function M.roll(rng, table_id, opts)
	opts = opts or {}
	local t = DATA.tables[table_id]
	if not t then error("unknown loot table: " .. tostring(table_id), 2) end
	local danger = opts.danger or 1
	local rare_mul = 1 + M.DANGER_RARE_BONUS * (danger - 1)
	local entries = t.entries
	local n = opts.rolls or rng:int(t.rolls[1], t.rolls[2])
	if (opts.luck or 0) > 0 and rng:chance(opts.luck) then n = n + 1 end
	local bundle = {}
	local function weight(en) return en.rare and en.w * rare_mul or en.w end
	for _ = 1, n do
		local en = rng:weighted(entries, weight)
		if en then
			local q = rng:int(en.min, en.max)
			if opts.mult and opts.mult ~= 1 then q = U.max(1, U.round(q * opts.mult)) end
			bundle[en.item] = (bundle[en.item] or 0) + q
		end
	end
	return bundle
end

-- the district whose centre is nearest to pos (ties by id); returns district, distance
function M.nearest_district(pos)
	local best, bd
	for _, id in ipairs(U.keys(DISTRICTS)) do
		local d = DISTRICTS[id]
		local dist = U.dist2(pos.x, pos.y, d.x, d.y)
		if not bd or dist < bd then best, bd = d, dist end
	end
	return best, bd
end

-- sanity: every item a table can drop exists
function M.validate()
	for tid, t in pairs(DATA.tables) do -- order-free
		for i = 1, #t.entries do
			if not items.exists(t.entries[i].item) then return false, tid .. ": unknown item " .. t.entries[i].item end
			if t.entries[i].min > t.entries[i].max then return false, tid .. ": min > max" end
		end
	end
	for ct, tid in pairs(DATA.container_types) do -- order-free
		if not DATA.tables[tid] then return false, "container type " .. ct .. " -> missing table " .. tid end
	end
	return true
end

return M
