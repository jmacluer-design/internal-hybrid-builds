-- One synthetic scene (synth.rs output) with pieces left out, ridden in the
-- moving layer over an empty world, to find what costs the speed.
--   luajit steplab.lua <scene.lua> <variant raw|piped> <from x> <yaw> <start z> <speeds> <out>
local data = dofile(arg[1])[arg[2]]
local FROM, YAW, Z0, outname = tonumber(arg[3]), tonumber(arg[4]), tonumber(arg[5]), arg[7]
local speeds = {}
for v in arg[6]:gmatch("[^,]+") do speeds[#speeds + 1] = tonumber(v) end
local out = assert(io.open(outname, "w"))
local function log(...) local s = string.format(...) out:write(s, "\n") out:flush() print(s) end
local open = assert(package.loadlib(os.getenv("SK8_DLL"), "gmod13_open")) open()
skategm.SetTuning("SK8_OFF", "crossings,bigterrain,shortsteps,slopededges,world,props")
local BASE = { 0, 0, 3000 }
local f = assert(io.open(os.getenv("SK8_MAP"), "rb")) local bytes = f:read("*a") f:close()
skategm.Load(os.getenv("SK8_DATA"), BASE[1], BASE[2], BASE[3], 0, bytes, 1, 1, 1, 8)
local function wait(s) local t = os.clock() + s while os.clock() < t do end end
repeat wait(0.5) until skategm.Poll().status ~= "loading"
local function tick()
	local before = skategm.Poll().tick or 0
	skategm.Step(1 / 60, false, 0, 0, 0, 0, 0, 0, 0)
	local w, q = os.clock() + 0.5, nil
	repeat q = skategm.Poll() until (q.tick or 0) > before or os.clock() > w
	return q
end
local function info(t, i)
	local ux, uy, uz, vx, vy, vz = t[i+3]-t[i], t[i+4]-t[i+1], t[i+5]-t[i+2], t[i+6]-t[i], t[i+7]-t[i+1], t[i+8]-t[i+2]
	local nx, ny, nz = uy*vz-uz*vy, uz*vx-ux*vz, ux*vy-uy*vx
	local l = math.sqrt(nx*nx+ny*ny+nz*nz)
	return l > 0 and nz / l or 0, math.min(t[i+2], t[i+5], t[i+8]), math.max(t[i+2], t[i+5], t[i+8]),
		math.min(t[i], t[i+3], t[i+6]), math.max(t[i], t[i+3], t[i+6])
end
local variants = {
	{ "everything", function() return true end },
	{ "nothing below the floor (box sides, bottoms)", function(nz, zlo, zhi) return zhi > 0.01 end },
	{ "no vertical faces", function(nz) return math.abs(nz) > 0.05 end },
	{ "no faces facing down", function(nz) return nz > -0.3 end },
	{ "no floor under the ramp", function(nz, zlo, zhi, xlo, xhi) return not (nz > 0.99 and zhi < 0.01 and xlo > -40 and xhi <= 0.01) end },
	{ "only up-facing faces", function(nz) return nz > 0.3 end },
	{ "no floor beyond x = 0 (under a kicker)", function(nz, zlo, zhi, xlo) return not (nz > 0.99 and zhi < 0.01 and xlo > -0.01) end },
	{ "nothing beyond x = 0 below 0.5", function(nz, zlo, zhi, xlo) return not (zhi < 0.5 and xlo > -0.01) end },
}
for k, v in ipairs(variants) do
	local flat = {}
	for i = 1, #data - 8, 9 do
		if v[2](info(data, i)) then for j = 0, 8 do flat[#flat + 1] = data[i + j] end end
	end
	local name = "steplab/" .. k
	skategm.DefineModel(name, { flat }, 1)
	-- (SK8_LAB_AS=entity: through the entity path - its cleanup, and rails -
	-- instead of the moving layer, which has no rails)
	if os.getenv("SK8_LAB_AS") == "entity" then
		skategm.SetMovers({})
		skategm.SetEntities({ { name, BASE[1], BASE[2], BASE[3], 0, 0, 0 } })
		for _ = 1, 600 do
			tick()
			local c = skategm.Poll().collision or ""
			if c:find("1 entities") and not c:find("pending") or c:find("1 entities, 0 shapes") then break end
		end
	else
		skategm.SetMovers({ { name, BASE[1], BASE[2], BASE[3], 0, 0, 0 } })
	end
	local cells = {}
	for _, sp in ipairs(speeds) do
		local dx, dy = math.cos(math.rad(YAW)), math.sin(math.rad(YAW))
		-- (SK8_LAB_AT="x y": aimed at that point from |from| back, measured from it)
		local ax, ay = (os.getenv("SK8_LAB_AT") or ""):match("([%-%d%.]+) ([%-%d%.]+)")
		local tx, ty = tonumber(ax) or 0, tonumber(ay) or 0
		local sx, sy = ax and (tx - dx * math.abs(FROM)) or FROM, ax and (ty - dy * math.abs(FROM)) or 0
		skategm.Activate(BASE[1] + sx, BASE[2] + sy, BASE[3] + Z0 - 15.5, YAW)
		for _ = 1, 30 do tick() end
		skategm.Push(dx * sp / 0.0254, dy * sp / 0.0254, 0)
		local seq, last, prev, slow = {}, nil, nil, 99
		local passed
		for _ = 1, 150 do
			local q = tick()
			local st = q.state or "?"
			if st ~= last then seq[#seq + 1] = st last = st end
			if q.pos and prev then
				local s = math.sqrt((q.pos[1] - prev[1]) ^ 2 + (q.pos[2] - prev[2]) ^ 2) * 60 * 0.0254
				local rel = (q.pos[1] - BASE[1] - tx) * dx + (q.pos[2] - BASE[2] - ty) * dy
				if rel > -10 and rel < 80 then slow = math.min(slow, s) end
				if rel > 80 and not passed then passed = s end
			end
			prev = q.pos
		end
		local s = table.concat(seq, ">")
		cells[#cells + 1] = (s:find("Biped") and "OFF" or s:find("Wipeout") and "BAIL" or "ok") .. string.format("(min %.1f, after %s)", slow, passed and string.format("%.1f", passed) or "-")
		-- (SK8_STATES=1: and any grind on the way)
		if os.getenv("SK8_STATES") and s:find("Grind") then cells[#cells] = cells[#cells] .. "[" .. (s:match("(Grind%a+)") or "") .. "]" end
	end
	log("%-46s %s", v[1], table.concat(cells, "  "))
end
out:close()
