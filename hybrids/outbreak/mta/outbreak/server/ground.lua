-- server/ground.lua : ground heights for a server that has no collision world. MTA's server cannot ask where the ground is (getGroundPosition and processLineOfSight are
-- client-only), but it creates the peds and objects, and a ped created at the wrong height falls through the map or drops from the sky. So the owner's client samples the
-- ground under everything it can see (client/ground.lua, outbreak:ground) and this module keeps a coarse height map (16 m cells) for new spawns, and re-seats the entities that
-- were created before the ground was known. Until a sample exists the configured origin height is used (the base is meant to be flat).
-- Written here; nothing borrowed.
local ctx = require("server.ctx")
local U = require("shared.util")

local G = { cells = {}, tracked = {}, stats = { samples = 0, reseated = 0, rejected = 0 } }
local CELL = 16.0
local floor, abs = math.floor, math.abs

local function key(cx, cy) return string.format("%d:%d", cx, cy) end

function G.sample(x, y, z)
	G.cells[key(floor(x / CELL), floor(y / CELL))] = { x = x, y = y, z = z }
	G.stats.samples = G.stats.samples + 1
end

-- best known ground height at (x, y): the nearest sample within about one cell, else the origin height
function G.z_at(x, y)
	local cx, cy = floor(x / CELL), floor(y / CELL)
	local best, bd
	for dx = -1, 1 do
		for dy = -1, 1 do
			local s = G.cells[key(cx + dx, cy + dy)]
			if s then
				local d = (s.x - x) ^ 2 + (s.y - y) ^ 2
				if not bd or d < bd then best, bd = s, d end
			end
		end
	end
	if best then return best.z, true end
	return ctx.origin.z, false
end

-- entities created by this resource whose height may need correcting once the client has seen the ground; `off` = height of the element origin above the ground
function G.track(el, off) G.tracked[el] = { off = off or 0.0 } end
function G.untrack(el) G.tracked[el] = nil end

local LIMIT = 6000.0
local function sane(v, lo, hi) return U.finite(v) and v >= lo and v <= hi end

-- samples from the client: { { e = element | nil, x, y, z (ground), b (origin height above ground, for e) }, ... }
function G.on_samples(list)
	if type(list) ~= "table" then return 0 end
	local n = 0
	for i = 1, math.min(#list, 24) do
		local s = list[i]
		if type(s) == "table" and sane(s.x, -LIMIT + ctx.origin.x, LIMIT + ctx.origin.x) and sane(s.y, -LIMIT + ctx.origin.y, LIMIT + ctx.origin.y) and sane(s.z, -100.0, 1500.0) then
			local e = s.e
			if e == nil then
				G.sample(s.x, s.y, s.z); n = n + 1
			elseif isElement(e) and G.tracked[e] then
				G.sample(s.x, s.y, s.z); n = n + 1
				local b = (type(s.b) == "number" and sane(s.b, 0.0, 20.0)) and s.b or G.tracked[e].off
				G.tracked[e].off = b
				local ex, ey, ez = getElementPosition(e)
				if abs(ex - s.x) < 8.0 and abs(ey - s.y) < 8.0 and abs(ez - (s.z + b)) > 0.6 then
					setElementPosition(e, ex, ey, s.z + b)
					G.stats.reseated = G.stats.reseated + 1
				end
			else
				G.stats.rejected = G.stats.rejected + 1 -- an element that is not ours (or gone): ignored, never acted on
			end
		else
			G.stats.rejected = G.stats.rejected + 1
		end
	end
	return n
end

ctx.on_cleanup("ground", function() G.tracked = {} end)
return G
