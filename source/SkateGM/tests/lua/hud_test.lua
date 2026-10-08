dofile("gmock.lua")
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
function RealTime() return 0 end
function IsValid(x) if type(x) == "table" and x.IsValid then return x:IsValid() end return x ~= nil end
function CreateClientConVar(n, d) return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetInt = function() return tonumber(d) or 0 end, GetString = function() return d end } end
MsgC = function() end chat = { AddText = function() end }
function LocalPlayer() return {} end
function ScrW() return 1920 end function ScrH() return 1080 end
TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP = 0, 1, 2, 3
local texts = {}
draw = { SimpleText = function(t) texts[#texts + 1] = t end }
surface = setmetatable({ GetTextSize = function(t) return #t * 20, 40 end }, { __index = function() return function() end end })
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
S.phase = "on"
local t = 0
local function feed(sc) t = t + 0.1 S.HudUpdate(sc, t) end
local function events() local out = {} for _, e in ipairs(S.H.events) do out[#out + 1] = e.text end return table.concat(out, " | ") end
local base = { total = 0, line = 0, sequence = 0, lineTime = 0, lineCapacity = 4, multiplier = 1, trick = "" }
local function sc(over) local r = {} for k, v in pairs(base) do r[k] = v end for k, v in pairs(over) do r[k] = v end return r end

feed(sc({}))
feed(sc({ sequence = 100, trick = "Kickflip" }))
print("trick name shows:", S.H.trick == "Kickflip" and "OK" or "<-- WRONG")
feed(sc({ sequence = 0, line = 100, lineTime = 4, clean = true, trick = "Kickflip" }))
print("clean landing call-out, no false bail:", events():find("CLEAN") and not events():find("BAILED") and "OK" or "<-- WRONG (" .. events() .. ")")
feed(sc({ sequence = 600, line = 100, lineTime = 3.5, multiplier = 2, trick = "50-50" }))
feed(sc({ sequence = 0, line = 700, lineTime = 4, multiplier = 2, trick = "50-50" }))
print("combo multiplier tracked:", S.H.mult == 2 and S.H.line == 700 and "OK" or "<-- WRONG")
feed(sc({ total = 700, line = 0, lineTime = 0 }))
print("line banks: LINE +700:", events():find("LINE  %+700") and "OK" or "<-- WRONG (" .. events() .. ")")
feed(sc({ total = 700, sequence = 250, lineTime = 3, trick = "Heelflip" }))
feed(sc({ total = 700, sequence = 0, line = 0, lineTime = 0, trick = "Heelflip" }))
print("lost sequence: BAILED:", events():find("BAILED") and "OK" or "<-- WRONG (" .. events() .. ")")
print("thousands separators:", S.Commas(1234567) == "1,234,567" and S.Commas(950) == "950" and "OK" or "<-- WRONG")
-- drawing: runs and shows the numbers
texts = {}
feed(sc({ total = 12500, line = 1800, sequence = 400, lineTime = 2, multiplier = 3, trick = "Kickflip" }))
local ok, err = pcall(S.HudPaint, 1920, 1080, t)
local shown = table.concat(texts, " ")
print("display draws:", ok and shown:find("12,500") and shown:find("1,800") and shown:find("x3") and shown:find("+400") and shown:find("KICKFLIP") and "OK" or ("<-- WRONG " .. tostring(err) .. " / " .. shown))
S.phase = "off" texts = {}
S.HudPaint(1920, 1080, t)
print("hidden when not skating:", #texts == 0 and "OK" or "<-- WRONG")
texts = {}
local boxes = 0
draw.RoundedBox = function() boxes = boxes + 1 end
S.phase = "on"
S.pose = { held = true }
S.HudPaint(1920, 1080, t)
print("waiting for collision: nothing for the first few frames", boxes == 0 and "OK" or "<-- WRONG")
S.HudPaint(1920, 1080, t + 0.3)
local said = table.concat(texts, " | ")
print("waiting for collision: a popup says so", boxes == 1 and said:find("Waiting for collision to load", 1, true) and "OK" or "<-- WRONG (" .. said .. ")")
S.pose = { held = false }
texts, boxes = {}, 0
S.HudPaint(1920, 1080, t + 0.35)
print("... and goes away once it's in", boxes == 0 and not table.concat(texts, " "):find("Waiting", 1, true) and "OK" or "<-- WRONG")
