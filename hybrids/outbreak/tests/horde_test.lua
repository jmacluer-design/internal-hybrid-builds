-- hordes: drift, noise attraction, materialize hysteresis (no flapping), cap, assault, merge; abstract combat.
local T = ...
package.path = T.root .. "/?.lua;" .. T.root .. "/tests/?.lua;" .. package.path
local H = require("helpers").init(T.root)
local U = require("sim.util")
local R = require("sim.rng")
local TUNING = require("data.tuning")
local horde = require("sim.horde")
local combat = require("sim.combat_abstract")
local blueprints = require("sim.blueprints")
local items = require("sim.items")
local colonist = require("sim.colonist")

local HT = TUNING.horde

T.group("hordes")

local function world_with_horde(opts)
	opts = opts or {}
	local w = H.world({ seed = opts.seed or 3 })
	local h = horde.spawn(w, { x = opts.x or 1200, y = opts.y or 0, mix = opts.mix or { walker = 20 }, src = "ambient" })
	return w, h
end

local function set_player(w, x, y)
	w:handle({ type = "player_state", pos = { x = x, y = y, z = 0 } })
end

T.test("drift: slow persistent wandering, bounded by the map, heading stays a unit vector", function()
	local w, h = world_with_horde({ x = 1400, y = 300 })
	local x0, y0 = h.x, h.y
	local maxstep = 0
	local px, py = h.x, h.y
	for _ = 1, 600 do
		w:tick(1)
		local d = U.dist2(h.x, h.y, px, py)
		if d > maxstep then maxstep = d end
		px, py = h.x, h.y
		T.near(h.hx * h.hx + h.hy * h.hy, 1, 1e-6, "unit heading")
		local cx, cy = horde.cell_of(h.x, h.y)
		if cx ~= h.cx or cy ~= h.cy then T.truthy(false, "cell index out of sync") end
		if h.x < TUNING.map.min_x or h.x > TUNING.map.max_x or h.y < TUNING.map.min_y or h.y > TUNING.map.max_y then T.truthy(false, "left the map") end
	end
	T.le(maxstep, h.speed * HT.wander_mult + 1e-6, "never faster than the wander speed")
	T.gt(U.dist2(h.x, h.y, x0, y0), 5, "it did move")
	T.eq(h.state, "wander")
	T.eq(w.s.hordes[1], h)
end)

T.test("hordes bounce off the map edge instead of leaving it", function()
	local w = H.world()
	local h = horde.spawn(w, { x = TUNING.map.max_x - 6, y = 0, mix = { walker = 5 } })
	h.hx, h.hy = 1, 0
	for _ = 1, 400 do
		w:tick(1)
		T.le(h.x, TUNING.map.max_x)
	end
	T.lt(h.hx, 0.99, "heading reflected or turned away")
end)

T.test("noise attracts hordes inside loudness x radius, not outside; the loudest wins", function()
	local w = H.world()
	local near = horde.spawn(w, { x = 900, y = 0, mix = { walker = 10 } })
	local far = horde.spawn(w, { x = 2000, y = 0, mix = { walker = 10 } })
	local radius = HT.noise.gunshot * HT.noise_radius_per_loud
	T.gt(2000 - 900, radius)
	local hit = horde.noise(w, { x = 900, y = 200, z = 0 }, HT.noise.gunshot, "gunshot")
	T.eq(hit, 1)
	T.eq(near.state, "seek")
	T.near(near.tx, 900, 21)
	T.near(near.ty, 200, 21)
	T.eq(far.tx, nil, "out of earshot")
	local d0 = U.dist2(near.x, near.y, 900, 200)
	w:tick(3)
	T.lt(U.dist2(near.x, near.y, 900, 200), d0, "moves toward the noise")
	-- a louder noise elsewhere takes over, a quieter one does not
	local score = near.tscore
	horde.noise(w, { x = 900, y = -100, z = 0 }, 20, "melee")
	T.eq(near.tscore, score, "quiet noise does not override")
	T.near(near.ty, 200, 21)
	horde.noise(w, { x = 900, y = -150, z = 0 }, HT.noise.explosion, "explosion")
	T.near(near.ty, -150, 21, "explosion retargets")
	T.gt(near.tscore, score)
	T.le(#w.s.noise, HT.noise_keep)
	for _ = 1, 100 do horde.noise(w, { x = 0, y = 0, z = 0 }, 5, "tick") end
	T.le(#w.s.noise, HT.noise_keep, "noise log is a bounded ring")
	-- adapter-sent noise goes through the same path and is sanitised
	local before = #w.s.noise
	w:handle({ type = "noise", pos = { x = 900, y = 50, z = 0 }, loudness = HT.noise.explosion })
	T.eq(#w.s.noise > 0, true)
	w:handle({ type = "noise", pos = { x = 900, y = 50 }, loudness = 0 / 0 })
	w:handle({ type = "noise", pos = "nowhere", loudness = 50 })
	w:handle({ type = "noise", loudness = 50 })
	local huge = w:handle({ type = "noise", pos = { x = 0, y = 0, z = 0 }, loudness = 1e9 })
	T.eq(w.s.noise[#w.s.noise].loud, 400, "loudness is capped")
end)

T.test("arriving at a noise: linger, then resume wandering", function()
	local w = H.world()
	local h = horde.spawn(w, { x = 250, y = 0, mix = { walker = 10 } })
	horde.noise(w, { x = 150, y = 0, z = 0 }, HT.noise.gunshot, "gunshot")
	local lingered, resumed = false, false
	for _ = 1, 300 do
		w:tick(1)
		if h.state == "linger" then lingered = true end
		if lingered and h.state == "wander" then resumed = true; break end
	end
	T.truthy(lingered, "reached the noise and lingered")
	T.truthy(resumed, "then drifted off again")
	T.eq(h.tx, nil)
end)

T.test("materialize: only within R_materialize of an observer; spawn_horde carries cell, count, mix", function()
	local w, h = world_with_horde({ x = 1000, y = 0, mix = { walker = 12, runner = 4, brute = 1 } })
	h.state = "linger"; h.linger_until = 1e9 -- keep it still
	set_player(w, 1000 + HT.R_dematerialize, 0)
	local evs = w:tick(1)
	T.eq(H.count(evs, "spawn_horde"), 0, "outside R_materialize: stays abstract")
	set_player(w, 1000 + HT.R_materialize + 1, 0)
	T.eq(H.count(w:tick(1), "spawn_horde"), 0, "just outside")
	set_player(w, 1000 + HT.R_materialize - 1, 0)
	local e = H.find(w:tick(1), "spawn_horde")
	T.truthy(e, "inside R_materialize -> peds spawn")
	T.eq(e.id, h.id)
	T.eq(e.count, 17)
	T.eq(e.mix.walker + e.mix.runner + e.mix.brute, 17)
	T.eq(e.mix.brute, 1)
	T.eq(e.cell.x, h.cx)
	T.eq(e.cell.y, h.cy)
	T.near(e.pos.x, h.x, 1e-9)
	T.truthy(h.mat)
	T.eq(h.mat.count, 17)
end)

T.test("hysteresis: no despawn inside the band, despawn only beyond R_dematerialize after min_dwell", function()
	local w, h = world_with_horde({ x = 1000, y = 0 })
	h.state = "linger"; h.linger_until = 1e12
	set_player(w, 1000 + 100, 0)
	local spawned_at = w.s.t
	T.truthy(H.find(w:tick(1), "spawn_horde"))
	-- inside the hysteresis band (between the two radii): must stay real
	set_player(w, 1000 + (HT.R_materialize + HT.R_dematerialize) / 2, 0)
	for _ = 1, 60 do
		T.eq(H.count(w:tick(1), "despawn_horde"), 0)
		T.truthy(h.mat, "still materialized in the band")
	end
	-- beyond R_dematerialize: gone (min dwell long satisfied)
	set_player(w, 1000 + HT.R_dematerialize + 5, 0)
	local evs = w:tick(1)
	local d = H.find(evs, "despawn_horde")
	T.truthy(d, "despawns beyond R_dematerialize")
	T.eq(d.id, h.id)
	T.eq(d.reason, "far")
	T.eq(h.mat, nil)
	T.eq(h.size, 20, "no zombies lost by the round trip")
	-- min dwell: leaving immediately does not despawn before min_dwell minutes
	local w2, h2 = world_with_horde({ x = 1000, y = 0 })
	h2.state = "linger"; h2.linger_until = 1e12
	set_player(w2, 1100, 0)
	w2:tick(1)
	set_player(w2, 5000, 0)
	local gone_at
	for m = 1, 10 do
		if H.count(w2:tick(1), "despawn_horde") > 0 then gone_at = m; break end
	end
	T.truthy(gone_at and gone_at >= HT.min_dwell - 1, "min_dwell respected")
end)

T.test("no flapping: an observer jittering around the boundary causes at most one spawn and one despawn", function()
	local w, h = world_with_horde({ x = 1000, y = 0 })
	h.state = "linger"; h.linger_until = 1e12
	local rng = R.new(404)
	local spawns, despawns = 0, 0
	local mid = (HT.R_materialize + HT.R_dematerialize) / 2
	for step = 1, 800 do
		-- wander randomly inside +-(band/2) of the midpoint: never beyond R_dematerialize, sometimes inside R_materialize
		local dist = mid + rng:range(-(mid - HT.R_materialize + 20), (HT.R_dematerialize - mid - 5))
		set_player(w, 1000 + dist, 0)
		local evs = w:tick(1)
		spawns = spawns + H.count(evs, "spawn_horde")
		despawns = despawns + H.count(evs, "despawn_horde")
	end
	T.le(spawns, 1, "spawned at most once")
	T.eq(despawns, 0, "never beyond R_dematerialize: never despawned")
	-- and jittering across BOTH radii (worst case) is limited by the dwell time
	local w2, h2 = world_with_horde({ x = 1000, y = 0 })
	h2.state = "linger"; h2.linger_until = 1e12
	local s2, d2 = 0, 0
	for step = 1, 600 do
		local dist = (step % 2 == 0) and (HT.R_materialize - 10) or (HT.R_dematerialize + 50)
		set_player(w2, 1000 + dist, 0)
		local evs = w2:tick(1)
		s2 = s2 + H.count(evs, "spawn_horde")
		d2 = d2 + H.count(evs, "despawn_horde")
	end
	T.le(s2, 600 / HT.min_dwell + 1, "transitions are rate-limited by min_dwell")
	T.le(d2, s2)
end)

T.test("cap: materialized peds never exceed max_materialized across hordes and raiders", function()
	local w = H.world({ seed = 8 })
	for i = 1, 8 do
		local h = horde.spawn(w, { x = 1000 + i * 12, y = (i % 3) * 20, mix = { walker = 25, runner = 5 } })
		h.state = "linger"; h.linger_until = 1e12
	end
	set_player(w, 1050, 20)
	local peak = 0
	for _ = 1, 120 do
		w:tick(1)
		local n = horde.materialized_count(w)
		if n > peak then peak = n end
		T.le(n, HT.max_materialized, "cap")
	end
	T.eq(peak, HT.max_materialized, "the cap was actually reached")
	for i = 1, #w.s.hordes do
		local h = w.s.hordes[i]
		if h.mat then
			T.le(h.mat.count, HT.per_horde_max)
			local sum = 0
			for _, v in pairs(h.mat.mix) do sum = sum + v end -- order-free
			T.eq(sum, h.mat.count, "materialized mix adds up")
			T.le(h.mat.count, h.size)
		end
	end
	-- killing peds frees room: the remaining hordes get topped up, never past the cap
	local killed = 0
	for round = 1, 200 do
		for i = 1, #w.s.hordes do
			local h = w.s.hordes[i]
			if h.mat and h.mat.count > 0 and killed < 120 then
				local z = next(h.mat.mix)
				w:handle({ type = "ped_died", id = h.id, zkind = z, cause = "player" })
				killed = killed + 1
				break
			end
		end
		w:tick(1)
		T.le(horde.materialized_count(w), HT.max_materialized)
	end
	T.gt(killed, 60)
end)

T.test("ped_died accounting: counts and mix shrink, an emptied horde is removed with a despawn", function()
	local w, h = world_with_horde({ x = 1000, y = 0, mix = { walker = 2, runner = 1 } })
	h.state = "linger"; h.linger_until = 1e12
	set_player(w, 1000, 0)
	w:tick(1)
	T.eq(h.mat.count, 3)
	w:handle({ type = "ped_died", id = h.id, zkind = "runner", cause = "player" })
	T.eq(h.size, 2)
	T.eq(h.mix.runner, nil)
	T.eq(h.mat.count, 2)
	w:handle({ type = "ped_died", id = h.id, zkind = "walker", cause = "player" })
	local evs = w:handle({ type = "ped_died", id = h.id, zkind = "walker", cause = "player" })
	T.eq(#w.s.hordes, 0, "horde gone when its last member dies")
	T.truthy(H.find(evs, "despawn_horde"))
	T.eq(w.s.stats.zombies_killed, 3)
	-- unknown kinds fall back to a present kind; unknown horde ids are ignored
	local w2, h2 = world_with_horde({ x = 1000, y = 0, mix = { walker = 3 } })
	w2:handle({ type = "ped_died", id = h2.id, zkind = "brute" })
	T.eq(h2.size, 2)
	w2:handle({ type = "ped_died", id = "h999", zkind = "walker" })
	T.eq(h2.size, 2)
end)

T.test("horde_report keeps the abstract position in sync with the real group", function()
	local w, h = world_with_horde({ x = 1000, y = 0 })
	local evs = w:handle({ type = "horde_report", id = h.id, pos = { x = 1111, y = 222, z = 0 } })
	T.eq(h.x, 1111)
	T.eq(h.y, 222)
	local cx, cy = horde.cell_of(1111, 222)
	T.eq(h.cx, cx)
	T.eq(h.cy, cy)
end)

T.test("a horde reaching the base assaults it; defenders and walls decide; kills, wounds and wall damage are applied", function()
	local w = H.world({ seed = 12 })
	for i = 1, 8 do H.force_build(w, "wall", { x = i * 4 - 18, y = 40, z = 0 }) end
	local guards = {}
	for i = 1, 3 do
		local c = H.colonist(w, { skills = { shooting = 5, melee = 3 } })
		w:create(c.inv, "pistol", 1, "test")
		w:create(c.inv, "ammo_9mm", 60, "test")
		guards[i] = c
		c.drafted = true
	end
	local h = horde.spawn(w, { x = 40, y = 0, mix = { walker = 20 } })
	local hp0 = 0
	for _, c in ipairs(guards) do hp0 = hp0 + c.hp end
	local def0 = select(1, blueprints.defense(w))
	local ammo0 = 180
	local repelled = false
	local notes = {}
	for _ = 1, 120 do
		local evs = w:tick(1)
		for i = 1, #evs do if evs[i].type == "notify" then notes[#notes + 1] = evs[i].text end end
		H.keep_fed(w)
		if #w.s.hordes == 0 then repelled = true; break end
	end
	T.truthy(repelled, "20 walkers lose to three drafted shooters behind eight walls")
	T.gt(w.s.stats.zombies_killed, 19)
	T.gt(w.s.stats.attacks_repelled, 0)
	T.truthy(notes[1] and notes[1]:find("horde"), "the colony was told")
	local ammo_left = 0
	for _, c in ipairs(guards) do ammo_left = ammo_left + items.count(c.inv, "ammo_9mm") end
	T.lt(ammo_left, ammo0, "ammunition was spent (destroyed in the ledger as combat)")
	T.eq(w.s.ledger.reasons["-combat"], ammo0 - ammo_left)
	local def1 = select(1, blueprints.defense(w))
	T.le(def1, def0, "walls only get weaker")
	H.audit_ok(T, w, "after the assault")
end)

T.test("an undefended base is overrun; the horde does not vanish", function()
	local w = H.world({ seed = 13 })
	local h = horde.spawn(w, { x = 40, y = 0, mix = { walker = 15 } })
	for _ = 1, 60 do w:tick(1) end
	T.truthy(w.s.hordes[1], "still there: nobody to fight it")
	T.ge(w.s.hordes[1].size, 15 - 0)
end)

T.test("unarmed, unwalled colonists lose to a big horde; the dead are reported and reanimate when infected", function()
	local w = H.world({ seed = 14 })
	local cs = {}
	for i = 1, 3 do cs[i] = H.colonist(w); w:create(cs[i].inv, "baseball_bat", 1, "test") end
	local h = horde.spawn(w, { x = 40, y = 0, mix = { walker = 120, runner = 20, brute = 4 } })
	local evs = {}
	for _ = 1, 180 do
		local e = w:tick(1)
		for i = 1, #e do evs[#evs + 1] = e[i] end
		H.keep_fed(w)
		if #w.s.colonists == 0 then break end
	end
	T.eq(#w.s.colonists, 0, "wiped out")
	T.gt(H.count(evs, "colonist_died"), 2)
	T.eq(H.count(evs, "game_over"), 1)
	T.truthy(w.s.over)
end)

T.test("merge: neighbouring idle hordes combine; the number of groups stays capped", function()
	local w = H.world()
	local a = horde.spawn(w, { x = 600, y = 600, mix = { walker = 10 } })
	local b = horde.spawn(w, { x = 620, y = 610, mix = { walker = 5, runner = 2 } })
	a.state = "linger"; b.state = "linger"; a.linger_until = 1e12; b.linger_until = 1e12
	horde.merge(w)
	T.eq(#w.s.hordes, 1)
	T.eq(w.s.hordes[1].size, 17)
	T.eq(w.s.hordes[1].mix.runner, 2)
	for i = 1, 60 do
		local h = horde.spawn(w, { x = -2000 + i * 60, y = 1500 - (i % 5) * 300, mix = { walker = 3 + (i % 7) } })
		h.state = "linger"; h.linger_until = 1e12
	end
	horde.merge(w)
	T.le(#w.s.hordes, HT.max_hordes)
end)

T.test("old unseen ambient hordes shrink but never below the minimum; waves do not", function()
	local w = H.world()
	local old = horde.spawn(w, { x = 1500, y = 1500, mix = { walker = 40 }, src = "ambient" })
	local wave = horde.spawn(w, { x = 1500, y = -1500, mix = { walker = 40 }, src = "wave" })
	old.last_seen, wave.last_seen = -100000, -100000
	w.s.t = 20 * 1440
	for _ = 1, 400 do horde.dissipate(w) end
	T.lt(old.size, 40)
	T.ge(old.size, HT.min_size_to_keep)
	T.eq(wave.size, 40)
end)

T.test("wave construction: points become a mix of about that power, spawned beyond the ring heading for the base", function()
	local mix = horde.mix_for_points(60)
	local power = combat.mix_power(mix)
	T.near(power, 60, 8)
	T.truthy(mix.walker and mix.walker > 0)
	T.eq(next(horde.mix_for_points(1.5)), "walker", "tiny budgets still produce something")
	T.eq(next(horde.mix_for_points(0.2)), nil, "less than one point of threat is nothing")
	local w = H.world({ seed = 15 })
	local h = horde.spawn_wave(w, { walker = 30, runner = 6 })
	T.truthy(h)
	local d = U.dist2(h.x, h.y, 0, 0)
	T.ge(d, HT.spawn_dist[1] - 1)
	T.le(d, HT.spawn_dist[2] + 1 + 2 * 5)
	T.eq(h.state, "seek")
	T.near(h.tx, 0, 40)
	local d0 = d
	w:tick(30)
	T.lt(U.dist2(h.x, h.y, 0, 0), d0, "closing in")
	-- the world-wide cap refuses further waves
	local w2 = H.world()
	horde.spawn(w2, { x = 1000, y = 1000, mix = { walker = HT.max_total - 1 } })
	T.eq(horde.spawn_wave(w2, { walker = 50 }), nil)
end)

T.test("threat_near raises the alert; the alert clears after the hold time", function()
	local w = H.world()
	local h = horde.spawn(w, { x = 500, y = 0, mix = { walker = 30 } })
	h.state = "linger"; h.linger_until = 1e12
	local evs = w:tick(1)
	T.eq(w.s.alert, 1)
	T.truthy(H.find(evs, "play_alert", function(e) return e.kind == "horde_near" end))
	h.x = 2000
	w:tick(HT.alert_hold + 5)
	T.eq(w.s.alert, 0)
end)

-- ---------------------------------------------------------------------------------------------
T.group("combat_abstract")

local function def(id, power, extra)
	local d = { id = id, power = power, hp = 100, ready = 1 }
	for k, v in pairs(extra or {}) do d[k] = v end -- order-free
	return d
end

local function avg_outcome(attackers, defenders_fn, extra, trials)
	local killed, hits, dead = 0, 0, 0
	for seed = 1, trials do
		local spec = { attackers = attackers, defenders = defenders_fn(), defense = (extra and extra.defense) or 0,
			barrier_hp = (extra and extra.barrier_hp) or 0, enclosure = (extra and extra.enclosure) or 0, rounds = 6 }
		local r = combat.resolve(R.new(seed), spec)
		killed = killed + combat.mix_count(r.killed)
		hits = hits + #r.hits
		dead = dead + #r.dead
	end
	return killed / trials, hits / trials, dead / trials
end

T.test("deterministic from the rng; results never negative or over the starting counts", function()
	local spec = function() return { attackers = { walker = 30, runner = 5, brute = 1 }, defenders = { def("a", 4), def("b", 3) }, rounds = 6 } end
	local r1 = combat.resolve(R.new(7), spec())
	local r2 = combat.resolve(R.new(7), spec())
	T.eq(require("sim.save").serialize(r1), require("sim.save").serialize(r2))
	for seed = 1, 200 do
		local r = combat.resolve(R.new(seed), spec())
		for _, t in ipairs({ "walker", "runner", "brute" }) do
			local left, killed = r.attackers_left[t] or 0, r.killed[t] or 0
			T.truthy(left >= 0 and killed >= 0 and left + killed == ({ walker = 30, runner = 5, brute = 1 })[t], "head count conserved for " .. t)
		end
		for i = 1, #r.hits do T.truthy(r.hits[i].id == "a" or r.hits[i].id == "b") end
		T.truthy(r.rounds_run >= 1 and r.rounds_run <= 6)
	end
end)

T.test("more / stronger defenders kill more and lose fewer", function()
	local zomb = { walker = 40 }
	local k1, h1 = avg_outcome(zomb, function() return { def("a", 3) } end, nil, 150)
	local k2, h2 = avg_outcome(zomb, function() return { def("a", 3), def("b", 3), def("c", 3) } end, nil, 150)
	T.gt(k2, k1)
	local k3 = avg_outcome(zomb, function() return { def("a", 3, { ready = 0.3 }) } end, nil, 150)
	T.lt(k3, k1, "unready (asleep) defenders kill less")
end)

T.test("walls cut the damage taken and shooters behind walls kill more", function()
	local zomb = { walker = 40 }
	local d = function() return { def("a", 4, { ranged = true, ammo = "ammo_9mm", ammo_have = 100 }), def("b", 4, { ranged = true, ammo = "ammo_9mm", ammo_have = 100 }) } end
	local _, h_open = avg_outcome(zomb, d, nil, 200)
	local k_wall, h_wall = avg_outcome(zomb, d, { defense = 60, barrier_hp = 800, enclosure = 1 }, 200)
	T.lt(h_wall, h_open * 0.75, "walls absorb hits")
	local k_open = avg_outcome(zomb, d, nil, 200)
	T.gt(k_wall, k_open, "enclosed shooters kill more")
end)

T.test("ammo is spent by ranged defenders and runs out; empty guns fight weaker", function()
	local d = { def("a", 5, { ranged = true, ammo = "ammo_9mm", ammo_have = 10 }) }
	local r = combat.resolve(R.new(3), { attackers = { walker = 50 }, defenders = d, rounds = 6 })
	T.le(r.ammo_used.a, 10, "can only fire what it has")
	T.ge(r.ammo_used.a, 8, "fires whole volleys until the magazine is dry")
	local armed = avg_outcome({ walker = 30 }, function() return { def("a", 5, { ranged = true, ammo = "ammo_9mm", ammo_have = 500 }) } end, nil, 100)
	local empty = avg_outcome({ walker = 30 }, function() return { def("a", 5, { ranged = true, ammo = "ammo_9mm", ammo_have = 0 }) } end, nil, 100)
	T.gt(armed, empty * 1.5)
end)

T.test("no defenders: overrun; no attackers: nothing happens; downed defenders can still be hit", function()
	local r = combat.resolve(R.new(1), { attackers = { walker = 10 }, defenders = {}, rounds = 6 })
	T.eq(r.outcome, "overrun")
	T.eq(combat.mix_count(r.killed), 0)
	local r2 = combat.resolve(R.new(1), { attackers = {}, defenders = { def("a", 5) }, rounds = 6 })
	T.eq(r2.outcome, "repelled")
	T.eq(r2.rounds_run, 0)
	local helpless = 0
	for seed = 1, 100 do
		local r3 = combat.resolve(R.new(seed), { attackers = { walker = 60 }, defenders = { def("d", 0, { ready = 0 }) }, rounds = 6 })
		helpless = helpless + #r3.hits
	end
	T.gt(helpless, 100, "zombies still reach a helpless colonist")
end)

T.test("raiders shoot (bullets), zombies bite or scratch; brutes count for a lot of power", function()
	local bullets, bites = 0, 0
	for seed = 1, 100 do
		local r = combat.resolve(R.new(seed), { attackers = { raider = 8 }, defenders = { def("a", 3), def("b", 3) }, rounds = 6 })
		for i = 1, #r.hits do if r.hits[i].kind == "bullet" then bullets = bullets + 1 end end
		local z = combat.resolve(R.new(seed), { attackers = { walker = 30 }, defenders = { def("a", 3), def("b", 3) }, rounds = 6 })
		for i = 1, #z.hits do if z.hits[i].kind == "bite" then bites = bites + 1 end; T.ne(z.hits[i].kind, "bullet") end
	end
	T.gt(bullets, 0)
	T.gt(bites, 0)
	T.eq(combat.mix_power({ brute = 2 }), 12)
	T.gt(combat.type_power("brute"), 5 * combat.type_power("walker"))
	T.eq(combat.mix_count({ walker = 3, runner = 2, bogus = 99 }), 5, "unknown types are ignored")
end)

T.test("screamers left alive are reported (the world turns them into noise)", function()
	local r = combat.resolve(R.new(2), { attackers = { screamer = 6, walker = 4 }, defenders = {}, rounds = 3 })
	T.eq(r.screamers_left, 6)
end)
