dofile("gmock.lua")
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
function IsValid(x) return x ~= nil end
MsgC = function() end chat = { AddText = function() end } function LocalPlayer() return {} end
local function run(saved)
	local cv = { skategm_smooth_steps = saved, skategm_settings_version = "1" }
	CreateClientConVar = function(n, d)
		if cv[n] == nil then cv[n] = d end
		return { GetBool = function() return cv[n] == "1" end, GetFloat = function() return tonumber(cv[n]) or 0 end, GetInt = function() return math.floor(tonumber(cv[n]) or 0) end, GetString = function() return cv[n] end }
	end
	RunConsoleCommand = function(n, v) cv[n] = tostring(v) end
	dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
	return cv.skategm_smooth_steps, cv.skategm_settings_version
end
for _, c in ipairs({ { "2", "8" }, { "6", "12" }, { "4", "4" } }) do
	local got, ver = run(c[1])
	print(string.format("saved %s -> %s (version %s) %s", c[1], got, ver, got == c[2] and ver == "2" and "OK" or "<-- WRONG"))
end
local got = run(nil)
print("fresh install gets the new default: " .. tostring(got), got == "8" and "OK" or "<-- WRONG")
