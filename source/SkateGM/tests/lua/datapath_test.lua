dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
function IsValid(x) return x ~= nil end
local saved = {}
function CreateClientConVar(n, d) return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetInt = function() return 0 end, GetString = function() return saved[n] or d end } end
MsgC = function() end chat = { AddText = function() end }
function LocalPlayer() return {} end
local ran = {}
function RunConsoleCommand(...) ran[#ran + 1] = table.concat({ ... }, " ") end
local files = { ["skategm/datapath.txt"] = "C:/Users/me/AppData/Local/SkateGM/data/assets\n" }
file = { Read = function(p) return files[p] end, Exists = function(p) return files[p] ~= nil end, Find = function() return {} end, CreateDir = function() end, Write = function() end }
local function load() ran = {} dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua") end
load()
local set
for _, r in ipairs(ran) do if r:find("^skategm_data ") then set = r end end
check("the installer's data folder is used", set == "skategm_data C:/Users/me/AppData/Local/SkateGM/data/assets")
check("... even while the setting still says the default (a server join, config.txt)", SkateGM.DataPath() == "C:/Users/me/AppData/Local/SkateGM/data/assets")
saved.skategm_data = "D:/mydata"
load()
set = nil
for _, r in ipairs(ran) do if r:find("^skategm_data ") then set = r end end
check("... unless the player chose a folder of their own", set == nil)
check("... and then theirs is what the engine gets", SkateGM.DataPath() == "D:/mydata")
files["skategm/datapath.txt"] = nil
saved.skategm_data = nil
load()
set = nil
for _, r in ipairs(ran) do if r:find("^skategm_data ") then set = r end end
check("no installer file: the default stays", set == nil)
check("... and the engine gets the default", SkateGM.DataPath() == "C:/skategm/assets")
