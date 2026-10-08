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
function LerpVector(f, a, b) return a + (b - a) * f end
local ME = { EntIndex = function() return 2 end, GetPos = function() return Vector(0, 0, 0) end, EyeAngles = function() return { y = 0 } end, Nick = function() return "Me" end }
local ANN = { EntIndex = function() return 1 end, Nick = function() return "Ann" end }
local BEN = { EntIndex = function() return 3 end, Nick = function() return "Ben" end }
function LocalPlayer() return ME end
function Entity(i) return ({ [1] = ANN, [2] = ME, [3] = BEN })[i] end
local api = { skating = true, poses = {}, starts = 0, score = 100, pad = 0, frozen = false, blocked = false, clips = {} }
SkateGM = { API = {
	IsSkating = function() return api.skating end, CanSkate = function() return true end,
	StartSkating = function() api.starts = api.starts + 1 end,
	TeleportTo = function() return true end, Freeze = function(on) api.frozen = on end,
	SkaterPos = function() return api.poses[ME] and api.poses[ME].HIPS end,
	PoseOf = function(ply) return api.poses[ply] end,
	State = function() return "PhysicsGround" end,
	Score = function() return api.score end,
	Pad = function() return { buttons = api.pad } end,
	BlockInput = function(on) api.blocked = on end,
	SetView = function(fn) api.view = fn end,
	PlayClip = function(id, ply, clip) api.clips[id] = { ply = ply, clip = clip } return { ghostOf = ply } end,
	StopClip = function(id) api.clips[id] = nil end,
	SetPlayerCollision = function() end,
	Say = function() end,
} }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_royale/sh_royale.lua")
dofile("../../addon/skategm/lua/skategm_royale/cl_royale.lua")
local C = ROYALE.client
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
local function players(extra)
	local list = { { ent = 1, name = "Ann", inMatch = true }, { ent = 2, name = "Me", inMatch = true }, { ent = 3, name = "Ben", inMatch = true } }
	for _, p in ipairs(list) do for k, v in pairs((extra or {})[p.ent] or {}) do p[k] = v end end
	return list
end
local function st(phase, extra)
	local t = { phase = phase, host = 1, start = { 0, 0, 0 }, yaw = 0, runTime = 20, round = 1, timeLeft = 20, players = players() }
	for k, v in pairs(extra or {}) do t[k] = v end
	return t
end
local function pose(x) return { HIPS = Vector(x, 0, 40), TRUCK_FRONT = Vector(x + 7, 0, 3) } end

C.OnState(st("countdown"), 1)
api.poses[ME], api.poses[ANN], api.poses[BEN] = pose(0), pose(100), pose(200)
C.OnState(st("running"), 2)
for i = 0, 40 do
	local now = 2 + i * 0.05
	api.poses[ME], api.poses[ANN] = pose(i * 5), pose(100 + i * 5)
	C.Think(now)
end
check("every runner's run is recorded, mine and the others'", #C.clips[2] >= 20 and #C.clips[1] >= 20 and #C.clips[3] >= 20)
check("... as copies, moving as they moved", C.clips[1][1].P.HIPS.x == 100 and C.clips[1][#C.clips[1]].P.HIPS.x > 250)
check("... timed from the start of the run", C.clips[2][1].t < 0.06 and C.clips[2][#C.clips[2]].t > 1.9)
local before = C.clips[1][1].P.HIPS.x
C.OnFrameShift(Vector(20000, 0, 0))
check("an infinite map's frame shift moves the recorded runs with it", C.clips[1][1].P.HIPS.x == before - 20000)
C.OnFrameShift(Vector(-20000, 0, 0))
api.score = 1600
sentCmds = {}
C.OnState(st("replays", { replay = { ent = 1, name = "Ann", index = 1, total = 3, at = 0 } }), 30)
check("the run ends: my score for it goes to the server", sentCmds[1] and sentCmds[1].cmd == "score" and sentCmds[1].score == 1500)
check("replays: Ann's recorded run plays, as a ghost of her", api.clips.royale and api.clips.royale.ply == ANN and api.clips.royale.clip == C.clips[1])
check("... the camera follows it", C.watch and C.watch.target.ghostOf == ANN and api.view ~= nil)
check("... and my skater waits", api.frozen == true)
C.OnState(st("replays", { replay = { ent = 2, name = "Me", index = 2, total = 3, at = 0 } }), 52)
check("next replay: my own run", api.clips.royale.ply == ME)
C.OnState(st("voting", { timeLeft = 20 }), 80)
check("voting: replays stop, the camera's mine again", api.clips.royale == nil and api.view == nil and C.watch == nil)
check("... the D-pad votes, not skates", api.blocked == true)
local choices = C.Choices(C.state)
check("I can vote for everyone still in but me", #choices == 2 and choices[1].name == "Ann" and choices[2].name == "Ben")
api.pad = C.PAD.DOWN C.Think(80.1) api.pad = 0 C.Think(80.2)
api.pad = C.PAD.A C.Think(80.3) api.pad = 0 C.Think(80.4)
check("D-pad down, A: a vote for Ben", sentCmds[#sentCmds].cmd == "vote" and sentCmds[#sentCmds].target == 3 and C.myVote == 3)
C.Chat("!royale vote 1")
check("or in chat: !royale vote 1", ran[#ran] == "skategm_royale_vote 1")
C.VoteNumber(1)
check("... a vote for Ann", sentCmds[#sentCmds].target == 1)
C.OnState(st("out", { knocked = { name = "Ben", ent = 3 }, players = players({ [3] = { out = true } }) }), 100)
check("the count's in: input back", api.blocked == false)
C.OnState(st("countdown", { players = players({ [2] = { out = true } }) }), 110)
C.OnState(st("running", { players = players({ [2] = { out = true } }) }), 113)
check("knocked out: I watch the runners while they run", C.watch and (C.watch.target == ANN or C.watch.target == BEN) and api.frozen == true)
local first = C.watch.target
api.pad = C.PAD.RIGHT C.Think(113.1) api.pad = 0 C.Think(113.2)
check("... D-pad right: the next runner", C.watch.target ~= first)
C.OnState(st("lobby", { players = players() }), 140)
check("back in the lobby: free to skate again", api.frozen == false and C.watch == nil)
