local S = SkateGM

---------------------------------------------------------------------------
-- Infinite maps: a separate path, off on every other map. Two backends:
-- InfMap2 (gm_inf_*) shows Lua absolute positions everywhere (its detours),
-- so the engine simply runs in absolute coordinates. The original InfMap
-- (gm_infmap*) shows the client positions relative to its own chunk: the
-- engine runs in absolute ones through the frame offset (S.frameOffset).
-- What both need:
--   - the map's BSP is only a container box: left out (SK8_OFF=world)
--   - the terrain is generated at runtime: each chunk's mesh (from the
--     InfMap's own generator / height function) goes to the engine as an entity
--   - the skater is frozen while there's no terrain under it yet (after a
--     teleport, before its chunks are built)
--   - InfMap2 only: the skater's bones are drawn relative to the camera's
--     cell, and InfMap2's render override is kept off our skater models
---------------------------------------------------------------------------
local IM = {}
S.infmap = IM
IM.PREFIX = "skategm_inf:"
IM.PREFIX1 = "skategm_inf1:"
IM.SKIP = { inf_chunk = true, inf_crosschunkclone = true, inf_planet = true,
	infmap_terrain_collider = true, infmap_clone = true, infmap_planet = true, infmap_terrain_render = true }
IM.GROUND_RADIUS = 2000

local function MapWord()
	local map = game and game.GetMap and game.GetMap():lower() or ""
	return string.Explode and string.Explode("_", map)[2] or map:match("^[^_]+_([^_]+)")
end

-- which InfMap runs this map: "infmap2" (InfMap2, gm_inf_*), "infmap1" (the
-- original InfMap, gm_infmap*), or nil
function IM.Backend()
	if InfMap2 and InfMap2.Realms and InfMap2.ChunkSize and (MapWord() == "inf" or InfMap2.InfMap1Compat == true) then return "infmap2" end
	if InfMap and InfMap.chunk_size and MapWord() == "infmap" then return "infmap1" end
	return nil
end

function IM.Active() return IM.Backend() ~= nil end

---------------------------------------------------------------------------
-- the original InfMap: chunks 2 x chunk_size wide; the client sees positions
-- relative to its own chunk (the frame offset below), the server absolute ones
---------------------------------------------------------------------------
function IM.Inf1Offset()
	local lp = LocalPlayer and LocalPlayer()
	local c = lp and IsValid(lp) and lp.CHUNK_OFFSET
	if not c then return nil end
	local w = InfMap.chunk_size * 2
	return Vector(c.x * w, c.y * w, c.z * w)
end

-- the original InfMap's sea: flat, at InfMap.water_height (absolute)
function IM.Inf1WaterLevel(p)
	if not (IM.on and IM.backend == "infmap1" and InfMap.water_height) then return nil end
	local off = S.Offset()
	return InfMap.water_height - (off and off.z or 0)
end

function IM.Inf1Cell(v) local cs = InfMap.chunk_size return math.floor((v + cs) / (cs * 2)) end

-- the terrain the original InfMap collides with (infmap_terrain_collider:
-- InfMap.height_function sampled every 1 / chunk_resolution of a chunk, the
-- same corners and diagonals), each square given to the one chunk its low
-- corner is in (InfMap's own colliders overlap by a chunk). Positions are
-- relative to the chunk's centre at height 0.
function IM.Inf1Triangles(cx, cy, height, cs, res)
	local w = cs * 2
	local flat = {}
	local k0, k1 = math.ceil((cx - 0.5) * res), math.ceil((cx + 0.5) * res) - 1
	local j0, j1 = math.ceil((cy - 0.5) * res), math.ceil((cy + 0.5) * res) - 1
	local function P(k, j)
		local u, v = k / res, j / res
		return { u * w - cx * w, v * w - cy * w, height(u, v) }
	end
	local function tri(a, b, c)
		local nz = (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
		if nz < 0 then b, c = c, b end
		for _, q in ipairs({ a, b, c }) do flat[#flat + 1] = q[1] flat[#flat + 1] = q[2] flat[#flat + 1] = q[3] end
	end
	for k = k0, k1 do
		for j = j0, j1 do
			local p1, p2, p3, p4 = P(k + 1, j + 1), P(k, j + 1), P(k + 1, j), P(k, j)
			tri(p1, p2, p3)
			tri(p2, p3, p4)
		end
	end
	return flat
end

function IM.Inf1Hulls(name)
	if type(name) ~= "string" or name:sub(1, #IM.PREFIX1) ~= IM.PREFIX1 then return nil end
	local x, y = name:sub(#IM.PREFIX1 + 1):match("^(%-?%d+):(%-?%d+)$")
	if not x then return nil end
	local ok, flat = pcall(IM.Inf1Triangles, tonumber(x), tonumber(y), InfMap.height_function, InfMap.chunk_size, InfMap.chunk_resolution or 3)
	return { ok and flat or {} }, true, "InfMap terrain"
end

-- Map-made collision on the original InfMap: entities whose collision is a
-- mesh built at runtime (PhysicsFromMesh) on a stand-in model, e.g.
-- InfMap's own OBJ colliders (a cinder block model) or a map's own chunk
-- colliders. Their model says nothing about their shape; their physics
-- object, which the client builds too, does. Which entities: InfMap's own
-- OBJ collider, and anything a map marks as InfMap.filter (InfMap's list of
-- its helper entities - map colliders mark themselves there).
IM.PHYS_CLASSES = { infmap_obj_collider = true }
IM.PREFIX1P = "skategm_inf1phys:"

function IM.MeshCollider(e)
	if IM.backend ~= "infmap1" or not IsValid(e) then return false end
	local class = e:GetClass()
	if IM.SKIP[class] then return false end
	return IM.PHYS_CLASSES[class] or (InfMap and InfMap.filter and InfMap.filter[class]) or false
end

-- a collider's triangles, in its own space
function IM.PhysTriangles(e)
	local phys = e.GetPhysicsObject and e:GetPhysicsObject()
	if not (phys and IsValid(phys)) then return nil end
	local flat = {}
	local verts = phys.GetMesh and phys:GetMesh()
	if type(verts) == "table" and #verts >= 3 then
		for i = 1, #verts - 2, 3 do
			for k = 0, 2 do
				local v = verts[i + k].pos or verts[i + k]
				flat[#flat + 1] = v.x flat[#flat + 1] = v.y flat[#flat + 1] = v.z
			end
		end
		return flat
	end
	local convexes = phys.GetMeshConvexes and phys:GetMeshConvexes()
	if type(convexes) ~= "table" then return nil end
	for _, cv in ipairs(convexes) do
		for i = 1, #cv - 2, 3 do
			for k = 0, 2 do
				local v = cv[i + k].pos or cv[i + k]
				flat[#flat + 1] = v.x flat[#flat + 1] = v.y flat[#flat + 1] = v.z
			end
		end
	end
	return #flat >= 9 and flat or nil
end

-- InfMap's OBJ collision (InfMap.parse_obj) is known for every chunk ahead
-- (InfMap.parsed_collision_data, triangles relative to their chunk, on the
-- client too): fed for the chunks around the skater. Colliders a map builds
-- per chunk only exist where a player is; the server asks the map for the
-- chunks a skater is about to reach (skategm/sv_infmap.lua), and they come in
-- through Inf1PhysFeed like any other.
IM.PREFIX1O = "skategm_inf1obj:"

function IM.Inf1ChunkHulls(name)
	if type(name) ~= "string" or name:sub(1, #IM.PREFIX1O) ~= IM.PREFIX1O then return nil end
	local key, i = name:sub(#IM.PREFIX1O + 1):match("^(.*)#(%d+)$")
	local data = key and InfMap.parsed_collision_data and InfMap.parsed_collision_data[key]
	local verts = data and data[tonumber(i)]
	local flat = {}
	for _, v in ipairs(verts or {}) do local q = v.pos or v flat[#flat + 1] = q.x flat[#flat + 1] = q.y flat[#flat + 1] = q.z end
	return IM.Oriented(flat)
end

function IM.Inf1ChunkFeed(cx, cy, cz, list, sig)
	local data = InfMap.parsed_collision_data
	if not (data and InfMap.ezcoord) then return end
	local w = InfMap.chunk_size * 2
	local off = S.Offset() or Vector(0, 0, 0)
	for dx = -1, 1 do
		for dy = -1, 1 do
			for dz = -1, 1 do
				local x, y, z = cx + dx, cy + dy, cz + dz
				local key = InfMap.ezcoord(Vector(x, y, z))
				for i = 1, #(data[key] or {}) do
					local name = IM.PREFIX1O .. key .. "#" .. i
					list[#list + 1] = { name, x * w - off.x, y * w - off.y, z * w - off.z, 0, 0, 0 }
					sig[#sig + 1] = name
				end
			end
		end
	end
end

-- covered by Inf1ChunkFeed: no need to read these colliders' physics
function IM.Covered(class)
	return class == "infmap_obj_collider" and InfMap.parsed_collision_data ~= nil
end

-- a chunk next to mine (or mine): its entities' positions come back in my
-- frame (InfMap's GetPos), so their collision can be placed here
function IM.NearChunk(e)
	local lp = LocalPlayer()
	local c, m = e.CHUNK_OFFSET, IsValid(lp) and lp.CHUNK_OFFSET
	if not (c and m) then return true end
	return math.abs(c.x - m.x) <= 1 and math.abs(c.y - m.y) <= 1 and math.abs(c.z - m.z) <= 1
end

-- Map-made collision is triangle soup with either winding (GMod's physics
-- collides with both sides of a mesh; the skater's is one-sided): floors and
-- slopes are turned to face up, walls given both sides. Measured with the
-- real engine on a map like this (gm_infmap_vicecity, harness/vc.lua).
IM.ORIENT = "up"
function IM.Orient(flat, mode)
	mode = mode or IM.ORIENT
	if mode == "none" or #flat < 9 then return flat end
	local o = {}
	local function put(i, j, k)
		for _, b in ipairs({ i, j, k }) do o[#o + 1] = flat[b] o[#o + 1] = flat[b + 1] o[#o + 1] = flat[b + 2] end
	end
	for i = 1, #flat - 8, 9 do
		local ux, uy, uz = flat[i + 3] - flat[i], flat[i + 4] - flat[i + 1], flat[i + 5] - flat[i + 2]
		local vx, vy, vz = flat[i + 6] - flat[i], flat[i + 7] - flat[i + 1], flat[i + 8] - flat[i + 2]
		local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
		local nl = math.sqrt(nx * nx + ny * ny + nz * nz)
		if mode == "both" or nl <= 0 or math.abs(nz) / nl <= 0.2 then
			put(i, i + 3, i + 6) put(i, i + 6, i + 3)
		elseif nz < 0 then
			put(i, i + 6, i + 3)
		else
			put(i, i + 3, i + 6)
		end
	end
	return o
end

-- (turned up-facing by the module if it can - DefineModel mesh mode 2: a big
-- mesh took ~6 ms of Lua per chunk on the game thread - or here)
function IM.Oriented(flat)
	if IM.ORIENT == "up" and skategm and skategm.MeshModes and skategm.MeshModes() >= 2 then
		return { flat }, 2, "InfMap map collision"
	end
	return { IM.Orient(flat) }, true, "InfMap map collision"
end

IM.physOf = IM.physOf or {}
function IM.Inf1PhysHulls(name)
	if type(name) ~= "string" or name:sub(1, #IM.PREFIX1P) ~= IM.PREFIX1P then return nil end
	local e = IM.physOf[name]
	local flat = IsValid(e) and IM.PhysTriangles(e) or nil
	if not flat then return S.LATER end
	IM.physRead[name] = true
	return IM.Oriented(flat)
end

-- A collider's shape is named by where it is and what it's made from (model,
-- chunk, position, vertex count), not by the entity: maps remove a chunk's
-- colliders when nobody's there and build them again when someone comes back,
-- and a rebuilt collider is the same shape - no new read of its mesh, no new
-- definition, and the collision rebuild is skipped as identical. One that's
-- gone stays in the feed IM.LINGER seconds more at its last place, so
-- crossing a chunk border (the map drops the chunk just left, the server asks
-- for it again) doesn't make two rebuilds and leave a gap.
IM.LINGER = 4
IM.lastPhys = IM.lastPhys or {}
IM.countAt = IM.countAt or {}
IM.physRead = IM.physRead or {}

function IM.Inf1PhysFeed(list, sig)
	IM.physCount, IM.physWaiting = 0, 0
	local now = RealTime and RealTime() or 0
	local seen = {}
	for _, e in ipairs(ents.GetAll()) do
		if IM.MeshCollider(e) and not IM.Covered(e:GetClass()) and IM.NearChunk(e) then
			local phys = e:GetPhysicsObject()
			if phys and IsValid(phys) then
				local p = e:GetPos()
				local abs = S.ToAbs and S.ToAbs(p) or p
				local c = e.CHUNK_OFFSET
				local where = string.format("%s@%s:%d,%d,%d", string.lower(e:GetModel() or ""), c and string.format("%d,%d,%d", c.x, c.y, c.z) or "-",
					math.floor(abs.x / 4 + 0.5), math.floor(abs.y / 4 + 0.5), math.floor(abs.z / 4 + 0.5))
				-- (its mesh counted once per physics object; a new collider where
				-- one was before takes that one's count without reading its mesh)
				local mc = e.Sk8MeshCount
				if not mc or mc.phys ~= phys then
					local n = not mc and IM.countAt[where]
					if not n then n = (phys.GetMesh and #(phys:GetMesh() or {})) or 0 end
					IM.countAt[where] = n
					mc = { phys = phys, n = n }
					e.Sk8MeshCount = mc
				end
				local name = IM.PREFIX1P .. where .. ":" .. mc.n
				IM.physOf[name] = e
				list[#list + 1] = { name, p.x, p.y, p.z, 0, 0, 0 }
				sig[#sig + 1] = name
				seen[name] = true
				IM.lastPhys[name] = { abs = abs, at = now }
				IM.physCount = IM.physCount + 1
			else
				IM.physWaiting = IM.physWaiting + 1
			end
		end
	end
	for name, l in pairs(IM.lastPhys) do
		if not seen[name] then
			if IM.physRead[name] and now - l.at < IM.LINGER then
				local p = S.FromAbs and S.FromAbs(l.abs) or l.abs
				list[#list + 1] = { name, p.x, p.y, p.z, 0, 0, 0 }
				sig[#sig + 1] = name
			elseif now - l.at >= IM.LINGER then
				IM.lastPhys[name] = nil
			end
		end
	end
end

function IM.Inf1Feed(centre, list, sig)
	if not IM.on then return end
	IM.Inf1PhysFeed(list, sig)
	local here = S.ToAbs(centre)
	IM.Inf1ChunkFeed(IM.Inf1Cell(here.x), IM.Inf1Cell(here.y), IM.Inf1Cell(here.z), list, sig)
	if not InfMap.height_function then return end
	local abs = here
	local w = InfMap.chunk_size * 2
	local cx, cy = IM.Inf1Cell(abs.x), IM.Inf1Cell(abs.y)
	local off = S.Offset() or Vector(0, 0, 0)
	for dx = -1, 1 do
		for dy = -1, 1 do
			local x, y = cx + dx, cy + dy
			local name = string.format("%s%d:%d", IM.PREFIX1, x, y)
			-- (placed in Lua's frame: the module wrapper turns it absolute)
			list[#list + 1] = { name, x * w - off.x, y * w - off.y, -off.z, 0, 0, 0 }
			sig[#sig + 1] = name
		end
	end
end

function IM.Realm() return IsValid(LocalPlayer()) and LocalPlayer().GetRealm and LocalPlayer():GetRealm() or "default" end

function IM.Cell(v)
	local size = InfMap2.ChunkSize
	return math.floor((v + size / 2) / size)
end

function IM.Name(realm, x, y, z) return string.format("%s%s:%d:%d:%d", IM.PREFIX, realm, x, y, z) end

function IM.Parse(name)
	if type(name) ~= "string" or name:sub(1, #IM.PREFIX) ~= IM.PREFIX then return nil end
	local realm, x, y, z = name:sub(#IM.PREFIX + 1):match("^(.-):(%-?%d+):(%-?%d+):(%-?%d+)$")
	if not realm then return nil end
	return realm, tonumber(x), tonumber(y), tonumber(z)
end

-- a chunk's physics mesh as the engine wants it: one triangle list, facing up
IM.empty = {}
function IM.ChunkTriangles(realm, x, y, z)
	local r = InfMap2.Realms[realm == "default" and "default" or realm] or InfMap2.Realms.default
	local gen = r and r.Generator
	if not (gen and gen.GenerateChunkPhysics) then return {} end
	local ok, verts = pcall(gen.GenerateChunkPhysics, Vector(x, y, z), realm)
	if not ok or type(verts) ~= "table" then return {} end
	local flat = {}
	for i = 1, #verts - 2, 3 do
		local a, b, c = verts[i], verts[i + 1], verts[i + 2]
		local n = (b - a):Cross(c - a)
		if n.z < 0 then b, c = c, b end
		for _, v in ipairs({ a, b, c }) do
			flat[#flat + 1] = v.x
			flat[#flat + 1] = v.y
			flat[#flat + 1] = v.z
		end
	end
	return flat
end

function IM.Hulls(name)
	local realm, x, y, z = IM.Parse(name)
	if not realm then return nil end
	local flat = IM.ChunkTriangles(realm, x, y, z)
	IM.empty[name] = #flat == 0 or nil
	return { flat }, true, "InfMap terrain"
end

-- the 3 x 3 x 3 chunks around the skater; the ones next to it are always in,
-- so crossing into a neighbour never waits for its collision
function IM.Feed(centre, list, sig)
	if not IM.on then return end
	local size = InfMap2.ChunkSize
	local realm = IM.Realm()
	local cx, cy, cz = IM.Cell(centre.x), IM.Cell(centre.y), IM.Cell(centre.z)
	for dx = -1, 1 do
		for dy = -1, 1 do
			for dz = -1, 1 do
				local x, y, z = cx + dx, cy + dy, cz + dz
				local name = IM.Name(realm, x, y, z)
				if not IM.empty[name] then
					list[#list + 1] = { name, x * size, y * size, z * size, 0, 0, 0 }
					sig[#sig + 1] = name
				end
			end
		end
	end
end

function IM.OtherChunk(e)
	local lp = LocalPlayer()
	return e.CHUNK_OFFSET ~= nil and IsValid(lp) and lp.CHUNK_OFFSET ~= nil and e.CHUNK_OFFSET ~= lp.CHUNK_OFFSET
end

function IM.Skip(e)
	if not IM.on then return false end
	if IM.SKIP[e:GetClass()] then return true end
	if IM.backend == "infmap2" then return e.GetRealm and e:GetRealm() ~= IM.Realm() end
	-- (mesh colliders come in through Inf1PhysFeed, with their real shape)
	if IM.MeshCollider(e) then return true end
	return IM.OtherChunk(e)
end

-- where the renderer draws: InfMap2 draws relative to the camera's cell
function IM.ViewOffset()
	local stack = InfMap2.ViewOffsetStack
	if stack and #stack > 0 then return stack[#stack] end
	return InfMap2.MainViewOffset or Vector(0, 0, 0)
end

function IM.RenderSpace(P)
	if not IM.on or IM.backend ~= "infmap2" then return P end
	local off = IM.ViewOffset()
	if off.x == 0 and off.y == 0 and off.z == 0 then return P end
	local out = {}
	for k, v in pairs(P) do out[k] = v - off end
	return out
end

function IM.AfterPlace(e)
	if not IM.on or IM.backend ~= "infmap2" then return end
	if e.Sk8Render and e.RenderOverride ~= e.Sk8Render then e.RenderOverride = e.Sk8Render end
	if e.INF_SetRenderBoundsWS and InfMap2.SourceBounds then e:INF_SetRenderBoundsWS(-InfMap2.SourceBounds, InfMap2.SourceBounds) end
end

-- no terrain near the skater yet: hold it still until there is
function IM.Think()
	if not IM.on or S.phase ~= "on" or not skategm or not skategm.CollisionHas then return end
	local p = S.pose and S.pose.pos
	local ground = p and skategm.CollisionHas(p[1], p[2], p[3], IM.GROUND_RADIUS)
	local want = p ~= nil and not ground
	if want ~= (IM.waiting or false) then
		IM.waiting = want or nil
		if skategm.SetFrozen and not S.frozen then skategm.SetFrozen(want and 1 or 0) end
	end
end

local function AddOnce(list, f)
	for _, g in ipairs(list) do if g == f then return end end
	list[#list + 1] = f
end

function IM.Setup()
	IM.backend = IM.Backend()
	IM.on = IM.backend ~= nil
	S.extraOff = IM.on and "world" or nil
	if not IM.on then return end
	S.HullProviders = S.HullProviders or {}
	S.ExtraFeeds = S.ExtraFeeds or {}
	if IM.backend == "infmap1" then
		AddOnce(S.HullProviders, IM.Inf1Hulls)
		AddOnce(S.HullProviders, IM.Inf1PhysHulls)
		AddOnce(S.HullProviders, IM.Inf1ChunkHulls)
		AddOnce(S.ExtraFeeds, IM.Inf1Feed)
		S.frameOffset = IM.Inf1Offset
		S.WaterLevel = IM.Inf1WaterLevel
		if S.WrapModule then S.WrapModule() end
	else
		AddOnce(S.HullProviders, IM.Hulls)
		AddOnce(S.ExtraFeeds, IM.Feed)
	end
	S.EntitySkippers = S.EntitySkippers or {}
	local have = false
	for _, f in ipairs(S.EntitySkippers) do if f == IM.Skip then have = true end end
	if not have then S.EntitySkippers[#S.EntitySkippers + 1] = IM.Skip end
	S.SkipEntity = S.SkipEntity or function(e)
		for _, skip in ipairs(S.EntitySkippers) do if skip(e) then return true end end
		return false
	end
	S.RenderSpace = IM.RenderSpace
	S.AfterPlace = IM.AfterPlace
end

IM.Setup()
if hook then
	hook.Add("InitPostEntity", "skategm_infmap", IM.Setup)
	hook.Add("Think", "skategm_infmap", IM.Think)
end

-- what InfMap support sees right now (for bug reports)
function IM.Why()
	local lines = {}
	local function say(...) lines[#lines + 1] = string.format(...) end
	say("InfMap: %s (on: %s, map box left out: %s)", tostring(IM.backend), tostring(IM.on), tostring(S.extraOff == "world"))
	local p = skategm and skategm.Poll and skategm.Poll() or {}
	if p.pos then
		local abs = S.ToAbs(Vector(p.pos[1], p.pos[2], p.pos[3]))
		say("skater at %.0f %.0f %.0f (absolute %.0f %.0f %.0f), state %s, held %s", p.pos[1], p.pos[2], p.pos[3], abs.x, abs.y, abs.z, tostring(p.state), tostring(p.held))
		say("collision under it: %s", tostring(skategm.CollisionHas and skategm.CollisionHas(p.pos[1], p.pos[2], p.pos[3], 200)))
	else
		say("not skating")
	end
	say("collision: %s", tostring(p.collision))
	local off = S.Offset()
	say("frame offset: %s", off and string.format("%.0f %.0f %.0f", off.x, off.y, off.z) or "none")
	if IM.backend == "infmap2" then
		local lp = LocalPlayer()
		say("megapos %s, view offset %s, chunk size %s", tostring(lp.GetMegaPos and lp:GetMegaPos()), tostring(InfMap2.MainViewOffset), tostring(InfMap2.ChunkSize))
	elseif IM.backend == "infmap1" then
		say("chunk %s, chunk size %s, terrain %s, map colliders %d (%d without physics yet)", tostring(LocalPlayer().CHUNK_OFFSET), tostring(InfMap.chunk_size),
			InfMap.height_function and "generated" or "none", IM.physCount or 0, IM.physWaiting or 0)
	end
	local e = S.skater
	if IsValid(e) then
		say("skater model at %s, drawn by us: %s, hidden: %s", tostring(e:GetPos()), tostring(e.RenderOverride == e.Sk8Render), tostring(e:GetNoDraw()))
	end
	for _, l in ipairs(lines) do print("[SkateGM] " .. l) end
	return lines
end
if concommand then concommand.Add("skategm_infmap_why", IM.Why, nil, "Print what SkateGM's InfMap support sees (for bug reports)") end
