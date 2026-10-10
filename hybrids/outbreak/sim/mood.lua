-- mood.lua : thoughts with +/- values that fade, need-derived modifiers, trait modifiers,
-- and mental breaks at low mood (refuse work / binge / wander off).
--
-- Colonist fields owned here:
--   thoughts = { { id, v, t0, dur, ds } ... }   (value v already scaled by traits)
--   mood (0..100 cached), mood_t (minute of last full recompute)
--   mbreak = { kind = "refuse"|"binge"|"wander", level = "minor"|"major"|"extreme", until_t = minute } | nil
--   break_cd = minute before which no new break can start
-- (Design idea from Cataclysm-DDA's morale: entries with a bonus, a duration and a decay_start.)
local U = require("sim.util")
local TUNING = require("data.tuning")
local THOUGHTS = require("data.thoughts")
local traits = require("sim.traits")
local needs = require("sim.needs")

local M = {}
M.defs = THOUGHTS
local MT = TUNING.mood

function M.init(c)
	c.thoughts = c.thoughts or {}
	c.mood = c.mood or MT.base
	c.mood_t = c.mood_t or -1000
	c.break_cd = c.break_cd or 0
	return c
end

-- current fading value of one thought entry
function M.entry_value(e, now)
	local age = now - e.t0
	if age >= e.dur then return 0 end
	if age <= e.ds then return e.v end
	return e.v * (1 - (age - e.ds) / (e.dur - e.ds))
end

-- add a thought. Re-adding refreshes the timer; `stack` > 1 allows several copies.
-- value_mult scales the data value (used for graded situations). Returns true if added/refreshed.
function M.add(c, id, now, value_mult)
	local d = THOUGHTS[id]
	if not d then error("unknown thought: " .. tostring(id), 2) end
	local mult = traits.thought_mul(c, id)
	if mult == 0 then return false end
	local v = d.value * mult * (value_mult or 1)
	local stack = d.stack or 1
	local th = c.thoughts
	local same, oldest, oldest_t = 0, nil, 1e18
	for i = 1, #th do
		if th[i].id == id then
			same = same + 1
			if th[i].t0 < oldest_t then oldest_t = th[i].t0; oldest = i end
		end
	end
	local e = { id = id, v = v, t0 = now, dur = d.dur, ds = d.decay_start or d.dur }
	if same >= stack then
		th[oldest] = e
	else
		th[#th + 1] = e
		if #th > MT.max_thoughts then
			-- drop the weakest (smallest |current value|, oldest first) to stay bounded
			local wi, wv = 1, 1e18
			for i = 1, #th do
				local val = math.abs(M.entry_value(th[i], now))
				if val < wv then wv = val; wi = i end
			end
			table.remove(th, wi)
		end
	end
	return true
end

function M.has(c, id, now)
	local th = c.thoughts
	for i = 1, #th do
		if th[i].id == id and M.entry_value(th[i], now) ~= 0 then return true end
	end
	return false
end

function M.remove(c, id)
	local th, out = c.thoughts, {}
	for i = 1, #th do if th[i].id ~= id then out[#out + 1] = th[i] end end
	c.thoughts = out
end

-- drop expired thoughts
function M.expire(c, now)
	local th = c.thoughts
	local i = 1
	while i <= #th do
		if now - th[i].t0 >= th[i].dur then table.remove(th, i) else i = i + 1 end
	end
end

function M.thoughts_total(c, now)
	local s = 0
	local th = c.thoughts
	for i = 1, #th do s = s + M.entry_value(th[i], now) end
	return s
end

-- contribution of raw needs (hunger, thirst, tiredness, pain, sickness, maiming)
function M.needs_total(c, now)
	local s = 0
	if c.hunger >= MT.hunger_bad then s = s + MT.hunger_bad_pen elseif c.hunger >= MT.hunger_mid then s = s + MT.hunger_mid_pen end
	if c.thirst >= MT.thirst_bad then s = s + MT.thirst_bad_pen elseif c.thirst >= MT.thirst_mid then s = s + MT.thirst_mid_pen end
	if c.fatigue >= MT.fatigue_bad then s = s + MT.fatigue_bad_pen elseif c.fatigue >= MT.fatigue_mid then s = s + MT.fatigue_mid_pen end
	s = s + needs.perceived_pain(c, now) * MT.pain_pen_per_point
	s = s + (MT.infection_pen[c.inf.stage] or 0)
	s = s + c.maimed * MT.maimed_pen
	return s
end

-- full recompute. ctx = { colonists = n } (optional). Result clamped to [0, 100] and cached in c.mood.
function M.compute(c, now, ctx)
	local lvl = MT.base + traits.add(c, "mood_base") + M.thoughts_total(c, now) + M.needs_total(c, now)
	local n = ctx and ctx.colonists or 0
	if n > 6 then lvl = lvl - traits.add(c, "crowd_pen") * (n - 6) end
	if n > 1 then lvl = lvl + traits.add(c, "social_bonus") * U.min(n - 1, 6) end
	lvl = U.clamp(lvl, 0, 100)
	c.mood = lvl
	c.mood_t = now
	return lvl
end

function M.level_name(m)
	if m < MT.break_levels.extreme then return "extreme" end
	if m < MT.break_levels.major then return "major" end
	if m < MT.break_levels.minor then return "minor" end
	return nil
end

-- per-step update. env = { rng, ctx, food_available (bool) }. Returns array of events or nil:
--   { kind = "break_start", break_kind, level }  /  { kind = "break_end", break_kind }
function M.step(c, now, dt, env)
	if c.dead then return nil end
	local ev
	if now - c.mood_t >= MT.eval_interval then
		M.expire(c, now)
		M.compute(c, now, env.ctx)
	end
	-- break in progress?
	local b = c.mbreak
	if b then
		if now >= b.until_t or c.downed then
			c.mbreak = nil
			c.break_cd = now + MT.break_cooldown
			M.add(c, "break_relief", now)
			ev = { { kind = "break_end", break_kind = b.kind } }
		end
		return ev
	end
	if now < c.break_cd or c.downed then return nil end
	local level = M.level_name(c.mood)
	if not level then return nil end
	local p = MT.break_per_hour[level] / 60 * dt
	local rng = env.rng
	if not rng:chance(p) then return nil end
	local kind
	if level == "minor" then
		kind = "refuse"
	elseif level == "major" then
		kind = (env.food_available and rng:chance(0.5)) and "binge" or "refuse"
	else
		local x = rng:float()
		if x < 0.6 then kind = "wander" elseif x < 0.8 and env.food_available then kind = "binge" else kind = "refuse" end
	end
	local mins = rng:int(MT.break_minutes[1], MT.break_minutes[2])
	if level == "extreme" then mins = mins * 1.3 end
	c.mbreak = { kind = kind, level = level, until_t = now + math.floor(mins) }
	return { { kind = "break_start", break_kind = kind, level = level } }
end

return M
