dofile("gmock.lua")
do local mt = getmetatable(Vector(0, 0, 0)) local idx = type(mt.__index) == "table" and mt.__index or mt idx.Distance = idx.Distance or function(a, b) return (a - b):Length() end end
local sent = {}
util = setmetatable({ TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
net = { Start = function() end, WriteString = function(t) sent[#sent + 1] = t end, SendToServer = function() end, Receive = function() end }
local hooks = {}
hook = { Add = function(n, id, f) hooks[n] = f end }
concommand = { Add = function() end }
surface = setmetatable({ CreateFont = function() end }, { __index = function() return function() end end })
function CreateClientConVar(n, d) return { GetInt = function() return tonumber(d) end, GetBool = function() return d == "1" end } end
function ScrH() return 1080 end
function LocalPlayer() return { EntIndex = function() return 1 end, GetPos = function() return Vector(0, 0, 0) end, EyeAngles = function() return { y = 90 } end } end
local skating, started, collision, pos, teleports = false, 0, "unset", Vector(0, 0, 0), {}
SkateGM = { API = {
	StartSkating = function() started = started + 1 skating = true end, IsSkating = function() return skating end,
	TeleportTo = function(p, yaw) teleports[#teleports + 1] = { p, yaw } end, SetPlayerCollision = function(on) collision = on end,
	SkaterPos = function() return skating and pos or nil end, Say = function() end,
} }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_race/sh_race.lua")
dofile("../../addon/skategm/lua/skategm_race/cl_race.lua")
local C = RACE.client
local function check(label, ok) print(string.format("%-66s %s", label, ok and "OK" or "<-- WRONG")) end
local base = { host = 1, start = { 0, 0, 0 }, yaw = 90, finish = { 0, 3000, 0 }, radius = 150, count = 2,
	players = { { ent = 1, name = "Me", slot = 1 }, { ent = 2, name = "Bob", slot = 2 } } }
local function state(phase, extra) local t = {} for k, v in pairs(base) do t[k] = v end t.phase = phase for k, v in pairs(extra or {}) do t[k] = v end return t end
C.OnState(state("lobby"), 0)
check("joined: straight into Skate 3 mode, to be loaded in time", started == 1)
check("in the lobby, player collision is my own setting", collision == nil)
base.players[1].racing, base.players[2].racing = true, true
C.OnState(state("countdown", { timeLeft = 5 }), 2)
check("countdown: other skaters stop being solid to me", collision == false)
C.Think(2.0)
local slot = teleports[#teleports]
check("held exactly on the start (everyone the same spot), facing the course", slot and slot[2] == 90 and slot[1].x == 0 and slot[1].y == 0)
C.OnState(state("racing", { timeLeft = 180, elapsed = 0 }), 5)
C.Think(5.0)
local n = #sent
pos = Vector(0, 1500, 0)
C.Think(8)
check("halfway there: nothing sent", #sent == n)
pos = Vector(0, 2900, 0)
C.Think(12)
check("inside the finish: finished is sent", sent[#sent].cmd == "finished")
C.Think(12.1)
check("only once", #sent == n + 1)
C.OnState(state("results"), 20)
check("results: still not solid (everyone's milling about the finish)", collision == false)
C.OnState(state("lobby"), 32)
check("back in the lobby: my own collision setting again", collision == nil)
C.OnState({ phase = "idle" }, 40)
check("race closed: nothing overridden", collision == nil)
local quads, dir = C.ArrowShape(Vector(0, 0, 50), Vector(0, 1000, 0))
check("the arrow above the skater points at the finish", quads and dir.y > 0.99 and quads[2][2].y > quads[1][2].y)
check("... level, whatever the height difference", quads and math.abs(quads[2][2].z - 50) < 1e-6)
check("the beacon gets wider with distance, so it stays visible far away", C.BeaconWidth(100) == 40 and C.BeaconWidth(10000) > 100)
