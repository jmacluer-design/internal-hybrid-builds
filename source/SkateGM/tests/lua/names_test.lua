dofile("gmock.lua")
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
function RealTime() return 0 end
function IsValid(x) return x ~= nil end
function CreateClientConVar(n, d) return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetInt = function() return 0 end, GetString = function() return d end } end
MsgC = function() end chat = { AddText = function() end } function LocalPlayer() return {} end
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local N = SkateGM.TrickName
for _, c in ipairs({ { "ID_POP_SHUVIT", "Pop Shove-it" }, { "ID_FS_BOARDSLIDE", "Frontside Boardslide" }, { "ID_5_0", "5-0" },
	{ "ID_50_50", "50-50" }, { "ID_BS_360_KICKFLIP", "Backside 360 Kickflip" }, { "ID_NOLLIE_HEELFLIP", "Nollie Heelflip" },
	{ "Pop Shove-it", "Pop Shove-it" } }) do
	local got = N(c[1])
	print(string.format("%-22s -> %-24s %s", c[1], got, got == c[2] and "OK" or "<-- WRONG (want " .. c[2] .. ")"))
end
