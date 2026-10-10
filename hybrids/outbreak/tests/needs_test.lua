-- needs / infection state machine / mood / skills / traits / colonist.
local T = ...
package.path = T.root .. "/?.lua;" .. package.path
local U = require("sim.util")
local R = require("sim.rng")
local TUNING = require("data.tuning")
local needs = require("sim.needs")
local mood = require("sim.mood")
local skills = require("sim.skills")
local traits = require("sim.traits")
local colonist = require("sim.colonist")
local items = require("sim.items")
local THOUGHTS = require("data.thoughts")

local N = TUNING.needs
local function fresh(seed, opts)
	local rng = R.new(seed or 1)
	opts = opts or {}
	opts.id = opts.id or "c1"
	opts.traits = opts.traits or {}
	local c = colonist.new(rng, opts)
	return c, rng
end
local function env(rng, act, now) return { now = now or 0, activity = act or "idle", rest_q = 1, rng = rng } end

T.group("needs")

T.test("initial state is full health, sane needs, no infection", function()
	local c = fresh(1)
	T.eq(c.hp, c.hp_max)
	T.truthy(c.hunger >= 0 and c.hunger <= 100)
	T.eq(c.inf.stage, "none")
	T.falsy(c.dead)
	T.falsy(c.downed)
	T.truthy(needs.check(c))
end)

T.test("hunger and thirst grow at the tuned rates; sleeping slows them", function()
	local c, rng = fresh(2)
	c.hunger, c.thirst = 0, 0
	for t = 1, 600 do needs.step(c, 1, env(rng, "idle", t)) end
	T.near(c.hunger, N.hunger_per_min * 600, 0.01)
	T.near(c.thirst, N.thirst_per_min * 600, 0.01)
	local s, rng2 = fresh(2)
	s.hunger, s.thirst = 0, 0
	for t = 1, 600 do needs.step(s, 1, env(rng2, "sleep", t)) end
	T.lt(s.hunger, c.hunger * 0.7, "sleepers get hungry slower")
	T.lt(s.thirst, c.thirst, "sleepers get thirsty slower")
end)

T.test("fatigue builds while awake (work faster) and recovers asleep, bounded 0..100", function()
	local c, rng = fresh(3)
	c.fatigue = 0
	for t = 1, 600 do needs.step(c, 1, env(rng, "work", t)) end
	local worked = c.fatigue
	c.fatigue = 0
	local d, rng2 = fresh(3)
	d.fatigue = 0
	for t = 1, 600 do needs.step(d, 1, env(rng2, "idle", t)) end
	T.gt(worked, d.fatigue, "work tires faster than idling")
	T.le(worked, 100)
	local sleeper, rng3 = fresh(3)
	sleeper.fatigue = 100
	for t = 1, 500 do needs.step(sleeper, 1, env(rng3, "sleep", t)) end
	T.lt(sleeper.fatigue, 5, "about 7 hours of sleep empties the tiredness")
	T.ge(sleeper.fatigue, 0)
end)

T.test("collapse event fires once when fatigue hits 100", function()
	local c, rng = fresh(4)
	c.fatigue = 99.9
	local seen = 0
	for t = 1, 30 do
		local ev = needs.step(c, 1, env(rng, "idle", t))
		if ev then for _, e in ipairs(ev) do if e.kind == "collapse" then seen = seen + 1 end end end
	end
	T.eq(seen, 1)
end)

T.test("starvation and dehydration drain hp only at 100 and name the cause", function()
	local c, rng = fresh(5)
	c.hunger, c.thirst = 99, 0
	needs.step(c, 1, env(rng))
	T.eq(c.hp, c.hp_max, "no damage below 100")
	c.hunger = 100
	local died
	for t = 1, 5000 do
		local ev = needs.step(c, 1, env(rng, "idle", t))
		if ev then for _, e in ipairs(ev) do if e.kind == "died" then died = e end end end
		if c.dead then break end
		c.thirst = 0
	end
	T.truthy(died, "starvation kills eventually")
	T.eq(died.cause, "starved")
	local d, rng2 = fresh(5)
	d.thirst = 100
	for t = 1, 5000 do
		local ev = needs.step(d, 1, env(rng2, "idle", t))
		d.hunger = 0
		if d.dead then break end
	end
	T.eq(d.cause, "dehydrated")
end)

T.test("bleeding: wounds clot, bandage stops the worst, kit stops all, heavy untreated bleeding kills", function()
	local c, rng = fresh(6)
	local info = needs.wound(c, rng, "bullet", 18, "torso")
	T.gt(info.bleed, 0)
	T.gt(needs.bleeding(c), 0)
	needs.wound(c, rng, "cut", 5, "arm")
	T.eq(#c.wounds, 2)
	local before = needs.bleeding(c)
	local closed = needs.treat_bleeding(c, R.new(1), 1)
	T.le(closed, 1)
	T.lt(needs.bleeding(c), before)
	needs.treat_bleeding(c, rng, 2)
	T.eq(needs.bleeding(c), 0, "a kit closes everything")
	-- natural clotting of a small cut
	local d, rng2 = fresh(6)
	needs.wound(d, rng2, "scratch", 2, "arm")
	for t = 1, 3000 do needs.step(d, 1, env(rng2, "idle", t)) end
	T.eq(needs.bleeding(d), 0, "small wounds stop on their own")
	-- a catastrophic untreated bleed
	local e, rng3 = fresh(7)
	e.wounds[1] = { part = "torso", kind = "bullet", bleed = 2.5, age = 0, bite = false }
	local cause
	for t = 1, 400 do
		local ev = needs.step(e, 1, env(rng3, "idle", t))
		e.wounds[1].bleed = 2.5
		if ev then for _, x in ipairs(ev) do if x.kind == "died" then cause = x.cause end end end
		if e.dead then break end
	end
	T.eq(cause, "bled_out")
end)

T.test("downed at low hp with hysteresis, then recovered", function()
	local c, rng = fresh(8)
	c.hp = N.downed_hp - 1
	local ev = needs.step(c, 1, env(rng))
	T.truthy(c.downed)
	T.eq(ev[#ev].kind, "downed")
	c.hp = N.downed_hp + 3
	needs.step(c, 1, env(rng))
	T.truthy(c.downed, "still downed inside the hysteresis band")
	c.hp = N.downed_hp + 20
	local ev2 = needs.step(c, 1, env(rng))
	T.falsy(c.downed)
	T.eq(ev2[#ev2].kind, "recovered")
end)

T.test("natural healing needs food and water and no bleeding; resting heals faster", function()
	local a, rng = fresh(9)
	a.hp = 50
	a.hunger, a.thirst = 10, 10
	for t = 1, 300 do needs.step(a, 1, env(rng, "idle", t)); a.hunger, a.thirst = 10, 10 end
	local idle_gain = a.hp - 50
	local b, rng2 = fresh(9)
	b.hp = 50
	for t = 1, 300 do needs.step(b, 1, env(rng2, "rest", t)); b.hunger, b.thirst = 10, 10 end
	T.gt(b.hp - 50, idle_gain * 2, "resting multiplies regeneration")
	local starving, rng3 = fresh(9)
	starving.hp, starving.hunger = 50, 90
	for t = 1, 100 do needs.step(starving, 1, env(rng3, "idle", t)); starving.hunger = 90 end
	T.near(starving.hp, 50, 0.001, "no regeneration while hungry")
end)

T.test("bounds: hp/hunger/thirst/fatigue/pain stay finite and in range for any dt (fuzz, 6000 steps)", function()
	local rng = R.new(31)
	local c = fresh(10)
	local dts = { 0, 1, 1, 1, 2, 5, 10, 60, 600, 5000 }
	local kinds = { "bite", "scratch", "cut", "bullet", "blunt", "fall", "fire", "explosion" }
	for i = 1, 6000 do
		local dt = dts[rng:int(1, #dts)]
		local act = ({ "idle", "work", "sleep", "rest", "guard" })[rng:int(1, 5)]
		needs.step(c, dt, { now = i * 7, activity = act, rest_q = rng:range(0.3, 1.2), rng = rng })
		if rng:chance(0.1) then needs.wound(c, rng, kinds[rng:int(1, #kinds)], rng:range(0, 40)) end
		if rng:chance(0.05) then needs.eat(c, { hunger = rng:range(0, 60), thirst = rng:range(0, 60) }) end
		if rng:chance(0.02) then needs.treat_bleeding(c, rng, rng:int(1, 2)) end
		if rng:chance(0.02) then needs.treat_infection(c, rng, rng:int(0, 10)) end
		if rng:chance(0.01) then c.hp = c.hp_max; c.dead = false; c.downed = false; c.hunger = 0; c.thirst = 0 end
		local ok, err = needs.check(c)
		if not ok then T.truthy(false, "step " .. i .. ": " .. err) end
	end
	T.truthy(true)
	T.finite(needs.work_speed(c, 0))
	-- hostile inputs are clamped, not propagated
	local d, r2 = fresh(11)
	needs.wound(d, r2, "bite", 0 / 0)
	needs.wound(d, r2, "bite", math.huge)
	needs.eat(d, { hunger = 1e12, thirst = -1e12 })
	local ok, err = needs.check(d)
	T.truthy(ok, err)
end)

T.test("work speed falls with hunger, thirst, fatigue, pain, sickness and maiming and stays bounded", function()
	local c = fresh(12)
	local base = needs.work_speed(c, 0)
	T.near(base, 1, 0.05)
	c.hunger = 100
	T.lt(needs.work_speed(c, 0), base)
	c.hunger = 0
	c.thirst = 100
	T.lt(needs.work_speed(c, 0), base)
	c.thirst = 0
	c.fatigue = 100
	local tired = needs.work_speed(c, 0)
	T.lt(tired, base)
	c.fatigue = 0
	c.pain = 80
	T.lt(needs.work_speed(c, 0), base)
	T.lt(needs.work_speed(c, 0) , needs.work_speed(c, 0) + 1e-9)
	c.pain = 0
	c.inf.stage = "symptomatic"
	T.lt(needs.work_speed(c, 0), 0.8)
	c.inf.stage = "none"
	c.maimed = 2
	T.lt(needs.work_speed(c, 0), base)
	c.maimed = 50
	T.ge(needs.work_speed(c, 0), N.speed_floor)
	T.le(needs.work_speed(c, 0), 1.5)
	-- painkillers reduce perceived pain
	local p = fresh(12)
	p.pain = 60
	local raw = needs.perceived_pain(p, 100)
	needs.take_painkiller(p, 100)
	T.lt(needs.perceived_pain(p, 101), raw)
	T.near(needs.perceived_pain(p, 100 + N.painkiller_minutes + 1), needs.perceived_pain({ pain = p.pain, traits = p.traits, painkill_until = 0 }, 1e9), 1e-9)
end)

T.group("infection")

T.test("timeline: incubating -> symptomatic -> terminal -> death within the configured windows", function()
	local c, rng = fresh(20)
	c.hunger, c.thirst = 0, 0
	T.truthy(needs.infect(c, rng, "arm"))
	T.eq(c.inf.stage, "incubating")
	T.falsy(needs.infect(c, rng, "leg"), "already infected: no-op")
	local inc = TUNING.needs.infection.incubate
	T.truthy(c.inf.t >= inc[1] and c.inf.t <= inc[2], "incubation timer inside its window")
	local stage_at, died_at = {}, nil
	local last = "incubating"
	for t = 1, 6000 do
		c.hunger, c.thirst, c.fatigue = 0, 0, 0
		local ev = needs.step(c, 1, env(rng, "work", t))
		if c.inf.stage ~= last and not c.dead then stage_at[c.inf.stage] = t; last = c.inf.stage end
		if c.dead then died_at = t; break end
		c.hp = c.hp_max -- isolate the timers from the hp drain
	end
	T.truthy(stage_at.symptomatic and stage_at.terminal and died_at, "all stages reached")
	T.truthy(stage_at.symptomatic >= inc[1] - 1 and stage_at.symptomatic <= inc[2] + 1)
	T.lt(stage_at.symptomatic, stage_at.terminal)
	T.lt(stage_at.terminal, died_at)
	T.eq(c.cause, "infection")
	T.truthy(c.turns, "an infection death reanimates")
end)

T.test("symptoms are visible only after incubation (colonist.view hides the silent stage)", function()
	local c, rng = fresh(21)
	needs.infect(c, rng, "arm")
	T.eq(colonist.view(c, 0).infection, "none")
	c.inf.stage = "symptomatic"
	T.eq(colonist.view(c, 0).infection, "symptomatic")
end)

T.test("rest slows the infection clock", function()
	local a, ra = fresh(22)
	local b, rb = fresh(22)
	needs.infect(a, ra, "arm")
	needs.infect(b, rb, "arm")
	T.eq(a.inf.t, b.inf.t)
	for t = 1, 200 do
		a.hunger, a.thirst, b.hunger, b.thirst, a.fatigue, b.fatigue = 0, 0, 0, 0, 0, 0
		needs.step(a, 1, env(ra, "work", t))
		needs.step(b, 1, env(rb, "rest", t))
	end
	T.lt(a.inf.t, b.inf.t, "the resting patient has more time left")
	T.near(a.inf.t - b.inf.t, -200 * (1 - N.infection.rest_slow), 1.0)
end)

T.test("antibiotics: cure chance falls with stage and rises with skill; failure slows the infection", function()
	local function rate(stage, level, trials)
		local cured = 0
		local rng = R.new(500 + level)
		for _ = 1, trials do
			local c = fresh(23)
			needs.infect(c, rng, "arm")
			c.inf.stage = stage
			c.inf.t = 100
			if needs.treat_infection(c, rng, level) then cured = cured + 1 end
		end
		return cured / trials
	end
	local inc, sym, term = rate("incubating", 0, 3000), rate("symptomatic", 0, 3000), rate("terminal", 0, 3000)
	T.near(inc, N.infection.cure.incubating, 0.03)
	T.near(sym, N.infection.cure.symptomatic, 0.04)
	T.near(term, N.infection.cure.terminal, 0.03)
	T.gt(inc, sym)
	T.gt(sym, term)
	T.gt(rate("symptomatic", 8, 3000), sym + 0.1, "medicine skill helps")
	local c, rng = fresh(23)
	needs.infect(c, rng, "arm")
	c.inf.t = 100
	T.eq(needs.cure_chance(fresh(24), 5), 0, "nothing to cure")
	local failed = false
	for _ = 1, 50 do
		local d = fresh(23)
		needs.infect(d, rng, "arm")
		d.inf.t = 100
		d.inf.stage = "terminal"
		if not needs.treat_infection(d, rng, 0) then failed = true; T.near(d.inf.t, 130, 1e-9, "failed course buys time"); break end
	end
	T.truthy(failed)
	local cure = fresh(25)
	needs.infect(cure, rng, "arm")
	needs.cure_infection(cure)
	T.eq(cure.inf.stage, "none")
end)

T.test("amputation-lite: limb + incubating/symptomatic only, costs hp and speed, removes the infection", function()
	local rng = R.new(77)
	local c = fresh(26)
	needs.infect(c, rng, "torso")
	T.falsy(needs.can_amputate(c), "torso infections cannot be amputated")
	T.eq(select(2, needs.amputate(c, rng, 5)), "not_amputable")
	local ok_count, trials = 0, 400
	for _ = 1, trials do
		local d = fresh(27)
		needs.wound(d, rng, "bite", 8, "arm")
		needs.infect(d, rng, "arm")
		d.inf.stage = "incubating"
		local hp0, maimed0 = d.hp, d.maimed
		local ok = needs.amputate(d, rng, 4)
		if ok then
			ok_count = ok_count + 1
			T.eq(d.inf.stage, "none")
			T.eq(d.maimed, maimed0 + 1)
			T.lt(d.hp, hp0)
			T.ge(d.hp, 1)
			for i = 1, #d.wounds do T.ne(d.wounds[i].part, "arm") end
		else
			T.ne(d.inf.stage, "none")
		end
	end
	T.near(ok_count / trials, N.infection.amputate_base + 4 * N.infection.amputate_per_skill, 0.07)
	local t = fresh(28)
	needs.infect(t, rng, "leg")
	t.inf.stage = "terminal"
	T.falsy(needs.can_amputate(t), "too late once terminal")
end)

T.test("sickly/hardy traits scale the infection clock", function()
	local rng = R.new(5)
	local sick = fresh(30, { traits = { "sickly" } })
	local hardy = fresh(30, { traits = { "hardy" } })
	local plain = fresh(30)
	needs.infect(sick, R.new(5), "arm")
	needs.infect(hardy, R.new(5), "arm")
	needs.infect(plain, R.new(5), "arm")
	T.lt(sick.inf.t, plain.inf.t)
	T.gt(hardy.inf.t, plain.inf.t)
	T.lt(sick.hp_max, plain.hp_max)
	T.gt(hardy.hp_max, plain.hp_max)
end)

T.test("a bite can infect; a dead colonist cannot", function()
	local rng = R.new(123)
	local infected = 0
	for _ = 1, 400 do
		local c = fresh(31)
		local info = needs.wound(c, rng, "bite", 8, "leg")
		if info.infected then infected = infected + 1; T.eq(c.inf.stage, "incubating") end
	end
	T.near(infected / 400, N.wounds.bite.infect, 0.07)
	local d = fresh(32)
	d.dead = true
	T.falsy(needs.infect(d, rng, "arm"))
	needs.wound(d, rng, "bite", 50)
	T.eq(#d.wounds, 0, "the dead take no more wounds")
end)

T.group("mood+skills+traits")

T.test("thoughts add, fade linearly after decay_start, expire, and refresh instead of stacking", function()
	local c = fresh(40)
	local d = THOUGHTS.ate_fine_meal
	mood.add(c, "ate_fine_meal", 0)
	T.near(mood.thoughts_total(c, 0), d.value, 1e-9)
	T.near(mood.thoughts_total(c, d.decay_start), d.value, 1e-9, "no fade before decay_start")
	local mid = d.decay_start + (d.dur - d.decay_start) / 2
	T.near(mood.thoughts_total(c, mid), d.value / 2, 1e-9, "half way through the fade")
	T.near(mood.thoughts_total(c, d.dur), 0, 1e-9)
	mood.add(c, "ate_fine_meal", 100)
	T.eq(#c.thoughts, 1, "same thought refreshes (stack 1)")
	T.eq(c.thoughts[1].t0, 100)
	mood.expire(c, 100 + d.dur + 1)
	T.eq(#c.thoughts, 0)
	T.throws(function() mood.add(c, "no_such_thought", 0) end)
end)

T.test("stacking thoughts cap at their stack size", function()
	local c = fresh(41)
	for i = 1, 10 do mood.add(c, "saw_death", i) end
	T.eq(#c.thoughts, THOUGHTS.saw_death.stack)
	T.near(mood.thoughts_total(c, 10), THOUGHTS.saw_death.value * THOUGHTS.saw_death.stack, 1e-9)
	for i = 1, 100 do mood.add(c, ({ "ate_sweet", "saw_death", "bitten", "lights_out", "caravan_trade" })[i % 5 + 1], i) end
	T.le(#c.thoughts, TUNING.mood.max_thoughts)
end)

T.test("trait multipliers scale thoughts (and can cancel them)", function()
	local plain, gut, jumpy = fresh(42), fresh(42, { traits = { "iron_gut" } }), fresh(42, { traits = { "jumpy" } })
	mood.add(plain, "ate_canned", 0)
	mood.add(gut, "ate_canned", 0)
	T.eq(#gut.thoughts, 0, "iron gut ignores tinned food")
	T.lt(mood.thoughts_total(plain, 0), 0)
	mood.add(plain, "horde_near", 0)
	mood.add(jumpy, "horde_near", 0)
	T.near(mood.thoughts_total(jumpy, 0), THOUGHTS.horde_near.value * 2, 1e-9)
end)

T.test("mood is always within 0..100 and reacts to needs and traits", function()
	local c = fresh(43)
	local base = mood.compute(c, 0, { colonists = 4 })
	T.near(base, TUNING.mood.base, 12)
	c.hunger, c.thirst, c.fatigue, c.pain = 100, 100, 100, 100
	T.lt(mood.compute(c, 0, { colonists = 4 }), base - 15)
	for i = 1, 30 do mood.add(c, "friend_died", i) mood.add(c, "saw_death", i) mood.add(c, "bitten", i) end
	local low = mood.compute(c, 100, {})
	T.ge(low, 0)
	local h = fresh(43, { traits = { "optimist" } })
	T.gt(mood.compute(h, 0, {}), mood.compute(fresh(43), 0, {}) + 5)
	local loner = fresh(43, { traits = { "loner" } })
	T.lt(mood.compute(loner, 0, { colonists = 20 }), mood.compute(loner, 0, { colonists = 2 }))
	for _ = 1, 200 do
		local x = fresh(44)
		x.hunger, x.thirst = U.clamp(math.random(), 0, 1) * 100, 50
		local m = mood.compute(x, 0, { colonists = 9 })
		if m < 0 or m > 100 or m ~= m then T.truthy(false, "mood out of range") end
	end
	T.truthy(true)
end)

T.test("mental breaks: only below thresholds, kinds by severity, cooldown, relief afterwards, no breaks while downed", function()
	local rng = R.new(60)
	local c = fresh(45)
	c.mood = 80
	for t = 1, 3000 do
		c.mood_t = t -- keep the cached value
		c.mood = 80
		if mood.step(c, t, 1, { rng = rng, ctx = {}, food_available = true }) then T.truthy(false, "break at high mood") end
	end
	T.truthy(true)
	local kinds, levels = {}, {}
	for trial = 1, 300 do
		local d = fresh(46 + trial)
		local r = R.new(trial)
		local seen
		for t = 1, 6000 do
			d.mood_t = t
			d.mood = 5
			local ev = mood.step(d, t, 1, { rng = r, ctx = {}, food_available = true })
			if ev and ev[1].kind == "break_start" then seen = ev[1]; break end
		end
		T.truthy(seen, "extreme mood must break eventually")
		kinds[seen.break_kind] = true
		levels[seen.level] = true
		T.eq(seen.level, "extreme")
		T.truthy(d.mbreak ~= nil)
	end
	T.truthy(kinds.wander and (kinds.binge or kinds.refuse), "extreme breaks vary")
	-- break ends, grants relief, then cooldown blocks the next one
	local e = fresh(47)
	e.mbreak = { kind = "refuse", level = "minor", until_t = 100 }
	local ev = mood.step(e, 100, 1, { rng = rng, ctx = {}, food_available = false })
	T.eq(ev[1].kind, "break_end")
	T.eq(e.mbreak, nil)
	T.truthy(mood.has(e, "break_relief", 101))
	e.mood, e.mood_t = 3, 101
	T.eq(mood.step(e, 101, 1, { rng = R.new(1), ctx = {}, food_available = false }), nil, "cooldown blocks an immediate relapse")
	local f = fresh(48)
	f.downed = true
	f.mood, f.mood_t = 0, 0
	T.eq(mood.step(f, 0, 1, { rng = R.new(1), ctx = {}, food_available = true }), nil, "downed colonists do not break")
	T.eq(mood.level_name(35), nil)
	T.eq(mood.level_name(25), "minor")
	T.eq(mood.level_name(15), "major")
	T.eq(mood.level_name(5), "extreme")
end)

T.test("skills: level curve, xp thresholds, max level, speed with trait multipliers", function()
	T.eq(skills.xp_for_level(0), 0)
	T.eq(skills.xp_for_level(1), TUNING.skills.xp_unit)
	T.eq(skills.xp_for_level(3), TUNING.skills.xp_unit * 6)
	for L = 1, 10 do T.gt(skills.xp_for_level(L), skills.xp_for_level(L - 1)) end
	T.eq(skills.level_for_xp(0), 0)
	T.eq(skills.level_for_xp(skills.xp_for_level(4)), 4)
	T.eq(skills.level_for_xp(skills.xp_for_level(4) - 1), 3)
	T.eq(skills.level_for_xp(1e9), skills.max_level())
	local c = fresh(50, { skills = { shooting = { l = 0, xp = 0 }, melee = { l = 0, xp = 0 }, construction = { l = 0, xp = 0 },
		medicine = { l = 0, xp = 0 }, scavenging = { l = 0, xp = 0 }, cooking = { l = 0, xp = 0 } } })
	T.eq(skills.add_xp(c, "melee", skills.xp_for_level(2)), 2)
	T.eq(skills.level(c, "melee"), 2)
	T.eq(skills.add_xp(c, "melee", 0), 0)
	T.eq(skills.add_xp(c, "melee", -5), 0)
	skills.add_xp(c, "melee", 1e9)
	T.eq(skills.level(c, "melee"), skills.max_level())
	T.near(skills.speed(c, "melee"), TUNING.skills.speed_base + TUNING.skills.speed_per_level * 10, 1e-9)
	local tink = fresh(50, { traits = { "tinkerer" } })
	T.gt(skills.speed(tink, "construction") / skills.speed(fresh(50), "construction"), 1.1)
	T.eq(#skills.list, 6)
	T.eq(skills.level(c, "no_such_skill"), 0)
end)

T.test("traits: at least six original traits, consistent exclusions, valid rolls", function()
	T.ge(#traits.ids(), 6)
	for _, id in ipairs(traits.ids()) do
		local d = traits.def(id)
		T.truthy(d.name and d.desc, id .. " has text")
		for _, ex in ipairs(d.excludes or {}) do
			T.truthy(traits.defs[ex], id .. " excludes a real trait")
			local back = false
			for _, e2 in ipairs(traits.defs[ex].excludes or {}) do if e2 == id then back = true end end
			T.truthy(back, "exclusions are symmetric: " .. id .. " <-> " .. ex)
		end
	end
	local rng = R.new(8)
	for _ = 1, 400 do
		local n = rng:int(1, 4)
		local list = traits.roll(rng, n)
		T.eq(#list, n)
		T.truthy(traits.compatible(list), "rolled traits must be compatible")
		local seen = {}
		for i = 1, #list do T.falsy(seen[list[i]], "no duplicates"); seen[list[i]] = true end
	end
	T.falsy(traits.compatible({ "optimist", "pessimist" }))
	local pac = fresh(51, { traits = { "pacifist" } })
	T.truthy(traits.blocks(pac, "guard"))
	T.falsy(traits.blocks(pac, "build"))
	T.eq(traits.schedule_pref(fresh(51, { traits = { "night_owl" } })), "night")
	T.eq(traits.schedule_pref(fresh(51)), "day")
	T.throws(function() traits.def("nope") end)
end)

T.group("colonist")

T.test("colonist creation: stats, inventory limits, schedule, priorities", function()
	local c = fresh(60)
	T.truthy(c.name and #c.name > 3)
	T.eq(c.inv.cap, colonist.carry_cap(c))
	T.eq(c.inv.slots, TUNING.colonist.slots)
	T.eq(#c.sched, 24)
	T.truthy(c.sched:find("S"), "has sleep hours")
	T.truthy(c.sched:find("W"), "has work hours")
	for _, w in ipairs(colonist.WORK) do T.truthy(c.prio[w] ~= nil, "priority for " .. w) end
	T.ge(#colonist.WORK, 6)
	T.truthy(colonist.schedule_at(c, 3) == "S" or colonist.schedule_at(c, 3) == "W")
	local night = fresh(60, { traits = { "night_owl" } })
	T.ne(night.sched, c.sched)
	T.eq(night.sched:sub(11, 11), "S", "night owls sleep through the day")
	T.gt(colonist.carry_cap(fresh(60, { traits = { "packrat" }, str = 5 })), colonist.carry_cap(fresh(60, { str = 5 })))
end)

T.test("priorities clamp to 0..4 and blocked work stays at 0", function()
	local c = fresh(61)
	T.eq(colonist.set_priority(c, "haul", 9), 4)
	T.eq(colonist.set_priority(c, "haul", -3), 0)
	T.eq(colonist.set_priority(c, "build", 1.9), 1)
	T.eq(colonist.priority(c, "build"), 1)
	local pac = fresh(61, { traits = { "pacifist" } })
	T.eq(colonist.set_priority(pac, "guard", 1), 0)
	T.eq(pac.prio.guard, 0)
	T.eq(colonist.priority(c, "nonsense"), 0)
	for _, w in ipairs(colonist.WORK) do T.truthy(c.prio[w] >= 0 and c.prio[w] <= 4) end
end)

T.test("combat power: weapons, ammo, skill, injuries", function()
	local c = fresh(62)
	local unarmed = colonist.combat_power(c, 0)
	items.add(c.inv, "baseball_bat", 1)
	T.gt(colonist.combat_power(c, 0), unarmed * 0.99)
	items.add(c.inv, "pistol", 1)
	local nogun = colonist.combat_power(c, 0)
	items.add(c.inv, "ammo_9mm", 30)
	local power, ranged, ammo = colonist.combat_power(c, 0)
	T.truthy(ranged)
	T.eq(ammo, "ammo_9mm")
	T.gt(power, nogun, "a loaded pistol beats the bat")
	T.eq(colonist.best_weapon(c), "pistol")
	c.hunger = 100
	T.lt(colonist.combat_power(c, 0), power, "being starved weakens a fighter")
	c.hunger = 0
	c.downed = true
	T.eq(colonist.combat_power(c, 0), 0)
	c.downed, c.dead = false, true
	T.eq(colonist.combat_power(c, 0), 0)
	T.falsy(colonist.is_available(c))
	local pac = fresh(62, { traits = { "pacifist" } })
	items.add(pac.inv, "pistol", 1)
	items.add(pac.inv, "ammo_9mm", 30)
	T.lt(colonist.combat_power(pac, 0), colonist.combat_power(fresh(62), 0) + 3)
end)

T.test("colonist.view is plain data with no references into the sim", function()
	local c = fresh(63)
	c.ref = { opaque = true }
	local v = colonist.view(c, 0)
	T.eq(v.id, "c1")
	v.pos.x = 12345
	T.ne(c.pos.x, 12345, "view positions are copies")
	T.eq(v.ref, nil, "the adapter's ref is not echoed back")
	for k, val in pairs(v) do -- order-free
		T.ne(type(val), "function", k)
	end
end)
