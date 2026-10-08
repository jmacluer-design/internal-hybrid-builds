dofile("gmock.lua")
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
local cmds = {}
concommand = { Add = function(n, f) cmds[n] = f end }
local clock = 0
function RealTime() return clock end
function IsValid(x) if type(x) == "table" and x.IsValid then return x:IsValid() end return x ~= nil end
function CreateClientConVar(n, d) return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetInt = function() return 0 end, GetString = function() return d end } end
local said, printed = {}, {}
MsgC = function(...) local t = { ... } said[#said + 1] = t[#t - 1] end chat = { AddText = function() end }
local realprint = print
print = function(...) local t = {} for i, v in ipairs({ ... }) do t[i] = tostring(v) end printed[#printed + 1] = table.concat(t, "\t") end
function LocalPlayer() return {} end
game = { GetMap = function() return "tl_skatepark" end }
local written
file = setmetatable({ Write = function(name, text) written = { name = name, text = text } end }, { __index = function() return function() end end })
-- a ramp surface under the board (slope 40 degrees), as a displacement
skategm = { CollisionNear = function(x, y, z) return { x - 50, y - 50, z - 1, x + 50, y - 50, z - 1, x, y + 60, z - 1 }, { 1 } end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
S.phase, S.loadedScale = "on", 1
cmds["skategm_trace"](nil, nil, { "2" })
local tick, z, speed = 0, 0, 6.0
local function frame(state, dspeed)
	clock = clock + 1 / 60
	tick = tick + 1
	speed = math.max(0, speed + dspeed)
	z = z + speed * 0.3
	-- (the trace measures speed from movement: move the board at that speed)
	xpos = (xpos or 0) + speed / 0.0254 / 60
	S.anchor = Vector(xpos, 0, z)
	S.P = { TRUCK_FRONT = Vector(xpos + 7, 0, z + 5), TRUCK_BACK = Vector(xpos - 7, 0, z) }
	local v = speed / 0.0254
	S.TraceThink({ pos = { 0, 0, z }, tick = tick, vel = { v * 0.6, 0, v * 0.8 }, state = state }, clock)
end
for i = 1, 60 do frame("PhysicsGround", -0.02) end   -- climbing: gradual slowing
frame("PhysicsGround", -3.5)                          -- a sudden hit
for i = 1, 20 do frame("PhysicsGround", -0.02) end
frame("WipeoutGround", -1)                            -- the bail
for i = 1, 60 do frame("WipeoutGround", -0.05) end    -- until the recording ends
local out = table.concat(printed, "\n")
local function check(label, ok) realprint(string.format("%-62s %s", label, ok and "OK" or "<-- WRONG")) end
check("the sudden speed drop is named, with height and surface", out:find("speed [%d%.]+ %-> [%d%.]+ m/s in 0.1 s at height") and out:find("displacement") ~= nil)
check("the bail is named (state change and where)", out:find("PhysicsGround %-> WipeoutGround") ~= nil)
check("the whole log is saved for sending", written and written.name == "skategm_trace.txt" and select(2, written.text:gsub("\n", "")) > 100)
check("recording stops by itself", S.trace == nil)
local firstText = written.text
-- a run with only gradual slowing: nothing flagged
printed = {}
cmds["skategm_trace"](nil, nil, { "2" })
speed = 6
for i = 1, 130 do frame("PhysicsGround", -0.02) end
check("gradual slowing only: no sudden drops reported", table.concat(printed, "\n"):find("only gradual slowing") ~= nil)
-- the first run's file also holds the collision around the board at the hit
check("the collision around the board at the hit is saved", firstText:find("collision within 48 units of the board") ~= nil and firstText:find("displacement |", 1, true) ~= nil)
-- the engine's velocity says 68 m/s (as in a runout), the skater moves at 1 m/s
printed = {}
cmds["skategm_trace"](nil, nil, { "2" })
for i = 1, 130 do
	clock = clock + 1 / 60
	tick = tick + 1
	xpos = xpos + 1 / 0.0254 / 60
	S.anchor = Vector(xpos, 0, 400)
	S.TraceThink({ pos = { xpos, 0, 400 }, tick = tick, vel = { 68 / 0.0254, 0, 0 }, state = "BipedGround" }, clock)
end
local top = table.concat(printed, "\n"):match("top speed ([%d%.]+) m/s")
check("speed comes from movement, not the engine's (wrong) velocity: top " .. tostring(top), top and tonumber(top) < 1.5)
