dofile("gmock.lua")
SERVER = true
CurTime = CurTime or function() return 0 end
SysTime = SysTime or function() return 0 end
local chats = {}
util = setmetatable({ AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
local states = {}
net = { Start = function() end, WriteString = function(t) states[#states + 1] = t end, Broadcast = function() end, Receive = function() end, ReadString = function() end, Send = function() end }
hook = { Add = function() end }
timer = { Simple = function(_, f) f() end }
PrintMessage = function(_, t) chats[#chats + 1] = t end
HUD_PRINTTALK = 3
math.NormalizeAngle = math.NormalizeAngle or function(a) return (a + 180) % 360 - 180 end
function IsValid(x) return x ~= nil and (type(x) ~= "table" or not x.gone) end
local skating = {}
SkateGM = { API = { Allowed = function() return true end, IsSkating = function(p) return skating[p] == true end } }
local function Player(id, name)
	local p = { id = id, name = name }
	function p:EntIndex() return self.id end
	function p:UserID() if self.gone then error("NULL entity") end return self.id end
	function p:Nick() return self.name end
	function p:IsAdmin() return self.admin == true end
	function p:ChatPrint(t) chats[#chats + 1] = self.name .. ": " .. t end
	return p
end
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
dofile("../../addon/skategm/lua/skategm_potato/sh_potato.lua")
dofile("../../addon/skategm/lua/skategm_potato/sv_potato.lua")
local G = POTATO.session
local host, bob, cat, dan = Player(1, "Host"), Player(2, "Bob"), Player(3, "Cat"), Player(4, "Dan")
local function check(label, ok) print(string.format("%-70s %s", label, ok and "OK" or "<-- WRONG")) end
local function lastChat() return chats[#chats] or "" end
local function last() return states[#states] end
math.randomseed(7)
local t = 100

POTATO.Command(host, { cmd = "create", pos = { 0, 0, 0 }, yaw = 90, canSkate = true, fuse = 500, lives = 2 }, t)
check("created; settings kept within limits", G.phase == "lobby" and G.fuse == POTATO.FUSE_MAX and G.lives == 2)
POTATO.Command(bob, { cmd = "join", canSkate = true }, t)
POTATO.Command(cat, { cmd = "join", canSkate = true }, t)
POTATO.Command(dan, { cmd = "join", canSkate = false }, t)
check("players join; without Skate 3 mode you can't", #G.players == 3 and lastChat():find("Skater mode") ~= nil)
POTATO.Command(host, { cmd = "settings", fuse = 20, lives = 2 }, t)
skating[host] = true
POTATO.Command(host, { cmd = "begin" }, t)
check("needs at least two skaters in Skate 3 mode", G.phase == "lobby" and lastChat():find("two") ~= nil)
skating[bob], skating[cat] = true, true
POTATO.Command(bob, { cmd = "begin" }, t)
check("only the host can start", G.phase == "lobby")
POTATO.Command(host, { cmd = "begin" }, t)
check("start: the countdown", G.phase == "countdown")
POTATO.Think(t + POTATO.COUNTDOWN)
t = t + POTATO.COUNTDOWN
check("GO: playing, no bomb yet while everyone scatters", G.phase == "playing" and G.holder == nil and G.armAt == t + POTATO.SCATTER)
POTATO.Think(t + POTATO.SCATTER)
t = t + POTATO.SCATTER
local h1 = G.holder
check("after the scatter someone has the bomb", h1 ~= nil and G.fuseAt > t)
check("the fuse is about the setting, never exactly known", G.fuseLen >= 20 * (1 - POTATO.FUSE_SPREAD) and G.fuseLen <= 20 * (1 + POTATO.FUSE_SPREAD))
local pub = last()
check("clients see who holds it and how far the fuse has burnt, not when it blows", pub.holder == h1:EntIndex() and pub.ticking == 1 and pub.fuseAt == nil)
local others = {}
for _, p in ipairs({ host, bob, cat }) do if p ~= h1 then others[#others + 1] = p end end
local a, b = others[1], others[2]
local fuseBefore = G.fuseAt
POTATO.Command(h1, { cmd = "pass", target = a:EntIndex() }, t + 0.5)
check("a fresh holder can't pass it straight on (catch grace)", G.holder == h1)
POTATO.Command(a, { cmd = "pass", target = b:EntIndex() }, t + 2)
check("only the holder can pass it", G.holder == h1)
POTATO.Command(h1, { cmd = "pass", target = h1:EntIndex() }, t + 2)
check("you can't pass it to yourself", G.holder == h1)
POTATO.Command(h1, { cmd = "pass", target = 99 }, t + 2)
check("or to someone not in the game", G.holder == h1)
POTATO.Command(h1, { cmd = "pass", target = a:EntIndex() }, t + 2)
check("skating into someone passes it", G.holder == a and G.passedFrom == h1)
POTATO.Command(a, { cmd = "pass", target = h1:EntIndex() }, t + 3.5)
check("no tag-backs straight away", G.holder == a)
POTATO.Command(a, { cmd = "pass", target = b:EntIndex() }, t + 3.5)
check("but anyone else is fine", G.holder == b)
check("passing doesn't reset the fuse", G.fuseAt == fuseBefore)
local fuseAt = G.fuseAt
-- it blows on whoever holds it
local holder = G.holder
POTATO.Think(G.fuseAt)
t = fuseAt
local e = G.entries[tostring(holder:UserID())]
check("BOOM: the holder loses a life", e.lives == 1 and e.booms == 1 and not e.out and G.holder == nil)
check("everyone hears about it (for the blast and the launch)", last().boom and last().boom.ent == holder:EntIndex())
POTATO.Think(t + POTATO.BETWEEN)
t = t + POTATO.BETWEEN
check("a fresh bomb after a moment, to someone else", G.holder ~= nil and G.holder ~= holder)
-- the second life goes too: out
for _ = 1, 10 do
	if G.phase ~= "playing" then break end
	if G.holder then
		local victim = G.holder
		POTATO.Think(G.fuseAt) t = G.fuseAt
		if G.phase == "playing" then POTATO.Think(t + POTATO.BETWEEN) t = t + POTATO.BETWEEN end
		if G.entries[tostring(victim:UserID())].out then break end
	end
end
local outs = 0
for _, en in pairs(G.entries) do if en.out then outs = outs + 1 end end
check("out of lives: out of the game", outs >= 1)
for _ = 1, 20 do
	if G.phase ~= "playing" then break end
	if G.holder then POTATO.Think(G.fuseAt) t = G.fuseAt else POTATO.Think(t + POTATO.BETWEEN) t = t + POTATO.BETWEEN end
end
check("the last one standing wins", G.phase == "results" and G.winner ~= nil)
POTATO.Think(t + POTATO.RESULTS)
check("then back to the lobby for a rematch", G.phase == "lobby" and G.entries["1"].lives == nil)
-- the holder leaving: the bomb jumps, fuse still burning
POTATO.Command(dan, { cmd = "join", canSkate = true }, t)
skating[dan] = true
POTATO.Command(host, { cmd = "begin" }, t + 200)
POTATO.Think(t + 200 + POTATO.COUNTDOWN)
POTATO.Think(t + 200 + POTATO.COUNTDOWN + POTATO.SCATTER)
t = t + 200 + POTATO.COUNTDOWN + POTATO.SCATTER
local leaver, burn = G.holder, G.fuseAt
leaver.gone = true
POTATO.Think(t + 1)
check("the holder disconnects: the bomb jumps to someone still in", G.holder ~= nil and G.holder ~= leaver and G.fuseAt == burn)
-- dropping out of Skate 3 mode with it doesn't save you
local runner = G.holder
skating[runner] = false
POTATO.Think(t + 1.5)
POTATO.Think(t + 3)
check("leaving Skate 3 mode while holding it: it blows on you, and you're out",
	G.entries[tostring(runner:UserID())] and G.entries[tostring(runner:UserID())].out == true)
skating[runner] = true
POTATO.Command(cat, { cmd = "stop" }, t + 4)
check("only the host or an admin can stop it", G.phase ~= "lobby" and G.phase ~= "idle")
cat.admin = true
POTATO.Command(cat, { cmd = "stop" }, t + 4)
check("an admin can: back to the lobby", G.phase == "lobby")
MOCK_SET_CVAR("skategm_potato_allowed", 0)
check("turned off on the server: it ends", G.phase == "idle")
POTATO.Command(bob, { cmd = "create", pos = { 0, 0, 0 }, canSkate = true }, t + 10)
check("and can't be set up while off", G.phase == "idle" and lastChat():find("turned off") ~= nil)
