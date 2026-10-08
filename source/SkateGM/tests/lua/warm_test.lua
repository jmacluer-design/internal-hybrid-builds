dofile("gmock.lua")
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
function IsValid(x) return x ~= nil end
local said = {}
MsgC = function(...) said[#said + 1] = select(select("#", ...) - 1, ...) end chat = { AddText = function() end }
local hooks = {}
hook = { Add = function(n, id, f) hooks[n .. "/" .. id] = f end }
local timers = {}
timer = { Simple = function(_, f) timers[#timers + 1] = f end }
local function flush() local t = timers timers = {} for _, f in ipairs(t) do f() end end
local function run(warmSetting, moduleThere)
	local cv = { skategm_warm_engine = warmSetting, skategm_data = "C:/skategm/assets" }
	CreateClientConVar = function(n, d) if cv[n] == nil then cv[n] = d end
		return { GetBool = function() return cv[n] == "1" end, GetFloat = function() return tonumber(cv[n]) or 0 end, GetInt = function() return 0 end, GetString = function() return cv[n] end } end
	local preloaded
	skategm = nil
	require = function(name)
		if name == "skategm" and moduleThere then skategm = { Preload = function(p) preloaded = p return true end } return end
		error("module not found")
	end
	LocalPlayer = function() return nil end
	said, timers, hooks = {}, {}, {}
	dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
	hooks["InitPostEntity/skategm_warm"]()
	flush() flush()
	return preloaded
end
print("joining a map warms the engine, with the data path:", run("1", true) == "C:/skategm/assets" and "OK" or "<-- WRONG")
print("setting off: nothing:", run("0", true) == nil and "OK" or "<-- WRONG")
local p = run("1", false)
print("no module (not on x86-64): nothing, and nothing in chat:", p == nil and #said == 0 and "OK" or ("<-- WRONG " .. table.concat(said, "|")))
