dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
function IsValid(x) return x ~= nil and x ~= false and not (type(x) == "table" and x.gone) end
FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY = 128, 8192, 256
local cv = { skategm_knock_props = "1", skategm_knock_mass = "150" }
function CreateConVar(n, d) cv[n] = cv[n] or d return { GetBool = function() return cv[n] == "1" end, GetFloat = function() return tonumber(cv[n]) end } end
local timers, hooks, receivers, sent = {}, {}, {}, {}
timer = { Create = function(n, _, _, f) timers[n] = f end }
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
local cur
net = { Start = function(n) cur = { name = n, f = {} } end, WriteEntity = function(e) cur.ent = e end, WriteFloat = function(v) cur.f[#cur.f + 1] = v end,
	SendToServer = function() sent[#sent + 1] = cur end, Receive = function(n, f) receivers[n] = f end }
util = setmetatable({ AddNetworkString = function() end }, { __index = util })
VectorRand = function() return Vector(1, 0, 0) end
local constrained = {}
constraint = { HasConstraints = function(e) return constrained[e] == true end }
local props = {}
local function Prop(class, mass, pos, size)
	local phys = { mass = mass, motion = true, vel = Vector(0, 0, 0), spin = Vector(0, 0, 0) }
	function phys:IsValid() return true end
	function phys:IsMotionEnabled() return self.motion end
	function phys:GetMass() return self.mass end
	function phys:Wake() self.awake = true end
	function phys:GetVelocity() return self.vel end
	function phys:SetVelocity(v) self.vel = v end
	function phys:AddAngleVelocity(v) self.spin = v end
	local e = { class = class, phys = phys, pos = pos, size = size or 8, nw = {} }
	function e:GetClass() return self.class end
	function e:GetPhysicsObject() return self.phys end
	function e:GetNW2Bool(k, d) local v = self.nw[k] if v == nil then return d end return v end
	function e:SetNW2Bool(k, v) self.nw[k] = v end
	function e:GetNW2Int(k, d) return self.nw[k] or d end
	function e:SetNW2Int(k, v) self.nw[k] = v end
	function e:SetPhysicsAttacker(p) self.attacker = p end
	function e:NearestPoint(p)
		local d = p - self.pos
		local function c(v) return math.max(-self.size, math.min(self.size, v)) end
		return self.pos + Vector(c(d.x), c(d.y), c(d.z))
	end
	props[#props + 1] = e
	return e
end
ents = { FindByClass = function(c) local out = {} for _, e in ipairs(props) do if e.class == c then out[#out + 1] = e end end return out end,
	FindInSphere = function(p, r) local out = {} for _, e in ipairs(props) do if (e.pos - p):Length() <= r + e.size * 2 then out[#out + 1] = e end end return out end }
local skater = { SkateGM = true, SkateGMHips = Vector(0, 0, 40) }
player = { GetAll = function() return { skater } end }

SERVER = true
dofile("../../addon/skategm/lua/skategm_knock/sh_knock.lua")
dofile("../../addon/skategm/lua/skategm_knock/sv_knock.lua")
SERVER = nil

local melon = Prop("prop_physics", 15, Vector(30, 0, 10))
local crate = Prop("prop_physics", 40, Vector(30, 0, 10))
local car = Prop("prop_physics", 1200, Vector(300, 0, 10))
local frozen = Prop("prop_physics", 40, Vector(300, 0, 10)) frozen.phys.motion = false
local welded = Prop("prop_physics", 40, Vector(300, 0, 10)) constrained[welded] = true
local door = Prop("prop_door_rotating", 30, Vector(300, 0, 10))
local mk = Prop("prop_physics", 10, Vector(300, 0, 10)) mk.SkateGMMelon = true
check("light, loose props can be knocked over", KNOCK.Knockable(melon) and KNOCK.Knockable(crate))
check("heavy, frozen or welded ones stay solid", not KNOCK.Knockable(car) and not KNOCK.Knockable(frozen) and not KNOCK.Knockable(welded))
check("doors and game-mode props stay as they are", not KNOCK.Knockable(door) and not KNOCK.Knockable(mk))
timers.skategm_knock_refresh()
check("clients are told which (and how heavy)", crate.nw.SkateGMKnock == true and crate.nw.SkateGMMass == 40 and car:GetNW2Bool("SkateGMKnock", false) == false)
cv.skategm_knock_mass = "2000"
timers.skategm_knock_refresh()
check("the weight limit is the server's to set", car.nw.SkateGMKnock == true)
cv.skategm_knock_mass = "150"
timers.skategm_knock_refresh()

check("a skater not skating: nothing", not KNOCK.Hit({ SkateGMHips = Vector(0, 0, 40) }, crate, Vector(300, 0, 0), 1))
check("the skater far from the prop: refused", not KNOCK.Hit({ SkateGM = true, SkateGMHips = Vector(5000, 0, 40) }, crate, Vector(300, 0, 0), 1))
check("a knock: the prop flies the way the skater was going, up and spinning", KNOCK.Hit(skater, crate, Vector(400, 0, 0), 1) and crate.phys.vel.x > 400 and crate.phys.vel.z > 0 and crate.phys.spin.x > 0 and crate.attacker == skater)
check("... not again straight away", not KNOCK.Hit(skater, crate, Vector(400, 0, 0), 1.1))
check("a silly speed is capped", KNOCK.Hit(skater, melon, Vector(1e9, 0, 0), 2) and melon.phys.vel.x <= KNOCK.MAX_SPEED * 1.15 + 1)
check("NaN is refused", not KNOCK.Hit(skater, crate, Vector(0 / 0, 0, 0), 5))
check("heavier props slow the skater more", KNOCK.SpeedLoss(10) < KNOCK.SpeedLoss(100) and KNOCK.SpeedLoss(1e6) <= 0.35)

-- client
local src = io.open("../../addon/skategm/lua/autorun/client/skategm_cl.lua"):read("*a")
local BONES = {}
for name in src:match("local BONES = (%b{})"):gmatch('"([%w_]+)"') do BONES[name] = true end
local CL = io.open("../../addon/skategm/lua/skategm_knock/cl_knock.lua"):read("*a")
local allReal = true
for name in CL:gmatch('"([%u_]+)"') do if not BONES[name] then allReal = false print("  not a bone: " .. name) end end
check("the touch points are real bone names", allReal)
local launched
function RealTime() return 10 end
SkateGM = { phase = "on", loadedScale = 1, API = { Velocity = function() return Vector(394, 0, 0) end, Launch = function(v) launched = v end } }
dofile("../../addon/skategm/lua/skategm_knock/cl_knock.lua")
crate.nw.SkateGMKnock, crate.nw.SkateGMMass = true, 100
car.nw.SkateGMKnock = false
SkateGM.P = { HIPS = Vector(0, 0, 40), TRUCK_FRONT = Vector(20, 0, 4), TRUCK_BACK = Vector(0, 0, 4) }
hooks["Think/skategm_knock"]()
check("knockable props aren't collision for the skater", SkateGM.SkipEntity == nil and SkateGM.EntitySkippers[1](crate) and not SkateGM.EntitySkippers[1](car))
sent, launched = {}, nil
KNOCK.recent = {}
KNOCK.Think(10)
local hit
for _, m in ipairs(sent) do if m.ent == crate then hit = m end end
check("the board running into one tells the server, with the skater's speed", hit and hit.f[1] == 394)
check("... and the skater loses a little speed", launched and launched.x < 0 and math.abs(launched.x) < 394 * 0.0254)
sent = {}
KNOCK.Think(10.1)
local again = false
for _, m in ipairs(sent) do if m.ent == crate then again = true end end
check("... once, not every frame", not again)
cv.skategm_knock_props = "0"
check("turned off on the server: props are solid again", not SkateGM.EntitySkippers[1](crate))
