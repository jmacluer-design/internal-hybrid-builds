-- InfMap2 with the real engine: the map's BSP left out (SK8_OFF=world), the
-- terrain built chunk by chunk from the map's own height function and handed
-- to the engine as entities (as the add-on does), the collision region
-- following the skater. Rides go out across chunk boundaries far from the
-- origin, where the BSP's box walls would have been.
--   luajit infmap.lua <infmap2 dir> <map name> <out> [rides]
-- SK8_DLL, SK8_DATA, SK8_PUSH (m/s, default 8), SK8_TICKS (default 600)
local INF, MAPNAME, outname, rides = arg[1], arg[2] or "gm_inf_bliss", arg[3] or "infmap_out.txt", tonumber(arg[4] or "6")
local DLL = os.getenv("SK8_DLL") or "gmcl_skategm_win64.dll"
local DATA = os.getenv("SK8_DATA") or (os.getenv("LOCALAPPDATA") or ".") .. "/SkateGM/data/assets"
local out = assert(io.open(outname, "w"))
local function log(...) local s = string.format(...) out:write(s, "\n") out:flush() print(s) end
local function wait(sec) local t = os.clock() + sec while os.clock() < t do end end

dofile("../tests/lua/gmock.lua")
bit = bit or require("bit")
function AddCSLuaFile() end
function Lerp(f, a, b) return a + (b - a) * f end
util = util or {}
util.SharedRandom = function(name, lo, hi, seed) local h = math.sin((seed or 0) * 12.9898 + #name * 78.233) * 43758.5453 return lo + (hi - lo) * (h - math.floor(h)) end
Color = Color or function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
Material = function(p) return p end
hook = { Add = function() end }
resource = { AddSingleFile = function() end }
SERVER, CLIENT = false, true
local simplex = dofile(INF .. "/lua/simplex.lua")
function include(f) if f == "simplex.lua" then return simplex end error("include " .. f) end
local main = dofile(INF .. "/lua/infmap2/" .. MAPNAME .. "/main.lua")
local realm = main.realms.default
local gen = realm.generator.legacy_terrain
local CHUNK = main.chunksize or 20000
local SAMPLES = gen.samples[1]

-- InfMap2's legacy_terrain GenerateChunkPhysics, ported (it uses GMod's `continue`)
local function ChunkPhysics(mx, my, mz)
	local physmesh, heightmap = {}, {}
	local half, sample = CHUNK / 2, CHUNK / SAMPLES
	local z_offset = mz * CHUNK
	for sx = -2, SAMPLES + 1 do
		local hmp = {}
		heightmap[sx] = hmp
		for sy = -2, SAMPLES + 1 do
			local x = (mx + (sx / SAMPLES)) * CHUNK - CHUNK / 2
			local y = (my + (sy / SAMPLES)) * CHUNK - CHUNK / 2
			hmp[sy] = gen.height_function(x, y) - z_offset
		end
	end
	for x = -1, SAMPLES do
		for y = -1, SAMPLES do
			local v0 = { (x - SAMPLES / 2) * sample, (y - SAMPLES / 2) * sample, heightmap[x][y] }
			local v1 = { (x - SAMPLES / 2 + 1) * sample, (y - SAMPLES / 2) * sample, heightmap[x + 1][y] }
			local v2 = { (x - SAMPLES / 2) * sample, (y - SAMPLES / 2 + 1) * sample, heightmap[x][y + 1] }
			local v3 = { (x - SAMPLES / 2 + 1) * sample, (y - SAMPLES / 2 + 1) * sample, heightmap[x + 1][y + 1] }
			local outside = true
			for _, v in ipairs({ v0, v1, v2, v3 }) do if v[3] >= -half and v[3] <= half then outside = false end end
			if not outside then
				for _, v in ipairs({ v0, v2, v1, v2, v3, v1 }) do physmesh[#physmesh + 1] = v end
			end
		end
	end
	return physmesh
end

-- as the add-on hands it over: one triangle list per chunk, facing up
local function ChunkFlat(mx, my, mz)
	local pm = ChunkPhysics(mx, my, mz)
	local flat = {}
	for i = 1, #pm - 2, 3 do
		local a, b, c = pm[i], pm[i + 1], pm[i + 2]
		local nz = (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
		if nz < 0 then b, c = c, b end
		for _, v in ipairs({ a, b, c }) do flat[#flat + 1] = v[1] flat[#flat + 1] = v[2] flat[#flat + 1] = v[3] end
	end
	return flat
end

local function Height(x, y) return gen.height_function(x, y) end
local function Cell(v) return math.floor((v + CHUNK / 2) / CHUNK) end

local open = assert(package.loadlib(DLL, "gmod13_open")) open()
skategm.SetTuning("SK8_CURVE_CAP", "16")
skategm.SetTuning("SK8_TAPER", "linear")
skategm.SetTuning("SK8_OFF", "crossings,bigterrain,shortsteps,slopededges,world")
local f = assert(io.open(INF .. "/maps/" .. MAPNAME .. ".bsp", "rb")) local bytes = f:read("*a") f:close()
skategm.Load(DATA, 0, 0, 0, 0, bytes, 1, 1, 1, 8)
bytes = nil collectgarbage()
local p, t0 = nil, os.time()
repeat wait(0.5) p = skategm.Poll() until p.status ~= "loading" or os.time() - t0 > 400
log("loaded: %s in %d s: %s", tostring(p.status), os.time() - t0, tostring(p.world))

local defined, placedKey = {}, nil
local function Feed(pos)
	for _, name in ipairs(skategm.Poll().needModels or {}) do
		if not defined[name] then
			defined[name] = true
			local mx, my, mz = name:match("^skategm_inf:default:(%-?%d+):(%-?%d+):(%-?%d+)$")
			skategm.DefineModel(name, mx and { ChunkFlat(tonumber(mx), tonumber(my), tonumber(mz)) } or {}, 1)
		end
	end
	local cx, cy, cz = Cell(pos[1]), Cell(pos[2]), Cell(pos[3])
	local key = cx .. "," .. cy .. "," .. cz
	if key == placedKey then return end
	placedKey = key
	local list = {}
	for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
		local mx, my, mz = cx + dx, cy + dy, cz + dz
		list[#list + 1] = { string.format("skategm_inf:default:%d:%d:%d", mx, my, mz), mx * CHUNK, my * CHUNK, mz * CHUNK, 0, 0, 0 }
	end end end
	skategm.SetEntities(list)
end

local function tick()
	local before = skategm.Poll().tick or 0
	skategm.Step(1 / 60, false, 0, 0, 0, 0, 0, 0, 0)
	local w, q = os.clock() + 0.5, nil
	repeat q = skategm.Poll() until (q.tick or 0) > before or os.clock() > w
	return q
end

local push = tonumber(os.getenv("SK8_PUSH") or "8") / 0.0254
local ticks = tonumber(os.getenv("SK8_TICKS") or "600")
math.randomseed(5)
for r = 1, rides do
	-- start well away from the origin, on the terrain, heading somewhere
	local sx, sy = (math.random() - 0.5) * 120000, (math.random() - 0.5) * 120000
	if r == 1 then sx, sy = 9000, 300 end
	if os.getenv("SK8_ONLY") and tostring(r) ~= os.getenv("SK8_ONLY") then goto skip end
	local sz = Height(sx, sy) + 4
	local yaw = r == 1 and 0 or math.random() * 360
	Feed({ sx, sy, sz })
	skategm.Activate(sx, sy, sz, yaw)
	local waited, held = 0, 0
	local frozenTicks = 0
	for _ = 1, 600 do
		Feed({ sx, sy, sz })
		local here = skategm.Poll().pos or { sx, sy, sz }
		local ground = skategm.CollisionHas(here[1], here[2], here[3] - 8, 48)
		skategm.SetFrozen(ground and 0 or 1)
		if not ground then frozenTicks = frozenTicks + 1 end
		local q = tick()
		if os.getenv("SK8_VERBOSE") == tostring(r) and waited == 20 then
			local t, tags = skategm.CollisionNear(here[1], here[2], here[3], 3000, 100000)
			local n, lo, hi, nearest = #t / 9, 1e9, -1e9, 1e9
			for i = 1, #t - 8, 9 do
				for k = 0, 2 do lo = math.min(lo, t[i + k * 3 + 2]) hi = math.max(hi, t[i + k * 3 + 2]) end
				local cxm, cym, czm = (t[i] + t[i + 3] + t[i + 6]) / 3, (t[i + 1] + t[i + 4] + t[i + 7]) / 3, (t[i + 2] + t[i + 5] + t[i + 8]) / 3
				nearest = math.min(nearest, math.sqrt((cxm - here[1]) ^ 2 + (cym - here[2]) ^ 2 + (czm - here[3]) ^ 2))
			end
			for _, c in ipairs({ { 0, 0, 0 }, { -20000, 20000, 0 }, { -21831, 23125, -750 }, { 20000, -20000, 0 } }) do
				local tt = skategm.CollisionNear(c[1], c[2], c[3], 15000, 200000)
				local lx, hx, ly, hy = 1e9, -1e9, 1e9, -1e9
				for i = 1, #tt - 2, 3 do lx, hx, ly, hy = math.min(lx, tt[i]), math.max(hx, tt[i]), math.min(ly, tt[i + 1]), math.max(hy, tt[i + 1]) end
				log("  around %d %d: %d triangles, x %.0f..%.0f y %.0f..%.0f", c[1], c[2], #tt / 9, lx, hx, ly, hy)
			end
			log("  near: %d triangles within 3000, z %.0f..%.0f, nearest centroid %.0f; CollisionHas r=48 %s r=500 %s r=5000 %s", n, lo, hi, nearest,
				tostring(skategm.CollisionHas(here[1], here[2], here[3], 48)), tostring(skategm.CollisionHas(here[1], here[2], here[3], 500)), tostring(skategm.CollisionHas(here[1], here[2], here[3], 5000)))
		end
		if os.getenv("SK8_VERBOSE") == tostring(r) and (waited < 30 or waited % 50 == 0) then
			log("  settle %d: here %.0f %.0f %.0f ground %s held %s state %s | %s", waited, here[1], here[2], here[3], tostring(ground), tostring(q.held), tostring(q.state), tostring(q.collision))
		end
		waited = waited + 1
		if q.held then held = held + 1 end
		local c = q.collision or ""
		if ground and not q.held and c:find("entities") and q.state and q.state:find("PhysicsGround") and waited > 60 then break end
		wait(0.01)
	end
	local q0 = skategm.Poll()
	if os.getenv("SK8_VERBOSE") == tostring(r) and q0.pos then log("  settled at %.0f %.0f %.0f (terrain %.0f) state %s", q0.pos[1], q0.pos[2], q0.pos[3], Height(q0.pos[1], q0.pos[2]), tostring(q0.state)) end
	local dx, dy = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
	skategm.Push(dx * push, dy * push, 0)
	local cells, lastCell, seq, last = 0, nil, {}, nil
	local minAbove, maxAbove, bail, fell, heldTicks = 1e9, -1e9, false, false, 0
	local p0 = q0.pos and { q0.pos[1], q0.pos[2], q0.pos[3] } or { sx, sy, sz }
	local q = q0
	local rideFrozen = 0
	for i = 1, ticks do
		if q.pos then
			Feed(q.pos)
			local ground = skategm.CollisionHas(q.pos[1], q.pos[2], q.pos[3], 2000)
			skategm.SetFrozen(ground and 0 or 1)
			if not ground then rideFrozen = rideFrozen + 1 end
		end
		q = tick()
		if q.held then heldTicks = heldTicks + 1 end
		if q.pos then
			local cell = Cell(q.pos[1]) .. "," .. Cell(q.pos[2])
			if cell ~= lastCell then cells = cells + 1 lastCell = cell end
			local above = q.pos[3] - Height(q.pos[1], q.pos[2])
			minAbove, maxAbove = math.min(minAbove, above), math.max(maxAbove, above)
			if above < -60 then fell = true end
		end
		local st = q.state or "?"
		if os.getenv("SK8_VERBOSE") == tostring(r) and q.pos and i <= tonumber(os.getenv("SK8_VERBOSE_TICKS") or "150") then
			log("  tick %d: pos %.0f %.0f %.0f terrain %.0f state %s held %s cell %d,%d ents %s", i, q.pos[1], q.pos[2], q.pos[3], Height(q.pos[1], q.pos[2]), st, tostring(q.held), Cell(q.pos[1]), Cell(q.pos[2]), tostring((q.collision or ""):match("(%d+) entities")))
		end
		if st ~= last then seq[#seq + 1] = st last = st end
		if st:find("Wipeout") then bail = true end
	end
	local dist = q.pos and math.sqrt((q.pos[1] - p0[1]) ^ 2 + (q.pos[2] - p0[2]) ^ 2) or 0
	local sp = q.vel and math.sqrt(q.vel[1] ^ 2 + q.vel[2] ^ 2 + q.vel[3] ^ 2) * 0.0254 or 0
	log("ride %d: start %.0f %.0f %.0f (cell %d,%d) yaw %.0f | settled after %d ticks (%d held) | rode %.0f units through %d cells, end speed %.1f m/s, skater %.0f..%.0f above the terrain, held %d ticks, frozen waiting for terrain %d (settle %d), fell %s, bail %s | %s",
		r, sx, sy, sz, Cell(sx), Cell(sy), yaw, waited, held, dist, cells, sp, minAbove, maxAbove, heldTicks, rideFrozen, frozenTicks, tostring(fell), tostring(bail), table.concat(seq, " > "))
	log("  collision: %s", tostring(q.collision))
	::skip::
end
out:close()
