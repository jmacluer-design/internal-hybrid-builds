-- expedition.lua : abstract scavenging trips by vehicle.
--
-- An expedition: { id, district, vehicle, state, want_crew, min_crew, crew = { colonist ids }, form_deadline,
--   t_out, t_loot, t_back (absolute minutes), loot = <container>, fuel_cans, flags }
-- States: forming (volunteers sign up via the `scavenge` work type) -> outbound -> looting -> returning
--         -> removed when done. An ambush can happen on the way out, while looting, and on the way back;
--         it is resolved with combat_abstract against the crew. Crew can be injured, infected, lost, or
--         wiped out (and then the loot and maybe the vehicle are gone).
local U = require("sim.util")
local TUNING = require("data.tuning")
local DISTRICTS = require("data.districts")
local items = require("sim.items")
local loot = require("sim.loot")
local combat = require("sim.combat_abstract")
local colonist = require("sim.colonist")
local skills = require("sim.skills")
local traits = require("sim.traits")
local clock = require("sim.clock")

local M = {}
local X = TUNING.expedition
local floor = math.floor

function M.districts() return U.keys(DISTRICTS) end

-- vehicles ------------------------------------------------------------------------------------
function M.init_vehicles(w)
	local s = w.s
	s.vehicles = {}
	for i = 1, #X.start_vehicles do
		local kind = X.start_vehicles[i]
		s.vehicles[#s.vehicles + 1] = { id = w:new_id("v"), kind = kind, hp = X.vehicles[kind].hp, state = "home" }
	end
end

function M.vehicle(w, id)
	local vs = w.s.vehicles
	for i = 1, #vs do if vs[i].id == id then return vs[i] end end
	return nil
end

function M.free_vehicle(w)
	local vs = w.s.vehicles
	for i = 1, #vs do
		if vs[i].state == "home" and vs[i].hp >= 20 then return vs[i] end
	end
	return nil
end

function M.fuel_cans_needed(district, vehicle_kind)
	local speed = X.vehicles[vehicle_kind].speed
	local round = 2 * district.travel / speed
	local n = math.ceil(round / X.fuel_min_per_can)
	if n < 1 then n = 1 end
	return n
end

local function crew_list(w, x)
	local out = {}
	for i = 1, #x.crew do
		local c = w:colonist(x.crew[i])
		if c then out[#out + 1] = c end
	end
	return out
end

-- chance of an ambush on one leg for this district and crew (0..1)
function M.risk(district, crew, night)
	local base = X.risk[district.danger]
	local lv, n = 0, 0
	for i = 1, #crew do
		lv = lv + skills.level(crew[i], "shooting") + skills.level(crew[i], "scavenging")
		n = n + 1
	end
	local avg = (n > 0) and lv / (n * 2) or 0
	local f = 1 - X.skill_risk_cut * avg * 2
	if f < X.risk_floor then f = X.risk_floor end
	local p = base * f
	if night then p = p * X.night_risk_mult end
	return U.clamp(p, 0, X.risk_cap)
end

function M.crew_strength(crew)
	local p = 0
	for i = 1, #crew do p = p + (select(1, colonist.combat_power(crew[i], 0))) end
	return p
end

-- plan an expedition. opts = { district, vehicle (id, optional), crew (ids, optional: leave out for open sign-up),
-- size (wanted crew when open), min_crew }. Returns expedition or nil, reason.
function M.plan(w, opts)
	local s = w.s
	local d = DISTRICTS[opts.district]
	if not d then return nil, "unknown_district" end
	local foot = (opts.mode == "foot")
	local v, cans
	if foot then
		if d.travel > X.foot.max_travel then return nil, "too_far_on_foot" end
		cans = 0
	else
		if opts.vehicle then v = M.vehicle(w, opts.vehicle) else v = M.free_vehicle(w) end
		if not v or v.state ~= "home" then return nil, "no_vehicle" end
		if v.hp < 20 then return nil, "vehicle_damaged" end
		for i = 1, #s.exped do if s.exped[i].vehicle == v.id then return nil, "vehicle_busy" end end
		cans = M.fuel_cans_needed(d, v.kind)
		local stock = 0
		for i = 1, #s.zones do stock = stock + (s.zones[i].items.items.fuel_can or 0) end
		if stock < cans then return nil, "no_fuel" end
	end
	local x = {
		id = w:new_id("x"), district = d.id, vehicle = v and v.id or "", mode = foot and "foot" or "vehicle", state = "forming", crew = {},
		want_crew = U.clamp(opts.size or 2, X.crew_min, X.crew_max), min_crew = opts.min_crew or X.crew_min,
		form_deadline = s.t + TUNING.jobs.sign_up_minutes, loot = items.new(foot and X.foot.trunk_g or X.vehicles[v.kind].trunk_g),
		fuel_cans = cans, planned = s.t, t_out = 0, t_loot = 0, t_back = 0, hurt = 0,
	}
	s.exped[#s.exped + 1] = x
	if v then v.state = "reserved" end
	if opts.crew then
		x.want_crew = #opts.crew
		for i = 1, #opts.crew do
			local c = w:colonist(opts.crew[i])
			if c and colonist.is_available(c) then M.join(w, x.id, c) end
		end
		if #x.crew == 0 then
			M.cancel(w, x.id, "no_crew")
			return nil, "no_crew"
		end
	end
	w:emit({ type = "notify", level = "info", text = string.format("Expedition to %s is forming (%d crew wanted%s).", d.name, x.want_crew, foot and ", on foot" or "") })
	return x
end

function M.find(w, id)
	local xs = w.s.exped
	for i = 1, #xs do if xs[i].id == id then return xs[i] end end
	return nil
end

-- a colonist volunteers. Returns false when the expedition is full / not forming.
function M.join(w, xid, c)
	local x = M.find(w, xid)
	if not x or x.state ~= "forming" or #x.crew >= x.want_crew or c.dead or c.state == "away" then return false end
	require("sim.jobs").release_colonist(w, c)
	x.crew[#x.crew + 1] = c.id
	c.state = "away"
	c.xid = x.id
	c.job = nil
	c.report = true
	local g = w:garage_pos()
	c.pos = U.pos_copy(g)
	return true
end

local function release_crew(w, x, arrive)
	for i = 1, #x.crew do
		local c = w:colonist(x.crew[i])
		if c and not c.dead then
			c.state = "idle"
			c.xid = nil
			c.dirty = true
			c.report = true
			if arrive then c.pos = U.pos_copy(w:garage_pos()) end
		end
	end
end

function M.cancel(w, id, why)
	local s = w.s
	for i = 1, #s.exped do
		local x = s.exped[i]
		if x.id == id then
			if x.state == "forming" then
				release_crew(w, x, false)
				local v = M.vehicle(w, x.vehicle)
				if v and v.state == "reserved" then v.state = "home" end
				table.remove(s.exped, i)
				w:emit({ type = "notify", level = "info", text = "Expedition cancelled (" .. (why or "cancelled") .. ")." })
				return true
			end
			return false
		end
	end
	return false
end

-- called by the world when a colonist dies / leaves: drop them from any crew list
function M.on_colonist_removed(w, c)
	for i = 1, #w.s.exped do
		local x = w.s.exped[i]
		for k = #x.crew, 1, -1 do
			if x.crew[k] == c.id then table.remove(x.crew, k) end
		end
	end
end

local function ambush_mix(rng, d)
	local base = floor(d.zombies * X.zombies_per_danger * rng:range(X.ambush_spread[1], X.ambush_spread[2]) + 0.5)
	if base < 2 then base = 2 end
	local mix = { walker = base }
	if d.danger >= 3 then mix.runner = floor(base * X.runner_share + rng:float()) end
	if d.danger >= 4 then mix.brute = floor(base * X.brute_share * (d.danger - 2) + rng:float()) end
	if d.danger >= 3 then mix.screamer = floor(base * X.screamer_share + rng:float()) end
	return mix
end

-- resolve one ambush against the living crew. Returns result (or nil when nobody is left).
local function ambush(w, x, where)
	local rng = w:rng("exped")
	local d = DISTRICTS[x.district]
	local crew = crew_list(w, x)
	local defenders = {}
	for i = 1, #crew do
		local c = crew[i]
		if not c.dead and not c.downed then
			local power, ranged, ammo = colonist.combat_power(c, w.s.t)
			defenders[#defenders + 1] = { id = c.id, power = power, ranged = ranged, ammo = ammo,
				ammo_have = ammo and (c.inv.items[ammo] or 0) or 0, hp = c.hp, ready = 1 }
		end
	end
	if #defenders == 0 then return nil end
	local res = combat.resolve(rng, { attackers = ambush_mix(rng, d), defenders = defenders, rounds = 8 })
	local hit_c = {}
	for i = 1, #res.hits do
		local h = res.hits[i]
		local c = w:colonist(h.id)
		if c then
			w:wound(c, h.kind, h.amount)
			hit_c[h.id] = true
		end
	end
	for id, n in pairs(res.ammo_used) do -- order-free (independent colonists)
		local c = w:colonist(id)
		if c then
			local def = nil
			local _, wd = colonist.best_weapon(c)
			if wd and wd.weapon.ammo then w:destroy(c.inv, wd.weapon.ammo, n, "combat") end
		end
	end
	local kills = combat.mix_count(res.killed)
	w:stat("zombies_killed", kills)
	for i = 1, #crew do
		local c = crew[i]
		if not c.dead then
			skills.add_xp(c, "shooting", kills * TUNING.skills.xp_per_kill * X.xp_shoot_mult)
			skills.add_xp(c, "melee", kills * TUNING.skills.xp_per_kill * X.xp_melee_mult)
		end
	end
	for i = 1, #crew do w:process_vitals(crew[i]) end
	-- vehicle damage when it went badly
	local v = M.vehicle(w, x.vehicle)
	if v and res.outcome ~= "repelled" then
		v.hp = v.hp - rng:int(X.vehicle_ambush_damage[1], X.vehicle_ambush_damage[2])
	end
	x.hurt = x.hurt + #res.hits
	if res.screamers_left > 0 then
		w:noise(w:district_pos(x.district), 90, "screamer")
	end
	return res
end

local function roll_ambush(w, x, where)
	local rng = w:rng("exped")
	local d = DISTRICTS[x.district]
	local crew = crew_list(w, x)
	local p = M.risk(d, crew, clock.is_night(w.s.t))
	if x.mode == "foot" then p = U.min(X.risk_cap, p * X.foot.risk_mult) end
	if not rng:chance(p) then return nil end
	local res = ambush(w, x, where)
	if res and res.outcome ~= "repelled" then
		-- survivors may be separated from the group
		local lc = X.lost_chance[d.danger]
		local survivors = crew_list(w, x)
		for i = 1, #survivors do
			local c = survivors[i]
			if not c.dead and rng:chance(lc) then
				w:notify("bad", string.format("%s was separated from the group and is missing.", c.name))
				-- anything they carried goes into the loot bin (or is lost with them)
				for _, it in ipairs(items.list(c.inv)) do items.transfer(c.inv, x.loot, it.id, it.n) end
				w:colonist_leaves(c, "lost_on_run")
			end
		end
	end
	return res
end

local function depart(w, x)
	local s = w.s
	local rng = w:rng("exped")
	local d = DISTRICTS[x.district]
	local v = M.vehicle(w, x.vehicle)
	if v then
		-- pay the fuel
		local left = x.fuel_cans
		for i = 1, #s.zones do
			if left <= 0 then break end
			local got = w:destroy(s.zones[i].items, "fuel_can", left, "fuel")
			left = left - got
		end
		if left > 0 then -- the fuel was taken while we were forming: abort
			M.cancel(w, x.id, "no_fuel")
			return
		end
	end
	local speed = v and X.vehicles[v.kind].speed or X.foot.speed
	local var = X.trip_variance
	local out = d.travel / speed * rng:range(var[1], var[2])
	local look = rng:int(X.loot_minutes[1], X.loot_minutes[2]) * (d.radius / 260)
	local back = d.travel / speed * rng:range(var[1], var[2])
	x.state = "outbound"
	x.t_out = s.t + floor(out + 0.5)
	x.t_loot = x.t_out + floor(look + 0.5)
	x.t_back = x.t_loot + floor(back + 0.5)
	if v then v.state = "away" end
	w:emit({ type = "expedition", phase = "depart", id = x.id, district = d.id, vehicle = x.vehicle, mode = x.mode, crew = U.copy(x.crew),
		eta = x.t_back, pos = w:district_pos(d.id) })
	w:emit({ type = "notify", level = "info", text = string.format("Expedition to %s departs with %d crew%s.", d.name, #x.crew, x.mode == "foot" and " on foot" or "") })
end

local function finish(w, x, how)
	local s = w.s
	local v = M.vehicle(w, x.vehicle)
	local d = DISTRICTS[x.district]
	local crew = crew_list(w, x)
	local alive = 0
	for i = 1, #crew do if not crew[i].dead then alive = alive + 1 end end
	if how == "wiped" or alive == 0 then
		-- nobody came back: the loot is gone; the vehicle may be lost too
		for _, it in ipairs(items.list(x.loot)) do w:destroy(x.loot, it.id, it.n, "lost") end
		if v then
			if w:rng("exped"):chance(X.vehicle_lost_if_wiped) then
				for i = 1, #s.vehicles do if s.vehicles[i].id == v.id then table.remove(s.vehicles, i); break end end
				w:notify("bad", string.format("The expedition to %s never returned. The vehicle is gone.", d.name))
			else
				v.state = "home"
				v.hp = U.max(1, v.hp - 30)
				w:notify("bad", string.format("The expedition to %s was wiped out. The vehicle limped home empty.", d.name))
			end
		end
		w:emit({ type = "expedition", phase = "lost", id = x.id, district = d.id })
	else
		if v then v.state = "home" end
		local bundle = {}
		local pile
		if not items.is_empty(x.loot) then
			pile = w:pile_for(w:garage_pos())
			for _, it in ipairs(items.list(x.loot)) do
				local moved = items.transfer(x.loot, pile.items, it.id, it.n)
				if moved > 0 then bundle[it.id] = (bundle[it.id] or 0) + moved end
			end
		end
		release_crew(w, x, true)
		w:emit({ type = "loot_spawn", container = pile and ("pile:" .. pile.id) or "none", items = bundle, source = "expedition",
			expedition = x.id, district = d.id, pos = U.pos_copy(pile and pile.pos or w:garage_pos()) })
		w:emit({ type = "expedition", phase = "return", id = x.id, district = d.id, crew = U.copy(x.crew), loot = bundle })
		w:notify("info", string.format("Expedition back from %s: %d crew, %d items.", d.name, alive, U.sum_map(bundle)))
		w:stat("expeditions_done", 1)
		-- anyone hurt on the way gets a thought
		for i = 1, #crew do
			local c = crew[i]
			if not c.dead and #c.wounds > 0 then w:add_thought(c, "close_call") end
		end
	end
	for i = 1, #s.exped do if s.exped[i].id == x.id then table.remove(s.exped, i); break end end
end

-- advance every expedition
function M.step(w, dt)
	local s = w.s
	local now = s.t
	local rng = w:rng("exped")
	-- vehicles heal slowly at home when there is a workbench
	for i = 1, #s.vehicles do
		local v = s.vehicles[i]
		if v.state == "home" and v.hp < X.vehicles[v.kind].hp then
			v.hp = U.min(X.vehicles[v.kind].hp, v.hp + X.vehicle_repair_per_min * dt)
		end
	end
	local i = 1
	while i <= #s.exped do
		local x = s.exped[i]
		local before = #s.exped
		if x.state == "forming" then
			if #x.crew >= x.want_crew or (now >= x.form_deadline and #x.crew >= x.min_crew) then
				depart(w, x)
			elseif now >= x.form_deadline then
				M.cancel(w, x.id, "nobody volunteered")
			end
		elseif x.state == "outbound" then
			if now >= x.t_out then
				local res = roll_ambush(w, x, "out")
				if #crew_list(w, x) == 0 then
					finish(w, x, "wiped")
				else
					x.state = "looting"
					w:emit({ type = "expedition", phase = "arrive", id = x.id, district = x.district, pos = w:district_pos(x.district) })
				end
			end
		elseif x.state == "looting" then
			if now >= x.t_loot then
				local d = DISTRICTS[x.district]
				local crew = crew_list(w, x)
				local lv, luck = 0, 0
				for k = 1, #crew do
					lv = lv + skills.level(crew[k], "scavenging")
					luck = luck + traits.add(crew[k], "loot_luck")
				end
				local lr = X.loot_rolls
				local rolls = rng:int(lr[1], lr[2]) + floor(lv / X.loot_per_scav_levels)
				if rng:chance(X.cache_chance) then
					rolls = rolls + X.cache_rolls
					w:notify("info", "The crew found an untouched cache.")
				end
				local bundle = loot.roll(w:rng("loot"), d.loot, { danger = d.danger, luck = luck, rolls = rolls })
				for _, id in ipairs(U.keys(bundle)) do w:create(x.loot, id, bundle[id], "expedition") end
				local res = roll_ambush(w, x, "loot")
				if #crew_list(w, x) == 0 then
					finish(w, x, "wiped")
				else
					if rng:chance(X.breakdown_chance) then
						local extra = rng:int(X.breakdown_minutes[1], X.breakdown_minutes[2])
						x.t_back = x.t_back + extra
						w:notify("warn", string.format("The vehicle broke down on the way back (+%d min).", extra))
					end
					x.state = "returning"
				end
			end
		elseif x.state == "returning" then
			if now >= x.t_back then
				roll_ambush(w, x, "back")
				finish(w, x, (#crew_list(w, x) == 0) and "wiped" or "ok")
			end
		end
		if #s.exped == before then i = i + 1 end -- an entry was removed: stay on the same index
	end
end

return M
