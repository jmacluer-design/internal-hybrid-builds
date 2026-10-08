SKATEGM_PARTS = SKATEGM_PARTS or { list = {}, shapes = {}, meshes = {} }
local PARTS = SKATEGM_PARTS

PARTS.CATEGORY = "SkateGM"
PARTS.SURFACES = {
	concrete = { texture = "concrete/concretefloor001a", scale = 128, tint = { 200, 200, 196 } },
	wood = { texture = "wood/woodfloor005a", scale = 128, tint = { 235, 220, 200 } },
	metal = { texture = "metal/metalpipe001a", scale = 32, tint = { 210, 214, 222 } },
	paint = { texture = "concrete/concretefloor001a", scale = 128, tint = { 70, 120, 200 } },
}
PARTS.BASE_MODEL = "models/hunter/blocks/cube025x025x025.mdl"

function PARTS.Prism(axis, profile, from, to, surface, convex)
	return { axis = axis, profile = profile, from = from, to = to, surface = surface, convex = convex }
end

function PARTS.Box(x0, y0, z0, x1, y1, z1, surface)
	return PARTS.Prism("y", { { x0, z0 }, { x1, z0 }, { x1, z1 }, { x0, z1 } }, y0, y1, surface)
end

function PARTS.Pipe(axis, from, to, cu, cv, radius, surface, sides)
	local profile = {}
	sides = sides or 8
	for i = 0, sides - 1 do
		local a = (i + 0.5) / sides * math.pi * 2
		profile[#profile + 1] = { cu + math.cos(a) * radius, cv + math.sin(a) * radius }
	end
	return PARTS.Prism(axis, profile, from, to, surface or "metal")
end

-- a coping along a lip: drawn only, its top flush with the deck at height v
function PARTS.Coping(axis, from, to, cu, v, radius)
	local piece = PARTS.Pipe(axis, from, to, cu, v - radius, radius)
	piece.visual = true
	return piece
end

function PARTS.CurveUp(x0, x1, height, power, steps)
	local pts = {}
	for i = 0, steps do
		local f = i / steps
		pts[#pts + 1] = { x0 + (x1 - x0) * f, height * f ^ power }
	end
	return pts
end

function PARTS.QuarterCurve(x0, radius, steps)
	local pts = {}
	for i = 0, steps do
		local t = i / steps * math.pi / 2
		pts[#pts + 1] = { x0 + radius * math.sin(t), radius - radius * math.cos(t) }
	end
	return pts
end

function PARTS.UnderCurve(pts)
	local slabs = {}
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		local slab = { { a[1], 0 }, { b[1], 0 } }
		if b[2] > 0 then slab[#slab + 1] = { b[1], b[2] } end
		if a[2] > 0 then slab[#slab + 1] = { a[1], a[2] } end
		if #slab >= 3 then slabs[#slabs + 1] = slab end
	end
	return slabs
end

local function Area(poly)
	local a = 0
	for i = 1, #poly do
		local p, q = poly[i], poly[i % #poly + 1]
		a = a + p[1] * q[2] - q[1] * p[2]
	end
	return a / 2
end

local function CCW(poly)
	if Area(poly) >= 0 then return poly end
	local out = {}
	for i = #poly, 1, -1 do out[#out + 1] = poly[i] end
	return out
end

local function Inside(p, a, b, c)
	local function side(u, v, w) return (v[1] - u[1]) * (w[2] - u[2]) - (v[2] - u[2]) * (w[1] - u[1]) end
	return side(a, b, p) > 1e-9 and side(b, c, p) > 1e-9 and side(c, a, p) > 1e-9
end

function PARTS.Triangulate(poly)
	poly = CCW(poly)
	local idx, out = {}, {}
	for i = 1, #poly do idx[i] = i end
	local guard = 0
	while #idx > 3 and guard < 10000 do
		guard = guard + 1
		local clipped = false
		for k = 1, #idx do
			local ia, ib, ic = idx[(k - 2) % #idx + 1], idx[k], idx[k % #idx + 1]
			local a, b, c = poly[ia], poly[ib], poly[ic]
			local cross = (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
			if cross > 1e-9 then
				local ear = true
				for _, j in ipairs(idx) do
					if j ~= ia and j ~= ib and j ~= ic and Inside(poly[j], a, b, c) then ear = false break end
				end
				if ear then
					out[#out + 1] = { a, b, c }
					table.remove(idx, k)
					clipped = true
					break
				end
			end
		end
		if not clipped then
			for k = 2, #idx - 1 do out[#out + 1] = { poly[idx[1]], poly[idx[k]], poly[idx[k + 1]] } end
			return out
		end
	end
	if #idx == 3 then out[#out + 1] = { poly[idx[1]], poly[idx[2]], poly[idx[3]] } end
	return out
end

local function To3D(axis, u, v, w)
	if axis == "x" then return Vector(w, u, v) end
	return Vector(u, w, v)
end

local function Normal3D(axis, nu, nv)
	if axis == "x" then return Vector(0, nu, nv) end
	return Vector(nu, 0, nv)
end

local function AxisVec(axis)
	if axis == "x" then return Vector(1, 0, 0) end
	return Vector(0, 1, 0)
end

local function Face(out, a, b, c, outward, surface)
	local n = (b - a):Cross(c - a)
	if n:LengthSqr() < 1e-8 then return end
	if n:Dot(outward) < 0 then b, c = c, b n = -n end
	out[#out + 1] = { a, b, c, n:GetNormalized(), surface }
end

function PARTS.PieceTriangles(piece, surface)
	local out = {}
	local poly = CCW(piece.profile)
	local ax = AxisVec(piece.axis)
	local surf = piece.surface or surface
	for _, t in ipairs(PARTS.Triangulate(poly)) do
		Face(out, To3D(piece.axis, t[1][1], t[1][2], piece.to), To3D(piece.axis, t[2][1], t[2][2], piece.to), To3D(piece.axis, t[3][1], t[3][2], piece.to), ax, surf)
		Face(out, To3D(piece.axis, t[1][1], t[1][2], piece.from), To3D(piece.axis, t[2][1], t[2][2], piece.from), To3D(piece.axis, t[3][1], t[3][2], piece.from), -ax, surf)
	end
	for i = 1, #poly do
		local p, q = poly[i], poly[i % #poly + 1]
		local du, dv = q[1] - p[1], q[2] - p[2]
		local outward = Normal3D(piece.axis, dv, -du)
		local a, b = To3D(piece.axis, p[1], p[2], piece.from), To3D(piece.axis, q[1], q[2], piece.from)
		local c, d = To3D(piece.axis, q[1], q[2], piece.to), To3D(piece.axis, p[1], p[2], piece.to)
		Face(out, a, b, c, outward, surf)
		Face(out, a, c, d, outward, surf)
	end
	return out
end

function PARTS.PieceConvexes(piece)
	local out = {}
	for _, poly in ipairs(piece.convex or { piece.profile }) do
		local verts = {}
		for _, p in ipairs(poly) do
			verts[#verts + 1] = To3D(piece.axis, p[1], p[2], piece.from)
			verts[#verts + 1] = To3D(piece.axis, p[1], p[2], piece.to)
		end
		out[#out + 1] = verts
	end
	return out
end

function PARTS.Shape(def)
	local cached = PARTS.shapes[def.id]
	if cached then return cached end
	-- (a piece with visual = true is only drawn: copings, which as collision
	-- stand proud of the deck and stop the board like a wall)
	local tris, convex, looks = {}, {}, {}
	for _, piece in ipairs(def.pieces()) do
		for _, t in ipairs(PARTS.PieceTriangles(piece, def.surface or "concrete")) do
			looks[#looks + 1] = t
			if not piece.visual then tris[#tris + 1] = t end
		end
		if not piece.visual then
			for _, c in ipairs(PARTS.PieceConvexes(piece)) do convex[#convex + 1] = c end
		end
	end
	local lo, hi = Vector(1e9, 1e9, 1e9), Vector(-1e9, -1e9, -1e9)
	for _, t in ipairs(tris) do
		for k = 1, 3 do
			local v = t[k]
			lo = Vector(math.min(lo.x, v.x), math.min(lo.y, v.y), math.min(lo.z, v.z))
			hi = Vector(math.max(hi.x, v.x), math.max(hi.y, v.y), math.max(hi.z, v.z))
		end
	end
	local shift = Vector(-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -lo.z)
	for _, t in ipairs(looks) do
		for k = 1, 3 do t[k] = t[k] + shift end
	end
	local flat = {}
	for _, t in ipairs(tris) do
		for k = 1, 3 do
			flat[#flat + 1] = t[k].x
			flat[#flat + 1] = t[k].y
			flat[#flat + 1] = t[k].z
		end
	end
	for _, c in ipairs(convex) do
		for k = 1, #c do c[k] = c[k] + shift end
	end
	local shape = { tris = tris, looks = looks, convex = convex, flat = flat, mins = lo + shift, maxs = hi + shift }
	PARTS.shapes[def.id] = shape
	return shape
end

function PARTS.Get(id) return PARTS.list[id] end

function PARTS.Ordered()
	local out = {}
	for _, def in pairs(PARTS.list) do out[#out + 1] = def end
	table.sort(out, function(a, b)
		if (a.order or 99) ~= (b.order or 99) then return (a.order or 99) < (b.order or 99) end
		return a.id < b.id
	end)
	return out
end

function PARTS.EngineName(id) return "skategm_part:" .. id end

function PARTS.FromEngineName(name)
	local id = type(name) == "string" and name:match("^skategm_part:([%w_]+)$")
	return id and PARTS.list[id] or nil
end

local BASE = {
	Type = "anim",
	Base = "base_anim",
	PrintName = "SkateGM park part",
	Category = PARTS.CATEGORY,
	Spawnable = false,
	SkateGMPart = true,
	RenderGroup = RENDERGROUP_OPAQUE,
}

function BASE:Part() return PARTS.Get(self.PartId) end

function BASE:Initialize()
	local def = self:Part()
	if not def then return end
	local shape = PARTS.Shape(def)
	self:SetModel(PARTS.BASE_MODEL)
	self:PhysicsInitMultiConvex(shape.convex)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:EnableCustomCollisions(true)
	if SERVER then
		local phys = self:GetPhysicsObject()
		if IsValid(phys) then
			phys:SetMass(def.mass or 400)
			phys:EnableMotion(false)
		end
	else
		self:SetRenderBounds(shape.mins, shape.maxs)
	end
end

function BASE:SpawnFunction(ply, tr, class)
	if not tr.Hit then return end
	local ent = ents.Create(class)
	if not IsValid(ent) then return end
	ent:SetPos(tr.HitPos + tr.HitNormal * 0.5)
	ent:SetAngles(Angle(0, IsValid(ply) and ply:EyeAngles().y or 0, 0))
	ent:Spawn()
	ent:Activate()
	return ent
end

if CLIENT then
	PARTS.mats = PARTS.mats or {}

	function PARTS.Material(surface)
		local m = PARTS.mats[surface]
		if m then return m end
		local s = PARTS.SURFACES[surface] or PARTS.SURFACES.concrete
		m = CreateMaterial("skategm_part_" .. surface, "UnlitGeneric", { ["$basetexture"] = s.texture, ["$vertexcolor"] = "1", ["$model"] = "1" })
		PARTS.mats[surface] = m
		return m
	end

	PARTS.LIGHT = Vector(0.35, 0.25, 0.9):GetNormalized()

	function PARTS.Shade(n, light)
		return math.Clamp((0.45 + 0.55 * math.max(0, n:Dot(PARTS.LIGHT))) * light, 0.08, 1.2)
	end

	function PARTS.UV(v, n, scale)
		local ax, ay, az = math.abs(n.x), math.abs(n.y), math.abs(n.z)
		if az >= ax and az >= ay then return v.x / scale, v.y / scale end
		if ax >= ay then return v.y / scale, -v.z / scale end
		return v.x / scale, -v.z / scale
	end

	function PARTS.Meshes(def, light)
		local bucket = math.floor(light * 8 + 0.5)
		local key = def.id .. "#" .. bucket
		local cached = PARTS.meshes[key]
		if cached then return cached end
		local shape = PARTS.Shape(def)
		local groups = {}
		for _, t in ipairs(shape.looks or shape.tris) do
			local g = groups[t[5]]
			if not g then g = {} groups[t[5]] = g end
			g[#g + 1] = t
		end
		local out = {}
		for surface, tris in pairs(groups) do
			local s = PARTS.SURFACES[surface] or PARTS.SURFACES.concrete
			local m = Mesh()
			mesh.Begin(m, MATERIAL_TRIANGLES, #tris)
			for _, t in ipairs(tris) do
				local k = PARTS.Shade(t[4], bucket / 8)
				local r, g, b = math.min(255, s.tint[1] * k), math.min(255, s.tint[2] * k), math.min(255, s.tint[3] * k)
				for i = 3, 1, -1 do
					local u, v = PARTS.UV(t[i], t[4], s.scale)
					mesh.Position(t[i])
					mesh.Normal(t[4])
					mesh.TexCoord(0, u, v)
					mesh.Color(r, g, b, 255)
					mesh.AdvanceVertex()
				end
			end
			mesh.End()
			out[#out + 1] = { surface = surface, mesh = m }
		end
		PARTS.meshes[key] = out
		return out
	end

	function BASE:Draw()
		local def = self:Part()
		if not def then return end
		local c = render.GetLightColor(self:LocalToWorld(Vector(0, 0, 8)))
		local light = math.Clamp(0.3 + (c.x + c.y + c.z) / 3 * 1.4, 0.3, 1.15)
		local M = Matrix()
		M:SetTranslation(self:GetPos())
		M:SetAngles(self:GetAngles())
		cam.PushModelMatrix(M)
		for _, g in ipairs(PARTS.Meshes(def, light)) do
			render.SetMaterial(PARTS.Material(g.surface))
			g.mesh:Draw()
		end
		cam.PopModelMatrix()
	end
end

if scripted_ents and scripted_ents.Register then scripted_ents.Register(BASE, "skategm_part") end

-- A family: one part per size, from one builder. sizes = { { key = "96x128",
-- title = "96 high, 128 wide", ... }, ... }; build(size) returns the pieces.
-- A size without a key is registered under the family's own id (so a part
-- that gained sizes keeps its old id for maps and saved parks).
function PARTS.Family(fam)
	for i, size in ipairs(fam.sizes) do
		local id = size.key and (fam.id .. "_" .. size.key) or fam.id
		PARTS.Register({
			id = id, family = fam.id, size = size,
			title = fam.title .. (size.title and (" (" .. size.title .. ")") or ""),
			order = (fam.order or 99) + i / 100, category = fam.category, surface = size.surface or fam.surface,
			info = size.info or fam.info, mass = fam.mass,
			pieces = function() return fam.build(size) end,
		})
	end
end

-- Connectors: where a part joins another. Each side of its footprint (+x, -x,
-- +y, -y) is one, at the middle of that side, with the height of the part's
-- top along it (a ramp's foot is 0, a deck's edge its height). Two parts snap
-- side to side when the sides face each other and stand as high.
function PARTS.Connectors(def)
	local shape = PARTS.Shape(def)
	if shape.connectors then return shape.connectors end
	local lo, hi = shape.mins, shape.maxs
	local sides = {
		{ name = "+x", dir = Vector(1, 0, 0), at = Vector(hi.x, 0, 0), along = "x", bound = hi.x, width = hi.y - lo.y },
		{ name = "-x", dir = Vector(-1, 0, 0), at = Vector(lo.x, 0, 0), along = "x", bound = lo.x, width = hi.y - lo.y },
		{ name = "+y", dir = Vector(0, 1, 0), at = Vector(0, hi.y, 0), along = "y", bound = hi.y, width = hi.x - lo.x },
		{ name = "-y", dir = Vector(0, -1, 0), at = Vector(0, lo.y, 0), along = "y", bound = lo.y, width = hi.x - lo.x },
	}
	for _, side in ipairs(sides) do
		local h = 0
		for _, t in ipairs(shape.tris) do
			for k = 1, 3 do
				local v = t[k]
				if math.abs(v[side.along] - side.bound) < 0.5 then h = math.max(h, v.z) end
			end
		end
		side.height = h
	end
	shape.connectors = sides
	return sides
end

-- Where a part placed at (pos, yaw) should go to join another part already
-- at (opos, oyaw): the nearest pair of connectors that face each other at the
-- same height, within `reach` of each other. Returns pos, yaw (or nil).
PARTS.SNAP_REACH = 40
PARTS.SNAP_HEIGHT = 1.0
local function Turn(v, yaw)
	local r = math.rad(yaw)
	local c, s = math.cos(r), math.sin(r)
	return Vector(v.x * c - v.y * s, v.x * s + v.y * c, v.z)
end
PARTS.Turn = Turn
function PARTS.SnapPlacement(def, pos, yaw, odef, opos, oyaw, reach)
	reach = reach or PARTS.SNAP_REACH
	local best, bestD
	for _, a in ipairs(PARTS.Connectors(odef)) do
		local aw, ad = opos + Turn(a.at, oyaw), Turn(a.dir, oyaw)
		for _, b in ipairs(PARTS.Connectors(def)) do
			if math.abs(a.height - b.height) <= PARTS.SNAP_HEIGHT then
				local bw = pos + Turn(b.at, yaw)
				local d = (bw - aw):Length2D()
				if d <= reach and (not bestD or d < bestD) then
					-- turn the part so b faces back at a, then move b onto a
					local byaw = math.deg(math.atan2(b.dir.y, b.dir.x))
					local ayaw = math.deg(math.atan2(ad.y, ad.x))
					local nyaw = (ayaw + 180 - byaw) % 360
					local npos = aw - Turn(b.at, nyaw)
					best, bestD = { pos = Vector(npos.x, npos.y, opos.z), yaw = nyaw }, d
				end
			end
		end
	end
	if best then return best.pos, best.yaw end
end

-- Where a part dropped at pos/yaw goes: joined to the nearest of `others`
-- ({ id, pos, yaw }) it snaps to, else rounded to the grid and turn steps.
-- settings = { snap, grid, turn }; returns pos, yaw, joined (the other entry).
function PARTS.Place(def, pos, yaw, others, settings, reach)
	if settings.snap then
		local best, bestD
		for _, o in ipairs(others) do
			local odef = PARTS.Get(o.id)
			if odef then
				local npos, nyaw = PARTS.SnapPlacement(def, pos, yaw, odef, o.pos, o.yaw, reach)
				if npos then
					local d = (npos - pos):Length2D()
					if not bestD or d < bestD then best, bestD = { npos, nyaw, o }, d end
				end
			end
		end
		if best then return best[1], best[2], best[3] end
	end
	local grid, turn = settings.grid or 0, settings.turn or 0
	if grid > 0 then pos = Vector(math.Round(pos.x / grid) * grid, math.Round(pos.y / grid) * grid, pos.z) end
	if turn > 0 then yaw = math.Round(yaw / turn) * turn end
	return pos, yaw, nil
end

function PARTS.Register(def)
	assert(type(def) == "table" and type(def.id) == "string" and def.id:match("^[%w_]+$") and type(def.pieces) == "function", "a park part needs an id and a pieces function")
	PARTS.list[def.id] = def
	PARTS.shapes[def.id] = nil
	for key in pairs(PARTS.meshes) do
		if key:sub(1, #def.id + 1) == def.id .. "#" then PARTS.meshes[key] = nil end
	end
	if scripted_ents and scripted_ents.Register then
		scripted_ents.Register({
			Base = "skategm_part", Type = "anim", PrintName = def.title or def.id, Category = def.category or PARTS.CATEGORY,
			Spawnable = true, AdminOnly = def.adminOnly or false, PartId = def.id, Information = def.info,
		}, "skategm_part_" .. def.id)
	end
	return def
end
