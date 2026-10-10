-- shared/placement.lua (Lua twin of ui/js/build.js) against the REAL sim rule blueprints.why_not, on many random placements.
local T, H = ...
local Placement = require("shared.placement")
local V = require("shared.view")
local blueprints = require("sim.blueprints")
local TUNING = require("data.tuning")
local BP = require("data.blueprints")
local World = require("sim.world")

T.group("placement")

local function buildings_view(w)
	local out = {}
	for i, b in ipairs(w.s.buildings) do out[i] = { bp = b.bp, x = b.pos.x, y = b.pos.y, state = b.state } end
	return out
end

T.test("snap rounds to the grid", function()
	T.eq(Placement.snap(7.4, 2), 8); T.eq(Placement.snap(6.9, 2), 6); T.eq(Placement.snap(-1.2, 2), -2); T.eq(Placement.snap(1850.3, 4), 1852)
end)

T.test("agrees with sim blueprints.why_not on 600 random placements over several worlds", function()
	local cat = V.catalog()
	local rng = require("sim.rng").new(99)
	local ids = {}
	for id in pairs(BP) do ids[#ids + 1] = id end
	table.sort(ids)
	local checked, reasons = 0, {}
	for seed = 1, 4 do
		local w = World.new({ seed = seed, profile = "calm", colonists = 3, max_dt = 1 })
		-- grow the world a little so there are planned and built buildings
		w:tick(60 * 24 * 3)
		for _ = 1, 25 do
			local id = ids[rng:int(1, #ids)]
			local b = TUNING.base
			blueprints.place(w, id, { x = b.x + rng:int(-60, 60), y = b.y + rng:int(-60, 60), z = 0 })
		end
		local view = buildings_view(w)
		for _ = 1, 150 do
			local id = ids[rng:int(1, #ids)]
			local b = TUNING.base
			local x, y = b.x + rng:int(-230, 230), b.y + rng:int(-230, 230)
			if #w.s.buildings > 0 and rng:int(1, 3) == 1 then -- right next to an existing building: exercises the spacing rule
				local o = w.s.buildings[rng:int(1, #w.s.buildings)].pos
				x, y = o.x + rng:int(-2, 2) * 0.6, o.y + rng:int(-2, 2) * 0.6
			end
			local why = blueprints.why_not(w, id, { x = x, y = y, z = 0 })
			local ok, reason = Placement.validate(view, cat, id, x, y)
			T.eq(ok, why == nil, string.format("%s at %.1f,%.1f: sim says %s, lua says %s", id, x, y, tostring(why), tostring(reason)))
			if why then T.eq(reason, why) end
			reasons[reason] = (reasons[reason] or 0) + 1
			checked = checked + 1
		end
	end
	T.eq(checked, 600)
	T.gt(reasons.ok or 0, 10, "some placements were valid")
	T.gt(reasons.too_far or 0, 10, "some too far")
	T.gt(reasons.blocked or 0, 3, "some blocked")
	T.note("reasons: ok=%d too_far=%d blocked=%d prereq=%d max=%d", reasons.ok or 0, reasons.too_far or 0, reasons.blocked or 0,
		(function() local n = 0; for k, v in pairs(reasons) do if k:find("^prereq") then n = n + v end end return n end)(), reasons.max_reached or 0)
end)

T.test("unknown blueprint", function()
	local cat = V.catalog()
	local ok, why = Placement.validate({}, cat, "nope", 0, 0)
	T.falsy(ok); T.eq(why, "unknown_blueprint")
end)
