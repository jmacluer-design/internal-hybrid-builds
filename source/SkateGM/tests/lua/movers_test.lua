dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
function IsValid(x) if type(x) == "table" and x.IsValid then return x:IsValid() end return x ~= nil end
function CreateClientConVar(n, d) return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetInt = function() return 0 end, GetString = function() return d end } end
MsgC = function() end chat = { AddText = function() end }
local ME = { IsValid = function() return true end }
function LocalPlayer() return ME end
SOLID_NONE, SOLID_BSP, SOLID_BBOX, SOLID_OBB, SOLID_OBB_YAW, SOLID_VPHYSICS = 0, 1, 2, 3, 4, 6
FSOLID_NOT_SOLID, FSOLID_TRIGGER = 4, 8
local cratePos = Vector(100, 0, 0)
local crate = { IsValid = function() return true end, IsPlayer = function() return false end, IsNPC = function() return false end, IsWeapon = function() return false end,
	GetClass = function() return "prop_physics" end, GetSolid = function() return 6 end, GetSolidFlags = function() return 0 end,
	GetCollisionGroup = function() return 0 end, GetModel = function() return "models/crate.mdl" end, GetPos = function() return cratePos end, GetAngles = function() return Angle() end }
ents = { FindInSphere = function() return { crate } end }
local bob = { IsValid = function() return true end, Alive = function() return true end, IsPlayer = function() return true end, GetNoDraw = function() return true end }
player = { GetAll = function() return { ME, bob } end }
local now = 0
function RealTime() return now end
string.EndsWith = function(s, e) return e == "" or string.sub(s, -#e) == e end
local statics, movers, rebuilds = nil, nil, 0
skategm = { SetEntities = function(l) statics = l rebuilds = rebuilds + 1 end, SetMovers = function(l) movers = l return #l end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
S.phase, S.P = "on", { HIPS = Vector(0, 0, 40) }
local function names(list) local out = {} for _, e in ipairs(list or {}) do out[#out + 1] = e[1] end return table.concat(out, ",") end

-- another skater, 200 units away
S.remote[bob] = { snaps = { { t = 0, P = { HIPS = Vector(200, 0, 40), RIGHTFOOT = Vector(200, 0, 4), LEFTFOOT = Vector(200, 0, 4) } } }, last = 0 }
S.test.FeedEntities(Vector(0, 0, 40))
S.MoversThink(now)
check("other players go into the moving layer, not the static collision", names(movers) == "skategm/player" and not names(statics):find("player", 1, true))
local r0 = rebuilds
for i = 1, 20 do
	now = i * 0.05
	S.remote[bob].snaps = { { t = now - 0.2, P = { HIPS = Vector(200 + i * 10, 0, 40), RIGHTFOOT = Vector(200 + i * 10, 0, 4), LEFTFOOT = Vector(200 + i * 10, 0, 4) } } }
	S.remote[bob].last = now
	S.MoversThink(now)
	if i % 5 == 0 then S.test.FeedEntities(Vector(0, 0, 40)) end
end
check("... follows them every frame", movers[1] and movers[1][2] > 300)
check("... without a single collision rebuild", rebuilds == r0)

-- a prop starts moving: into the moving layer, out of the static collision
S.test.sent["models/crate.mdl"] = true
now = 2
S.test.FeedEntities(Vector(0, 0, 40))
check("a prop standing still: static collision", names(statics):find("crate", 1, true) ~= nil)
now = 2.25
cratePos = Vector(120, 0, 0)
S.test.FeedEntities(Vector(0, 0, 40))
S.MoversThink(now)
check("... moving: the moving layer instead", names(movers):find("crate", 1, true) ~= nil and not names(statics):find("crate", 1, true))
now = 2.5
cratePos = Vector(140, 0, 0)
S.test.FeedEntities(Vector(0, 0, 40))
S.MoversThink(now)
check("... placed where it is each frame", movers[#movers][2] == 140)
for t = 2.75, 3.25, 0.25 do now = t S.test.FeedEntities(Vector(0, 0, 40)) end
now = 3.55
S.test.FeedEntities(Vector(0, 0, 40))
S.MoversThink(now)
check("still for a second: back in the static collision...", names(statics):find("crate", 1, true) ~= nil)
check("... and kept in the moving layer while that rebuild runs", names(movers):find("crate", 1, true) ~= nil)
now = 5
S.test.FeedEntities(Vector(0, 0, 40))
S.MoversThink(now)
check("then only in the static collision", not names(movers):find("crate", 1, true))
S.test.sent["models/other.mdl"] = nil

-- a map door (brush model "*3"): the module knows its shape from the map
local doorPos = Vector(0, 100, 0)
local door = { IsValid = function() return true end, IsPlayer = function() return false end, IsNPC = function() return false end, IsWeapon = function() return false end,
	GetClass = function() return "func_door" end, GetSolid = function() return SOLID_BSP end, GetSolidFlags = function() return 0 end,
	GetCollisionGroup = function() return 0 end, GetModel = function() return "*3" end, GetPos = function() return doorPos end, GetAngles = function() return Angle() end }
ents.FindInSphere = function() return { door } end
skategm.HasShape = function(m) return m == "*3" end
now = 10
S.test.FeedEntities(Vector(0, 0, 40))
check("a door standing still: static collision", names(statics):find("*3", 1, true) ~= nil)
now = 10.25
doorPos = Vector(0, 100, 20)
S.test.FeedEntities(Vector(0, 0, 40))
S.MoversThink(now)
check("... opening: the moving layer", names(movers):find("*3", 1, true) ~= nil)
check("... and the static collision is told it's live (no copy where the map put it)", names(statics) == "*3#moving")
local r1 = rebuilds
for i = 1, 3 do now = 10.25 + i * 0.1 doorPos = Vector(0, 100, 20 + i * 5) S.test.FeedEntities(Vector(0, 0, 40)) end
check("... no rebuild while it keeps moving", rebuilds == r1)
skategm.HasShape = function() return false end
S.brushShape = {}
now = 20
doorPos = Vector(0, 100, 40)
S.test.FeedEntities(Vector(0, 0, 40))
now = 20.25
doorPos = Vector(0, 100, 60)
S.test.FeedEntities(Vector(0, 0, 40))
check("a brush model the module can't place stays in the static collision", names(statics):find("*3", 1, true) ~= nil)
skategm.HasShape = nil
ents.FindInSphere = function() return { crate } end

-- an older module without the moving layer: as before
skategm.SetMovers = nil
S.remote[bob].last = now
S.remote[bob].snaps[1].t = now
S.test.FeedEntities(Vector(0, 0, 40))
check("without the moving layer (an old module): players in the static collision, as before", names(statics):find("skategm/player", 1, true) ~= nil)

-- a lift going up: its velocity goes along (the module carries whoever stands on it)
skategm.SetMovers = function(l) movers = l return #l end
local liftPos = Vector(0, -100, 0)
local lift = { IsValid = function() return true end, IsPlayer = function() return false end, IsNPC = function() return false end, IsWeapon = function() return false end,
	GetClass = function() return "func_movelinear" end, GetSolid = function() return SOLID_BSP end, GetSolidFlags = function() return 0 end,
	GetCollisionGroup = function() return 0 end, GetModel = function() return "*5" end, GetPos = function() return liftPos end, GetAngles = function() return Angle() end }
ents.FindInSphere = function() return { lift } end
skategm.HasShape = function(m) return m == "*5" end
S.brushShape = {}
now = 40
S.test.FeedEntities(Vector(0, 0, 40))
for i = 1, 30 do
	now = 40 + i / 60
	liftPos = Vector(0, -100, i)
	if i % 15 == 0 then S.test.FeedEntities(Vector(0, 0, 40)) end
	S.MoversThink(now)
end
local liftEntry
for _, m in ipairs(movers or {}) do if m[1] == "*5" then liftEntry = m end end
check("a lift rising 60 units/s goes into the moving layer with its velocity", liftEntry and math.abs((liftEntry[10] or 0) - 60) < 6 and math.abs(liftEntry[8] or 0) < 1)
for i = 31, 60 do now = 40 + i / 60 S.MoversThink(now) end
for _, m in ipairs(movers or {}) do if m[1] == "*5" then liftEntry = m end end
check("... and when it stops, its velocity goes to nothing (it stops carrying)", liftEntry and math.abs(liftEntry[10] or 0) < 1)
skategm.HasShape = nil

-- a turntable: its turning rate goes along too
local turnYaw = 0
local turn = { IsValid = function() return true end, IsPlayer = function() return false end, IsNPC = function() return false end, IsWeapon = function() return false end,
	GetClass = function() return "func_rotating" end, GetSolid = function() return SOLID_BSP end, GetSolidFlags = function() return 0 end,
	GetCollisionGroup = function() return 0 end, GetModel = function() return "*6" end, GetPos = function() return Vector(0, 200, 0) end, GetAngles = function() return Angle(0, turnYaw, 0) end }
ents.FindInSphere = function() return { turn } end
skategm.HasShape = function(m) return m == "*6" end
S.brushShape = {}
now = 60
S.test.FeedEntities(Vector(0, 0, 40))
for i = 1, 30 do
	now = 60 + i / 60
	turnYaw = (i * 0.5) % 360
	if i % 15 == 0 then S.test.FeedEntities(Vector(0, 0, 40)) end
	S.MoversThink(now)
end
local turnEntry
for _, m in ipairs(movers or {}) do if m[1] == "*6" then turnEntry = m end end
check("a turntable turning 30 degrees a second goes in with its turning rate", turnEntry and math.abs((turnEntry[11] or 0) - 30) < 4)
skategm.HasShape = nil

-- a seesaw: its roll rate goes along too
local seesawRoll = 0
local seesaw = { IsValid = function() return true end, IsPlayer = function() return false end, IsNPC = function() return false end, IsWeapon = function() return false end,
	GetClass = function() return "func_door_rotating" end, GetSolid = function() return SOLID_BSP end, GetSolidFlags = function() return 0 end,
	GetCollisionGroup = function() return 0 end, GetModel = function() return "*7" end, GetPos = function() return Vector(0, 300, 0) end, GetAngles = function() return Angle(0, 0, seesawRoll) end }
ents.FindInSphere = function() return { seesaw } end
skategm.HasShape = function(m) return m == "*7" end
S.brushShape = {}
now = 80
S.test.FeedEntities(Vector(0, 0, 40))
for i = 1, 30 do
	now = 80 + i / 60
	seesawRoll = i * 0.25
	if i % 15 == 0 then S.test.FeedEntities(Vector(0, 0, 40)) end
	S.MoversThink(now)
end
local ssEntry
for _, m in ipairs(movers or {}) do if m[1] == "*7" then ssEntry = m end end
check("a seesaw tilting 15 degrees a second goes in with its roll rate", ssEntry and math.abs((ssEntry[13] or 0) - 15) < 3 and math.abs(ssEntry[11] or 0) < 1)
skategm.HasShape = nil
