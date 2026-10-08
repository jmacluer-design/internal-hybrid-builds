dofile("gmock.lua")
SERVER = true
CurTime = CurTime or function() return 0 end
SysTime = SysTime or function() return 0 end
local chats = {}
util = setmetatable({ AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
local states = {}
net = { Start = function() end, WriteString = function(t) states[#states + 1] = t end, Broadcast = function() end, Receive = function() end, ReadString = function() end, Send = function() end }
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
timer = { Simple = function(_, f) f() end }
PrintMessage = function(_, t) chats[#chats + 1] = t end
HUD_PRINTTALK = 3
MASK_SOLID_BRUSHONLY, COLLISION_GROUP_WEAPON = 1, 11
math.NormalizeAngle = math.NormalizeAngle or function(a) return (a + 180) % 360 - 180 end
math.Rand = math.Rand or function(a, b) return a + (b - a) * math.random() end
function IsValid(x) return x ~= nil and (type(x) ~= "table" or not x.gone) end
util.TraceLine = function(t) if t.endpos.z < t.start.z then return { Hit = true, HitPos = Vector(t.start.x, t.start.y, 0) } end return { Hit = false, HitPos = t.endpos } end
local made = {}
ents = { Create = function(class)
	local e = { class = class, pos = Vector(0, 0, 0), nw = {} }
	function e:SetModel(m) self.model = m end
	function e:SetPos(p) self.pos = p end
	function e:GetPos() return self.pos end
	function e:SetAngles() end
	function e:SetNWBool(k, v) self.nw[k] = v end
	function e:Spawn() end
	function e:SetCollisionGroup(g) self.group = g end
	function e:GetPhysicsObject() return { Wake = function() end, SetVelocity = function(_, v) e.vel = v end } end
	function e:Remove() self.gone = true end
	function e:EntIndex() return 500 + #made end
	made[#made + 1] = e
	return e
end }
local skating = {}
SkateGM = { API = { Allowed = function() return true end, IsSkating = function(p) return skating[p] == true end } }
local function Player(id, name)
	local p = { id = id, name = name }
	function p:EntIndex() return self.id end
	function p:UserID() if self.gone then error("NULL entity") end return self.id end
	function p:Nick() return self.name end
	function p:IsAdmin() return self.admin == true end
	function p:GetPos() return self.SkateGMHips or Vector(0, 0, 0) end
	function p:ChatPrint(t) chats[#chats + 1] = self.name .. ": " .. t end
	return p
end
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_royale/sh_royale.lua")
dofile("../../addon/skategm/lua/skategm_royale/sv_royale.lua")
local G = ROYALE.session
local host, bob, cat, dan = Player(1, "Host"), Player(2, "Bob"), Player(3, "Cat"), Player(4, "Dan")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
local function lastChat() return chats[#chats] or "" end
local function last() return states[#states] end
local t = 100

check("votes: the most votes goes", ROYALE.Tally({ [1] = 3, [2] = 3, [3] = 1 }, { [1] = true, [3] = true, [2] = true }) == 3)
check("votes: a tie goes to one of the tied", ROYALE.Tally({ [1] = 2, [2] = 1 }, { [1] = true, [2] = true }, function() return 2 end) == 2)
check("votes: nobody voted - someone still goes", ROYALE.Tally({}, { [4] = true }) == 4)
ROYALE.Command(host, { cmd = "create", pos = { 0, 0, 0 }, centre = { 0, 0, 0 }, radius = 1, runTime = 999, yaw = 0, canSkate = true }, t)
check("created; settings kept within limits, and no play area (skate anywhere)", G.phase == "lobby" and G.runTime == ROYALE.RUN_MAX and G.area == nil)
ROYALE.Command(host, { cmd = "settings", runTime = 20, radius = 1000 }, t)
for _, p in ipairs({ bob, cat, dan }) do ROYALE.Command(p, { cmd = "join", canSkate = true }, t) end
skating[host], skating[bob], skating[cat], skating[dan] = true, true, true, true
ROYALE.Command(host, { cmd = "begin" }, t)
check("start: round 1 countdown, four in", G.phase == "countdown" and G.round == 1 and #G.players == 4)
t = t + ROYALE.COUNTDOWN ROYALE.Think(t)
check("then everyone runs for 20 seconds", G.phase == "running" and math.abs(G.deadline - t - 20) < 1e-6)
ROYALE.Command(bob, { cmd = "score", score = 1234 }, t + 19)
t = t + 20 ROYALE.Think(t)
check("time's up: the replays, one run at a time", G.phase == "replays" and last().replay and last().replay.index == 1 and last().replay.total == 4)
ROYALE.Command(cat, { cmd = "score", score = 50 }, t + 0.2)
local scores = {}
for i = 1, 4 do
	scores[G.order[i].name] = G.order[i].score
	t = t + 20 + ROYALE.REPLAY_GAP ROYALE.Think(t)
end
check("each replay shows the run's score (sent as the run ended)", scores.Bob == 1234 and scores.Cat == 50)
check("after the last replay: voting", G.phase == "voting")
check("you can't vote for yourself", not ROYALE.Vote(bob, 2, t))
check("you can vote for anyone still in", ROYALE.Vote(bob, 3, t) and ROYALE.Vote(host, 3, t) and ROYALE.Vote(cat, 2, t))
check("nobody sees who voted for whom, only who has", last().players[2].voted == true and last().votes == nil)
check("you can change your vote", ROYALE.Vote(dan, 2, t) and ROYALE.Vote(dan, 3, t))
check("everyone's voted: the count comes early", G.deadline <= t + 1.5)
t = t + 2 ROYALE.Think(t)
check("most votes is out", G.phase == "out" and G.knocked.name == "Cat" and G.entries["3"].out and lastChat():find("Cat had the worst run"))
t = t + ROYALE.OUT_TIME ROYALE.Think(t)
check("next round: the ones still in run again", G.phase == "countdown" and G.round == 2)
t = t + ROYALE.COUNTDOWN ROYALE.Think(t)
t = t + 20 ROYALE.Think(t)
check("round 2 replays: only those still in", #G.order == 3)
for i = 1, 3 do t = t + 20 + ROYALE.REPLAY_GAP ROYALE.Think(t) end
check("knocked out, but still votes", ROYALE.Vote(cat, 4, t))
check("... and can't be voted for", not ROYALE.Vote(bob, 3, t))
t = t + ROYALE.VOTE_TIME ROYALE.Think(t)
check("Dan's out", G.knocked.name == "Dan")
t = t + ROYALE.OUT_TIME ROYALE.Think(t) t = t + ROYALE.COUNTDOWN ROYALE.Think(t) t = t + 20 ROYALE.Think(t)
for i = 1, 2 do t = t + 20 + ROYALE.REPLAY_GAP ROYALE.Think(t) end
ROYALE.Vote(host, 2, t) ROYALE.Vote(cat, 2, t) ROYALE.Vote(dan, 2, t) ROYALE.Vote(bob, 1, t)
t = t + ROYALE.VOTE_TIME ROYALE.Think(t)
check("one left: the winner", G.phase == "results" and G.winner and G.winner.name == "Host" and lastChat():find("Host wins Run Royale"))
t = t + ROYALE.RESULTS ROYALE.Think(t)
check("then back to the lobby, everyone in again", G.phase == "lobby" and not G.entries["3"].out and #G.players == 4)
ROYALE.Command(host, { cmd = "begin" }, t)
t = t + ROYALE.COUNTDOWN ROYALE.Think(t)
bob.gone, cat.gone, dan.gone = true, true, true
ROYALE.Think(t + 1)
check("everyone else leaves mid-run: the one left wins", G.phase == "results" and G.winner and G.winner.name == "Host")
