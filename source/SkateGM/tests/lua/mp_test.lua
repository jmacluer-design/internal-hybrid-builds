dofile("gmock.lua")
-- a mock net library with one wire; bits are counted like GMod does
local wire, handlers, cur = {}, {}, nil
local function newmsg(name) cur = { name = name, v = {}, bits = 0 } end
net = {
	Start = function(name) newmsg(name) end,
	WriteFloat = function(x) table.insert(cur.v, x) cur.bits = cur.bits + 32 end,
	WriteInt = function(x, b) table.insert(cur.v, x) cur.bits = cur.bits + b end,
	WriteUInt = function(x, b) table.insert(cur.v, x) cur.bits = cur.bits + b end,
	WriteEntity = function(e) table.insert(cur.v, e) cur.bits = cur.bits + 16 end,
	WriteBool = function(x) table.insert(cur.v, x) cur.bits = cur.bits + 1 end,
	WriteVector = function(x) table.insert(cur.v, x) cur.bits = cur.bits + 60 end,
	SendToServer = function() cur.to = "server" table.insert(wire, cur) end,
	SendOmit = function(ply) cur.to = "clients" cur.omit = ply table.insert(wire, cur) end,
	Broadcast = function() cur.to = "clients" table.insert(wire, cur) end,
	Receive = function(name, fn) handlers[name] = handlers[name] or {} table.insert(handlers[name], fn) end,
}
local rd
local function rnext() rd.i = rd.i + 1 return rd.v[rd.i] end
net.ReadFloat, net.ReadInt, net.ReadEntity, net.ReadBool, net.ReadVector, net.ReadUInt = rnext, rnext, rnext, rnext, rnext, rnext

-- players
local A = { name = "A", SkateGM = false, IsValid = true }
local B = { name = "B" }
function IsValid(x) return x ~= nil and x ~= false end
local clock = 0
function RealTime() return clock end
function SysTime() return clock end
function LerpVector(f, a, b) return a + (b - a) * f end
math.Clamp = function(v, a, b) return math.max(a, math.min(b, v)) end
math.Round = function(x) return math.floor(x + 0.5) end
util = { AddNetworkString = function() end }
function CreateConVar() return { GetBool = function() return true end } end
FCVAR_ARCHIVE, FCVAR_NOTIFY = 1, 2
game = { SinglePlayer = function() return false end }
COLLISION_GROUP_DEBRIS, COLLISION_GROUP_DEBRIS_TRIGGER, COLLISION_GROUP_WEAPON = 1, 2, 11
COLLISION_GROUP_IN_VEHICLE, COLLISION_GROUP_PASSABLE_DOOR, COLLISION_GROUP_WORLD = 10, 15, 20

-- the server script
dofile("../../addon/skategm/lua/autorun/server/skategm_sv.lua")
local server_pose = handlers["skategm_pose"][1]

-- ConVars with their real defaults
function CreateClientConVar(name, default)
	return { GetBool = function() return default == "1" end, GetFloat = function() return tonumber(default) or 0 end, GetString = function() return default end }
end
-- client B (the viewer)
function LocalPlayer() return B end
dofile("../../addon/skategm/lua/autorun/client/skategm_cl.lua")
local S = SkateGM
local client_pose = handlers["skategm_pose"][2]

local function deliver_once()
	local msgs = wire wire = {}
	for _, m in ipairs(msgs) do
		rd = { v = m.v, i = 0 }
		if m.to == "server" then server_pose(m.bits, A)
		elseif m.name == "skategm_pose" and m.omit ~= B then client_pose(m.bits) end
	end
end
local function deliver() for _ = 1, 3 do deliver_once() end end

-- A's skater pose: hips somewhere on the map, bones around it
local function poseAt(x)
	local P = {}
	for i, name in ipairs(S.BONES) do P[name] = Vector(x + i * 0.37, 200 - i * 1.11, 40 + i * 0.73) end
	P.HIPS = Vector(x, 200, 40)
	return P
end

-- 1) not skating yet: the server must not relay
S.P = poseAt(100)
net.Start("skategm_pose", true) S.Encode(S.P, { float = net.WriteFloat, int = function(v) net.WriteInt(v, 16) end, u8 = function(v) net.WriteInt(v, 8) end })
net.SendToServer() deliver()
print("relayed before A is skating:", S.remote[A] ~= nil and "YES <-- WRONG" or "no  OK")

-- 2) A skating: snapshot arrives at B intact
A.SkateGM = true
local sent = poseAt(100)
S.P = sent
clock = 1.0
net.Start("skategm_pose", true) S.Encode(sent, { float = net.WriteFloat, int = function(v) net.WriteInt(v, 16) end, u8 = function(v) net.WriteInt(v, 8) end })
print("snapshot size:", cur.bits, "bits =", cur.bits / 8, "bytes")
net.SendToServer() deliver()
local got = S.remote[A] and S.remote[A].snaps[1].P
local worst = 0
for _, name in ipairs(S.BONES) do worst = math.max(worst, (got[name] - sent[name]):Length()) end
print(string.format("bones arrive within %.4f units of the sender's %s", worst, worst <= math.sqrt(3) / 32 + 1e-6 and "OK" or "<-- WRONG"))

-- 3) spam: a second packet in the same instant is dropped
net.Start("skategm_pose", true) S.Encode(poseAt(999), { float = net.WriteFloat, int = function(v) net.WriteInt(v, 16) end, u8 = function(v) net.WriteInt(v, 8) end })
net.SendToServer() deliver()
print("spam in the same 1/40 s dropped:", #S.remote[A].snaps == 1 and "OK" or "<-- WRONG")

-- 4) a short/junk packet is rejected
clock = 1.03
net.Start("skategm_pose", true) net.WriteFloat(1) net.WriteFloat(2)
net.SendToServer() deliver()
print("truncated packet rejected:", #S.remote[A].snaps == 1 and "OK" or "<-- WRONG")

-- 5) smoothing: second snapshot 50 ms later, 20 units further
clock = 1.05
net.Start("skategm_pose", true) S.Encode(poseAt(120), { float = net.WriteFloat, int = function(v) net.WriteInt(v, 16) end, u8 = function(v) net.WriteInt(v, 8) end })
net.SendToServer() deliver()
local r = S.remote[A]
local mid = S.RemotePose(r, 1.125) -- draw time 1.025 = halfway between 1.00 and 1.05
print(string.format("drawn halfway between snapshots: hips x = %.2f (expect 110) %s", mid.HIPS.x, math.abs(mid.HIPS.x - 110) < 0.05 and "OK" or "<-- WRONG"))
local newest = S.RemotePose(r, 5)
print(string.format("no extrapolation past the newest: hips x = %.1f %s", newest.HIPS.x, newest.HIPS.x == 120 and "OK" or "<-- WRONG"))

-- 6) other players become blocks in B's collision
local C = { name = "C" } -- walking, not skating
A.Alive = function() return true end
C.Alive = function() return true end
C.GetNoDraw = function() return false end
C.GetPos = function() return Vector(300, 200, 0) end
B.Alive = function() return true end
player = { GetAll = function() return { A, B, C } end }
local sentEnts
skategm = { SetEntities = function(list) sentEnts = list end, DefineModel = function() end }
ents = { FindInSphere = function() return {} end }
clock = 1.2
S.test.FeedEntities(Vector(100, 200, 0))
local blocks = {}
for _, e in ipairs(sentEnts or {}) do if e[1] == "skategm/player" then blocks[#blocks + 1] = e end end
print("player blocks sent:", #blocks, #blocks == 2 and "OK (skater A and walker C, not me)" or "<-- WRONG")
for _, b in ipairs(blocks) do print(string.format("  block at %.0f, %.0f, %.0f", b[2], b[3], b[4])) end
A.GetNoDraw = function() return true end
local sends = 0
skategm.SetEntities = function(list) sends = sends + 1 sentEnts = list end
local cx = 300
C.GetPos = function() return Vector(cx, 200, 0) end
for k = 1, 4 do
	clock = 1.2 + k * 0.25
	cx = 300 + k * 40
	S.test.FeedEntities(Vector(100, 200, 0))
end
print("another player walking past: collision rebuilt at most once a second", sends == 1 and "OK" or "<-- WRONG (" .. sends .. ")")
clock = 3.3
cx = 900
S.test.FeedEntities(Vector(100, 200, 0))
print("... and caught up a second later", sends == 2 and "OK" or "<-- WRONG (" .. sends .. ")")

-- 7) A stops skating: gone for B at once
rd = { v = { A }, i = 0 }
handlers["skategm_off"][1]()
print("A removed after skategm_off:", S.remote[A] == nil and "OK" or "<-- WRONG")
-- the state byte travels with the pose
clock = 3
A.SkateGM = true
S.remote[A] = nil
local P = poseAt(50)
net.Start("skategm_pose", true) S.Encode(P, { float = net.WriteFloat, int = function(v) net.WriteInt(v, 16) end, u8 = function(v) net.WriteUInt(v, 8) end }, "GrindFiftyFifty")
net.SendToServer() deliver()
print("state arrives with the snapshot:", S.remote[A] and S.remote[A].state == "GrindFiftyFifty" and "OK" or "<-- WRONG (" .. tostring(S.remote[A] and S.remote[A].state) .. ")")

local poses = 0
local realStart = net.Start
net.Start = function(name, u) if name == "skategm_pose" then poses = poses + 1 end return realStart(name, u) end
S.P, S.pose = poseAt(10), { state = "PhysicsGround" }
for k = 0, 19 do clock = 10 + k * 0.05 S.SendPose() end
print(string.format("standing still: pose sent %d times in 1 s (a keepalive, not 20) %s", poses, (poses >= 2 and poses <= 4) and "OK" or "<-- WRONG"))
poses = 0
for k = 0, 9 do clock = 20 + k * 0.05 S.P = poseAt(10 + k * 5) S.SendPose() end
print(string.format("moving: every pose sent (%d of 10) %s", poses, poses == 10 and "OK" or "<-- WRONG"))
net.Start = realStart
