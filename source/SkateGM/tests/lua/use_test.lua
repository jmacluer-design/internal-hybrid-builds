dofile("gmock.lua")
do local mt = getmetatable(Vector(0, 0, 0)) local idx = type(mt.__index) == "table" and mt.__index or mt
	idx.Distance = idx.Distance or function(a, b) return (a - b):Length() end end
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
util = setmetatable({ AddNetworkString = function() end }, { __index = util })
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
CreateConVar = function() return { GetBool = function() return true end, GetInt = function() return 1 end } end
FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED, FCVAR_SERVER_CAN_EXECUTE = 128, 256, 8192, 268435456
function IsValid(x) return x ~= nil end
MASK_SOLID, USE_ON = 1, 1
SERVER = true
local used
local door = { GetClass = function() return "prop_door_rotating" end, IsPlayer = function() return false end, IsWorld = function() return false end, Use = function(self, a, c, t, v) used = { a, t } end }
local traced
util.TraceLine = function(t) traced = t return { Entity = ((t.endpos - t.start):Length() > 50) and door or nil } end
dofile("../../addon/skategm/lua/autorun/server/skategm_sv.lua")
local ply = { SkateGM = true, SkateGMHips = Vector(0, 0, 36) }
local function check(label, ok) print(string.format("%-66s %s", label, ok and "OK" or "<-- WRONG")) end
SkateGM.UseFrom(ply, Vector(0, 0, 64), Vector(1, 0, 0))
check("a door in front of my skater's head: used, by me", used and used[1] == ply and used[2] == USE_ON)
check("  looking 96 units ahead", traced and math.abs((traced.endpos - traced.start):Length() - 96) < 1e-3)
used = nil
SkateGM.UseFrom(ply, Vector(2000, 0, 64), Vector(1, 0, 0))
check("from far away from where my skater is: refused", used == nil)
used = nil
SkateGM.UseFrom({ SkateGM = false, SkateGMHips = Vector(0, 0, 36) }, Vector(0, 0, 64), Vector(1, 0, 0))
check("not skating: refused (E works as normal then)", used == nil)
