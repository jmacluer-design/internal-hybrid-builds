dofile("gmock.lua")
local function check(label, ok) print(string.format("%-74s %s", label, ok and "OK" or "<-- WRONG")) end
scripted_ents = { Register = function() end }
local files = {}
for _, f in ipairs({ "bank", "deck", "funbox", "half_pipe", "kicker", "quarter_pipe" }) do files[#files + 1] = f .. ".lua" end
file = { Find = function() return files end }
function include(f) dofile("../../addon/skategm/lua/" .. f) end
function AddCSLuaFile() end
SERVER = true
dofile("../../addon/skategm/lua/autorun/skategm_parts_load.lua")
local P = SKATEGM_PARTS
local function near(a, b, tol) return math.abs(a - b) <= (tol or 0.01) end

-- connectors: each side's height is the part's top along that side
local qp = P.Get("quarter_pipe")
local c = {}
for _, k in ipairs(P.Connectors(qp)) do c[k.name] = k end
check("a quarter pipe's foot is at the ground, its deck edge as high as it", near(c["-x"].height, 0) and near(c["+x"].height, 96, 1))
check("... its sides as high as the deck", near(c["+y"].height, 96, 1.5))

-- a 96-high deck dropped a little off the quarter pipe's deck edge, turned a bit
local deck = P.Get("deck_96x128")
local qpPos, qpYaw = Vector(0, 0, 0), 0
local back = P.Shape(qp).maxs.x -- the deck edge, in the part's frame
local pos, yaw = P.SnapPlacement(deck, Vector(back + 64 + 20, 10, 0), 12, qp, qpPos, qpYaw)
check("a deck dropped near a quarter pipe's deck edge snaps to it", pos ~= nil)
local dmin = P.Shape(deck).mins.x
check("... flush against it, centred on it", pos and near(pos.x + P.Turn(Vector(dmin, 0, 0), yaw).x, back, 0.05) and near(pos.y, 0, 0.05))
check("... squared up to it", yaw and (near(yaw % 180, 0, 0.01) or near(yaw % 180, 180, 0.01)))

-- different heights don't snap
local low = P.Get("deck_48x128")
check("a deck too low for the quarter pipe's edge doesn't snap to it", P.SnapPlacement(low, Vector(back + 66, 0, 0), 0, qp, qpPos, qpYaw) == nil)

-- two quarter pipes back to back (a spine of two parts): deck edges meet
local p2, y2 = P.SnapPlacement(qp, Vector(back * 2 + 15, 0, 0), 170, qp, qpPos, qpYaw)
check("two quarter pipes dropped back to back join at their deck edges", p2 ~= nil and near(p2.x, back * 2, 0.05) and near(y2 % 360, 180, 0.01))

-- turned parts: the same join with the first one turned 90 degrees
local p3, y3 = P.SnapPlacement(deck, Vector(5, back + 70, 0), 95, qp, qpPos, 90)
check("... and the same with everything turned", p3 ~= nil and near(p3.x, 0, 0.05) and near(p3.y, back + 64, 0.05) and near(y3 % 180, 90, 0.01))

-- too far: no snap
check("a part dropped well away from the others doesn't snap", P.SnapPlacement(deck, Vector(back + 400, 0, 0), 0, qp, qpPos, qpYaw) == nil)
