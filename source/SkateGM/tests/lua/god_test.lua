dofile("gmock.lua")
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
util = setmetatable({ AddNetworkString = function() end }, { __index = util })
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
CreateConVar = function() return { GetBool = function() return true end, GetInt = function() return 1 end } end
function IsValid(x) return x ~= nil end
SERVER = true
FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED, FCVAR_SERVER_CAN_EXECUTE = 128, 256, 8192, 268435456
local ok, err = pcall(dofile, "../../addon/skategm/lua/autorun/server/skategm_sv.lua")
local f = hooks["EntityTakeDamage/skategm"]
local skater = { SkateGM = true, IsPlayer = function() return true end }
local walker = { SkateGM = false, IsPlayer = function() return true end }
print("server file loads:", ok and "OK" or ("<-- WRONG " .. tostring(err)))
print("a skater takes no damage:", f and f(skater, {}) == true and "OK" or "<-- WRONG")
print("someone not skating does:", f and f(walker, {}) == nil and "OK" or "<-- WRONG")
