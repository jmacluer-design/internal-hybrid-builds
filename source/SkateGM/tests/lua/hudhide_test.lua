dofile("gmock.lua")
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
concommand = { Add = function() end }
function IsValid(x) return x ~= nil end
MsgC = function() end chat = { AddText = function() end } function LocalPlayer() return {} end
function CreateClientConVar(n, d) return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetInt = function() return 0 end, GetString = function() return d end } end
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S, f = SkateGM, hooks["HUDShouldDraw/skategm"]
S.phase = "loading"
print("loading: health hidden:", f("CHudHealth") == false and f("CHudSuitPower") == false and "OK" or "<-- WRONG")
S.phase = "on"
print("skating: health hidden:", f("CHudHealth") == false and f("CHudDamageIndicator") == false and "OK" or "<-- WRONG")
print("chat and the rest are left alone:", f("CHudChat") == nil and "OK" or "<-- WRONG")
S.phase = "off"
print("not skating: health shown as normal:", f("CHudHealth") == nil and "OK" or "<-- WRONG")
