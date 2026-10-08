-- Rides the SkateGM park parts with the real engine: each part is placed on
-- clear flat ground in front of the skater, who is pushed straight into it.
--   luajit parts.lua <cx> <cy> <cz> <spots file> <out> [part ids...]
-- SK8_DLL, SK8_DATA, SK8_MAP, SK8_PUSH (m/s, default 6), SK8_TICKS (default 240)
local cx, cy, cz = tonumber(arg[1]), tonumber(arg[2]), tonumber(arg[3])
local spotfile, outname = arg[4], arg[5] or "parts_out.txt"
local only = {}
for i = 6, #arg do only[arg[i]] = true end
local DLL = os.getenv("SK8_DLL") or "gmcl_skategm_win64.dll"
local DATA = os.getenv("SK8_DATA") or (os.getenv("LOCALAPPDATA") or ".") .. "/SkateGM/data/assets"
local MAP = os.getenv("SK8_MAP") or "tl_skatepark.bsp"
local out = assert(io.open(outname, "w"))
local function log(...) local s = string.format(...) out:write(s, "\n") out:flush() print(s) end
local function wait(sec) local t = os.clock() + sec while os.clock() < t do end end

dofile("../tests/lua/gmock.lua")
SERVER = true
dofile("../addon/skategm/lua/skategm_parts/sh_parts.lua")
local PARTS = SKATEGM_PARTS
for f in io.popen('dir /b "..\\addon\\skategm\\lua\\skategm_parts\\parts\\*.lua"'):lines() do
	dofile("../addon/skategm/lua/skategm_parts/parts/" .. f)
end

if os.getenv("SK8_VARIANTS") then dofile(os.getenv("SK8_VARIANTS")) end
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
log("loaded: %s in %d s", tostring(p.status), os.time() - t0)
skategm.Activate(cx, cy, cz, 0)
for _ = 1, 30 do skategm.Step(1 / 60, false, 0, 0, 0, 0, 0, 0, 0) wait(0.05) end

local function tick()
	local before = skategm.Poll().tick or 0
	skategm.Step(1 / 60, false, 0, 0, 0, 0, 0, 0, 0)
	local w, q = os.clock() + 0.5, nil
	repeat q = skategm.Poll() until (q.tick or 0) > before or os.clock() > w
	return q
end

local function feed()
	for _, name in ipairs(skategm.Poll().needModels or {}) do
		local def = PARTS.FromEngineName(name)
		if def then skategm.DefineModel(name, { PARTS.Shape(def).flat }, 1) else skategm.DefineModel(name, {}) end
	end
end

local bone = {}
local function board(q)
	if not bone.TRUCK_FRONT then for k, nm in ipairs(skategm.Poll(true).names or {}) do bone[nm] = k end end
	local b = q.bones or {}
	local fr, r = b[bone.TRUCK_FRONT or -1], b[bone.TRUCK_BACK or -1]
	if fr and r then return (fr[1] + r[1]) / 2, (fr[2] + r[2]) / 2, (fr[3] + r[3]) / 2 end
	return q.pos[1], q.pos[2], q.pos[3]
end

-- clear flat ground: no steep face and the floor within 1 unit, 600 units ahead, 80 wide
local function clear(x, y, z, yaw)
	local dx, dy = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
	local t = skategm.CollisionNear(x + dx * 300, y + dy * 300, z, 360, 200000)
	for i = 1, #t - 8, 9 do
		local ux, uy, uz, vx, vy, vz = t[i+3]-t[i], t[i+4]-t[i+1], t[i+5]-t[i+2], t[i+6]-t[i], t[i+7]-t[i+1], t[i+8]-t[i+2]
		local nx, ny, nz = uy*vz-uz*vy, uz*vx-ux*vz, ux*vy-uy*vx
		local l = math.sqrt(nx*nx+ny*ny+nz*nz)
		if l > 1e-6 then
			for k = 0, 2 do
				local px, py, pz = t[i + k * 3], t[i + k * 3 + 1], t[i + k * 3 + 2]
				local along = (px - x) * dx + (py - y) * dy
				local side = math.abs(-(px - x) * dy + (py - y) * dx)
				if along > -40 and along < 600 and side < 80 and pz > z + 1 and pz < z + 200 then return false end
				if along > -40 and along < 600 and side < 80 and nz / l > 0.5 and math.abs(pz - z) > 1 and pz < z + 200 and pz > z - 40 then return false end
			end
		end
	end
	return true
end

local spots = {}
for line in io.lines(spotfile) do
	local x, y, z = line:match("([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+)")
	if x then
		for yaw = 0, 315, 45 do
			if #spots < tonumber(os.getenv("SK8_SPOTS") or "6") then
				local far = true
				for _, s in ipairs(spots) do if (s[1] - x) ^ 2 + (s[2] - y) ^ 2 < 400 ^ 2 then far = false end end
				if far and clear(tonumber(x), tonumber(y), tonumber(z), yaw) then spots[#spots + 1] = { tonumber(x), tonumber(y), tonumber(z), yaw } end
			end
		end
	end
end
log("clear spots: %d", #spots)

local push = tonumber(os.getenv("SK8_PUSH") or "6") / 0.0254
local ticks = tonumber(os.getenv("SK8_TICKS") or "240")
local function ride(def, s, gap)
	math.randomseed(1)
	local x, y, z, yaw = s[1], s[2], s[3], s[4]
	local dx, dy = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
	skategm.SetEntities({})
	skategm.Activate(x, y, z + 2, yaw)
	local calm = 0
	for _ = 1, 180 do
		feed()
		local q = tick()
		local v = q.vel and math.sqrt(q.vel[1] ^ 2 + q.vel[2] ^ 2 + q.vel[3] ^ 2) * 0.0254 or 0
		if (q.state or ""):find("PhysicsGround") and v < 0.2 then calm = calm + 1 else calm = 0 end
		if calm >= 20 then break end
	end
	local bx, by = board(skategm.Poll())
	local list = {}
	if def then
		local sh = PARTS.Shape(def)
		local d = gap - sh.mins.x
		list[1] = { PARTS.EngineName(def.id), bx + dx * d, by + dy * d, z, 0, yaw, 0 }
	end
	skategm.SetEntities(list)
	local want = def and 1 or 0
	local w0 = os.clock()
	local seen = false
	while os.clock() - w0 < 20 do
		feed()
		tick()
		wait(0.05)
		local c = skategm.Poll().collision or ""
		local n = tonumber(c:match("(%d+) entities"))
		if def then
			local sh = PARTS.Shape(def)
			local d = gap - sh.mins.x
			local reach = math.sqrt(((sh.maxs.x - sh.mins.x) / 2) ^ 2 + ((sh.maxs.y - sh.mins.y) / 2) ^ 2 + (sh.maxs.z / 2) ^ 2) + 4
			local t, tags = skategm.CollisionNear(bx + dx * d, by + dy * d, z + sh.maxs.z * 0.5, reach, 20000)
			for k = 1, #(tags or {}) do if tags[k] == 3 then seen = true break end end
		else
			seen = true
		end
		if seen and os.clock() - w0 > 1.5 then break end
	end
	if not seen then return { missing = true, maxh = 0, seq = "part never appeared", endAlong = 0, worst = 0, back = false, bail = false } end
	DIAG = "part in the collision: " .. tostring(seen)
	x, y = bx, by
	skategm.Push(dx * push, dy * push, 0)
	local maxh, states, bail, seq, minAhead = 0, {}, false, {}, nil
	local last, lastAlong, back = nil, 0, false
	local speeds = {}
	for i = 1, ticks do
		feed()
		local q = tick()
		local bx, by, bz = board(q)
		local along = (bx - x) * dx + (by - y) * dy
		maxh = math.max(maxh, bz - z)
		if along < lastAlong - 0.5 and i > 20 then back = true end
		lastAlong = along
		local st = q.state or "?"
		if st ~= last then seq[#seq + 1] = st last = st end
		if st:find("Wipeout") or st:find("Bail") then bail = true end
		if i > 1 and q.vel then speeds[#speeds + 1] = { along, math.sqrt(q.vel[1] ^ 2 + q.vel[2] ^ 2 + q.vel[3] ^ 2) * 0.0254 } end
	end
	local worst = 0
	for k = 4, #speeds do
		local drop = speeds[k - 3][2] - speeds[k][2]
		if drop > worst then worst = drop end
	end
	return { maxh = maxh, bail = bail, seq = table.concat(seq, " > "), back = back, worst = worst, endAlong = lastAlong }
end

-- SK8_LAYOUTS=1: parts snapped together with the park editor's own snapping
-- (PARTS.SnapPlacement), ridden across their seams. Each layout is built in
-- its own frame (the rider at 0, 0 heading +x) and turned onto the spot.
local function Chain(first, firstX, rest)
	local placed = { { id = first, pos = Vector(firstX - PARTS.Shape(PARTS.Get(first)).mins.x, 0, 0), yaw = 0 } }
	-- (each next part an id, or { id, yaw } to drop it turned - a quarter pipe
	-- turned around to meet another back to back)
	for _, item in ipairs(rest) do
		local id, gyaw = type(item) == "table" and item[1] or item, type(item) == "table" and item[2] or 0
		local prev = placed[#placed]
		local def, pdef = PARTS.Get(id), PARTS.Get(prev.id)
		local half = math.max(math.abs(PARTS.Shape(def).mins.x), PARTS.Shape(def).maxs.x)
		local guess = prev.pos + Vector(PARTS.Shape(pdef).maxs.x + half + 10, 0, 0)
		local pos, yaw = PARTS.SnapPlacement(def, guess, gyaw, pdef, prev.pos, prev.yaw)
		placed[#placed + 1] = { id = id, pos = pos or guess, yaw = yaw or gyaw, snapped = pos ~= nil }
	end
	return placed
end
local LAYOUTS = {
	{ name = "bank 48 up onto a deck 48", parts = Chain("bank_48", 120, { "deck_48x128" }) },
	{ name = "bank 24 onto 3 decks 24 (2 seams)", parts = Chain("bank_24", 120, { "deck_24x128", "deck_24x128", "deck_24x128" }) },
	{ name = "2 quarter pipes snapped back to back", parts = Chain("quarter_pipe", 120, { { "quarter_pipe", 180 } }) },
	{ name = "half pipe, from its flat bottom", parts = { { id = "half_pipe_96_128", pos = Vector(0, 0, 0), yaw = 0 } } },
}

local function ride_layout(layout, s)
	local x, y, z, yaw = s[1], s[2], s[3], s[4]
	skategm.SetEntities({})
	skategm.Activate(x, y, z + 2, yaw)
	local calm = 0
	for _ = 1, 180 do
		feed()
		local q = tick()
		local v = q.vel and math.sqrt(q.vel[1] ^ 2 + q.vel[2] ^ 2 + q.vel[3] ^ 2) * 0.0254 or 0
		if (q.state or ""):find("PhysicsGround") and v < 0.2 then calm = calm + 1 else calm = 0 end
		if calm >= 20 then break end
	end
	local bx, by = board(skategm.Poll())
	local list = {}
	for _, p in ipairs(layout.parts) do
		local w = PARTS.Turn(p.pos, yaw)
		list[#list + 1] = { PARTS.EngineName(p.id), bx + w.x, by + w.y, z, 0, (yaw + p.yaw) % 360, 0 }
	end
	skategm.SetEntities(list)
	local w0 = os.clock()
	while os.clock() - w0 < 20 do
		feed()
		tick()
		wait(0.05)
		local c = skategm.Poll().collision or ""
		if tonumber(c:match("(%d+) entities")) == #list and not c:find("[1-9]%d* shapes pending") and os.clock() - w0 > 1.5 then break end
	end
	local dx, dy = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
	skategm.Push(dx * push, dy * push, 0)
	local maxh, bail, seq, last, worst, speeds, lastAlong = 0, false, {}, nil, 0, {}, 0
	for i = 1, ticks do
		feed()
		local q = tick()
		local qx, qy, qz = board(q)
		lastAlong = (qx - bx) * dx + (qy - by) * dy
		maxh = math.max(maxh, qz - z)
		local st = q.state or "?"
		if st ~= last then seq[#seq + 1] = st last = st end
		if st:find("Wipeout") then bail = true end
		if q.vel then speeds[#speeds + 1] = math.sqrt(q.vel[1] ^ 2 + q.vel[2] ^ 2 + q.vel[3] ^ 2) * 0.0254 end
	end
	for k = 4, #speeds do worst = math.max(worst, speeds[k - 3] - speeds[k]) end
	return { maxh = maxh, bail = bail, worst = worst, endAlong = lastAlong, seq = table.concat(seq, " > ") }
end

if os.getenv("SK8_LAYOUTS") then
	for _, l in ipairs(LAYOUTS) do
		local snapped = 0
		for _, p in ipairs(l.parts) do if p.snapped then snapped = snapped + 1 end end
		log("layout %s: %d parts, %d snapped", l.name, #l.parts, snapped)
	end
	for si, s in ipairs(spots) do
		for _, l in ipairs(LAYOUTS) do
			local r = ride_layout(l, s)
			log("spot %d %-38s max height %5.1f, rolled %5.0f, sharpest 3-tick speed loss %.2f m/s, bail %-5s | %s", si, l.name, r.maxh, r.endAlong, r.worst, tostring(r.bail), r.seq)
		end
	end
	out:close()
	return
end

local ids = {}
for _, def in ipairs(PARTS.Ordered()) do if not next(only) or only[def.id] then ids[#ids + 1] = def end end
for si, s in ipairs(spots) do
	local base = ride(nil, s, 0)
	log("spot %d (%.0f %.0f %.0f yaw %d) no part: max height %.1f, rolled %.0f, sharpest 3-tick speed loss %.2f m/s, bail %s | %s", si, s[1], s[2], s[3], s[4], base.maxh, base.endAlong, base.worst, tostring(base.bail), base.seq)
	for _, def in ipairs(ids) do
		local r = ride(def, s, 120)
		if r.missing then log("  %-13s MISSING", def.id) end
		log("  %-13s max height %5.1f, came back %-5s, rolled %5.0f, sharpest 3-tick speed loss %.2f m/s, bail %-5s | %s", def.id, r.maxh, tostring(r.back), r.endAlong, r.worst, tostring(r.bail), r.seq)
	end
end
out:close()
