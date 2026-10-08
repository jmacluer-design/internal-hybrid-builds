dofile("gmock.lua")
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
local registered = {}
scripted_ents = { Register = function(t, class) registered[class] = t end }
local files = {}
file = { Find = function() return files end }
local partFiles = { "bank", "deck", "flat_bar", "funbox", "half_pipe", "kicker", "launch_ramp", "ledge", "manual_pad", "quarter_pipe", "spine", "stairs" }
for _, f in ipairs(partFiles) do files[#files + 1] = f .. ".lua" end
local included = {}
function include(f) included[#included + 1] = f dofile("../../addon/skategm/lua/" .. f) end
function AddCSLuaFile() end
SERVER = true
dofile("../../addon/skategm/lua/autorun/skategm_parts_load.lua")
local P = SKATEGM_PARTS

check("the loader picks up every part file (and the park editor)", #included == #partFiles + 3)
check("the base entity is registered", registered.skategm_part and registered.skategm_part.SkateGMPart)
local listed, total = 0, 0
for class, e in pairs(registered) do
	if class ~= "skategm_part" then
		total = total + 1
		if e.Spawnable and e.Category:find("^SkateGM") and e.Base == "skategm_part" and P.Get(e.PartId) then listed = listed + 1 end
	end
end
check("every part (" .. total .. " of them, every size) is in a SkateGM spawn menu category", total >= 40 and listed == total)
local old = { "flat_bar", "funbox", "kicker", "launch_ramp", "ledge", "manual_pad", "quarter_pipe", "stairs" }
local kept = 0
for _, id in ipairs(old) do if registered["skategm_part_" .. id] then kept = kept + 1 end end
check("the parts from before keep their ids (maps and saved parks still load)", kept == #old)

local function key(v) return string.format("%.3f,%.3f,%.3f", v.x, v.y, v.z) end
for _, def in ipairs(P.Ordered()) do
	local sh = P.Shape(def)
	local edges, vol = {}, 0
	for _, t in ipairs(sh.tris) do
		vol = vol + t[1]:Dot(t[2]:Cross(t[3])) / 6
		for i = 1, 3 do
			local a, b = key(t[i]), key(t[i % 3 + 1])
			edges[a .. ">" .. b] = (edges[a .. ">" .. b] or 0) + 1
		end
	end
	local open = 0
	for e, n in pairs(edges) do
		local a, b = e:match("^(.-)>(.-)$")
		if n ~= 1 or edges[b .. ">" .. a] ~= 1 then open = open + 1 end
	end
	local facing = true
	for _, t in ipairs(sh.tris) do
		local n = (t[2] - t[1]):Cross(t[3] - t[1])
		if n:Dot(t[4]) <= 0 then facing = false end
	end
	local convexOk = true
	for _, c in ipairs(sh.convex) do
		if #c < 4 then convexOk = false end
	end
	local size = sh.maxs - sh.mins
	check(string.format("%-13s closed mesh, outward (%d tris, %.0f x %.0f x %.0f)", def.id, #sh.tris, size.x, size.y, size.z),
		open == 0 and vol > 0 and facing and convexOk and math.abs(sh.mins.z) < 1e-6 and math.abs(sh.mins.x + sh.maxs.x) < 1e-6 and #sh.flat == #sh.tris * 9)
end

local qp = P.Shape(P.Get("quarter_pipe"))
local steep = 0
for _, t in ipairs(qp.tris) do if t[4].z > 0.05 and t[4].z < 0.4 then steep = steep + 1 end end
check("the quarter pipe curves all the way to near vertical", steep >= 4 and math.abs(qp.maxs.z - 96) < 2)
local kick = P.Shape(P.Get("kicker"))
local lip = false
for _, t in ipairs(kick.tris) do
	for k = 1, 3 do if t[k].x < kick.mins.x + 0.01 and t[k].z > 0.01 then lip = true end end
end
check("the kicker's foot meets the ground with no edge to catch the wheels", not lip)
check("engine names round-trip", P.FromEngineName(P.EngineName("ledge")) == P.Get("ledge") and P.FromEngineName("models/x.mdl") == nil)
local tri = P.Triangulate({ { 0, 0 }, { 96, 0 }, { 96, 24 }, { 32, 24 }, { 32, 16 }, { 16, 16 }, { 16, 8 }, { 0, 8 } })
local area = 0
for _, t in ipairs(tri) do area = area + ((t[2][1] - t[1][1]) * (t[3][2] - t[1][2]) - (t[2][2] - t[1][2]) * (t[3][1] - t[1][1])) / 2 end
check("a concave profile is cut into triangles covering it exactly", #tri == 6 and math.abs(area - (16 * 8 + 16 * 16 + 64 * 24)) < 1e-6)

CLIENT, SERVER = true, false
local verts = {}
function Mesh() return { Draw = function() end } end
MATERIAL_TRIANGLES = 4
mesh = { Begin = function() end, End = function() end, Normal = function() end, TexCoord = function() end, Color = function() end, AdvanceVertex = function() end,
	Position = function(v) verts[#verts + 1] = v end }
function CreateMaterial() return {} end
dofile("../../addon/skategm/lua/skategm_parts/sh_parts.lua")
P = SKATEGM_PARTS
local def = P.Get("funbox")
P.Meshes(def, 1)
local sh, front = P.Shape(def), 0
for i = 1, #verts, 3 do
	local a, b, c = verts[i], verts[i + 1], verts[i + 2]
	local n = sh.tris[(i + 2) / 3][4]
	if (b - a):Cross(c - a):Dot(n) < 0 then front = front + 1 end
end
check("drawn clockwise seen from outside (Source's front faces)", #verts > 0 and front == #verts / 3)

-- copings are drawn only: nothing in the collision stands above a quarter
-- pipe's deck or out in front of its lip
for _, id in ipairs({ "quarter_pipe", "quarter_pipe_48x128", "half_pipe_96_128", "spine_72" }) do
	local sh = P.Shape(P.Get(id))
	local top = sh.maxs.z
	local proud = false
	for _, t in ipairs(sh.tris) do for k = 1, 3 do if t[k].z > top + 1e-3 then proud = true end end end
	check(id .. ": the coping is drawn but not solid", #sh.looks > #sh.tris and not proud and math.abs(top - (P.Get(id).size.r or top)) < 1e-3)
end
