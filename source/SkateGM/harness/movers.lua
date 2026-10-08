-- The moving collision layer with the real engine (skategm.SetMovers): player
-- boxes placed straight into the engine every tick, no collision rebuild.
--   luajit movers.lua <cx> <cy> <cz> <spots file> <out>
-- SK8_DLL, SK8_DATA, SK8_MAP
local cx, cy, cz = tonumber(arg[1]), tonumber(arg[2]), tonumber(arg[3])
local spotfile, outname = arg[4], arg[5] or "movers_out.txt"
local DLL = os.getenv("SK8_DLL") or "gmcl_skategm_win64.dll"
local DATA = os.getenv("SK8_DATA") or (os.getenv("LOCALAPPDATA") or ".") .. "/SkateGM/data/assets"
local MAP = os.getenv("SK8_MAP")
local out = assert(io.open(outname, "w"))
local function log(...) local s = string.format(...) out:write(s, "\n") out:flush() print(s) end
local function wait(sec) local t = os.clock() + sec while os.clock() < t do end end

local open = assert(package.loadlib(DLL, "gmod13_open")) open()
skategm.SetTuning("SK8_CURVE_CAP", "16")
skategm.SetTuning("SK8_TAPER", "linear")
skategm.SetTuning("SK8_OFF", "crossings,bigterrain,shortsteps,slopededges")
skategm.SetTuning("SK8_REGION_HALF", "4800")
local f = assert(io.open(MAP, "rb")) local bytes = f:read("*a") f:close()
skategm.Load(DATA, cx, cy, cz, 0, bytes, 1, 1, 1, 8)
bytes = nil collectgarbage()
local p, t0 = nil, os.time()
repeat wait(0.5) p = skategm.Poll() until p.status ~= "loading" or os.time() - t0 > 400
log("loaded: %s in %d s; SetMovers %s", tostring(p.status), os.time() - t0, tostring(skategm.SetMovers ~= nil))
skategm.Activate(cx, cy, cz, 0)

-- the add-on's player box (PlayerHull in skategm_cl.lua): 28 x 28 x 64, feet at the origin
local function PlayerHull()
	local w, h = 14, 64
	local c = {}
	local function q(a, b, cc, d)
		for _, v in ipairs({ a, b, cc, a, cc, d }) do c[#c + 1] = v[1] c[#c + 1] = v[2] c[#c + 1] = v[3] end
	end
	q({ -w, -w, h }, { w, -w, h }, { w, w, h }, { -w, w, h })
	q({ -w, -w, 0 }, { -w, w, 0 }, { w, w, 0 }, { w, -w, 0 })
	q({ w, -w, 0 }, { w, w, 0 }, { w, w, h }, { w, -w, h })
	q({ -w, -w, 0 }, { -w, -w, h }, { -w, w, h }, { -w, w, 0 })
	q({ -w, w, 0 }, { -w, w, h }, { w, w, h }, { w, w, 0 })
	q({ -w, -w, 0 }, { w, -w, 0 }, { w, -w, h }, { -w, -w, h })
	return { c }
end
skategm.DefineModel("skategm/player", PlayerHull())
for _ = 1, 60 do skategm.Step(1 / 60, false, 0, 0, 0, 0, 0, 0, 0) wait(0.02) end

local function tick()
	local before = skategm.Poll().tick or 0
	local t = os.clock()
	skategm.Step(1 / 60, false, 0, 0, 0, 0, 0, 0, 0)
	local w, q = os.clock() + 0.5, nil
	repeat q = skategm.Poll() until (q.tick or 0) > before or os.clock() > w
	return q, (os.clock() - t) * 1000
end

local bone = {}
local function board(q)
	if not bone.TRUCK_FRONT then for k, nm in ipairs(skategm.Poll(true).names or {}) do bone[nm] = k end end
	local b = q.bones or {}
	local fr, r = b[bone.TRUCK_FRONT or -1], b[bone.TRUCK_BACK or -1]
	if fr and r then return (fr[1] + r[1]) / 2, (fr[2] + r[2]) / 2, (fr[3] + r[3]) / 2 end
	return q.pos[1], q.pos[2], q.pos[3]
end

-- the biggest brush model the module can place that's 32 to 200 across
local door
if os.getenv("SK8_BRUSH") and skategm.HasShape then
	local best = 0
	for n = 1, 400 do
		local ok, a, b, c, x, y, z = skategm.HasShape("*" .. n)
		if ok then
			local w, h = math.max(x - a, y - b), z - c
			if w <= 200 and w >= 32 and h >= 24 and w * h > best then best, door = w * h, { name = "*" .. n, lo = { a, b, c }, hi = { x, y, z } } end
		end
	end
	log("brush model: %s", door and string.format("%s %.0f x %.0f x %.0f", door.name, door.hi[1] - door.lo[1], door.hi[2] - door.lo[2], door.hi[3] - door.lo[3]) or "none")
end

local spots = {}
for line in io.lines(spotfile) do
	local x, y, z, yaw = line:match("([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+)")
	if x then spots[#spots + 1] = { tonumber(x), tonumber(y), tonumber(z), tonumber(yaw) } end
end

-- a ride: boxes(i, bx, by, z, dx, dy) -> list of movers for tick i
local function ride(s, label, boxes, ticks)
	skategm.SetMovers({})
	skategm.Activate(s[1], s[2], s[3] + 2, s[4])
	local calm = 0
	for _ = 1, 180 do
		local q = tick()
		local v = q.vel and math.sqrt(q.vel[1] ^ 2 + q.vel[2] ^ 2 + q.vel[3] ^ 2) * 0.0254 or 0
		if (q.state or ""):find("PhysicsGround") and v < 0.2 then calm = calm + 1 else calm = 0 end
		if calm >= 20 then break end
	end
	local q0 = skategm.Poll()
	local bx, by, bz = board(q0)
	local dx, dy = math.cos(math.rad(s[4])), math.sin(math.rad(s[4]))
	local floor = bz - 3.4
	skategm.Push(dx * 6 / 0.0254, dy * 6 / 0.0254, 0)
	local seq, last, maxStep, sumStep, n, minAhead = {}, nil, 0, 0, 0, 1e9
	local stopped, traveled = false, 0
	local q = q0
	for i = 1, ticks do
		local list = boxes and boxes(i, bx, by, floor, dx, dy) or {}
		local sent = skategm.SetMovers(list)
		local ms
		q, ms = tick()
		maxStep, sumStep, n = math.max(maxStep, ms), sumStep + ms, n + 1
		local x, y = board(q)
		traveled = (x - bx) * dx + (y - by) * dy
		local st = q.state or "?"
		if st ~= last then seq[#seq + 1] = st last = st end
	end
	local sp = q.vel and math.sqrt(q.vel[1] ^ 2 + q.vel[2] ^ 2) * 0.0254 or 0
	log("%-34s rolled %5.0f units, end speed %4.1f m/s, moving layer %s triangles, tick %.2f ms avg / %.2f max | %s",
		label, traveled, sp, tostring(q.moving), sumStep / n, maxStep, table.concat(seq, " > "))
end

for si = 1, math.min(#spots, tonumber(os.getenv("SK8_SPOTS") or "4")) do
	local s = spots[si]
	log("spot %d (%.0f %.0f %.0f yaw %.0f)", si, s[1], s[2], s[3], s[4])
	ride(s, "  no box", nil, 120)
	ride(s, "  a box parked 100 ahead", function(i, bx, by, z, dx, dy) return { { "skategm/player", bx + dx * 100, by + dy * 100, z, 0, 0, 0 } } end, 120)
	-- crossing the path: from 150 to the side to 150 the other side over 2 s,
	-- at the spot the board reaches at tick ~38 (100 units at 6 m/s)
	ride(s, "  a box crossing in time", function(i, bx, by, z, dx, dy)
		local side = -150 + i * 5
		return { { "skategm/player", bx + dx * 100 - dy * side, by + dy * 100 + dx * side, z, 0, 0, 0 } }
	end, 120)
	ride(s, "  a box crossing too late", function(i, bx, by, z, dx, dy)
		local side = -600 + i * 5
		return { { "skategm/player", bx + dx * 100 - dy * side, by + dy * 100 + dx * side, z, 0, 0, 0 } }
	end, 120)
	-- (SK8_BRUSH=1: a map brush model, e.g. a door, in the moving layer)
	if door then
		local d = door
		-- (turned so its long side is across the board's line)
		local long = (d.hi[2] - d.lo[2]) >= (d.hi[1] - d.lo[1])
		local function at(bx, by, z, dx, dy, lift)
			local yaw = math.deg(math.atan2(dy, dx)) + (long and 0 or 90)
			local c, sn = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
			local cxm, cym = (d.lo[1] + d.hi[1]) / 2, (d.lo[2] + d.hi[2]) / 2
			local rx, ry = cxm * c - cym * sn, cxm * sn + cym * c
			return { { d.name, bx + dx * 100 - rx, by + dy * 100 - ry, z - d.lo[3] + lift, 0, yaw, 0 } }
		end
		ride(s, "  brush " .. d.name .. " parked 100 ahead", function(i, bx, by, z, dx, dy) return at(bx, by, z, dx, dy, 0) end, 120)
		ride(s, "  brush rising out of the way in time", function(i, bx, by, z, dx, dy) return at(bx, by, z, dx, dy, math.min(1, i / 20) * (d.hi[3] - d.lo[3] + 10)) end, 120)
		ride(s, "  brush rising too late", function(i, bx, by, z, dx, dy) return at(bx, by, z, dx, dy, i > 90 and (d.hi[3] - d.lo[3] + 10) or 0) end, 120)
	end
	ride(s, "  8 boxes moving nearby (not in the way)", function(i, bx, by, z, dx, dy)
		local list = {}
		for k = 1, 8 do
			local a = k / 8 * math.pi * 2 + i * 0.05
			list[k] = { "skategm/player", bx - dx * 300 + math.cos(a) * 120, by - dy * 300 + math.sin(a) * 120, z, 0, 0, 0 }
		end
		return list
	end, 120)
end
out:close()
