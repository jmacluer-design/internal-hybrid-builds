dofile("gmock.lua")
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
function IsValid(x) return x ~= nil and (type(x) ~= "table" or not x.IsValid or x:IsValid()) end
local GMDIR = "../../addon/skategm/gamemodes/skategm/gamemode/"
function DeriveGamemode() end
local base = { PlayerSpawn = function() end, Think = function() end, HUDPaint = function() end }
function DEFINE_BASECLASS() BaseClass = base end
function include(f) dofile(GMDIR .. f) end
function AddCSLuaFile() end
local timers = {}
timer = { Simple = function(_, f) timers[#timers + 1] = f end }
local function runTimers() local t = timers timers = {} for _, f in ipairs(t) do f() end end

-- net: messages queue; receivers by name
local recv, outbox, current = {}, {}, nil
net = {
	Receive = function(n, f) recv[n] = f end,
	Start = function(n) current = { name = n } end,
	WriteString = function(s) current[#current + 1] = s end,
	ReadString = function() return current and current[1] or "" end,
	Send = function(to) current.to = to outbox[#outbox + 1] = current end,
	SendToServer = function() outbox[#outbox + 1] = current end,
}
local hooks = {}
hook = { Add = function(e, id, f) hooks[e .. "/" .. id] = f end }
concommand = { Add = function(n, f) _G["CMD_" .. n] = f end }
GetConVar = function() return { GetBool = function() return false end } end

---------------------------------------------------------------------------
-- server
---------------------------------------------------------------------------
SERVER, CLIENT = true, nil
GM = {}
local now = 100
CurTime = function() return now end
game = { SinglePlayer = function() return false end }
OBS_MODE_NONE, OBS_MODE_FIXED, OBS_MODE_ROAMING = 0, 3, 6
dofile(GMDIR .. "init.lua")
local SV = GM

local function Player()
	local p = { nw = {}, alive = true, stripped = 0 }
	function p:IsValid() return true end
	function p:IsAdmin() return false end
	function p:Alive() return self.alive end
	function p:SetNW2String(k, v) self.nw[k] = v end
	function p:StripWeapons() self.stripped = self.stripped + 1 end
	function p:Spectate(m) self.spectating = m end
	function p:UnSpectate() self.spectating = nil end
	function p:GetObserverMode() return self.spectating or OBS_MODE_NONE end
	function p:Spawn() SV:PlayerSpawn(self) end
	function p:Give(w) self.gave = (self.gave or 0) + 1 end
	return p
end
local ply = Player()
player = { GetHumans = function() return { ply } end }

SV:PlayerSpawn(ply)
runTimers()
check("server: spawning asks the player's game to start Skater mode", outbox[#outbox] and outbox[#outbox].name == SKATEGM_GM.NET_START and outbox[#outbox].to == ply)
check("... with no weapons", SV:PlayerLoadout(ply) == true and ply.gave == nil)
check("... watching from the spawn meanwhile (not walking about)", ply.spectating == OBS_MODE_FIXED)
hooks["SkateGMEnter/skategm_gm"](ply)
check("... and once Skater mode is on, not spectating any more", ply.spectating == nil)
ply.SkateGMFailed, ply.nw.SkateGMFailed = "you're not alive", "you're not alive"
hooks["SkateGMEnter/skategm_gm"](ply)
check("... and a failure from before is cleared once it's on", ply.SkateGMFailed == nil and ply.nw.SkateGMFailed == "")
check("... no noclip, vehicles, weapons, tools, physgun", SV:PlayerNoClip(ply) == false and SV:CanPlayerEnterVehicle() == false and SV:PlayerSpawnSWEP(ply) == false and SV:CanTool() == false and SV:PhysgunPickup() == false)
check("... nothing spawned the Garry's Mod way (props, NPCs, entities), no flashlight or suicide", SV:PlayerSpawnProp() == false and SV:PlayerSpawnNPC() == false and SV:PlayerSpawnSENT() == false and SV:PlayerSwitchFlashlight(ply, true) == false and SV:CanPlayerSuicide() == false)

current = { "the SkateGM module isn't installed" }
recv[SKATEGM_GM.NET_FAILED](0, ply)
check("server: a player who can't skate spectates, and is told why", ply.spectating == OBS_MODE_ROAMING and ply.nw.SkateGMFailed == "the SkateGM module isn't installed")
recv[SKATEGM_GM.NET_RETRY](0, ply)
runTimers()
check("... asking again: back to a spawn (waiting), asked to start again", ply.spectating == OBS_MODE_FIXED and ply.nw.SkateGMFailed == "" and outbox[#outbox].name == SKATEGM_GM.NET_START)

-- out of Skater mode for long: asked again, then spectating
ply.SkateGM = nil
now = now + 10
SV:Think()
check("server: not skating for a while, asked again", outbox[#outbox].name == SKATEGM_GM.NET_START)
now = now + SKATEGM_GM.START_TIMEOUT + 5
SKATEGM_GM.nextCheck = 0
SV:Think()
check("... and for too long: spectating, with the reason", ply.spectating == OBS_MODE_ROAMING and ply.nw.SkateGMFailed:find("didn't start", 1, true) ~= nil)

---------------------------------------------------------------------------
-- client
---------------------------------------------------------------------------
SERVER, CLIENT = nil, true
RealTime = function() return 0 end
GM = {}
recv, outbox, hooks = {}, {}, {}
local me = { nw = {}, alive = true }
function me:IsValid() return true end
function me:Alive() return self.alive end
function me:GetNW2String(k, d) return self.nw[k] or d end
function LocalPlayer() return me end
local api = { phase = "off", canSkate = true }
SkateGM = { API = {
	SetLocked = function(on) api.locked = on end, IsLocked = function() return api.locked == true end,
	IsSkating = function() return api.phase == "on" end, IsLoading = function() return api.phase == "loading" end,
	CanSkate = function() return api.canSkate end, LastError = function() return api.err end,
	StartSkating = function() api.started = (api.started or 0) + 1 api.phase = api.startTo or "loading" end,
} }
dofile(GMDIR .. "cl_init.lua")
local C = SKATEGM_GM.client

-- just joined, not spawned yet: no start, and no failure either
me.alive = false
recv[SKATEGM_GM.NET_START]()
C.Think(0.5)
C.Think(5)
check("client: not spawned yet: it waits (no start, nothing reported)", api.started == nil and #outbox == 0)
me.alive = true
C.Think(6)
check("client: spawned: Skater mode locked on and started", api.locked == true and api.started == 1)
api.phase = "on"
C.Think(1)
check("... loading then skating: nothing sent", #outbox == 0)

-- the module isn't there: the reason goes to the server
api.phase, api.canSkate, api.err = "off", false, "the SkateGM module (gmcl_skategm_win64.dll) isn't installed"
recv[SKATEGM_GM.NET_START]()
check("client: can't skate at all: the server hears why", outbox[1] and outbox[1].name == SKATEGM_GM.NET_FAILED and outbox[1][1]:find("isn't installed", 1, true))

-- starting goes wrong (data missing): off again, and the reason sent
outbox = {}
api.canSkate, api.err, api.startTo = true, nil, "off"
recv[SKATEGM_GM.NET_START]()
api.err = "no Skate 3 data at C:/skategm/assets"
C.Think(10)
C.Think(13)
check("client: Skater mode didn't start: the reason from the add-on goes to the server", outbox[1] and outbox[1].name == SKATEGM_GM.NET_FAILED and outbox[1][1] == "no Skate 3 data at C:/skategm/assets")

game.SinglePlayer = function() return false end
function me:IsAdmin() return true end
check("no spawn menu or context menu in the SkateGM gamemode", GM:SpawnMenuOpen() == false and GM:ContextMenuOpen() == false)
check("... not even for admins", GM:SpawnMenuOpen() == false)
check("no crosshair, weapon selection or health on screen", GM:HUDShouldDraw("CHudCrosshair") == false and GM:HUDShouldDraw("CHudWeaponSelection") == false)
me.nw.SkateGMFailed = "no Skate 3 data at C:/skategm/assets"
outbox = {}
local bind = hooks["PlayerBindPress/skategm_gm"]
check("spectating: Reload tries again", bind(me, "+reload", true) == true and outbox[1] and outbox[1].name == SKATEGM_GM.NET_RETRY)

-- the server still says I failed, but I'm skating now: no popup
api.phase = "on"
check("skating: the failure message is gone, whatever the server's flag says", C.Failed() == nil)
