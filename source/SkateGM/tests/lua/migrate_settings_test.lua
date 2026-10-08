dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
MsgC = function() end
chat = { AddText = function() end }
function LocalPlayer() return {} end
local data = {
	["sk8/config.txt"] = "data = D:/old/assets\n",
	["sk8/boards/mine.png"] = "PNGDATA",
}
local mod = { ["cfg/client.vdf"] = '"InstalledConVars"\n{\n\t"sk8_camera_shake"\t\t"1"\n\t"sk8_deck_color"\t\t"1 2 3"\n\t"sk8_nonsense"\t\t"5"\n}\n' }
file = {
	Exists = function(n, where) if where == "MOD" then return mod[n] ~= nil end return data[n] ~= nil end,
	Read = function(n, where) if where == "MOD" then return mod[n] end return data[n] end,
	Write = function(n, t) data[n] = t end,
	CreateDir = function() end,
	Find = function(pat) local out = {} local dir = pat:gsub("%*$", "") for k in pairs(data) do if k:sub(1, #dir) == dir and not k:sub(#dir + 1):find("/") then out[#out + 1] = k:sub(#dir + 1) end end return out end,
}
local set, created = {}, {}
function RunConsoleCommand(n, v) set[n] = v end
function CreateClientConVar(n, d) created[n] = true return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetInt = function() return tonumber(d) or 0 end, GetString = function() return d end, GetName = function() return n end } end
function GetConVar(n) if created[n] then return { GetString = function() return "" end } end end
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
check("old settings come across to the new names", set.skategm_camera_shake == "1")
check("... only ones that still exist", set.skategm_nonsense == nil)
check("the old config file (with the data folder) comes across", data["skategm/config.txt"] == "data = D:/old/assets\n")
check("board images come across", data["skategm/boards/mine.png"] == "PNGDATA")
check("... once: marked as done", data["skategm/migrated.txt"] ~= nil)
set = {}
SkateGM.MigrateOldSettings()
check("a second start doesn't do it again", next(set) == nil)
