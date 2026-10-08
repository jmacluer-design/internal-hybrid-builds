dofile("sound_test.lua") -- mocks + S (prints its own results first)
print("--- local skater at 144 fps, engine at 60 Hz, two updates per frame")
local S = SkateGM
local log3 = {}
local ent3 = { IsValid = function() return true end, EmitSound = function(_, path) log3[#log3 + 1] = path end }
local fps, hz = 144, 60
local t, simT = 200, 200
local P = nil
-- advance game time frame by frame; the pose only changes when the engine ticks
local function play(seconds, state, makePose)
	local frames = math.floor(seconds * fps)
	for _ = 1, frames do
		t = t + 1 / fps
		S.UpdateSound("local", ent3, P, state, t)          -- start of Think: last frame's pose
		while simT + 1 / hz <= t do simT = simT + 1 / hz P = makePose(simT) end
		S.UpdateSound("local", ent3, P, state, t)          -- after Poll: this frame's pose
	end
end
local function board(x, z) return { RIGHT_WHEELFRONT = Vector(x + 7, -4, z), LEFT_WHEELFRONT = Vector(x + 7, 4, z), RIGHT_WHEELBACK = Vector(x - 7, -4, z), LEFT_WHEELBACK = Vector(x - 7, 4, z) } end
local function riding(tt, pushAt)
	local x = (tt - 200) * 500 -- 500 u/s
	local b = board(x, 1.1)
	b.HIPS = Vector(x, 0, 36)
	b.RIGHTTOEBASE = Vector(x + 4, -2, 4.5)
	-- pushing: the left foot is planted on the ground beside the board, still in
	-- the world while the board rolls on (then swings back up onto the board)
	b.LEFTTOEBASE = pushAt and Vector(pushAt, 14, 2.5) or Vector(x - 4, 2, 4.5)
	return b
end
P = riding(t)
play(1.0, "PhysicsGround", function(tt) return riding(tt) end)
print("rolling sound while riding:", RAG_PLAYING[S.SND.roll] and "OK" or "<-- WRONG")
log3 = {}
for _ = 1, 3 do
	local plantX = (t - 200) * 500 - 6
	play(0.15, "PhysicsGround", function(tt) return riding(tt, plantX) end)
	play(0.4, "PhysicsGround", function(tt) return riding(tt) end)
end
local pushes = 0
for _, p in ipairs(log3) do if p:find("footsteps", 1, true) then pushes = pushes + 1 end end
print(string.format("push steps: %d (3 pushes) %s", pushes, pushes == 3 and "OK" or "<-- WRONG"))

-- walking: a real gait. The planted foot stays put; the other swings forward,
-- lifting only 2 units (a slow walk / shuffle: the case that used to be silent)
local function walker(lift)
	return function(tt)
		local e = tt - 200
		local step = math.floor(e / 0.4)             -- a step every 0.4 s
		local f = (e % 0.4) / 0.4
		local stride = 30
		local hipsX = e / 0.4 * stride
		local p = board(5000, 1.1)
		p.HIPS = Vector(hipsX, 0, 38)
		local planted = step * stride                -- where the back foot rests
		local swing = planted + f * 2 * stride - stride
		local swingZ = 2 + math.sin(f * math.pi) * lift
		if step % 2 == 0 then
			p.RIGHTTOEBASE, p.LEFTTOEBASE = Vector(planted, -4, 2), Vector(swing, 4, swingZ)
		else
			p.LEFTTOEBASE, p.RIGHTTOEBASE = Vector(planted, 4, 2), Vector(swing, -4, swingZ)
		end
		return p
	end
end
for _, lift in ipairs({ 6, 2 }) do
	log3 = {}
	play(4.0, "BipedGround", walker(lift))
	local steps = 0
	for _, p in ipairs(log3) do if p:find("footsteps", 1, true) then steps = steps + 1 end end
	print(string.format("walking, feet lifting %d units: %d steps in 4 s (10 foot plants) %s", lift, steps, steps >= 9 and steps <= 11 and "OK" or "<-- WRONG"))
end
-- standing still on the board: silent
log3 = {}
play(1.0, "PhysicsGround", function() local b = board(0, 1.1) b.HIPS = Vector(0, 0, 36) b.RIGHTTOEBASE = Vector(4, -2, 4.5) b.LEFTTOEBASE = Vector(-4, 2, 4.5) return b end)
local noise = 0
for _, p in ipairs(log3) do if p:find("footsteps", 1, true) then noise = noise + 1 end end
print(string.format("standing still on the board: %d steps %s", noise, noise == 0 and "OK" or "<-- WRONG"))

-- a steady tumble at 144/60: no phantom ragdoll hits
log3 = {}
local function tumble(tt)
	local x = (tt - 200) * 250
	local p = board(x + 30, 20)
	p.HIPS = Vector(x, 0, 20) p.HEAD = Vector(x + 20, 0, 24) p.SPINE2 = Vector(x + 10, 0, 22)
	p.RIGHTHAND = Vector(x + 15, -10, 20) p.LEFTHAND = Vector(x + 15, 10, 20) p.RIGHTFOOT = Vector(x - 30, -4, 18) p.LEFTFOOT = Vector(x - 30, 4, 18)
	return p
end
play(0.1, "WipeoutGround", tumble)  -- the bail starts: its own body hit + board clatter
log3 = {}                           -- from here on, any impact would be a phantom
play(1.0, "WipeoutGround", tumble)
local phantom = 0
for _, p in ipairs(log3) do if p:find("impact", 1, true) then phantom = phantom + 1 end end
print(string.format("steady slide at 144 fps: %d phantom ragdoll hits %s", phantom, phantom == 0 and "OK" or "<-- WRONG"))
