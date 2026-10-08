dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
local cmds = {}
concommand = { Add = function(n, f) cmds[n] = f end }
function IsValid(x) return x ~= nil and x ~= false end
function CreateClientConVar(n, d) return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetInt = function() return 0 end, GetString = function() return d end } end
MsgC = function() end chat = { AddText = function() end }
string.Explode = function(sep, s) local out = {} for part in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = part end return out end
local ME = {}
function LocalPlayer() return ME end
function RunConsoleCommand() end
file = { Read = function() return nil end, Exists = function() return false end, Find = function() return {} end, CreateDir = function() end, Write = function() end }
local map = "gm_infmap"
game = { GetMap = function() return map end }

local seen = {}
skategm = {
	Version = function() return "test" end,
	Activate = function(x, y, z) seen.activate = { x, y, z } end,
	CollisionHas = function(x, y, z, r) seen.has = { x, y, z } return true end,
	CollisionNear = function(x, y, z) seen.near = { x, y, z } return { x + 1, y, z, x, y + 1, z, x, y, z + 1 } end,
	SetEntities = function(list) seen.ents = list end,
	SetMovers = function(list) seen.movers = list end,
	Poll = function() return { pos = { 40010, 20, 30 }, bones = { HIPS = { 40010, 20, 70 } }, cam = { pos = { 39900, 0, 100 } } } end,
}
InfMap = { chunk_size = 10000, chunk_resolution = 3, height_function = function(u, v)
	if (u > -0.5 and u < 0.5) or (v > -0.5 and v < 0.5) then return -15 end
	return u * 100 + v
end }
local allEnts = {}
ents = { GetAll = function() return allEnts end, FindInSphere = function() return {} end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
if not S.infmap then dofile("../../addon/skategm/lua/skategm/cl_infmap.lua") end
local IM = S.infmap
IM.Setup()
check("the original InfMap: its own backend, the map's box left out", IM.backend == "infmap1" and IM.on and S.extraOff == "world")
local function has(list, f) for _, g in ipairs(list or {}) do if g == f then return true end end return false end
check("... its terrain is a collision source", has(S.HullProviders, IM.Inf1Hulls) and has(S.HullProviders, IM.Inf1PhysHulls))
check("chunk 0: no frame offset", S.Offset() == nil)

ME.CHUNK_OFFSET = Vector(2, 0, 0)
check("in chunk 2: Lua's frame is 40000 units off", S.Offset() and S.Offset().x == 40000)
check("the module is wrapped", rawget(skategm, "__frame") == true)
skategm.Activate(10, 20, 30)
check("... Activate gets absolute coordinates", seen.activate[1] == 40010 and seen.activate[2] == 20)
local p = skategm.Poll()
check("... Poll gives Lua's (chunk-relative) ones back", p.pos[1] == 10 and p.bones.HIPS[1] == 10 and p.cam.pos[1] == -100)
local t = skategm.CollisionNear(5, 0, 0)
check("... CollisionNear: asked absolute, answered relative", seen.near[1] == 40005 and t[1] == 6)
check("ToAbs / FromAbs", S.ToAbs(Vector(1, 2, 3)).x == 40001 and S.FromAbs(Vector(40001, 0, 0)).x == 1)

local list, sig = {}, {}
IM.Inf1Feed(Vector(5000, 0, 0), list, sig)
check("the 3 x 3 chunks around the skater are fed", #list == 9)
local mid
for _, e in ipairs(list) do if e[1] == "skategm_inf1:2:0" then mid = e end end
check("... each at its chunk's centre, in Lua's frame", mid and mid[2] == 0 and mid[3] == 0 and mid[4] == 0)
skategm.SetEntities(list)
local placed
for _, e in ipairs(seen.ents) do if e[1] == "skategm_inf1:2:0" then placed = e end end
check("... which the module gets absolute", placed and placed[2] == 40000)
IM.Inf1Feed(Vector(12000, 0, 0), list, sig)
check("crossing into the next chunk shifts the 3 x 3", list[#list][1] == "skategm_inf1:4:1")

local hulls, mesh = IM.Inf1Hulls("skategm_inf1:2:0")
local flat = hulls[1]
check("a chunk's terrain: 3 x 3 squares, 2 triangles each, as a mesh", mesh == true and #flat == 3 * 3 * 2 * 9)
local okUp, inside, heights = true, true, true
for i = 1, #flat, 9 do
	local ax, ay, bx, by, cx, cy = flat[i], flat[i + 1], flat[i + 3], flat[i + 4], flat[i + 6], flat[i + 7]
	if (bx - ax) * (cy - ay) - (by - ay) * (cx - ax) <= 0 then okUp = false end
	for k = 0, 2 do
		local x, y, z = flat[i + 3 * k], flat[i + 3 * k + 1], flat[i + 3 * k + 2]
		if math.abs(x) > 10000 + 20000 / 3 + 0.01 or math.abs(y) > 10000 + 20000 / 3 + 0.01 then inside = false end
		local u, v = (x + 40000) / 20000, y / 20000
		if math.abs(z - InfMap.height_function(u, v)) > 1e-6 then heights = false end
	end
end
check("... every triangle facing up", okUp)
check("... within a square of its own chunk", inside)
check("... at InfMap's own heights", heights)
local total = 0
for x = -1, 1 do total = total + #IM.Inf1Hulls("skategm_inf1:" .. x .. ":0")[1] end
check("neighbouring chunks share no squares", total == 3 * #flat)

check("InfMap's own helper entities aren't collision", S.SkipEntity({ GetClass = function() return "infmap_terrain_collider" end }))
check("... nor props in another chunk", S.SkipEntity({ GetClass = function() return "prop_physics" end, CHUNK_OFFSET = Vector(0, 0, 0) }))
check("... props in my chunk are", not S.SkipEntity({ GetClass = function() return "prop_physics" end, CHUNK_OFFSET = ME.CHUNK_OFFSET }))
check("InfMap1 isn't drawn through InfMap2's render offset", IM.RenderSpace({ HIPS = Vector(1, 0, 0) }).HIPS.x == 1)
check("the diagnostic command exists", cmds.skategm_infmap_why ~= nil)
local lines = IM.Why()
local joined = table.concat(lines, "\n")
check("... and says the backend, the position both ways and the chunk", joined:find("infmap1", 1, true) and joined:find("40010", 1, true) and joined:find("chunk", 1, true))

-- a map whose ground is mesh colliders on a stand-in model (gm_infmap_vicecity:
-- vicecity_collider; InfMap's own OBJ colliders use a cinder block)
local function Collider(class, chunk, mesh)
	local phys = { IsValid = function() return true end, GetMesh = function() return mesh end }
	return { GetClass = function() return class end, CHUNK_OFFSET = chunk, EntIndex = function() return 77 end,
		GetPos = function() return Vector(0, 0, 0) end, GetPhysicsObject = function() return phys end, IsValid = function() return true end,
		GetModel = function() return "models/props_junk/CinderBlock01a.mdl" end }
end
local tri = { { pos = Vector(-5000, -5000, 100) }, { pos = Vector(5000, -5000, 100) }, { pos = Vector(5000, 5000, 120) } }
-- (a map marks its own colliders as InfMap helpers, as gm_infmap_vicecity does)
InfMap.filter = InfMap.filter or {}
InfMap.filter.vicecity_collider = true
local mine = Collider("vicecity_collider", ME.CHUNK_OFFSET, tri)
local away = Collider("infmap_obj_collider", Vector(9, 9, 0), tri)
allEnts = { mine, away }
InfMap.height_function = nil
map = "gm_infmap_vicecity"
IM.Setup()
check("an InfMap map with no generated terrain: still the InfMap path", IM.backend == "infmap1" and S.extraOff == "world")
check("mesh colliders aren't fed as their stand-in model", S.SkipEntity(mine) and S.SkipEntity(away))
list, sig = {}, {}
IM.Inf1Feed(Vector(0, 0, 0), list, sig)
check("... they're fed by their real shape: mine, not one in another chunk", #list == 1 and list[1][1]:find("skategm_inf1phys:", 1, true) == 1 and IM.physOf[list[1][1]] == mine)
check("... and no generated terrain on a map without it", IM.physCount == 1)
local h, isMesh = IM.Inf1PhysHulls(list[1][1])
check("... the shape is its physics mesh, as a mesh", isMesh == true and #h[1] == 9 and h[1][3] == 100 and h[1][9] == 120)
skategm.SetEntities(list)
check("... placed absolute, like everything else", seen.ents[1][2] == 40000)

-- ahead of time: the chunks around me from the map's own data
InfMap.ezcoord = function(v) return v.x .. "," .. v.y .. "," .. v.z end
InfMap.parsed_collision_data = { ["3,0,0"] = { { { pos = Vector(0, 0, 50) }, { pos = Vector(100, 0, 50) }, { pos = Vector(0, 100, 50) } } } }
IM.Setup()
list, sig = {}, {}
IM.Inf1Feed(Vector(0, 0, 0), list, sig)
local byName = {}
for _, e in ipairs(list) do byName[e[1]] = e end
local objName = "skategm_inf1obj:3,0,0#1"
check("the next chunk's OBJ collision is fed before I get there", byName[objName] and byName[objName][2] == 60000 - 40000)
local hO = IM.Inf1ChunkHulls(objName)
check("... with its triangles, relative to its chunk", #hO[1] == 9 and hO[1][3] == 50)
check("... so InfMap's own OBJ colliders aren't read twice", IM.Covered("infmap_obj_collider") and not IM.Covered("vicecity_collider"))

-- a map's own colliders in the chunk next to mine (asked for ahead by the
-- server) come in too, placed where InfMap says they are; two chunks away don't
InfMap.filter.vicecity_collider = true
local nextDoor = Collider("vicecity_collider", Vector(3, 0, 0), tri)
local far = Collider("vicecity_collider", Vector(5, 0, 0), tri)
nextDoor.EntIndex = function() return 78 end
far.EntIndex = function() return 79 end
allEnts = { mine, nextDoor, far }
list, sig = {}, {}
IM.Inf1Feed(Vector(0, 0, 0), list, sig)
local got = {}
for _, e in ipairs(list) do local c = IM.physOf[e[1]] if c then got[c:EntIndex()] = true end end
check("map colliders: mine and the next chunk's, not one two chunks away", got[77] and got[78] and not got[79])

-- map-made collision comes with either winding; the skater's collision is one-sided
local down = IM.Orient({ 0, 0, 0, 0, 100, 0, 100, 0, 0 })
local nz = (down[4] - down[1]) * (down[8] - down[2]) - (down[5] - down[2]) * (down[7] - down[1])
check("a floor wound downwards is turned to face up", #down == 9 and nz > 0)
local wall = IM.Orient({ 0, 0, 0, 100, 0, 0, 0, 0, 100 })
check("a wall gets both sides", #wall == 18)
check("an up-facing floor stays as it is", #IM.Orient({ 0, 0, 0, 100, 0, 0, 0, 100, 0 }) == 9)

-- a map collider's mesh is read once, not on every entity feed
local reads = 0
local phys = { IsValid = function() return true end, GetMesh = function() reads = reads + 1 return tri end }
local big = Collider("vicecity_collider", ME.CHUNK_OFFSET, tri)
big.GetPhysicsObject = function() return phys end
big.EntIndex = function() return 90 end
big.GetPos = function() return Vector(4000, 0, 0) end
allEnts = { big }
for _ = 1, 10 do list, sig = {}, {} IM.Inf1Feed(Vector(0, 0, 0), list, sig) end
check("ten entity feeds: the collider's mesh read once (no stutter on big maps)", reads == 1)

-- a map rebuilding a chunk's collider (nobody there, then someone back): the
-- same shape, so no new mesh read and no new definition
local function Placed(entIndex, pos)
	local reads = { n = 0 }
	local ph = { IsValid = function() return true end, GetMesh = function() reads.n = reads.n + 1 return tri end }
	local c = Collider("vicecity_collider", ME.CHUNK_OFFSET, tri)
	c.GetPhysicsObject = function() return ph end
	c.EntIndex = function() return entIndex end
	c.GetPos = function() return pos end
	c.GetModel = function() return "models/vicecitychunkscol/1_0_0_col.mdl" end
	return c, reads
end
local clock = 100
RealTime = function() return clock end
local first, r1 = Placed(100, Vector(10, 20, 30))
allEnts = { first }
list, sig = {}, {}
IM.Inf1Feed(Vector(0, 0, 0), list, sig)
local name1 = list[1] and list[1][1]
check("a map collider is named by its model and place, not its entity", name1 and name1:find("1_0_0_col.mdl", 1, true) and not name1:find(":100:", 1, true))
IM.Inf1PhysHulls(name1)
local again, r2 = Placed(101, Vector(10, 20, 30))
allEnts = { again }
list, sig = {}, {}
IM.Inf1Feed(Vector(0, 0, 0), list, sig)
check("... rebuilt by the map (a new entity): the same name", list[1] and list[1][1] == name1)
check("... without reading its mesh again", r2.n == 0)
local other = Placed(102, Vector(500, 20, 30))
allEnts = { other }
list, sig = {}, {}
IM.Inf1Feed(Vector(0, 0, 0), list, sig)
local otherName
for _, e in ipairs(list) do if IM.physOf[e[1]] == other then otherName = e[1] end end
check("one somewhere else is a different shape", otherName and otherName ~= name1)

-- gone (the map dropped the chunk just left): still fed a few seconds, so the
-- collision isn't rebuilt twice when it comes back
local t0 = RealTime()
allEnts = {}
list, sig = {}, {}
IM.Inf1Feed(Vector(0, 0, 0), list, sig)
local kept = false
for _, e in ipairs(list) do if e[1] == name1 then kept = true end end
check("a collider that's just gone stays in the feed for a moment", kept)
clock = t0 + IM.LINGER + 1
list, sig = {}, {}
IM.Inf1Feed(Vector(0, 0, 0), list, sig)
kept = false
for _, e in ipairs(list) do if e[1] == name1 then kept = true end end
check("... and leaves it after IM.LINGER seconds", not kept)

-- read before the map finished it (or after it went): asked again later,
-- never defined empty
local gone = Placed(103, Vector(900, 20, 30))
allEnts = { gone }
list, sig = {}, {}
IM.Inf1Feed(Vector(0, 0, 0), list, sig)
local goneName = list[1][1]
IM.physOf[goneName] = nil
check("a collider that can't be read yet says so (not an empty shape)", IM.Inf1PhysHulls(goneName) == S.LATER)

-- a module that orients meshes itself (DefineModel mode 2): handed over raw
skategm.MeshModes = function() return 2 end
local downFlat = { 0, 0, 0, 0, 100, 0, 100, 0, 0 }
local hh, mode = IM.Oriented(downFlat)
check("a module that turns meshes up itself gets them raw, mode 2 (no Lua work per chunk)", mode == 2 and hh[1] == downFlat)
skategm.MeshModes = nil
local hl, ml = IM.Oriented(downFlat)
check("... an older module: turned here, as before", ml == true and #hl[1] == 9 and hl[1][5] ~= 100)
