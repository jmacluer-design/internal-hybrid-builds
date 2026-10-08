dofile("gmock.lua")
SERVER = true
CurTime = function() return 0 end
util = setmetatable({ AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
net = { Start = function() end, WriteString = function() end, Broadcast = function() end, Receive = function() end, ReadString = function() end, Send = function() end }
hook = { Add = function() end }
timer = { Simple = function(_, f) f() end }
PrintMessage = function() end HUD_PRINTTALK = 3
function IsValid(x) return x ~= nil end
SkateGM = { API = { Allowed = function() return true end, IsSkating = function() return true end } }
local told = {}
local host = { EntIndex = function() return 1 end, UserID = function() return 1 end, Nick = function() return "Host" end, ChatPrint = function(_, t) told[#told + 1] = t end, Freeze = function() end, GetPos = function() return Vector(0, 0, 0) end, EyeAngles = function() return { y = 0 } end }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_ots/sh_ots.lua")
dofile("../../addon/skategm/lua/skategm_ots/sv_ots.lua")
local function check(label, ok) print(string.format("%-66s %s", label, ok and "OK" or "<-- WRONG")) end
OTS.Command(host, { cmd = "create", canSkate = true }, 0)
check("Own the Spot can be set up while allowed", OTS.session.phase == "lobby")
MOCK_SET_CVAR("skategm_ots_allowed", 0)
check("turned off mid-session: it ends", OTS.session.phase == "idle")
OTS.Command(host, { cmd = "create", canSkate = true }, 1)
check("and while off, it can't be set up (and says so)", OTS.session.phase == "idle" and (told[#told] or ""):find("turned off") ~= nil)
