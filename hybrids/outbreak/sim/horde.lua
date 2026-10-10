-- horde.lua : abstract hordes as groups on a coarse cell grid.
--
-- A horde: { id, x, y, cx, cy (cell), size, mix = {walker,runner,brute,screamer}, speed, hx, hy (unit heading),
--            state = "wander" | "seek" | "linger" | "assault", tx, ty, tscore, linger_until, born, last_seen,
--            mat = nil | { t0, count, mix, last_top } }
-- Drift: hordes wander with a persistent heading; noise (gunshots, helicopters, ...) sets a target they head for.
-- Materialize: within R_materialize of an observer a horde becomes real peds (spawn_horde); it only goes
-- abstract again beyond R_dematerialize (hysteresis) and after min_dwell minutes. The number of real peds
-- is capped by TUNING.horde.max_materialized (shared with raiders).
-- (Idea only: Cataclysm-DDA keeps hordes as abstract groups on a coarse map and tiers them by activity.)
local U = require("sim.util")
local TUNING = require("data.tuning")
local combat = require("sim.combat_abstract")
local siege = require("sim.siege")

local M = {}
local H = TUNING.horde
local MAP = TUNING.map
local floor, sqrt = math.floor, math.sqrt

-- 16 compass vectors (precomputed: no trig at runtime)
M.DIRS = {
	{ 1, 0 }, { 0.9238795325112867, 0.3826834323650898 }, { 0.7071067811865476, 0.7071067811865476 }, { 0.3826834323650898, 0.9238795325112867 },
	{ 0, 1 }, { -0.3826834323650898, 0.9238795325112867 }, { -0.7071067811865476, 0.7071067811865476 }, { -0.9238795325112867, 0.3826834323650898 },
	{ -1, 0 }, { -0.9238795325112867, -0.3826834323650898 }, { -0.7071067811865476, -0.7071067811865476 }, { -0.3826834323650898, -0.9238795325112867 },
	{ 0, -1 }, { 0.3826834323650898, -0.9238795325112867 }, { 0.7071067811865476, -0.7071067811865476 }, { 0.9238795325112867, -0.3826834323650898 },
}
-- rotation constants for heading jitter: cos/sin of 15, 30, 60 degrees
local ROT = { { 0.9659258262890683, 0.25881904510252074 }, { 0.8660254037844387, 0.5 }, { 0.5, 0.8660254037844386 } }

function M.cell_of(x, y)
	return floor((x - MAP.min_x) / MAP.cell), floor((y - MAP.min_y) / MAP.cell)
end

local function mix_speed(mix)
	local n, sp = 0, 0
	for _, t in ipairs(TUNING.combat.order) do
		local c = mix[t] or 0
		if c > 0 and H.speed[t] then n = n + c; sp = sp + c * H.speed[t] end
	end
	if n == 0 then return H.speed.walker end
	return sp / n
end

local function base_pos() return { x = TUNING.base.x, y = TUNING.base.y, z = TUNING.base.z } end

function M.total_size(w)
	local n = 0
	for i = 1, #w.s.hordes do n = n + w.s.hordes[i].size end
	return n
end

function M.find(w, id)
	local hs = w.s.hordes
	for i = 1, #hs do if hs[i].id == id then return hs[i] end end
	return nil
end

function M.set_mix(h, mix)
	h.mix = combat.copy_mix(mix)
	h.size = combat.mix_count(h.mix)
	h.speed = mix_speed(h.mix)
end

-- create a horde. opts = { x, y, mix, target = {x,y}, src, state }
function M.spawn(w, opts)
	local s = w.s
	local rng = w:rng("horde")
	local h = {
		id = w:new_id("h"), x = opts.x, y = opts.y, state = opts.state or "wander", born = s.t, last_seen = s.t,
		tscore = 0, linger_until = 0, src = opts.src or "ambient",
	}
	M.set_mix(h, opts.mix)
	h.x = U.clamp(h.x, MAP.min_x + 5, MAP.max_x - 5)
	h.y = U.clamp(h.y, MAP.min_y + 5, MAP.max_y - 5)
	h.cx, h.cy = M.cell_of(h.x, h.y)
	local dv = M.DIRS[rng:int(1, #M.DIRS)]
	h.hx, h.hy = dv[1], dv[2]
	if opts.target then
		h.tx, h.ty = opts.target.x, opts.target.y
		h.tscore = opts.score or 100
		h.state = "seek"
	end
	if h.size <= 0 then return nil end
	s.hordes[#s.hordes + 1] = h
	return h
end

function M.remove(w, h)
	if h.mat then
		w:emit({ type = "despawn_horde", id = h.id, count = h.mat.count, mix = combat.copy_mix(h.mat.mix), reason = "removed" })
		h.mat = nil
	end
	for i = 1, #w.s.hordes do
		if w.s.hordes[i] == h then table.remove(w.s.hordes, i); return end
	end
end

-- ambient population at world creation
function M.seed_ambient(w, n)
	local rng = w:rng("horde")
	local R = TUNING.base
	for _ = 1, n do
		local dv = M.DIRS[rng:int(1, #M.DIRS)]
		local dist = rng:range(1100, 2300)
		local size = rng:int(H.ambient_size[1], H.ambient_size[2])
		local mix = { walker = size }
		if size >= 12 and rng:chance(0.35) then mix.runner = floor(size * 0.12) + 1; mix.walker = size - mix.runner end
		if size >= 25 and rng:chance(0.3) then mix.brute = 1; mix.walker = mix.walker - 1 end
		M.spawn(w, { x = R.x + dv[1] * dist, y = R.y + dv[2] * dist, mix = mix, src = "ambient" })
	end
end

-- turn a point budget into a mix using the configured shares
function M.mix_for_points(points, shares)
	shares = shares or H.wave_shares
	local mix = {}
	for _, t in ipairs(TUNING.combat.order) do
		local sh = shares[t]
		if sh and sh > 0 then
			local n = floor(points * sh / TUNING.combat.types[t].power + 0.5)
			if n > 0 then mix[t] = n end
		end
	end
	if next(mix) == nil and points >= 1 then mix.walker = 1 end
	return mix
end

-- a wave heading for the base from beyond the spawn ring. Returns the horde or nil (world cap).
function M.spawn_wave(w, mix, opts)
	opts = opts or {}
	local rng = w:rng("horde")
	local n = combat.mix_count(mix)
	if n <= 0 then return nil end
	if M.total_size(w) + n > H.max_total then return nil end
	local dv = M.DIRS[rng:int(1, #M.DIRS)]
	local dist = rng:range(H.spawn_dist[1], H.spawn_dist[2])
	local b = TUNING.base
	local jitter = rng:range(-35, 35)
	local h = M.spawn(w, { x = b.x + dv[1] * dist, y = b.y + dv[2] * dist, mix = mix, src = "wave",
		target = { x = b.x + jitter, y = b.y - jitter }, score = 150 })
	return h
end

-- ---------------------------------------------------------------------------------------------
-- noise
-- ---------------------------------------------------------------------------------------------
-- Register a noise at pos. Every non-materialized horde inside loudness*radius_per_loud may take it as a
-- target when it beats their current target's score.
function M.noise(w, pos, loudness, kind)
	local s = w.s
	local log = s.noise
	log[#log + 1] = { t = s.t, x = pos.x, y = pos.y, loud = loudness, kind = kind or "noise" }
	if #log > H.noise_keep then table.remove(log, 1) end
	local radius = loudness * H.noise_radius_per_loud
	local hs = s.hordes
	local hit = 0
	for i = 1, #hs do
		local h = hs[i]
		if not h.mat and h.state ~= "assault" then
			local d = U.dist2(h.x, h.y, pos.x, pos.y)
			if d <= radius then
				local score = loudness * (1 - d / radius) + 1
				if score > (h.tscore or 0) or not h.tx then
					local rng = w:rng("horde")
					h.tx = pos.x + rng:range(-20, 20)
					h.ty = pos.y + rng:range(-20, 20)
					h.tscore = score
					h.state = "seek"
					hit = hit + 1
				end
			end
		end
	end
	return hit
end

-- ---------------------------------------------------------------------------------------------
-- materialization
-- ---------------------------------------------------------------------------------------------
function M.materialized_count(w)
	local n = 0
	local hs = w.s.hordes
	for i = 1, #hs do if hs[i].mat then n = n + hs[i].mat.count end end
	for i = 1, #(w.s.raids or {}) do
		local r = w.s.raids[i]
		if r.mat then n = n + r.mat.count end
	end
	return n
end

function M.cap_room(w)
	local room = H.max_materialized - M.materialized_count(w)
	if room < 0 then room = 0 end
	return room
end

-- pick `count` heads out of mix proportionally (largest remainder; rarer types win ties)
local function take_mix(mix, count)
	local total = combat.mix_count(mix)
	local out = {}
	if count >= total then return combat.copy_mix(mix) end
	local given, rema = 0, {}
	local order = TUNING.combat.order
	for i = 1, #order do
		local t = order[i]
		local n = mix[t] or 0
		if n > 0 then
			local exact = n * count / total
			local k = floor(exact)
			out[t] = k
			given = given + k
			rema[#rema + 1] = { t = t, frac = exact - k, idx = i }
		end
	end
	U.sort(rema, function(a, b)
		if a.frac ~= b.frac then return a.frac > b.frac end
		return a.idx > b.idx
	end)
	local i = 1
	while given < count and i <= #rema do
		local t = rema[i].t
		if out[t] < (mix[t] or 0) then out[t] = out[t] + 1; given = given + 1 end
		i = i + 1
	end
	local clean = {}
	for _, t in ipairs(order) do if (out[t] or 0) > 0 then clean[t] = out[t] end end
	return clean
end

local function spawn_ped_group(w, h, count, top_up)
	local mix = take_mix(h.mix, count)
	if h.mat then
		-- top-up: take from what is not yet real
		local rest = {}
		for _, t in ipairs(TUNING.combat.order) do
			local n = (h.mix[t] or 0) - (h.mat.mix[t] or 0)
			if n > 0 then rest[t] = n end
		end
		mix = take_mix(rest, count)
	end
	local n = combat.mix_count(mix)
	if n <= 0 then return 0 end
	if not h.mat then h.mat = { t0 = w.s.t, count = 0, mix = {}, last_top = w.s.t } end
	for t, k in pairs(mix) do -- order-free (adds)
		h.mat.mix[t] = (h.mat.mix[t] or 0) + k
	end
	h.mat.count = h.mat.count + n
	h.mat.last_top = w.s.t
	w:emit({ type = "spawn_horde", id = h.id, cell = { x = h.cx, y = h.cy }, pos = { x = h.x, y = h.y, z = TUNING.base.z },
		count = n, mix = mix, heading = { x = h.hx, y = h.hy }, top_up = top_up or false })
	return n
end

local function nearest_observer_dist(h, obs)
	local best
	for i = 1, #obs do
		local d = U.dist2(h.x, h.y, obs[i].x, obs[i].y)
		if not best or d < best then best = d end
	end
	return best
end

function M.update_materialization(w)
	local obs = w:observers()
	local s = w.s
	local now = s.t
	local hs = s.hordes
	for i = 1, #hs do
		local h = hs[i]
		local d = (#obs > 0) and nearest_observer_dist(h, obs) or nil
		if not h.mat then
			if d and d <= H.R_materialize and h.size > 0 then
				local room = M.cap_room(w)
				if room > 0 then
					local count = h.size
					if count > H.per_horde_max then count = H.per_horde_max end
					if count > room then count = room end
					spawn_ped_group(w, h, count, false)
				end
			end
		else
			if (not d or d > H.R_dematerialize) and now - h.mat.t0 >= H.min_dwell then
				w:emit({ type = "despawn_horde", id = h.id, count = h.mat.count, mix = combat.copy_mix(h.mat.mix), reason = "far" })
				h.mat = nil
				h.last_seen = now
			elseif d and d <= H.R_dematerialize then
				h.last_seen = now
				-- top up when real peds were killed and more of the horde remains abstract
				local want = h.size
				if want > H.per_horde_max then want = H.per_horde_max end
				if h.mat.count < want and now - h.mat.last_top >= H.top_up_min then
					local room = M.cap_room(w)
					local more = want - h.mat.count
					if more > room then more = room end
					if more > 0 then spawn_ped_group(w, h, more, true) end
				end
			end
		end
	end
end

-- the adapter reports one ped of horde `id` died (zkind = walker|runner|brute|screamer)
function M.on_ped_died(w, id, zkind)
	local h = M.find(w, id)
	if not h then return false end
	zkind = zkind or "walker"
	if (h.mix[zkind] or 0) <= 0 then
		-- unknown kind: take the commonest present
		for _, t in ipairs(TUNING.combat.order) do if (h.mix[t] or 0) > 0 then zkind = t; break end end
	end
	if (h.mix[zkind] or 0) > 0 then
		h.mix[zkind] = h.mix[zkind] - 1
		if h.mix[zkind] <= 0 then h.mix[zkind] = nil end
		h.size = h.size - 1
		if h.mat and (h.mat.mix[zkind] or 0) > 0 then
			h.mat.mix[zkind] = h.mat.mix[zkind] - 1
			if h.mat.mix[zkind] <= 0 then h.mat.mix[zkind] = nil end
			h.mat.count = h.mat.count - 1
		end
		w:stat("zombies_killed", 1)
	end
	if h.size <= 0 then M.remove(w, h) else h.speed = mix_speed(h.mix) end
	return true
end

-- optional adapter report: the real group moved. Keeps the abstract position in sync while materialized.
function M.report(w, id, pos)
	local h = M.find(w, id)
	if not h then return false end
	h.x, h.y = pos.x, pos.y
	h.cx, h.cy = M.cell_of(h.x, h.y)
	return true
end

-- ---------------------------------------------------------------------------------------------
-- movement + assault
-- ---------------------------------------------------------------------------------------------
local function normalize(h)
	local l = sqrt(h.hx * h.hx + h.hy * h.hy)
	if l > 0 then h.hx, h.hy = h.hx / l, h.hy / l else h.hx, h.hy = 1, 0 end
end

local function move(h, dx, dy)
	h.x = h.x + dx
	h.y = h.y + dy
	if h.x < MAP.min_x then h.x = MAP.min_x; h.hx = -h.hx end
	if h.x > MAP.max_x then h.x = MAP.max_x; h.hx = -h.hx end
	if h.y < MAP.min_y then h.y = MAP.min_y; h.hy = -h.hy end
	if h.y > MAP.max_y then h.y = MAP.max_y; h.hy = -h.hy end
	h.cx, h.cy = M.cell_of(h.x, h.y)
end

local function do_assault(w, h)
	local s = w.s
	if s.t - (h.assault_t or -1000) < H.assault_round_min then return end
	h.assault_t = s.t
	local before = h.size
	local res = siege.resolve(w, h.mix, { rounds = H.assault_rounds, source = "horde" })
	M.set_mix(h, res.attackers_left)
	if h.size <= 0 then
		w:emit({ type = "notify", level = "good", text = "A horde was beaten back at the walls." })
		w:on_attack_repelled("horde", before)
		M.remove(w, h)
		return
	end
	if res.outcome == "overrun" then
		h.nodef = (h.nodef or 0) + 1
		if h.nodef >= 3 then -- nothing left to fight: drift away
			h.state = "wander"
			h.nodef = 0
			local rng = w:rng("horde")
			local away = M.DIRS[rng:int(1, #M.DIRS)]
			h.hx, h.hy = away[1], away[2]
			h.tx, h.ty, h.tscore = nil, nil, 0
		end
	else
		h.nodef = 0
	end
end

function M.step(w, dt)
	local s = w.s
	local now = s.t
	local hs = s.hordes
	local rng = w:rng("horde")
	local b = TUNING.base
	local i = 1
	while i <= #hs do
		local h = hs[i]
		local removed = false
		if not h.mat then
			local dbase = U.dist2(h.x, h.y, b.x, b.y)
			if h.state == "assault" or dbase <= H.assault_radius then
				h.state = "assault"
				h.tx, h.ty = nil, nil
				if dbase > H.assault_radius * 1.5 then h.state = "wander" else do_assault(w, h) end
				if h.size <= 0 then removed = true end
			elseif h.tx then
				local dx, dy = h.tx - h.x, h.ty - h.y
				local d = sqrt(dx * dx + dy * dy)
				if d <= H.arrive_radius then
					h.tx, h.ty, h.tscore = nil, nil, 0
					h.state = "linger"
					h.linger_until = now + H.linger_min
				else
					local stp = h.speed * H.seek_mult * dt
					if stp > d then stp = d end
					h.hx, h.hy = dx / d, dy / d
					move(h, h.hx * stp, h.hy * stp)
				end
			elseif h.state == "linger" then
				if now >= h.linger_until then h.state = "wander" end
			else
				-- wander: persistent heading with occasional turns
				if rng:chance(H.turn_chance_per_min * dt) then
					local r = ROT[rng:int(1, 3)]
					local sg = rng:chance(0.5) and 1 or -1
					local cx, sx = r[1], r[2] * sg
					h.hx, h.hy = h.hx * cx - h.hy * sx, h.hx * sx + h.hy * cx
					normalize(h)
				end
				local stp = h.speed * H.wander_mult * dt
				move(h, h.hx * stp, h.hy * stp)
				-- drifting hordes near the alert radius may be drawn toward the (noisy) base
				if U.dist2(h.x, h.y, b.x, b.y) < TUNING.base.alert_radius * 1.6 and rng:chance(H.base_target_chance / 60 * dt) then
					h.tx, h.ty, h.tscore = b.x, b.y, 20
					h.state = "seek"
				end
			end
		end
		if removed then
			M.remove(w, h)
		else
			i = i + 1
		end
	end
	-- merge neighbours / cap the number of groups
	if now % H.merge_every < dt then M.merge(w) end
	-- daily dissipation of hordes nobody has seen for a long time
	if now % 1440 < dt then M.dissipate(w) end
	M.update_materialization(w)
end

function M.merge(w)
	local hs = w.s.hordes
	local i = 1
	while i <= #hs do
		local a = hs[i]
		local merged = false
		if not a.mat then
			local j = i + 1
			while j <= #hs do
				local b = hs[j]
				if not b.mat and a.state ~= "assault" and b.state ~= "assault" and U.dist2(a.x, a.y, b.x, b.y) <= H.merge_dist then
					local mix = combat.copy_mix(a.mix)
					for t, n in pairs(b.mix) do mix[t] = (mix[t] or 0) + n end -- order-free
					M.set_mix(a, mix)
					if b.tx and (not a.tx or (b.tscore or 0) > (a.tscore or 0)) then a.tx, a.ty, a.tscore, a.state = b.tx, b.ty, b.tscore, "seek" end
					table.remove(hs, j)
					merged = true
				else
					j = j + 1
				end
			end
		end
		i = i + 1
	end
	-- too many groups: fold the smallest idle ones into their nearest neighbour
	while #hs > H.max_hordes do
		local si, sn = nil, 1e9
		for k = 1, #hs do if not hs[k].mat and hs[k].size < sn then si, sn = k, hs[k].size end end
		if not si then break end
		table.remove(hs, si)
	end
end

function M.dissipate(w)
	local hs = w.s.hordes
	local now = w.s.t
	local i = 1
	while i <= #hs do
		local h = hs[i]
		local gone = false
		if not h.mat and h.src == "ambient" and now - h.last_seen > H.dissipate_days * 1440 and h.size > H.min_size_to_keep then
			local keep = floor(h.size * (1 - H.dissipate_frac))
			if keep < H.min_size_to_keep then keep = H.min_size_to_keep end
			local f = keep / h.size
			local mix = {}
			for _, t in ipairs(TUNING.combat.order) do
				local n = h.mix[t] or 0
				if n > 0 then mix[t] = floor(n * f + 0.5) end
			end
			if next(mix) == nil then mix.walker = keep end
			M.set_mix(h, mix)
		end
		i = i + 1
	end
end

-- is a sizeable horde close to the base (alert condition)?
function M.threat_near(w)
	local b = TUNING.base
	local hs = w.s.hordes
	for i = 1, #hs do
		local h = hs[i]
		if h.size >= H.alert_min_size and U.dist2(h.x, h.y, b.x, b.y) <= b.alert_radius then return true, h end
	end
	return false
end

return M
