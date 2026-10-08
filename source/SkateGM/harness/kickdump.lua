-- the processed collision around one spot, as the engine has it, saved for kicklab.lua
--   luajit kickdump.lua <x> <y> <z> <radius> <out.lua>
local x, y, z, r, outname = tonumber(arg[1]), tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4]), arg[5]
local open = assert(package.loadlib(os.getenv("SK8_DLL"), "gmod13_open")) open()
skategm.SetTuning("SK8_CURVE_CAP", "16") skategm.SetTuning("SK8_TAPER", "linear")
skategm.SetTuning("SK8_OFF", "crossings,bigterrain,shortsteps,slopededges" .. (os.getenv("SK8_OFF_ADD") and ("," .. os.getenv("SK8_OFF_ADD")) or ""))
local f = assert(io.open(os.getenv("SK8_MAP"), "rb")) local bytes = f:read("*a") f:close()
skategm.Load(os.getenv("SK8_DATA"), x, y, z, 0, bytes, 1, 1, 1, 8)
local function wait(s) local t = os.clock() + s while os.clock() < t do end end
repeat wait(0.5) until skategm.Poll().status ~= "loading"
-- props: their real shapes (as harness.lua does)
local PAK = (os.getenv("SK8_PAK") or "pak") .. "/"
for _ = 1, 40 do
	for _, mdl in ipairs(skategm.Poll().needModels or {}) do
		local ph = io.open(PAK .. mdl:gsub("#bbox$", ""):gsub("%.mdl$", ".phy"), "rb") or (os.getenv("SK8_PROPS_GMOD") ~= "0" and io.open("pak_gmod/" .. mdl:gsub("#bbox$", ""):gsub("%.mdl$", ".phy"), "rb") or nil)
		local hulls = {}
		if ph then local d = ph:read("*a") ph:close() hulls = skategm.PhyHulls(d) or {} end
		skategm.DefineModel(mdl, hulls)
	end
	skategm.Step(1 / 60, false, 0, 0, 0, 0, 0, 0, 0)
	wait(0.1)
end
wait(3)
local t, tags = skategm.CollisionNear(x, y, z, r, 200000)
local o = assert(io.open(outname, "w"))
o:write("return { tris = {")
for i = 1, #t do o:write(string.format("%.3f,", t[i])) end
o:write("}, tags = {")
for i = 1, #tags do o:write(tags[i], ",") end
o:write("} }\n")
o:close()
print(#t / 9 .. " triangles saved")
