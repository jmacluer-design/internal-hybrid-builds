dofile("gmock.lua")
net = setmetatable({ Receive = function() end }, { __index = function() return function() end end })
concommand = { Add = function() end }
function RealTime() return 0 end
function IsValid(x) if type(x) == "table" and x.IsValid then return x:IsValid() end return x ~= nil end
function CreateClientConVar(n, d) return { GetBool = function() return d == "1" end, GetFloat = function() return tonumber(d) or 0 end, GetString = function() return d end } end
function LerpVector(f, a, b) return a + (b - a) * f end
function Lerp(f, a, b) return a + (b - a) * f end
MsgC = function() end chat = { AddText = function() end }
local ME = { IsValid = function() return true end }
function LocalPlayer() return ME end
local log = {}
local playing = {}
RAG_PLAYING = playing
function CreateSound(ent, path)
	local s = { path = path, on = false, vol = 0, pitch = 100 }
	function s:PlayEx(v, p) self.on = true playing[path] = self end
	function s:IsPlaying() return self.on end
	function s:ChangeVolume(v) self.vol = v end
	function s:ChangePitch(p) self.pitch = p end
	function s:FadeOut() self.on = false playing[path] = nil end
	function s:Stop() self.on = false playing[path] = nil end
	return s
end
local ent = { IsValid = function() return true end, EmitSound = function(_, path, lvl, pitch, vol) log[#log + 1] = path end }
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM

local t, x, z = 0, 0, 36
local function pose(footDown)
	local P = { HIPS = Vector(x, 0, z), RIGHT_WHEELFRONT = Vector(x + 7, -4, z - 35), LEFT_WHEELFRONT = Vector(x + 7, 4, z - 35),
		RIGHT_WHEELBACK = Vector(x - 7, -4, z - 35), LEFT_WHEELBACK = Vector(x - 7, 4, z - 35),
		RIGHTTOEBASE = Vector(x + 4, -2, z - 33), LEFTTOEBASE = Vector(x - 4, 2, z - 33) }
	if footDown then P.LEFTTOEBASE = Vector(x - 3, 16, z - 36) end -- planted beside the board
	return P
end
local function run(state, frames, dx, dz, foot)
	for _ = 1, frames do
		t = t + 1 / 60 x = x + dx z = z + (dz or 0)
		S.UpdateSound("me", ent, pose(foot), state, t)
	end
end
local function heard(pattern) for _, p in ipairs(log) do if p:find(pattern, 1, true) then return true end end return false end
local function loop(name) return playing[S.SND[name]] end

run("PhysicsGround", 60, 8)                        -- rolling at 480 u/s
local r = loop("roll")
print(string.format("rolling loop on: %s, pitch %.0f", r and "OK" or "<-- WRONG", r and r.pitch or 0))
run("PhysicsAir", 10, 8, 4)                        -- pop: rising
print("pop sound on takeoff:", heard("wood_plank_impact_hard") and "OK" or "<-- WRONG")
print("rolling stops in the air:", not loop("roll") and "OK" or "<-- WRONG")
run("PhysicsAir", 20, 8, -6)                       -- falling fast
log = {}
run("PhysicsGround", 5, 8)
print("landing sound:", (heard("wood_box_impact_hard") or heard("wood_crate_impact_hard")) and "OK" or "<-- WRONG")
run("PhysicsAir", 5, 8, 3) run("PhysicsAir", 10, 8, -3)
log = {}
run("GrindFiftyFifty", 30, 6)
print("clank into a 50-50 and metal grind loop:", heard("metal_solid_impact") and loop("grindMetal") and "OK" or "<-- WRONG")
run("GrindBoardslide", 10, 6)
print("boardslide switches to the wood scrape:", loop("grindWood") and not loop("grindMetal") and "OK" or "<-- WRONG")
log = {}
run("PhysicsGround", 20, 6)
run("PhysicsGround", 20, 3, 0, true)               -- foot planted, slowing down
print("brake scrape while a foot drags beside the board:", loop("drag") and "OK" or "<-- WRONG")
log = {}
run("WipeoutGround", 3, 2)
print("bail: body impact + board clatter:", heard("body_medium_impact") and heard("wood_box_impact_soft") and "OK" or "<-- WRONG")
S.StopSounds("me")
local any = false for _ in pairs(playing) do any = true end
print("all loops stop when the skater goes away:", not any and "OK" or "<-- WRONG")
