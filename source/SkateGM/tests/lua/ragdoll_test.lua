dofile("sound_test.lua") -- reuses its mocks and S; prints its own results first
print("--- ragdoll")
local S = SkateGM
local log2 = {}
local playing2 = {}
local ent2 = { IsValid = function() return true end, EmitSound = function(_, path) log2[#log2 + 1] = path end }
local t2 = 100
local function body(hips, board)
	return { HIPS = hips, HEAD = hips + Vector(0, 0, 28), SPINE2 = hips + Vector(0, 0, 14),
		RIGHTHAND = hips + Vector(10, -8, 10), LEFTHAND = hips + Vector(-10, 8, 10), RIGHTFOOT = hips + Vector(4, -4, -34), LEFTFOOT = hips + Vector(-4, 4, -34),
		RIGHT_WHEELFRONT = board + Vector(7, -4, 0), LEFT_WHEELFRONT = board + Vector(7, 4, 0), RIGHT_WHEELBACK = board + Vector(-7, -4, 0), LEFT_WHEELBACK = board + Vector(-7, 4, 0) }
end
local function frames(n, fn) for i = 1, n do t2 = t2 + 1 / 60 S.UpdateSound("rag", ent2, fn(i), "WipeoutGround", t2) end end
local function heard(p) for _, x in ipairs(log2) do if x:find(p, 1, true) then return true end end return false end
-- 1) the body falls from 80 units at ~400 u/s and hits the ground
local hz, bz = 80, 60
frames(12, function() hz = hz - 7 bz = bz - 5 return body(Vector(0, 0, hz), Vector(40, 0, bz)) end)
frames(10, function() return body(Vector(0, 0, hz), Vector(40, 0, bz)) end)
print("body hits the ground:", (heard("body_medium_impact_hard") or heard("body_medium_impact_soft")) and "OK" or "<-- WRONG")
print("board knocks when it lands:", heard("wood_box_impact") and "OK" or "<-- WRONG")
-- 2) the body skids along the ground at 360 u/s
local x = 0
frames(30, function() x = x + 6 return body(Vector(x, 0, hz), Vector(40, 0, bz)) end)
local skid = false
for _, a in pairs({}) do end
print("skid plays the body scrape loop:", heard("") and "(see loop below)" or "")
print("  body scrape loop on:", RAG_PLAYING[S.SND.bodySlide] and "OK" or "<-- WRONG")
-- 3) a remote skater: smooth (blended) motion that changes direction at each
-- 20 Hz snapshot, plus a late packet that freezes it for 4 frames (marked stale)
log2 = {}
local y, vy = 0, 4
for i = 1, 120 do
	t2 = t2 + 1 / 60
	if i % 3 == 0 then vy = 4 + math.sin(i) end        -- velocity varies between snapshots
	local frozen = i >= 60 and i < 64                  -- late packet
	if not frozen then y = y + vy end
	S.UpdateSound("rag", ent2, body(Vector(500, y, 200), Vector(540, y, 190)), "WipeoutGround", t2, frozen)
end
local hits = 0
for _, p in ipairs(log2) do if p:find("impact", 1, true) then hits = hits + 1 end end
print(string.format("remote motion with jitter and a late packet: %d phantom hits %s", hits, hits == 0 and "OK" or "<-- WRONG"))
-- 4) leaving the bail stops the scrape
t2 = t2 + 1 / 60 S.UpdateSound("rag", ent2, body(Vector(500, y, 200), Vector(540, y, 190)), "PhysicsGround", t2)
print("scrape stops when the bail ends:", not RAG_PLAYING[S.SND.bodySlide] and "OK" or "<-- WRONG")
