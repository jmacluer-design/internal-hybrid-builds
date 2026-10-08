dofile("gmock.lua")
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
function IsValid(x) if type(x) == "table" and x.IsValid then return x:IsValid() end return x ~= nil end
function CreateClientConVar(n, d) return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetInt = function() return 0 end, GetString = function() return d end } end
MsgC = function() end chat = { AddText = function() end } function LocalPlayer() return {} end
SOLID_NONE, SOLID_BSP, SOLID_BBOX, SOLID_OBB, SOLID_OBB_YAW, SOLID_VPHYSICS = 0, 1, 2, 3, 4, 6
FSOLID_NOT_SOLID, FSOLID_TRIGGER = 4, 8
local function ent(mdl, solid)
	return { IsValid = function() return true end, IsPlayer = function() return false end, IsNPC = function() return false end, IsWeapon = function() return false end,
		GetClass = function() return "prop_dynamic" end, GetSolid = function() return solid end, GetSolidFlags = function() return 0 end,
		GetCollisionGroup = function() return 0 end, GetModel = function() return mdl end, GetPos = function() return Vector(10, 0, 0) end, GetAngles = function() return Angle() end }
end
ents = { FindInSphere = function() return { ent("models/car.mdl", 2), ent("models/crate.mdl", 6) } end }
player = { GetAll = function() return {} end }
local sentList
skategm = { SetEntities = function(l) sentList = l end }
function RealTime() return 0 end
string.EndsWith = function(s, e) return e == "" or string.sub(s, -#e) == e end
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
SkateGM.test.FeedEntities(Vector())
local names = {}
for _, e in ipairs(sentList or {}) do names[#names + 1] = e[1] end
print("entity with box solidity is sent as its box, a physics one as itself: " .. table.concat(names, ", "),
	names[1] == "models/car.mdl#bbox" and names[2] == "models/crate.mdl" and "OK" or "<-- WRONG")
