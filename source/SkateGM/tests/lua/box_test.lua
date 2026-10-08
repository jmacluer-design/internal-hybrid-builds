dofile("gmock.lua")
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
local cmds = {}
concommand = { Add = function(n, f) cmds[n] = f end }
function RealTime() return 0 end
function IsValid(x) if type(x) == "table" and x.IsValid then return x:IsValid() end return x ~= nil end
function CreateClientConVar(n, d) return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetInt = function() return 0 end, GetString = function() return d end } end
local said = {}
MsgC = function(...) local t = { ... } said[#said + 1] = t[#t - 1] end chat = { AddText = function() end }
SOLID_VPHYSICS, SOLID_NONE, FSOLID_NOT_SOLID, FSOLID_TRIGGER, MASK_PLAYERSOLID = 6, 0, 4, 8, 33636363
-- models: a car with no physics mesh, a crate with one, a can
local models = {
	["models/car.mdl"] = { phys = false, mn = Vector(-90, -40, 0), mx = Vector(90, 40, 55) },
	["models/crate.mdl"] = { phys = true, mn = Vector(-19, -19, 0), mx = Vector(19, 19, 38) },
	["models/can.mdl"] = { phys = true, mn = Vector(-2.5, -2.5, 0), mx = Vector(2.5, 2.5, 10) },
}
util = setmetatable({ IsValidModel = function(m) return models[m] ~= nil end }, { __index = util })
ents = { CreateClientProp = function(m)
	local d = models[m]
	local e = { IsValid = function() return true end, SetPos = function() end, SetAngles = function() end, PhysicsInit = function() end, Remove = function() end }
	function e:GetModelBounds() return d.mn, d.mx end
	function e:GetPhysicsObject()
		if not d.phys then return { IsValid = function() return false end } end
		local verts = {}
		for _, p in ipairs({ { d.mn.x, d.mn.y, 0 }, { d.mx.x, d.mn.y, 0 }, { d.mx.x, d.mx.y, d.mx.z }, { d.mn.x, d.mx.y, 0 }, { d.mx.x, d.mx.y, 0 }, { d.mn.x, d.mn.y, d.mx.z } }) do verts[#verts + 1] = { pos = Vector(p[1], p[2], p[3]) } end
		return { IsValid = function() return true end, GetMeshConvexes = function() return { verts } end }
	end
	return e
end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
local function bounds(h) local lo, hi = Vector(1e9, 1e9, 1e9), Vector(-1e9, -1e9, -1e9) for _, f in ipairs(h) do for i = 1, #f - 2, 3 do lo = Vector(math.min(lo.x, f[i]), math.min(lo.y, f[i + 1]), math.min(lo.z, f[i + 2])) hi = Vector(math.max(hi.x, f[i]), math.max(hi.y, f[i + 1]), math.max(hi.z, f[i + 2])) end end return lo, hi end
local car = S.Hulls("models/car.mdl")
print("no physics model and no box solidity -> not solid (Source's rule):", #car == 0 and "OK" or "<-- WRONG")
local carBox = S.Hulls("models/car.mdl#bbox")
local lo, hi = bounds(carBox)
print("the same car with box solidity -> its bounding box:", #carBox == 1 and #carBox[1] == 36 * 3 and hi.x == 90 and hi.z == 55 and lo.y == -40 and "OK" or "<-- WRONG")
local crateBox = S.Hulls("models/crate.mdl#bbox")
print("#bbox request -> box, even with a physics mesh:", #crateBox == 1 and #crateBox[1] == 36 * 3 and "OK" or "<-- WRONG")
local crate = S.Hulls("models/crate.mdl")
print("normal prop -> its physics mesh:", #crate == 1 and #crate[1] == 6 * 3 and "OK" or "<-- WRONG")
print("tiny can still left out:", #S.Hulls("models/can.mdl") == 0 and "OK" or "<-- WRONG")

-- skategm_why
S.phase = "on"
S.view = { origin = Vector(0, 0, 50), angles = Angle(0, 0, 0) }
local traceResult
util.TraceLine = function() return traceResult end
LocalPlayer = function() return { EyePos = function() return Vector() end, EyeAngles = function() return Angle() end } end
local near = {}
skategm = { CollisionNear = function() return near.t or {}, near.tags or {} end }
local function ent(cls, mdl, over)
	local e = { IsValid = function() return true end, GetClass = function() return cls end, GetModel = function() return mdl end,
		GetSolid = function() return 6 end, GetSolidFlags = function() return 0 end, GetCollisionGroup = function() return 0 end,
		IsPlayer = function() return false end, IsNPC = function() return false end }
	for k, v in pairs(over or {}) do e[k] = v end
	return e
end
-- a solid prop right at a collision triangle
traceResult = { Hit = true, HitPos = Vector(100, 0, 20), Entity = ent("prop_physics", "models/crate.mdl") }
near = { t = { 100, -10, 0, 100, 10, 0, 100, 0, 40 }, tags = { 3 } }
cmds["skategm_why"]()
print("skategm_why on a solid prop:", said[#said]:find("IS solid") and "OK" or "<-- WRONG: " .. said[#said])
-- tiny clutter, nothing there
near = {}
traceResult = { Hit = true, HitPos = Vector(100, 0, 5), Entity = ent("prop_physics", "models/can.mdl") }
cmds["skategm_why"]()
print("skategm_why on tiny clutter explains why:", said[#said]:find("NOT") and said[#said]:find("tiny") and "OK" or "<-- WRONG: " .. said[#said])
-- a static prop the skater misses
traceResult = { Hit = true, HitPos = Vector(100, 0, 5), Entity = nil, HitTexture = "**studio**" }
cmds["skategm_why"]()
print("skategm_why names static props:", said[#said]:find("static prop") and not said[#said]:find("send me") and "OK" or "<-- WRONG: " .. said[#said])
