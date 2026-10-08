dofile("gmock.lua")
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
function IsValid(x) if type(x) == "table" and x.IsValid then return x:IsValid() end return x ~= nil end
function CreateClientConVar(n, d) return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetInt = function() return 0 end, GetString = function() return d end } end
local said = {}
MsgC = function(...) local t = { ... } said[#said + 1] = t[#t - 1] end chat = { AddText = function() end }
function LocalPlayer() return {} end
game = { GetMap = function() return "gm_mcdonalds" end }
MASK_PLAYERSOLID = 1
-- the world: a car (static prop) at x = 100, and a crate entity at x = 300 that IS in the skater's collision
local traceHit
util = setmetatable({ TraceLine = function(t) return traceHit(t) end }, { __index = util })
skategm = {
	CollisionNear = function(x) if x > 250 then return { 1, 2, 3, 4, 5, 6, 7, 8, 9 }, { 3 } end return {}, {} end,
	CollisionHas = function(x) return x > 250 end,
	StaticPropsNear = function() return { { model = "models/props_vehicles/car002a.mdl", solid = "solid (bounding box)", status = "waiting for its shape from the game", distance = 20 } } end,
}
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
S.phase = "on"
local function at(x) S.P = { HIPS = Vector(x, 0, 36) } S.anchor = Vector(x, 0, 1) end
local function step(x0, x1, t)
	at(x0) S.PassThrough(t)
	at(x1) S.PassThrough(t + 0.15)
end
-- moving through the car (static prop, no skater collision there)
traceHit = function(t) if t.start.x < 100 and t.endpos.x >= 100 then return { Hit = true, HitPos = Vector(100, 0, t.start.z), HitTexture = "**studio**" } end return { Hit = false } end
step(90, 110, 1)
print("passing through a car is reported with its model and status:", said[#said] and said[#said]:find("car002a") and said[#said]:find("waiting") and "OK" or "<-- WRONG")
local n = #said
step(90, 110, 10)
print("the same thing is only reported once:", #said == n and "OK" or "<-- WRONG")
-- moving through something that IS in the skater's collision: nothing to report
traceHit = function(t) if t.start.x < 300 and t.endpos.x >= 300 then return { Hit = true, HitPos = Vector(300, 0, 20), Entity = { IsValid = function() return true end, GetClass = function() return "prop_physics" end, GetModel = function() return "models/crate.mdl" end, IsPlayer = function() return false end, IsNPC = function() return false end, GetSolid = function() return 6 end, GetCollisionGroup = function() return 0 end } } end return { Hit = false } end
step(290, 310, 20)
print("no report when the skater's collision is there:", #said == n and "OK" or "<-- WRONG")
-- a teleport (marker return, water reset) across the car is not a pass-through
passSeen = nil
traceHit = function() return { Hit = true, HitPos = Vector(100, 0, 20), HitTexture = "**studio**", Entity = nil } end
S.passLast = nil
step(-500, 700, 30)
print("teleports are ignored:", #said == n and "OK" or "<-- WRONG")
