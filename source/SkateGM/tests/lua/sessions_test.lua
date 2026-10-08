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
dofile("../../addon/skategm/lua/skategm_melon/sh_melon.lua")
dofile("../../addon/skategm/lua/skategm_melon/sv_melon.lua")
local P = POTATO.mode
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
local function lastChat() return chats[#chats] or "" end
local ann, bob, cat, dan, eve = Player(1, "Ann"), Player(2, "Bob"), Player(3, "Cat"), Player(4, "Dan"), Player(5, "Eve")
for _, p in ipairs({ ann, bob, cat, dan, eve }) do skating[p] = true end
local clock = 100
local function cmd(mode, ply, m) clock = clock + 1 mode:HandleCommand(ply, 10, m, clock) end

cmd(P, ann, { cmd = "create", pos = { 0, 0, 0 }, yaw = 0, canSkate = true, fuse = 20, lives = 1 })
cmd(P, bob, { cmd = "create", pos = { 500, 0, 0 }, yaw = 0, canSkate = true, fuse = 30, lives = 2 })
local keys = P:SessionKeys()
check("two people host Hot Potato at the same time: two games", #keys == 2)
local a, b = P:SessionOf(ann), P:SessionOf(bob)
check("... each their own", a and b and a ~= b and P:SessionData(a).fuse == 20 and P:SessionData(b).fuse == 30)
cmd(P, cat, { cmd = "join", session = b, canSkate = true })
cmd(P, dan, { cmd = "join", session = a, canSkate = true })
check("joining the game picked", P:SessionOf(cat) == b and P:SessionOf(dan) == a and #P:SessionData(a).players == 2 and #P:SessionData(b).players == 2)
cmd(P, eve, { cmd = "join", canSkate = true })
check("joining without saying which, with two open: told to pick", P:SessionOf(eve) == nil and lastChat():find("more than one", 1, true))
cmd(P, cat, { cmd = "join", session = a, canSkate = true })
check("already in a game: can't join another", P:SessionOf(cat) == b and lastChat():find("already in", 1, true))
cmd(MELON.mode, ann, { cmd = "create", pos = { 0, 0, 0 }, centre = { 0, 0, 0 }, radius = 500, target = 30, yaw = 0, canSkate = true })
check("... nor host a second minigame of another kind", MELON.mode:SessionOf(ann) == nil and #MELON.mode:SessionKeys() == 0 and lastChat():find("already in Hot Potato", 1, true))
cmd(P, bob, { cmd = "settings", fuse = 45, lives = 2 })
check("a host's settings change only their game", P:SessionData(b).fuse == 45 and P:SessionData(a).fuse == 20)
cmd(P, ann, { cmd = "begin" })
check("one host starts: only their game starts", P:SessionData(a).phase == "countdown" and P:SessionData(b).phase == "lobby")
P:RunThink(clock + POTATO.COUNTDOWN + 1)
check("each game runs on its own", P:SessionData(a).phase == "playing" and P:SessionData(b).phase == "lobby")
local canRespawn = hooks["SkateGMCanRespawn/skategm_modes"]
check("respawn: refused while my game is being played", canRespawn and canRespawn(ann) == false and canRespawn(dan) == false)
check("... fine in a lobby, or in no game", canRespawn(bob) == nil and canRespawn(cat) == nil and canRespawn(eve) == nil)
cmd(P, bob, { cmd = "stop" })
check("closing one leaves the other going", #P:SessionKeys() == 1 and P:SessionOf(ann) == a and P:SessionOf(cat) == nil)
cmd(MELON.mode, cat, { cmd = "create", pos = { 0, 0, 0 }, centre = { 0, 0, 0 }, radius = 500, target = 30, yaw = 0, canSkate = true })
check("out of their game, a player can host something else", MELON.mode:SessionOf(cat) ~= nil)
cmd(P, dan, { cmd = "leave" })
check("leaving only takes you out of yours", P:SessionOf(dan) == nil and P:SessionOf(ann) == a)
local states = {}
for _, st in ipairs(sentStates or {}) do states[#states + 1] = st end
