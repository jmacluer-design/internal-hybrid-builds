dofile("gmock.lua")
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
local cmds = {}
concommand = { Add = function(n, f) cmds[n] = f end }
function IsValid(x) return x ~= nil end
MsgC = function() end chat = { AddText = function() end } function LocalPlayer() return {} end
function CreateClientConVar(n, d) return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetInt = function() return 0 end, GetString = function() return d end } end
local pushed
skategm = { Push = function(x, y, z) pushed = { x, y, z } return true end, Poll = function() return { vel = { 0, 0, 0 } } end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
S.phase, S.loadedScale = "on", 1
-- rolling along +y at 4 m/s: pushed along +y, 5 m/s worth
skategm.Poll = function() return { vel = { 0, 4 / 0.0254, 0 } } end
cmds["skategm_boost"](nil, nil, {})
local mps = pushed and math.sqrt(pushed[1] ^ 2 + pushed[2] ^ 2) * 0.0254
print(string.format("rolling: pushed along the way you're going, %.1f m/s", mps or -1), (pushed and math.abs(pushed[1]) < 1e-3 and pushed[2] > 0 and math.abs(mps - 5) < 0.01) and "OK" or "<-- WRONG")
-- stopped: the way the board points (+x), and an amount given on the command line
pushed = nil
skategm.Poll = function() return { vel = { 0, 0, 0 } } end
S.P = { TRUCK_FRONT = Vector(10, 0, 2), TRUCK_BACK = Vector(-10, 0, 1) }
cmds["skategm_boost"](nil, nil, { "12" })
mps = pushed and math.sqrt(pushed[1] ^ 2 + pushed[2] ^ 2) * 0.0254
print(string.format("stopped: pushed the way the board points, %.1f m/s", mps or -1), (pushed and pushed[1] > 0 and math.abs(pushed[2]) < 1e-3 and pushed[3] == 0 and math.abs(mps - 12) < 0.01) and "OK" or "<-- WRONG")
-- world scale 0.5: the same real speed means twice the map units
pushed = nil
S.loadedScale = 0.5
cmds["skategm_boost"](nil, nil, { "5" })
print("world scale taken into account:", pushed and math.abs(pushed[1] * 0.0254 * 0.5 - 5) < 0.01 and "OK" or "<-- WRONG")
-- not skating: nothing
pushed = nil
S.phase = "off"
cmds["skategm_boost"](nil, nil, {})
print("not skating: no push:", pushed == nil and "OK" or "<-- WRONG")
