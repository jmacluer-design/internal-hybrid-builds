dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
function IsValid(x) return x ~= nil end
string.Explode = function(sep, s) local out = {} for part in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = part end return out end
local map = "gm_construct"
game = { GetMap = function() return map end }
local ME = { GetRealm = function() return "default" end }
function LocalPlayer() return ME end
local frozen
local near = false
skategm = { CollisionHas = function() return near end, SetFrozen = function(v) frozen = v end }
SkateGM = { phase = "on", pose = { pos = { 50000, 0, 10 } } }
local S = SkateGM

dofile("../../addon/skategm/lua/skategm/cl_infmap.lua")
local IM = S.infmap
check("a normal map: InfMap stays out of the way", not IM.on and S.extraOff == nil and S.RenderSpace == nil and S.HullProviders == nil)

-- a stand-in InfMap2: 20000-unit chunks, a gently sloping terrain
local calls = 0
InfMap2 = {
	ChunkSize = 20000, SourceBounds = Vector(16384, 16384, 16384), MainViewOffset = Vector(40000, 0, 0), ViewOffsetStack = {},
	Realms = { default = { Generator = { GenerateChunkPhysics = function(megapos, realm)
		calls = calls + 1
		if megapos.z ~= 0 then return {} end
		local a, b, c = Vector(-100, -100, 0), Vector(-100, 100, 0), Vector(100, -100, 1)
		return { a, b, c }
	end } } },
}
map = "gm_inf_bliss"
IM.Setup()
check("an infinite map: InfMap on, the map's own box left out", IM.on and S.extraOff == "world")
check("... its terrain is a collision source", S.HullProviders and S.HullProviders[1] == IM.Hulls and S.ExtraFeeds[1] == IM.Feed)
check("cells as InfMap2 counts them", IM.Cell(9999) == 0 and IM.Cell(10001) == 1 and IM.Cell(-10001) == -1)

local list, sig = {}, {}
IM.Feed(Vector(45000, 1000, 10), list, sig)
check("the 3 x 3 x 3 chunks around the skater are placed", #list == 27)
local centre
for _, e in ipairs(list) do if e[1] == "skategm_inf:default:2:0:0" then centre = e end end
check("... each at its chunk's centre, in absolute coordinates", centre and centre[2] == 40000 and centre[3] == 0 and centre[4] == 0)
local hulls, isMesh, from = S.HullProviders[1]("skategm_inf:default:2:0:0")
local flat = hulls and hulls[1]
check("a chunk's shape: InfMap2's own physics mesh, as a mesh", isMesh == true and flat and #flat == 9 and from == "InfMap terrain")
local ax, ay, az = flat[1], flat[2], flat[3]
local bx, by = flat[4], flat[5]
local cx, cy = flat[7], flat[8]
check("... every triangle facing up", (bx - ax) * (cy - ay) - (by - ay) * (cx - ax) > 0)
check("other models aren't ours", S.HullProviders[1]("models/props_c17/oildrum001.mdl") == nil)
S.HullProviders[1]("skategm_inf:default:2:0:1")
list, sig = {}, {}
IM.Feed(Vector(45000, 1000, 10), list, sig)
check("an empty chunk (all sky) isn't placed again", #list == 26)

check("InfMap's own helper entities aren't collision", S.SkipEntity({ GetClass = function() return "inf_chunk" end, GetRealm = function() return "default" end }))
check("... nor things in another realm (another planet)", S.SkipEntity({ GetClass = function() return "prop_physics" end, GetRealm = function() return "mun" end }))
check("... props here are", not S.SkipEntity({ GetClass = function() return "prop_physics" end, GetRealm = function() return "default" end }))

local P = { HIPS = Vector(45000, 10, 40), HEAD = Vector(45000, 10, 70) }
local R = S.RenderSpace(P)
check("bones are drawn relative to the camera's cell", R.HIPS.x == 5000 and R.HEAD.z == 70 and P.HIPS.x == 45000)
local e = { Sk8Render = function() end }
e.RenderOverride = function() end
local wsb
e.INF_SetRenderBoundsWS = function(_, a, b) wsb = b end
S.AfterPlace(e)
check("InfMap2's render override is kept off our skater", e.RenderOverride == e.Sk8Render and wsb == InfMap2.SourceBounds)

near = false
IM.Think()
check("no terrain under the skater yet: held still", frozen == 1 and IM.waiting)
near = true
IM.Think()
check("terrain built: free again", frozen == 0 and not IM.waiting)
