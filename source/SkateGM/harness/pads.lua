-- Which controller the module finds, and what it reads from it, for SECONDS
-- (default 20): press buttons and move the sticks while it runs.
--   luajit pads.lua [seconds]
-- SK8_DLL, SK8_DATA, SK8_MAP; SK8_ON=sdlonly ignores XInput pads
local seconds = tonumber(arg[1]) or 20
local DLL = os.getenv("SK8_DLL") or "gmcl_skategm_win64.dll"
local DATA = os.getenv("SK8_DATA") or (os.getenv("LOCALAPPDATA") or ".") .. "/SkateGM/data/assets"
local MAP = os.getenv("SK8_MAP")
local function wait(sec) local t = os.clock() + sec while os.clock() < t do end end

local open = assert(package.loadlib(DLL, "gmod13_open")) open()
if os.getenv("SK8_ON") then skategm.SetTuning("SK8_ON", os.getenv("SK8_ON")) end
local f = assert(io.open(MAP, "rb")) local bytes = f:read("*a") f:close()
skategm.Load(DATA, 0, 0, 8, 0, bytes, 1, 1, 1, 8)
bytes = nil collectgarbage()
local p, t0 = nil, os.time()
repeat wait(0.5) p = skategm.Poll() until p.status ~= "loading" or os.time() - t0 > 400
skategm.Activate(0, 0, 8, 0)
local last
local stop = os.clock() + seconds
while os.clock() < stop do
	skategm.Step(1 / 60, true, 0, 0, 0, 0, 0, 0, 0)
	wait(1 / 60)
	p = skategm.Poll()
	local line = string.format("pad: %s [%s] (connected %s) | buttons %04x LT %d RT %d | L %.2f %.2f R %.2f %.2f", tostring(p.padName), tostring(p.padType), tostring(p.pad), p.padButtons or 0,
		p.padLT or 0, p.padRT or 0, p.padLX or 0, p.padLY or 0, p.padRX or 0, p.padRY or 0)
	if line ~= last then print(line) last = line end
end
