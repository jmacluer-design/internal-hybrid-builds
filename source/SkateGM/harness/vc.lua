-- gm_infmap_vicecity with the real engine: the map's BSP left out
-- (SK8_OFF=world), its ground (chunk models + .obj collision, from
-- vc_extract.py) handed over as one mesh per chunk, the 3 x 3 chunks around
-- the skater, as the add-on does.
--   luajit vc.lua <bsp> <chunks dir> <out> [rides]
-- SK8_DLL, SK8_DATA, SK8_PUSH (m/s, default 8), SK8_TICKS (default 600),
-- SK8_ORIENT = none | up | both (how the map's mixed-winding triangles are
-- given to the engine; its collision is one-sided)
local BSP, DIR, outname, rides = arg[1], arg[2], arg[3] or "vc_out.txt", tonumber(arg[4] or "20")
local DLL = os.getenv("SK8_DLL") or "gmcl_skategm_win64.dll"
local DATA = os.getenv("SK8_DATA") or (os.getenv("LOCALAPPDATA") or ".") .. "/SkateGM/data/assets"
local ORIENT = os.getenv("SK8_ORIENT") or "none"
local out = assert(io.open(outname, "w"))
local function log(...) local s = string.format(...) out:write(s, "\n") out:flush() print(s) end
local function wait(sec) local t = os.clock() + sec while os.clock() < t do end end
local W = 10000
local function Cell(v) return math.floor((v + W / 2) / W) end

-- the add-on's own orientation step (skategm/cl_infmap.lua IM.Orient)
local function Orient(flat, mode)
	if mode == "none" then return flat end
	local o = {}
	for i = 1, #flat - 8, 9 do
		local ax, ay, az, bx, by, bz, cx, cy, cz = flat[i], flat[i + 1], flat[i + 2], flat[i + 3], flat[i + 4], flat[i + 5], flat[i + 6], flat[i + 7], flat[i + 8]
		local ux, uy, uz, vx, vy, vz = bx - ax, by - ay, bz - az, cx - ax, cy - ay, cz - az
		local nz = ux * vy - uy * vx
		local nl = math.sqrt((uy * vz - uz * vy) ^ 2 + (uz * vx - ux * vz) ^ 2 + nz ^ 2)
		local function put(p, q, r)
			for _, v in ipairs({ p, q, r }) do o[#o + 1] = v[1] o[#o + 1] = v[2] o[#o + 1] = v[3] end
		end
		local A, B, C = { ax, ay, az }, { bx, by, bz }, { cx, cy, cz }
		if mode == "both" then
			put(A, B, C) put(A, C, B)
		elseif mode == "up" then
			if nl > 0 and math.abs(nz) / nl > 0.2 then
				if nz < 0 then put(A, C, B) else put(A, B, C) end
			else
				put(A, B, C) put(A, C, B)
			end
		end
	end
	return o
end

-- the map's own ground under a point (any winding): the highest triangle
-- below z, or nil
local raw = {}
local function Raw(x, y)
	local key = x .. "_" .. y
	if raw[key] == nil then
		local f = io.open(DIR .. "/" .. key .. ".lua", "r")
		if f then f:close() raw[key] = dofile(DIR .. "/" .. key .. ".lua") else raw[key] = false end
	end
	return raw[key] or nil
end
local function GroundBelow(px, py, pz)
	local flat = Raw(Cell(px), Cell(py))
	if not flat then return nil end
	local best
	for i = 1, #flat - 8, 9 do
		local ax, ay, bx, by, cx, cy = flat[i], flat[i + 1], flat[i + 3], flat[i + 4], flat[i + 6], flat[i + 7]
		local d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
		if math.abs(d) > 1e-6 then
			local l1 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / d
			local l2 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / d
			local l3 = 1 - l1 - l2
			if l1 >= 0 and l2 >= 0 and l3 >= 0 then
				local z = l1 * flat[i + 2] + l2 * flat[i + 5] + l3 * flat[i + 8]
				if z <= pz + 2 and (not best or z > best) then best = z end
			end
		end
	end
	return best
end

local cache = {}
local function Chunk(x, y)
	local key = x .. "_" .. y
	if cache[key] == nil then
		local f = io.open(DIR .. "/" .. key .. ".lua", "r")
		if f then f:close() cache[key] = Orient(dofile(DIR .. "/" .. key .. ".lua"), ORIENT) else cache[key] = false end
	end
	return cache[key] or nil
end

local open = assert(package.loadlib(DLL, "gmod13_open")) open()
skategm.SetTuning("SK8_CURVE_CAP", "16")
skategm.SetTuning("SK8_TAPER", "linear")
skategm.SetTuning("SK8_OFF", "crossings,bigterrain,shortsteps,slopededges,world")
local f = assert(io.open(BSP, "rb")) local bytes = f:read("*a") f:close()
skategm.Load(DATA, -14082, -17050, 619, 0, bytes, 1, 1, 1, 8)
bytes = nil collectgarbage()
local p, t0 = nil, os.time()
repeat wait(0.5) p = skategm.Poll() until p.status ~= "loading" or os.time() - t0 > 400
log("loaded: %s in %d s; orient %s", tostring(p.status), os.time() - t0, ORIENT)

local defined, placedKey = {}, nil
local function Feed(pos)
	for _, name in ipairs(skategm.Poll().needModels or {}) do
		if not defined[name] then
			defined[name] = true
			local x, y = name:match("^vc:(%-?%d+):(%-?%d+)$")
			skategm.DefineModel(name, { x and Chunk(tonumber(x), tonumber(y)) or {} }, 1)
		end
	end
	local cx, cy = Cell(pos[1]), Cell(pos[2])
	local key = cx .. "," .. cy
	if key == placedKey then return end
	placedKey = key
	local list = {}
	for dx = -1, 1 do for dy = -1, 1 do
		if Chunk(cx + dx, cy + dy) then list[#list + 1] = { string.format("vc:%d:%d", cx + dx, cy + dy), 0, 0, 0, 0, 0, 0 } end
	end end
	skategm.SetEntities(list)
end

local function tick()
	local before = skategm.Poll().tick or 0
	skategm.Step(1 / 60, false, 0, 0, 0, 0, 0, 0, 0)
	local w, q = os.clock() + 0.5, nil
	repeat q = skategm.Poll() until (q.tick or 0) > before or os.clock() > w
	return q
end

-- ride starts: big, flat, up-facing floor triangles (either winding) in the
-- chunks around the spawn
math.randomseed(11)
local starts = {}
for x = -3, 1 do for y = -4, 0 do
	local raw = io.open(DIR .. "/" .. x .. "_" .. y .. ".lua", "r")
	if raw then
		raw:close()
		local flat = dofile(DIR .. "/" .. x .. "_" .. y .. ".lua")
		for i = 1, #flat - 8, 9 do
			local ux, uy, uz = flat[i + 3] - flat[i], flat[i + 4] - flat[i + 1], flat[i + 5] - flat[i + 2]
			local vx, vy, vz = flat[i + 6] - flat[i], flat[i + 7] - flat[i + 1], flat[i + 8] - flat[i + 2]
			local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
			local area = math.sqrt(nx * nx + ny * ny + nz * nz) / 2
			if area > 40000 and math.abs(nz) / (2 * area) > 0.97 then
				starts[#starts + 1] = { (flat[i] + flat[i + 3] + flat[i + 6]) / 3, (flat[i + 1] + flat[i + 4] + flat[i + 7]) / 3, (flat[i + 2] + flat[i + 5] + flat[i + 8]) / 3, nz > 0 }
			end
		end
	end
end end
log("%d possible starts", #starts)

local push = tonumber(os.getenv("SK8_PUSH") or "8") / 0.0254
local ticks = tonumber(os.getenv("SK8_TICKS") or "600")
local totals = { rides = 0, fell = 0, bail = 0, clean = 0, badspot = 0, cells = 0, dist = 0 }
for r = 1, rides do
	local s = starts[math.random(#starts)]
	local yaw = math.random() * 360
	Feed(s)
	skategm.Activate(s[1], s[2], s[3] + 4, yaw)
	local settled = false
	for w = 1, 400 do
		Feed(skategm.Poll().pos or s)
		local q = tick()
		local c = q.collision or ""
		if not q.held and c:find("entities") and q.state and q.state:find("PhysicsGround") and w > 60 then settled = true break end
	end
	local q0 = skategm.Poll()
	local z0 = q0.pos and q0.pos[3] or s[3]
	if not settled or not q0.pos or math.abs(z0 - s[3]) > 80 then
		totals.badspot = totals.badspot + 1
		log("ride %2d: badspot (start %.0f %.0f %.0f %s, settled %s at z %.0f)", r, s[1], s[2], s[3], s[4] and "up" or "down", tostring(settled), z0)
	else
		local dx, dy = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
		skategm.Push(dx * push, dy * push, 0)
		local cells, lastCell, seq, last, bail, fell, minZ = 0, nil, {}, nil, false, false, z0
		local airAt, through
		-- (held: the engine waiting for collision - the add-on's "Waiting for
		-- collision to load..." - counted per tick and per stretch)
		local heldTicks, heldRuns, wasHeld, lastColl, builds = 0, 0, false, nil, 0
		local q, prev = q0, q0.pos
		local p0 = { q0.pos[1], q0.pos[2] }
		for i = 1, ticks do
			if q.pos then Feed(q.pos) end
			q = tick()
			if q.held then heldTicks = heldTicks + 1 if not wasHeld then heldRuns = heldRuns + 1 end end
			wasHeld = q.held and true or false
			if q.collision and q.collision ~= lastColl then builds = builds + 1 lastColl = q.collision end
			if q.pos then
				local cell = Cell(q.pos[1]) .. "," .. Cell(q.pos[2])
				if cell ~= lastCell then cells = cells + 1 lastCell = cell end
				minZ = math.min(minZ, q.pos[3])
				local st = q.state or ""
				if st:find("Air") then airAt = airAt or { q.pos[1], q.pos[2], q.pos[3] } elseif st:find("Ground") then airAt = nil end
				if q.pos[3] < z0 - 2000 then
					fell = true
					-- was there map ground under where it went airborne, that it went through?
					local g = airAt and GroundBelow(airAt[1], airAt[2], airAt[3])
					local g2 = GroundBelow(q.pos[1], q.pos[2], q.pos[3] + 1950)
					through = (g and g > q.pos[3] + 100) or (g2 and g2 > q.pos[3] + 100)
				end
			end
			local st = q.state or "?"
			if st ~= last then seq[#seq + 1] = st last = st end
			if st:find("Wipeout") then bail = true end
			if fell then break end
		end
		local dist = q.pos and math.sqrt((q.pos[1] - p0[1]) ^ 2 + (q.pos[2] - p0[2]) ^ 2) or 0
		totals.rides = totals.rides + 1
		totals.cells = totals.cells + math.max(0, cells - 1)
		totals.dist = totals.dist + dist
		totals.edge = totals.edge or 0
		if fell and not through then totals.edge = totals.edge + 1 elseif fell then totals.fell = totals.fell + 1 elseif bail then totals.bail = totals.bail + 1 else totals.clean = totals.clean + 1 end
		log("ride %2d: %s  %5.0f units, %d chunk crossings, lowest %.0f below start | held %d ticks in %d stretches, %d collision builds | %s", r,
			(fell and through) and "FELL THROUGH" or fell and "off an edge" or bail and "bail" or "clean", dist, math.max(0, cells - 1), z0 - minZ, heldTicks, heldRuns, builds, (lastColl or ""):sub(1, 120))
		totals.held, totals.heldRuns, totals.builds = (totals.held or 0) + heldTicks, (totals.heldRuns or 0) + heldRuns, (totals.builds or 0) + builds
	end
end
log("held %d ticks in %d stretches, %d collision builds", totals.held or 0, totals.heldRuns or 0, totals.builds or 0)
log("TOTAL (orient %s): %d rides: %d clean, %d bails, %d fell THROUGH the ground, %d off an edge; %d badspots; %d chunk crossings, %.0f units", ORIENT,
	totals.rides, totals.clean, totals.bail, totals.fell, totals.edge or 0, totals.badspot, totals.cells, totals.dist)
out:close()
