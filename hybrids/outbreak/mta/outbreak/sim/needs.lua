-- needs.lua : hunger, thirst, fatigue, bleeding, pain and infection for one colonist.
--
-- Colonist fields owned here:
--   hp, hp_max, hunger, thirst, fatigue, pain          (hunger/thirst/fatigue/pain: 0 best .. 100 worst)
--   wounds = { { part, kind, bleed, age, bite } ... }  bleed = hp lost per minute
--   inf    = { stage = "none"|"incubating"|"symptomatic"|"terminal", t = minutes left in stage, part, speed }
--   downed (bool), dead (bool), cause (string), turns (bool: will reanimate), maimed (count)
--   painkill_until (minute), hurt_by (last damage source for death attribution)
--
-- Infection state machine:  none -> incubating (silent) -> symptomatic (fever, slow, hp drain)
--                                -> terminal (heavy drain) -> death (reanimates when `turns`)
-- Cures: antibiotics (chance falls with stage), rest slows progress, amputation of an infected
-- LIMB wound while still incubating/symptomatic ("amputation-lite").
-- Everything is clamped: no NaN, no negatives, no value above its bound, for any dt.
local U = require("sim.util")
local TUNING = require("data.tuning")
local traits = require("sim.traits")

local M = {}
local N = TUNING.needs
local INF = N.infection

local clamp, min, max = U.clamp, U.min, U.max

M.PARTS = { "arm", "leg", "torso", "head" }
M.LIMBS = { arm = true, leg = true }

function M.init(c)
	c.hp_max = c.hp_max or TUNING.colonist.hp_max
	c.hp = c.hp or c.hp_max
	c.hunger = c.hunger or 10
	c.thirst = c.thirst or 10
	c.fatigue = c.fatigue or 10
	c.pain = c.pain or 0
	c.wounds = c.wounds or {}
	c.inf = c.inf or { stage = "none", t = 0, part = "", speed = 1 }
	c.maimed = c.maimed or 0
	c.downed = c.downed or false
	c.dead = c.dead or false
	c.painkill_until = c.painkill_until or 0
	c.hurt_by = c.hurt_by or ""
	return c
end

function M.bleeding(c)
	local b = 0
	local w = c.wounds
	for i = 1, #w do b = b + w[i].bleed end
	return b
end

function M.perceived_pain(c, now)
	local p = c.pain * traits.mul(c, "pain_taken")
	if now and c.painkill_until > now then p = p - N.painkiller_pain end
	return clamp(p, 0, 100)
end

-- multiplier on every work speed (hunger, thirst, tiredness, pain, sickness, maiming, injury)
function M.work_speed(c, now)
	local s = 1
	local sp = N.speed
	if c.hunger > sp.hunger_from then s = s * (1 - (c.hunger - sp.hunger_from) * sp.hunger_k) end
	if c.thirst > sp.thirst_from then s = s * (1 - (c.thirst - sp.thirst_from) * sp.thirst_k) end
	if c.fatigue > sp.fatigue_from then s = s * (1 - (c.fatigue - sp.fatigue_from) * sp.fatigue_k) end
	s = s * (1 - M.perceived_pain(c, now) * sp.pain_k)
	local st = c.inf.stage
	if st == "symptomatic" then s = s * INF.symptom_speed elseif st == "terminal" then s = s * sp.terminal_mult end
	for _ = 1, c.maimed do s = s * INF.maim_speed end
	if c.hp < c.hp_max * sp.hurt_below then s = s * sp.hurt_mult end
	return clamp(s, N.speed_floor, sp.ceiling)
end

local function roll_range(rng, r) return rng:int(r[1], r[2]) end

-- start an infection (no-op if already infected). part = body part of the source wound.
function M.infect(c, rng, part)
	if c.inf.stage ~= "none" or c.dead then return false end
	local mul = traits.mul(c, "infection_progress")
	c.inf = { stage = "incubating", t = roll_range(rng, INF.incubate) / mul, part = part or "torso", speed = mul }
	return true
end

function M.cure_infection(c)
	c.inf = { stage = "none", t = 0, part = "", speed = 1 }
end

-- apply damage of `kind` (bite, scratch, cut, bullet, blunt, fall, fire, explosion).
-- Returns { part, bleed, infected }. Death is resolved in step()/check_vitals().
function M.wound(c, rng, kind, amount, part)
	local info = { part = part, bleed = 0, infected = false }
	if c.dead then return info end
	local def = N.wounds[kind] or N.wounds.blunt
	amount = clamp(amount or 0, 0, 1000)
	part = part or rng:pick(M.PARTS)
	if kind == "bite" and part == "head" and rng:chance(N.head_bite_to_arm) then part = "arm" end
	info.part = part
	local ws = N.wound_scale
	local scale = clamp(amount / ws.per_hp, ws.min, ws.max)
	c.hp = max(0, c.hp - amount)
	if amount > 0 then c.hurt_by = (kind == "bite" or kind == "scratch") and "zombies" or "wounds" end
	c.pain = min(N.pain_cap, c.pain + def.pain * scale)
	if def.bleed_max > 0 and amount > 0 then
		local w = c.wounds
		local b = rng:range(def.bleed_min, def.bleed_max) * scale
		w[#w + 1] = { part = part, kind = kind, bleed = b, age = 0, bite = (kind == "bite") }
		if #w > N.wounds_cap then table.remove(w, 1) end
		info.bleed = b
	end
	if def.infect > 0 and amount > 0 and c.inf.stage == "none" then
		if rng:chance(def.infect) then info.infected = M.infect(c, rng, part) end
	end
	return info
end

-- stop bleeding. power 1 = bandage (stops the worst wound with chance bandage_stop), 2 = kit (all wounds)
-- Returns the number of wounds closed.
function M.treat_bleeding(c, rng, power)
	local w = c.wounds
	local closed = 0
	if power >= 2 then
		for i = 1, #w do if w[i].bleed > 0 then w[i].bleed = 0; closed = closed + 1 end end
		c.pain = max(0, c.pain - 10)
		return closed
	end
	local worst, wi = 0, nil
	for i = 1, #w do if w[i].bleed > worst then worst = w[i].bleed; wi = i end end
	if wi then
		if rng:chance(N.bandage_stop) then w[wi].bleed = 0; closed = 1
		else w[wi].bleed = w[wi].bleed * N.bandage_partial end
	end
	return closed
end

function M.cure_chance(c, skill_level, bonus)
	local base = INF.cure[c.inf.stage] or 0
	if c.inf.stage == "none" then return 0 end
	return clamp(base + INF.cure_per_skill * skill_level + (bonus or 0), 0, INF.cure_cap)
end

-- antibiotics. Returns true when the infection was cured; a failed course still slows it.
function M.treat_infection(c, rng, skill_level, bonus)
	if c.inf.stage == "none" or c.dead then return false end
	if rng:chance(M.cure_chance(c, skill_level, bonus)) then
		M.cure_infection(c)
		return true
	end
	c.inf.t = c.inf.t * INF.fail_extend
	return false
end

function M.can_amputate(c)
	local st = c.inf.stage
	return (st == "incubating" or st == "symptomatic") and M.LIMBS[c.inf.part] == true and not c.dead
end

-- Returns ok (infection removed), message
function M.amputate(c, rng, skill_level, bonus)
	if not M.can_amputate(c) then return false, "not_amputable" end
	local chance = INF.amputate_base + INF.amputate_per_skill * skill_level + (bonus or 0)
	if c.inf.stage == "symptomatic" then chance = chance - INF.amputate_symptomatic_pen end
	chance = clamp(chance, INF.amputate_min, INF.amputate_max)
	local part = c.inf.part
	if rng:chance(chance) then
		M.cure_infection(c)
		c.maimed = c.maimed + 1
		c.hp = max(1, c.hp - INF.amputate_hp_cost)
		c.pain = min(N.pain_cap, c.pain + INF.amputate_pain)
		local keep = {}
		for i = 1, #c.wounds do if c.wounds[i].part ~= part then keep[#keep + 1] = c.wounds[i] end end
		c.wounds = keep
		return true, "ok"
	end
	c.hp = max(1, c.hp - INF.amputate_hp_cost * INF.amputate_fail_hp_mult)
	c.pain = min(N.pain_cap, c.pain + INF.amputate_pain)
	return false, "failed"
end

function M.take_painkiller(c, now)
	c.painkill_until = now + N.painkiller_minutes
	c.pain = max(0, c.pain - 10)
end

function M.eat(c, food)
	if food.hunger then c.hunger = clamp(c.hunger - food.hunger, 0, 100) end
	if food.thirst then c.thirst = clamp(c.thirst - food.thirst, 0, 100) end
end

function M.drink(c, points) c.thirst = clamp(c.thirst - points, 0, 100) end

function M.heal(c, amount) c.hp = clamp(c.hp + amount, 0, c.hp_max) end

-- resolve death / downed. Returns event table or nil.
function M.check_vitals(c)
	if c.dead then return nil end
	if c.hp <= 0 then
		c.hp = 0
		c.dead = true
		local cause = "wounds"
		if c.hurt_by == "bleeding" then cause = "bled_out"
		elseif c.hurt_by == "starving" then cause = "starved"
		elseif c.hurt_by == "dehydration" then cause = "dehydrated"
		elseif c.hurt_by == "infection" then cause = "infection"; c.turns = true
		elseif c.hurt_by == "zombies" then cause = "zombies"; c.turns = (c.inf.stage ~= "none") end
		c.cause = cause
		return { kind = "died", cause = cause, turns = c.turns == true }
	end
	if not c.downed and c.hp <= N.downed_hp then
		c.downed = true
		return { kind = "downed" }
	end
	if c.downed and c.hp > N.downed_hp + N.recover_margin then
		c.downed = false
		return { kind = "recovered" }
	end
	return nil
end

-- Advance every need by dt minutes. env = { now, activity, rest_q, rng }
--   activity: "sleep" | "rest" | "work" | "guard" | "idle"
-- Returns an array of notable transitions (or nil).
function M.step(c, dt, env)
	if c.dead then return nil end
	local ev
	local function push(e) if not ev then ev = {} end; ev[#ev + 1] = e end
	if dt <= 0 then return nil end
	local act = env.activity or "idle"
	local sleeping = (act == "sleep")
	local resting = sleeping or act == "rest"

	-- hunger / thirst
	local ac = N.activity
	local hf = (sleeping and ac.hunger_sleep) or (resting and ac.hunger_rest) or (act == "work" and ac.hunger_work) or 1
	local was_h, was_t = c.hunger, c.thirst
	c.hunger = clamp(c.hunger + N.hunger_per_min * dt * hf * traits.mul(c, "hunger_rate"), 0, 100)
	c.thirst = clamp(c.thirst + N.thirst_per_min * dt * (sleeping and ac.thirst_sleep or 1) * traits.mul(c, "thirst_rate"), 0, 100)
	if c.hunger >= 100 and was_h < 100 then push({ kind = "starving" }) end
	if c.thirst >= 100 and was_t < 100 then push({ kind = "dehydrated" }) end

	-- fatigue
	local was_f = c.fatigue
	if sleeping then
		c.fatigue = clamp(c.fatigue - N.fatigue_sleep_per_min * dt * (env.rest_q or 1), 0, 100)
	elseif resting then
		c.fatigue = clamp(c.fatigue - N.fatigue_sleep_per_min * dt * ac.rest_fatigue_frac, 0, 100)
	else
		local wf = (act == "work") and N.fatigue_work_mult or 1
		c.fatigue = clamp(c.fatigue + N.fatigue_awake_per_min * dt * wf * traits.mul(c, "fatigue_rate"), 0, 100)
		if c.fatigue >= N.collapse_fatigue and was_f < N.collapse_fatigue then push({ kind = "collapse" }) end
	end

	-- wounds: clotting, bleeding
	local bleed = 0
	local w = c.wounds
	local f = 1 - (1 - N.bleed_decay) * dt
	if f < 0 then f = 0 end
	local i = 1
	while i <= #w do
		local wd = w[i]
		wd.age = wd.age + dt
		if wd.bleed > 0 then
			wd.bleed = wd.bleed * f
			if wd.bleed < N.clot_below then wd.bleed = 0 end
			bleed = bleed + wd.bleed
		end
		local keep_src = (c.inf.stage ~= "none" and c.inf.part == wd.part and wd.bite)
		if wd.bleed == 0 and wd.age > N.wound_heal_min and not keep_src then table.remove(w, i) else i = i + 1 end
	end
	local hp_loss = bleed * dt
	local hurt = (bleed > 0) and "bleeding" or nil
	local worst = hp_loss

	-- starvation / dehydration
	if c.hunger >= 100 then
		local l = N.starve_hp_per_min * dt
		hp_loss = hp_loss + l
		if l > worst then worst = l; hurt = "starving" end
	end
	if c.thirst >= 100 then
		local l = N.dehydrate_hp_per_min * dt
		hp_loss = hp_loss + l
		if l > worst then worst = l; hurt = "dehydration" end
	end

	-- infection state machine
	local inf = c.inf
	if inf.stage ~= "none" then
		local spd = resting and INF.rest_slow or 1
		inf.t = inf.t - dt * spd
		if inf.stage == "symptomatic" then
			local l = INF.symptom_hp_per_min * dt
			hp_loss = hp_loss + l
			if l > worst then worst = l; hurt = "infection" end
		elseif inf.stage == "terminal" then
			local l = INF.terminal_hp_per_min * dt
			hp_loss = hp_loss + l
			if l > worst then worst = l; hurt = "infection" end
		end
		-- a single large dt can cross several stages; loop until time is spent
		local guard = 0
		while inf.t <= 0 and inf.stage ~= "none" and guard < 4 do
			guard = guard + 1
			local over = -inf.t
			local rng = env.rng
			if inf.stage == "incubating" then
				inf.stage = "symptomatic"
				inf.t = roll_range(rng, INF.symptomatic) / inf.speed - over
				push({ kind = "infection_symptomatic" })
			elseif inf.stage == "symptomatic" then
				inf.stage = "terminal"
				inf.t = roll_range(rng, INF.terminal) - over
				push({ kind = "infection_terminal" })
			else -- terminal timer ran out: the infection kills
				c.hp = 0
				hurt = "infection"
				inf.t = 0
				break
			end
		end
	end
	if hurt then c.hurt_by = hurt end

	-- healing
	if hp_loss > 0 then
		c.hp = c.hp - hp_loss
	elseif bleed == 0 and c.hunger < 60 and c.thirst < 60 and inf.stage == "none" and c.hp < c.hp_max then
		local r = N.regen_hp_per_min * dt
		if resting then r = r * N.regen_rest_mult end
		c.hp = c.hp + r * (env.heal_mult or 1)
	end
	c.hp = clamp(c.hp, 0, c.hp_max)

	-- pain
	c.pain = clamp(c.pain - N.pain_decay_per_min * dt, 0, 100)

	local v = M.check_vitals(c)
	if v then push(v) end
	return ev
end

function M.summary(c, now)
	return {
		hp = c.hp, hp_max = c.hp_max, hunger = c.hunger, thirst = c.thirst, fatigue = c.fatigue,
		pain = M.perceived_pain(c, now), bleeding = M.bleeding(c), infection = c.inf.stage,
		downed = c.downed, dead = c.dead, maimed = c.maimed,
	}
end

-- bounded-state validator used by tests and the soak. Returns ok, err.
function M.check(c)
	local function bad(x) return type(x) ~= "number" or x ~= x or x == math.huge or x == -math.huge end
	for _, k in ipairs({ "hp", "hp_max", "hunger", "thirst", "fatigue", "pain" }) do
		if bad(c[k]) then return false, k .. " is not finite" end
	end
	if c.hp < 0 or c.hp > c.hp_max + 1e-9 then return false, "hp out of range" end
	for _, k in ipairs({ "hunger", "thirst", "fatigue", "pain" }) do
		if c[k] < 0 or c[k] > 100 then return false, k .. " out of range" end
	end
	for i = 1, #c.wounds do
		if bad(c.wounds[i].bleed) or c.wounds[i].bleed < 0 then return false, "bad bleed" end
	end
	if c.inf.stage ~= "none" and (bad(c.inf.t)) then return false, "bad infection timer" end
	return true
end

return M
