-- shared/host.lua: the game-agnostic server core (clock accumulator, validation, orders, UI actions, persistence, resync, debug tools).
local T, H = ...
local Host = require("shared.host")
local Config = require("shared.config")
local P = require("shared.protocol")
local U = require("shared.util")
local V = require("shared.view")
local World = require("sim.world")
local save = require("sim.save")
local SU = require("sim.util")

T.group("host")

-- a host with a recording `send` and an in-memory KVP store
local function new_host(opts)
	opts = opts or {}
	local cfg = { server = U.copy(Config.server), client = U.copy(Config.client), origin = Config.origin }
	for k, v in pairs(opts.server or {}) do cfg.server[k] = v end
	cfg.server.autosave_s = opts.server and opts.server.autosave_s or 0
	local rec = { sent = {}, by = {}, kv = opts.kv or {}, logs = {} }
	local h = Host.new({
		cfg = cfg,
		send = function(topic, payload)
			local ok, why = U.msgpack_safe(payload)
			assert(ok, "payload for " .. topic .. " is not msgpack-safe: " .. tostring(why))
			rec.sent[#rec.sent + 1] = { topic = topic, payload = payload }
			rec.by[topic] = (rec.by[topic] or 0) + 1
		end,
		store = opts.nostore and nil or { get = function(k) return rec.kv[k] end, set = function(k, v) rec.kv[k] = v end, del = function(k) rec.kv[k] = nil end },
		log = function(level, text) rec.logs[#rec.logs + 1] = level .. ": " .. text end,
	})
	if not opts.empty then h:new_game(opts.seed or 11, opts.profile or "calm", opts.colonists or 4) end
	return h, rec
end

local function events_of(rec, from)
	local out = {}
	for i = from or 1, #rec.sent do
		local m = rec.sent[i]
		if m.topic == P.NET.events then for _, e in ipairs(m.payload.events) do out[#out + 1] = e end end
	end
	return out
end

local function find(evs, ty) for _, e in ipairs(evs) do if e.type == ty then return e end end end
local function count_of(evs, ty) local n = 0; for _, e in ipairs(evs) do if e.type == ty then n = n + 1 end end return n end

-- ---------------------------------------------------------------------------------------------------------------------------- clock
T.test("new_game: world, survival body, resync batch with reset flag", function()
	local h, rec = new_host()
	T.truthy(h.world); T.truthy(h.survival)
	local first = rec.sent[1]
	T.eq(first.topic, P.NET.events); T.eq(first.payload.reset, true, "the first batch of a game resets the client")
	local evs = events_of(rec)
	T.eq(count_of(evs, "colonist_joined"), 4)
	T.truthy(find(evs, "set_power") and find(evs, "weather"))
	for _, m in ipairs(rec.sent) do if m.topic == P.NET.events then T.le(#m.payload.events, Config.server.max_events_per_msg, "batches are split") end end
end)

T.test("advance: real ms -> sim minutes at the configured scale", function()
	local h = new_host({ server = { time_scale = 30 } })
	local w = h.world
	local t0 = w.s.t
	local ticked = 0
	for _ = 1, 8 do ticked = ticked + h:advance(500) end -- 4 real seconds at 30 game s per real s = 2 minutes
	T.eq(ticked, 2); T.eq(w.s.t - t0, 2)
	T.eq(h:advance(0), 0, "dt 0 ticks nothing")
	h.speed = 4
	T.eq(h:advance(1000), 2, "speed 4 = 120 game s per real s = 2 minutes per second")
end)

T.test("advance: fractional remainders are carried, never lost", function()
	local h = new_host({ server = { time_scale = 30 } })
	local total = 0
	for _ = 1, 600 do total = total + h:advance(100) end -- 60 real s = 30 sim minutes
	T.eq(total, 30)
end)

T.test("advance: catch-up cap stops a spiral of death", function()
	local h = new_host({ server = { time_scale = 30, max_catchup_min = 30 } })
	h.speed = 16
	local t0 = h.world.s.t
	local ticked = h:advance(5000) -- 5 s at speed 16 = 40 min of game time; the cap is 30
	T.le(ticked, 30); T.eq(h.world.s.t - t0, ticked)
	T.lt(h.acc, 1, "the excess is dropped, not queued")
	local ticked2 = h:advance(100000) -- a long stall is clamped to 5 s by advance itself
	T.le(ticked2, 30)
end)

T.test("advance: paused and speed 0 tick nothing", function()
	local h = new_host()
	h.paused = true
	T.eq(h:advance(5000), 0)
	h.paused = false; h.speed = 0
	T.eq(h:advance(5000), 0)
end)

T.test("advance: game over stops the clock", function()
	local h = new_host({ colonists = 1, profile = "chaos", seed = 2 })
	h.speed = 16
	for _ = 1, 4000 do h:advance(1000); if h.world.s.over then break end end
	T.truthy(h.world.s.over, "a lone colonist under chaos eventually dies")
	local t = h.world.s.t
	T.eq(h:advance(5000), 0); T.eq(h.world.s.t, t)
end)

T.test("host adds no nondeterminism: any chunking gives the sim's own hash", function()
	for _, chunk in ipairs({ 100, 333, 500, 1000, 4999 }) do
		local h = new_host({ seed = 21, profile = "escalating", server = { time_scale = 30, max_catchup_min = 600 } })
		local guard = 0
		local stop = h.world.s.t + 600
		while h.world.s.t < stop and guard < 100000 do
			h:advance(chunk)
			guard = guard + 1
		end
		-- the host may overshoot by < one chunk; compare at exactly t = 600 by trimming with direct ticks on a twin
		local twin = World.new({ seed = 21, profile = "escalating", colonists = 4, max_dt = 1 })
		for _ = 1, h.world.s.t - twin.s.t do twin:tick(1) end
		T.eq(h.world:hash(), twin:hash(), "chunk " .. chunk)
	end
end)

T.test("periodic pushes: clock 1 Hz, hud at hud_hz, state only while a colony screen is open", function()
	local h, rec = new_host({ server = { hud_hz = 2, ui_hz = 1 } })
	for _ = 1, 20 do h:advance(500) end -- 10 s
	T.ge(rec.by[P.NET.clock] or 0, 9); T.le(rec.by[P.NET.clock] or 0, 11)
	T.ge(rec.by[P.NET.hud] or 0, 18); T.le(rec.by[P.NET.hud] or 0, 22)
	T.eq(rec.by[P.NET.state] or 0, 0, "no state pushes while the UI is closed")
	h:ui_action("screens", { colony = true })
	local before = rec.by[P.NET.state] or 0
	for _ = 1, 20 do h:advance(500) end
	T.ge((rec.by[P.NET.state] or 0) - before, 9)
	h:ui_action("screens", { colony = false })
	local mid = rec.by[P.NET.state] or 0
	for _ = 1, 10 do h:advance(500) end
	T.eq(rec.by[P.NET.state] or 0, mid)
end)

-- ---------------------------------------------------------------------------------------------------------------------------- IN events
T.test("IN events: valid ones reach the sim, hostile ones are counted and dropped", function()
	local h = new_host()
	local n = h:on_client_events({
		{ type = "noise", pos = { x = 5, y = 5, z = 0 }, loudness = 90, kind = "gunshot" },
		{ type = "noise", pos = { x = 5, y = 5, z = 0 }, loudness = -1 },
		{ type = "order", id = "c1", kind = "priority" },       -- not allowed through the IN path
		{ type = "time_set", hour = 3 },
		"junk", 42,
		{ type = "horde_report", id = "h1", pos = { x = 1, y = 1 } },
	})
	T.eq(n, 2)
	T.eq(h.stats.in_ok, 2); T.ge(h.stats.in_rejected, 5)
	T.eq(h:on_client_events("not a list"), 0)
	T.eq(h:on_client_events({}), 0)
end)

T.test("IN events: the token bucket drops a flood and refills over time", function()
	local h = new_host({ server = { max_in_per_sec = 50 } })
	local list = {}
	for i = 1, 120 do list[i] = { type = "noise", pos = { x = i, y = 0, z = 0 }, loudness = 20 } end
	local a = h:on_client_events(list)       -- at most 120 per call, bucket holds 50 (cap 100 after refill, starts at 50)
	local b = h:on_client_events(list)
	T.le(a + b, 55, "bucket capped the flood")
	T.ge(h.stats.in_dropped, 100)
	h:advance(2000)
	T.ge(h:on_client_events({ list[1], list[2], list[3] }), 3, "tokens come back")
end)

T.test("IN events: the player's own needs cannot be overwritten by the client", function()
	local h = new_host()
	local before = h.survival:view().hunger
	h:on_client_event({ type = "player_state", pos = { x = 1, y = 1, z = 0 }, needs = { hunger = 999, thirst = 999 } })
	T.eq(h.survival:view().hunger, before)
end)

T.test("IN events: player_damage hurts the survival body, and kills it", function()
	local h, rec = new_host()
	local hp0 = h.survival:view().hp
	T.truthy(h:on_client_event({ type = "player_damage", amount = 15, kind = "bullet", part = "torso" }))
	T.lt(h.survival:view().hp, hp0)
	T.eq(h:on_client_event({ type = "player_damage", amount = -5 }), false)
	T.eq(h:on_client_event({ type = "player_damage", amount = 0 / 0 }), false)
	h:on_client_event({ type = "player_damage", amount = 500, kind = "explosion" })
	h:on_client_event({ type = "player_damage", amount = 500, kind = "explosion" })
	T.truthy(h.survival:view().dead or h.survival:view().downed or h.survival:view().hp <= 0)
end)

-- ---------------------------------------------------------------------------------------------------------------------------- orders
T.test("orders: priority round trip -> sim changed + order_result ok", function()
	local h, rec = new_host()
	local c = h.world.s.colonists[1]
	local from = #rec.sent + 1
	T.truthy(h:on_order({ id = c.id, kind = "priority", target = { work = "cook", level = 4 } }))
	local r = find(events_of(rec, from), "order_result")
	T.truthy(r and r.ok, "order_result ok: " .. tostring(r and r.reason))
	T.eq(require("sim.colonist").priority(c, "cook"), 4)
end)

T.test("orders: draft, place_blueprint, cancel; a sim refusal comes back as order_result ok=false", function()
	local h, rec = new_host()
	local c = h.world.s.colonists[1]
	local b = require("data.tuning").base
	local from = #rec.sent + 1
	h:on_order({ id = c.id, kind = "draft", target = true })
	T.truthy(c.drafted)
	h:on_order({ id = "colony", kind = "place_blueprint", target = { bp = "wall", pos = { x = b.x + 20, y = b.y + 20 } } })
	local placed = find(events_of(rec, from), "place_blueprint")
	T.truthy(placed, "place_blueprint event emitted")
	from = #rec.sent + 1
	h:on_order({ id = "colony", kind = "place_blueprint", target = { bp = "wall", pos = { x = b.x + 20, y = b.y + 20 } } })
	local r = find(events_of(rec, from), "order_result")
	T.truthy(r and r.ok == false and r.reason == "blocked", "second placement at the same spot: " .. tostring(r and r.reason))
	h:on_order({ id = "colony", kind = "cancel_blueprint", target = placed.id })
end)

T.test("orders: invalid orders are rejected with a result and counted", function()
	local h, rec = new_host()
	local from = #rec.sent + 1
	T.eq(h:on_order({ id = "c1", kind = "nuke" }), false)
	T.eq(h:on_order("junk"), false)
	T.eq(h:on_order({ id = "colony", kind = "set_profile", target = "hardcore" }), false)
	local rejected = 0
	for _, e in ipairs(events_of(rec, from)) do if e.type == "order_result" and e.ok == false then rejected = rejected + 1 end end
	T.ge(rejected, 2)
	T.eq(h.stats.orders_rejected, 3)
	T.truthy(h:on_order({ id = "colony", kind = "set_profile", target = "chaos" }))
	T.eq(h.world.s.profile, "chaos")
end)

-- ---------------------------------------------------------------------------------------------------------------------------- UI actions
T.test("ui_action: request_catalog / request_state / request_summary / select", function()
	local h, rec = new_host()
	T.truthy(h:ui_action("request_catalog")); T.eq(rec.by[P.NET.catalog], 1)
	T.truthy(h:ui_action("request_state")); T.eq(rec.by[P.NET.state], 1)
	T.truthy(h:ui_action("request_summary"))
	local last
	for _, m in ipairs(rec.sent) do if m.topic == P.NET.ui and m.payload.name == "summary" then last = m end end
	T.truthy(last and last.payload.data.alive == 4)
	local c = h.world.s.colonists[2]
	h:ui_action("select", { id = c.id })
	local st
	for _, m in ipairs(rec.sent) do if m.topic == P.NET.state then st = m.payload end end
	T.eq(st.card and st.card.id, c.id)
	h:ui_action("select", { id = "nope" })
	for _, m in ipairs(rec.sent) do if m.topic == P.NET.state then st = m.payload end end
	T.eq(st.card, nil)
	T.eq(h:ui_action("bogus_action"), false)
	T.eq(h:ui_action(("x"):rep(500), {}), false)
end)

T.test("ui_action: set_speed validates, toggle_pause flips", function()
	local h = new_host()
	T.truthy(h:ui_action("set_speed", { speed = 8 })); T.eq(h.speed, 8)
	T.eq(h:ui_action("set_speed", { speed = 3 }), false); T.eq(h.speed, 8)
	T.eq(h:ui_action("set_speed", { speed = "fast" }), false)
	h:ui_action("toggle_pause"); T.truthy(h.paused); h:ui_action("toggle_pause"); T.falsy(h.paused)
	h:ui_action("set_speed", { speed = 0 }); T.truthy(h.paused)
end)

T.test("inventory: give, move between player and a zone, use, drop; weights are conserved", function()
	local h, rec = new_host()
	local w = h.world
	local items = require("sim.items")
	T.truthy(h:debug("give", { item = "water_bottle", n = 3 }))
	T.eq(items.count(w.s.player.inv, "water_bottle"), 3)
	local zone = w.s.zones[1]
	local zone_before = items.count(zone.items, "water_bottle")
	T.truthy(h:ui_action("inventory_move", { from = { kind = "player" }, to = { kind = "zone", id = zone.id }, item = "water_bottle", n = 2 }))
	T.eq(items.count(w.s.player.inv, "water_bottle"), 1); T.eq(items.count(zone.items, "water_bottle"), zone_before + 2)
	T.eq(h:ui_action("inventory_move", { from = { kind = "player" }, to = { kind = "zone", id = zone.id }, item = "not_an_item", n = 1 }), false)
	T.eq(h:ui_action("inventory_move", { from = { kind = "player" }, to = { kind = "zone", id = zone.id }, item = "water_bottle", n = 0 }), false)
	T.eq(h:ui_action("inventory_move", { from = { kind = "zone", id = "../etc" }, to = { kind = "player" }, item = "water_bottle", n = 1 }), true, "unknown ids are the sim's problem and harmless")
	h.survival.c.thirst = 80
	T.truthy(h:ui_action("use_item", { item = "water_bottle" }))
	T.eq(items.count(w.s.player.inv, "water_bottle"), 0, "consumed")
	T.eq(h:ui_action("use_item", { item = "water_bottle" }), false, "none left")
	h:debug("give", { item = "bandage", n = 5 })
	local from = #rec.sent + 1
	T.truthy(h:ui_action("drop_item", { item = "bandage", n = 2 }))
	T.eq(items.count(w.s.player.inv, "bandage"), 3)
	local drop = find(events_of(rec, from), "loot_spawn")
	T.truthy(drop and drop.items.bandage == 2 and drop.source == "drop", "a drop spawns a loot pile for the client")
	T.truthy(w:audit(), "item conservation audit")
	T.truthy(select(1, h:debug("audit")))
end)

T.test("inventory: other-container selection is validated", function()
	local h, rec = new_host()
	h:ui_action("inventory", { other = { kind = "zone", id = h.world.s.zones[1].id } })
	T.eq(h.other.kind, "zone")
	h:ui_action("inventory", { other = { kind = "player" } }); T.eq(h.other, nil)
	h:ui_action("inventory", { other = { kind = "evil", id = "x" } }); T.eq(h.other, nil)
	h:ui_action("inventory", { other = "zone" }); T.eq(h.other, nil)
end)

-- ---------------------------------------------------------------------------------------------------------------------------- persistence
T.test("save / load: hash round trip, survival body and speed restored", function()
	local h, rec = new_host({ seed = 33 })
	h.speed = 4
	for _ = 1, 40 do h:advance(500) end
	h.survival.c.hunger = 61
	local hash = h.world:hash()
	local ok, slot = h:save_game("test")
	T.truthy(ok); T.eq(slot, "a")
	h.speed = 1
	for _ = 1, 40 do h:advance(500) end
	T.ne(h.world:hash(), hash)
	local from = #rec.sent + 1
	local ok2, slot2 = h:load_game()
	T.truthy(ok2); T.eq(slot2, "a")
	T.eq(h.world:hash(), hash); T.eq(h.speed, 4); T.eq(h.survival.c.hunger, 61)
	local first = rec.sent[from]
	T.eq(first.payload.reset, true, "loading resets the client")
	T.eq(count_of(events_of(rec, from), "colonist_joined"), #h.world.s.colonists)
	local saves = h:list_saves()
	T.eq(#saves, 1); T.eq(saves[1].slot, "a"); T.truthy(saves[1].latest)
end)

T.test("save: two slots rotate, the pointer flips only after a complete write", function()
	local h, rec = new_host()
	h:save_game("1"); local m1 = save.deserialize(rec.kv["outbreak:meta"]); T.eq(m1.latest, "a")
	h:advance(2000); h:save_game("2"); local m2 = save.deserialize(rec.kv["outbreak:meta"]); T.eq(m2.latest, "b")
	h:save_game("3"); local m3 = save.deserialize(rec.kv["outbreak:meta"]); T.eq(m3.latest, "a")
	T.truthy(rec.kv["outbreak:slot:a"] and rec.kv["outbreak:slot:b"])
	T.eq(#h:list_saves(), 2)
	-- a crash while writing slot b (the non-latest) must not damage slot a
	local good_a = rec.kv["outbreak:slot:a"]
	h.store.set("outbreak:slot:b", "OBHOST 1 999 deadbeef\npartial")
	local h2 = new_host({ kv = rec.kv, empty = true })
	T.truthy(h2:load_game(), "loads the latest good slot")
	T.eq(rec.kv["outbreak:slot:a"], good_a)
end)

T.test("load: corruption falls back to the other slot, and a failed load leaves the game untouched", function()
	local h, rec = new_host({ seed = 5 })
	h:save_game("old")                      -- slot a
	for _ = 1, 20 do h:advance(500) end
	local hash_b = h.world:hash()
	h:save_game("new")                      -- slot b = latest
	-- 1) latest slot corrupted (flip a byte in the body)
	local b = rec.kv["outbreak:slot:b"]
	rec.kv["outbreak:slot:b"] = b:sub(1, #b - 10) .. "X" .. b:sub(#b - 8)
	local h2 = new_host({ kv = rec.kv, empty = true })
	local ok, slot = h2:load_game()
	T.truthy(ok); T.eq(slot, "a", "fell back to the older slot")
	-- 2) both corrupted: load fails, the existing game keeps running untouched
	rec.kv["outbreak:slot:a"] = "garbage"
	local h3, rec3 = new_host({ kv = rec.kv, seed = 9 })
	local before = h3.world:hash()
	local ok3, why = h3:load_game()
	T.eq(ok3, false); T.truthy(why and #why > 0)
	T.eq(h3.world:hash(), before)
	-- 3) truncated, wrong magic, newer format, empty, no meta
	local good = h:save_game("again") and rec.kv["outbreak:slot:a"]
	for name, bad in pairs({ truncated = good:sub(1, #good - 100), magic = "NOPE" .. good, newer = good:gsub("^OBHOST 1", "OBHOST 99"), empty = "" }) do
		local _, err = Host._unwrap(bad)
		T.truthy(err, name .. " must be rejected")
	end
	local t = Host._unwrap(good)
	T.truthy(t and t.game and t.extras)
	local h4 = new_host({ kv = {}, empty = true })
	local ok4, why4 = h4:load_game()
	T.eq(ok4, false); T.eq(why4, "no save found")
	local h5 = new_host({ nostore = true, empty = true })
	T.eq(h5:load_game(), false); T.eq(h5:save_game(), false)
end)

T.test("autosave runs on the real-time interval, not on sim time", function()
	local h, rec = new_host({ server = { autosave_s = 10 } })
	for _ = 1, 15 do h:advance(500) end    -- 7.5 s
	T.eq(h.stats.saves, 0)
	for _ = 1, 10 do h:advance(500) end    -- 12.5 s
	T.eq(h.stats.saves, 1)
	for _ = 1, 40 do h:advance(500) end    -- +20 s
	T.eq(h.stats.saves, 3)
end)

T.test("new_game replaces the world and resets the client", function()
	local h, rec = new_host({ seed = 7 })
	local from = #rec.sent + 1
	T.truthy(h:ui_action("new_game", { seed = 99, profile = "chaos" }))
	T.eq(h.world.s.seed, 99); T.eq(h.world.s.profile, "chaos")
	T.eq(rec.sent[from].payload.reset, true)
	h:ui_action("new_game", { seed = 100, profile = "nonsense" })
	T.eq(h.world.s.profile, Config.server.profile)
end)

-- ---------------------------------------------------------------------------------------------------------------------------- resync
T.test("resync describes the whole world: buildings, hordes, raids, caravans, piles, colonist tasks", function()
	local h, rec = new_host({ seed = 4, profile = "escalating" })
	local w = h.world
	local b = require("data.tuning").base
	local horde = require("sim.horde")
	horde.spawn(w, { x = b.x + 60, y = b.y, mix = { walker = 12 }, target = { x = b.x, y = b.y }, src = "test" })
	h.speed = 16
	for _ = 1, 300 do h:advance(1000) end
	local evs = h:resync_events()
	local ok, why = U.msgpack_safe({ events = evs })
	T.truthy(ok, why)
	T.eq(count_of(evs, "colonist_joined"), #w.s.colonists)
	T.eq(count_of(evs, "colonist_state"), #w.s.colonists)
	local built, planned = 0, 0
	for _, bd in ipairs(w.s.buildings) do if bd.state == "built" then built = built + 1 else planned = planned + 1 end end
	T.eq(count_of(evs, "construction_done"), built); T.eq(count_of(evs, "place_blueprint"), planned)
	T.eq(count_of(evs, "loot_spawn"), #w.s.piles)
	local mat = 0
	for _, hd in ipairs(w.s.hordes) do if hd.mat and hd.mat.count > 0 then mat = mat + 1 end end
	T.eq(count_of(evs, "spawn_horde"), mat)
	for _, e in ipairs(evs) do T.truthy(e.type and e.t, "every event has a type and a time") end
	-- the resync never mutates the world
	local hash = w:hash()
	h:resync_events()
	T.eq(w:hash(), hash)
end)

-- ---------------------------------------------------------------------------------------------------------------------------- debug tools
T.test("debug: horde / event / give / player_pos / time_set / fast_forward / kill / damage / audit", function()
	local h, rec = new_host({ seed = 8 })
	local w = h.world
	local ok, id = h:debug("horde", { n = 40, dist = 300 })
	T.truthy(ok and id, "horde spawned")
	T.eq((h:debug("horde", { n = 1e9 })), true); -- clamped to 120, never an error
	T.eq((h:debug("event", { id = "nonexistent" })), false)
	local ev_ok = h:debug("event", { id = require("data.events").order[1] })
	T.truthy(ev_ok ~= nil)
	T.truthy(h:debug("player_pos", { x = 10, y = 20 })); T.near(w.s.player.pos.x, 10, 1e-9)
	T.eq((h:debug("player_pos", { x = "a" })), false)
	local c = w.s.colonists[1]
	local hp0 = c.hp
	T.truthy(h:debug("damage_colonist", { id = c.id, amount = 10, kind = "bite", part = "arm" }))
	T.truthy(c.hp < hp0 or #c.wounds > 0, "colonist was hurt")
	T.truthy(h:debug("time_set", { hour = 5, minute = 30 }))
	T.eq(require("sim.clock").hour(w.s.t), 5)
	local t0 = w.s.t
	local fok, n = h:debug("fast_forward", { minutes = 120 })
	T.truthy(fok); T.eq(n, 120); T.eq(w.s.t - t0, 120)
	T.eq((h:debug("fast_forward", { minutes = 0 })), true, "clamped to at least 1 minute")
	T.truthy(h:debug("kill_colonist", { id = w.s.colonists[#w.s.colonists].id }))
	T.eq((h:debug("kill_colonist", { id = "c9999" })), false)
	T.eq((h:debug("rm_rf")), false)
	T.truthy((h:debug("audit")), "audit OK after all of that")
	local on = select(2, h:debug("autopilot", { on = true })); T.eq(on, true)
	T.eq(select(2, h:debug("autopilot", { on = false })), false)
end)

T.test("debug: fast_forward under autopilot keeps a 6-colonist colony alive for 10 days", function()
	local h = new_host({ seed = 1, profile = "calm", colonists = 6 })
	h:debug("autopilot", { on = true })
	h:debug("fast_forward", { minutes = 10 * 1440 })
	T.ge(#h.world.s.colonists, 1)
	T.truthy(h:debug("audit"))
	T.eq(require("sim.clock").day(h.world.s.t), 11)
end)

T.test("status: a complete summary of the host", function()
	local h = new_host()
	local st = h:status()
	T.truthy(st.world and st.hash and #st.hash > 6); T.eq(st.colonists, 4); T.eq(st.day, 1); T.eq(st.paused, false)
	local h2 = new_host({ empty = true })
	T.eq(h2:status().world, false)
	T.eq(h2:advance(1000), 0, "no world: advance is a no-op")
	T.eq(h2:on_client_event({ type = "noise" }), false); T.eq(h2:on_order({}), false); T.eq(h2:ui_action("request_state"), false)
	T.eq((h2:debug("horde")), false)
end)
