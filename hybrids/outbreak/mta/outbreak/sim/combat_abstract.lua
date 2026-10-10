-- combat_abstract.lua : resolve off-screen skirmishes (horde assaults, raids, ambushes) from the rng.
-- Pure: takes plain tables, returns a result table; the world applies the consequences.
--
-- spec = {
--   attackers = { walker = n, runner = n, brute = n, screamer = n, raider = n },
--   defenders = { { id, power, ranged (bool), ammo (item id), ammo_have (n), hp, ready (0..1) } ... },
--   defense = building defense score, barrier_hp = total hp of defensive structures, enclosure = 0..1,
--   rounds = optional override,
-- }
-- result = { attackers_left = mix, killed = mix, hits = { {id, kind, amount} }, dead = { id... },
--            ammo_used = { id = n }, wall_damage, breached, outcome, rounds_run, screamers_left }
local U = require("sim.util")
local TUNING = require("data.tuning")

local M = {}
local CT = TUNING.combat

function M.type_power(t) return CT.types[t] and CT.types[t].power or 1 end

function M.mix_count(mix)
	local n = 0
	for i = 1, #CT.order do n = n + (mix[CT.order[i]] or 0) end
	return n
end

function M.mix_power(mix)
	local p = 0
	for i = 1, #CT.order do
		local t = CT.order[i]
		p = p + (mix[t] or 0) * CT.types[t].power
	end
	return p
end

function M.copy_mix(mix)
	local m = {}
	for i = 1, #CT.order do local t = CT.order[i]; if (mix[t] or 0) > 0 then m[t] = mix[t] end end
	return m
end

-- remove attacker power `amount` from a mix proportionally (cheapest bodies die first inside a type);
-- returns the mix of removed heads.
local function remove_power(rng, mix, amount)
	local removed = {}
	local total = M.mix_power(mix)
	if total <= 0 or amount <= 0 then return removed end
	if amount >= total then
		for i = 1, #CT.order do
			local t = CT.order[i]
			if (mix[t] or 0) > 0 then removed[t] = mix[t]; mix[t] = nil end
		end
		return removed
	end
	local f = amount / total
	for i = 1, #CT.order do
		local t = CT.order[i]
		local n = mix[t] or 0
		if n > 0 then
			local exact = n * f
			local k = math.floor(exact)
			if rng:float() < exact - k then k = k + 1 end
			if k > n then k = n end
			if k > 0 then
				removed[t] = k
				mix[t] = (n - k > 0) and (n - k) or nil
			end
		end
	end
	return removed
end

function M.resolve(rng, spec)
	local mix = M.copy_mix(spec.attackers)
	local killed = {}
	local defenders = spec.defenders or {}
	local hits, dead, ammo_used = {}, {}, {}
	local hp_left, alive = {}, {}
	local ammo = {}
	for i = 1, #defenders do
		local d = defenders[i]
		hp_left[d.id] = d.hp or 100
		alive[d.id] = true
		ammo[d.id] = d.ammo_have or 0
	end
	local barrier_score = spec.defense or 0
	local barrier_hp0 = spec.barrier_hp or 0
	local barrier_left = barrier_hp0
	local enclosure = U.clamp(spec.enclosure or 0, 0, 1)
	local wall_damage = 0
	local rounds = spec.rounds or CT.rounds
	local ran = 0
	local raider_mix = (mix.raider or 0) > 0

	for _ = 1, rounds do
		local A = M.mix_power(mix)
		if A <= 0 then break end
		-- defender strength this round
		local D, ranged_share, n_alive = 0, 0, 0
		for i = 1, #defenders do
			local d = defenders[i]
			if alive[d.id] then
				local p = (d.power or 0) * (d.ready or 1)
				if d.ranged then
					if ammo[d.id] >= CT.ammo_per_round then
						local use = CT.ammo_per_round
						ammo[d.id] = ammo[d.id] - use
						ammo_used[d.id] = (ammo_used[d.id] or 0) + use
						ranged_share = ranged_share + p
					else
						p = p * CT.out_of_ammo
					end
				end
				D = D + p
				n_alive = n_alive + 1
			end
		end
		if n_alive == 0 then break end
		ran = ran + 1
		local var = rng:range(CT.var_lo, CT.var_hi)
		-- killing: shooters get a bonus behind intact walls
		local bonus = 1 + (D > 0 and (ranged_share / D) or 0) * CT.ranged_wall_bonus * enclosure
		local kill = D * CT.k_kill * bonus * var
		local gone = remove_power(rng, mix, kill)
		for t, n in pairs(gone) do killed[t] = (killed[t] or 0) + n end -- order-free (integer sums)
		local A2 = M.mix_power(mix)
		-- damage to defenders (attackers that died this round still got their swings in: use mean power)
		local Aavg = (A + A2) / 2
		local barrier_eff = 0
		if barrier_hp0 > 0 then
			barrier_eff = barrier_score * (barrier_left / barrier_hp0) * (CT.barrier_enclosure_base + (1 - CT.barrier_enclosure_base) * enclosure)
		end
		local wall_mult = 1 / (1 + barrier_eff / CT.barrier_k)
		local dmg = Aavg * CT.k_damage * wall_mult * rng:range(CT.var_lo, CT.var_hi)
		if barrier_hp0 > 0 and barrier_left > 0 then
			local wear = U.min(barrier_left, Aavg * CT.wall_wear)
			barrier_left = barrier_left - wear
			wall_damage = wall_damage + wear
		end
		-- hits are quantized (a hit is about hit_hp); the fractional part is a chance of one more hit
		local n_hits = math.floor(dmg / CT.hit_hp)
		if rng:float() < dmg / CT.hit_hp - n_hits then n_hits = n_hits + 1 end
		if n_hits > 0 and dmg > 0 then
			local per = CT.hit_hp
			for _ = 1, n_hits do
				-- pick a random living defender
				local pool = {}
				for i = 1, #defenders do if alive[defenders[i].id] then pool[#pool + 1] = defenders[i].id end end
				if #pool == 0 then break end
				local id = rng:pick(pool)
				local kind
				if raider_mix and (mix.raider or 0) > 0 and rng:chance(CT.raider_bullet_share) then kind = "bullet"
				elseif rng:chance(CT.bite_share * (1 - CT.bite_enclosure_cut * enclosure)) then kind = "bite" else kind = "scratch" end
				hits[#hits + 1] = { id = id, kind = kind, amount = per }
				hp_left[id] = hp_left[id] - per
				if hp_left[id] <= 0 then
					alive[id] = false
					dead[#dead + 1] = id
				end
			end
		end
	end

	local left_n = M.mix_count(mix)
	local alive_n = 0
	for i = 1, #defenders do if alive[defenders[i].id] then alive_n = alive_n + 1 end end
	local outcome
	if left_n == 0 then outcome = "repelled"
	elseif alive_n == 0 and #defenders > 0 then outcome = "overrun"
	elseif #defenders == 0 then outcome = "overrun"
	else outcome = "stalemate" end
	return {
		attackers_left = mix, killed = killed, hits = hits, dead = dead, ammo_used = ammo_used,
		wall_damage = wall_damage, breached = (barrier_hp0 > 0 and barrier_left <= barrier_hp0 * CT.breach_hp_frac) or (barrier_hp0 <= 0),
		outcome = outcome, rounds_run = ran, screamers_left = mix.screamer or 0,
	}
end

return M
