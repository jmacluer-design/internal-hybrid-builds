-- One spot's real collision (from kickdump.lua) alone in the moving layer,
-- ridden along a line, with pieces left out to find what the board hits.
--   luajit kicklab.lua <geo.lua> <x> <y> <z> <yaw> <speed> <out>
local geo = dofile(arg[1])
local X, Y, Z, YAW, SPEED, outname = tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4]), tonumber(arg[5]), tonumber(arg[6]), arg[7]
local out = assert(io.open(outname, "w"))
local function log(...) local s = string.format(...) out:write(s, "\n") out:flush() print(s) end
local open = assert(package.loadlib(os.getenv("SK8_DLL"), "gmod13_open")) open()
skategm.SetTuning("SK8_OFF", "crossings,bigterrain,shortsteps,slopededges,world,props")
local f = assert(io.open(os.getenv("SK8_MAP"), "rb")) local bytes = f:read("*a") f:close()
skategm.Load(os.getenv("SK8_DATA"), X, Y, Z, 0, bytes, 1, 1, 1, 8)
local function wait(s) local t = os.clock() + s while os.clock() < t do end end
repeat wait(0.5) until skategm.Poll().status ~= "loading"
local function tick()
	local before = skategm.Poll().tick or 0
	skategm.Step(1 / 60, false, 0, 0, 0, 0, 0, 0, 0)
	local w, q = os.clock() + 0.5, nil
	repeat q = skategm.Poll() until (q.tick or 0) > before or os.clock() > w
	return q
end
local function nz(t, i)
	local ux, uy, uz, vx, vy, vz = t[i+3]-t[i], t[i+4]-t[i+1], t[i+5]-t[i+2], t[i+6]-t[i], t[i+7]-t[i+1], t[i+8]-t[i+2]
	local nx, ny, n3 = uy*vz-uz*vy, uz*vx-ux*vz, ux*vy-uy*vx
	local l = math.sqrt(nx*nx+ny*ny+n3*n3)
	return l > 0 and n3 / l or 0
end
local variants0 = {
	{ "everything", function() return true end },
	{ "no prop faces facing down", function(tag, n) return not (tag == 2 and n < -0.5) end },
	{ "no ledge ramps", function(tag) return tag ~= 5 end },
	{ "no curves", function(tag) return tag ~= 6 end },
	{ "no prop sides (steep)", function(tag, n) return not (tag == 2 and math.abs(n) < 0.3) end },
	{ "no displacement", function(tag) return tag ~= 1 end },
}
-- (SK8_LAB=brush: variants for maps built of brushes)
local variants = os.getenv("SK8_LAB") == "brush" and {
	{ "everything", function() return true end },
	{ "no faces facing down", function(tag, n) return n > -0.5 end },
	{ "no vertical faces", function(tag, n) return math.abs(n) > 0.05 end },
	{ "no steep faces (< 30 deg from vertical)", function(tag, n) return math.abs(n) > 0.5 end },
	{ "no ledge ramps", function(tag) return tag ~= 5 end },
	{ "no curves", function(tag) return tag ~= 6 end },
} or variants0
local k = 0
for _, v in ipairs(variants) do
	local flat = {}
	for i = 1, #geo.tris - 8, 9 do
		if v[2](geo.tags[(i - 1) / 9 + 1], nz(geo.tris, i)) then for j = 0, 8 do flat[#flat + 1] = geo.tris[i + j] end end
	end
	k = k + 1
	local name = "lab/" .. k
	skategm.DefineModel(name, { flat }, 1)
	skategm.SetMovers({ { name, 0, 0, 0, 0, 0, 0 } })
	local results = {}
	for _, back in ipairs({ 150, 200, 260 }) do
		local dx, dy = math.cos(math.rad(YAW)), math.sin(math.rad(YAW))
		skategm.Activate(X - dx * back, Y - dy * back, Z - 15, YAW)
		for _ = 1, 60 do tick() end
		skategm.Push(dx * SPEED / 0.0254, dy * SPEED / 0.0254, 0)
		local seq, last = {}, nil
		local top, prev, at = -1e9, nil, nil
		local mark = tonumber(os.getenv("SK8_LAB_Z") or "")
		for _ = 1, 150 do
			local q = tick()
			local st = q.state or "?"
			if st ~= last then seq[#seq + 1] = st last = st end
			if q.pos then
				top = math.max(top, q.pos[3])
				if prev and mark and not at and prev[3] < mark and q.pos[3] >= mark then
					at = math.sqrt((q.pos[1] - prev[1]) ^ 2 + (q.pos[2] - prev[2]) ^ 2 + (q.pos[3] - prev[3]) ^ 2) * 60 * 0.0254
				end
				prev = q.pos
			end
		end
		local s = table.concat(seq, ">")
		local verdict = s:find("Biped") and "OFF" or s:find("Wipeout") and "BAIL" or "ok"
		results[#results + 1] = string.format("%s(top %.0f%s)", verdict, top, at and string.format(", %.1f m/s at %d", at, mark) or "")
	end
	log("%-28s %d tris: %s", v[1], #flat / 9, table.concat(results, " "))
end
out:close()
