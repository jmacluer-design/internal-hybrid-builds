dofile("gmock.lua")
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
scripted_ents = { Register = function() end }
local files = { "deck.lua", "quarter_pipe.lua" }
local hooks, cmds, written = {}, {}, {}
file = {
	Find = function(pat) if pat:find("parks") then local o = {} for k in pairs(written) do o[#o + 1] = k:match("([^/]+)$") end return o end return files end,
	CreateDir = function() end,
	Write = function(name, text) written[name] = text end,
	Read = function(name) return written[name] end,
}
hook = { Add = function(ev, id, fn) hooks[ev .. "/" .. id] = fn end }
concommand = { Add = function(name, fn) cmds[name] = fn end }
timer = { Simple = function(_, f) f() end }
util = util or {}
util.TableToJSON = function(t) return t end
util.JSONToTable = function(t) return t end
game = { SinglePlayer = function() return true end }
function include(f) dofile("../../addon/skategm/lua/" .. f) end
function AddCSLuaFile() end
function IsValid(x) return x ~= nil and (type(x) ~= "table" or not x.IsValid or x:IsValid()) end
SERVER = true
dofile("../../addon/skategm/lua/autorun/skategm_parts_load.lua")
local P = SKATEGM_PARTS
local PARK = P.park

-- fake part entities
local world = {}
local function Part(id, pos, yaw)
	local e = { SkateGMPart = true, PartId = id, pos = pos, ang = Angle(0, yaw, 0) }
	function e:IsValid() return true end
	function e:GetPos() return self.pos end
	function e:SetPos(p) self.pos = p end
	function e:GetAngles() return self.ang end
	function e:SetAngles(a) self.ang = a end
	function e:GetPhysicsObject() return nil end
	function e:Remove() for i, o in ipairs(world) do if o == self then table.remove(world, i) break end end end
	world[#world + 1] = e
	return e
end
ents = {
	FindInSphere = function() return world end,
	GetAll = function() local c = {} for i, e in ipairs(world) do c[i] = e end return c end,
	Create = function(class) return Part(class:gsub("^skategm_part_", ""), Vector(0, 0, 0), 0) end,
}
for _, e in ipairs(world) do end
local function Spawned(e) e.Spawn = function() end e.Activate = function() end return e end
local oldCreate = ents.Create
ents.Create = function(class) return Spawned(oldCreate(class)) end

local qp = Part("quarter_pipe", Vector(0, 0, 0), 0)
local back = P.Shape(P.Get("quarter_pipe")).maxs.x
local deck = Part("deck_96x128", Vector(back + 80, 6, 0), 8)
hooks["PhysgunDrop/skategm_park_snap"](nil, deck)
local dmin = P.Shape(P.Get("deck_96x128")).mins.x
check("a deck let go of near a quarter pipe snaps flush to its deck edge", math.abs(deck.pos.x + P.Turn(Vector(dmin, 0, 0), deck.ang.y).x - back) < 0.05 and math.abs(deck.pos.y) < 0.05)

-- nothing near, a 32 grid and 15-degree turns: on the grid
world = { qp }
local lone = Part("deck_24x128", Vector(2003, 517, 0), 22)
local ply = { GetInfoNum = function(_, name, d) return ({ skategm_parts_grid = 32, skategm_parts_turn = 15 })[name] or d end, IsValid = function() return true end }
world = { lone }
hooks["PhysgunDrop/skategm_park_snap"](ply, lone)
check("with nothing to snap to, the player's grid and turn steps apply", lone.pos.x == 2016 and lone.pos.y == 512 and lone.ang.y == 15)

-- save and load: the same layout again, turned to where the loader looks
world = { qp, deck }
local saver = { GetPos = function() return Vector(0, 0, 0) end, EyeAngles = function() return Angle(0, 0, 0) end, IsValid = function() return true end, IsAdmin = function() return true end }
local ok, msg = PARK.Save(saver, "my park!")
check("a park saves every part (and a name is made safe)", ok and written["skategm/parks/my_park_.json"] and #written["skategm/parks/my_park_.json"].parts == 2)
world = {}
local ok2 = PARK.Load(nil, "my park!", Vector(1000, 0, 0), 90)
local loadedDeck
for _, e in ipairs(world) do if e.PartId == "deck_96x128" then loadedDeck = e end end
local want = Vector(1000, 0, 0) + P.Turn(deck.pos, 90)
check("... and loads it again, turned and moved to where you look", ok2 and #world == 2 and loadedDeck and (loadedDeck.pos - want):Length() < 0.01 and math.abs((loadedDeck.ang.y - (deck.ang.y + 90)) % 360) < 0.01)
check("a park that doesn't exist says so", select(2, PARK.Load(nil, "nope", Vector(0, 0, 0), 0)):find("no saved park", 1, true) ~= nil)
world[#world + 1] = { IsValid = function() return true end, GetPos = function() return Vector(0, 0, 0) end }
check("clearing the park removes every part and nothing else", PARK.Clear() == 2 and #world == 1)
