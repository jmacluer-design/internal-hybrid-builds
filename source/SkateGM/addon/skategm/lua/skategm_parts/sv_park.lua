---------------------------------------------------------------------------
-- The park editor, server side: park parts snap together where they're
-- spawned or dropped (the physgun), and whole parks are saved and loaded.
-- Each player's own settings (client convars, sent as userinfo):
--   skategm_parts_snap 1      snap to the nearest part's matching edge
--   skategm_parts_grid 0      else round the position to this grid (0 = off)
--   skategm_parts_turn 15     and the turn to this many degrees (0 = off)
--   skategm_park_save <name> [x y z yaw]  every park part, relative to where
--                             you stand (or to that point and heading)
--   skategm_park_load <name> [x y z yaw]  placed again where you're looking
--                             (or there)
--   skategm_park_list         the saved parks
--   skategm_park_clear        every park part removed
-- Parks live in data/skategm/parks/<name>.json.
---------------------------------------------------------------------------
local P = SKATEGM_PARTS
local PARK = {}
P.park = PARK
PARK.DIR = "skategm/parks"
PARK.MAX_PARTS = 300
PARK.DEFAULTS = { snap = 1, grid = 0, turn = 15 }

-- a player's snapping settings (the defaults for nobody)
function PARK.Settings(ply)
	local get = function(name, d) return IsValid(ply) and ply.GetInfoNum and ply:GetInfoNum("skategm_parts_" .. name, d) or d end
	return { snap = get("snap", PARK.DEFAULTS.snap) ~= 0, grid = get("grid", PARK.DEFAULTS.grid), turn = get("turn", PARK.DEFAULTS.turn) }
end

function PARK.IsPart(e) return IsValid(e) and e.SkateGMPart == true and e.PartId ~= nil end

-- where a part at pos/yaw should go: joined to the nearest other part, or on the grid
function PARK.Placement(def, pos, yaw, others, settings)
	local npos, nyaw, joined = P.Place(def, pos, yaw, others, settings or PARK.Settings())
	return npos, nyaw, joined ~= nil
end

-- the other parts near e, as { id, pos, yaw }
function PARK.Neighbours(e, radius)
	local out = {}
	for _, o in ipairs(ents.FindInSphere(e:GetPos(), radius or 800)) do
		if o ~= e and PARK.IsPart(o) then out[#out + 1] = { id = o.PartId, pos = o:GetPos(), yaw = o:GetAngles().y } end
	end
	return out
end

function PARK.Snap(e, ply)
	if not PARK.IsPart(e) then return false end
	local def = P.Get(e.PartId)
	if not def then return false end
	local pos, yaw, joined = PARK.Placement(def, e:GetPos(), e:GetAngles().y, PARK.Neighbours(e), PARK.Settings(ply))
	e:SetPos(pos)
	e:SetAngles(Angle(0, yaw, 0))
	local phys = e:GetPhysicsObject()
	if IsValid(phys) then
		phys:EnableMotion(false)
		phys:Wake()
	end
	return joined
end

-- spawned from the menu, or let go of with the physgun: snapped
hook.Add("PlayerSpawnedSENT", "skategm_park_snap", function(ply, e)
	if PARK.IsPart(e) and not e.SkateGMOwner then timer.Simple(0, function() if IsValid(e) then PARK.Snap(e, ply) end end) end
end)
hook.Add("PhysgunDrop", "skategm_park_snap", function(ply, e)
	if PARK.IsPart(e) then PARK.Snap(e, ply) end
end)

-- saving and loading: positions relative to the player and the way they face
local function SafeName(name)
	name = tostring(name or ""):lower():gsub("[^%w_%-]", "_")
	return name ~= "" and name:sub(1, 48) or nil
end
PARK.SafeName = SafeName

function PARK.Collect(origin, yaw)
	local out = {}
	for _, e in ipairs(ents.GetAll()) do
		if PARK.IsPart(e) then
			local d = P.Turn(e:GetPos() - origin, -yaw)
			out[#out + 1] = { id = e.PartId, x = d.x, y = d.y, z = d.z, yaw = (e:GetAngles().y - yaw) % 360 }
		end
	end
	return out
end

function PARK.Save(ply, name, origin, yaw)
	name = SafeName(name)
	if not name then return false, "give the park a name" end
	local parts = PARK.Collect(origin or ply:GetPos(), yaw or ply:EyeAngles().y)
	if #parts == 0 then return false, "there are no park parts to save" end
	file.CreateDir(PARK.DIR)
	file.Write(PARK.DIR .. "/" .. name .. ".json", util.TableToJSON({ version = 1, parts = parts }, true))
	return true, string.format("saved %d parts as \"%s\"", #parts, name)
end

function PARK.Load(ply, name, origin, yaw)
	name = SafeName(name)
	local text = name and file.Read(PARK.DIR .. "/" .. name .. ".json", "DATA")
	local data = text and util.JSONToTable(text)
	if not (data and type(data.parts) == "table") then return false, "no saved park called \"" .. tostring(name) .. "\"" end
	if #data.parts > PARK.MAX_PARTS then return false, "that park has too many parts" end
	local made = 0
	if undo then undo.Create("SkateGM park") end
	for _, p in ipairs(data.parts) do
		local def = P.Get(p.id)
		if def then
			local e = ents.Create("skategm_part_" .. p.id)
			if IsValid(e) then
				e:SetPos(origin + P.Turn(Vector(p.x, p.y, p.z), yaw))
				e:SetAngles(Angle(0, (p.yaw + yaw) % 360, 0))
				e:Spawn()
				e:Activate()
				if undo then undo.AddEntity(e) end
				if IsValid(ply) and ply.AddCleanup then ply:AddCleanup("skategm_parts", e) end
				made = made + 1
			end
		end
	end
	if undo then undo.SetPlayer(ply) undo.Finish() end
	return true, string.format("placed \"%s\" (%d parts)", name, made)
end

-- every park part on the map gone (before loading another park)
function PARK.Clear()
	local n = 0
	for _, e in ipairs(ents.GetAll()) do
		if PARK.IsPart(e) then
			e:Remove()
			n = n + 1
		end
	end
	return n
end

function PARK.List()
	local names = {}
	for _, f in ipairs(file.Find(PARK.DIR .. "/*.json", "DATA") or {}) do names[#names + 1] = f:gsub("%.json$", "") end
	table.sort(names)
	return names
end

-- (an origin given after the name: "x y z yaw" - the park editor's camera)
function PARK.ArgsOrigin(args)
	local x, y, z, yaw = tonumber(args[2]), tonumber(args[3]), tonumber(args[4]), tonumber(args[5])
	if x and y and z then return Vector(x, y, z), yaw or 0 end
end

-- (saving and loading spawn and read files on the server: the host and admins)
local function Allowed(ply) return not IsValid(ply) or ply:IsAdmin() or game.SinglePlayer() end
local function Reply(ply, text) if IsValid(ply) then ply:ChatPrint("[SkateGM] " .. text) else print("[SkateGM] " .. text) end end

concommand.Add("skategm_park_save", function(ply, _, args)
	if not Allowed(ply) then return Reply(ply, "only the host and admins can save parks") end
	local origin, yaw = PARK.ArgsOrigin(args)
	local _, msg = PARK.Save(ply, args[1], origin, yaw)
	Reply(ply, msg)
end)
concommand.Add("skategm_park_load", function(ply, _, args)
	if not Allowed(ply) then return Reply(ply, "only the host and admins can load parks") end
	if not IsValid(ply) then return end
	local origin, yaw = PARK.ArgsOrigin(args)
	if not origin then origin, yaw = ply:GetEyeTrace().HitPos, ply:EyeAngles().y end
	local _, msg = PARK.Load(ply, args[1], origin, yaw)
	Reply(ply, msg)
end)
concommand.Add("skategm_park_clear", function(ply)
	if not Allowed(ply) then return Reply(ply, "only the host and admins can clear the park") end
	Reply(ply, string.format("removed %d park parts", PARK.Clear()))
end)
concommand.Add("skategm_park_list", function(ply)
	local names = PARK.List()
	Reply(ply, #names > 0 and ("saved parks: " .. table.concat(names, ", ")) or "no parks saved yet")
end)
