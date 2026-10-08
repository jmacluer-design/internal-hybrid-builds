-- Carrying with the real engine: a plate in the moving layer slides under a
-- stopped board. Does the board go with it (as is, or with the plate's
-- velocity matched through skategm.Push)?
--   luajit carry.lua <cx> <cy> <cz> <spots file> <out>
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
log("carry test; loaded: %s in %d s; SetMovers %s", tostring(p.status), os.time() - t0, tostring(skategm.SetMovers ~= nil))
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


local function PlateHull()
	local c = {}
	for x = -512, 512 - 128, 128 do
		for y = -512, 512 - 128, 128 do
			for _, v in ipairs({ { x, y }, { x + 128, y }, { x + 128, y + 128 }, { x, y }, { x + 128, y + 128 }, { x, y + 128 } }) do
				c[#c + 1] = v[1] c[#c + 1] = v[2] c[#c + 1] = 0
			end
		end
	end
	return { c }
end
skategm.DefineModel("carry/plate", PlateHull(), 1)
local spots = {}
for line in io.lines(spotfile) do
	local x, y, z, yaw = line:match("([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+) ([%-%d%.]+)")
	if x then spots[#spots + 1] = { tonumber(x), tonumber(y), tonumber(z), tonumber(yaw) } end
end
local function ride(s, label, speed, angle, match, rise)
	local lift = 150
	local px, py, pz = s[1], s[2], s[3] + lift
	skategm.SetMovers({ { "carry/plate", px, py, pz, 0, 0, 0 } })
	skategm.Activate(s[1], s[2], pz + 4, s[4])
	for _ = 1, 120 do tick() end
	local q0 = skategm.Poll()
	local bx, by, bz = board(q0)
	local vx, vy = math.cos(math.rad(angle)) * speed / 0.0254, math.sin(math.rad(angle)) * speed / 0.0254
	if match then skategm.Push(vx, vy, 0) end
	local q = q0
	local seq, last = {}, nil
	local vz = (rise or 0) / 0.0254
	local z0p = pz
	for i = 1, 180 do
		px, py, pz = px + vx / 60, py + vy / 60, pz + vz / 60
		-- (SK8_CARRY_VEL=1: with the plate's velocity, as the add-on sends it)
		local vel = os.getenv("SK8_CARRY_VEL") and { vx, vy, vz } or { 0, 0, 0 }
		skategm.SetMovers({ { "carry/plate", px, py, pz, 0, 0, 0, vel[1], vel[2], vel[3] } })
		q = tick()
		local st = q.state or "?"
		if st ~= last then seq[#seq + 1] = st last = st end
	end
	local x, y, z = board(q)
	local moved = math.sqrt((x - bx) ^ 2 + (y - by) ^ 2)
	local plate = math.max(1e-3, math.sqrt((px - s[1]) ^ 2 + (py - s[2]) ^ 2))
	if rise then
		log("%-36s plate rose %4.0f, board %.0f above the plate at the end (%.0f at the start) | %s", label, pz - z0p, z - pz, bz - z0p, table.concat(seq, " > "))
		return
	end
	local relx, rely = x - px, y - py
	log("%-36s plate moved %4.0f, board moved %4.0f (%3.0f%%), board now %.0f from the plate's centre, %.0f above it | %s", label, plate, moved, moved / plate * 100,
		math.sqrt(relx ^ 2 + rely ^ 2), z - pz, table.concat(seq, " > "))
end
-- a turntable: the plate turns about its centre `rate` degrees a second, the
-- board standing `off` units from that centre
local function turntable(s, label, rate, off)
	local lift = 150
	local cxp, cyp, pz = s[1] - off, s[2], s[3] + lift
	local yaw = 0
	skategm.SetMovers({ { "carry/plate", cxp, cyp, pz, 0, yaw, 0 } })
	skategm.Activate(s[1], s[2], pz + 4, s[4])
	for _ = 1, 120 do tick() end
	local q = skategm.Poll()
	local bx, by = board(q)
	local function heading(qq)
		local b = qq.bones or {}
		local f, r = b[bone.TRUCK_FRONT or -1], b[bone.TRUCK_BACK or -1]
		return f and r and math.deg(math.atan2(f[2] - r[2], f[1] - r[1])) or 0
	end
	local a0, h0, r0 = math.deg(math.atan2(by - cyp, bx - cxp)), heading(q), math.sqrt((bx - cxp) ^ 2 + (by - cyp) ^ 2)
	local seq, last = {}, nil
	for _ = 1, 180 do
		yaw = yaw + rate / 60
		skategm.SetMovers({ { "carry/plate", cxp, cyp, pz, 0, yaw, 0, 0, 0, 0, os.getenv("SK8_CARRY_VEL") and rate or 0 } })
		q = tick()
		local st = q.state or "?"
		if st ~= last then seq[#seq + 1] = st last = st end
	end
	local x, y, z = board(q)
	local wrap = function(d) return ((d + 180) % 360) - 180 end
	local a1 = math.deg(math.atan2(y - cyp, x - cxp))
	log("%-36s plate turned %4.0f deg, board went round %4.0f deg, turned %4.0f deg, from the centre %.0f -> %.0f, %.0f above | %s", label, yaw,
		wrap(a1 - a0), wrap(heading(q) - h0), r0, math.sqrt((x - cxp) ^ 2 + (y - cyp) ^ 2), z - pz, table.concat(seq, " > "))
end

-- a seesaw: the plate tilts (roll, about its centre line along x) `rate`
-- degrees a second for `secs`, the board standing `off` units out along y
local function seesaw(s, label, rate, secs, off)
	local lift = 150
	local cxp, cyp, pz = s[1], s[2] - off, s[3] + lift
	local roll = 0
	skategm.SetMovers({ { "carry/plate", cxp, cyp, pz, 0, 0, roll } })
	skategm.Activate(s[1], s[2], pz + 4, s[4])
	for _ = 1, 120 do tick() end
	local seq, last, q = {}, nil, nil
	for _ = 1, math.floor(secs * 60) do
		roll = roll + rate / 60
		skategm.SetMovers({ { "carry/plate", cxp, cyp, pz, 0, 0, roll, 0, 0, 0, 0, 0, os.getenv("SK8_CARRY_VEL") and rate or 0 } })
		q = tick()
		local st = q.state or "?"
		if st ~= last then seq[#seq + 1] = st last = st end
	end
	local x, y, z = board(q)
	-- (the tilted plate's height under the board: rolled about the x axis through the centre)
	local plateZ = pz + (y - cyp) * math.tan(math.rad(roll))
	log("%-36s plate tilted %3.0f deg, board %.1f above the plate under it (it rose %.0f) | %s", label, roll, z - plateZ, plateZ - pz, table.concat(seq, " > "))
end

for si = 1, math.min(#spots, tonumber(os.getenv("SK8_SPOTS") or "3")) do
	local s = spots[si]
	log("spot %d", si)
	-- (SK8_CARRY_ONLY=lift: just the lifts, up and down at two speeds)
	if os.getenv("SK8_CARRY_ONLY") == "tilt" then
		seesaw(s, "  a seesaw 10 deg/s for 1 s, 100 out", 10, 1, 100)
		seesaw(s, "  a seesaw -10 deg/s for 1 s, 100 out", -10, 1, 100)
		seesaw(s, "  a seesaw 20 deg/s for 1 s, 100 out", 20, 1, 100)
	elseif os.getenv("SK8_CARRY_ONLY") == "turn" then
		turntable(s, "  a turntable 30 deg/s, 150 out", 30, 150)
		turntable(s, "  a turntable 60 deg/s, 150 out", 60, 150)
		turntable(s, "  a turntable 30 deg/s, at the centre", 30, 0)
	elseif os.getenv("SK8_CARRY_ONLY") == "lift" then
		ride(s, "  a lift rising 1 m/s", 0, 0, false, 1)
		ride(s, "  a lift rising 2 m/s", 0, 0, false, 2)
		ride(s, "  a lift going down 1 m/s", 0, 0, false, -1)
		ride(s, "  a platform sliding 2 m/s", 2, s[4] + 45, false)
	else
		ride(s, "  sideways 3 m/s, as is", 3, s[4] + 90, false)
		ride(s, "  sideways 3 m/s, velocity matched", 3, s[4] + 90, true)
		ride(s, "  along 3 m/s, as is", 3, s[4], false)
		ride(s, "  along 3 m/s, velocity matched", 3, s[4], true)
		ride(s, "  a lift rising 1 m/s", 0, 0, false, 1)
	end
end
out:close()
