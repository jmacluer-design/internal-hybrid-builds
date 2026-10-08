-- What the real engine does with small lips: the synthetic scenes from
-- examples/synth.rs (steps, cracks, bumps, overhangs, seams), raw and after
-- the pipeline, put in the moving layer high above an empty world, ridden
-- into at several speeds and angles.
--   luajit lips.lua <synth dir> <out> [kinds, e.g. "step,bump"]
-- SK8_DLL, SK8_DATA, SK8_MAP (any BSP: SK8_OFF=world leaves it out)
-- SK8_OFF_ADD: more switches off (e.g. entclean), SK8_SPEEDS: m/s list
local DIR, outname, kinds = arg[1], arg[2] or "lips_out.txt", arg[3]
local DLL = os.getenv("SK8_DLL") or "gmcl_skategm_win64.dll"
local DATA = os.getenv("SK8_DATA") or (os.getenv("LOCALAPPDATA") or ".") .. "/SkateGM/data/assets"
local MAP = os.getenv("SK8_MAP")
local out = assert(io.open(outname, "w"))
local function log(...) local s = string.format(...) out:write(s, "\n") out:flush() print(s) end
local function wait(sec) local t = os.clock() + sec while os.clock() < t do end end
local want = {}
for k in (kinds or ""):gmatch("[^,]+") do want[k] = true end

local open = assert(package.loadlib(DLL, "gmod13_open")) open()
skategm.SetTuning("SK8_CURVE_CAP", "16")
skategm.SetTuning("SK8_TAPER", "linear")
skategm.SetTuning("SK8_OFF", "crossings,bigterrain,shortsteps,slopededges,world,props" .. (os.getenv("SK8_OFF_ADD") and ("," .. os.getenv("SK8_OFF_ADD")) or ""))
local BASE = { 0, 0, 3000 }
local f = assert(io.open(MAP, "rb")) local bytes = f:read("*a") f:close()
skategm.Load(DATA, BASE[1], BASE[2], BASE[3], 0, bytes, 1, 1, 1, 8)
bytes = nil collectgarbage()
local p, t0 = nil, os.time()
repeat wait(0.5) p = skategm.Poll() until p.status ~= "loading" or os.time() - t0 > 400
log("lips test; loaded: %s", tostring(p.status))

local bone = {}
local function board(q)
	if not bone.TRUCK_FRONT then for k, nm in ipairs(skategm.Poll(true).names or {}) do bone[nm] = k end end
	local b = q.bones or {}
	local fr, r = b[bone.TRUCK_FRONT or -1], b[bone.TRUCK_BACK or -1]
	if fr and r then return (fr[1] + r[1]) / 2, (fr[2] + r[2]) / 2, (fr[3] + r[3]) / 2 end
	return q.pos[1], q.pos[2], q.pos[3]
end
local function tick()
	local before = skategm.Poll().tick or 0
	skategm.Step(1 / 60, false, 0, 0, 0, 0, 0, 0, 0)
	local w, q = os.clock() + 0.5, nil
	repeat q = skategm.Poll() until (q.tick or 0) > before or os.clock() > w
	return q
end

-- one ride: from `from` (scene x) towards x = 0 at `angle` degrees off
-- straight-on, at `speed` m/s; measured once the board is 60 past the edge
local function ride(floorStart, from, dir, angle, speed)
	local yaw = (dir > 0 and 0 or 180) + angle
	local sx, sy, sz = BASE[1] + from, BASE[2] - math.sin(math.rad(angle)) * math.abs(from) * dir * 0, BASE[3] + floorStart
	-- start far enough back that the line still reaches the edge mid-scene
	local back = math.abs(from) / math.max(0.2, math.cos(math.rad(angle)))
	sx = BASE[1] - dir * back * math.cos(math.rad(angle))
	sy = BASE[2] - back * math.sin(math.rad(angle))
	skategm.Activate(sx, sy, sz - 15, yaw)
	for _ = 1, 50 do tick() end
	local q = skategm.Poll()
	local rad = math.rad(yaw)
	skategm.Push(math.cos(rad) * speed / 0.0254, math.sin(rad) * speed / 0.0254, 0)
	local before, after, minSp, bail, last, crossedAt
	local seq, hist, afterSum, afterN = {}, {}, nil, nil
	local prev = { board(q) }
	for i = 1, 240 do
		q = tick()
		local x, y, z = board(q)
		local sp = math.sqrt((x - prev[1]) ^ 2 + (y - prev[2]) ^ 2 + (z - prev[3]) ^ 2) * 60 * 0.0254
		prev = { x, y, z }
		local rel = (x - BASE[1]) * dir
		-- (speeds averaged: before = the 12 ticks up to 20 short of the edge,
		-- after = from 30 past it to 60 past it)
		hist[#hist + 1] = sp
		if rel < -20 then
			local n, sum = 0, 0
			for k = math.max(1, #hist - 11), #hist do n, sum = n + 1, sum + hist[k] end
			before = sum / n
		end
		if rel > 30 then afterSum, afterN = (afterSum or 0) + sp, (afterN or 0) + 1 end
		if rel > 0 and not crossedAt then crossedAt = i end
		if crossedAt then minSp = math.min(minSp or 99, sp) end
		local st = q.state or "?"
		if st ~= last then seq[#seq + 1] = st last = st end
		if st:find("Wipeout") then bail = true end
		if rel > 60 then after = afterSum / afterN break end
		if i > 30 and sp < 0.3 and not crossedAt then break end
	end
	return before or 0, after, minSp, bail, seq
end

local index = dofile(DIR .. "/index.lua")
local speeds = {}
for v in (os.getenv("SK8_SPEEDS") or "4,6,9,12"):gmatch("[^,]+") do speeds[#speeds + 1] = tonumber(v) end
local angles = { 0, 45, 70 }
for _, sc in ipairs(index) do
	if next(want) == nil or want[sc.kind] then
		local data = dofile(DIR .. "/" .. sc.name .. ".lua")
		local variants = os.getenv("SK8_VARIANTS") and {} or { "raw", "piped" }
		for v in (os.getenv("SK8_VARIANTS") or ""):gmatch("[^,]+") do variants[#variants + 1] = v end
		for _, variant in ipairs(variants) do
			local name = "lips/" .. sc.name .. "/" .. variant
			skategm.DefineModel(name, { data[variant] }, 1)
			-- (SK8_LIPS_AS=entity: through the entity path - placement and the
			-- entities' cleanup - instead of straight into the moving layer)
			if os.getenv("SK8_LIPS_AS") == "entity" then
				skategm.SetMovers({})
				skategm.SetEntities({ { name, BASE[1], BASE[2], BASE[3], 0, 0, 0 } })
				for _ = 1, 400 do
					tick()
					local c = skategm.Poll().collision or ""
					if c:find("1 entities") then break end
				end
			else
				skategm.SetMovers({ { name, BASE[1], BASE[2], BASE[3], 0, 0, 0 } })
			end
			for _ = 1, 3 do tick() end
			local dirs = (sc.kind == "step" or sc.kind:find("^slope")) and { 1, -1 } or { 1 }
			for _, dir in ipairs(dirs) do
				local rise = sc.kind:find("^slope") and math.floor(sc.v * 10) / 10 or sc.v
				local startZ = (sc.kind == "step" or sc.kind == "overhang" or sc.kind:find("^slope")) and dir < 0 and rise or 0
				for _, angle in ipairs(angles) do
					local cells = {}
					for _, speed in ipairs(speeds) do
						local b, a, m, bail, seq = ride(startZ, -120, dir, angle, speed)
						local keep = a and b > 0 and a / b or 0
						cells[#cells + 1] = bail and "BAIL" or (not a and "STOP") or string.format("%3.0f%%", keep * 100)
						local odd = {}
						for _, st in ipairs(seq) do if not st:find("^Physics") then odd[#odd + 1] = st end end
						if #odd > 0 and os.getenv("SK8_STATES") then cells[#cells] = cells[#cells] .. "[" .. table.concat(odd, ">") .. "]" end
					end
					log("%-14s %-5s %-4s %2d deg | %s  (at %s m/s)", sc.name, variant, dir > 0 and "up" or "down", angle, table.concat(cells, "  "), table.concat(speeds, "/"))
				end
			end
		end
	end
end
out:close()
