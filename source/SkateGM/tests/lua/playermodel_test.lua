dofile("gmock.lua")
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end, Call = function() end }
util = setmetatable({ AddNetworkString = function() end }, { __index = util })
local receivers = {}
net = setmetatable({ Receive = function(n, f) receivers[n] = f end }, { __index = function() return function() end end })
concommand = { Add = function() end }
CreateConVar = function() return { GetBool = function() return true end, GetInt = function() return 1 end } end
FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED, FCVAR_SERVER_CAN_EXECUTE = 128, 256, 8192, 268435456
function IsValid(x) return x ~= nil end
SERVER = true
local ran = 0
player_manager = { RunClass = function(ply, fn) if fn == "SetModel" then ran = ran + 1 ply.model = ply.wants end end }
dofile("../../addon/skategm/lua/autorun/server/skategm_sv.lua")
local function check(label, ok) print(string.format("%-66s %s", label, ok and "OK" or "<-- WRONG")) end
local colour
local ply = { SkateGM = true, wants = "models/player/kleiner.mdl", GetInfo = function(_, k) return k == "cl_playercolor" and "0.1 0.2 0.3" or "" end,
	SetPlayerColor = function(_, v) colour = v end }
check("the server listens for model changes", receivers.skategm_model ~= nil)
check("a skater who changes model gets it right away", SkateGM.ApplyPlayerModel(ply, 10) and ply.model == "models/player/kleiner.mdl")
check("  and their player colour", colour and math.abs(colour.y - 0.2) < 1e-6)
check("asking again straight away: held back", not SkateGM.ApplyPlayerModel(ply, 10.2) and ran == 1)
check("half a second later: applied", SkateGM.ApplyPlayerModel(ply, 10.6) and ran == 2)
check("not skating: left to the game", not SkateGM.ApplyPlayerModel({ SkateGM = false }, 20))

local src = io.open("../../addon/skategm/lua/autorun/client/skategm_cl.lua"):read("*a")
for _, name in ipairs({ "cl_playermodel", "cl_playerskin", "cl_playerbodygroups", "cl_playercolor" }) do
	check("the client watches " .. name, src:find('"' .. name .. '"', 1, true) ~= nil)
end
check("the skater copies skin and bodygroups while skating", src:find("e:SetSkin(ply:GetSkin())", 1, true) ~= nil)
