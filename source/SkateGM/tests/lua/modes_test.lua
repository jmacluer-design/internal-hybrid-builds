dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end

local function json(t) local parts = {} for k, v in pairs(t) do parts[#parts + 1] = k .. "=" .. tostring(v) end table.sort(parts) return table.concat(parts, ";") end
local function unjson(s)
	if s == "bad" then error("not json") end
	local t = {}
	for k, v in s:gmatch("([^;=]+)=([^;]*)") do t[k] = tonumber(v) or v end
	return t
end
util = setmetatable({ AddNetworkString = function(n) NETS = NETS or {} NETS[n] = true end, TableToJSON = json, JSONToTable = unjson }, { __index = util })
local receivers, sent, cur = {}, {}, nil
net = {
	Receive = function(n, f) receivers[n] = f end,
	Start = function(n) cur = { name = n } end,
	WriteString = function(s) cur.text = s end,
	ReadString = function() return READ end,
	Broadcast = function() cur.to = "all" sent[#sent + 1] = cur end,
	Send = function(p) cur.to = p sent[#sent + 1] = cur end,
	SendToServer = function() cur.to = "server" sent[#sent + 1] = cur end,
}
local hooks, runs = {}, {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end, Run = function(n, a) runs[#runs + 1] = { n, a } end }
local cvarCallbacks = {}
cvars = { AddChangeCallback = function(n, f) cvarCallbacks[n] = f end }
local convars = {}
function GetConVar(n) return convars[n] end
function CreateConVar(n, d) local c = { value = d } function c:GetBool() return self.value == "1" end convars[n] = c return c end
FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY = 1, 2, 4
local clock = 100
function CurTime() return clock end
function SysTime() return clock end
function RealTime() return clock end

SERVER, CLIENT = true, nil
SKATEGM_MODES = nil
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
local M = SKATEGM_MODES
check("the framework announces itself for add-ons that load first", runs[1] and runs[1][1] == "Sk8ModesReady" and runs[1][2] == M)

local mode = M.Register({ id = "tag", title = "Tag", order = 5 })
check("registering makes its messages", NETS[mode.NET_STATE] and NETS[mode.NET_CMD] and mode.NET_STATE == "skategm_mode_tag_state")
check("... an 'allowed on this server' switch, on by default", convars.skategm_tag_allowed and mode:Allowed())
check("... and tells everyone it's there", runs[#runs][1] == "Sk8ModeRegistered" and runs[#runs][2] == mode)
check("bad ids are refused", not pcall(M.Register, { id = "no spaces" }))
check("SKATEGM_MODES.Get finds it", M.Get("tag") == mode)

local got = {}
mode:OnCommand(function(ply, m) got[#got + 1] = { ply, m } end)
local bob = { name = "bob" }
READ = "cmd=join"
receivers[mode.NET_CMD](100, bob)
check("a command from a player reaches the mode", got[1] and got[1][1] == bob and got[1][2].cmd == "join")
receivers[mode.NET_CMD](100, bob)
check("a second one in the same instant gets through (\"begin\" then \"ready\")", #got == 2)
for _ = 1, 20 do receivers[mode.NET_CMD](100, bob) end
check("... but a flood is cut off (a burst of 10, then 30 a second)", #got == M.CMD_BURST)
local n = #got
clock = clock + 0.5
for _ = 1, 20 do receivers[mode.NET_CMD](100, bob) end
check("... and it refills over time", #got > n and #got <= n + M.CMD_BURST)
got = { got[1] }
clock = clock + 0.1
READ = "bad"
receivers[mode.NET_CMD](100, bob)
check("a message that isn't JSON is ignored", #got == 1)
clock = clock + 0.1
READ = "cmd=x"
receivers[mode.NET_CMD](M.CMD_MAX_BITS + 8, bob)
check("an oversized message is ignored", #got == 1)
local big = M.Register({ id = "paintish", maxCommandBytes = 60000 })
local bigGot = 0
big:OnCommand(function() bigGot = bigGot + 1 end)
receivers[big.NET_CMD](40000 * 8, bob)
check("a mode can allow bigger commands", bigGot == 1)

sent = {}
mode:Broadcast({ phase = "lobby" })
check("state goes to everyone", sent[1] and sent[1].to == "all" and sent[1].name == mode.NET_STATE and sent[1].text == "phase=lobby")
local carl = { name = "carl" }
mode:SendState(carl)
check("... or to one player (the last state by default)", sent[2].to == carl and sent[2].text == "phase=lobby")

local thinks, joined, left, stopped = 0, nil, nil, false
mode:OnThink(function() thinks = thinks + 1 end)
mode:OnPlayerJoin(function(p) joined = p end)
mode:OnPlayerLeave(function(p) left = p end)
mode:OnDisallowed(function() stopped = true end)
hooks["Think/skategm_mode_tag"]()
hooks["PlayerInitialSpawn/skategm_mode_tag"](carl)
hooks["PlayerDisconnected/skategm_mode_tag"](bob)
cvarCallbacks.skategm_tag_allowed(nil, "1", "0")
check("think, join, leave and 'turned off' reach the mode", thinks == 1 and joined == carl and left == bob and stopped)
local again = M.Register({ id = "tag", title = "Tag 2" })
check("registering the same id again updates it, keeping its handlers", again == mode and mode.title == "Tag 2" and mode.commandHandler ~= nil)

SERVER, CLIENT = nil, true
SKATEGM_MODES = nil
receivers, sent, hooks = {}, {}, {}
convars = {}
local me = { name = "me" }
function LocalPlayer() return me end
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
M = SKATEGM_MODES
local cmode = M.Register({ id = "tag", title = "Tag", order = 5 })
cmode:Send({ cmd = "join" })
check("client: commands go to the server", sent[1] and sent[1].to == "server" and sent[1].name == cmode.NET_CMD and sent[1].text == "cmd=join")
local seen
cmode:OnState(function(st) seen = st end)
READ = "phase=playing"
receivers[cmode.NET_STATE]()
check("client: the server's state arrives", seen and seen.phase == "playing" and cmode.state == seen)
local words
cmode:OnChat(function(w) words = w end)
local handled = hooks["OnPlayerChat/skategm_mode_tag"](me, "!Tag join now")
check("client: '!tag ...' in chat reaches the mode, without the prefix", handled == true and words and words[1] == "join" and words[2] == "now")
words = nil
check("... other chat is left alone", hooks["OnPlayerChat/skategm_mode_tag"](me, "hello") == nil and words == nil)
check("... and other players' chat too", hooks["OnPlayerChat/skategm_mode_tag"]({}, "!tag join") == nil and words == nil)

SKATEGM_MODES = nil
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
receivers = {}
SERVER, CLIENT = true, nil
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
check("loading the framework twice keeps one registry", SKATEGM_MODES.modes ~= nil and SKATEGM_MODES.Register ~= nil)

SERVER, CLIENT = nil, true
SKATEGM_MODES = nil
convars = {}
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
SkateGM = { API = { IsSkating = function() return true end } }
dofile("../../docs/example_mode/lua/skategm_example_highspeed/sh_highspeed.lua")
dofile("../../docs/example_mode/lua/skategm_example_highspeed/cl_highspeed.lua")
check("the example add-on registers through the framework", SKATEGM_MODES.Get("highspeed") ~= nil)

-- watching someone else's turn (Mode:Watch)
do
	local hm = SKATEGM_MODES.Get("highspeed")
	local a = { stopped = 0 }
	SkateGM.API = {
		IsLocked = function() return a.locked end, IsSkating = function() return true end, IsLoading = function() return false end,
		StopSkating = function() a.stopped = a.stopped + 1 end, Freeze = function(on) a.frozen = on end, SetView = function(f) a.view = f end,
	}
	hm:Watch(true, function() return "view" end)
	check("watching, Skater mode free to stop: it stops (the mode's camera shows them)", a.stopped == 1 and a.view == nil)
	a.locked = true
	hm:Watch(true, function() return "view" end)
	check("... where it stays on (the SkateGM gamemode): frozen, the camera on them", a.frozen == true and a.view and a.view() == "view" and a.stopped == 1)
	hm:Watch(false)
	check("... and back when it's my turn again", a.frozen == false and a.view == nil)
end

-- the shared helpers
do
	local M = SKATEGM_MODES
	check("helpers: IndexOf, Num (no NaN, no huge), Vec, Clock", M.IndexOf({ "a", "b" }, "b") == 2 and M.IndexOf(nil, "a") == nil
		and M.Num("3") == 3 and M.Num(0 / 0) == nil and M.Num(1e9) == nil and M.Num(50, 10) == nil
		and M.Vec({ 1, "2", 3 })[2] == 2 and M.Vec({ 1, 2 }) == nil and M.Vec("x") == nil
		and M.Clock(65.2) == "1:06" and M.Clock(-3) == "0:00")
end
