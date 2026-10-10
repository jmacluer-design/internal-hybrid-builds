-- shared/placement.lua : client-side blueprint placement validity (grid snap + the same rules as sim/blueprints.lua `why_not`), so ghosts tint instantly
-- without a server round trip. The sim still has the final word (order_result). The browser UI has an identical JS twin (ui/js/build.js
-- OB.build.validate); fivem/tests/placement_test.lua proves this Lua copy agrees with the real sim on many random placements.
local M = {}

-- snap a sim coordinate to the placement grid
function M.snap(v, grid) return math.floor(v / grid + 0.5) * grid end

local function keys(t)
	local out = {}
	for k in pairs(t) do out[#out + 1] = k end -- sorted below
	table.sort(out)
	return out
end

-- buildings = list of { bp, x, y, state }  (UI view model); catalog = shared/view.lua catalog (blueprints + tuning.base)
-- returns ok, reason ("ok" | "unknown_blueprint" | "too_far" | "prereq:<bp>" | "max_reached" | "blocked")
function M.validate(buildings, catalog, bp, x, y)
	local d = catalog.blueprints[bp]
	if not d then return false, "unknown_blueprint" end
	local base = catalog.tuning.base
	local dx, dy = x - base.x, y - base.y
	if math.sqrt(dx * dx + dy * dy) > base.build_radius then return false, "too_far" end
	for _, need in ipairs(keys(d.needs or {})) do
		local have = 0
		for i = 1, #buildings do if buildings[i].bp == need and buildings[i].state == "built" then have = have + 1 end end
		if have < d.needs[need] then return false, "prereq:" .. need end
	end
	if d.max and d.max > 0 then
		local n = 0
		for i = 1, #buildings do if buildings[i].bp == bp then n = n + 1 end end
		if n >= d.max then return false, "max_reached" end
	end
	for i = 1, #buildings do
		local ex, ey = buildings[i].x - x, buildings[i].y - y
		if math.sqrt(ex * ex + ey * ey) < base.min_spacing then return false, "blocked" end
	end
	return true, "ok"
end

return M
