dofile("gmock.lua")
local handlers = {}
net = setmetatable({ Receive = function(n, f) handlers[n] = f end }, { __index = function() return function() end end })
local cmds = {}
concommand = { Add = function(n, f) cmds[n] = f end }
local clock = 0
function RealTime() return clock end
function LerpVector(f, a, b) return a + (b - a) * f end
function istable(x) return type(x) == "table" end
function IsValid(x) if type(x) == "table" and x.IsValid then return x:IsValid() end return x ~= nil end
math.Clamp = function(v, a, b) return math.max(a, math.min(b, v)) end
math.Round = function(x) return math.floor(x + 0.5) end
function CreateClientConVar(name, default) return { GetBool = function() return default == "1" end, GetFloat = function() return tonumber(default) or 0 end, GetString = function() return default end } end
local ME = { GetModel = function() return "models/player/kleiner.mdl" end, IsValid = function() return true end }
function LocalPlayer() return ME end
player = { GetAll = function() return { ME } end }
ents = { FindInSphere = function() return {} end }
local said = {}
MsgC = function(...) local t = { ... } said[#said + 1] = t[#t - 1] end
chat = { AddText = function() end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM

-- skate in a straight line for 3 s, recording at 20 Hz
for i = 0, 60 do
	clock = i * 0.05
	S.P = { HIPS = Vector(i * 10, 0, 40), RIGHTFOOT = Vector(i * 10, -4, 5), LEFTFOOT = Vector(i * 10, 4, 5) }
	S.Record(clock)
end
clock = 10
cmds["skategm_ghost"]()
print(said[#said])
-- run the ghost for 1.5 s of frames
local key
for f = 0, 90 do
	clock = 10 + f / 60
	S.GhostThink(clock)
end
for k in pairs(S.remote) do key = k end
local P = S.RemotePose(S.remote[key], clock)
print(string.format("after 1.5 s the ghost is at x = %.0f (recorded path at 1.4 s: 280) %s", P.HIPS.x, math.abs(P.HIPS.x - 280) <= 12 and "OK" or "<-- WRONG"))
-- solid: it becomes a player block
local sent
skategm = { SetEntities = function(l) sent = l end }
S.test.FeedEntities(Vector(0, 0, 0))
local n = 0
for _, e in ipairs(sent or {}) do if e[1] == "skategm/player" then n = n + 1 end end
print("ghost is solid:", n == 1 and "OK" or "<-- WRONG (" .. n .. ")")
-- loops after its 3 s clip
for f = 91, 60 * 4 do clock = 10 + f / 60 S.GhostThink(clock) end
P = S.RemotePose(S.remote[key], clock)
print(string.format("after 4 s it has looped back to x = %.0f (1 s into the loop, 0.1 s behind: ~180) %s", P.HIPS.x, math.abs(P.HIPS.x - 180) <= 12 and "OK" or "<-- WRONG"))
cmds["skategm_ghost"]()
print("stopped:", next(S.remote) == nil and "OK" or "<-- WRONG")
