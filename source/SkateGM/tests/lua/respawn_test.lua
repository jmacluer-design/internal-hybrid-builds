dofile("gmock.lua")
local function check(label, ok) print(string.format("%-66s %s", label, ok and "OK" or "<-- WRONG")) end
local hooks, receivers, sent = {}, {}, {}
local veto
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end, Run = function(n, ...) if n == "SkateGMCanRespawn" then return veto end end }
util = setmetatable({ AddNetworkString = function() end }, { __index = util })
local out
net = setmetatable({
	Receive = function(n, f) receivers[n] = f end,
	Start = function(n) out = { name = n, vals = {} } end,
	WriteFloat = function(v) out.vals[#out.vals + 1] = v end,
	Send = function(ply) out.to = ply sent[#sent + 1] = out end,
}, { __index = function() return function() end end })
concommand = { Add = function() end }
CreateConVar = function() return { GetBool = function() return true end, GetInt = function() return 1 end } end
FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED, FCVAR_SERVER_CAN_EXECUTE = 128, 256, 8192, 268435456
function IsValid(x) return x ~= nil and x ~= false end
SERVER = true
local clock = 100
function SysTime() return clock end
local spawn = { GetPos = function() return Vector(-500, 300, 64) end, GetAngles = function() return Angle(0, 90, 0) end }
GAMEMODE = { PlayerSelectSpawn = function(self, ply, transition) return spawn end }
dofile("../../addon/skategm/lua/autorun/server/skategm_sv.lua")
local ply = { SkateGM = true }
receivers.skategm_respawn(0, ply)
local r = sent[#sent]
check("LB + X: the server answers with the gamemode's spawn point", r and r.name == "skategm_respawn" and r.to == ply and r.vals[1] == -500 and r.vals[2] == 300 and r.vals[3] == 64 and r.vals[4] == 90)
receivers.skategm_respawn(0, ply)
check("... at most once a second", #sent == 1)
clock = clock + 2
veto = false
receivers.skategm_respawn(0, ply)
check("a game mode can say no (SkateGMCanRespawn)", #sent == 1)
veto = nil
GAMEMODE = { PlayerSelectSpawn = function() return nil end }
ents = { FindByClass = function(c) if c == "info_player_start" then return { spawn } end return {} end }
clock = clock + 2
receivers.skategm_respawn(0, ply)
check("no gamemode pick: any info_player_start", #sent == 2 and sent[2].vals[1] == -500)
