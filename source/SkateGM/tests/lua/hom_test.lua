dofile("gmock.lua")
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
SERVER = true
local chats = {}
util = setmetatable({ AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
local states = {}
net = { Start = function() end, WriteString = function(t) states[#states + 1] = t end, Broadcast = function() end, Receive = function() end, ReadString = function() end, Send = function() end, SendToServer = function() end }
hook = { Add = function() end, Run = function() end }
timer = { Simple = function(_, f) f() end }
PrintMessage = function(_, t) chats[#chats + 1] = t end
HUD_PRINTTALK = 3
function IsValid(x) return x ~= nil end
local skating = {}
SkateGM = { API = { Allowed = function() return true end, IsSkating = function(p) return skating[p] ~= false end } }
local function Player(id, name)
	local p = { id = id, name = name }
	function p:EntIndex() return self.id end
	function p:Nick() return self.name end
	function p:IsAdmin() return false end
	function p:ChatPrint(t) chats[#chats + 1] = t end
	return p
end
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_hom/sh_hom.lua")
dofile("../../addon/skategm/lua/skategm_hom/sv_hom.lua")

local function body(off)
	local P = {}
	for _, seg in ipairs(HOM.SKELETON) do
		for _, b in ipairs(seg) do P[b] = Vector(off.x, off.y, off.z + #b) end
	end
	return P
end
local T = HOM.NewTracker()
local tick, now = 0, 0
local function feed(P, state, ground)
	tick, now = tick + 1, now + 1 / 60
	return T:Feed(P, tick, state, ground, now)
end
local pos = Vector(0, 0, 0)
for _ = 1, 10 do pos = pos + Vector(20, 0, 0) feed(body(pos), "PhysicsGround") end
for _ = 1, 60 do pos = pos + Vector(20, 0, 0) feed(body(pos), "PhysicsAir") end
check("riding and flying: no bail yet", T.phase == "riding")
pos = pos + Vector(20, 0, 0)
local events = feed(body(pos), "WipeoutGround")
check("Wipeout starts the bail, counting the second of air before it", events[1] and events[1].kind == "start" and math.abs(T.air - 1) < 0.05)
local all = {}
local P = body(pos)
for _ = 1, 3 do
	pos = pos + Vector(20, 0, 0)
	P = body(pos)
	for _, e in ipairs(feed(P, "WipeoutGround", 60)) do all[#all + 1] = e end
end
pos = pos + Vector(20, 0, 0)
local slam = body(pos)
slam.LEFTUPLEG = P.LEFTUPLEG
for _, e in ipairs(feed(slam, "WipeoutGround", 60)) do all[#all + 1] = e end
local broke, femur
for _, e in ipairs(all) do
	if e.kind == "break" and e.part == "lfemur" then broke = true end
	if e.kind == "injury" and e.part == "lfemur" then femur = e.level end
end
check("a bone stopped dead from 1200 u/s: the femur breaks", femur and femur >= HOM.BREAK_LEVEL and broke)

for _, sp in ipairs({ 15, 10, 5, 0 }) do
	pos = pos + Vector(sp, 0, 0)
	for _, e in ipairs(feed(body(pos), "WipeoutGround", 0)) do all[#all + 1] = e end
end
for _ = 1, 240 do feed(body(pos), "WipeoutGround", 0) end
check("lying still in the wipeout: the bail goes on (as in Skate)", T.phase == "bail")
pos = pos + Vector(0, 0, 0)
local P2 = body(pos)
P2.HEAD = P2.HEAD + Vector(0, 0, 10)
feed(P2, "WipeoutGround", 0)
feed(body(pos), "WipeoutGround", 0)
check("... and still takes damage, hit after hit", (T.damage.skull or 0) > 0)
for _ = 1, 30 do feed(body(pos), "Teleporting", 0) end
check("the engine ends the wipeout: the bail is over", T.phase == "done")
check("... the other bones slowed down gently: no injury to them", T.levels.rfemur == nil and T.levels.pelvis == nil)
local r = T:Result()
local femur
for _, inj in ipairs(r.injuries) do if inj.part == "lfemur" then femur = inj end end
check("the result: injuries (worst first), air (before and during the bail), points", femur and r.injuries[1].level >= femur.level and r.air >= 1.04 and r.score > HOM.LEVELS[r.injuries[1].level].bonus)
-- as in the game: ONE pose table, its bones replaced each frame (the add-on
-- reuses S.P) - the tracker must keep its own copy of the last frame
do
	local T2 = HOM.NewTracker()
	local live = {}
	local tk, tnow = 0, 0
	local function frame(off, state, stopHead)
		local b = body(off)
		for k, v in pairs(b) do live[k] = v end
		if stopHead then live.HEAD = stopHead end
		tk, tnow = tk + 1, tnow + 1 / 60
		return T2:Feed(live, tk, state, 60, tnow)
	end
	local p0 = Vector(0, 0, 0)
	for _ = 1, 5 do p0 = p0 + Vector(0, 0, -25) frame(p0, "PhysicsAir") end
	frame(p0, "WipeoutGround")
	for _ = 1, 3 do p0 = p0 + Vector(0, 0, -25) frame(p0, "WipeoutGround") end
	-- the head slams into the ground: stops dead from 1500 u/s
	frame(p0 + Vector(0, 0, -25), "WipeoutGround", live.HEAD)
	check("one pose table updated in place (as the game does): a head-first slam still hurts the skull", (T2.levels.skull or 0) >= 1 and (T2.damage.skull or 0) > 0)
end
-- the engine puts the skater back up at the end (a teleport): no damage from that
do
	local T3 = HOM.NewTracker()
	local tk, tnow = 0, 0
	local function feed3(off, state) tk, tnow = tk + 1, tnow + 1 / 60 return T3:Feed(body(off), tk, state, 0, tnow) end
	local p = Vector(0, 0, 0)
	feed3(p, "PhysicsGround")
	for _ = 1, 10 do feed3(p, "WipeoutGround") end
	local before = T3.total
	feed3(Vector(3000, 0, 500), "WipeoutGround")
	feed3(Vector(3000, 0, 500), "WipeoutGround")
	check("a teleport during the wipeout (every bone 3000 units in a tick) isn't a hit", T3.total == before)
	feed3(Vector(0, 0, 0), "Teleporting")
	feed3(Vector(0, 0, 0), "Teleporting")
	check("... nor is moving about once it's over (out of the wipeout)", T3.total == before and next(T3.levels) == nil)
end
check("levels go up with damage", HOM.LevelFor(5) == 0 and HOM.LevelFor(12) == 1 and HOM.LevelFor(30) == 2 and HOM.LevelFor(50) == 3 and HOM.LevelFor(100) == 4)
local s1 = HOM.Score(10, {}, 0)
local s2 = HOM.Score(10, {}, 2)
check("every second in the air is points", s2 - s1 == 2 * HOM.POINTS_PER_AIR_SECOND)

local G = HOM.session
local host, bob = Player(1, "Host"), Player(2, "Bob")
local t = 100
HOM.Command(host, { cmd = "create", x = 10, y = 20, z = 0, yaw = 90, turn = 40, rounds = 1, canSkate = true }, t)
HOM.Command(bob, { cmd = "join", canSkate = true }, t)
check("created at the spot; Bob joins", G.phase == "lobby" and G.spot[1] == 10 and #G.players == 2)
HOM.Command(host, { cmd = "begin" }, t)
check("start: the first player's turn (getting to the spot)", G.phase == "prep" and G.active == host)
HOM.Command(bob, { cmd = "ready" }, t + 1)
check("only the active player can say they're ready", G.phase == "prep")
HOM.Command(host, { cmd = "ready" }, t + 1)
HOM.Think(t + 4.1)
check("countdown, then the turn", G.phase == "turn")
HOM.Command(host, { cmd = "bailing" }, t + 5)
HOM.Think(t + 4.1 + 41)
check("bailing in time: the turn's clock no longer ends it, the bail does", G.phase == "turn" and G.bailing == true)
HOM.Command(host, { cmd = "injury", part = "lfemur", level = 3, score = 2500 }, t + 6)
check("injuries show live to everyone", #G.live.injuries == 1 and G.live.score == 2500)
HOM.Command(host, { cmd = "injury", part = "notabone", level = 3 }, t + 6.1)
check("... nonsense parts are ignored", #G.live.injuries == 1)
HOM.Command(host, { cmd = "result", score = 4200, damage = 80, air = 1.2, bonus = 1500, injuries = { { part = "lfemur", level = 3 } } }, t + 8)
check("the bail's result: the card for everyone", G.phase == "between" and G.last.score == 4200 and G.last.injuries[1].part == "lfemur")
HOM.Think(t + 8 + HOM.BETWEEN + 0.1)
check("next player's turn", G.phase == "prep" and G.active == bob)
HOM.Command(bob, { cmd = "ready" }, t + 20)
HOM.Think(t + 23.1)
HOM.Think(t + 23.2 + 40)
check("no bail in time: zero, turn over", G.phase == "between" and G.last.score == 0)
HOM.Think(t + 23.3 + 40 + HOM.BETWEEN)
check("one round each: the best bail wins", G.phase == "final" and G.winner and G.winner.name == "Host" and G.winner.score == 4200)

SERVER, CLIENT = nil, nil
SKATEGM_MODES = nil
local sent = {}
net.WriteString = function(x) sent[#sent + 1] = x end
local ME = { EntIndex = function() return 1 end, EyeAngles = function() return Angle(0, 0, 0) end }
function LocalPlayer() return ME end
function Entity(i) return i == 1 and ME or nil end
local api = { skating = true, teleports = {}, scale = 1, tick = 0, state = "PhysicsGround", P = body(Vector(0, 0, 0)) }
SkateGM = { API = {
	IsSkating = function() return api.skating end, IsLoading = function() return false end, CanSkate = function() return true end,
	StartSkating = function() end, StopSkating = function() end,
	TeleportTo = function(p, y) api.teleports[#api.teleports + 1] = p return true end,
	Freeze = function(on) api.frozen = on end,
	SetTimeScale = function(s) api.scale = s end,
	Tick = function() return api.tick end, State = function() return api.state end,
	PoseOf = function() return api.P end, Say = function() end,
} }
util.TraceLine = function(tr) return { Hit = true, HitPos = Vector(tr.start.x, tr.start.y, 0) } end
MASK_SOLID_BRUSHONLY = 1
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_hom/sh_hom.lua")
dofile("../../addon/skategm/lua/skategm_hom/cl_hom.lua")
local C = HOM.client
local function stateOf(phase) return { phase = phase, host = 1, active = 1, spot = { 10, 20, 0 }, yaw = 90, players = { { ent = 1, name = "Me" } } } end
C.OnState(stateOf("prep"), 1)
C.Think(1)
check("my turn: teleported to the spot and frozen there, ready sent", api.teleports[1] and api.teleports[1].x == 10 and api.frozen == true and sent[#sent].cmd == "ready")
C.OnState(stateOf("countdown"), 2)
C.OnState(stateOf("turn"), 5)
C.Think(5)
check("the turn starts: free to skate", api.frozen == false)
local cpos = Vector(0, 0, 0)
local function step(now, state, P)
	api.tick, api.state, api.P = api.tick + 1, state, P
	C.Think(now)
end
for k = 1, 5 do cpos = cpos + Vector(20, 0, 0) step(5 + k / 60, "WipeoutGround", body(cpos)) end
local hit = body(cpos)
hit.RIGHTLEG = body(cpos - Vector(20, 0, 0)).RIGHTLEG
step(5.2, "WipeoutGround", hit)
check("a bone breaks: slow motion and the x-ray", api.scale == HOM.SLOWMO_SCALE and C.xrayUntil and C.xrayUntil > 5.2)
check("... and the injury goes to the server", (function() for _, m in ipairs(sent) do if m.cmd == "injury" and m.part == "rtibia" then return true end end end)())
C.Think(5.2 + HOM.SLOWMO_TIME + 0.05)
check("slow motion ends after a moment", api.scale == 1)
for k = 1, 80 do step(6.5 + k / 60, "WipeoutGround", hit) end
check("lying still, the bail isn't over yet", C.card == nil)
for k = 1, 40 do step(8 + k / 60, "Teleporting", hit) end
local res
for _, m in ipairs(sent) do if m.cmd == "result" then res = m end end
check("the bail ends: the result card, sent once", res and res.score > 0 and C.card ~= nil)
local hasSpot = false
for _, o in ipairs(HOM.mode.hostDef.options) do if o.key == "spot" then hasSpot = true end end
check("Hall of Meat is hostable from the controller, starting where the host stands (no spot to pick)", HOM.mode.hostDef and not hasSpot)
-- "ready" again every second until the countdown (one lost used to stall the turn)
local readies = 0
for _, m in ipairs(sent) do if m.cmd == "ready" then readies = readies + 1 end end
C.OnState(stateOf("prep"), 20)
local before = readies
for k = 1, 30 do C.Think(20 + k * 0.1) end
local after = 0
for _, m in ipairs(sent) do if m.cmd == "ready" then after = after + 1 end end
check("... and my ready is said again each second until the countdown", after - before >= 2)
