-- Y (get off the board) pressed while grabbing in the air: what the engine does.
--   luajit airgrab.lua [grab: lt | rt | both | none] [y: 1 | 0] [ticks]
-- SK8_DLL, SK8_DATA, SK8_MAP (sgm_warehouse is fine)
local grab, pressY, ticks = arg[1] or "rt", (arg[2] or "1") == "1", tonumber(arg[3]) or 240
local yAt, lift = tonumber(arg[4]) or 25, tonumber(arg[5]) or 1400
local DLL = os.getenv("SK8_DLL") or "gmcl_skategm_win64.dll"
local DATA = os.getenv("SK8_DATA") or (os.getenv("LOCALAPPDATA") or ".") .. "/SkateGM/data/assets"
local MAP = os.getenv("SK8_MAP")
local function wait(sec) local t = os.clock() + sec while os.clock() < t do end end

local open = assert(package.loadlib(DLL, "gmod13_open")) open()
if os.getenv("SK8_BLOCK_AIR_Y") and skategm.SetAirDismountBlock then skategm.SetAirDismountBlock(1) end
local f = assert(io.open(MAP, "rb")) local bytes = f:read("*a") f:close()
skategm.Load(DATA, 0, 0, 8, 0, bytes, 1, 1, 1, 8)
bytes = nil collectgarbage()
local p, t0 = nil, os.time()
repeat wait(0.5) p = skategm.Poll() until p.status ~= "loading" or os.time() - t0 > 400
skategm.Activate(0, 0, 8, 0)

local function step(buttons, lt, rt)
	local before = skategm.Poll().tick or 0
	skategm.Step(1 / 60, false, buttons, lt, rt, 0, 0, 0, 0)
	local w = os.clock() + 0.5
	local q
	repeat q = skategm.Poll() until (q.tick or 0) > before or os.clock() > w
	return q
end
for _ = 1, 120 do step(0, 0, 0) end
skategm.Push(200, 0, 0)
for _ = 1, 20 do step(0, 0, 0) end
skategm.Push(0, 0, lift)

local Y = 0x8000
local lastState, lastPos, still, seenY = nil, nil, 0, nil
local seq = {}
for i = 1, ticks do
	local q = skategm.Poll()
	local air = (q.state or ""):find("Air") ~= nil
	local lt = (grab == "lt" or grab == "both") and air and 255 or 0
	local rt = (grab == "rt" or grab == "both") and air and 255 or 0
	local buttons = 0
	if pressY and air and i >= yAt and not seenY then
		buttons = Y
		seenY = i
	elseif pressY and seenY and i < seenY + 4 then
		buttons = Y
	end
	q = step(buttons, lt, rt)
	local pos = q.pos or { 0, 0, 0 }
	local moved = lastPos and math.sqrt((pos[1] - lastPos[1]) ^ 2 + (pos[2] - lastPos[2]) ^ 2 + (pos[3] - lastPos[3]) ^ 2) or 0
	if moved < 0.01 then still = still + 1 else still = 0 end
	if q.state ~= seq[#seq] then seq[#seq + 1] = q.state end
	if os.getenv("SK8_VERBOSE") and (q.state ~= lastState or i % 30 == 0 or buttons ~= 0) then
		print(string.format("tick %3d %-28s pos %.1f %.1f %.1f moved %.2f btn %04x lt %d rt %d recovered %s status %s %s",
			i, tostring(q.state), pos[1], pos[2], pos[3], moved, buttons, lt, rt, tostring(q.recovered), tostring(q.status), q.warning and ("| " .. q.warning) or ""))
		lastState = q.state
	end
	lastPos = pos
end
local q = skategm.Poll()
print("SEQ " .. table.concat(seq, " > "))
print(string.format("END state %s recovered %s status %s error %s still for %d ticks warning %s", tostring(q.state), tostring(q.recovered), tostring(q.status), tostring(q.error), still, tostring(q.warning)))
