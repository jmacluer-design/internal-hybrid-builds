-- Hoverboard on water with the real engine: the add-on's water plate (flat,
-- 3072 wide, 256-unit tiles; cl_water.lua) in the moving layer, following the
-- board in 512-unit steps, held in the air above the map as if it were water.
--   luajit water.lua <cx> <cy> <cz> <spots file> <out>
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
skategm.SetTuning("SK8_OFF", "crossings,bigterrain,shortsteps,slopededges" .. (os.getenv("SK8_NOWORLD") and ",world,props" or ""))
skategm.SetTuning("SK8_REGION_HALF", "4800")
local f = assert(io.open(MAP, "rb")) local bytes = f:read("*a") f:close()
skategm.Load(DATA, cx, cy, cz, 0, bytes, 1, 1, 1, 8)
bytes = nil collectgarbage()
local p, t0 = nil, os.time()
repeat wait(0.5) p = skategm.Poll() until p.status ~= "loading" or os.time() - t0 > 400
log("water plate test; loaded: %s in %d s; SetMovers %s", tostring(p.status), os.time() - t0, tostring(skategm.SetMovers ~= nil))
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


local function PlateHull()
	local c = {}
	for x = -1536, 1536 - 256, 256 do
		for y = -1536, 1536 - 256, 256 do
			for _, v in ipairs({ { x, y }, { x + 256, y }, { x + 256, y + 256 }, { x, y }, { x + 256, y + 256 }, { x, y + 256 } }) do
				c[#c + 1] = v[1] c[#c + 1] = v[2] c[#c + 1] = 0
			end
		end
	end
	return { c }
end
skategm.DefineModel("skategm/water_plate", PlateHull(), 1)

local spots = {}
for line in io.lines(spotfile) do
	local x, y, z, yaw = line:match("([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+)")
	if x then spots[#spots + 1] = { tonumber(x), tonumber(y), tonumber(z), tonumber(yaw) } end
end

local function snap(v) return math.floor(v / 512 + 0.5) * 512 end
local function ride(s, label, lift, speed, ticks, steer)
	local wz = s[3] + lift
	local px, py = snap(s[1]), snap(s[2])
	skategm.SetMovers({ { "skategm/water_plate", px, py, wz, 0, 0, 0 } })
	skategm.Activate(s[1], s[2], wz + 4, s[4])
	for _ = 1, 90 do tick() end
	local q0 = skategm.Poll()
	local bx, by, bz = board(q0)
	local dx, dy = math.cos(math.rad(s[4])), math.sin(math.rad(s[4]))
	skategm.Push(dx * speed / 0.0254, dy * speed / 0.0254, 0)
	local seq, last, moves, lo, hi, dist = {}, nil, 0, 1e9, -1e9, 0
	local q, lx, ly = q0, bx, by
	for i = 1, ticks do
		local x, y, z = board(q)
		local nx, ny = snap(x), snap(y)
		-- (sent only when it moves, as the add-on does)
		if nx ~= px or ny ~= py then
			px, py, moves = nx, ny, moves + 1
			skategm.SetMovers({ { "skategm/water_plate", px, py, wz, 0, 0, 0 } })
		end
		q = tick()
		x, y, z = board(q)
		dist = dist + math.sqrt((x - lx) ^ 2 + (y - ly) ^ 2) lx, ly = x, y
		if i > 10 then lo, hi = math.min(lo, z - wz), math.max(hi, z - wz) end
		local st = q.state or "?"
		if st ~= last then seq[#seq + 1] = st last = st end
	end
	local sp = q.vel and math.sqrt(q.vel[1] ^ 2 + q.vel[2] ^ 2) * 0.0254 or 0
	log("%-30s rode %5.0f units, end %4.1f m/s, board %.1f..%.1f above the plate, plate moved %d times | %s", label, dist, sp, lo, hi, moves, table.concat(seq, " > "))
end

for si = 1, math.min(#spots, tonumber(os.getenv("SK8_SPOTS") or "4")) do
	local s = spots[si]
	log("spot %d (%.0f %.0f %.0f yaw %.0f)", si, s[1], s[2], s[3], s[4])
	ride(s, "  plate 200 above, 6 m/s", 200, 6, 240)
	ride(s, "  plate 200 above, 15 m/s", 200, 15, 240)
	ride(s, "  plate 600 above, 30 m/s", 600, 30, 300)
end
out:close()
