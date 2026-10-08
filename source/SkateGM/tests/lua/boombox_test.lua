dofile("gmock.lua")
local function check(label, ok) print(string.format("%-70s %s", label, ok and "OK" or "<-- WRONG")) end
function AddCSLuaFile() end
function include(f) dofile("../../addon/skategm/lua/" .. f) end
local timers = {}
timer = { Simple = function(_, f) timers[#timers + 1] = f end }
local function runTimers() local t = timers timers = {} for _, f in ipairs(t) do f() end end
local now = 0
function CurTime() return now end
function IsValid(x) return x ~= nil and x ~= false end
local function Entity(realm)
	SERVER, CLIENT = realm == "server", realm == "client"
	ENT = {}
	dofile("../../addon/skategm/lua/entities/skategm_boombox.lua")
	local e = setmetatable({ vars = {}, notify = {} }, { __index = ENT })
	function e:NetworkVar(_, _, name)
		self["Get" .. name] = function(s) return s.vars[name] or (name:find("Url") or name:find("Name")) and "" or s.vars[name] or 0 end
		self["Set" .. name] = function(s, v) s.vars[name] = v for _, f in ipairs(s.notify[name] or {}) do f(s) end end
	end
	function e:NetworkVarNotify(name, f) self.notify[name] = self.notify[name] or {} table.insert(self.notify[name], f) end
	function e:EmitSound() end
	function e:GetPos() return Vector(0, 0, 0) end
	e:SetupDataTables()
	return e
end

file = { Read = function() return nil end }
include("skategm_boombox/stations.lua")
local list = SKATEGM_STATIONS_LOAD("# my stations\nChill | https://a.example/x.mp3\nnot a station\nRock|http://b.example/y\n")
check("a server's station file: one 'name | url' per line", #list == 2 and list[1][1] == "Chill" and list[2][2] == "http://b.example/y")
check("the built-in stations are there", #SKATEGM_STATIONS >= 8)

local e = Entity("server")
check("Entities > SkateGM > Boombox", ENT.Spawnable and ENT.Category == "SkateGM" and ENT.PrintName == "Boombox")
e:Resolve()
check("starts on the first station", e:GetStation() == 1 and e:GetPlayingUrl() == SKATEGM_STATIONS[1][2])
local said
local ply = { IsPlayer = function() return true end, ChatPrint = function(_, s) said = s end }
e:Use(ply)
check("Use: the next station, and says which", e:GetStation() == 2 and e:GetPlayingUrl() == SKATEGM_STATIONS[2][2] and said:find(SKATEGM_STATIONS[2][1], 1, true))
now = 0.1
e:Use(ply)
check("Use held down doesn't skip through every station", e:GetStation() == 2)
e:SetStation(#SKATEGM_STATIONS)
e:Resolve()
e:Next()
check("after the last station: off", e:GetStation() == 0 and e:GetPlayingUrl() == "")
e:SetStreamUrl("https://my.example/stream")
runTimers()
e:SetStation(#SKATEGM_STATIONS)
e:Next()
check("with your own stream set, it comes after the list", e:GetPlayingName() == "Your stream" and e:GetPlayingUrl() == "https://my.example/stream")
e:SetStreamUrl("javascript:alert(1)")
runTimers()
check("only http(s) streams", e:GetPlayingUrl() == "")

local c = Entity("client")
local played, stopped = {}, 0
sound = { PlayURL = function(url, flags, cb) played[#played + 1] = url cb({ Play = function() end, Stop = function() stopped = stopped + 1 end, SetPos = function() end, Set3DFadeDistance = function() end, SetVolume = function(_, v) c.vol = v end }) end }
local cv = { GetFloat = function() return 1 end }
CreateClientConVar = function() return cv end
ENT = {}
c = Entity("client")
c.SetNextClientThink = function() end
c.vars.PlayingUrl, c.vars.Volume = "https://a.example/x.mp3", 0.5
c:Think()
check("clients play the station's stream, at its volume", played[1] == "https://a.example/x.mp3" and c.vol == 0.5)
c:Think()
check("... once, not every think", #played == 1)
c.vars.PlayingUrl = ""
c:Think()
check("turned off: the stream stops", stopped == 1)
