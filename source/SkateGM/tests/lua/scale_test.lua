dofile("gmock.lua")
local hooks = {}
hook = { Add = function(name, id, fn) hooks[name .. "/" .. id] = fn end }
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
function RealTime() return 1 end
function FrameTime() return 1 / 60 end
function IsValid(x) if type(x) == "table" and x.IsValid then return x:IsValid() end return x ~= nil end
function CreateClientConVar(n, d) return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetString = function() return d end } end
input = { IsKeyDown = function() return false end, IsMouseDown = function() return false end }
ACT_HL2MP_IDLE = 1
function ClientsideModel() return nil end
ents = { FindInSphere = function() return {} end }
player = { GetAll = function() return {} end }
local ME = { IsValid = function() return true end, GetModel = function() return "models/player/kleiner.mdl" end, GetPos = function() return Vector() end }
function LocalPlayer() return ME end
MsgC = function() end chat = { AddText = function() end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM

-- engine output at world scale 0.75: a normal skater (hips 36 up, head 66 up,
-- wheels 1 up), but a third too big in map units, standing at x=1000
local k = 1 / 0.75
local names = { "HIPS", "HEAD", "RIGHT_WHEELFRONT", "LEFT_WHEELFRONT", "RIGHT_WHEELBACK", "LEFT_WHEELBACK" }
local rel = { HIPS = { 0, 0, 36 }, HEAD = { 0, 0, 66 }, RIGHT_WHEELFRONT = { 7, -4, 1 }, LEFT_WHEELFRONT = { 7, 4, 1 },
	RIGHT_WHEELBACK = { -7, -4, 1 }, LEFT_WHEELBACK = { -7, 4, 1 } }
local bones = {}
for i, n in ipairs(names) do local r = rel[n] bones[i] = { 1000 + r[1] * k, r[2] * k, r[3] * k } end
-- the ground contact point (wheel centre) is where the engine truly is
local contactZ = 1 * k
for i = 3, 6 do bones[i][3] = 1 end -- wheels are on the ground at z=1 in both spaces
skategm = {
	Poll = function() return { status = "active", bones = bones, names = names, pos = { 1000, 0, 0 },
		cam = { pos = { 1000 - 150 * k, 0, 60 * k }, fwd = { 1, 0, 0 }, up = { 0, 0, 1 } } } end,
	Step = function() end, CollisionNear = nil, SetEntities = function() end,
}
S.phase, S.loadedScale, S.idx = "on", 0.75, nil
hooks["Think/skategm"]()
local P = S.P
local height = P.HEAD.z - P.HIPS.z
print(string.format("drawn hips->head: %.1f units (normal 30; engine had %.1f) %s", height, 30 * k, math.abs(height - 30) < 0.5 and "OK" or "<-- WRONG"))
print(string.format("wheels stay on the ground: z = %.2f %s", P.RIGHT_WHEELFRONT.z, math.abs(P.RIGHT_WHEELFRONT.z - 1) < 1e-3 and "OK" or "<-- WRONG"))
local view = hooks["CalcView/skategm"](ME, Vector(), Angle(), 75)
local back = 1000 - view.origin.x
print(string.format("camera %.0f units behind (engine had %.0f) %s", back, 150 * k, math.abs(back - 150) < 1 and "OK" or "<-- WRONG"))
