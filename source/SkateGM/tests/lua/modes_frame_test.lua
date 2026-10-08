dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
util = setmetatable({ AddNetworkString = function() end, TableToJSON = function(t) return t end, JSONToTable = function(t) return t end }, { __index = util })
local wrote
net = { Receive = function() end, Start = function() end, WriteString = function(t) wrote = t end, SendToServer = function() end }
hook = { Add = function() end, Run = function() end }
cvars = { AddChangeCallback = function() end }
function GetConVar() return nil end
function CreateConVar(n, d) return { GetBool = function() return d == "1" end } end
FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY = 1, 2, 4
timer = { Simple = function(_, f) f() end }
function RealTime() return 0 end
local ME = { EntIndex = function() return 1 end }
function LocalPlayer() return ME end
function IsValid(x) return x ~= nil end
local offset
SkateGM = { API = {}, Offset = function() return offset end }
SERVER, CLIENT = nil, true
dofile("../../addon/skategm/lua/skategm_modes/sh_modes.lua")
local M = SKATEGM_MODES
local mode = M.Register({ id = "framey", title = "Framey", order = 9 })

mode:Send({ cmd = "create", pos = { 1, 2, 3 }, yaw = 90 })
check("a normal map: messages untouched", wrote.pos[1] == 1 and wrote.yaw == 90)

offset = Vector(40000, -20000, 0)
mode:Send({ cmd = "create", pos = { 1, 2, 3 }, centre = Vector(5, 0, 0), x = 7, y = 8, z = 9, p = { 1, 2, 3, 4, 5, 6 }, radius = 500, yaw = 90 })
check("out to the server: {x,y,z} positions made absolute", wrote.pos[1] == 40001 and wrote.pos[2] == -19998 and wrote.pos[3] == 3)
check("... Vectors too", wrote.centre.x == 40005)
check("... x / y / z fields too", wrote.x == 40007 and wrote.y == -19992 and wrote.z == 9)
check("... flat point lists too", wrote.p[1] == 40001 and wrote.p[2] == -19998 and wrote.p[4] == 40004 and wrote.p[5] == -19995)
check("... other numbers left alone", wrote.radius == 500 and wrote.yaw == 90)

mode:HandleState({ phase = "lobby", start = { 40001, -19999, 50 }, area = { 40000, -20000, 0, 800 }, timeLeft = 30,
	pellets = { { id = 1, x = 40010, y = -20000, z = 0 } }, players = { { ent = 1, start = { 40002, -20000, 0 } } } }, 0)
local st = mode.state
check("in from the server: positions relative to me", st.start[1] == 1 and st.start[2] == 1 and st.start[3] == 50)
check("... an area keeps its radius", st.area[1] == 0 and st.area[4] == 800)
check("... nested ones too (each player's start, the orbs)", st.players[1].start[1] == 2 and st.pellets[1].x == 10 and st.pellets[1].id == 1)
check("... timers alone", st.timeLeft == 30)
local seenStart
mode:OnState(function(s) seenStart = s.start and s.start[1] end)
M.FrameThink(1)
offset = Vector(60000, -20000, 0)
M.FrameThink(2)
check("crossing into the next chunk: the game's positions follow", seenStart == 40001 - 60000)

-- modes that keep positions of their own hear by how much the frame moved
local shifted
mode:OnFrameShift(function(d) shifted = d end)
offset = Vector(80000, -20000, 0)
M.FrameThink(3)
check("a mode keeping its own positions hears the frame's shift", shifted and shifted.x == 20000 and shifted.y == 0)
