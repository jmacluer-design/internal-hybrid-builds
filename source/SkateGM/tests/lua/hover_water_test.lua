dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
local clock = 0
function RealTime() return clock end
function FrameTime() return 1 / 60 end
function IsValid(x) if type(x) == "table" and x.IsValid then return x:IsValid() end return x ~= nil end
local hover = true
function CreateClientConVar(n, d) return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetInt = function() return 0 end, GetString = function() return d end } end
function GetConVar(n) if n == "skategm_hoverboard" then return { GetBool = function() return hover end } end end
MsgC = function() end chat = { AddText = function() end }
local ME = {}
function LocalPlayer() return ME end
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
CONTENTS_WATER, MASK_WATER, MASK_PLAYERSOLID_BRUSHONLY = 32, 16432, 81931
-- a lake: water surface at z 0 for x > 0, a street 300 above a canal for x < -1000
local effects = {}
util = {
	PointContents = function(p) return (p.z < 0 and (p.x > 0 or p.x < -1000)) and CONTENTS_WATER or 0 end,
	TraceLine = function(t)
		if t.mask == MASK_WATER then
			if t.start.x > 0 or t.start.x < -1000 then return { Hit = true, HitPos = Vector(t.start.x, t.start.y, 0), Contents = CONTENTS_WATER } end
			return { Hit = false }
		end
		return { Hit = t.start.x < -1000 and t.start.z > 300 }
	end,
	Effect = function(name) effects[#effects + 1] = name end,
}
function EffectData() return { SetOrigin = function() end, SetScale = function() end, SetFlags = function() end } end
sound = { Play = function() end }
local defined = {}
skategm = { DefineModel = function(name, hulls, mesh) defined[name] = { hulls, mesh } end, SetMovers = function(l) end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
S.phase = "on"

local hull = S.WaterPlateHull()[1]
local flat, minx, maxx = true, 1e9, -1e9
for i = 1, #hull, 3 do
	if hull[i + 2] ~= 0 then flat = false end
	minx, maxx = math.min(minx, hull[i]), math.max(maxx, hull[i])
end
check("the water plate: flat, 3072 wide, in 256-unit tiles", flat and minx == -1536 and maxx == 1536 and #hull == 12 * 12 * 2 * 9)
local ax, ay, bx, by, cx, cy = hull[1], hull[2], hull[4], hull[5], hull[7], hull[8]
check("... facing up", (bx - ax) * (cy - ay) - (by - ay) * (cx - ax) > 0)

local function frame(pos, state)
	clock = clock + 1 / 60
	S.anchor = pos
	S.WaterThink({ HIPS = pos + Vector(0, 0, 36) }, state or "PhysicsGround", clock)
	local list = {}
	for _, feed in ipairs(S.MoverFeeds) do feed(pos, list, clock) end
	return list
end
local list = frame(Vector(300, 40, 1.5))
check("hoverboard over water: a plate at the surface in the moving layer", #list == 1 and list[1][1] == S.WATER_PLATE and list[1][4] == S.WATER_LIFT and list[1][2] == 512 and list[1][3] == 0)
clock = clock + 0.2
list = frame(Vector(-500, 0, 20))
check("over dry land: no plate", #list == 0)
clock = clock + 0.2
list = frame(Vector(-1200, 0, 340))
check("on a street over a canal: no plate (the street's in between)", #list == 0)
list = frame(Vector(300, 40, 1.5), "WipeoutGround")
check("bailing: the plate goes, so you fall in", #list == 0)
list = frame(Vector(300, 40, 1.5), "BipedIdle")
check("on foot: no plate", #list == 0)
hover = false
list = frame(Vector(300, 40, 1.5))
check("not a hoverboard: no plate", #list == 0)
hover = true

math.Rand = math.Rand or function(a, b) return a + (b - a) * math.random() end
Lerp = Lerp or function(t, a, b) return a + (b - a) * t end
local particles = {}
function ParticleEmitter() return {
	SetPos = function() end, Finish = function(self) self.done = true end,
	Add = function(self, mat) local p = setmetatable({ mat = mat }, { __index = function() return function() end end }) particles[#particles + 1] = p return p end,
} end
local bound, begun = {}, {}
function Material(name) return { name = name } end
render = render or {}
render.SetMaterial = function(m) bound[#bound + 1] = m.name end
MATERIAL_QUADS, MATERIAL_TRIANGLE_STRIP = 3, 2
mesh = { Begin = function(kind, n) begun[#begun + 1] = { kind = kind, n = n, mat = bound[#bound], verts = 0 } end, End = function() end,
	Position = function() begun[#begun].verts = begun[#begun].verts + 1 end, TexCoord = function() end, Color = function() end, AdvanceVertex = function() end }
local function ride(x)
	clock = clock + 1 / 60
	local pos = Vector(x, 40, 1.5)
	S.anchor = pos
	S.P = { HIPS = pos + Vector(0, 0, 36), TRUCK_FRONT = pos + Vector(8, 0, 2), TRUCK_BACK = pos + Vector(-8, 0, 2) }
	S.WaterThink(S.P, "PhysicsGround", clock)
end
for i = 1, 120 do ride(300 + i * 8) end
local W = S.wakes[ME]
check("riding on water: the airboat's trail, at most 16 points", W and #W.pts >= 10 and #W.pts <= 16)
bound, begun, particles = {}, {}, {}
hooks["PostDrawTranslucentRenderables/skategm_wakes"](false, false)
local strip, quads = nil, 0
for _, b in ipairs(begun) do
	if b.kind == MATERIAL_TRIANGLE_STRIP and b.mat == "effects/splashwake4" then strip = b end
	if b.kind == MATERIAL_QUADS and b.mat == "effects/splashwake1" then quads = quads + 1 end
end
check("... drawn as one strip in splashwake4, two vertices a point", strip and strip.verts == 2 * #W.pts and strip.n == strip.verts - 2)
check("... foam swirling along the board (splashwake1), both sides", quads == 2)
local sprayOK = #particles > 0
for _, p in ipairs(particles) do if p.mat ~= "effects/splash1" and p.mat ~= "effects/splash2" then sprayOK = false end end
check("... and spray off the nose (splash1 / splash2 particles)", sprayOK)
local half = W.pts[#W.pts]
for i = 1, 200 do clock = clock + 1 / 60 S.anchor = Vector(1260, 40, 1.5) S.WaterThink(S.P, "PhysicsGround", clock) end
check("standing still: the trail fades in half a second", #S.wakes[ME].pts == 0)
hover = false
S.WaterThink(S.P, "PhysicsGround", clock + 1)
check("hover off: the trail state is dropped", S.wakes[ME] == nil)
