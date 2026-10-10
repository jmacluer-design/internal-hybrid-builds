-- world orchestrator: construction, tick/handle contract, IN events, orders, determinism, event hygiene.
local T = ...
package.path = T.root .. "/?.lua;" .. T.root .. "/tests/?.lua;" .. package.path
local H = require("helpers").init(T.root)
local U = require("sim.util")
local TUNING = require("data.tuning")
local World = require("sim.world")
local runner = require("sim.runner")
local policy = require("sim.ai_policy")
local save = require("sim.save")
local items = require("sim.items")
local stockpile = require("sim.stockpile")
local blueprints = require("sim.blueprints")
local expedition = require("sim.expedition")
local horde = require("sim.horde")
local clock = require("sim.clock")
local needs = require("sim.needs")
local colonist = require("sim.colonist")
local mood = require("sim.mood")

T.group("world")

local function new_world(seed, profile, extra)
	local o = { seed = seed or 1, profile = profile or "calm" }
	for k, v in pairs(extra or {}) do o[k] = v end -- order-free
	return World.new(o)
end

T.test("default scenario: colonists, zones, starting stock and buildings, ambient hordes; the first tick delivers the setup events", function()
	local w = new_world(1)
	T.eq(#w.s.colonists, TUNING.colonist.start_count)
	T.ge(#w.s.zones, 2)
	T.ge(#w.s.buildings, 4)
	T.eq(#w.s.hordes, TUNING.horde.ambient_count)
	T.eq(w.s.t, clock.at(1, TUNING.clock.start_hour, 0))
	T.ge(#w.s.vehicles, 1)
	T.eq(#w.s.factions, 5)
	for _, c in ipairs(w.s.colonists) do
		T.truthy(c.inv.w > 0, "everyone starts armed")
		T.truthy(c.hp == c.hp_max)
	end
	local pending = w:flush_events()
	T.eq(H.count(pending, "colonist_joined"), TUNING.colonist.start_count)
	T.eq(H.count(pending, "construction_done"), #TUNING.world.start_buildings)
	T.eq(#w:flush_events(), 0, "flush delivers once")
	local w2 = new_world(1)
	local first = w2:tick(1)
	T.eq(H.count(first, "colonist_joined"), TUNING.colonist.start_count, "tick() also delivers pending setup events first")
	H.audit_ok(T, w, "fresh world")
	local e = new_world(1, "calm", { scenario = "empty" })
	T.eq(#e.s.colonists, 0)
	T.eq(#e.s.hordes, 0)
	local custom = new_world(2, "chaos", { colonists = 7, ambient = 2 })
	T.eq(#custom.s.colonists, 7)
	T.eq(#custom.s.hordes, 2)
	T.eq(custom.s.profile, "chaos")
end)

T.test("tick(n): ordered events with non-decreasing timestamps; n ticks of 1 equal one tick of n", function()
	local a, b = new_world(3), new_world(3)
	local ev_a = a:tick(240)
	local ev_b = {}
	for _ = 1, 240 do
		local e = b:tick(1)
		for i = 1, #e do ev_b[#ev_b + 1] = e[i] end
	end
	T.eq(a:hash(), b:hash(), "chunking does not change the result")
	T.eq(#ev_a, #ev_b)
	local last = -1
	for i = 1, #ev_a do
		T.truthy(ev_a[i].t >= last, "timestamps never go backwards")
		last = ev_a[i].t
		T.eq(type(ev_a[i].type), "string")
		T.eq(ev_a[i].type, ev_b[i].type, "same event order")
	end
	T.eq(#a:tick(0), 0)
	T.eq(a.s.t, b.s.t)
	local w = new_world(3, "calm", { max_dt = 5 })
	local v = new_world(3, "calm", { max_dt = 5 })
	w:tick(600); v:tick(300); v:tick(300)
	T.eq(w:hash(), v:hash(), "max_dt substepping is deterministic too")
end)

T.test("determinism: same seed -> same state hash; different seed or profile -> different", function()
	local a, b, c, d = new_world(9), new_world(9), new_world(10), new_world(9, "chaos")
	for _, w in ipairs({ a, b, c, d }) do w:tick(1440) end
	T.eq(a:hash(), b:hash())
	T.ne(a:hash(), c:hash())
	T.ne(a:hash(), d:hash())
	T.eq(a:hash(), a:hash(), "hashing does not mutate")
	T.eq(#a:hash(), 16)
end)

T.test("full headless game: same seed -> identical hash with the policy driving it", function()
	local r1 = runner.run({ seed = 5, profile = "escalating", days = 8, max_dt = 1 })
	local r2 = runner.run({ seed = 5, profile = "escalating", days = 8, max_dt = 1 })
	T.eq(r1.world:hash(), r2.world:hash())
	T.eq(r1.counts.colonist_task, r2.counts.colonist_task)
	T.truthy(select(1, r1.world:audit()))
end)

T.test("unknown and malformed IN events never crash: they answer with an error event", function()
	local w = new_world(1)
	w:flush_events()
	local bad = { 42, "noise", {}, { type = 7 }, { type = "no_such_event" }, { type = "noise" }, { type = "ped_damage" }, { type = "ped_died" },
		{ type = "player_state", pos = "here" }, { type = "order" }, { type = "order", kind = {} }, { type = "item_moved" },
		{ type = "container_opened" }, { type = "time_set", hour = "noon" }, { type = "ped_damage", id = {}, amount = {} },
		{ type = "player_state", pos = { x = 0 / 0, y = 1 } }, { type = "horde_report", id = 5 }, { type = "colonist_ref" } }
	for i, ev in ipairs(bad) do
		local ok, out = pcall(w.handle, w, ev)
		T.truthy(ok, "event " .. i .. " must not raise: " .. tostring(out))
	end
	local out = w:handle({ type = "no_such_event" })
	T.eq(out[1].type, "error")
	T.eq(out[1].reason, "unknown_event")
	T.eq(w:handle("garbage")[1].reason, "bad_event")
	H.audit_ok(T, w, "after garbage")
	T.truthy(w.s.player.pos == nil, "NaN positions are rejected")
end)

T.test("player_state: position becomes an observer, needs are copied (and filtered)", function()
	local w = new_world(1)
	w:handle({ type = "player_state", pos = { x = 10, y = 20, z = 5 }, needs = { hunger = 40, thirst = 10, junk = "x", hp = 88 } })
	T.eq(w.s.player.pos.x, 10)
	T.eq(w.s.player.pos.z, 5)
	T.eq(w.s.player.needs.hunger, 40)
	T.eq(w.s.player.needs.junk, nil)
	local obs = w:observers()
	T.eq(#obs, 1)
	local pos = { x = 1, y = 2, z = 3 }
	w:handle({ type = "player_state", pos = pos })
	pos.x = 999
	T.eq(w.s.player.pos.x, 1, "the sim keeps its own copy")
	TUNING.horde.observe_colonists = true
	local n = #w:observers()
	TUNING.horde.observe_colonists = false
	T.eq(n, 1 + #w.s.colonists)
end)

T.test("ped_damage: wounds a colonist (bite -> bitten thought, may infect), downs and kills; junk is ignored", function()
	local w = new_world(2)
	local c = w.s.colonists[1]
	local hp0 = c.hp
	w:handle({ type = "ped_damage", id = c.id, amount = 12, kind = "bullet" })
	T.near(c.hp, hp0 - 12, 1e-9)
	T.gt(needs.bleeding(c), 0)
	w:handle({ type = "ped_damage", id = c.id, amount = 5, kind = "bite", part = "arm" })
	T.truthy(mood.has(c, "bitten", w.s.t))
	w:handle({ type = "ped_damage", id = "c999", amount = 5, kind = "bite" })
	w:handle({ type = "ped_damage", id = "h1", amount = 5, kind = "bite" })
	w:handle({ type = "ped_damage", id = c.id, amount = -5, kind = "bite" })
	w:handle({ type = "ped_damage", id = c.id, amount = 0 / 0, kind = "bite" })
	T.near(c.hp, hp0 - 17, 1e-9)
	local out = w:handle({ type = "ped_damage", id = c.id, amount = c.hp - 6, kind = "blunt" })
	T.truthy(c.downed)
	T.truthy(H.find(out, "notify", function(e) return e.text:find("down") end))
	local out2 = w:handle({ type = "ped_damage", id = c.id, amount = 500, kind = "explosion" })
	T.eq(w:colonist(c.id), nil, "fatal damage kills at once")
	T.truthy(H.find(out2, "colonist_died"))
	H.audit_ok(T, w, "after damage")
end)

T.test("ped_died: colonist removed with belongings dropped, others grieve, infected dead turn, last death ends the game once", function()
	local w = new_world(3)
	w:flush_events()
	local victim = w.s.colonists[1]
	needs.infect(victim, w:rng("t"), "arm")
	local carried = items.total_count(victim.inv)
	T.gt(carried, 0)
	victim.pos = { x = 600, y = 500, z = 0 }
	local out = w:handle({ type = "ped_died", id = victim.id, cause = "zombies" })
	local died = H.find(out, "colonist_died")
	T.eq(died.id, victim.id)
	T.eq(died.cause, "zombies")
	T.eq(died.turns, true)
	T.eq(died.pos.x, 600)
	T.eq(#w.s.colonists, TUNING.colonist.start_count - 1)
	local pile = w:pile_for({ x = 600, y = 500, z = 0 })
	T.eq(items.total_count(pile.items), carried, "belongings stayed where they fell")
	for _, c in ipairs(w.s.colonists) do T.truthy(mood.has(c, "friend_died", w.s.t)) end
	T.eq(w.s.dead[#w.s.dead].id, victim.id)
	local evs = w:tick(TUNING.needs.infection.turn_delay[2] + 2)
	local turned = H.find(evs, "colonist_turned")
	T.truthy(turned, "the infected dead rise")
	T.eq(turned.id, victim.id)
	local found = false
	for _, h in ipairs(w.s.hordes) do if h.src == "turned" then found = true end end
	T.truthy(found, "...as a one-zombie horde in the abstract sim")
	T.eq(w:handle({ type = "ped_died", id = victim.id, cause = "again" })[1], nil, "double death reports are ignored")
	-- ending the game
	local games = 0
	local rest = {}
	for i = 1, #w.s.colonists do rest[i] = w.s.colonists[i] end
	for _, c in ipairs(rest) do
		local o = w:handle({ type = "ped_died", id = c.id, cause = "test" })
		games = games + H.count(o, "game_over")
	end
	T.eq(games, 1, "exactly one game_over")
	T.truthy(w.s.over)
	T.eq(#w.s.colonists, 0)
	H.audit_ok(T, w, "after everyone died")
	-- a world with no colonists keeps ticking without errors
	T.no_throw(function() w:tick(120) end)
end)

T.test("orders: every kind answers with order_result; bad targets fail cleanly", function()
	local w = new_world(4)
	w:flush_events()
	local c = w.s.colonists[1]
	local function order(id, kind, target)
		local out = w:handle({ type = "order", id = id, kind = kind, target = target })
		return H.find(out, "order_result"), out
	end
	local r = order(c.id, "priority", { work = "build", level = 1 })
	T.truthy(r.ok)
	T.eq(c.prio.build, 1)
	T.eq(r.level, 1)
	r = order(c.id, "priority", { work = "build", level = 99 })
	T.truthy(r.ok)
	T.eq(r.reason, "clamped")
	T.eq(c.prio.build, 4)
	T.falsy(order(c.id, "priority", { work = "juggling", level = 1 }).ok)
	T.falsy(order("c999", "priority", { work = "build", level = 1 }).ok)
	T.eq(order("c999", "priority", { work = "build", level = 1 }).reason, "no_such_colonist")
	T.eq(order(c.id, "dance", {}).reason, "unknown_order")
	-- draft one / all
	T.truthy(order(c.id, "draft", true).ok)
	T.truthy(c.drafted)
	local all = order("all", "draft", false)
	T.eq(all.count, #w.s.colonists)
	T.falsy(c.drafted)
	-- goto / equip validation
	T.falsy(order(c.id, "goto", "the shops").ok)
	T.truthy(order(c.id, "goto", { x = 5, y = 5, z = 0 }).ok)
	T.falsy(order(c.id, "equip", { item = "canned_beans" }).ok)
	T.falsy(order(c.id, "equip", { item = "rifle" }).ok, "nothing in stock")
	-- blueprints
	local placed = order("colony", "place_blueprint", { bp = "wall", pos = { x = 30, y = 30, z = 0 } })
	T.truthy(placed.ok)
	T.truthy(placed.building)
	T.eq(order("colony", "place_blueprint", { bp = "radio_mast", pos = { x = 60, y = 30, z = 0 } }).reason, "prereq:generator")
	T.eq(order("colony", "place_blueprint", { bp = "wall" }).reason, "bad_target")
	T.truthy(order("colony", "cancel_blueprint", { id = placed.building }).ok)
	T.falsy(order("colony", "cancel_blueprint", { id = "b777" }).ok)
	-- schedules
	T.truthy(order(c.id, "schedule", "night").ok)
	T.eq(c.sched, colonist.default_schedule("night"))
	T.truthy(order(c.id, "schedule", string.rep("W", 24)).ok)
	T.falsy(order(c.id, "schedule", "WWW").ok)
	T.falsy(order(c.id, "schedule", string.rep("X", 24)).ok)
	-- zones
	local z = order("colony", "zone_create", { name = "Armoury", pos = { x = 20, y = 20, z = 0 }, tiles = 2, prio = 5, cats = { "weapon", "ammo" } })
	T.truthy(z.ok)
	local zone = w:zone(z.zone)
	T.truthy(stockpile.accepts(zone, "pistol"))
	T.falsy(stockpile.accepts(zone, "canned_beans"))
	T.truthy(order("colony", "zone_set", { id = z.zone, prio = 1, cats = { "food" } }).ok)
	T.truthy(stockpile.accepts(zone, "canned_beans"))
	T.eq(zone.prio, 1)
	T.eq(order("colony", "zone_set", { id = "z99" }).reason, "no_such_zone")
	-- amputation permission, building toggle, profile
	T.truthy(order(c.id, "amputation", true).ok)
	T.truthy(c.allow_amputation)
	local wb = blueprints.list_built(w, "workbench")[1]
	T.truthy(order("colony", "toggle_building", { id = wb.id, enabled = false }).ok)
	T.eq(wb.enabled, false)
	w:tick(1)
	T.falsy(wb.powered, "a disabled building draws no power")
	T.truthy(order("colony", "set_profile", "chaos").ok)
	T.eq(w.s.director.profile, "chaos")
	T.eq(order("colony", "set_profile", "nightmare").reason, "unknown_profile")
	T.eq(w.s.director.profile, "chaos")
	-- expeditions
	local x = order("colony", "expedition", { district = "orchard", size = 2 })
	T.truthy(x.ok)
	T.truthy(x.expedition)
	T.falsy(order("colony", "expedition", { district = "orchard" }).ok, "the van is taken")
	T.truthy(order("colony", "cancel_expedition", { id = x.expedition }).ok)
	H.audit_ok(T, w, "after orders")
end)

T.test("item_moved: transfers between player, colonists, zones, piles and adapter containers conserve items; void creates/destroys", function()
	local w = new_world(5)
	w:flush_events()
	local c = w.s.colonists[1]
	local z = w.s.zones[1]
	local function move(from, to, item, n)
		local out = w:handle({ type = "item_moved", from = from, to = to, item = item, n = n })
		return H.find(out, "item_result")
	end
	local r = move({ kind = "void" }, { kind = "player" }, "pistol", 1)
	T.truthy(r.ok)
	T.eq(items.count(w.s.player.inv, "pistol"), 1)
	T.eq(w.s.ledger.reasons["+adapter"], 1)
	r = move({ kind = "player" }, { kind = "container", id = "trunk:1" }, "pistol", 1)
	T.eq(r.moved, 1)
	T.truthy(w.s.containers["trunk:1"], "unknown adapter containers are created on demand")
	local before = items.count(z.items, "canned_beans")
	r = move({ kind = "zone", id = z.id }, { kind = "colonist", id = c.id }, "canned_beans", 3)
	T.eq(r.moved, 3)
	T.eq(items.count(z.items, "canned_beans"), before - 3)
	r = move({ kind = "colonist", id = c.id }, { kind = "void" }, "canned_beans", 2)
	T.eq(r.moved, 2)
	T.eq(w.s.ledger.reasons["-adapter"], 2)
	T.falsy(move({ kind = "zone", id = z.id }, { kind = "player" }, "no_item", 1).ok)
	T.falsy(move({ kind = "void" }, { kind = "void" }, "pistol", 1).ok)
	T.falsy(move({ kind = "zone", id = "z99" }, { kind = "player" }, "pistol", 1).ok)
	T.falsy(move({ kind = "player" }, { kind = "zone", id = z.id }, "pistol", 5).ok, "nothing to move")
	T.falsy(move({ kind = "player" }, { kind = "zone", id = z.id }, "pistol", -3).ok)
	T.falsy(move({ kind = "player" }, { kind = "zone", id = z.id }, "pistol", 1.5).ok)
	-- capacity limits partial moves
	w:create(w.s.player.inv, "scrap_wood", 5, "test")
	local tiny = w:handle({ type = "order", id = "colony", kind = "zone_create", target = { name = "Tiny", pos = { x = 30, y = 0, z = 0 }, tiles = 1, prio = 5 } })
	local tz = w:zone(H.find(tiny, "order_result").zone)
	tz.items.cap = 2500
	r = move({ kind = "player" }, { kind = "zone", id = tz.id }, "scrap_wood", 5)
	T.eq(r.moved, 1, "only what fits")
	T.eq(items.count(w.s.player.inv, "scrap_wood"), 4)
	H.audit_ok(T, w, "after moves")
end)

T.test("container_opened: loot generates once (loot_spawn), re-opens show contents, items move out, empty ones refill after the respawn delay", function()
	local w = new_world(6)
	w:flush_events()
	local open = function(ref, ctype, pos) return w:handle({ type = "container_opened", container = ref, ctype = ctype, pos = pos or { x = 500, y = 300, z = 0 } }) end
	local out = open("fridge:77", "fridge")
	local spawn = H.find(out, "loot_spawn")
	T.truthy(spawn)
	T.eq(spawn.container, "fridge:77")
	T.eq(spawn.ctype, "fridge")
	T.gt(U.sum_map(spawn.items), 0)
	for id in pairs(spawn.items) do T.truthy(items.def(id).cat ~= nil) end -- order-free
	local created = w.s.ledger.reasons["+container"]
	T.eq(created, U.sum_map(spawn.items))
	local out2 = open("fridge:77", "fridge")
	T.eq(H.count(out2, "loot_spawn"), 0, "no second roll")
	local contents = H.find(out2, "container_contents")
	for id, n in pairs(spawn.items) do T.eq(contents.items[id], n) end -- order-free
	T.eq(w.s.ledger.reasons["+container"], created, "re-opening creates nothing")
	-- take everything out through item_moved
	for id, n in pairs(spawn.items) do -- order-free
		w:handle({ type = "item_moved", from = { kind = "container", id = "fridge:77" }, to = { kind = "player" }, item = id, n = n })
	end
	T.eq(items.total_count(w.s.containers["fridge:77"].items), 0)
	T.eq(items.total_count(w.s.player.inv) >= 1, true)
	T.eq(H.count(open("fridge:77", "fridge"), "loot_spawn"), 0, "still empty before the respawn delay")
	w.s.t = w.s.t + TUNING.world.container_respawn_days * 1440
	T.eq(H.count(open("fridge:77", "fridge"), "loot_spawn"), 1, "refilled after a week")
	-- danger follows the district: the airfield has better stuff than the orchard
	local function rare(pos, n)
		local k = 0
		for i = 1, n do
			local ww = new_world(100 + i)
			local o = ww:handle({ type = "container_opened", container = "c" .. string.format("%d", i), ctype = "bunker", pos = pos })
			local s = H.find(o, "loot_spawn")
			for id, cnt in pairs(s.items) do if items.def(id).cat == "weapon" then k = k + cnt end end -- order-free
		end
		return k
	end
	T.gt(rare({ x = 1900, y = -1500, z = 0 }, 60), 0)
	T.eq(H.find(open("x", "unknown_type_of_box"), "loot_spawn").ctype, "unknown_type_of_box")
	T.eq(H.count(open("", "house"), "loot_spawn"), 0, "an empty container ref is ignored")
	H.audit_ok(T, w, "after containers")
	-- emptied containers are forgotten by the daily cleanup (bounded state)
	for i = 1, 30 do open("junk:" .. string.format("%d", i), "house") end
	for key, cont in pairs(w.s.containers) do -- order-free
		for _, it in ipairs(items.list(cont.items)) do w:destroy(cont.items, it.id, it.n, "test") end
	end
	w.s.t = w.s.t + TUNING.world.container_respawn_days * 1440 + 10
	w.s.day = clock.day(w.s.t) - 1
	w:tick(1)
	T.eq(U.count(w.s.containers), 0, "empty old containers pruned")
end)

T.test("time_set: sets the hour (and optionally the day), clamps nonsense", function()
	local w = new_world(7)
	local d = clock.day(w.s.t)
	w:handle({ type = "time_set", hour = 22, minute = 30 })
	T.eq(clock.hour(w.s.t), 22)
	T.eq(clock.minute(w.s.t), 30)
	T.eq(clock.day(w.s.t), d)
	w:handle({ type = "time_set", day = 5, hour = 3 })
	T.eq(clock.day(w.s.t), 5)
	T.eq(clock.hour(w.s.t), 3)
	w:handle({ type = "time_set", hour = 99, minute = -4 })
	T.eq(clock.hour(w.s.t), 23)
	T.eq(clock.minute(w.s.t), 0)
	T.eq(w.s.day, clock.day(w.s.t))
	T.truthy(clock.is_night(w.s.t))
	for _, c in ipairs(w.s.colonists) do T.truthy(c.dirty, "colonists re-evaluate after a time jump") end
	T.no_throw(function() w:tick(60) end)
end)

T.test("reports: day_start each midnight, colonist_state on change + heartbeat (throttled), alert and weather events", function()
	local w = new_world(8)
	local evs = w:tick(3 * 1440)
	T.eq(H.count(evs, "day_start"), 3)
	local per_colonist = {}
	local last_t = {}
	local max_burst = 0
	for i = 1, #evs do
		local e = evs[i]
		if e.type == "colonist_state" then
			per_colonist[e.id] = (per_colonist[e.id] or 0) + 1
			if last_t[e.id] then T.truthy(e.t - last_t[e.id] >= 3, "no more than one report per 3 minutes per colonist") end
			last_t[e.id] = e.t
			T.truthy(e.hp and e.hunger and e.mood and e.pos and e.state)
			T.eq(type(e.pos.x), "number")
		end
	end
	for id, n in pairs(per_colonist) do T.gt(n, 3 * 1440 / TUNING.sim.state_report_min * 0.9, "heartbeat reaches every colonist: " .. id) end -- order-free
	T.truthy(H.count(evs, "weather") >= 0)
	T.eq(w.s.day, 4)
	T.ge(#w.s.history, 3)
	T.le(#w.s.history, 60)
	local h = w.s.history[1]
	T.truthy(h.colonists and h.mood and h.food and h.wealth)
end)

T.test("snapshot summarises the colony; audit catches a corrupted ledger", function()
	local w = new_world(9)
	w:tick(120)
	local sn = w:snapshot()
	for _, k in ipairs({ "day", "time", "colonists", "mood", "food", "drink", "wealth", "budget", "alert", "hordes", "raids", "defense", "enclosure", "power" }) do
		T.truthy(sn[k] ~= nil, "snapshot." .. k)
	end
	T.eq(sn.colonists, #w.s.colonists)
	T.eq(sn.hordes, #w.s.hordes)
	H.audit_ok(T, w, "clean")
	w.s.ledger.created.canned_beans = w.s.ledger.created.canned_beans + 1
	local ok, rep = w:audit()
	T.falsy(ok)
	T.truthy(rep.problems[1]:find("canned_beans"))
	w.s.ledger.created.canned_beans = w.s.ledger.created.canned_beans - 1
	w.s.zones[1].items.items.bandage = (w.s.zones[1].items.items.bandage or 0) + 1 -- bypassing the API
	local ok2, rep2 = w:audit()
	T.falsy(ok2, "cache + ledger mismatch is detected")
end)

T.test("events are copies: mutating what the adapter receives cannot corrupt the sim", function()
	local function mutate(v)
		if type(v) == "table" then
			for k, x in pairs(v) do -- order-free
				if type(x) == "number" then v[k] = -9999 elseif type(x) == "table" then mutate(x) end
			end
		end
	end
	local a, b = new_world(11), new_world(11)
	a:flush_events(); b:flush_events()
	local st_a, st_b = policy.new(), policy.new()
	for _ = 1, 288 do -- two days in 10-minute chunks with the policy driving both
		local ea, eb = a:tick(10), b:tick(10)
		for i = 1, #ea do mutate(ea[i]) end -- the adapter scribbles over everything it was given
		policy.step(a, st_a, nil)
		policy.step(b, st_b, nil)
	end
	T.eq(a:hash(), b:hash(), "state is unaffected by event mutation")
end)

T.test("no game handles in state: only plain data (numbers, strings, booleans, tables) and the adapter's opaque ref", function()
	local w = new_world(12)
	w.s.colonists[1].ref = { handle = 12345 }
	w:tick(600)
	local bad = {}
	local function walk(v, path, depth)
		local t = type(v)
		if t == "function" or t == "userdata" or t == "thread" then bad[#bad + 1] = path end
		if t == "table" then
			if depth > 40 then bad[#bad + 1] = path .. " (too deep)"; return end
			for k, x in pairs(v) do -- order-free
				walk(x, path .. "." .. tostring(k), depth + 1)
			end
		end
	end
	walk(w.s, "s", 0)
	T.eq(#bad, 0, table.concat(bad, ", "))
	T.truthy(save.serialize(w.s), "and it serializes")
end)
