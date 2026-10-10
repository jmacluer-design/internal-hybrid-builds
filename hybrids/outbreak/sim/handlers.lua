-- handlers.lua : IN events from the adapter (game -> sim). Dispatched by world:handle(event).
-- Every handler may emit OUT events through w:emit; player orders always answer with an `order_result`.
local U = require("sim.util")
local TUNING = require("data.tuning")
local DISTRICTS = require("data.districts")
local items = require("sim.items")
local colonist = require("sim.colonist")
local stockpile = require("sim.stockpile")
local blueprints = require("sim.blueprints")
local expedition = require("sim.expedition")
local horde = require("sim.horde")
local factions = require("sim.factions")
local director = require("sim.director")
local loot = require("sim.loot")
local clock = require("sim.clock")
local traits = require("sim.traits")

local M = {}
local H = {}
local floor = math.floor

local function is_pos(p)
	return type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" and p.x == p.x and p.y == p.y
end

local function result(w, ev, ok, reason, extra)
	local e = { type = "order_result", id = ev.id, kind = ev.kind, ok = ok, reason = reason or (ok and "ok" or "failed") }
	if extra then for k, v in pairs(extra) do e[k] = v end end -- order-free copy
	w:emit(e)
end

-- ---------------------------------------------------------------------------------------------
-- simple IN events
-- ---------------------------------------------------------------------------------------------
H.noise = function(w, ev)
	if not is_pos(ev.pos) then return end
	local loud = ev.loudness
	if type(loud) ~= "number" or loud ~= loud or loud <= 0 then return end
	horde.noise(w, { x = ev.pos.x, y = ev.pos.y, z = ev.pos.z or 0 }, U.min(loud, 400), ev.kind or "noise")
end

H.ped_damage = function(w, ev)
	local c = w:colonist(ev.id)
	if not c then return end
	if type(ev.amount) ~= "number" or ev.amount ~= ev.amount or ev.amount <= 0 then return end
	w:wound(c, ev.kind or "blunt", U.min(ev.amount, 500), ev.part)
	w:process_vitals(c)
end

H.ped_died = function(w, ev)
	local id = ev.id
	if type(id) ~= "string" then return end
	local c = w:colonist(id)
	if c then
		c.hp = 0
		local cause = ev.cause or "killed"
		local turns = c.inf.stage ~= "none" or cause == "zombies" or cause == "zombie"
		w:kill_colonist(c, cause, turns)
		return
	end
	if id:sub(1, 1) == "h" then horde.on_ped_died(w, id, ev.zkind)
	elseif id:sub(1, 1) == "r" then factions.on_ped_died(w, id)
	elseif id == "player" then w:stat("player_deaths", 1) end
end

H.player_state = function(w, ev)
	local p = w.s.player
	if is_pos(ev.pos) then p.pos = { x = ev.pos.x, y = ev.pos.y, z = ev.pos.z or 0 } end
	if type(ev.needs) == "table" then
		local n = {}
		for _, k in ipairs({ "hunger", "thirst", "fatigue", "hp", "infection" }) do
			if type(ev.needs[k]) == "number" or type(ev.needs[k]) == "string" then n[k] = ev.needs[k] end
		end
		p.needs = n
	end
end

H.horde_report = function(w, ev) if is_pos(ev.pos) then horde.report(w, ev.id, ev.pos) end end
H.raid_report = function(w, ev) if is_pos(ev.pos) then factions.report(w, ev.id, ev.pos) end end

H.colonist_ref = function(w, ev)
	local c = w:colonist(ev.id)
	if c then c.ref = ev.ref end
end

H.time_set = function(w, ev)
	local s = w.s
	local function num(v, default)
		v = tonumber(v)
		if v == nil or not U.finite(v) then return default end
		return v
	end
	local hour = U.clamp(floor(num(ev.hour, clock.hour(s.t))), 0, 23)
	local minute = U.clamp(floor(num(ev.minute, 0)), 0, 59)
	local day = U.clamp(floor(num(ev.day, clock.day(s.t))), 1, 100000)
	s.t = clock.at(day, hour, minute)
	s.day = clock.day(s.t)
	for i = 1, #s.colonists do s.colonists[i].dirty = true end
end

-- ---------------------------------------------------------------------------------------------
-- containers + item movement
-- ---------------------------------------------------------------------------------------------
local function generate_container(w, ref, ev, existing)
	local s = w.s
	local pos = ev.pos or { x = 0, y = 0, z = 0 }
	local tid = loot.table_for_container(ev.ctype or "house") or "residential"
	local dist = loot.nearest_district(pos)
	local danger = ev.danger or (dist and dist.danger) or 1
	local luck = 0
	if s.player.luck then luck = s.player.luck end
	local bundle = loot.roll(w:rng("loot"), tid, { danger = danger, luck = luck })
	local cont = existing or { ref = ref, items = items.new(), ctype = ev.ctype or "house" }
	cont.gen_t = s.t
	for _, id in ipairs(U.keys(bundle)) do w:create(cont.items, id, bundle[id], "container") end
	s.containers[ref] = cont
	local map = {}
	for _, it in ipairs(items.list(cont.items)) do map[it.id] = it.n end
	w:emit({ type = "loot_spawn", container = ref, items = map, ctype = cont.ctype, danger = danger, source = "container" })
end

H.container_opened = function(w, ev)
	local s = w.s
	local ref = ev.container
	if type(ref) ~= "string" or ref == "" then return end
	local cont = s.containers[ref]
	local respawn = TUNING.world.container_respawn_days * 1440
	if not cont then
		generate_container(w, ref, ev, nil)
	elseif items.is_empty(cont.items) and s.t - cont.gen_t >= respawn then
		generate_container(w, ref, ev, cont)
	else
		local map = {}
		for _, it in ipairs(items.list(cont.items)) do map[it.id] = it.n end
		w:emit({ type = "container_contents", container = ref, items = map })
	end
	if is_pos(ev.pos) then horde.noise(w, ev.pos, TUNING.horde.noise.loot, "loot") end
end

local function resolve_loc(w, loc, create_ok)
	if type(loc) ~= "table" then return nil end
	local k, id = loc.kind, loc.id
	if k == "void" then return "void" end
	if k == "player" then return w.s.player.inv end
	if k == "colonist" then local c = w:colonist(id); return c and c.inv end
	if k == "zone" then local z = w:zone(id); return z and z.items end
	if k == "pile" then local p = w:pile(id); return p and p.items end
	if k == "container" then
		if type(id) ~= "string" then return nil end
		local c = w.s.containers[id]
		if not c and create_ok then
			c = { ref = id, items = items.new(), ctype = "adapter", gen_t = w.s.t }
			w.s.containers[id] = c
		end
		return c and c.items
	end
	return nil
end

H.item_moved = function(w, ev)
	local out = { type = "item_result", item = ev.item, n = ev.n, ok = false, moved = 0 }
	if not items.exists(ev.item) or type(ev.n) ~= "number" or ev.n ~= floor(ev.n) or ev.n <= 0 then
		out.reason = "bad_item"; w:emit(out); return
	end
	local src = resolve_loc(w, ev.from, false)
	local dst = resolve_loc(w, ev.to, true)
	if not src or not dst or (src == "void" and dst == "void") then out.reason = "bad_location"; w:emit(out); return end
	local moved
	if src == "void" then
		moved = w:create(dst, ev.item, ev.n, "adapter")
	elseif dst == "void" then
		moved = w:destroy(src, ev.item, ev.n, "adapter")
	else
		moved = items.transfer(src, dst, ev.item, ev.n)
	end
	out.ok = moved > 0
	out.moved = moved
	out.reason = moved > 0 and "ok" or "nothing_moved"
	w:emit(out)
end

-- ---------------------------------------------------------------------------------------------
-- orders (player-issued): ev = { type = "order", id = colonist id | "colony", kind, target }
-- ---------------------------------------------------------------------------------------------
local O = {}

local function need_colonist(w, ev)
	local c = w:colonist(ev.id)
	if not c then result(w, ev, false, "no_such_colonist"); return nil end
	return c
end

O.priority = function(w, ev)
	local c = need_colonist(w, ev); if not c then return end
	local t = ev.target or {}
	local known = false
	for i = 1, #colonist.WORK do if colonist.WORK[i] == t.work then known = true end end
	if not known or type(t.level) ~= "number" then return result(w, ev, false, "bad_target") end
	local lvl = colonist.set_priority(c, t.work, t.level)
	c.dirty = true
	result(w, ev, true, lvl == t.level and "ok" or "clamped", { level = lvl })
end

O.draft = function(w, ev)
	local on = ev.target == true
	local list = {}
	if ev.id == "all" then
		for i = 1, #w.s.colonists do list[#list + 1] = w.s.colonists[i] end
	else
		local c = need_colonist(w, ev); if not c then return end
		list[1] = c
	end
	for i = 1, #list do
		list[i].drafted = on
		list[i].dirty = true
		list[i].report = true
	end
	result(w, ev, true, "ok", { count = #list })
end

O["goto"] = function(w, ev)
	local c = need_colonist(w, ev); if not c then return end
	if not is_pos(ev.target) then return result(w, ev, false, "bad_target") end
	c.orders = c.orders or {}
	c.orders[#c.orders + 1] = { kind = "goto", pos = { x = ev.target.x, y = ev.target.y, z = ev.target.z or 0 } }
	c.dirty = true
	result(w, ev, true)
end

O.equip = function(w, ev)
	local c = need_colonist(w, ev); if not c then return end
	local item = ev.target and ev.target.item
	if not item or not items.exists(item) or not (items.defs[item].weapon or items.defs[item].cat == "ammo") then
		return result(w, ev, false, "bad_item")
	end
	if stockpile.total(w.s.zones, item) <= 0 then return result(w, ev, false, "not_in_stock") end
	c.orders = c.orders or {}
	c.orders[#c.orders + 1] = { kind = "equip", item = item }
	c.dirty = true
	result(w, ev, true)
end

O.place_blueprint = function(w, ev)
	local t = ev.target or {}
	if type(t.bp) ~= "string" or not is_pos(t.pos) then return result(w, ev, false, "bad_target") end
	local b, why = blueprints.place(w, t.bp, { x = t.pos.x, y = t.pos.y, z = t.pos.z or 0 })
	if not b then return result(w, ev, false, why) end
	result(w, ev, true, "ok", { building = b.id })
end

O.cancel_blueprint = function(w, ev)
	local t = ev.target or {}
	local ok, why = blueprints.cancel(w, t.id)
	result(w, ev, ok, why)
end

O.expedition = function(w, ev)
	local t = ev.target or {}
	local x, why = expedition.plan(w, { district = t.district, size = t.size, crew = t.crew, vehicle = t.vehicle, mode = t.mode })
	if not x then return result(w, ev, false, why) end
	result(w, ev, true, "ok", { expedition = x.id })
end

O.cancel_expedition = function(w, ev)
	local ok = expedition.cancel(w, (ev.target or {}).id, "cancelled by order")
	result(w, ev, ok, ok and "ok" or "cannot_cancel")
end

O.schedule = function(w, ev)
	local c = need_colonist(w, ev); if not c then return end
	local t = ev.target
	local sched
	if type(t) == "string" and #t == 24 and not t:find("[^SWAJ]") then sched = t
	elseif type(t) == "string" and (t == "day" or t == "night" or t == "early") then sched = colonist.default_schedule(t) end
	if not sched then return result(w, ev, false, "bad_target") end
	c.sched = sched
	c.dirty = true
	result(w, ev, true)
end

O.zone_create = function(w, ev)
	local t = ev.target or {}
	if not is_pos(t.pos) then return result(w, ev, false, "bad_target") end
	local filter = {}
	if type(t.cats) == "table" then
		filter.cats = {}
		for _, c in ipairs(t.cats) do filter.cats[c] = true end
	end
	local z = stockpile.new(w:new_id("z"), t.name or "Stockpile", { x = t.pos.x, y = t.pos.y, z = t.pos.z or 0 },
		U.clamp(floor(t.tiles or 2), 1, 40), U.clamp(floor(t.prio or 3), 1, 5), filter)
	w:add_zone(z)
	result(w, ev, true, "ok", { zone = z.id })
end

O.zone_set = function(w, ev)
	local t = ev.target or {}
	local z = w:zone(t.id)
	if not z then return result(w, ev, false, "no_such_zone") end
	if t.prio then z.prio = U.clamp(floor(t.prio), 1, 5) end
	if type(t.cats) == "table" then
		z.filter.cats = {}
		for _, c in ipairs(t.cats) do z.filter.cats[c] = true end
	end
	result(w, ev, true)
end

O.trade = function(w, ev)
	local t = ev.target or {}
	local ok, why, gv, tv = factions.trade(w, t.caravan, t.give or {}, t.take or {})
	result(w, ev, ok, why, { give_value = gv, take_value = tv })
end

O.gift = function(w, ev)
	local t = ev.target or {}
	local ok, why = factions.gift(w, t.faction, t.give or {})
	result(w, ev, ok, why)
end

O.truce = function(w, ev)
	local t = ev.target or {}
	local ok, why = factions.truce(w, t.faction, t.give or {})
	result(w, ev, ok, why)
end

O.amputation = function(w, ev)
	local c = need_colonist(w, ev); if not c then return end
	c.allow_amputation = ev.target == true
	result(w, ev, true)
end

O.toggle_building = function(w, ev)
	local t = ev.target or {}
	local b = w:building(t.id)
	if not b then return result(w, ev, false, "no_such_building") end
	b.enabled = t.enabled ~= false
	w.rt.grid_dirty = true
	result(w, ev, true)
end

O.set_profile = function(w, ev)
	local ok = pcall(director.profile, ev.target)
	if not ok then return result(w, ev, false, "unknown_profile") end
	w.s.director.profile = ev.target
	w.s.profile = ev.target
	result(w, ev, true)
end

H.order = function(w, ev)
	local f = O[ev.kind]
	if not f then return result(w, ev, false, "unknown_order") end
	f(w, ev)
end

-- ---------------------------------------------------------------------------------------------
function M.handle(w, ev)
	if type(ev) ~= "table" or type(ev.type) ~= "string" then
		w:emit({ type = "error", reason = "bad_event" })
		return
	end
	local f = H[ev.type]
	if not f then
		w:emit({ type = "error", reason = "unknown_event", event = ev.type })
		return
	end
	f(w, ev)
end

M.handlers = H
M.orders = O

return M
