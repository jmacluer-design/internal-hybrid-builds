-- siege.lua : resolve an abstract attack on the base (horde assault or raid) with combat_abstract,
-- then apply every consequence to the world: wounds, ammo spent, wall damage, noise, kill credit.
local U = require("sim.util")
local TUNING = require("data.tuning")
local combat = require("sim.combat_abstract")
local colonist = require("sim.colonist")
local blueprints = require("sim.blueprints")
local skills = require("sim.skills")
local items = require("sim.items")

local M = {}
local CT = TUNING.combat

-- readiness of one colonist when the base is attacked
local function readiness(w, c)
	local j = c.job
	if c.downed then return CT.downed_factor end
	if c.drafted or (j and j.kind == "guard") then return CT.guard_factor end
	local r
	if j and (j.kind == "sleep" or j.kind == "rest") then r = CT.sleep_factor else r = CT.awake_factor end
	if w.s.alert > 0 and r < CT.awake_factor * CT.alarm_bonus then r = U.min(CT.guard_factor, CT.awake_factor * CT.alarm_bonus) end
	return r
end

-- colonists who are at the base (not on an expedition, not wandering off)
function M.defenders(w)
	local list = {}
	local cs = w.s.colonists
	for i = 1, #cs do
		local c = cs[i]
		if not c.dead and c.state ~= "away" and not (c.job and c.job.kind == "wander") then
			local power, ranged, ammo = colonist.combat_power(c, w.s.t)
			list[#list + 1] = { id = c.id, power = power, ranged = ranged, ammo = ammo,
				ammo_have = ammo and (c.inv.items[ammo] or 0) or 0, hp = c.hp, ready = readiness(w, c) }
		end
	end
	return list
end

-- mix = attackers ({walker=..}); opts.rounds; opts.source ("horde"/"raid"). Returns the combat result.
function M.resolve(w, mix, opts)
	opts = opts or {}
	local defense, barrier_hp, enclosure = blueprints.defense(w)
	local spec = {
		attackers = mix, defenders = M.defenders(w), defense = defense, barrier_hp = barrier_hp, enclosure = enclosure,
		rounds = opts.rounds,
	}
	local res = combat.resolve(w:rng("siege"), spec)
	-- wounds
	for i = 1, #res.hits do
		local h = res.hits[i]
		local c = w:colonist(h.id)
		if c then w:wound(c, h.kind, h.amount) end
	end
	-- ammo
	local fired = 0
	for _, id in ipairs(U.keys(res.ammo_used)) do
		local c = w:colonist(id)
		if c then
			local _, wd = colonist.best_weapon(c)
			if wd and wd.weapon.ammo then
				w:destroy(c.inv, wd.weapon.ammo, res.ammo_used[id], "combat")
				fired = fired + res.ammo_used[id]
			end
		end
	end
	-- kills -> xp for everyone who fought, and the stat counter
	local kills = combat.mix_count(res.killed)
	if kills > 0 then
		w:stat("zombies_killed", (mix.raider and 0 or kills))
		w:stat("raiders_killed", (mix.raider and (res.killed.raider or 0) or 0))
		local cs = w.s.colonists
		local fighters = 0
		for i = 1, #cs do if not cs[i].dead and cs[i].state ~= "away" and not cs[i].downed then fighters = fighters + 1 end end
		if fighters > 0 then
			for i = 1, #cs do
				local c = cs[i]
				if not c.dead and c.state ~= "away" and not c.downed then
					local share = kills / fighters
					skills.add_xp(c, "shooting", share * TUNING.skills.xp_per_kill * CT.xp_shoot_mult)
					skills.add_xp(c, "melee", share * TUNING.skills.xp_per_kill * CT.xp_melee_mult)
					c.kills = c.kills + share
				end
			end
		end
	end
	-- the walls take a beating
	if res.wall_damage > 0 then blueprints.damage_defenses(w, res.wall_damage) end
	-- noise: gunfire draws more hordes; screamers draw many
	local base = { x = TUNING.base.x, y = TUNING.base.y, z = TUNING.base.z }
	if fired > 0 then w:noise(base, TUNING.horde.noise.gunshot, "gunshot") end
	if res.screamers_left > 0 then w:noise(base, TUNING.horde.noise.screamer, "screamer") end
	-- resolve deaths now so callers see a consistent roster
	local cs = w.s.colonists
	local i = 1
	while i <= #cs do
		local c = cs[i]
		local n = #cs
		w:process_vitals(c)
		if #cs == n then i = i + 1 end
	end
	return res
end

return M
