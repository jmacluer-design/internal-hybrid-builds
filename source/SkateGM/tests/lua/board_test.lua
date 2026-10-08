dofile("gmock.lua")
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
function RealTime() return 0 end
function IsValid(x) if type(x) == "table" and x.IsValid then return x:IsValid() end return x ~= nil end
function CreateClientConVar(n, d) return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetString = function() return d end } end
MsgC = function() end chat = { AddText = function() end }
function LocalPlayer() return {} end
MATERIAL_TRIANGLES = 2
-- mock mesh API: record vertices; count draws and transforms
local built, draws = {}, {}
local cur
function Mesh() local m = { verts = {} } function m:Draw() draws[#draws + 1] = { mesh = self, M = CURRENT_M } end return m end
mesh = {
	Begin = function(m, kind, count) cur = m m.count = count end,
	Position = function(p) cur.verts[#cur.verts + 1] = { pos = p } end,
	Normal = function() end,
	TexCoord = function() end,
	Color = function(r, g, b) cur.verts[#cur.verts].col = { r, g, b } end,
	AdvanceVertex = function() end,
	End = function() built[#built + 1] = cur end,
}
cam = { PushModelMatrix = function(M) CURRENT_M = M end, PopModelMatrix = function() CURRENT_M = nil end }
function Material() return {} end
render = setmetatable({ GetLightColor = function() return Vector(0.5, 0.5, 0.5) end }, { __index = function() return function() end end })
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local B = SkateGM.test.board
-- deck geometry
local deck = B.DeckTriangles(Color(40, 120, 220))
local lo, hi = Vector(1e9, 1e9, 1e9), Vector(-1e9, -1e9, -1e9)
local topGrip, bottomBlue, midZ, tipZ = 0, 0, 0, -1
for _, t in ipairs(deck) do
	for i = 1, 3 do local p = t[i] lo = Vector(math.min(lo.x, p.x), math.min(lo.y, p.y), math.min(lo.z, p.z)) hi = Vector(math.max(hi.x, p.x), math.max(hi.y, p.y), math.max(hi.z, p.z)) end
	local c = t[5][1]
	if c.r == 40 and c.g == 40 then topGrip = topGrip + 1 end
	if c.b == 220 then bottomBlue = bottomBlue + 1 end
	for i = 1, 3 do if math.abs(t[i].x) > 15.5 then tipZ = math.max(tipZ, t[i].z) end end
end
print(string.format("deck: %d triangles, %.1f long x %.1f wide %s", #deck, hi.x - lo.x, hi.y - lo.y,
	math.abs(hi.x - lo.x - 32) < 0.1 and math.abs(hi.y - lo.y - 8) < 0.1 and "OK (32 x 8, like a real deck)" or "<-- WRONG"))
print(string.format("kicktails raised: nose/tail tip %.1f units above the middle %s", tipZ, tipZ > 1.5 and tipZ < 3 and "OK" or "<-- WRONG"))
print("grip on top, rider's colour underneath:", topGrip > 100 and bottomBlue > 100 and "OK" or "<-- WRONG")
local truck = B.TruckTriangles()
print(string.format("truck: %d triangles (axle, hanger, bushings, baseplate, 2 round wheels) %s", #truck, #truck > 150 and "OK" or "<-- WRONG"))
-- drawing from engine bones: a board heading +x at z=0 with a 14-unit wheelbase
local P = { TRUCK_FRONT = Vector(7, 0, 1.5), TRUCK_BACK = Vector(-7, 0, 1.5),
	RIGHT_WHEELFRONT = Vector(7, -3.2, 0), LEFT_WHEELFRONT = Vector(7, 3.2, 0), RIGHT_WHEELBACK = Vector(-7, -3.2, 0), LEFT_WHEELBACK = Vector(-7, 3.2, 0) }
B.DrawBoard(P, { graphic = Color(40, 120, 220) })
print("mesh error:", SkateGM.meshErr)
print(string.format("drawn as meshes: %d draws (deck + 2 trucks) %s", #draws, #draws == 3 and "OK" or "<-- WRONG"))
local d = draws[1] and draws[1].M
if d then
	local o = d:GetTranslation()
	print(string.format("deck placed at %.1f %.1f %.1f (between trucks, ~2 above the axles) %s", o.x, o.y, o.z, math.abs(o.x) < 0.01 and math.abs(o.z - 2) < 0.01 and "OK" or "<-- WRONG"))
end
print(string.format("each triangle emitted both ways round: %d vertices for %d triangles %s", #built[1].verts, #deck, #built[1].verts == #deck * 6 and "OK" or "<-- WRONG"))
local red = B.DeckTriangles(Color(40, 120, 220), Color(200, 10, 10))
local redTop, blueBottom = 0, 0
for _, t in ipairs(red) do
	if t[5][1].r == 200 and t[5][1].g == 10 then redTop = redTop + 1 end
	if t[5][1].b == 220 then blueBottom = blueBottom + 1 end
end
print("deck colour of the rider's choosing on top, graphic underneath:", redTop == topGrip and blueBottom == bottomBlue and "OK" or "<-- WRONG")
local blue = B.TruckTriangles(Color(20, 40, 250))
local blueWheel = 0
for _, t in ipairs(blue) do if t[5][1].b == 250 then blueWheel = blueWheel + 1 end end
print("wheel colour of the rider's choosing:", blueWheel > 50 and "OK" or "<-- WRONG")
local under = B.UnderTriangles()
local ulo, uhi, below, uvok = 1, 0, true, true
for _, t in ipairs(under) do
	for i = 1, 3 do
		local uv = t[6][i]
		if uv[1] < -1e-6 or uv[1] > 1 + 1e-6 or uv[2] < -1e-6 or uv[2] > 1 + 1e-6 then uvok = false end
		ulo, uhi = math.min(ulo, uv[2]), math.max(uhi, uv[2])
	end
end
local noseT
for _, t in ipairs(under) do for i = 1, 3 do if t[i].x > 15 then noseT = math.min(noseT or 1, t[6][i][2]) end end end
print(string.format("underside image: %d triangles, texture inside the image %s", #under, #under == 48 * 8 * 2 and uvok and ulo < 0.01 and uhi > 0.99 and "OK" or "<-- WRONG"))
print("image top at the nose:", noseT and noseT < 0.05 and "OK" or "<-- WRONG")
local function tex(w, h) return { GetTexture = function() return { Width = function() return w end, Height = function() return h end } end } end
local wide, tall = SkateGM.UnderFit(tex(1000, 1000)), SkateGM.UnderFit(tex(100, 1000))
print("scale to fill: a square picture shows the middle quarter-ish of its width, all its height", wide and wide[2] == 1 and wide[1] > 0.2 and wide[1] < 0.3 and "OK" or "<-- WRONG")
print("... a very tall one all its width, part of its height", tall and tall[1] == 1 and tall[2] > 0.3 and tall[2] < 0.5 and "OK" or "<-- WRONG")
local filled = B.UnderTriangles(wide[1], wide[2])
local fx, ulo2, uhi2, vlo2, vhi2 = 0, 1, 0, 1, 0
for _, t in ipairs(filled) do
	for i = 1, 3 do
		fx = math.max(fx, math.abs(t[i].x))
		local uv = t[6][i]
		ulo2, uhi2, vlo2, vhi2 = math.min(ulo2, uv[1]), math.max(uhi2, uv[1]), math.min(vlo2, uv[2]), math.max(vhi2, uv[2])
	end
end
print("... the whole deck is covered, the picture's middle on it (not stretched)", fx > 15 and ulo2 > 0.35 and uhi2 < 0.65 and vlo2 < 0.01 and vhi2 > 0.99 and "OK" or "<-- WRONG")
draws = {}
local setMats = {}
render.SetMaterial = function(m) setMats[#setMats + 1] = m end
local IMG = { image = true }
B.DrawBoard(P, { graphic = Color(40, 120, 220), wheel = Color(20, 40, 250), under = IMG })
local imgDrawn = false
for k, m in ipairs(setMats) do if m == IMG then imgDrawn = true end end
print(string.format("with an image: %d draws (deck, image, 2 trucks), image material used %s", #draws, #draws == 4 and imgDrawn and setMats[#setMats] ~= IMG and "OK" or "<-- WRONG"))
local rocket = B.RocketTriangles()
local rlo, rhi = 1e9, -1e9
for _, t in ipairs(rocket) do for i = 1, 3 do rlo, rhi = math.min(rlo, t[i].x), math.max(rhi, t[i].x) end end
print(string.format("rocket model: %d triangles on the tail, x %.1f to %.1f %s", #rocket, rlo, rhi, #rocket > 50 and rhi < -8 and rlo > -21 and "OK" or "<-- WRONG"))
draws = {}
B.DrawBoard(P, { graphic = Color(40, 120, 220), rocket = true })
print(string.format("with the rocket on: %d draws (deck, rocket, 2 trucks) %s", #draws, #draws == 4 and "OK" or "<-- WRONG"))
draws = {}
B.DrawBoard(P, { graphic = Color(40, 120, 220), trucks = false })
print(string.format("hoverboard mode: the deck alone, no trucks or wheels: %d draws %s", #draws, #draws == 1 and "OK" or "<-- WRONG"))
draws = {}
B.DrawBoard(P, { graphic = Color(40, 120, 220), deck = false })
print(string.format("  a model board with wheels: trucks only, no deck: %d draws %s", #draws, #draws == 2 and "OK" or "<-- WRONG"))
draws = {}
local PATTERN = { name = "pattern" }
B.DrawBoard(P, { graphic = Color(40, 120, 220), pattern = PATTERN, patternColor = Color(255, 0, 0) })
print(string.format("grip tape pattern: one more layer on the deck: %d draws %s", #draws, #draws == 4 and "OK" or "<-- WRONG"))
local top = SkateGM.L.TopTriangles(Color(255, 0, 0))
local above, tiled = true, 0
for _, t in ipairs(top) do
	for k = 1, 3 do tiled = math.max(tiled, t[6][k][2]) end
	if t[4].z <= 0 then above = false end
end
print(string.format("  facing up, over the grip, tiled %.0f times along the deck %s", tiled, above and math.abs(tiled - 4) < 1e-6 and "OK" or "<-- WRONG"))
local thr
ClientsideModel = function(m) thr = { model = m, drawn = 0 } function thr:IsValid() return true end function thr:SetNoDraw() end function thr:SetModelScale(sc) self.scale = sc end
	function thr:SetPos(p) self.pos = p end function thr:SetAngles(a) self.ang = a end function thr:DrawModel() self.drawn = self.drawn + 1 end return thr end
-- as in GMod: client-side, a model isn't "valid" until it's precached
local precached = false
util.IsValidModel = function() return precached end
util.PrecacheModel = function() precached = true end
file = file or {}
file.Exists = function(p, where) return p == "models/maxofs2d/thruster_projector.mdl" and where == "GAME" end
local clock = 100
RealTime = function() clock = clock + 10 return clock end
draws = {}
B.DrawBoard(P, { graphic = Color(40, 120, 220), rocket = true })
print(string.format("the rocket is GMod's thruster model, deck-wide, off the tail's tip (x %.2f z %.2f) %s", thr and thr.pos.x or 0, thr and thr.pos.z or 0, thr and thr.model == "models/maxofs2d/thruster_projector.mdl" and thr.drawn == 1 and thr.scale == 0.4 and math.abs(thr.pos.x + 16) < 0.01 and thr.pos.z > 3.6 and thr.pos.z < 4.1 and #draws == 3 and "OK" or "<-- WRONG"))
local nozzleDir = thr.ang:Up()
print(string.format("  its nozzle points back, away from the nose (%.2f) %s", nozzleDir.x, nozzleDir.x < -0.99 and "OK" or "<-- WRONG"))
-- no Mesh available: the box board is drawn instead
Mesh = nil
local quads = 0
render.DrawQuad = function() quads = quads + 1 end
B.DrawBoard(P)
print("falls back to the box board without meshes:", quads > 0 and "OK" or "<-- WRONG")
