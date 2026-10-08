dofile("gmock.lua")
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
local cmds = {}
concommand = { Add = function(n, f) cmds[n] = f end }
function IsValid(x) if type(x) == "table" and x.IsValid then return x:IsValid() end return x ~= nil end
local cv = {}
function CreateClientConVar(n, d) cv[n] = d return { GetBool = function() return cv[n] == "1" end, GetFloat = function() return tonumber(cv[n]) or 0 end, GetInt = function() return math.floor(tonumber(cv[n]) or 0) end, GetString = function() return cv[n] end } end
local ran = {}
function RunConsoleCommand(name, v) ran[#ran + 1] = name .. " " .. tostring(v) if cv[name] ~= nil and v ~= nil then cv[name] = tostring(v) end if cmds[name] then cmds[name]() end end
MsgC = function() end chat = { AddText = function() end }
SOLID_VPHYSICS = 6
timer = { Simple = function(_, f) f() end }
-- a skatepark ramp model packed in the map: no physics model, but a visible mesh (a 30 degree slope)
local rise = math.tan(math.rad(30))
local function vert(x, y, z, nz) return { pos = Vector(x, y, z), normal = Vector(-0.5, 0, nz) } end
util = setmetatable({
	GetModelMeshes = function(m)
		if m ~= "models/TL_Skatepark_Ramp1.mdl" then return nil end
		-- the slope as two triangles, deliberately wound the "wrong" way (normals say which way is out)
		return { { triangles = { vert(0, -40, 0, 0.87), vert(0, 40, 0, 0.87), vert(60, 40, 60 * rise, 0.87),
			vert(0, -40, 0, 0.87), vert(60, -40, 60 * rise, 0.87), vert(60, 40, 60 * rise, 0.87) } } }
	end,
}, { __index = util })
ents = { CreateClientProp = function(m)
	local e = { IsValid = function() return true end, SetPos = function() end, SetAngles = function() end, PhysicsInit = function() end, Remove = function() end }
	function e:GetPhysicsObject() return { IsValid = function() return false end } end
	function e:GetModelBounds() return Vector(0, -40, 0), Vector(60, 40, 35) end
	return e
end }
skategm = { PhyHulls = nil }
function LocalPlayer() return { Alive = function() return true end, GetPos = function() return Vector() end, EyeAngles = function() return Angle() end } end
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
local none = S.Hulls("models/TL_Skatepark_Ramp1.mdl")
print("no physics model: not solid by default (players walk through it too):", #none == 0 and "OK" or "<-- WRONG")
cv.skategm_solid_no_physics = "1"
local hulls, isMesh = S.Hulls("models/TL_Skatepark_Ramp1.mdl")
cv.skategm_solid_no_physics = "0"
print("asked for (skategm_solid_no_physics 1): its visible mesh, not a box:", isMesh and #hulls == 1 and #hulls[1] == 18 and "OK" or "<-- WRONG")
local f = hulls[1]
local ok = true
for i = 1, 18, 9 do
	local a, b, c = Vector(f[i], f[i + 1], f[i + 2]), Vector(f[i + 3], f[i + 4], f[i + 5]), Vector(f[i + 6], f[i + 7], f[i + 8])
	if (b - a):Cross(c - a).z <= 0 then ok = false end
end
print("its triangles face out (up the slope), as the model's normals say:", ok and "OK" or "<-- WRONG")

-- the smoothing presets (Settings > Advanced on the controller) and the config file
-- the config file (garrysmod/data/skategm/config.txt), in memory
local files = {}
file = { Exists = function(n) return files[n] ~= nil end, Read = function(n) return files[n] end, Write = function(n, t) files[n] = t end, CreateDir = function() end }
function GetConVar(n) if cv[n] == nil then return nil end return { GetString = function() return cv[n] end } end
local S = SkateGM
S.ApplyPreset(3)
print("Strong preset sets all three:", cv.skategm_smooth == "2" and cv.skategm_smooth_creases == "1" and cv.skategm_smooth_steps == "12" and "OK" or "<-- WRONG")
print("... and the config file follows:", (files["skategm/config.txt"] or ""):find("smooth_steps%s*=%s*12") and "OK" or "<-- WRONG")
S.ApplyPreset(1)
print("None preset sets all three:", cv.skategm_smooth == "0" and cv.skategm_smooth_creases == "0" and cv.skategm_smooth_steps == "0" and "OK" or "<-- WRONG")
local text = files["skategm/config.txt"]
local values = S.ParseConfig(text)
print("every advanced setting is in the file, with a note", values.data and values.world_scale and values.collision_style and values.boost_amount and text:find("# how big the map is") and "OK" or "<-- WRONG")
-- edit the file by hand, reload
files["skategm/config.txt"] = text:gsub("world_scale%s*=%s*[%d%.]+", "world_scale = 0.75"):gsub("smooth_steps%s*=%s*%d+", "smooth_steps=4   # my own note")
local said
S.LoadConfig()
print("editing the file and reloading applies it (notes and spacing don't matter)", cv.skategm_world_scale == "0.75" and cv.skategm_smooth_steps == "4" and "OK" or "<-- WRONG")
local v2, unknown = S.ParseConfig("# a note\nnot_a_setting = 3\nsmooth = 2\n")
print("unknown names are reported, not applied", #unknown == 1 and unknown[1] == "not_a_setting" and v2.smooth == "2" and "OK" or "<-- WRONG")
files["skategm/config.txt"] = nil
S.LoadConfig()
print("no file yet: it's written from the current settings", files["skategm/config.txt"] and S.ParseConfig(files["skategm/config.txt"]).world_scale == "0.75" and "OK" or "<-- WRONG")
local dataLine = S.ParseConfig("data = D:/Games/Skate 3 data/assets   # mine\n").data
print("a data folder with spaces in it is read whole", dataLine == "D:/Games/Skate 3 data/assets" and "OK" or "<-- WRONG")
-- (back to what the None preset set: the checks below expect it)
cv.skategm_world_scale, cv.skategm_smooth, cv.skategm_smooth_creases, cv.skategm_smooth_steps = "1", "0", "0", "0"

-- switching on passes the separate settings; any change reloads, no change reuses
local loads = {}
skategm = { Poll = function() return { status = loads[1] and "ready" or "idle" } end,
	Load = function(...) loads[#loads + 1] = { ... } return true end, Stop = function() end, Activate = function() end }
game = { GetMap = function() return "gm_skatepark" end }
file = setmetatable({ Open = function() return nil end, Read = function() return nil end }, { __index = function() return function() end end })
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
S.phase = "off"
cmds["skategm_toggle"]()
local a = loads[1] or {}
print("load passes smoothing, creases and ledge height:", a[8] == 0 and a[9] == 0 and a[10] == 0 and "OK" or ("<-- WRONG " .. tostring(a[8]) .. "," .. tostring(a[9]) .. "," .. tostring(a[10])))
S.phase = "off"
cmds["skategm_toggle"]()
print("nothing changed: the loaded map is reused:", #loads == 1 and "OK" or "<-- WRONG (" .. #loads .. " loads)")
S.phase = "off"
cv.skategm_smooth_steps = "6"
cmds["skategm_toggle"]()
print("a setting changed: loads again with it:", #loads == 2 and loads[2][10] == 6 and "OK" or "<-- WRONG")
