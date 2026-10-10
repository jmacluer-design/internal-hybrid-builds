-- Web Swing: PURE MATH.
--
-- No GMod globals, no Vector/Angle objects: everything takes and returns plain
-- numbers, so the hot paths allocate nothing and the whole file runs under any
-- Lua 5.1+ / LuaJIT (that is how tests/ exercises it). GMod code gets this
-- module with `include("webswing/sh_swing.lua")` and keeps it as WebSwing.Math.
--
-- Units are Source units (1 unit = 1 inch = 0.0254 m), +x forward at yaw 0, +z up,
-- time in seconds. M.UNIT converts metres to units; the constants in M.params()
-- were taken from the browser prototype (games/webcraft.html, 1 block = 1 m) and
-- scaled by it, then retuned for GMod maps.
--
-- The rope is POSITION-BASED: constrain() predicts where the engine is about to
-- put the body this tick and, if that is outside the rope, returns the velocity
-- that lands it on the rope instead (the outward radial part is removed, the
-- tangential part - the momentum of the swing - is kept). Nothing is teleported:
-- the engine's own movement and collision still do the moving.

local M = {}
M.VERSION = 1
M.UNIT = 39.37 -- Source units per metre

local sqrt, abs, sin, cos, acos = math.sqrt, math.abs, math.sin, math.cos, math.acos
local floor, min, max, huge, pi = math.floor, math.min, math.max, math.huge, math.pi
local rad, deg = math.rad, math.deg
-- (Lua 5.3+ folded atan2 into atan; GMod's LuaJIT still has atan2)
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

---------------------------------------------------------------------------
-- Tuning. One flat table; GMod fills a copy of it from the ws_* convars.
---------------------------------------------------------------------------
function M.params()
	local U = M.UNIT
	return {
		g = 600,                 -- gravity the engine applies (sv_gravity * entity gravity)
		gravityScale = 1.6,      -- swing gravity multiplier (extra pull while on a web)
		-- rope
		minRope = 120,           -- shortest rope (reel stops here)
		maxDist = 2800,          -- web range
		autoReelT = 0.35,        -- seconds after attach in which slack is taken up
		maxPull = 9000,          -- cap on the rope's corrective speed (u/s): a snapped-tight rope never launches you
		pump = 17 * U,           -- forward key: acceleration along the arc
		pumpSoft = 40 * U,       -- ...fades out between these two speeds
		pumpHard = 74 * U,
		pumpMinTan = 2.5 * U,    -- below this tangential speed, pump toward where you face
		steer = 13 * U,          -- A/D lateral acceleration
		reel = 15 * U,           -- crouch: rope shortens by this much a second
		reelAM = 0.7,            -- angular momentum kept while reeling (1 = all of it)
		airDrag = 0.03,          -- linear drag per second
		airDragHi = 0.0006,      -- extra drag per (m/s over 40) per second
		maxSpeed = 3400,         -- hard speed clamp (sv_maxvelocity is 3500)
		-- release
		boostMult = 1,           -- ws_boost
		boostK = 0.17,           -- boost = speed * K * sin(2 * angle below the anchor)
		boostMax = 9 * U,
		boostMinBelow = 0.05,    -- no boost when released above the anchor's level
		boostMaxFall = 4 * U,    -- ...or when already falling faster than this
		boostHoldMin = 0.3,      -- a web held for less than this gives no boost (tap-spamming must not ratchet speed up)
		boostHoldFull = 0.7,     -- ...and the full boost from this long
		boostHorizK = 0.012 / U, -- horizontal speed gain per unit of boost
		jumpPop = 7.5 * U,       -- jump while attached
		-- attach-point assist
		assistMinDist = 400,
		assistMinUp = 96,        -- an anchor has to be at least this far above the body
		idealDist = 1500,
		idealElev = 50,          -- degrees from the horizontal that make a good anchor
		elevWidth = 28,
		wDist = 0.008, wAim = 14, wElev = 10, wBack = 8, wSim = 1,
		useSim = true,
		simT = 2.4, simDt = 0.05,
		-- zip
		zipSpeed = 56 * U,
		zipAccel = 170 * U,
		zipStart = 22 * U,
		zipArrive = 90,          -- close enough (body centre to goal)
		zipMaxT = 2.1,
		vaultUp = 300,           -- the hop over a ledge (webcraft: 11 m/s at 28 m/s^2 gravity; GMod's gravity is 600)
		vaultFwd = 220,
		vaultCarry = 0.06,       -- share of the zip speed carried forward over the ledge
		ledgeMax = 16 * U,       -- highest ledge a wall hit may snap up to
		zipRange = 3000,
		-- dive
		diveGrav = 62 * U,
		diveTerminal = 86 * U,
		diveSteer = 1.7,         -- rad/s the heading may turn
		diveMinH = 3 * U,
		diveMinSpeed = 15 * U,
		diveFwdAccel = 26 * U,
		pullPitch = 0.42,        -- rad
		pullKeep = 0.93,
	}
end
M.P = M.params()

---------------------------------------------------------------------------
-- Small scalar helpers
---------------------------------------------------------------------------
function M.clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local clamp = M.clamp
function M.lerp(a, b, t) return a + (b - a) * t end
function M.smoothstep(e0, e1, x)
	if e1 <= e0 then return x >= e1 and 1 or 0 end
	local t = clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end
local smoothstep = M.smoothstep
function M.len(x, y, z) return sqrt(x * x + y * y + z * z) end
function M.dist(ax, ay, az, bx, by, bz)
	local x, y, z = ax - bx, ay - by, az - bz
	return sqrt(x * x + y * y + z * z)
end
function M.dot(ax, ay, az, bx, by, bz) return ax * bx + ay * by + az * bz end
function M.cross(ax, ay, az, bx, by, bz) return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx end
-- unit vector and the length it had (a zero vector gives 0, 0, 0, 0)
function M.norm(x, y, z)
	local l = sqrt(x * x + y * y + z * z)
	if l < 1e-9 then return 0, 0, 0, 0 end
	local k = 1 / l
	return x * k, y * k, z * k, l
end
-- (a - b) wrapped into [-180, 180]
function M.angDiffDeg(a, b)
	local d = (a - b) % 360
	if d > 180 then d = d - 360 end
	return d
end
-- forward vector from GMod-style angles: pitch positive = looking DOWN
function M.forward(pitchDeg, yawDeg)
	local p, y = rad(pitchDeg), rad(yawDeg)
	local cp = cos(p)
	return cp * cos(y), cp * sin(y), -sin(p)
end
-- right vector for a yaw (flat)
function M.right(yawDeg)
	local y = rad(yawDeg)
	return sin(y), -cos(y), 0
end
-- direction from a yaw and an elevation (positive = UP)
function M.dirFromYawElev(yawDeg, elevDeg)
	local y, e = rad(yawDeg), rad(elevDeg)
	local ce = cos(e)
	return ce * cos(y), ce * sin(y), sin(e)
end
function M.yawOf(dx, dy) return deg(atan2(dy, dx)) end
function M.clampSpeed(vx, vy, vz, vmax)
	local s2 = vx * vx + vy * vy + vz * vz
	if s2 <= vmax * vmax or s2 < 1e-9 then return vx, vy, vz end
	local k = vmax / sqrt(s2)
	return vx * k, vy * k, vz * k
end
-- drag as a multiplier on the velocity for this step
function M.dragFactor(speed, dt, P)
	P = P or M.P
	local over = max(0, speed / M.UNIT - 40)
	return clamp(1 - (P.airDrag + P.airDragHi * over) * dt, 0, 1)
end

---------------------------------------------------------------------------
-- The rope
---------------------------------------------------------------------------
-- p: body position, v: its velocity at the start of the tick (before the engine
-- applies gravity), a: anchor, L: rope length, dt: tick, g: the gravity the
-- engine will apply this tick (it takes half before moving), maxPull: cap on
-- the corrective speed.
-- Returns the velocity to hand to the engine (nvx, nvy, nvz), the corrective
-- speed that was added (|dv|; divide by dt for the rope's acceleration) and the
-- predicted distance to the anchor before correcting.
--
-- The correction acts along the CURRENT rope direction (anchor -> body), not the
-- direction of the predicted position. That is what makes it a constraint force
-- that does no work: pulling along the predicted direction instead leans slightly
-- backwards against the motion and bleeds energy (measured: ~1% of the swing's
-- energy per second at 66 Hz, first order in dt; along the current direction the
-- drift is second order, ~0.01% over 20 s).
function M.constrain(px, py, pz, vx, vy, vz, ax, ay, az, L, dt, g, maxPull)
	local rx, ry, rz = px - ax, py - ay, pz - az
	local d0 = sqrt(rx * rx + ry * ry + rz * rz)
	-- where the engine is about to put the body: the offset from the anchor
	local wx, wy, wz = rx + vx * dt, ry + vy * dt, rz + (vz - 0.5 * g * dt) * dt
	local w2 = wx * wx + wy * wy + wz * wz
	if w2 <= L * L then return vx, vy, vz, 0, sqrt(w2) end
	if d0 < 1e-6 then return vx, vy, vz, 0, sqrt(w2) end
	local nx, ny, nz = rx / d0, ry / d0, rz / d0
	local wn = wx * nx + wy * ny + wz * nz
	local wt2 = w2 - wn * wn
	local rest = L * L - wt2
	-- displacement along n that lands the body on the rope (negative = toward the anchor)
	local s = (rest > 0 and sqrt(rest) or 0) - wn
	local cap = (maxPull or huge) * dt
	if -s > cap then s = -cap end
	local k = s / dt
	return vx + nx * k, vy + ny * k, vz + nz * k, -k, sqrt(w2)
end

-- crouch: shorten the rope, keeping (most of) the angular momentum
function M.reelVelocity(vx, vy, vz, nx, ny, nz, Lold, Lnew, am)
	if Lnew >= Lold or Lnew <= 0 then return vx, vy, vz end
	local k = (Lold / Lnew) ^ am
	local vr = vx * nx + vy * ny + vz * nz
	local tx, ty, tz = vx - nx * vr, vy - ny * vr, vz - nz * vr
	return nx * vr + tx * k, ny * vr + ty * k, nz * vr + tz * k
end

-- forward key: acceleration along the arc. n = unit vector anchor -> body,
-- f = where the player faces (unit)
function M.pumpAccel(vx, vy, vz, nx, ny, nz, fx, fy, fz, P)
	P = P or M.P
	local vr = vx * nx + vy * ny + vz * nz
	local tx, ty, tz = vx - nx * vr, vy - ny * vr, vz - nz * vr
	local tl = sqrt(tx * tx + ty * ty + tz * tz)
	local sp = sqrt(vx * vx + vy * vy + vz * vz)
	local ux, uy, uz
	if tl > P.pumpMinTan then
		ux, uy, uz = tx / tl, ty / tl, tz / tl
	else
		local d0 = fx * nx + fy * ny + fz * nz
		ux, uy, uz = fx - nx * d0, fy - ny * d0, fz - nz * d0
		local l = sqrt(ux * ux + uy * uy + uz * uz)
		if l < 1e-6 then return 0, 0, 0 end
		ux, uy, uz = ux / l, uy / l, uz / l
	end
	local below = clamp((-nz - 0.1) / 0.8, 0, 1)
	local scale = 1 - smoothstep(P.pumpSoft, P.pumpHard, sp)
	local a = P.pump * (0.35 + 0.65 * below) * scale
	return ux * a, uy * a, uz * a
end

-- A/D: acceleration sideways, perpendicular to the rope. r = view right (unit).
function M.steerAccel(nx, ny, nz, rx, ry, rz, side, P)
	P = P or M.P
	local dr = rx * nx + ry * ny + rz * nz
	local sx, sy, sz = rx - nx * dr, ry - ny * dr, rz - nz * dr
	local l = sqrt(sx * sx + sy * sy + sz * sz)
	if l < 1e-6 then return 0, 0, 0 end
	local a = P.steer * side / l
	return sx * a, sy * a, sz * a
end

-- the rope's acceleration as a multiple of gravity: the tension bar
function M.tensionG(corr, dt, g)
	if dt <= 0 or g <= 0 then return 0 end
	return corr / dt / g
end

---------------------------------------------------------------------------
-- Release
---------------------------------------------------------------------------
-- below = cosine of the angle between "straight down" and body - anchor
-- (1: hanging straight down, 0: level with the anchor, < 0: above it).
-- boost = speed * K * sin(2 * angle): nothing at the bottom of the swing,
-- most halfway up the arc, and nothing when released above the anchor.
function M.releaseBoost(speed, below, vz, P)
	P = P or M.P
	if below <= P.boostMinBelow or vz < -P.boostMaxFall then return 0 end
	local th = acos(clamp(below, -1, 1))
	return clamp(speed * P.boostK * sin(2 * th), 0, P.boostMax) * P.boostMult
end
-- how much of the boost a web earns by how long it was held (smooth 0 -> 1)
function M.boostHoldScale(held, P)
	P = P or M.P
	return smoothstep(P.boostHoldMin, P.boostHoldFull, held)
end
function M.releaseVelocity(vx, vy, vz, boost, P)
	P = P or M.P
	if boost > 0 and (vx ~= 0 or vy ~= 0) then
		local k = 1 + boost * P.boostHorizK
		vx, vy = vx * k, vy * k
	end
	return vx, vy, vz + boost
end

---------------------------------------------------------------------------
-- Attach-point assist
---------------------------------------------------------------------------
-- Rays are fired at these azimuth offsets (degrees, scaled by the cone setting)
-- from the heading, and these elevations above the horizon.
M.ASSIST_AZ = { -48, -24, 0, 24, 48 }
M.ASSIST_EL = { 6, 20, 34, 48, 62, 76 }

-- Heading for the rays: the aim, drawn toward the direction of travel when
-- moving fast (so a swing keeps going the way you are going).
function M.assistBaseYaw(aimYawDeg, vx, vy, P)
	local hv = sqrt(vx * vx + vy * vy)
	if hv > 8 * M.UNIT then
		local diff = M.angDiffDeg(deg(atan2(vy, vx)), aimYawDeg)
		return aimYawDeg + diff * 0.35 * smoothstep(8 * M.UNIT, 20 * M.UNIT, hv)
	end
	return aimYawDeg
end
function M.assistDir(i, j, baseYawDeg, coneScale)
	return M.dirFromYawElev(baseYawDeg + M.ASSIST_AZ[i] * (coneScale or 1), M.ASSIST_EL[j])
end

-- A short simulated swing from the body's position and velocity around a
-- candidate anchor (no collision: the caller feeds the floor height). Scores the
-- best moment to let go on the way up: speed, progress along the aim, height.
function M.simSwing(px, py, pz, vx, vy, vz, ax, ay, az, aimx, aimy, floorZ, P)
	P = P or M.P
	local U = M.UNIT
	local g = P.g * P.gravityScale
	local dt = P.simDt
	local n = floor(P.simT / dt + 0.5)
	local L = max(P.minRope, M.dist(px, py, pz, ax, ay, az))
	local x0, y0, z0 = px, py, pz
	local minZ = pz
	local relBest = -huge
	local passed = false
	for i = 1, n do
		vz = vz - g * dt
		px, py, pz = px + vx * dt, py + vy * dt, pz + vz * dt
		local dx, dy, dz = px - ax, py - ay, pz - az
		local d = sqrt(dx * dx + dy * dy + dz * dz)
		if d > L then
			local k = L / d
			px, py, pz = ax + dx * k, ay + dy * k, az + dz * k
			local nx, ny, nz = dx / d, dy / d, dz / d
			local vr = vx * nx + vy * ny + vz * nz
			if vr > 0 then vx, vy, vz = vx - nx * vr, vy - ny * vr, vz - nz * vr end
		end
		if pz < minZ then minZ = pz end
		if pz < az - L * 0.55 then passed = true end
		if passed and vz > 1 * U and i * dt > 0.25 then
			local sp = sqrt(vx * vx + vy * vy + vz * vz)
			local prog = (px - x0) * aimx + (py - y0) * aimy
			local rv = 0.55 * min(sp / U, 46) + 0.35 * clamp(prog / U, -20, 70) + 0.25 * clamp((pz - z0) / U, -10, 25)
			if rv > relBest then relBest = rv end
		end
	end
	local sc
	if relBest > -1e8 then
		sc = relBest
	else
		local sp = sqrt(vx * vx + vy * vy + vz * vz)
		local prog = (px - x0) * aimx + (py - y0) * aimy
		sc = 0.5 * min(sp / U, 40) + 0.3 * clamp(prog / U, -30, 60) - 12
	end
	if floorZ then
		local clear = (minZ - floorZ) / U
		if clear < 1.5 then sc = sc - 60 elseif clear < 4 then sc = sc - (4 - clear) * 6 end
	end
	if L < 300 then sc = sc - (300 - L) / U * 1.5 end
	return sc
end

-- Score for one candidate anchor (h) with the surface normal (n, may be nil).
-- p / v: body position and velocity, aim: unit aim vector. Returns -huge for
-- candidates that are out of range, too close or not above the body.
function M.assistScore(px, py, pz, vx, vy, vz, aimx, aimy, aimz, hx, hy, hz, nx, ny, nz, floorZ, P)
	P = P or M.P
	local dx, dy, dz = hx - px, hy - py, hz - pz
	local d = sqrt(dx * dx + dy * dy + dz * dz)
	if d < P.assistMinDist or d > P.maxDist or d < 1e-9 then return -huge end
	if dz < P.assistMinUp then return -huge end
	local k = 1 / d
	local ux, uy, uz = dx * k, dy * k, dz * k
	local elev = deg(atan2(dz, sqrt(dx * dx + dy * dy)))
	local s = -abs(d - P.idealDist) * P.wDist
	s = s + (ux * aimx + uy * aimy + uz * aimz) * P.wAim
	local e = (elev - P.idealElev) / P.elevWidth
	s = s - e * e * P.wElev
	if nx then
		local face = -(ux * nx + uy * ny + uz * nz) -- >0: the surface faces us
		if face < 0 then s = s + face * P.wBack end
	end
	if P.useSim and P.wSim ~= 0 then
		s = s + M.simSwing(px, py, pz, vx, vy, vz, hx, hy, hz, aimx, aimy, floorZ, P) * P.wSim
	end
	return s
end

-- C is a flat array of candidates, 6 numbers each (x, y, z, nx, ny, nz); n of
-- them are in use. Returns the index (1-based) of the best and its score, or
-- 0, -huge when nothing qualifies.
function M.pickBest(px, py, pz, vx, vy, vz, aimx, aimy, aimz, C, n, floorZ, P)
	local best, bi = -huge, 0
	for i = 1, n do
		local o = (i - 1) * 6
		local s = M.assistScore(px, py, pz, vx, vy, vz, aimx, aimy, aimz, C[o + 1], C[o + 2], C[o + 3], C[o + 4], C[o + 5], C[o + 6], floorZ, P)
		if s > best then best, bi = s, i end
	end
	return bi, best
end

-- Zip candidates: prefer what is near the aim and at a sensible distance;
-- a ledge (somewhere to stand) beats a bare wall.
function M.zipScore(dist, angleDeg, isLedge, P)
	P = P or M.P
	if dist < 150 or dist > P.zipRange then return -huge end
	return -angleDeg * 0.6 - abs(dist - 1200) * 0.004 + (isLedge and 12 or 0)
end

---------------------------------------------------------------------------
-- Zip
---------------------------------------------------------------------------
-- One tick toward the goal. speed ramps up (zipAccel) to zipSpeed and never
-- carries the body past the goal within a tick. Returns the velocity to set,
-- the new speed and the distance to the goal before moving.
function M.zipStep(px, py, pz, gx, gy, gz, speed, dt, P)
	P = P or M.P
	local dx, dy, dz = gx - px, gy - py, gz - pz
	local d = sqrt(dx * dx + dy * dy + dz * dz)
	if d < 1e-6 then return 0, 0, 0, speed, 0 end
	speed = min(P.zipSpeed, max(P.zipStart, speed) + P.zipAccel * dt)
	local s = min(speed, d / dt)
	return dx / d * s, dy / d * s, dz / d * s, speed, d
end
function M.zipDone(dist, t, P)
	P = P or M.P
	return dist <= P.zipArrive or t > P.zipMaxT
end
-- Velocity on arriving. ledge: hop up and over it (in = unit inward normal,
-- flat; dir = unit horizontal approach direction); otherwise keep 45% of the
-- zip speed along the (unit 3D) direction of travel plus a little lift.
function M.vaultVelocity(dirx, diry, inx, iny, speed, P)
	P = P or M.P
	return inx * P.vaultFwd + dirx * speed * P.vaultCarry, iny * P.vaultFwd + diry * speed * P.vaultCarry, P.vaultUp
end
function M.exitVelocity(dx, dy, dz, speed)
	return dx * speed * 0.45, dy * speed * 0.45, dz * speed * 0.45 + 3 * M.UNIT
end

---------------------------------------------------------------------------
-- Dive (hold in the air): fall fast, steer, pull up on release
---------------------------------------------------------------------------
-- wish: unit horizontal direction the player wants (or 0, 0); f: unit
-- horizontal facing. Returns the new velocity. Only the EXTRA pull (diveGrav) is
-- added here: the engine (or the test integrator) still applies normal gravity.
function M.diveVelocity(vx, vy, vz, wishx, wishy, fx, fy, dt, P)
	P = P or M.P
	vz = vz - P.diveGrav * dt
	if vz < -P.diveTerminal then vz = -P.diveTerminal end
	local hv = sqrt(vx * vx + vy * vy)
	local tx, ty = wishx, wishy
	if tx * tx + ty * ty < 0.04 then tx, ty = fx, fy end
	if hv > P.diveMinH then
		local ang = M.angDiffDeg(deg(atan2(ty, tx)), deg(atan2(vy, vx)))
		local r = clamp(rad(ang), -P.diveSteer * dt, P.diveSteer * dt)
		local c, s = cos(r), sin(r)
		vx, vy = vx * c - vy * s, vx * s + vy * c -- rotate toward the wish: speed unchanged
	end
	if hv < P.diveMinSpeed then
		vx, vy = vx + fx * P.diveFwdAccel * dt, vy + fy * P.diveFwdAccel * dt
	end
	return vx, vy, vz
end
-- Release of the dive: bend the velocity up along the heading, keeping most of the speed.
function M.pullUpVelocity(vx, vy, vz, dirx, diry, P)
	P = P or M.P
	local sp = sqrt(vx * vx + vy * vy + vz * vz) * P.pullKeep
	local hl = sqrt(dirx * dirx + diry * diry)
	if hl < 1e-6 then return vx, vy, vz end
	local cp, sp2 = cos(P.pullPitch), sin(P.pullPitch)
	return dirx / hl * cp * sp, diry / hl * cp * sp, sp2 * sp
end

---------------------------------------------------------------------------
-- Drawing helpers (kept here so they can be tested)
---------------------------------------------------------------------------
-- parabola: 0 at both ends, `sag` at the middle
function M.sagOffset(t, sag) return 4 * sag * t * (1 - t) end
-- how much the rope hangs: a slack rope sags, a taut one does not
function M.sagAmount(dist, L, maxSag)
	if L <= 0 then return 0 end
	return clamp((L - dist) / L, 0, 1) * maxSag
end

return M
