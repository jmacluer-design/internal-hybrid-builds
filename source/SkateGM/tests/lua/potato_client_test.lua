dofile("gmock.lua")
local sentCmds = {}
util = setmetatable({ TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
local effects = {}
util.Effect = function(name, fx) effects[#effects + 1] = { name, fx.origin } end
function EffectData() local fx = {} function fx:SetOrigin(v) self.origin = v end return fx end
net = { Start = function() end, WriteString = function(t) sentCmds[#sentCmds + 1] = t end, SendToServer = function() end, Receive = function() end }
hook = { Add = function() end }
local cmds = {}
concommand = { Add = function(n, f) cmds[n] = f end }
local ran = {}
function RunConsoleCommand(...) ran[#ran + 1] = table.concat({ ... }, " ") end
function IsValid(x) return x ~= nil end
chat = { AddText = function() end }
local beeps = 0
surface = { PlaySound = function() beeps = beeps + 1 end }
sound = { Play = function() beeps = beeps + 1 end }
do local mt = getmetatable(Vector(0, 0, 0)) local idx = type(mt.__index) == "table" and mt.__index or mt idx.Distance = idx.Distance or function(a, b) return (a - b):Length() end end
local ME = { EntIndex = function() return 2 end, GetPos = function() return Vector(0, 0, 0) end, EyeAngles = function() return { y = 45 } end }
local ANN = { EntIndex = function() return 1 end }
local BEN = { EntIndex = function() return 3 end }
function LocalPlayer() return ME end
function Entity(i) return ({ [1] = ANN, [2] = ME, [3] = BEN })[i] end
-- the skating add-on's interface: positions of me and the others
local api = { skating = true, mine = Vector(0, 0, 40), others = {}, teleports = {}, launches = {}, starts = 0, collision = "unset" }
SkateGM = { API = {
	IsSkating = function() return api.skating end, IsLoading = function() return false end, CanSkate = function() return true end,
	StartSkating = function() api.starts = api.starts + 1 end, StopSkating = function() end,
	TeleportTo = function(p, y) api.teleports[#api.teleports + 1] = { p, y } return true end,
	Freeze = function(on) api.frozen = on end,
	SkaterPos = function() return api.mine end,
	PoseOf = function(ply) local p = api.others[ply] return p and { HIPS = p } or nil end,
	Launch = function(v) api.launches[#api.launches + 1] = v return true end,
	SetPlayerCollision = function(on) api.collision = on end,
	Say = function() end,
} }
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_potato/sh_potato.lua")
dofile("../../addon/skategm/lua/skategm_potato/cl_potato.lua")
local C = POTATO.client
local function check(label, ok) print(string.format("%-70s %s", label, ok and "OK" or "<-- WRONG")) end
local function players(extra)
	local list = { { ent = 1, name = "Ann", lives = 1, playing = true }, { ent = 2, name = "Me", lives = 1, playing = true }, { ent = 3, name = "Ben", lives = 1, playing = true } }
	for _, p in ipairs(list) do for k, v in pairs((extra or {})[p.ent] or {}) do p[k] = v end end
	return list
end
local function st(phase, extra)
	local t = { phase = phase, host = 1, start = { 0, 0, 0 }, yaw = 45, fuse = 25, lives = 1, players = players(), timeLeft = 3 }
	for k, v in pairs(extra or {}) do t[k] = v end
	return t
end

check("passing within 48 units of another skater, centre to centre", POTATO.PASS_RADIUS == 48)
check("the ticking speeds up as the fuse burns", POTATO.BeepGap(1) > 0.9 and POTATO.BeepGap(0.1) < 0.25)
api.skating = false
C.OnState(st("lobby"), 1)
check("joining switches Skate 3 mode on", api.starts == 1)
api.skating = true
C.OnState(st("countdown"), 2)
C.Think(2)
C.Think(2.5)
check("other skaters aren't solid while we play; held on the start", api.collision == false and #api.teleports == 1)
check("... frozen there, not teleported over and over", api.frozen == true)
-- I have the bomb; Ann is close, Ben far
api.others[ANN], api.others[BEN] = Vector(30, 0, 40), Vector(400, 0, 40)
C.OnState(st("playing", { holder = 2, ticking = 1, fuseLen = 20, from = 0 }), 10)
C.Think(10.2)
check("at GO: free to skate", api.frozen == false)
check("just caught it: can't pass it on yet", #sentCmds == 0)
C.Think(11.3)
local c = sentCmds[#sentCmds]
check("skating into Ann passes it to her", c and c.cmd == "pass" and c.target == 1)
local n = #sentCmds
C.Think(11.35)
check("not every frame", #sentCmds == n)
-- Ann gave it to me: no tag-back to her for a moment, Ben's fine when he's close
api.others[BEN] = Vector(0, 40, 40)
C.OnState(st("playing", { holder = 2, ticking = 0.8, fuseLen = 20, from = 1 }), 20)
C.Think(21.5)
c = sentCmds[#sentCmds]
check("no tag-back: it goes to Ben, not straight back to Ann", c.target == 3)
api.others[BEN] = Vector(400, 0, 40)
C.OnState(st("playing", { holder = 1, ticking = 0.8, fuseLen = 20, from = 3 }), 29)
C.OnState(st("playing", { holder = 2, ticking = 0.8, fuseLen = 20, from = 1 }), 30)
n = #sentCmds
C.Think(31.5)
check("... and with only Ann nearby, nothing during the no-tag-back time", #sentCmds == n)
C.OnState(st("playing", { holder = 2, ticking = 0.8, fuseLen = 20, from = 3 }), 40)
C.Think(41.5)
check("players who are out don't take it", C.PassTarget(st("playing", { holder = 2, players = players({ [1] = { out = true } }) }), 50) == nil)
-- someone else has it: I don't pass anything
C.OnState(st("playing", { holder = 1, ticking = 0.5, fuseLen = 20 }), 60)
n = #sentCmds
C.Think(62)
check("only the holder passes it", #sentCmds == n)
beeps = 0
C.Think(64) C.Think(66)
check("everyone hears it ticking", beeps >= 2)
-- the blast: on Ann - an explosion where she is, I stay put
C.OnState(st("playing", { boom = { id = 1, ent = 1, name = "Ann" } }), 70)
check("BOOM on Ann: an explosion where she is", #effects == 1 and effects[1][1] == "Explosion" and effects[1][2] == api.others[ANN])
check("... and I'm not launched", #api.launches == 0)
C.OnState(st("playing", { boom = { id = 1, ent = 1, name = "Ann" } }), 70.5)
check("the same blast isn't shown twice", #effects == 1)
C.OnState(st("playing", { boom = { id = 2, ent = 2, name = "Me" } }), 80)
check("BOOM on me: I'm launched sky-high", #api.launches == 1 and api.launches[1].z >= 20)
C.OnState(st("results", { winner = { name = "Ben" } }), 90)
check("after the game skaters are solid again", api.collision == nil)
local rows = C.Standings({ players = players({ [1] = { out = true, lives = 0 }, [3] = { lives = 2 } }) })
check("standings: still in first, most lives first, who's out last", rows[1].name == "Ben" and rows[3].name == "Ann")
check("!potato fuse 30", C.Chat("!potato fuse 30") and ran[#ran] == "skategm_potato_fuse 30")
check("other chat is left alone", C.Chat("hot potato!") == false)
cmds["skategm_potato_create"]()
c = sentCmds[#sentCmds]
check("setting up sends where I stand, which way I face, and the settings", c.cmd == "create" and c.pos and c.yaw == 45 and c.fuse and c.lives and c.canSkate)
