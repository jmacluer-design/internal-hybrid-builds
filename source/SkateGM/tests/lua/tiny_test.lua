dofile("gmock.lua")
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
function RealTime() return 0 end
function IsValid(x) if type(x) == "table" and x.IsValid then return x:IsValid() end return x ~= nil end
local tinySolid = "0"
function CreateClientConVar(n, d)
	return { GetBool = function() if n == "skategm_tiny_props_solid" then return tinySolid == "1" end return d == "1" end,
		GetFloat = function() return tonumber(d) or 0 end, GetInt = function() return tonumber(d) or 0 end, GetString = function() return d end }
end
MsgC = function() end chat = { AddText = function() end }
function LocalPlayer() return {} end
SOLID_VPHYSICS = 6
local sizes = { ["models/props_junk/popcan01a.mdl"] = { 5, 5, 10 }, ["models/props_junk/wood_crate001a.mdl"] = { 38, 38, 38 },
	["models/hunter/plates/plate1x1.mdl"] = { 47, 47, 3 } }
util = { IsValidModel = function(m) return sizes[m] ~= nil end }
ents = { CreateClientProp = function(m)
	local sz = sizes[m]
	local e = { IsValid = function() return true end, SetPos = function() end, SetAngles = function() end, PhysicsInit = function() end, Remove = function() end }
	function e:GetPhysicsObject()
		local hx, hy, hz = sz[1] / 2, sz[2] / 2, sz[3]
		local verts = {}
		for _, p in ipairs({ { -hx, -hy, 0 }, { hx, -hy, 0 }, { hx, hy, hz }, { -hx, hy, 0 }, { hx, hy, 0 }, { -hx, -hy, hz } }) do verts[#verts + 1] = { pos = Vector(p[1], p[2], p[3]) } end
		return { IsValid = function() return true end, GetMeshConvexes = function() return { verts } end }
	end
	return e
end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
local function solid(m) return #S.Hulls(m) > 0 end
print("soda can (5 x 5 x 10) left out:", not solid("models/props_junk/popcan01a.mdl") and "OK" or "<-- WRONG")
print("crate (38 x 38 x 38) stays solid:", solid("models/props_junk/wood_crate001a.mdl") and "OK" or "<-- WRONG")
print("PHX plate (47 x 47 x 3) stays solid:", solid("models/hunter/plates/plate1x1.mdl") and "OK" or "<-- WRONG")
tinySolid = "1"
print("skategm_tiny_props_solid 1 makes the can solid:", solid("models/props_junk/popcan01a.mdl") and "OK" or "<-- WRONG")
