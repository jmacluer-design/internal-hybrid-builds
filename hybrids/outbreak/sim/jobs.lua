-- jobs.lua : job generation (the "job board"), priority-ordered assignment, reservations,
-- multi-step execution, and interruption by emergencies.
--
-- Work types (colonist.WORK): doctor, guard, build, cook, craft, haul, scavenge. A colonist's
-- priority 0 means "never", 1 = highest .. 4 = lowest. Needs jobs (eat / drink / sleep / rest)
-- are not on the board; they outrank ordinary work according to their CLASS:
--     1 WORK    board jobs by priority          2 NEED   eat / drink / sleep / rest on thresholds + schedule
--     3 URGENT  starving, collapse, heavy bleeding, mental breaks      4 FORCED  player orders / draft
-- A job of strictly higher class interrupts the current one; equal class never does.
--
-- Reservations: every job has a key ("build:b4", "haul:p2", "bed:b9" ...). A key may be held by
-- at most `cap` colonists at once (1 for nearly everything), so two colonists can never take the
-- same job. The reservation table is derived from colonists' jobs (rebuilt after a load).
--
-- Starvation bound: a board job that has waited `aging_minutes` is treated one priority step
-- higher (down to 1) for every `aging_minutes` it keeps waiting, so a low-priority job is
-- eventually served even under a constant stream of higher-priority work.
--
-- A job is plain data: { key, kind, work, class, target, steps = { {pos, dur, act, data} },
--   i (step index), ph ("go" | "do"), t (minutes left in the phase), res = { keys }, data }
local U = require("sim.util")
local TUNING = require("data.tuning")
local BP = require("data.blueprints")
local RECIPES = require("data.recipes")
local items = require("sim.items")
local needs = require("sim.needs")
local mood = require("sim.mood")
local skills = require("sim.skills")
local traits = require("sim.traits")
local stockpile = require("sim.stockpile")
local blueprints = require("sim.blueprints")
local grid = require("sim.grid")
local clock = require("sim.clock")
local colonist = require("sim.colonist")

local M = {}
local J = TUNING.jobs
local N = TUNING.needs
local CLASS = { WORK = 1, NEED = 2, URGENT = 3, FORCED = 4 }
M.CLASS = CLASS

local floor = math.floor
local ORDER = {}
for i = 1, #colonist.WORK do ORDER[colonist.WORK[i]] = i end

local function EXPED() return require("sim.expedition") end

-- ---------------------------------------------------------------------------------------------
-- reservations
-- ---------------------------------------------------------------------------------------------
function M.rebuild_res(w)
	local res = {}
	local cs = w.s.colonists
	for i = 1, #cs do
		local c = cs[i]
		if c.job then
			for k = 1, #c.job.res do
				local key = c.job.res[k]
				local r = res[key]
				if not r then r = {}; res[key] = r end
				r[#r + 1] = c.id
			end
		end
	end
	w.rt.res = res
end

local function can_reserve(w, key, cap)
	local r = w.rt.res[key]
	return (not r) or #r < (cap or 1)
end

local function reserve(w, key, cid)
	local r = w.rt.res[key]
	if not r then r = {}; w.rt.res[key] = r end
	r[#r + 1] = cid
end

local function unreserve(w, key, cid)
	local r = w.rt.res[key]
	if not r then return end
	for i = 1, #r do
		if r[i] == cid then table.remove(r, i); break end
	end
	if #r == 0 then w.rt.res[key] = nil end
end

function M.holders(w, key) return w.rt.res[key] or {} end

-- verify the reservation invariants. Returns ok, err.
function M.check_reservations(w)
	local seen = {}
	local cs = w.s.colonists
	for i = 1, #cs do
		local c = cs[i]
		if c.job then
			for k = 1, #c.job.res do
				local key = c.job.res[k]
				seen[key] = (seen[key] or 0) + 1
				local cap = c.job.caps and c.job.caps[key] or 1
				if seen[key] > cap then return false, "key over-reserved: " .. key end
			end
		end
	end
	-- the derived table must match
	for key, ids in pairs(w.rt.res) do -- order-free
		if #ids ~= (seen[key] or 0) then return false, "reservation table drift on " .. key end
	end
	for key, n in pairs(seen) do -- order-free
		local r = w.rt.res[key]
		if not r or #r ~= n then return false, "missing reservation " .. key end
	end
	return true
end

-- ---------------------------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------------------------
local function zones(w) return w.s.zones end

local function speed_of(w, c, skill)
	local s = needs.work_speed(c, w.s.t) * (skill and skills.speed(c, skill) or 1)
	if clock.is_night(w.s.t) then s = s * traits.mul(c, "work_speed_night") else s = s * traits.mul(c, "work_speed_day") end
	if s < 0.1 then s = 0.1 end
	return s
end

local function is_personal(c, id)
	local d = items.defs[id]
	if d.cat == "weapon" then return true end
	if d.cat == "ammo" then
		-- keep ammo for the best weapon only, up to personal_ammo rounds
		local _, wd = colonist.best_weapon(c)
		if wd and wd.weapon.ammo == id then return (c.inv.items[id] or 0) <= J.personal_ammo end
		return false
	end
	return false
end

-- items a colonist carries that should be stocked
local function haulables(c)
	local out = {}
	for _, id in ipairs(U.keys(c.inv.items)) do
		if not is_personal(c, id) then out[#out + 1] = id end
	end
	return out
end

local function new_job(kind, work, class, key, target, steps, data)
	return { key = key, kind = kind, work = work, class = class, target = target, steps = steps, i = 1, ph = "go", t = 0,
		res = {}, caps = {}, data = data or {} }
end

local function step(pos, dur, act, data)
	return { pos = pos and U.pos_copy(pos) or nil, dur = dur, act = act, data = data or {} }
end

local function state_for(job)
	if not job then return "idle" end
	local k = job.kind
	if k == "sleep" or k == "rest" then return "sleeping" end
	if k == "guard" then return "guarding" end
	if k == "draft" then return "drafted" end
	return "working"
end

local function activity_for(c)
	local job = c.job
	if not job then return "idle" end
	local k = job.kind
	if k == "sleep" then return "sleep" end
	if k == "rest" then return "rest" end
	if k == "guard" then return "guard" end
	if k == "draft" or k == "idle" then return "idle" end
	return "work"
end
M.activity_for = activity_for

-- ---------------------------------------------------------------------------------------------
-- step actions. Each entry: begin(w,c,job,st) tick(w,c,job,st,dt) done(w,c,job,st) -> false aborts the job
-- ---------------------------------------------------------------------------------------------
local ACT = {}

-- take n of an item from a zone into the colonist's inventory
ACT.take_zone = { done = function(w, c, job, st)
	local d = st.data
	local z = d.zone and w:zone(d.zone)
	if not z or (z.items.items[d.item] or 0) <= 0 then z = stockpile.find_source(zones(w), d.item, c.pos) end
	if not z then return false end
	local moved = items.transfer(z.items, c.inv, d.item, d.n)
	if moved <= 0 then return false end
	job.data.carried = job.data.carried or {}
	job.data.carried[d.item] = (job.data.carried[d.item] or 0) + moved
	return true
end }

ACT.pickup_pile = { done = function(w, c, job, st)
	local pile = w:pile(st.data.pile)
	if not pile then return false end
	local moved_any = false
	for _, id in ipairs(U.keys(pile.items.items)) do
		if stockpile.find_dest(zones(w), id, pile.pos) then
			local n = pile.items.items[id]
			local moved = items.transfer(pile.items, c.inv, id, n)
			if moved > 0 then moved_any = true end
		end
	end
	if items.is_empty(pile.items) then w:remove_pile(pile) end
	return moved_any
end }

-- unload everything haulable into the best zones; leftovers go on the ground here
ACT.drop_zone = { done = function(w, c, job, st)
	for _, id in ipairs(haulables(c)) do
		local n = c.inv.items[id] or 0
		local guard = 0
		while n > 0 and guard < 6 do
			guard = guard + 1
			local z = stockpile.find_dest(zones(w), id, c.pos)
			if not z then break end
			local moved = items.transfer(c.inv, z.items, id, n)
			if moved <= 0 then break end
			n = n - moved
		end
	end
	local pile
	for _, id in ipairs(haulables(c)) do -- nothing accepts it: leave it on the ground rather than carry it forever
		local n = c.inv.items[id] or 0
		if n > 0 then
			pile = pile or w:pile_for(c.pos)
			items.transfer(c.inv, pile.items, id, n)
		end
	end
	return true
end }

ACT.drop_site = { done = function(w, c, job, st)
	local b = w:building(st.data.site)
	if not b or b.state ~= "planned" then return true end
	local missing = blueprints.missing(b)[st.data.item] or 0
	if missing > 0 then
		items.transfer(c.inv, b.delivered, st.data.item, missing)
	end
	return true
end }

ACT.build = {
	tick = function(w, c, job, st, dt)
		local b = w:building(st.data.site)
		if not b or b.state ~= "planned" then job.t = 0; return end
		local sp = speed_of(w, c, "construction")
		if blueprints.add_work(w, b, dt * sp) then job.t = 0 end
		skills.add_xp(c, "construction", dt * TUNING.skills.xp_per_work_min)
	end,
	done = function(w, c, job, st) return true end,
}

ACT.repair = {
	tick = function(w, c, job, st, dt)
		local b = w:building(st.data.site)
		if not b or b.state ~= "built" then job.t = 0; return end
		local sp = speed_of(w, c, "construction")
		blueprints.repair(b, dt * J.repair_hp_per_min * sp)
		skills.add_xp(c, "construction", dt * TUNING.skills.xp_per_work_min * 0.6)
		if b.hp >= b.hp_max - 1e-6 then job.t = 0 end
	end,
	done = function(w, c, job, st)
		local d = st.data
		local have = c.inv.items[d.item] or 0
		local n = have < d.n and have or d.n
		if n > 0 then w:destroy(c.inv, d.item, n, "repair") end
		return true
	end,
}

-- cook / craft: consume the carried inputs, create the outputs
ACT.make = {
	tick = function(w, c, job, st, dt)
		local r = RECIPES[st.data.recipe]
		skills.add_xp(c, r.skill, dt * TUNING.skills.xp_per_work_min)
	end,
	done = function(w, c, job, st)
		local r = RECIPES[st.data.recipe]
		local need = {}
		for id, n in pairs(r.inputs) do need[id] = n end -- order-free copy
		local station = w:building(st.data.station)
		local fuel = station and BP[station.bp].tags.fire
		if fuel then need.firewood = (need.firewood or 0) + 1 end
		if not items.has_all(c.inv, need) then return false end
		for _, id in ipairs(U.keys(need)) do
			w:destroy(c.inv, id, need[id], fuel and id == "firewood" and "fuel" or r.work_type)
		end
		for _, id in ipairs(U.keys(r.outputs)) do
			local made = w:create(c.inv, id, r.outputs[id], r.work_type)
			if made < r.outputs[id] then -- inventory full: the rest goes on the ground at the station
				local pile = w:pile_for(station and station.pos or c.pos)
				w:create(pile.items, id, r.outputs[id] - made, r.work_type)
			end
		end
		return true
	end,
}

ACT.tend = { done = function(w, c, job, st)
	local p = w:colonist(st.data.patient)
	if not p or p.dead then return false end
	local item = st.data.item
	if (c.inv.items[item] or 0) <= 0 then return false end
	local power = items.defs[item].med.power
	w:destroy(c.inv, item, 1, "medical")
	local closed = needs.treat_bleeding(p, w:rng("medical"), power)
	skills.add_xp(c, "medicine", TUNING.skills.xp_per_work_min * 4)
	p.dirty = true
	p.report = true
	return true
end }

ACT.medicate = { done = function(w, c, job, st)
	local p = w:colonist(st.data.patient)
	if not p or p.dead then return false end
	if (c.inv.items.antibiotics or 0) <= 0 then return false end
	w:destroy(c.inv, "antibiotics", 1, "medical")
	local rng = w:rng("medical")
	local was = p.inf.stage
	p.medicated_until = w.s.t + J.medicate_cooldown
	local bonus = traits.add(c, "cure_bonus")
	local cured = needs.treat_infection(p, rng, skills.level(c, "medicine"), bonus)
	skills.add_xp(c, "medicine", TUNING.skills.xp_per_work_min * 5)
	if cured then
		w:notify("info", string.format("%s was treated: the infection is gone.", p.name))
		w:stat("infections_cured", 1)
	end
	p.dirty = true
	p.report = true
	return true
end }

ACT.amputate = { done = function(w, c, job, st)
	local p = w:colonist(st.data.patient)
	if not p or p.dead then return false end
	if stockpile.total(zones(w), "surgical_kit") <= 0 then return false end
	local ok = needs.amputate(p, w:rng("medical"), skills.level(c, "medicine"), traits.add(c, "cure_bonus"))
	skills.add_xp(c, "medicine", TUNING.skills.xp_per_work_min * 12)
	if ok then
		w:notify("info", string.format("%s lost a limb to stop the infection.", p.name))
		w:add_thought(p, "amputated")
		w:stat("amputations", 1)
	else
		w:notify("warn", string.format("The amputation on %s did not stop the infection.", p.name))
	end
	p.dirty = true
	p.report = true
	return true
end }

ACT.guard = {
	tick = function(w, c, job, st, dt)
		skills.add_xp(c, "shooting", dt * 0.15)
		if not M.guard_needed(w) then job.t = 0 end
	end,
	done = function() return true end,
}

ACT.join = { done = function(w, c, job, st)
	return EXPED().join(w, st.data.exp, c)
end }

ACT.fuel = { done = function(w, c, job, st)
	local b = w:building(st.data.gen)
	if not b or b.state ~= "built" or (c.inv.items.fuel_can or 0) <= 0 then return false end
	w:destroy(c.inv, "fuel_can", 1, "fuel")
	grid.add_fuel(b, items.defs.fuel_can.fuel_l)
	return true
end }

ACT.consume = { done = function(w, c, job, st)
	local id = st.data.item
	if (c.inv.items[id] or 0) <= 0 then return false end
	local d = items.defs[id]
	w:destroy(c.inv, id, 1, "eat")
	needs.eat(c, d.food)
	if d.food.mood then w:add_thought(c, d.food.mood) end
	return true
end }

ACT.drink_tank = { done = function(w, c, job, st)
	local got = grid.draw_water(w, TUNING.grid.drink_l)
	if got <= 0 then return false end
	needs.drink(c, got / TUNING.grid.drink_l * TUNING.grid.drink_points)
	return true
end }

local function wake_check(w, c, job, st, dt)
	local d = job.data
	d.slept = (d.slept or 0) + dt
	if job.kind == "sleep" then
		local sched = colonist.schedule_at(c, clock.hour(w.s.t))
		if c.fatigue <= J.wake_fatigue then job.t = 0
		elseif sched ~= "S" and c.fatigue <= 45 and c.fatigue < N.emergency_fatigue then job.t = 0 end
	else -- resting
		local healed = c.hp >= c.hp_max * 0.85 and (c.inf.stage == "none" or c.inf.stage == "incubating")
		if healed then job.t = 0 end
	end
end

ACT.sleep = {
	tick = wake_check,
	done = function(w, c, job, st)
		local d = job.data
		if job.kind == "sleep" and (d.slept or 0) >= 120 then
			w:add_thought(c, d.bed and "slept_in_bed" or "slept_on_floor")
		end
		return true
	end,
}

ACT.stand = {
	tick = function(w, c, job, st, dt)
		if not c.drafted then job.t = 0 end
		if c.hunger >= 95 or c.thirst >= 95 then c.drafted = false; job.t = 0 end
	end,
	done = function() return true end,
}

ACT.noop = { done = function() return true end }

ACT.binge_take = { done = function(w, c, job, st)
	local want = TUNING.mood.binge_items
	local got = 0
	for _ = 1, want do
		local id, z = stockpile.find_item(zones(w), function(id, d) if d.food and (d.food.hunger or 0) >= 8 then return d.food.pref or 1 end end, c.pos)
		if not id then break end
		if items.transfer(z.items, c.inv, id, 1) > 0 then got = got + 1 end
	end
	return got > 0
end }

ACT.binge_eat = { done = function(w, c, job, st)
	local ate = 0
	for _, id in ipairs(U.keys(c.inv.items)) do
		local d = items.defs[id]
		if d.food and (d.food.hunger or 0) >= 8 then
			local n = c.inv.items[id]
			w:destroy(c.inv, id, n, "binge")
			for _ = 1, n do needs.eat(c, d.food) end
			ate = ate + n
		end
	end
	if ate > 0 then w:notify("warn", string.format("%s binged on %d food items.", c.name, ate)) end
	return true
end }

ACT.wander = { done = function(w, c, job, st)
	local b = c.mbreak
	if b and b.level == "extreme" and w:rng("mood"):chance(TUNING.mood.wander_leave_chance) then
		w:colonist_leaves(c, "wandered_off")
		return false
	end
	return true
end }

-- ---------------------------------------------------------------------------------------------
-- job lifecycle
-- ---------------------------------------------------------------------------------------------
local function emit_task(w, c, job, st)
	local pos = (st and st.pos) or c.pos
	w:emit({ type = "colonist_task", id = c.id, kind = job.kind, target = { kind = job.target.kind, id = job.target.id },
		pos = U.pos_copy(pos), step = st and st.act or nil, class = job.class })
end

local function begin_step(w, c, job)
	local st = job.steps[job.i]
	if st.pos then
		local d = U.dist(c.pos, st.pos)
		local t = d / colonist.walk_speed(c)
		job.ph = "go"
		job.t = t
		job.t0 = t
		job.from = U.pos_copy(c.pos)
		if d > 1 or job.i == 1 then emit_task(w, c, job, st) end
		if t <= 0 then
			c.pos = U.pos_copy(st.pos)
			job.ph = "do"
			job.t = st.dur
		end
	else
		job.ph = "do"
		job.t = st.dur
		if job.i == 1 then emit_task(w, c, job, st) end
	end
end

local function release_all(w, c, job)
	for i = 1, #job.res do unreserve(w, job.res[i], c.id) end
end

local function end_job(w, c, how)
	local job = c.job
	if not job then return end
	release_all(w, c, job)
	c.job = nil
	c.state = "idle"
	if how == "failed" then
		c.ban = c.ban or {}
		c.ban[job.key] = w.s.t + 30
	end
	c.reeval_t = w.s.t
	c.report = true
end

function M.abort(w, c, how) end_job(w, c, how or "aborted") end

-- reserve keys and start the job. Returns false when a key cannot be reserved.
local function start_job(w, c, job)
	for k, cap in pairs(job.caps) do -- order-free check
		if not can_reserve(w, k, cap) then return false end
	end
	for _, k in ipairs(U.keys(job.caps)) do
		reserve(w, k, c.id)
		job.res[#job.res + 1] = k
	end
	c.job = job
	c.state = state_for(job)
	job.started = w.s.t
	begin_step(w, c, job)
	c.report = true
	return true
end

-- advance the current job by dt minutes
local function progress(w, c, dt)
	local job = c.job
	local guard = 0
	while job and dt > 0 and guard < 24 do
		guard = guard + 1
		local st = job.steps[job.i]
		if job.ph == "go" then
			local use = dt < job.t and dt or job.t
			job.t = job.t - use
			dt = dt - use
			if job.t0 and job.t0 > 0 then
				local f = 1 - job.t / job.t0
				c.pos.x = job.from.x + (st.pos.x - job.from.x) * f
				c.pos.y = job.from.y + (st.pos.y - job.from.y) * f
				c.pos.z = job.from.z + (st.pos.z - job.from.z) * f
			end
			if job.t <= 1e-9 then
				c.pos = U.pos_copy(st.pos)
				job.ph = "do"
				job.t = st.dur
				local a = ACT[st.act]
				if a and a.begin then a.begin(w, c, job, st) end
			end
		else
			local use = dt < job.t and dt or job.t
			if use < 0 then use = 0 end
			local a = ACT[st.act]
			if use > 0 and a and a.tick then a.tick(w, c, job, st, use) end
			job.t = job.t - use
			dt = dt - use
			if job.t <= 1e-9 then
				local ok = true
				if a and a.done then ok = a.done(w, c, job, st) end
				if ok == false then
					end_job(w, c, "failed")
					return
				end
				if c.job ~= job then return end -- the action itself ended the job (e.g. joined an expedition)
				job.i = job.i + 1
				if job.i > #job.steps then
					end_job(w, c, "done")
					return
				end
				begin_step(w, c, job)
			end
		end
	end
end

-- ---------------------------------------------------------------------------------------------
-- planners: each returns a job (not yet started) or nil
-- ---------------------------------------------------------------------------------------------
local function find_food(w, c)
	local best, bscore, from_zone
	local function consider(id, d, in_zone)
		if d.food and (d.food.hunger or 0) >= 8 then
			local score = (d.food.pref or 1) * 10 + ((c.hunger >= 70) and d.food.hunger or 0)
			if not bscore or score > bscore then best, bscore, from_zone = id, score, in_zone end
		end
	end
	for _, id in ipairs(U.keys(c.inv.items)) do consider(id, items.defs[id], false) end
	local zid, z = stockpile.find_item(zones(w), function(id, d)
		if d.food and (d.food.hunger or 0) >= 8 then return (d.food.pref or 1) * 10 + ((c.hunger >= 70) and d.food.hunger or 0) end
	end, c.pos)
	if zid then
		local d = items.defs[zid]
		local score = (d.food.pref or 1) * 10 + ((c.hunger >= 70) and d.food.hunger or 0) - 0.5 -- carried food first on ties
		if not bscore or score > bscore then return zid, z end
	end
	return best, nil
end

local function plan_eat(w, c, class)
	local id, z = find_food(w, c)
	if not id then return nil end
	local steps = {}
	if z then steps[#steps + 1] = step(z.pos, J.take_min, "take_zone", { item = id, n = 1, zone = z.id }) end
	steps[#steps + 1] = step(nil, J.eat_min, "consume", { item = id })
	local job = new_job("eat", nil, class, "eat:" .. c.id, { kind = "self", id = c.id }, steps)
	job.caps["eat:" .. c.id] = 1
	return job
end

local function find_drink(w, c)
	if grid.water_available(w) then return "tank" end
	local best, bscore, zone
	local function consider(id, d, z)
		if d.food and (d.food.thirst or 0) >= 10 then
			local sc = (d.food.pref or 1) * 10 + d.food.thirst
			if not bscore or sc > bscore then best, bscore, zone = id, sc, z end
		end
	end
	for _, id in ipairs(U.keys(c.inv.items)) do consider(id, items.defs[id], nil) end
	local zid, z = stockpile.find_item(zones(w), function(id, d)
		if d.food and (d.food.thirst or 0) >= 10 then return (d.food.pref or 1) * 10 + d.food.thirst end
	end, c.pos)
	if zid and not best then best, zone = zid, z end
	return best, zone
end

local function plan_drink(w, c, class)
	local what, z = find_drink(w, c)
	if not what then return nil end
	local steps = {}
	if what == "tank" then
		steps[1] = step(w:water_pos(), J.drink_min, "drink_tank")
	else
		if z then steps[#steps + 1] = step(z.pos, J.take_min, "take_zone", { item = what, n = 1, zone = z.id }) end
		steps[#steps + 1] = step(nil, J.drink_min, "consume", { item = what })
	end
	local job = new_job("drink", nil, class, "drink:" .. c.id, { kind = "self", id = c.id }, steps)
	job.caps["drink:" .. c.id] = 1
	return job
end

-- sleep (kind "sleep") or rest (kind "rest") in a free bed if there is one
local function plan_sleep(w, c, class, kind)
	local best, bd
	local sick = c.hp < c.hp_max * 0.6 or c.inf.stage == "symptomatic" or c.inf.stage == "terminal"
	local beds = blueprints.beds(w)
	for i = 1, #beds do
		local b = beds[i]
		local med = BP[b.bp].tags.med_bed
		if can_reserve(w, "bed:" .. b.id, 1) and (not med or sick) then
			local d = U.dist(c.pos, b.pos) - ((med and sick) and 400 or 0)
			if not bd or d < bd then best, bd = b, d end
		end
	end
	local data = {}
	local pos
	if best then
		data.bed = best.id
		data.q = BP[best.bp].rest_quality or 1
		pos = best.pos
	else
		data.q = J.floor_rest_quality
	end
	local job = new_job(kind, nil, class, kind .. ":" .. c.id, { kind = "bed", id = best and best.id or "floor" },
		{ step(pos, 600, "sleep", data) }, data)
	job.caps[kind .. ":" .. c.id] = 1
	if best then job.caps["bed:" .. best.id] = 1 end
	return job
end

local function plan_haul(w, c, d)
	local pile = w:pile(d.data.pile)
	if not pile then return nil end
	local dest
	for _, id in ipairs(U.keys(pile.items.items)) do
		dest = stockpile.find_dest(zones(w), id, pile.pos)
		if dest then break end
	end
	if not dest then return nil end
	local job = new_job("haul", "haul", CLASS.WORK, d.key, { kind = "pile", id = pile.id }, {
		step(pile.pos, J.pickup_min, "pickup_pile", { pile = pile.id }),
		step(dest.pos, J.drop_min, "drop_zone", {}),
	})
	job.caps[d.key] = 1
	return job
end

local function plan_unload(w, c)
	local hs = haulables(c)
	if #hs == 0 then return nil end
	local dest
	for i = 1, #hs do
		dest = stockpile.find_dest(zones(w), hs[i], c.pos)
		if dest then break end
	end
	local pos = dest and dest.pos or nil
	local job = new_job("unload", "haul", CLASS.WORK, "unload:" .. c.id, { kind = "self", id = c.id },
		{ step(pos, J.drop_min, "drop_zone", {}) })
	job.caps["unload:" .. c.id] = 1
	return job
end

local function plan_deliver(w, c, d)
	local b = w:building(d.data.site)
	if not b or b.state ~= "planned" then return nil end
	local item = d.data.item
	local miss = blueprints.missing(b)[item]
	if not miss then return nil end
	local z, have = stockpile.find_source(zones(w), item, c.pos)
	if not z then return nil end
	local n = miss < have and miss or have
	local fit = items.can_add(c.inv, item)
	if fit < n then n = fit end
	if n <= 0 then return nil end
	local job = new_job("deliver", "haul", CLASS.WORK, d.key, { kind = "building", id = b.id }, {
		step(z.pos, J.take_min, "take_zone", { item = item, n = n, zone = z.id }),
		step(b.pos, J.drop_min, "drop_site", { site = b.id, item = item }),
	})
	job.caps[d.key] = 1
	return job
end

local function plan_build(w, c, d)
	local b = w:building(d.data.site)
	if not b or b.state ~= "planned" or not blueprints.is_supplied(b) then return nil end
	if skills.level(c, "construction") < BP[b.bp].skill_min then return nil end
	local sp = speed_of(w, c, "construction")
	local dur = (BP[b.bp].work - b.progress) / sp
	local job = new_job("build", "build", CLASS.WORK, d.key, { kind = "building", id = b.id },
		{ step(b.pos, dur, "build", { site = b.id }) })
	job.caps[d.key] = 1
	return job
end

local function repair_item_for(b)
	local d = BP[b.bp]
	if d.materials.scrap_wood then return "scrap_wood" end
	return "scrap_metal"
end

local function plan_repair(w, c, d)
	local b = w:building(d.data.site)
	if not b or b.state ~= "built" then return nil end
	local item = repair_item_for(b)
	local n = math.ceil((b.hp_max - b.hp) / J.repair_per_item_hp)
	if n < 1 then return nil end
	local z, have = stockpile.find_source(zones(w), item, c.pos)
	if not z then return nil end
	if have < n then n = have end
	local sp = speed_of(w, c, "construction")
	local dur = (b.hp_max - b.hp) / (J.repair_hp_per_min * sp)
	local job = new_job("repair", "build", CLASS.WORK, d.key, { kind = "building", id = b.id }, {
		step(z.pos, J.take_min, "take_zone", { item = item, n = n, zone = z.id }),
		step(b.pos, dur, "repair", { site = b.id, item = item, n = n }),
	})
	job.caps[d.key] = 1
	return job
end

local function plan_make(w, c, d)
	local station = w:building(d.data.station)
	if not station or station.state ~= "built" then return nil end
	local r = RECIPES[d.data.recipe]
	if skills.level(c, r.skill) < r.skill_min then return nil end
	local steps = {}
	local need = {}
	for id, n in pairs(r.inputs) do need[id] = n end -- order-free copy
	if BP[station.bp].tags.fire then need.firewood = (need.firewood or 0) + 1 end
	local lastz
	for _, id in ipairs(U.keys(need)) do
		local z, have = stockpile.find_source(zones(w), id, c.pos)
		if not z or have < need[id] then return nil end
		steps[#steps + 1] = step(z.pos, J.take_min, "take_zone", { item = id, n = need[id], zone = z.id })
		lastz = z
	end
	local sp = speed_of(w, c, r.skill)
	if station.powered and BP[station.bp].power_use then sp = sp * 1.25 end
	steps[#steps + 1] = step(station.pos, r.work / sp, "make", { station = station.id, recipe = r.id })
	local out_id = U.keys(r.outputs)[1]
	local dest = stockpile.find_dest(zones(w), out_id, station.pos)
	steps[#steps + 1] = step(dest and dest.pos or station.pos, J.drop_min, "drop_zone", {})
	local job = new_job(r.work_type, r.work_type, CLASS.WORK, d.key, { kind = "building", id = station.id }, steps)
	job.caps[d.key] = 1
	return job
end

local function plan_med(w, c, d, kind)
	local p = w:colonist(d.data.patient)
	if not p or p.dead then return nil end
	if kind == "tend" then
		local item = d.data.item
		local z = stockpile.find_source(zones(w), item, c.pos)
		if not z then return nil end
		local sp = speed_of(w, c, "medicine")
		local job = new_job("tend", "doctor", d.urgency >= 3 and CLASS.URGENT or CLASS.WORK, d.key, { kind = "colonist", id = p.id }, {
			step(z.pos, J.take_min, "take_zone", { item = item, n = 1, zone = z.id }),
			step(p.pos, J.tend_min / sp, "tend", { patient = p.id, item = item }),
		})
		job.caps[d.key] = 1
		return job
	elseif kind == "medicate" then
		local z = stockpile.find_source(zones(w), "antibiotics", c.pos)
		if not z then return nil end
		local sp = speed_of(w, c, "medicine")
		local job = new_job("medicate", "doctor", d.urgency >= 3 and CLASS.URGENT or CLASS.WORK, d.key, { kind = "colonist", id = p.id }, {
			step(z.pos, J.take_min, "take_zone", { item = "antibiotics", n = 1, zone = z.id }),
			step(p.pos, J.medicate_min / sp, "medicate", { patient = p.id }),
		})
		job.caps[d.key] = 1
		return job
	else -- amputate
		if stockpile.total(zones(w), "surgical_kit") <= 0 then return nil end
		if skills.level(c, "medicine") < 2 then return nil end
		local sp = speed_of(w, c, "medicine")
		local job = new_job("amputate", "doctor", CLASS.WORK, d.key, { kind = "colonist", id = p.id }, {
			step(p.pos, TUNING.needs.infection.amputate_work_min / sp, "amputate", { patient = p.id }),
		})
		job.caps[d.key] = 1
		return job
	end
end

local function plan_guard(w, c, d)
	local job = new_job("guard", "guard", CLASS.WORK, d.key, { kind = "post", id = d.data.post }, {
		step(d.pos, J.guard_shift_min, "guard", { post = d.data.post }),
	})
	job.caps[d.key] = d.cap or 1
	return job
end

local function plan_join(w, c, d)
	local job = new_job("scavenge", "scavenge", CLASS.WORK, d.key, { kind = "expedition", id = d.data.exp }, {
		step(w:garage_pos(), 3, "join", { exp = d.data.exp }),
	})
	job.caps[d.key] = d.cap or 1
	return job
end

local function plan_refuel(w, c, d)
	local g = w:building(d.data.gen)
	if not g or g.state ~= "built" then return nil end
	local z = stockpile.find_source(zones(w), "fuel_can", c.pos)
	if not z then return nil end
	local job = new_job("refuel", "haul", CLASS.WORK, d.key, { kind = "building", id = g.id }, {
		step(z.pos, J.take_min, "take_zone", { item = "fuel_can", n = 1, zone = z.id }),
		step(g.pos, 2, "fuel", { gen = g.id }),
	})
	job.caps[d.key] = 1
	return job
end

local function plan_stand(w, c)
	local job = new_job("draft", nil, CLASS.FORCED, "stand:" .. c.id, { kind = "self", id = c.id }, { step(nil, 600, "stand") })
	job.caps["stand:" .. c.id] = 1
	return job
end

local function plan_binge(w, c)
	local job = new_job("binge", nil, CLASS.URGENT, "break:" .. c.id, { kind = "self", id = c.id }, {
		step(w:garage_pos(), J.take_min, "binge_take"),
		step(nil, J.binge_min, "binge_eat"),
	})
	job.caps["break:" .. c.id] = 1
	return job
end

local function plan_wander(w, c)
	local rng = w:rng("mood")
	-- pick one of 8 compass directions (no trig)
	local dirs = { { 1, 0 }, { 0.7071, 0.7071 }, { 0, 1 }, { -0.7071, 0.7071 }, { -1, 0 }, { -0.7071, -0.7071 }, { 0, -1 }, { 0.7071, -0.7071 } }
	local dv = dirs[rng:int(1, 8)]
	local r = J.wander_radius
	local pos = { x = TUNING.base.x + dv[1] * r, y = TUNING.base.y + dv[2] * r, z = TUNING.base.z }
	local left = c.mbreak and (c.mbreak.until_t - w.s.t) or 60
	if left < 5 then left = 5 end
	local job = new_job("wander", nil, CLASS.URGENT, "break:" .. c.id, { kind = "self", id = c.id }, { step(pos, left, "wander") })
	job.caps["break:" .. c.id] = 1
	return job
end

local function plan_goto(w, c, o)
	local job = new_job("goto", nil, CLASS.FORCED, "goto:" .. c.id, { kind = "pos", id = "" }, { step(o.pos, 1, "noop") })
	job.caps["goto:" .. c.id] = 1
	return job
end

local function plan_equip(w, c, o)
	local steps = {}
	local z = stockpile.find_source(zones(w), o.item, c.pos)
	if not z then return nil end
	steps[1] = step(z.pos, J.take_min, "take_zone", { item = o.item, n = 1, zone = z.id })
	local wd = items.defs[o.item].weapon
	if wd and wd.ammo then
		local az, have = stockpile.find_source(zones(w), wd.ammo, c.pos)
		if az then
			local want = J.personal_ammo - (c.inv.items[wd.ammo] or 0)
			if want > 0 then
				local n = have < want and have or want
				steps[2] = step(az.pos, J.take_min, "take_zone", { item = wd.ammo, n = n, zone = az.id })
			end
		end
	end
	local job = new_job("equip", nil, CLASS.FORCED, "equip:" .. c.id, { kind = "item", id = o.item }, steps)
	job.caps["equip:" .. c.id] = 1
	return job
end

-- ---------------------------------------------------------------------------------------------
-- the board
-- ---------------------------------------------------------------------------------------------
function M.guard_needed(w)
	return clock.is_night(w.s.t) or w.s.alert > 0
end

function M.guards_wanted(w)
	local n = 0
	if clock.is_night(w.s.t) then n = J.guard_posts_night end
	if w.s.alert > 0 then n = J.guard_posts_alert end
	return n
end

local function has_item(tot, id, n) return (tot[id] or 0) >= (n or 1) end

-- Rebuild the job board from world state. Existing entries keep their `since` time (aging).
function M.refresh(w)
	local s = w.s
	local now = s.t
	local old = {}
	for i = 1, #s.board.jobs do old[s.board.jobs[i].key] = s.board.jobs[i].since end
	local list = {}
	local zs = s.zones
	local tot = stockpile.totals(zs)
	local function add(d)
		d.since = old[d.key] or now
		d.cap = d.cap or 1
		d.urgency = d.urgency or 0
		list[#list + 1] = d
	end

	-- hauling loose piles into zones
	for i = 1, #s.piles do
		local p = s.piles[i]
		local storable = false
		for _, id in ipairs(U.keys(p.items.items)) do
			if stockpile.find_dest(zs, id, p.pos) then storable = true; break end
		end
		if storable then
			add({ key = "haul:" .. p.id, kind = "haul", work = "haul", target = { kind = "pile", id = p.id }, pos = p.pos, data = { pile = p.id },
				urgency = 1 })
		end
	end

	-- construction: deliveries, building, repairs
	for i = 1, #s.buildings do
		local b = s.buildings[i]
		if b.state == "planned" then
			local miss = blueprints.missing(b)
			local any = false
			for _, item in ipairs(U.keys(miss)) do
				any = true
				if has_item(tot, item) then
					add({ key = "deliver:" .. b.id .. ":" .. item, kind = "deliver", work = "haul", target = { kind = "building", id = b.id },
						pos = b.pos, data = { site = b.id, item = item }, urgency = 1 })
				end
			end
			if not any then
				add({ key = "build:" .. b.id, kind = "build", work = "build", target = { kind = "building", id = b.id }, pos = b.pos,
					data = { site = b.id }, skill = "construction", skill_min = BP[b.bp].skill_min, urgency = 1 })
			end
		elseif b.state == "built" and b.hp < b.hp_max * J.repair_below then
			if has_item(tot, repair_item_for(b)) then
				add({ key = "repair:" .. b.id, kind = "repair", work = "build", target = { kind = "building", id = b.id }, pos = b.pos,
					data = { site = b.id }, urgency = 2 })
			end
		end
		-- generator fuel
		if b.state == "built" and BP[b.bp].power_gen and b.fuel_min <= BP[b.bp].fuel_cap_min - 500 and has_item(tot, "fuel_can") then
			add({ key = "refuel:" .. b.id, kind = "refuel", work = "haul", target = { kind = "building", id = b.id }, pos = b.pos,
				data = { gen = b.id }, urgency = (b.fuel_min < 120) and 3 or 2 })
		end
	end

	-- cooking + crafting stations: one job per station for the most-needed recipe
	for i = 1, #s.buildings do
		local b = s.buildings[i]
		if b.state == "built" then
			local tags = BP[b.bp].tags
			local tag = tags.cook_station and "cook_station" or (tags.craft_station and "craft_station" or nil)
			local powered_ok = (not tags.needs_power) or b.powered
			if tag and powered_ok then
				local best, bscore
				for _, rid in ipairs(U.keys(RECIPES)) do
					local r = RECIPES[rid]
					if r.station == tag then
						local want_id, want_n = r.want[1], r.want[2]
						local have = tot[want_id] or 0
						local ok = have < want_n
						if ok then
							for id, n in pairs(r.inputs) do if (tot[id] or 0) < n then ok = false end end -- order-free
						end
						if ok and tags.fire and not has_item(tot, "firewood") then ok = false end
						if ok then
							local score = (want_n - have) / want_n
							if not bscore or score > bscore then best, bscore = r, score end
						end
					end
				end
				if best then
					add({ key = "cook:" .. b.id, kind = best.work_type, work = best.work_type, target = { kind = "building", id = b.id }, pos = b.pos,
						data = { station = b.id, recipe = best.id }, skill = best.skill, skill_min = best.skill_min, urgency = 1 })
				end
			end
		end
	end

	-- doctors
	local have_bandage = has_item(tot, "bandage") or has_item(tot, "first_aid_kit")
	local have_abx = has_item(tot, "antibiotics")
	local have_kit = has_item(tot, "surgical_kit")
	for i = 1, #s.colonists do
		local p = s.colonists[i]
		if not p.dead and p.state ~= "away" then
			local bleed = needs.bleeding(p)
			if bleed > 0.0001 and have_bandage then
				local item = (has_item(tot, "first_aid_kit") and (bleed > 0.3 or #p.wounds >= 3)) and "first_aid_kit" or (has_item(tot, "bandage") and "bandage" or "first_aid_kit")
				add({ key = "tend:" .. p.id, kind = "tend", work = "doctor", target = { kind = "colonist", id = p.id }, pos = p.pos,
					data = { patient = p.id, item = item }, urgency = (bleed >= J.treat_bleed_urgent or p.downed) and 3 or 2 })
			end
			-- bitten (visible bite wound) or visibly sick: antibiotics, once per cooldown
			local bitten = false
			for k = 1, #p.wounds do if p.wounds[k].bite and p.wounds[k].age < 720 then bitten = true end end
			local visible = p.inf.stage == "symptomatic" or p.inf.stage == "terminal"
			if (bitten or visible) and have_abx and now >= (p.medicated_until or 0) then
				add({ key = "medicate:" .. p.id, kind = "medicate", work = "doctor", target = { kind = "colonist", id = p.id }, pos = p.pos,
					data = { patient = p.id }, urgency = (p.inf.stage == "terminal") and 3 or (visible and 2 or 1) })
			end
			-- amputation-lite: allowed per colonist, only when there is no antibiotic left to try first
			if p.allow_amputation and have_kit and not have_abx and (bitten or visible) and needs.LIMBS[p.inf.part] and p.inf.stage ~= "none" and p.inf.stage ~= "terminal" then
				add({ key = "amputate:" .. p.id, kind = "amputate", work = "doctor", target = { kind = "colonist", id = p.id }, pos = p.pos,
					data = { patient = p.id }, skill = "medicine", skill_min = 2, urgency = 2 })
			end
		end
	end

	-- guard posts
	if M.guard_needed(w) then
		local wanted = M.guards_wanted(w)
		local posts = 0
		local towers = blueprints.list_tag(w, "guard_post", true)
		for i = 1, #towers do
			local b = towers[i]
			if posts < wanted then
				posts = posts + 1
				add({ key = "guard:" .. b.id, kind = "guard", work = "guard", target = { kind = "post", id = b.id }, pos = b.pos,
					data = { post = b.id }, cap = BP[b.bp].guard_slots or 1, urgency = 1 })
			end
		end
		local R = J.gate_radius
		local gates = { { "gate_e", R, 0 }, { "gate_n", 0, R }, { "gate_w", -R, 0 }, { "gate_s", 0, -R } }
		for i = 1, #gates do
			if posts < wanted then
				posts = posts + 1
				local g = gates[i]
				add({ key = "guard:" .. g[1], kind = "guard", work = "guard", target = { kind = "post", id = g[1] },
					pos = { x = TUNING.base.x + g[2], y = TUNING.base.y + g[3], z = TUNING.base.z }, data = { post = g[1] }, urgency = 1 })
			end
		end
	end

	-- expeditions waiting for crew
	for i = 1, #s.exped do
		local x = s.exped[i]
		if x.state == "forming" and #x.crew < x.want_crew then
			add({ key = "join:" .. x.id, kind = "scavenge", work = "scavenge", target = { kind = "expedition", id = x.id }, pos = w:garage_pos(),
				data = { exp = x.id }, cap = x.want_crew - #x.crew, urgency = 1 })
		end
	end

	U.sort(list, function(a, b) return a.key < b.key end)
	s.board = { t = now, jobs = list }
end

-- ---------------------------------------------------------------------------------------------
-- choosing a job for a colonist
-- ---------------------------------------------------------------------------------------------
local function plan_from_desc(w, c, d)
	local k = d.kind
	if k == "haul" then return plan_haul(w, c, d)
	elseif k == "deliver" then return plan_deliver(w, c, d)
	elseif k == "build" then return plan_build(w, c, d)
	elseif k == "repair" then return plan_repair(w, c, d)
	elseif k == "cook" or k == "craft" then return plan_make(w, c, d)
	elseif k == "tend" or k == "medicate" or k == "amputate" then return plan_med(w, c, d, k)
	elseif k == "guard" then return plan_guard(w, c, d)
	elseif k == "scavenge" then return plan_join(w, c, d)
	elseif k == "refuel" then return plan_refuel(w, c, d)
	end
	return nil
end

-- best board job for this colonist. urgent_only = only urgency-3 jobs. Returns a planned job or nil.
local function pick_board(w, c, urgent_only)
	local now = w.s.t
	local board = w.s.board.jobs
	for _ = 1, 5 do
		local best, bk
		for i = 1, #board do
			local d = board[i]
			local ok = true
			if urgent_only then ok = d.urgency >= 3 end
			local prio = c.prio[d.work] or 0
			if ok and prio > 0 and can_reserve(w, d.key, d.cap) and not (c.ban and c.ban[d.key] and c.ban[d.key] > now) then
				if d.skill and skills.level(c, d.skill) < (d.skill_min or 0) then ok = false end
				if ok then
					local eff = prio - floor((now - d.since) / J.aging_minutes)
					if eff < 1 then eff = 1 end
					local dist = U.dist(c.pos, d.pos)
					-- lexicographic: eff asc, work order asc, urgency desc, distance asc, key asc
					local better = false
					if not best then better = true
					else
						local e2, o2, u2, d2 = bk[1], bk[2], bk[3], bk[4]
						if eff ~= e2 then better = eff < e2
						elseif ORDER[d.work] ~= o2 then better = ORDER[d.work] < o2
						elseif d.urgency ~= u2 then better = d.urgency > u2
						elseif dist ~= d2 then better = dist < d2
						else better = d.key < best.key end
					end
					if better then best = d; bk = { eff, ORDER[d.work], d.urgency, dist } end
				end
			end
		end
		if not best then return nil end
		local job = plan_from_desc(w, c, best)
		if job then return job end
		c.ban = c.ban or {}
		c.ban[best.key] = now + 30
	end
	return nil
end

local function clean_bans(c, now)
	if not c.ban then return end
	local any = false
	for k, t in pairs(c.ban) do -- order-free
		if t <= now then c.ban[k] = nil else any = true end
	end
	if not any then c.ban = nil end
end

function M.pick(w, c)
	local s = w.s
	local now = s.t
	clean_bans(c, now)
	-- forced orders
	if c.orders and #c.orders > 0 then
		local o = c.orders[1]
		local job
		if o.kind == "goto" then job = plan_goto(w, c, o) elseif o.kind == "equip" then job = plan_equip(w, c, o) end
		table.remove(c.orders, 1)
		if job then return job end
	end
	if c.drafted then return plan_stand(w, c) end
	-- mental break jobs
	if c.mbreak then
		if c.mbreak.kind == "binge" then
			local j = plan_binge(w, c)
			if j then return j end
		elseif c.mbreak.kind == "wander" then
			return plan_wander(w, c)
		end
	end
	-- emergencies
	local job
	if c.thirst >= N.emergency_thirst then job = plan_drink(w, c, CLASS.URGENT); if job then return job end end
	if c.hunger >= N.emergency_hunger then job = plan_eat(w, c, CLASS.URGENT); if job then return job end end
	if c.fatigue >= N.emergency_fatigue then return plan_sleep(w, c, CLASS.URGENT, "sleep") end
	if (c.prio.doctor or 0) > 0 and not (c.mbreak and c.mbreak.kind == "refuse") then
		job = pick_board(w, c, true)
		if job then return job end
	end
	-- needs
	if c.thirst >= N.drink_at then job = plan_drink(w, c, CLASS.NEED); if job then return job end end
	if c.hunger >= N.eat_at then job = plan_eat(w, c, CLASS.NEED); if job then return job end end
	local sched = colonist.schedule_at(c, clock.hour(now))
	if (sched == "S" and c.fatigue >= 20) or c.fatigue >= N.sleep_at then return plan_sleep(w, c, CLASS.NEED, "sleep") end
	local sick = c.hp < c.hp_max * 0.55 or c.inf.stage == "symptomatic" or c.inf.stage == "terminal"
	if sick and sched ~= "W" then return plan_sleep(w, c, CLASS.NEED, "rest") end
	if sick and c.inf.stage ~= "none" and c.inf.stage ~= "incubating" then return plan_sleep(w, c, CLASS.NEED, "rest") end
	-- work
	if sched == "J" then return nil end
	if c.mbreak and c.mbreak.kind == "refuse" then return nil end
	job = plan_unload(w, c)
	if job then return job end
	return pick_board(w, c, false)
end

-- ---------------------------------------------------------------------------------------------
-- per-step update (called by the world for every living colonist)
-- ---------------------------------------------------------------------------------------------
function M.update(w, c, dt, index)
	if c.dead or c.state == "away" then return end
	local now = w.s.t
	if c.downed then
		if c.job then end_job(w, c, "downed") end
		if c.state ~= "downed" then c.state = "downed"; c.report = true end
		return
	end
	if c.state == "downed" then c.state = "idle"; c.dirty = true end
	if c.job then progress(w, c, dt) end
	local due = (not c.job) or c.dirty or now >= (c.reeval_t or 0)
	if not due then return end
	local newjob = M.pick(w, c)
	c.dirty = false
	if newjob then
		if (not c.job) or newjob.class > c.job.class then
			if c.job then
				local old = c.job
				end_job(w, c, "preempted")
			end
			if not start_job(w, c, newjob) then
				c.reeval_t = now + 2
			else
				c.reeval_t = now + J.reeval_interval + (index % 5)
			end
		else
			c.reeval_t = now + J.reeval_interval + (index % 5)
		end
	else
		if c.job then
			c.reeval_t = now + J.reeval_interval + (index % 5)
		else
			if c.state ~= "idle" then c.state = "idle"; c.report = true end
			c.reeval_t = now + 2
			if not c.idle_sent then
				c.idle_sent = true
				w:emit({ type = "colonist_task", id = c.id, kind = "idle", target = { kind = "self", id = c.id }, pos = U.pos_copy(c.pos), class = 0 })
			end
		end
	end
	if c.job then c.idle_sent = false end
end

-- release everything a colonist holds (death, leaving, joining an expedition)
function M.release_colonist(w, c)
	if c.job then end_job(w, c, "released") end
end

return M
