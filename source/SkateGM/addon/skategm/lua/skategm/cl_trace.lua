local S = SkateGM
local L = S.L
local SOURCE_NAMES, Say, cvCreases, cvSteps = L.SOURCE_NAMES, L.Say, L.cvCreases, L.cvSteps

---------------------------------------------------------------------------
-- What the board is on: the nearest collision surface straight below it
---------------------------------------------------------------------------
function S.UnderBoard()
	if not (S.anchor and skategm and skategm.CollisionNear) then return nil end
	local t, tags = skategm.CollisionNear(S.anchor.x, S.anchor.y, S.anchor.z, 120, 2000)
	local best
	for i = 1, #t - 8, 9 do
		local a, b, c = Vector(t[i], t[i + 1], t[i + 2]), Vector(t[i + 3], t[i + 4], t[i + 5]), Vector(t[i + 6], t[i + 7], t[i + 8])
		local n = (b - a):Cross(c - a):GetNormalized()
		local d = (S.anchor - a):Dot(n)
		if n.z > 0.3 and d > -2 and d < 24 then
			local p = S.anchor - n * d -- the board's spot on this triangle's plane: inside it?
			local function inside(u, v) return (v - u):Cross(p - u):Dot(n) >= -0.01 end
			if inside(a, b) and inside(b, c) and inside(c, a) and (not best or d < best.gap) then
				best = { gap = d, slope = math.deg(math.acos(math.Clamp(n.z, -1, 1))), what = SOURCE_NAMES[tags[(i - 1) / 9 + 1] or 0] or "?" }
			end
		end
	end
	return best
end

---------------------------------------------------------------------------
-- skategm_trace [seconds]: record a run (e.g. up a ramp that stops you) tick by
-- tick - speed, climb, height, board pitch, the engine's state and what's
-- under the board - then summarise the sudden speed drops and bails, and save
-- the whole log to garrysmod/data/skategm_trace.txt to send.
---------------------------------------------------------------------------
-- skategm_boost [m/s]: a push forward, for testing ramps without having to find
-- somewhere to build speed ("bind b skategm_boost"). Along the way you're already
-- rolling, or the way the board points if you're nearly stopped.
local cvBoost = CreateClientConVar("skategm_boost_amount", "5", true, false, "How much skategm_boost adds, in m/s", 0.5, 30)
function S.Boost(amount)
	if S.phase ~= "on" or not (skategm and skategm.Push) then return false end
	local p = skategm.Poll()
	local vel = p.vel and Vector(p.vel[1], p.vel[2], 0) or Vector()
	local dir
	if vel:Length() * 0.0254 * (S.loadedScale or 1) > 1.0 then
		dir = vel:GetNormalized()
	elseif S.P and S.P.TRUCK_FRONT and S.P.TRUCK_BACK then
		dir = S.P.TRUCK_FRONT - S.P.TRUCK_BACK
		dir.z = 0
		dir = dir:GetNormalized()
	end
	if not dir or dir:LengthSqr() < 0.5 then return false end
	local units = (amount or cvBoost:GetFloat()) / (0.0254 * (S.loadedScale or 1))
	return skategm.Push(dir.x * units, dir.y * units, 0)
end
concommand.Add("skategm_boost", function(_, _, args)
	if S.phase ~= "on" then Say("switch Skater mode on first", true) return end
	S.Boost(tonumber(args[1]))
end)

concommand.Add("skategm_trace", function(_, _, args)
	if S.phase ~= "on" then Say("switch Skater mode on first, then skategm_trace and skate up the ramp", true) return end
	local secs = math.Clamp(tonumber(args[1]) or 10, 2, 60)
	S.trace = { rows = {}, stop = RealTime() + secs, start = RealTime() }
	Say(string.format("recording %d seconds: skate up the ramp now", secs))
end)

local function BoardPitch(P)
	local tf, tb = P and P.TRUCK_FRONT, P and P.TRUCK_BACK
	if not (tf and tb) then return 0 end
	local d = (tf - tb):GetNormalized()
	return math.deg(math.asin(math.Clamp(d.z, -1, 1)))
end

function S.TraceThink(p, now)
	local tr = S.trace
	if not tr or not p or not p.pos then return end
	if p.tick and p.tick == tr.lastTick then return end
	tr.lastTick = p.tick
	local scale = S.loadedScale or 1
	-- speed from how far the skater actually moved (the engine's velocity output
	-- isn't the skater's during runouts and bails - it read 68 m/s on foot)
	local here = S.anchor or (S.P and S.P.HIPS) or Vector(p.pos[1], p.pos[2], p.pos[3])
	local vel = Vector()
	if tr.lastPos and tr.lastTickSeen and p.tick and p.tick > tr.lastTickSeen then
		vel = (here - tr.lastPos) / ((p.tick - tr.lastTickSeen) / 60)
	end
	tr.lastPos, tr.lastTickSeen = Vector(here.x, here.y, here.z), p.tick
	local row = { t = now - tr.start, speed = vel:Length() * 0.0254 * scale, climb = vel.z * 0.0254 * scale,
		z = S.anchor and S.anchor.z or p.pos[3], pitch = BoardPitch(S.P), state = p.state or "?" }
	if #tr.rows % 3 == 0 then
		local u = S.UnderBoard()
		row.under = u and string.format("%s %.0f deg", u.what, u.slope) or "-"
	end
	tr.rows[#tr.rows + 1] = row
	-- at a sudden drop or a runout / bail, keep the collision around the board
	-- (a few times per run), so what the board hit can be measured exactly
	local before = tr.rows[math.max(1, #tr.rows - 6)]
	local prevState = tr.rows[#tr.rows - 1] and tr.rows[#tr.rows - 1].state
	local hit = before.speed - row.speed > 1.0 and before.speed > 1.5
	local offBoard = prevState and prevState ~= row.state and (row.state == "BipedGround" or row.state == "WipeoutGround")
	tr.captures = tr.captures or {}
	if (hit or offBoard) and #tr.captures < 3 and now > (tr.lastCapture or 0) + 0.5 and S.anchor and skategm.CollisionNear then
		tr.lastCapture = now
		local t, tags = skategm.CollisionNear(S.anchor.x, S.anchor.y, S.anchor.z, 48, 400)
		tr.captures[#tr.captures + 1] = { t = row.t, anchor = Vector(S.anchor.x, S.anchor.y, S.anchor.z), vel = vel:GetNormalized(),
			why = offBoard and (prevState .. " -> " .. row.state) or string.format("speed %.1f -> %.1f m/s", before.speed, row.speed), tris = t, tags = tags }
	end
	if now >= tr.stop then
		S.trace = nil
		S.TraceReport(tr.rows, tr.captures)
	end
end

function S.TraceReport(rows, captures)
	if #rows < 2 then Say("the trace caught nothing", true) return end
	local lines = { string.format("skategm_trace on %s, world scale %.2f, smoothing %s/%s/%s", game.GetMap(), S.loadedScale or 1,
		tostring(S.loadedSmooth), tostring(cvCreases:GetBool()), tostring(cvSteps:GetFloat())),
		"time  speed(m/s) climb(m/s) height pitch(deg) state / under the board" }
	local lastUnder = "-"
	for _, r in ipairs(rows) do
		lastUnder = r.under or lastUnder
		lines[#lines + 1] = string.format("%5.2f %6.2f %6.2f %7.1f %6.1f  %s / %s", r.t, r.speed, r.climb, r.z, r.pitch, r.state, lastUnder)
	end
	-- the summary: sudden drops (a real speed loss, not a gentle slow-down) and bails
	local events = {}
	lastUnder = "-"
	for i = 2, #rows do
		lastUnder = rows[i].under or lastUnder
		local j = math.max(1, i - 6) -- ~0.1 s before
		local drop = rows[j].speed - rows[i].speed
		if drop > 1.0 and rows[j].speed > 1.5 then
			events[#events + 1] = string.format("  %.2f s: speed %.1f -> %.1f m/s in 0.1 s at height %.0f, pitch %.0f deg, on %s (%s)",
				rows[i].t, rows[j].speed, rows[i].speed, rows[i].z, rows[i].pitch, lastUnder, rows[i].state)
		end
		if rows[i].state ~= rows[i - 1].state then
			events[#events + 1] = string.format("  %.2f s: %s -> %s at %.1f m/s, height %.0f, on %s", rows[i].t, rows[i - 1].state, rows[i].state, rows[i].speed, rows[i].z, lastUnder)
		end
	end
	-- merge runs of the same drop into one line each
	local summary, seen = {}, {}
	for _, e in ipairs(events) do
		local k = string.sub(e, 1, 9)
		if not seen[k] then seen[k] = true summary[#summary + 1] = e end
	end
	local peak = 0
	for _, r in ipairs(rows) do peak = math.max(peak, r.speed) end
	local top = rows[1].z
	for _, r in ipairs(rows) do top = math.max(top, r.z) end
	print(string.format("[SkateGM] trace: %d ticks, top speed %.1f m/s, rose %.0f units", #rows, peak, top - rows[1].z))
	print("[SkateGM] sudden speed drops and state changes:")
	for i = 1, math.min(#summary, 25) do print("[SkateGM]" .. summary[i]) end
	if #summary == 0 then print("[SkateGM]   none: only gradual slowing (that's the physics of climbing)") end
	lines[#lines + 1] = "--- summary ---"
	for _, e in ipairs(summary) do lines[#lines + 1] = e end
	for _, c in ipairs(captures or {}) do
		lines[#lines + 1] = string.format("--- collision within 48 units of the board at %.2f s (%s): board at %.1f %.1f %.1f, moving %.2f %.2f %.2f ---",
			c.t, c.why, c.anchor.x, c.anchor.y, c.anchor.z, c.vel.x, c.vel.y, c.vel.z)
		lines[#lines + 1] = "kind | corner 1 | corner 2 | corner 3"
		local t = c.tris
		for i = 1, #t - 8, 9 do
			lines[#lines + 1] = string.format("%s | %.2f %.2f %.2f | %.2f %.2f %.2f | %.2f %.2f %.2f", SOURCE_NAMES[c.tags[(i - 1) / 9 + 1] or 0] or "?",
				t[i], t[i + 1], t[i + 2], t[i + 3], t[i + 4], t[i + 5], t[i + 6], t[i + 7], t[i + 8])
		end
	end
	local ok = pcall(file.Write, "skategm_trace.txt", table.concat(lines, "\n"))
	Say(ok and "trace saved to garrysmod/data/skategm_trace.txt" or "trace done (summary in the console)")
end
