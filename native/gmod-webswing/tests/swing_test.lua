-- Tests for lua/webswing/sh_swing.lua (pure math). Run through tests/run.lua.
local T = ...

local globalsBefore = {}
for k in pairs(_G) do globalsBefore[k] = true end
local M = dofile(T.root .. "/lua/webswing/sh_swing.lua")
local sqrt, sin, cos, rad, abs, max = math.sqrt, math.sin, math.cos, math.rad, math.abs, math.max
local U = M.UNIT

-- the engine as GMod's walk/air movement does it: half the gravity before the
-- move, the move, half the gravity after
local function engineStep(p, v, dt, g, ax, ay, az)
	v.z = v.z - 0.5 * g * dt
	if ax then v.x, v.y, v.z = v.x + ax * dt, v.y + ay * dt, v.z + az * dt end
	p.x, p.y, p.z = p.x + v.x * dt, p.y + v.y * dt, p.z + v.z * dt
	v.z = v.z - 0.5 * g * dt
end

-- a deterministic noise source (no math.random: the same numbers on every Lua)
local function lcg(seed)
	local s = seed
	return function()
		s = (s * 1103515245 + 12345) % 2147483648
		return s / 2147483648 * 2 - 1
	end
end

-- swing on a rope. Returns the history tables measured at tick boundaries.
local function swing(opts)
	local g, dt, L = opts.g or 600, opts.dt or 1 / 66, opts.L or 1000
	local a = { x = 0, y = 0, z = 1500 }
	local ang = rad(opts.angle or 60)
	local p = { x = a.x + L * sin(ang), y = a.y, z = a.z - L * cos(ang) }
	local v = opts.v and { x = opts.v[1], y = opts.v[2], z = opts.v[3] } or { x = 0, y = 0, z = 0 }
	local out = { maxOver = -1e9, maxUnder = 0, E0 = 0.5 * (v.x ^ 2 + v.y ^ 2 + v.z ^ 2) + g * p.z, Emax = -1e9, Emin = 1e9, Lz0 = nil, Lzmin = 1e9, Lzmax = -1e9, minZ = 1e9, n = 0 }
	local noise = opts.noise and lcg(7)
	local steps = math.floor((opts.seconds or 20) / dt)
	for i = 1, steps do
		local nvx, nvy, nvz = M.constrain(p.x, p.y, p.z, v.x, v.y, v.z, a.x, a.y, a.z, L, dt, g, opts.maxPull)
		v.x, v.y, v.z = nvx, nvy, nvz
		if noise then
			engineStep(p, v, dt, g, noise() * opts.noise, noise() * opts.noise, noise() * opts.noise)
		else
			engineStep(p, v, dt, g)
		end
		local d = M.dist(p.x, p.y, p.z, a.x, a.y, a.z)
		if d - L > out.maxOver then out.maxOver = d - L end
		local E = 0.5 * (v.x ^ 2 + v.y ^ 2 + v.z ^ 2) + g * p.z
		if E > out.Emax then out.Emax = E end
		if E < out.Emin then out.Emin = E end
		local rx, ry = p.x - a.x, p.y - a.y
		local Lz = rx * v.y - ry * v.x
		out.Lz0 = out.Lz0 or Lz
		if Lz < out.Lzmin then out.Lzmin = Lz end
		if Lz > out.Lzmax then out.Lzmax = Lz end
		if p.z < out.minZ then out.minZ = p.z end
		out.n = i
	end
	out.p, out.v, out.a = p, v, a
	return out
end

T.test("module loads without leaking globals", function()
	T.eq(type(M), "table")
	local leaked = {}
	for k in pairs(_G) do if not globalsBefore[k] then leaked[#leaked + 1] = tostring(k) end end
	T.eq(#leaked, 0, "leaked: " .. table.concat(leaked, ","))
end)

T.test("helpers: norm, angDiffDeg, forward/dirFromYawElev agree, clampSpeed", function()
	local x, y, z, l = M.norm(3, 0, 4)
	T.near(x, 0.6, 1e-12) T.near(z, 0.8, 1e-12) T.near(l, 5, 1e-12)
	local zx, zy, zz, zl = M.norm(0, 0, 0)
	T.eq(zl, 0) T.eq(zx + zy + zz, 0)
	T.near(M.angDiffDeg(10, 350), 20, 1e-9)
	T.near(M.angDiffDeg(350, 10), -20, 1e-9)
	T.near(M.angDiffDeg(180, -180), 0, 1e-9)
	-- GMod angles: pitch +30 looks down; the same direction as elevation -30
	local fx, fy, fz = M.forward(30, 45)
	local ex, ey, ez = M.dirFromYawElev(45, -30)
	T.near(fx, ex, 1e-12) T.near(fy, ey, 1e-12) T.near(fz, ez, 1e-12)
	T.near(M.len(M.forward(-20, 123)), 1, 1e-12)
	local rx, ry = M.right(0)
	T.near(rx, 0, 1e-12) T.near(ry, -1, 1e-12) -- right of +x is -y
	local cx, cy, cz = M.clampSpeed(3000, 0, 4000, 1000)
	T.near(M.len(cx, cy, cz), 1000, 1e-9)
	T.near(cx / cz, 0.75, 1e-12)
end)

T.test("rope length is never exceeded (pure pendulum, 20 s, 66 Hz)", function()
	local r = swing({ L = 1000, angle = 60, seconds = 20 })
	T.note("max over-length %.3g units after %d ticks; lowest point z=%.1f", r.maxOver, r.n, r.minZ)
	T.lt(r.maxOver, 0.01, "rope stretched")
	T.truthy(r.minZ < 1500 - 1000 * 0.99, "the swing should reach the bottom of the arc")
end)

T.test("rope length bounded when the engine adds its own acceleration (air control noise)", function()
	local r = swing({ L = 1000, angle = 50, seconds = 20, noise = 1500, v = { 0, 300, 0 } })
	T.note("noise 1500 u/s^2: max over-length %.3f units", r.maxOver)
	T.lt(r.maxOver, 1.0)
end)

T.test("energy is conserved by the rope (planar pendulum)", function()
	local g, L = 600, 1000
	local r = swing({ g = g, L = L, angle = 60, seconds = 20 })
	local range = g * L * (1 - cos(rad(60)))
	local drift = max(abs(r.Emax - r.E0), abs(r.Emin - r.E0)) / range
	T.note("energy drift over ~2.5 periods: %.4f%% of the swing's potential-energy range", drift * 100)
	T.lt(drift, 0.01, "energy not conserved")
end)

T.test("energy is conserved at a steep, fast swing too (dt 1/33)", function()
	local g, L = 960, 1500
	local r = swing({ g = g, L = L, angle = 80, seconds = 30, dt = 1 / 33, v = { 0, 200, 0 } })
	local range = g * L
	local drift = max(abs(r.Emax - r.E0), abs(r.Emin - r.E0)) / range
	T.note("dt 1/33, L 1500, g 960: drift %.4f%% of g*L", drift * 100)
	T.lt(drift, 0.02)
end)

T.test("angular momentum about the vertical axis is conserved (conical swing)", function()
	local g, L = 600, 1000
	-- tangential horizontal speed for a roughly circular conical orbit at 45 degrees
	local ang = rad(45)
	local v0 = sqrt(g * L * sin(ang) * sin(ang) / cos(ang))
	local r = swing({ g = g, L = L, angle = 45, seconds = 20, v = { 0, v0, 0 } })
	local spread = max(abs(r.Lzmax - r.Lz0), abs(r.Lzmin - r.Lz0)) / abs(r.Lz0)
	T.note("v0=%.0f u/s, Lz drift %.4f%%, rope over-length %.2g", v0, spread * 100, r.maxOver)
	T.lt(spread, 0.01, "angular momentum not conserved")
	T.lt(r.maxOver, 0.01)
end)

T.test("a slack rope does nothing", function()
	local vx, vy, vz, corr = M.constrain(0, 0, 0, 100, 50, -20, 0, 0, 500, 1000, 1 / 66, 600)
	T.eq(vx, 100) T.eq(vy, 50) T.eq(vz, -20) T.eq(corr, 0)
end)

T.test("the rope's corrective speed is capped (a snapped-tight rope never launches you)", function()
	-- rope suddenly 500 units too short; the cap must hold
	local dt = 1 / 66
	local vx, vy, vz, corr = M.constrain(0, 0, 0, 0, 0, 0, 0, 0, 1500, 1000, dt, 600, 3000)
	T.le(corr, 3000 + 1e-6)
	T.near(M.len(vx, vy, vz), corr, 1e-6, "all of it points at the anchor")
	T.gt(vz, 0)
	-- uncapped it would be the whole 500 units in one tick
	local _, _, _, corr2 = M.constrain(0, 0, 0, 0, 0, 0, 0, 0, 1500, 1000, dt, 600, nil)
	T.gt(corr2, 3000)
end)

T.test("a taut rope removes outward speed and keeps tangential speed", function()
	-- body level with the anchor, 1000 away along +x, moving straight outward at 800
	local dt = 1 / 66
	local vx, vy, vz = M.constrain(1000, 0, 0, 800, 0, 0, 0, 0, 0, 1000, dt, 0)
	T.near(vx, 0, 1e-6)
	-- moving tangentially: only a second-order change in speed
	local tx, ty, tz = M.constrain(1000, 0, 0, 0, 800, 0, 0, 0, 0, 1000, dt, 0)
	T.near(M.len(tx, ty, tz), 800, 800 * (800 * dt / 1000) ^ 2)
	T.lt(tx, 0, "turned toward the anchor")
end)

T.test("reeling keeps angular momentum (am = 1) and the radial speed", function()
	local nx, ny, nz = 0, 0, -1 -- hanging straight below the anchor
	local vx, vy, vz = M.reelVelocity(500, 0, 0, nx, ny, nz, 1000, 800, 1)
	T.near(vx, 500 * 1000 / 800, 1e-9, "r * v_t is constant")
	local wx, wy, wz = M.reelVelocity(500, 0, -40, nx, ny, nz, 1000, 800, 0.7)
	T.near(wx, 500 * (1000 / 800) ^ 0.7, 1e-9)
	T.near(wz, -40, 1e-9, "radial part untouched")
	-- growing the rope does nothing
	local ax = M.reelVelocity(500, 0, 0, nx, ny, nz, 800, 1000, 0.7)
	T.eq(ax, 500)
end)

T.test("pump adds speed along the arc, fades out at high speed, steer is perpendicular to the rope", function()
	-- hanging below the anchor, moving along +x at 600
	local ax, ay, az = M.pumpAccel(600, 0, 0, 0, 0, -1, 1, 0, 0)
	T.gt(ax, 0) T.near(az, 0, 1e-9)
	T.near(ax, M.P.pump * (0.35 + 0.65 * 1), 1e-6, "full strength straight below the anchor")
	local fx = M.pumpAccel(M.P.pumpHard + 100, 0, 0, 0, 0, -1, 1, 0, 0)
	T.near(fx, 0, 1e-9, "no pump beyond pumpHard")
	local px = M.pumpAccel(M.P.pumpSoft * 0.5, 0, 0, 0, 0, -1, 1, 0, 0)
	local py = M.pumpAccel(M.P.pumpSoft * 1.2, 0, 0, 0, 0, -1, 1, 0, 0)
	T.gt(px, py, "fades with speed")
	-- standing still: pump toward the facing direction (projected on the tangent plane)
	local sx, sy, sz = M.pumpAccel(0, 0, 0, 0, 0, -1, 0, 1, 0)
	T.gt(sy, 0) T.near(sx, 0, 1e-9)
	-- steer
	local nx, ny, nz = M.norm(300, 100, -800)
	local ex, ey, ez = M.steerAccel(nx, ny, nz, 0, -1, 0, 1)
	T.near(M.dot(ex, ey, ez, nx, ny, nz), 0, 1e-6, "perpendicular to the rope")
	T.near(M.len(ex, ey, ez), M.P.steer, 1e-6)
end)

T.test("release boost is monotonic in speed", function()
	local below = cos(rad(45))
	local prev = -1
	for s = 0, 4000, 50 do
		local b = M.releaseBoost(s, below, 0)
		T.le(prev, b + 1e-12, "boost went down as speed went up at " .. s)
		prev = b
	end
	T.gt(M.releaseBoost(2000, below, 0), M.releaseBoost(1000, below, 0))
	T.near(M.releaseBoost(10000, below, 0), M.P.boostMax, 1e-9, "capped")
end)

T.test("release boost follows the swing angle: none at the bottom, peak halfway up, none above the anchor", function()
	local sp = 1500
	T.near(M.releaseBoost(sp, 1, 0), 0, 1e-9, "straight below the anchor")
	T.near(M.releaseBoost(sp, 0, 0), 0, 1e-9, "level with the anchor")
	T.near(M.releaseBoost(sp, -0.5, 0), 0, 1e-9, "above it")
	local best, bestDeg = -1, 0
	for d = 1, 89 do
		local b = M.releaseBoost(sp, cos(rad(d)), 0)
		if b > best then best, bestDeg = b, d end
	end
	T.note("peak boost %.0f u/s at %d degrees from straight down", best, bestDeg)
	T.truthy(bestDeg >= 43 and bestDeg <= 47, "peak near 45 degrees")
	T.near(M.releaseBoost(sp, cos(rad(45)), -M.P.boostMaxFall - 1), 0, 1e-9, "no boost when already plunging")
	local p2 = M.params() p2.boostMult = 2
	T.near(M.releaseBoost(sp, cos(rad(45)), 0, p2), 2 * M.releaseBoost(sp, cos(rad(45)), 0), 1e-9, "ws_boost scales it")
end)

T.test("release velocity: adds the boost upward, speeds up the horizontal part, keeps its direction", function()
	local vx, vy, vz = M.releaseVelocity(600, 800, 100, 200)
	T.near(vz, 300, 1e-9)
	T.near(vx / vy, 600 / 800, 1e-12)
	T.gt(M.len(vx, vy, 0), 1000)
	local zx, zy, zz = M.releaseVelocity(0, 0, 50, 200)
	T.eq(zx, 0) T.eq(zz, 250)
end)

-- candidate anchors for the assist tests
local function scoreOf(h, vel, withSim)
	local P = M.params()
	P.useSim = withSim
	return M.assistScore(0, 0, 0, vel or 0, 0, 0, 1, 0, 0, h[1], h[2], h[3], h[4], h[5], h[6], nil, P)
end

T.test("assist: rejects anchors that are too close, too far or not above the body", function()
	T.eq(scoreOf({ 300, 0, 300 }, 0, false), -math.huge, "too close")
	T.eq(scoreOf({ 4000, 0, 3000 }, 0, false), -math.huge, "out of range")
	T.eq(scoreOf({ 1000, 0, 20 }, 0, false), -math.huge, "level with the body")
	T.eq(scoreOf({ 1000, 0, -300 }, 0, false), -math.huge, "below the body")
	T.finite(scoreOf({ 1000, 0, 700 }, 0, false))
end)

T.test("assist picks the nearer, higher surface (geometry only)", function()
	-- same bearing: A is nearer and higher, B farther and lower
	local A = { 900, 0, 800, -1, 0, 0 }
	local B = { 2200, 0, 450, -1, 0, 0 }
	T.gt(scoreOf(A, 0, false), scoreOf(B, 0, false), "near+high beats far+low")
	-- same distance: higher beats lower
	T.gt(scoreOf({ 1000, 0, 700, -1, 0, 0 }, 0, false), scoreOf({ 1000, 0, 200, -1, 0, 0 }, 0, false), "higher beats lower at the same distance")
	-- same elevation (45 degrees): the one nearer the ideal distance beats the far one
	local s = sqrt(0.5)
	T.gt(scoreOf({ 1500 * s, 0, 1500 * s, -1, 0, 0 }, 0, false), scoreOf({ 2500 * s, 0, 2500 * s, -1, 0, 0 }, 0, false), "nearer beats farther at the same elevation")
	T.gt(scoreOf({ 1100 * s, 0, 1100 * s, -1, 0, 0 }, 0, false), scoreOf({ 2500 * s, 0, 2500 * s, -1, 0, 0 }, 0, false))
end)

T.test("assist picks the nearer, higher surface (with the swing simulation on)", function()
	local A = { 900, 0, 800, -1, 0, 0 }
	local B = { 2200, 0, 450, -1, 0, 0 }
	local sa, sb = scoreOf(A, 0, true), scoreOf(B, 0, true)
	T.note("sim on: A (near/high) %.1f, B (far/low) %.1f", sa, sb)
	T.gt(sa, sb)
end)

T.test("assist: pickBest returns the best candidate's index and ignores rejects", function()
	local C = {
		300, 0, 300, -1, 0, 0,     -- too close
		2200, 0, 450, -1, 0, 0,    -- far and low
		900, 0, 800, -1, 0, 0,     -- near and high
		-800, 0, 700, 1, 0, 0,     -- behind
	}
	local P = M.params() P.useSim = false
	local i, s = M.pickBest(0, 0, 0, 0, 0, 0, 1, 0, 0, C, 4, nil, P)
	T.eq(i, 3) T.finite(s)
	local none, ns = M.pickBest(0, 0, 0, 0, 0, 0, 1, 0, 0, C, 1, nil, P)
	T.eq(none, 0) T.eq(ns, -math.huge)
	T.eq((M.pickBest(0, 0, 0, 0, 0, 0, 1, 0, 0, C, 0, nil, P)), 0)
end)

T.test("assist: aim direction breaks ties; ideal elevation beats straight overhead", function()
	local P = M.params() P.useSim = false
	local ahead = M.assistScore(0, 0, 0, 0, 0, 0, 1, 0, 0, 1000, 0, 900, nil, nil, nil, nil, P)
	local aside = M.assistScore(0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1000, 900, nil, nil, nil, nil, P)
	T.gt(ahead, aside, "ahead of the aim beats to the side")
	local good = M.assistScore(0, 0, 0, 0, 0, 0, 0, 0, 1, 800, 0, 950, nil, nil, nil, nil, P)
	local over = M.assistScore(0, 0, 0, 0, 0, 0, 0, 0, 1, 50, 0, 1400, nil, nil, nil, nil, P)
	T.gt(good, over, "an anchor around 50 degrees up beats one straight overhead")
	-- a surface facing away from us (we would hit its back) is worse
	local facing = M.assistScore(0, 0, 0, 0, 0, 0, 1, 0, 0, 1000, 0, 900, -1, 0, 0, nil, P)
	local away = M.assistScore(0, 0, 0, 0, 0, 0, 1, 0, 0, 1000, 0, 900, 1, 0, 0, nil, P)
	T.gt(facing, away)
end)

T.test("assist: ray fan covers the cone and its directions are unit vectors", function()
	T.eq(#M.ASSIST_AZ, 5) T.eq(#M.ASSIST_EL, 6)
	for i = 1, #M.ASSIST_AZ do
		for j = 1, #M.ASSIST_EL do
			local x, y, z = M.assistDir(i, j, 30, 1)
			T.near(M.len(x, y, z), 1, 1e-12)
			T.gt(z, 0, "every ray points up")
		end
	end
	local cx = M.assistDir(3, 3, 90, 1)
	T.near(cx, 0, 1e-9, "centre ray follows the heading (yaw 90 -> +y)")
	local x1, y1 = M.assistDir(1, 1, 0, 1)
	local x2, y2 = M.assistDir(1, 1, 0, 0.5)
	T.gt(math.abs(M.yawOf(x1, y1)), math.abs(M.yawOf(x2, y2)), "a smaller cone setting narrows the fan")
end)

T.test("assist: base heading bends toward the direction of travel only when moving fast", function()
	T.near(M.assistBaseYaw(0, 100, 100), 0, 1e-9, "slow: the aim")
	local y = M.assistBaseYaw(0, 0, 1800)
	T.gt(y, 20) T.lt(y, 90 * 0.35 + 1e-6)
end)

T.test("simSwing: a good swing outscores a rope hanging straight overhead", function()
	local P = M.params()
	-- standing still; anchor ahead and above vs almost straight above
	local good = M.simSwing(0, 0, 0, 0, 0, 0, 900, 0, 900, 1, 0, nil, P)
	local over = M.simSwing(0, 0, 0, 0, 0, 0, 60, 0, 1300, 1, 0, nil, P)
	T.note("ahead-and-up %.1f vs overhead %.1f", good, over)
	T.gt(good, over)
	T.finite(good)
	-- diving into the floor is penalised
	local lowRope = M.simSwing(0, 0, 0, 0, 0, 0, 900, 0, 900, 1, 0, -50, P)
	T.lt(lowRope, good)
end)

T.test("zip converges to the goal without overshoot (2000 and 3000 units)", function()
	for _, dist0 in ipairs({ 300, 2000, 3000 }) do
		local dt = 1 / 66
		local p = { x = 0, y = 0, z = 0 }
		local goal = { x = dist0 * 0.6, y = dist0 * 0.2, z = dist0 * sqrt(1 - 0.36 - 0.04) }
		local speed, t, prev, arrived = 0, 0, M.dist(0, 0, 0, goal.x, goal.y, goal.z), nil
		while t < 3 do
			local vx, vy, vz, sp, d = M.zipStep(p.x, p.y, p.z, goal.x, goal.y, goal.z, speed, dt)
			if M.zipDone(d, t) then arrived = t break end
			T.le(M.len(vx, vy, vz) * dt, d + 1e-6, "overshoot")
			p.x, p.y, p.z = p.x + vx * dt, p.y + vy * dt, p.z + vz * dt
			speed = sp
			t = t + dt
			local nd = M.dist(p.x, p.y, p.z, goal.x, goal.y, goal.z)
			T.le(nd, prev + 1e-9, "distance must never grow")
			prev = nd
			T.le(speed, M.P.zipSpeed + 1e-9)
		end
		T.truthy(arrived, "never arrived from " .. dist0)
		T.note("%4d units: arrived after %.2f s (limit %.1f s)", dist0, arrived, M.P.zipMaxT)
		T.lt(arrived, M.P.zipMaxT, "needs the maximum zip time")
	end
end)

T.test("zip ramps up from a standstill and honours a moving goal", function()
	local dt = 1 / 66
	local _, _, _, s1 = M.zipStep(0, 0, 0, 0, 0, 2000, 0, dt)
	T.near(s1, M.P.zipStart + M.P.zipAccel * dt, 1e-9)
	T.lt(s1, M.P.zipSpeed)
	-- a goal moving away at 1000 u/s is still caught
	local p, g, speed, t = { 0, 0, 0 }, { 0, 0, 1500 }, 0, 0
	while t < 3 do
		local vx, vy, vz, sp, d = M.zipStep(p[1], p[2], p[3], g[1], g[2], g[3], speed, dt)
		if M.zipDone(d, t) then break end
		p[1], p[2], p[3] = p[1] + vx * dt, p[2] + vy * dt, p[3] + vz * dt
		g[3] = g[3] + 1000 * dt
		speed = sp t = t + dt
	end
	T.lt(t, 3, "caught the moving goal")
end)

T.test("zip exit velocities", function()
	local vx, vy, vz = M.vaultVelocity(1, 0, 0, 1, 2000)
	T.near(vz, M.P.vaultUp, 1e-9)
	T.near(vx, 2000 * 0.18, 1e-9)
	T.near(vy, M.P.vaultFwd, 1e-9)
	local ex, ey, ez = M.exitVelocity(0, 0, 1, 2000)
	T.near(ez, 900 + 3 * U, 1e-6)
end)

T.test("dive: terminal speed holds, steering turns the heading but not the speed", function()
	local P = M.params()
	local dt, g = 1 / 66, 600
	local v = { x = 800, y = 0, z = 0 }
	for i = 1, 66 * 6 do
		local nvx, nvy, nvz = M.diveVelocity(v.x, v.y, v.z, 0, 1, 1, 0, dt, P)
		-- steering rotates the horizontal velocity: its length is unchanged by the turn itself
		T.near(sqrt(nvx ^ 2 + nvy ^ 2), sqrt(v.x ^ 2 + v.y ^ 2), 1e-6)
		v.x, v.y, v.z = nvx, nvy, nvz - g * dt -- (the engine adds normal gravity after our hook)
		T.truthy(v.z >= -P.diveTerminal - g * dt - 1e-6, "never beyond terminal (plus one tick of engine gravity)")
	end
	T.note("after 6 s: vz = %.0f (terminal %.0f), heading %.0f degrees", v.z, -P.diveTerminal, M.yawOf(v.x, v.y))
	T.lt(v.z, -P.diveTerminal * 0.9, "dive should reach near terminal speed")
	T.gt(M.yawOf(v.x, v.y), 60, "heading turned toward the wish direction (+y)")
	-- a turn rate cap: one second of steering moves the heading by at most diveSteer radians
	local x, y = 800, 0
	for i = 1, 66 do x, y = M.diveVelocity(x, y, 0, 0, 1, 1, 0, dt, P) end
	T.le(math.abs(M.yawOf(x, y)), math.deg(P.diveSteer) + 0.5)
end)

T.test("pull-up bends the dive upward along the heading and keeps most of the speed", function()
	local P = M.params()
	local vx, vy, vz = M.pullUpVelocity(300, 400, -2500, 1, 0, P)
	T.gt(vz, 0) T.gt(vx, 0) T.near(vy, 0, 1e-9)
	T.near(M.len(vx, vy, vz), M.len(300, 400, -2500) * P.pullKeep, 1e-6)
end)

T.test("drawing helpers: sag is a parabola, taut ropes do not hang", function()
	T.eq(M.sagOffset(0, 10), 0) T.eq(M.sagOffset(1, 10), 0) T.eq(M.sagOffset(0.5, 10), 10)
	T.eq(M.sagAmount(1000, 1000, 40), 0)
	T.gt(M.sagAmount(500, 1000, 40), 0)
	T.eq(M.sagAmount(500, 0, 40), 0)
end)

T.test("tension in g: the rope's acceleration over gravity", function()
	T.near(M.tensionG(600 * (1 / 66) * 2, 1 / 66, 600), 2, 1e-9)
	T.eq(M.tensionG(10, 0, 600), 0)
end)

T.test("parameter table is independent per call (convars can edit a copy)", function()
	local a, b = M.params(), M.params()
	a.pump = 1
	T.truthy(b.pump ~= 1)
	T.truthy(M.P.pump ~= 1)
end)

T.test("module also runs under a different Lua flavour's math (no atan2 needed)", function()
	-- emulate Lua 5.3+: atan2 gone, atan takes two arguments
	local saved = math.atan2
	local savedAtan = math.atan
	if saved then
		math.atan2 = nil
		math.atan = function(y, x) return saved(y, x or 1) end
		local M2 = dofile(T.root .. "/lua/webswing/sh_swing.lua")
		T.near(M2.yawOf(0, 1), 90, 1e-9)
		math.atan2, math.atan = saved, savedAtan
	end
end)
