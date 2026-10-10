-- world.lua : the orchestrator. world:tick(minutes) advances the sim and returns the ORDERED list of OUT
-- events for the adapter; world:handle(event) takes IN events from the adapter (see API.md).
--
-- All persistent state lives in plain data under `w.s` (serialized by save.lua). Everything under `w.rt`
-- is a derived cache (id indexes, reservations, event buffer) rebuilt by World.restore().
local U = require("sim.util")
local TUNING = require("data.tuning")
local DISTRICTS = require("data.districts")
local rng_mod = require("sim.rng")
local clock = require("sim.clock")
local items = require("sim.items")
local needs = require("sim.needs")
local mood = require("sim.mood")
local skills = require("sim.skills")
local traits = require("sim.traits")
local colonist = require("sim.colonist")
local stockpile = require("sim.stockpile")
local blueprints = require("sim.blueprints")
local grid = require("sim.grid")
local jobs = require("sim.jobs")
local expedition = require("sim.expedition")
local horde = require("sim.horde")
local factions = require("sim.factions")
local director = require("sim.director")
local loot = require("sim.loot")

local World = {}
World.__index = World
World.STATE_VERSION = 2

local W = TUNING.world
local floor = math.floor

-- ---------------------------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------------------------
local function base_pos() return { x = TUNING.base.x, y = TUNING.base.y, z = TUNING.base.z } end

-- opts = { seed, profile = "calm"|"escalating"|"chaos", colonists = n, max_dt, ambient = n, scenario = "default"|"empty" }
function World.new(opts)
	opts = opts or {}
	local seed = opts.seed or 1
	local w = setmetatable({}, World)
	w.s = {
		version = World.STATE_VERSION, seed = seed, profile = opts.profile or "calm", t = clock.at(1, TUNING.clock.start_hour, 0), day = 1,
		ids = {}, rngs = { master = rng_mod.new(seed) },
		colonists = {}, dead = {}, buildings = {}, zones = {}, piles = {}, containers = {}, board = { t = -1000, jobs = {} },
		vehicles = {}, exped = {}, hordes = {}, noise = {}, raids = {}, caravans = {}, factions = {},
		ledger = { created = {}, destroyed = {}, reasons = {} }, stats = {}, alert = 0, alert_until = 0, reanim = {}, history = {},
		player = { pos = nil, inv = items.new(TUNING.player.carry_g, TUNING.player.slots), needs = nil }, over = false,
	}
	w.rt = { out = nil, pending = {}, idx = { c = {}, b = {}, p = {}, z = {} }, res = {}, max_dt = opts.max_dt or TUNING.sim.max_dt,
		env = { rng = nil }, menv = { ctx = {} }, tmp = {} }
	grid.init(w)
	expedition.init_vehicles(w)
	factions.init(w)
	director.init(w, w.s.profile)
	if (opts.scenario or "default") ~= "empty" then w:setup_default(opts) end
	return w
end

-- rebuild every derived cache from plain state (after a load, or after tests edit state directly)
function World.restore(state)
	local w = setmetatable({}, World)
	w.s = state
	w.rt = { out = nil, pending = {}, idx = { c = {}, b = {}, p = {}, z = {} }, res = {}, max_dt = TUNING.sim.max_dt,
		env = { rng = nil }, menv = { ctx = {} }, tmp = {} }
	w:rebuild()
	return w
end

function World:rebuild()
	local s = self.s
	for _, name in ipairs(U.keys(s.rngs)) do rng_mod.attach(s.rngs[name]) end
	local idx = { c = {}, b = {}, p = {}, z = {} }
	for i = 1, #s.colonists do idx.c[s.colonists[i].id] = s.colonists[i]; items.rebuild(s.colonists[i].inv) end
	for i = 1, #s.buildings do idx.b[s.buildings[i].id] = s.buildings[i]; items.rebuild(s.buildings[i].delivered) end
	for i = 1, #s.piles do idx.p[s.piles[i].id] = s.piles[i]; items.rebuild(s.piles[i].items) end
	for i = 1, #s.zones do idx.z[s.zones[i].id] = s.zones[i]; items.rebuild(s.zones[i].items) end
	for _, k in ipairs(U.keys(s.containers)) do items.rebuild(s.containers[k].items) end
	items.rebuild(s.player.inv)
	for i = 1, #s.exped do items.rebuild(s.exped[i].loot) end
	for i = 1, #s.caravans do items.rebuild(s.caravans[i].stock) end
	for i = 1, #s.raids do items.rebuild(s.raids[i].loot) end
	self.rt.idx = idx
	jobs.rebuild_res(self)
end

function World:setup_default(opts)
	local s = self.s
	local b = TUNING.base
	-- storage
	local mz = W.main_zone
	local z1 = stockpile.new(self:new_id("z"), "Main store", { x = b.x + mz.x, y = b.y + mz.y, z = b.z }, mz.tiles, mz.prio, {})
	z1.main = true
	self:add_zone(z1)
	local mdz = W.med_zone
	local z2 = stockpile.new(self:new_id("z"), "Medical shelf", { x = b.x + mdz.x, y = b.y + mdz.y, z = b.z }, mdz.tiles, mdz.prio,
		{ cats = { medical = true, ammo = true } })
	self:add_zone(z2)
	-- starting stock
	for _, id in ipairs(U.keys(W.start_items)) do
		local zone = stockpile.find_dest(s.zones, id, z1.pos)
		self:create((zone or z1).items, id, W.start_items[id], "start")
	end
	-- pre-built furniture
	for i = 1, #W.start_buildings do
		local sb = W.start_buildings[i]
		local bd = blueprints.place(self, sb[1], { x = b.x + sb[2], y = b.y + sb[3], z = b.z })
		if bd then blueprints.complete(self, bd) end
	end
	-- people
	local n = opts.colonists or TUNING.colonist.start_count
	local focus = { "medicine", "construction", "shooting", "scavenging", "cooking", "melee" }
	local rng = self:rng("setup")
	for i = 1, n do
		local c = colonist.new(rng, { id = self:new_id("c"), focus = focus[(i - 1) % #focus + 1], joined = s.t,
			pos = { x = b.x + rng:range(-12, 12), y = b.y + rng:range(-12, 12), z = b.z } })
		self:add_colonist(c)
		if i % 3 == 1 then
			self:create(c.inv, "pistol", 1, "start")
			self:create(c.inv, "ammo_9mm", 30, "start")
		elseif i % 3 == 2 then
			self:create(c.inv, "machete", 1, "start")
		else
			self:create(c.inv, "baseball_bat", 1, "start")
		end
		self:emit({ type = "colonist_joined", id = c.id, name = c.name, pos = U.pos_copy(c.pos), traits = U.copy(c.traits), start = true })
	end
	self:refresh_caps()
	horde.seed_ambient(self, opts.ambient or TUNING.horde.ambient_count)
end

-- ---------------------------------------------------------------------------------------------
-- plumbing
-- ---------------------------------------------------------------------------------------------
function World:rng(name)
	local r = self.s.rngs[name]
	if not r then
		r = self.s.rngs.master:fork(name)
		self.s.rngs[name] = r
	end
	return r
end

function World:new_id(prefix) return U.next_id(self.s.ids, prefix) end

function World:emit(ev)
	ev.t = self.s.t
	local out = self.rt.out or self.rt.pending
	out[#out + 1] = ev
end

function World:notify(level, text)
	self:emit({ type = "notify", level = level, text = text })
end

function World:stat(name, n)
	local st = self.s.stats
	st[name] = (st[name] or 0) + n
end

-- item ledger: every item enters the world through create() and leaves through destroy()
function World:create(cont, id, n, reason)
	local added = items.add(cont, id, n)
	if added > 0 then
		local l = self.s.ledger
		l.created[id] = (l.created[id] or 0) + added
		local k = "+" .. reason
		l.reasons[k] = (l.reasons[k] or 0) + added
	end
	return added
end

function World:destroy(cont, id, n, reason)
	local removed = items.remove(cont, id, n)
	if removed > 0 then
		local l = self.s.ledger
		l.destroyed[id] = (l.destroyed[id] or 0) + removed
		local k = "-" .. reason
		l.reasons[k] = (l.reasons[k] or 0) + removed
	end
	return removed
end

-- Every container that can hold items: { { label, container }, ... } in deterministic order
function World:all_containers()
	local s = self.s
	local list = {}
	for i = 1, #s.colonists do list[#list + 1] = { "colonist:" .. s.colonists[i].id, s.colonists[i].inv } end
	for i = 1, #s.zones do list[#list + 1] = { "zone:" .. s.zones[i].id, s.zones[i].items } end
	for i = 1, #s.piles do list[#list + 1] = { "pile:" .. s.piles[i].id, s.piles[i].items } end
	for i = 1, #s.buildings do list[#list + 1] = { "site:" .. s.buildings[i].id, s.buildings[i].delivered } end
	list[#list + 1] = { "player", s.player.inv }
	for _, k in ipairs(U.keys(s.containers)) do list[#list + 1] = { "container:" .. k, s.containers[k].items } end
	for i = 1, #s.exped do list[#list + 1] = { "exped:" .. s.exped[i].id, s.exped[i].loot } end
	for i = 1, #s.caravans do list[#list + 1] = { "caravan:" .. s.caravans[i].id, s.caravans[i].stock } end
	for i = 1, #s.raids do list[#list + 1] = { "raid:" .. s.raids[i].id, s.raids[i].loot } end
	return list
end

-- Conservation check: the items found in every container must equal created - destroyed, per item id.
-- Returns ok, report ({ problems = {...}, totals = {id=n} }).
function World:audit()
	local have, problems = {}, {}
	local list = self:all_containers()
	for i = 1, #list do
		local label, cont = list[i][1], list[i][2]
		local ok, err = items.check(cont)
		if not ok then problems[#problems + 1] = label .. ": " .. err end
		for id, n in pairs(cont.items) do have[id] = (have[id] or 0) + n end -- order-free
	end
	local l = self.s.ledger
	local ids = {}
	for id in pairs(have) do ids[id] = true end -- order-free
	for id in pairs(l.created) do ids[id] = true end -- order-free
	for id in pairs(l.destroyed) do ids[id] = true end -- order-free
	for _, id in ipairs(U.keys(ids)) do
		local expect = (l.created[id] or 0) - (l.destroyed[id] or 0)
		local got = have[id] or 0
		if expect ~= got then problems[#problems + 1] = string.format("%s: ledger says %d, containers hold %d", id, expect, got) end
		if got < 0 then problems[#problems + 1] = id .. ": negative total" end
	end
	return #problems == 0, { problems = problems, totals = have }
end

-- ---------------------------------------------------------------------------------------------
-- entity access
-- ---------------------------------------------------------------------------------------------
function World:colonist(id) return self.rt.idx.c[id] end
function World:building(id) return self.rt.idx.b[id] end
function World:pile(id) return self.rt.idx.p[id] end
function World:zone(id) return self.rt.idx.z[id] end

function World:add_colonist(c)
	self.s.colonists[#self.s.colonists + 1] = c
	self.rt.idx.c[c.id] = c
end

function World:remove_colonist(c)
	local cs = self.s.colonists
	for i = 1, #cs do
		if cs[i] == c then table.remove(cs, i); break end
	end
	self.rt.idx.c[c.id] = nil
end

function World:add_zone(z)
	self.s.zones[#self.s.zones + 1] = z
	self.rt.idx.z[z.id] = z
end

function World:add_building(b)
	self.s.buildings[#self.s.buildings + 1] = b
	self.rt.idx.b[b.id] = b
end

function World:remove_building(b)
	local bs = self.s.buildings
	for i = 1, #bs do
		if bs[i] == b then table.remove(bs, i); break end
	end
	self.rt.idx.b[b.id] = nil
	-- leftover delivered materials go to a pile so nothing vanishes
	if not items.is_empty(b.delivered) then
		local pile = self:pile_for(b.pos)
		for _, it in ipairs(items.list(b.delivered)) do items.transfer(b.delivered, pile.items, it.id, it.n) end
	end
	self:refresh_caps()
	self.rt.grid_dirty = true
end

function World:building_changed(b, what)
	self:refresh_caps()
	self.rt.grid_dirty = true
end

-- the main stockpile zone grows with finished crates
function World:refresh_caps()
	local bonus = blueprints.storage_bonus(self)
	for i = 1, #self.s.zones do
		local z = self.s.zones[i]
		if z.main then stockpile.set_cap(z, z.tiles, bonus) end
	end
end

function World:pile_for(pos)
	local s = self.s
	for i = 1, #s.piles do
		local p = s.piles[i]
		if U.dist2(p.pos.x, p.pos.y, pos.x, pos.y) <= W.pile_merge_dist then return p end
	end
	local p = { id = self:new_id("p"), pos = U.pos_copy(pos), items = items.new(), created = s.t }
	s.piles[#s.piles + 1] = p
	self.rt.idx.p[p.id] = p
	return p
end

function World:remove_pile(p)
	local ps = self.s.piles
	for i = 1, #ps do
		if ps[i] == p then table.remove(ps, i); break end
	end
	self.rt.idx.p[p.id] = nil
end

function World:water_pos()
	local list = blueprints.list_tag(self, "water", true)
	if #list > 0 then return list[1].pos end
	return { x = TUNING.base.x - 10, y = TUNING.base.y + 10, z = TUNING.base.z }
end

function World:garage_pos() return TUNING.base.garage end

function World:district_pos(id)
	local d = DISTRICTS[id]
	return { x = d.x, y = d.y, z = TUNING.base.z }
end

function World:observers()
	local obs = {}
	local p = self.s.player
	if p.pos then obs[#obs + 1] = { x = p.pos.x, y = p.pos.y } end
	if TUNING.horde.observe_colonists then
		local cs = self.s.colonists
		for i = 1, #cs do
			if not cs[i].dead and cs[i].state ~= "away" then obs[#obs + 1] = { x = cs[i].pos.x, y = cs[i].pos.y } end
		end
	end
	return obs
end

function World:noise(pos, loud, kind) return horde.noise(self, pos, loud, kind) end

-- ---------------------------------------------------------------------------------------------
-- people
-- ---------------------------------------------------------------------------------------------
function World:add_thought(c, id, mult)
	if not c.dead then mood.add(c, id, self.s.t, mult) end
end

function World:add_thought_all(id, except)
	local cs = self.s.colonists
	for i = 1, #cs do
		if cs[i] ~= except and not cs[i].dead then mood.add(cs[i], id, self.s.t) end
	end
end

-- damage a colonist. Death/downed are resolved by process_vitals (called by the step or the caller).
function World:wound(c, kind, amount, part)
	if c.dead then return nil end
	local info = needs.wound(c, self:rng("injury"), kind, amount, part)
	if kind == "bite" then self:add_thought(c, "bitten") end
	c.dirty = true
	c.report = true
	return info
end

function World:process_vitals(c)
	local ev = needs.check_vitals(c)
	if ev then self:handle_need_events(c, { ev }) end
end

local function describe_break(kind)
	if kind == "refuse" then return "refuses to work" elseif kind == "binge" then return "goes on a binge" end
	return "wanders off"
end

function World:handle_need_events(c, evs)
	for i = 1, #evs do
		local e = evs[i]
		local k = e.kind
		if k == "died" then
			self:kill_colonist(c, e.cause, e.turns)
			return
		elseif k == "downed" then
			c.dirty = true; c.report = true
			self:notify("bad", string.format("%s is down!", c.name))
			self:add_thought(c, "close_call")
		elseif k == "recovered" then
			c.dirty = true; c.report = true
		elseif k == "starving" then
			c.dirty = true
			self:notify("warn", string.format("%s is starving.", c.name))
		elseif k == "dehydrated" then
			c.dirty = true
			self:notify("warn", string.format("%s is badly dehydrated.", c.name))
		elseif k == "collapse" then
			c.dirty = true
		elseif k == "infection_symptomatic" then
			c.dirty = true; c.report = true
			self:notify("warn", string.format("%s has a fever.", c.name))
			self:add_thought_all("infected_fear", c)
		elseif k == "infection_terminal" then
			c.dirty = true; c.report = true
			self:notify("bad", string.format("%s is getting much worse.", c.name))
		end
	end
end

-- remove a colonist from the sim after death. cause: string; turns: will reanimate
function World:kill_colonist(c, cause, turns)
	local s = self.s
	if not self.rt.idx.c[c.id] then return end
	c.dead = true
	c.cause = cause
	local away = (c.state == "away")
	jobs.release_colonist(self, c)
	expedition.on_colonist_removed(self, c)
	-- belongings stay where they fell: a pile at the body (or lost with an expedition)
	if not items.is_empty(c.inv) then
		if away then
			for _, it in ipairs(items.list(c.inv)) do self:destroy(c.inv, it.id, it.n, "lost") end
		else
			local pile = self:pile_for(c.pos)
			for _, it in ipairs(items.list(c.inv)) do items.transfer(c.inv, pile.items, it.id, it.n) end
		end
	end
	self:remove_colonist(c)
	s.dead[#s.dead + 1] = { id = c.id, name = c.name, cause = cause, t = s.t, day = clock.day(s.t), turns = turns == true }
	if #s.dead > W.max_dead_kept then table.remove(s.dead, 1) end
	self:stat("colonists_died", 1)
	self:emit({ type = "colonist_died", id = c.id, name = c.name, cause = cause, turns = turns == true, pos = U.pos_copy(c.pos) })
	self:notify("bad", string.format("%s died (%s).", c.name, cause))
	for i = 1, #s.colonists do
		local o = s.colonists[i]
		self:add_thought(o, "friend_died")
		if not away and o.state ~= "away" then self:add_thought(o, "saw_death") end
		o.dirty = true
	end
	if turns then
		local rng = self:rng("injury")
		local d = TUNING.needs.infection.turn_delay
		s.reanim[#s.reanim + 1] = { t = s.t + rng:int(d[1], d[2]), x = c.pos.x, y = c.pos.y, z = c.pos.z, name = c.name, id = c.id }
	end
	if #s.colonists == 0 and not s.over then
		s.over = true
		self:emit({ type = "game_over", reason = "all_colonists_lost", day = clock.day(s.t) })
		self:notify("bad", "The last colonist is gone. The colony has fallen.")
	end
end

-- a colonist leaves the colony alive (wandered off / lost on a run)
function World:colonist_leaves(c, why)
	local s = self.s
	if not self.rt.idx.c[c.id] then return end
	local away = (c.state == "away")
	jobs.release_colonist(self, c)
	expedition.on_colonist_removed(self, c)
	if not items.is_empty(c.inv) then
		if away then
			for _, it in ipairs(items.list(c.inv)) do self:destroy(c.inv, it.id, it.n, "lost") end
		else
			local pile = self:pile_for(c.pos)
			for _, it in ipairs(items.list(c.inv)) do items.transfer(c.inv, pile.items, it.id, it.n) end
		end
	end
	c.dead = true -- gone from the sim (not a death: no cause, no reanimation)
	c.cause = why
	self:remove_colonist(c)
	s.dead[#s.dead + 1] = { id = c.id, name = c.name, cause = why, t = s.t, day = clock.day(s.t), turns = false, left = true }
	if #s.dead > W.max_dead_kept then table.remove(s.dead, 1) end
	self:stat("colonists_left", 1)
	self:emit({ type = "colonist_left", id = c.id, name = c.name, why = why })
	self:notify("bad", string.format("%s is gone (%s).", c.name, why))
	for i = 1, #s.colonists do self:add_thought(s.colonists[i], "friend_died", 0.5) end
	if #s.colonists == 0 and not s.over then
		s.over = true
		self:emit({ type = "game_over", reason = "all_colonists_lost", day = clock.day(s.t) })
	end
end

-- a new survivor joins (director event). Returns the colonist.
function World:add_refugee()
	local s = self.s
	if #s.colonists >= TUNING.colonist.max_count then return nil end
	local rng = self:rng("refugee")
	local b = TUNING.base
	local dv = horde.DIRS[rng:int(1, #horde.DIRS)]
	local c = colonist.new(rng, { id = self:new_id("c"), joined = s.t,
		pos = { x = b.x + dv[1] * (b.radius + 20), y = b.y + dv[2] * (b.radius + 20), z = b.z } })
	self:add_colonist(c)
	for _, id in ipairs(U.keys(W.refugee_items)) do self:create(c.inv, id, W.refugee_items[id], "refugee") end
	if rng:chance(W.refugee_armed_chance) then self:create(c.inv, "baseball_bat", 1, "refugee") end
	local infected = false
	if rng:chance(TUNING.director.refugee_infected_chance) then
		needs.wound(c, rng, "scratch", 2, "arm")
		infected = needs.infect(c, rng, "arm")
	end
	self:emit({ type = "colonist_joined", id = c.id, name = c.name, pos = U.pos_copy(c.pos), traits = U.copy(c.traits), start = false })
	self:notify("info", string.format("%s from the camps asks to join.", c.name))
	self:add_thought_all("new_arrival", c)
	self:stat("refugees", 1)
	return c, infected
end

function World:on_attack_repelled(kind, size)
	self:stat("attacks_repelled", 1)
	local cs = self.s.colonists
	local th = (kind == "raid") and "raid_repelled" or "survived_attack"
	for i = 1, #cs do
		if cs[i].state ~= "away" then self:add_thought(cs[i], th) end
	end
end

function World:on_power_lost()
	self:add_thought_all("lights_out")
end

-- ---------------------------------------------------------------------------------------------
-- time stepping
-- ---------------------------------------------------------------------------------------------
function World:update_alert(dt)
	local s = self.s
	local near = horde.threat_near(self)
	if not near then
		for i = 1, #s.raids do
			local r = s.raids[i]
			if U.dist2(r.x, r.y, TUNING.base.x, TUNING.base.y) <= TUNING.base.alert_radius then near = true; break end
		end
	end
	if near then
		if s.alert == 0 then
			s.alert = 1
			self:emit({ type = "play_alert", kind = "horde_near" })
			self:add_thought_all("horde_near")
			for i = 1, #s.colonists do s.colonists[i].dirty = true end
		end
		s.alert_until = s.t + TUNING.horde.alert_hold
	elseif s.alert > 0 and s.t >= s.alert_until then
		s.alert = 0
		for i = 1, #s.colonists do s.colonists[i].dirty = true end
	end
end

function World:update_reanim()
	local s = self.s
	local i = 1
	while i <= #s.reanim do
		local r = s.reanim[i]
		if s.t >= r.t then
			table.remove(s.reanim, i)
			self:emit({ type = "colonist_turned", id = r.id, name = r.name, pos = { x = r.x, y = r.y, z = r.z } })
			horde.spawn(self, { x = r.x, y = r.y, mix = { walker = 1 }, src = "turned" })
		else
			i = i + 1
		end
	end
end

function World:on_new_day()
	local s = self.s
	local day = s.day
	self:emit({ type = "day_start", day = day })
	local _, _, enclosure = blueprints.defense(self)
	if enclosure >= 0.8 then self:add_thought_all("secure_walls") end
	-- one history row per day (bounded) for reports and balance tooling
	local n = #s.colonists
	local msum = 0
	for i = 1, n do msum = msum + s.colonists[i].mood end
	local tot = stockpile.totals(s.zones)
	local food = 0
	for id, k in pairs(tot) do -- order-free
		local d = items.defs[id]
		if d.food and (d.food.hunger or 0) >= 8 then food = food + k end
	end
	s.history[#s.history + 1] = { day = day - 1, colonists = n, mood = (n > 0) and msum / n or 0, food = food,
		water = (tot.water_bottle or 0), wealth = director.wealth(self), budget = s.director.budget }
	if #s.history > 60 then table.remove(s.history, 1) end
	-- forget adapter containers that were emptied long ago (they regenerate on the next open anyway)
	local respawn = W.container_respawn_days * 1440
	for _, k in ipairs(U.keys(s.containers)) do
		local c = s.containers[k]
		if items.is_empty(c.items) and s.t - c.gen_t >= respawn then s.containers[k] = nil end
	end
end

function World:update_colonists(dt)
	local s = self.s
	local now = s.t
	local cs = s.colonists
	local n = #cs
	if n == 0 then return end
	local tmp = self.rt.tmp
	for i = 1, n do tmp[i] = cs[i] end
	for i = n + 1, #tmp do tmp[i] = nil end
	local env, menv = self.rt.env, self.rt.menv
	env.rng = self:rng("needs")
	menv.rng = self:rng("mood")
	menv.ctx.colonists = n
	-- is there food in stock? (cheap proxy used for binge breaks)
	menv.food_available = stockpile.cat_total(s.zones, "food") > 0
	local start = floor(now / dt) % n
	for k = 0, n - 1 do
		local c = tmp[(start + k) % n + 1]
		if not c.dead then
			env.now = now
			env.activity = c.downed and "rest" or jobs.activity_for(c)
			local j = c.job
			env.rest_q = (j and j.data and j.data.q) or 1
			env.heal_mult = 1
			if j and j.data and j.data.bed then
				local bd = self:building(j.data.bed)
				if bd and require("data.blueprints")[bd.bp].tags.med_bed then env.heal_mult = bd.powered and 1.8 or 1.3 end
			end
			local ev = needs.step(c, dt, env)
			if ev then self:handle_need_events(c, ev) end
			if not c.dead then
				local mev = mood.step(c, now, dt, menv)
				if mev then
					local e = mev[1]
					c.dirty = true
					c.report = true
					if e.kind == "break_start" then
						self:notify("warn", string.format("%s snaps and %s.", c.name, describe_break(e.break_kind)))
						self:stat("mental_breaks", 1)
					end
				end
				jobs.update(self, c, dt, k)
			end
		end
	end
	-- colonist_state reports: on change, plus a slow heartbeat
	cs = s.colonists
	for i = 1, #cs do
		local c = cs[i]
		local since = now - (c.report_t or -1e9)
		if (c.report and since >= 3) or since >= TUNING.sim.state_report_min then
			c.report = false
			c.report_t = now
			local v = colonist.view(c, now)
			v.type = "colonist_state"
			self:emit(v)
		end
	end
end

function World:step(dt)
	local s = self.s
	s.t = s.t + dt
	local now = s.t
	local day = clock.day(now)
	if day ~= s.day then
		s.day = day
		self:on_new_day()
	end
	grid.step(self, dt)
	horde.step(self, dt)
	factions.step(self, dt)
	expedition.step(self, dt)
	director.step(self, dt)
	self:update_alert(dt)
	self:update_reanim()
	if now % 60 < dt then
		local gens = blueprints.list_tag(self, "generator", true)
		for i = 1, #gens do
			if gens[i].running then
				self:noise(gens[i].pos, TUNING.horde.noise.generator, "generator")
				break
			end
		end
	end
	if now - s.board.t >= TUNING.jobs.board_interval then jobs.refresh(self) end
	self:update_colonists(dt)
end

-- advance `minutes` (a positive integer) and return the ordered list of OUT events
function World:tick(minutes)
	minutes = floor(minutes)
	local out = self.rt.pending
	self.rt.pending = {}
	self.rt.out = out
	local remaining = minutes
	local max_dt = self.rt.max_dt
	while remaining > 0 do
		local dt = remaining < max_dt and remaining or max_dt
		self:step(dt)
		remaining = remaining - dt
	end
	self.rt.out = nil
	return out
end

-- IN events from the adapter (see API.md). Returns the list of OUT events produced.
function World:handle(ev)
	local out = self.rt.pending
	self.rt.pending = {}
	local prev = self.rt.out
	self.rt.out = out
	require("sim.handlers").handle(self, ev)
	self.rt.out = prev
	return out
end

-- events produced at construction / between ticks (not yet delivered)
function World:flush_events()
	local out = self.rt.pending
	self.rt.pending = {}
	return out
end

-- ---------------------------------------------------------------------------------------------
-- reporting
-- ---------------------------------------------------------------------------------------------
function World:alive_count() return #self.s.colonists end

function World:snapshot()
	local s = self.s
	local n = #s.colonists
	local msum, hurt = 0, 0
	for i = 1, n do
		msum = msum + s.colonists[i].mood
		if s.colonists[i].hp < s.colonists[i].hp_max * 0.7 then hurt = hurt + 1 end
	end
	local tot = stockpile.totals(s.zones)
	local food, drink = 0, 0
	for id, k in pairs(tot) do -- order-free
		local d = items.defs[id]
		if d.food and (d.food.hunger or 0) >= 8 then food = food + k end
		if d.food and (d.food.thirst or 0) >= 10 then drink = drink + k end
	end
	local defense, hp, enclosure = blueprints.defense(self)
	local hs = 0
	for i = 1, #s.hordes do hs = hs + s.hordes[i].size end
	return {
		day = clock.day(s.t), time = clock.fmt(s.t), colonists = n, mood = (n > 0) and msum / n or 0, hurt = hurt,
		food = food, drink = drink, wealth = director.wealth(self), budget = s.director.budget, alert = s.alert,
		hordes = #s.hordes, horde_size = hs, raids = #s.raids, defense = defense, enclosure = enclosure,
		power = s.grid.power.ok, water_tank = s.grid.water.tank, vehicles = #s.vehicles, expeditions = #s.exped,
		buildings = #s.buildings, over = s.over,
	}
end

function World:hash()
	return require("sim.save").hash_state(self.s)
end

return World
