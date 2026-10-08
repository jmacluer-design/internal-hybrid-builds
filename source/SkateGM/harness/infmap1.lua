-- The original InfMap (gm_infmap) with the real engine: the map's BSP left out
-- (SK8_OFF=world), the terrain built by the add-on's own IM.Inf1Triangles from
-- InfMap's height function, the 3 x 3 chunks around the skater placed as the
-- add-on places them. Rides go out across chunk borders, far from the middle.
--   luajit infmap1.lua <infmap dir> <out> [rides]
-- SK8_DLL, SK8_DATA, SK8_PUSH (m/s, default 8), SK8_TICKS (default 600)
local INF, outname, rides = arg[1], arg[2] or "infmap1_out.txt", tonumber(arg[3] or "12")
local DLL = os.getenv("SK8_DLL") or "gmcl_skategm_win64.dll"
local DATA = os.getenv("SK8_DATA") or (os.getenv("LOCALAPPDATA") or ".") .. "/SkateGM/data/assets"
local out = assert(io.open(outname, "w"))
local function log(...) local s = string.format(...) out:write(s, "\n") out:flush() print(s) end
local function wait(sec) local t = os.clock() + sec while os.clock() < t do end end

dofile("../tests/lua/gmock.lua")
bit = bit or require("bit")
function AddCSLuaFile() end
Material = function(p) return p end
hook = { Add = function() end }
SERVER, CLIENT = false, false
util = util or {}
util.SharedRandom = function(name, lo, hi) return (lo + hi) / 2 end
local simplex = dofile(INF .. "/lua/simplex.lua")
function include(f) if f == "simplex.lua" then return simplex end error("include " .. f) end
InfMap = { chunk_size = 10000, filter = {}, disable_pickup = {} }
-- (GMod Lua: // comments, != and ! for not)
local function LoadGLua(path)
	local src = assert(io.open(path, "r")):read("*a")
	src = src:gsub("//", "--"):gsub("!=", "~="):gsub("!(%w)", "not %1")
	return assert(loadstring(src, path))()
end
LoadGLua(INF .. "/lua/infmap/gm_infmap/sh_collider_functions.lua")
local CS, RES = InfMap.chunk_size, InfMap.chunk_resolution or 3
local W = CS * 2
local function Height(x, y) return InfMap.height_function(x / W, y / W) end
local function Cell(v) return math.floor((v + CS) / W) end

-- the add-on's own builder
game = { GetMap = function() return "gm_infmap" end }
function LocalPlayer() return nil end
SkateGM = { L = {} }
dofile("../addon/skategm/lua/skategm/cl_infmap.lua")
local IM = SkateGM.infmap

local open = assert(package.loadlib(DLL, "gmod13_open")) open()
skategm.SetTuning("SK8_CURVE_CAP", "16")
skategm.SetTuning("SK8_TAPER", "linear")
skategm.SetTuning("SK8_OFF", "crossings,bigterrain,shortsteps,slopededges,world")
local f = assert(io.open(INF .. "/maps/gm_infmap.bsp", "rb")) local bytes = f:read("*a") f:close()
skategm.Load(DATA, 0, 0, 0, 0, bytes, 1, 1, 1, 8)
bytes = nil collectgarbage()
local p, t0 = nil, os.time()
repeat wait(0.5) p = skategm.Poll() until p.status ~= "loading" or os.time() - t0 > 400
log("loaded: %s in %d s", tostring(p.status), os.time() - t0)

local defined, placedKey = {}, nil
local function Feed(pos)
	for _, name in ipairs(skategm.Poll().needModels or {}) do
		if not defined[name] then
			defined[name] = true
			local x, y = name:match("^skategm_inf1:(%-?%d+):(%-?%d+)$")
			skategm.DefineModel(name, { x and IM.Inf1Triangles(tonumber(x), tonumber(y), InfMap.height_function, CS, RES) or {} }, 1)
		end
	end
	local cx, cy = Cell(pos[1]), Cell(pos[2])
	local key = cx .. "," .. cy
	if key == placedKey then return end
	placedKey = key
	local list = {}
	for dx = -1, 1 do for dy = -1, 1 do
		list[#list + 1] = { string.format("skategm_inf1:%d:%d", cx + dx, cy + dy), (cx + dx) * W, (cy + dy) * W, 0, 0, 0, 0 }
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

local push = tonumber(os.getenv("SK8_PUSH") or "8") / 0.0254
local ticks = tonumber(os.getenv("SK8_TICKS") or "600")
math.randomseed(7)
local totals = { rides = 0, clean = 0, bail = 0, fell = 0, cells = 0 }
for r = 1, rides do
	-- near a chunk border, far out, heading across it
	local cx, cy = math.random(-6, 6), math.random(-6, 6)
	local sx, sy = cx * W + CS - 300, cy * W + (math.random() - 0.5) * CS
	local yaw = (math.random() - 0.5) * 60
	local sz = Height(sx, sy) + 4
	Feed({ sx, sy, sz })
	skategm.Activate(sx, sy, sz, yaw)
	for w = 1, 400 do
		Feed(skategm.Poll().pos or { sx, sy, sz })
		local q = tick()
		if not q.held and (q.collision or ""):find("entities") and q.state and q.state:find("PhysicsGround") and w > 60 then break end
	end
	local q0 = skategm.Poll()
	local dx, dy = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
	skategm.Push(dx * push, dy * push, 0)
	local cells, lastCell, seq, last, bail, fell, lowest = 0, nil, {}, nil, false, false, 1e9
	local q = q0
	for i = 1, ticks do
		if q.pos then Feed(q.pos) end
		q = tick()
		if q.pos then
			local cell = Cell(q.pos[1]) .. "," .. Cell(q.pos[2])
			if cell ~= lastCell then cells = cells + 1 lastCell = cell end
			local above = q.pos[3] - Height(q.pos[1], q.pos[2])
			lowest = math.min(lowest, above)
			if above < -60 then fell = true end
		end
		local st = q.state or "?"
		if st ~= last then seq[#seq + 1] = st last = st end
		if st:find("Wipeout") then bail = true end
	end
	local dist = (q.pos and q0.pos) and math.sqrt((q.pos[1] - q0.pos[1]) ^ 2 + (q.pos[2] - q0.pos[2]) ^ 2) or 0
	totals.rides = totals.rides + 1
	totals.cells = totals.cells + math.max(0, cells - 1)
	if fell then totals.fell = totals.fell + 1 elseif bail then totals.bail = totals.bail + 1 else totals.clean = totals.clean + 1 end
	log("ride %2d at %.0f %.0f: %s, %5.0f units, %d chunk crossings, lowest %.0f above the terrain | %s", r, sx, sy,
		fell and "FELL THROUGH" or bail and "bail" or "clean", dist, math.max(0, cells - 1), lowest, table.concat(seq, " > "))
end
log("TOTAL: %d rides: %d clean, %d bails, %d fell through; %d chunk crossings", totals.rides, totals.clean, totals.bail, totals.fell, totals.cells)
out:close()
