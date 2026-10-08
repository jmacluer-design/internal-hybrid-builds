dofile("gmock.lua")
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
function IsValid(x) return x ~= nil end
MsgC = function() end chat = { AddText = function() end } function LocalPlayer() return {} end
local cv = { skategm_collision_style = "0", skategm_speed_limit = "25" }
function CreateClientConVar(n, d) if cv[n] == nil then cv[n] = d end
	return { GetBool = function() return cv[n] == "1" end, GetFloat = function() return tonumber(cv[n]) or 0 end, GetInt = function() return math.floor(tonumber(cv[n]) or 0) end, GetString = function() return cv[n] end } end
local set, limit, airy = {}, nil, nil
skategm = { SetTuning = function(n, v) set[n] = v end, SetSpeedLimit = function(v) limit = v end, SetAirDismountBlock = function(v) airy = v end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
S.ApplyTuning()
print("classic (the default): small curves, no crossings / terrain creases / tiny-step ramps:",
	set.SK8_CURVE_CAP == "16" and set.SK8_TAPER == "linear" and set.SK8_OFF == "crossings,bigterrain,shortsteps" and "OK" or "<-- WRONG")
print("the speed limit is passed on:", limit == 25 and "OK" or "<-- WRONG")
cv.skategm_collision_style = "1"
S.ApplyTuning()
print("experimental: all cleared (5.20's behaviour):", set.SK8_CURVE_CAP == nil and set.SK8_TAPER == nil and set.SK8_OFF == nil and "OK" or "<-- WRONG")
print("Y in the air is allowed by default:", airy == 0 and "OK" or "<-- WRONG")
cv.skategm_block_air_dismount = "1"
S.ApplyTuning()
print("and can be blocked:", airy == 1 and "OK" or "<-- WRONG")
