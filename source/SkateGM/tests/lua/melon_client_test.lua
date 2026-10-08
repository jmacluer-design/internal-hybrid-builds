dofile("gmock.lua")
local sentCmds = {}
util = setmetatable({ TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
net = { Start = function() end, WriteString = function(t) sentCmds[#sentCmds + 1] = t end, SendToServer = function() end, Receive = function() end }
hook = { Add = function() end }
concommand = { Add = function() end }
local ran = {}
function RunConsoleCommand(...) ran[#ran + 1] = table.concat({ ... }, " ") end
function IsValid(x) return x ~= nil end
chat = { AddText = function() end }
local ME = { EntIndex = function() return 2 end, GetPos = function() return Vector(0, 0, 0) end, EyeAngles = function() return { y = 45 } end }
local ANN = { EntIndex = function() return 1 end }
local MELONENT = { GetPos = function() return Vector(500, 0, 10) end }
function LocalPlayer() return ME end
function Entity(i) return ({ [1] = ANN, [2] = ME, [77] = MELONENT })[i] end
local api = { skating = true, mine = Vector(0, 0, 40), others = {}, starts = 0, collision = "unset", state = "PhysicsGround" }
SkateGM = { API = {
	IsSkating = function() return api.skating end, CanSkate = function() return true end,
	StartSkating = function() api.starts = api.starts + 1 end,
	TeleportTo = function() return true end, Freeze = function() end,
	SkaterPos = function() return api.mine end,
	PoseOf = function(ply) local p = api.others[ply] return p and { HIPS = p } or nil end,
	State = function() return api.state end,
	SetPlayerCollision = function(on) api.collision = on end,
	Say = function() end,
} }
local forced = {}
BOARD = { client = { Force = function(ply, id, opts) forced[ply] = forced[ply] or {} forced[ply][id] = opts end } }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_melon/sh_melon.lua")
dofile("../../addon/skategm/lua/skategm_melon/cl_melon.lua")
local C = MELON.client
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
local function st(phase, extra)
	local t = { phase = phase, host = 1, start = { 0, 0, 0 }, yaw = 0, area = { 0, 0, 0, 1024 }, target = 30, timeLeft = 3,
		players = { { ent = 1, name = "Ann", held = 4, playing = true }, { ent = 2, name = "Me", held = 10, playing = true } } }
	for k, v in pairs(extra or {}) do t[k] = v end
	return t
end
local function lastCmd() return sentCmds[#sentCmds] end

api.skating = false
C.OnState(st("lobby"), 1)
check("joining switches Skater mode on", api.starts == 1)
api.skating = true
C.OnState(st("playing", { melon = 77 }), 2)
check("other skaters aren't solid while playing", api.collision == false)
check("the melon far away: nothing to do", C.Want(C.state, 2) == nil)
api.mine = Vector(490, 0, 30)
check("skate through the loose melon: grab it", (C.Want(C.state, 2) or {}).cmd == "grab")
C.Think(2)
check("... sent to the server", lastCmd() and lastCmd().cmd == "grab")
C.OnState(st("playing", { melon = 77, dropper = 2, dropLock = 2 }), 3)
check("just bailed it away: can't grab it back yet", C.Want(C.state, 3.5) == nil)
check("... a moment later I can", (C.Want(C.state, 5.1) or {}).cmd == "grab")

C.OnState(st("playing", { king = 2 }), 10)
check("I'm the Melon King: my board gets the trail", forced[ME] and forced[ME].trails and forced[ME].trails.style == MELON.TRAIL.style)
check("rolling along: nothing to send", C.Want(C.state, 10.5) == nil)
api.state = "WipeoutGround"
local w = C.Want(C.state, 10.5)
check("bail: I drop it, where I am", w and w.cmd == "bail" and w.pos[1] == 490)
sentCmds = {}
C.Think(10.5)
C.nextSend = 0
C.Think(10.6)
check("... said once, not every frame", #sentCmds == 1)
api.state = "PhysicsGround"

C.OnState(st("playing", { king = 1, from = 3, kingFor = 0 }), 20)
check("Ann took it: her board has the trail, mine doesn't", forced[ANN] and forced[ANN].trails and forced[ME].trails == nil)
api.others[ANN] = Vector(500, 0, 40)
check("skating into the King right away: her grace", C.Want(C.state, 20.5) == nil)
check("after the grace: steal it", (C.Want(C.state, 20 + MELON.HOLD_GRACE + 0.1) or {}).cmd == "steal")
C.OnState(st("playing", { king = 1, from = 2, kingFor = 0 }), 30)
check("I just lost it to her: no tagging straight back", C.Want(C.state, 30 + MELON.HOLD_GRACE + 0.1) == nil)
check("... a few seconds later, yes", (C.Want(C.state, 30 + MELON.NO_TAGBACK + 0.1) or {}).cmd == "steal")

C.OnState(st("playing", { king = 1 }), 40)
local rows = C.Standings(C.state, 41)
check("standings: closest to winning first, the King's clock running", rows[1].name == "Me" and rows[2].name == "Ann" and math.abs(rows[2].left - 25) < 1e-6)
api.others[ANN] = Vector(5000, 0, 40)
rows = C.Standings(C.state, 41)
check("... stopped while the King is outside the area", math.abs(rows[2].left - 26) < 1e-6)
C.OnState(st("results", { winner = { name = "Ann" } }), 50)
check("the game's over: no more trail, skaters solid again", forced[ANN].trails == nil and api.collision == nil)
check("chat: !melon join", C.Chat("!melon join") and ran[#ran] == "skategm_melon_join")
