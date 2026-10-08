-- Landings: the board dropped from a height with forward speed onto a
-- synthetic scene (synth.rs output, raw and after the pipeline), landing
-- around x = 0, in the moving layer over an empty world.
--   luajit droplab.lua <synth dir> <scenes, e.g. "step_0,seam_16"> <heights> <speeds> <out>
local DIR, names, heights, speeds, outname = arg[1], arg[2], arg[3], arg[4], arg[5] or "droplab_out.txt"
local out = assert(io.open(outname, "w"))
local function log(...) local s = string.format(...) out:write(s, "\n") out:flush() print(s) end
local function list(s) local t = {} for v in s:gmatch("[^,]+") do t[#t + 1] = tonumber(v) or v end return t end
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
local bone = {}
local function board(q)
	if not bone.TRUCK_FRONT then for k, nm in ipairs(skategm.Poll(true).names or {}) do bone[nm] = k end end
	local b = q.bones or {}
	local fr, r = b[bone.TRUCK_FRONT or -1], b[bone.TRUCK_BACK or -1]
	if fr and r then return (fr[1] + r[1]) / 2, (fr[2] + r[2]) / 2, (fr[3] + r[3]) / 2 end
	return q.pos[1], q.pos[2], q.pos[3]
end

-- one drop: horizontal speed just before touching down and 0.5 s after
local function drop(h, sp)
	-- (start far enough back to come down near x = 0: fall time at 386 in/s^2)
	local fall = math.sqrt(2 * math.max(h, 1) / 386)
	local x0 = -sp / 0.0254 * fall
	skategm.Activate(BASE[1] + x0 - 200, BASE[2], BASE[3] + h - 15.5, 0)
	-- (rolled up to speed on a run-up plank in the air, then let go)
	for _ = 1, 30 do tick() end
	skategm.Push(sp / 0.0254, 0, 0)
	local prev, seq, last = nil, {}, nil
	local before, landedAt, after, bail, landX
	for i = 1, 240 do
		local q = tick()
		local x, y, z = board(q)
		local st = q.state or "?"
		if st ~= last then seq[#seq + 1] = st last = st end
		if st:find("Wipeout") then bail = true end
		if prev then
			local s = math.sqrt((x - prev[1]) ^ 2 + (y - prev[2]) ^ 2) * 60 * 0.0254
			if st:find("Air") then before = s end
			if not landedAt and before and not st:find("Air") then landedAt, landX = i, x - BASE[1] end
			if landedAt and i == landedAt + 30 then after = s break end
		end
		prev = { x, y, z }
	end
	return before, after, bail, landX, seq
end

local runup = {}
-- a plank to roll up to speed on before the drop (from x = -2000 to the edge)
local function plank(h, sp)
	local fall = math.sqrt(2 * math.max(h, 1) / 386)
	local edge = -sp / 0.0254 * fall
	local z = h
	local x0, x1 = edge - 400, edge
	return { x0, -24, z, x1, -24, z, x1, 24, z, x0, -24, z, x1, 24, z, x0, 24, z }
end

for _, name in ipairs(list(names)) do
	local data = dofile(DIR .. "/" .. name .. ".lua")
	for _, variant in ipairs({ "raw", "piped" }) do
		for _, h in ipairs(list(heights)) do
			local cells = {}
			for _, sp in ipairs(list(speeds)) do
				local flat = {}
				for _, v in ipairs(data[variant]) do flat[#flat + 1] = v end
				for _, v in ipairs(plank(h, sp)) do flat[#flat + 1] = v end
				local mname = "droplab/" .. name .. "/" .. variant .. "/" .. h .. "/" .. sp
				skategm.DefineModel(mname, { flat }, 1)
				skategm.SetMovers({ { mname, BASE[1], BASE[2], BASE[3], 0, 0, 0 } })
				for _ = 1, 2 do tick() end
				local b, a, bail, lx = drop(h, sp)
				cells[#cells + 1] = bail and "BAIL" or (not (a and b) and "  - ") or string.format("%3.0f%%", a / b * 100)
				if os.getenv("SK8_DROP_DEBUG") then cells[#cells] = cells[#cells] .. string.format("(%s>%s @%s)", b and string.format("%.1f", b) or "-", a and string.format("%.1f", a) or "-", lx and string.format("%.0f", lx) or "-") end
			end
			log("%-16s %-5s drop %3d | %s  (at %s m/s)", name, variant, h, table.concat(cells, "  "), speeds)
		end
	end
end
out:close()
