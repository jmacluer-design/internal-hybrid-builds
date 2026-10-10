-- colonist.lua : a survivor. Stats, carried inventory (weight + slot limited), work priorities
-- (0 = never, 1 = highest .. 4 = lowest), a 24-hour schedule, and combat strength.
-- Plain data only (no game handles). `ref` is an opaque field the adapter owns.
local U = require("sim.util")
local TUNING = require("data.tuning")
local NAMES = require("data.names")
local items = require("sim.items")
local needs = require("sim.needs")
local mood = require("sim.mood")
local skills = require("sim.skills")
local traits = require("sim.traits")

local M = {}
local CT = TUNING.colonist

M.WORK = CT.work_types

-- which skill drives which work type
M.WORK_SKILL = { doctor = "medicine", guard = "shooting", build = "construction", cook = "cooking",
	craft = "construction", haul = nil, scavenge = "scavenging" }

function M.make_name(rng)
	return rng:pick(NAMES.first) .. " \"" .. rng:pick(NAMES.nick) .. "\""
end

-- 24-char schedule strings: S sleep, W work, A anything, J joy (no work)
local function sched(sleep_from, sleep_len)
	local t = {}
	for h = 0, 23 do t[h + 1] = "W" end
	for i = 0, sleep_len - 1 do t[(sleep_from + i) % 24 + 1] = "S" end
	t[(sleep_from + sleep_len) % 24 + 1] = "J"
	return table.concat(t)
end

function M.default_schedule(pref)
	if pref == "night" then return sched(8, 8) end
	if pref == "early" then return sched(21, 8) end
	return sched(22, 8)
end

function M.schedule_at(c, hour)
	return c.sched:sub(hour + 1, hour + 1)
end

function M.carry_cap(c)
	return CT.carry_base_g + CT.carry_per_str * c.str + traits.add(c, "carry_g")
end

function M.walk_speed(c)
	local s = CT.walk_speed
	for _ = 1, c.maimed do s = s * 0.85 end
	if c.hp < c.hp_max * 0.4 then s = s * 0.8 end
	return s
end

-- opts: id (required), name, traits, skills (table), focus (skill name), pos, str, joined (minute)
function M.new(rng, opts)
	local c = {
		id = opts.id,
		name = opts.name or M.make_name(rng),
		age = opts.age or rng:int(19, 58),
		str = opts.str or rng:int(3, 8),
		traits = opts.traits or traits.roll(rng, rng:int(1, 3)),
		pos = opts.pos and U.pos_copy(opts.pos) or { x = TUNING.base.x, y = TUNING.base.y, z = TUNING.base.z },
		state = "idle",
		drafted = false,
		kills = 0,
		joined = opts.joined or 0,
		prio = {},
		allow_amputation = true,
		ref = nil,
	}
	c.skills = opts.skills or skills.new(rng, opts.focus)
	needs.init(c)
	c.hp_max = c.hp_max + traits.add(c, "hp_max")
	c.hp = c.hp_max
	mood.init(c)
	c.inv = items.new(M.carry_cap(c), CT.slots)
	c.sched = M.default_schedule(traits.schedule_pref(c))
	M.auto_priorities(c)
	return c
end

function M.can_work(c, work)
	if traits.blocks(c, work) then return false end
	return true
end

-- priority level 0..4 (0 = disabled). Blocked work types are forced to 0.
function M.set_priority(c, work, level)
	level = U.clamp(math.floor(level), 0, 4)
	if not M.can_work(c, work) then level = 0 end
	c.prio[work] = level
	return level
end

function M.priority(c, work) return c.prio[work] or 0 end

-- sensible defaults: best-skilled work types first
function M.auto_priorities(c)
	local scored = {}
	for i = 1, #M.WORK do
		local w = M.WORK[i]
		local sk = M.WORK_SKILL[w]
		local lvl = sk and skills.level(c, sk) or 2
		scored[#scored + 1] = { w = w, s = lvl * 10 - i }
	end
	U.sort(scored, function(a, b) return a.s > b.s end)
	for i = 1, #scored do
		local lvl = (i <= 2) and 1 or ((i <= 4) and 2 or 3)
		M.set_priority(c, scored[i].w, lvl)
	end
	-- never leave a colonist unable to haul: it is everyone's fallback chore
	if M.can_work(c, "haul") and c.prio.haul == 0 then c.prio.haul = 4 end
end

-- best weapon in the inventory. Returns id, def, usable (ranged needs ammo on hand).
function M.best_weapon(c)
	local best, bdef, bscore = nil, nil, -1
	local usable = true
	for _, id in ipairs(U.keys(c.inv.items)) do
		local d = items.defs[id]
		if d.weapon then
			local ok = true
			if d.weapon.kind == "ranged" then ok = (c.inv.items[d.weapon.ammo] or 0) > 0 end
			local score = d.weapon.power * (ok and 1 or 0.3)
			if score > bscore then bscore = score; best = id; bdef = d; usable = ok end
		end
	end
	return best, bdef, usable
end

-- combat power used by combat_abstract. Returns power, ranged(bool), ammo_item (or nil)
function M.combat_power(c, now)
	if c.dead or c.downed then return 0, false, nil end
	local id, d, usable = M.best_weapon(c)
	local power, ranged, ammo = 1.2, false, nil
	local melee_f = 0.5 + 0.1 * skills.level(c, "melee")
	if d and d.weapon.kind == "ranged" and usable then
		power = d.weapon.power * (0.5 + 0.1 * skills.level(c, "shooting"))
		ranged = true
		ammo = d.weapon.ammo
	elseif d and d.weapon.kind == "melee" then
		power = d.weapon.power * melee_f
	else
		power = 1.2 * melee_f * 1.5
	end
	power = power * traits.mul(c, "combat_power") * needs.work_speed(c, now)
	return power, ranged, ammo
end

-- every colonist who is not dead / downed / away
function M.is_available(c)
	return not c.dead and not c.downed and c.state ~= "away"
end

-- compact public view (colonist_state event payload)
function M.view(c, now)
	local jk = c.job and c.job.kind or nil
	return {
		id = c.id, name = c.name, state = c.state, job = jk,
		hp = c.hp, hp_max = c.hp_max, hunger = c.hunger, thirst = c.thirst, fatigue = c.fatigue,
		pain = needs.perceived_pain(c, now), bleeding = needs.bleeding(c),
		infection = c.inf.stage == "none" and "none" or (c.inf.stage == "incubating" and "none" or c.inf.stage), -- incubation is invisible
		mood = c.mood, mood_break = c.mbreak and c.mbreak.kind or nil,
		downed = c.downed, drafted = c.drafted, maimed = c.maimed,
		pos = { x = c.pos.x, y = c.pos.y, z = c.pos.z },
		weapon = (M.best_weapon(c)),
	}
end

return M
