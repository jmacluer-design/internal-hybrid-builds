-- shared/host.lua : the game-agnostic SERVER CORE of the adapter. It owns the sim World, runs the fixed-step clock, batches OUT events,
-- validates IN events / orders from the (untrusted) client, serves the UI view models, persists saves, and implements the admin and
-- debug actions. It never calls a game native: everything it needs comes in through `opts` (send, store, log), so the same file runs
--   * inside FiveM  (server/main.lua wires send -> TriggerClientEvent, store -> KVP, advance <- a Wait() loop),
--   * inside the browser preview (wasmoon; the page wires send -> window.postMessage to the real NUI page),
--   * inside the mock-native test harness (lua5.4 and luajit).
local U = require("shared.util")
local SU = require("sim.util")
local P = require("shared.protocol")
local V = require("shared.view")
local Survival = require("shared.survival")
local World = require("sim.world")
local save = require("sim.save")
local clock = require("sim.clock")
local items = require("sim.items")
local TUNING = require("data.tuning")
local ITEMS = require("data.items")
local FACTIONS = require("data.factions")
local EVENTS = require("data.events")

local Host = {}
Host.__index = Host

Host.SAVE_FMT = 1
local KEY_META, KEY_A, KEY_B = "outbreak:meta", "outbreak:slot:a", "outbreak:slot:b"
local SPEEDS = { [0] = true, [1] = true, [2] = true, [4] = true, [8] = true, [16] = true }

-- opts = { cfg = Config (shared/config.lua), send = fn(topic, payload), store = { get, set, del } | nil, log = fn(level, text) | nil }
function Host.new(opts)
	opts = opts or {}
	local self = setmetatable({}, Host)
	self.cfg = opts.cfg or require("shared.config")
	self.send_fn = opts.send or function() end
	self.store = opts.store
	self.log_fn = opts.log or function() end
	self.world = nil
	self.survival = nil
	self.speed = 1
	self.paused = false
	self.acc = 0                -- fractional sim minutes waiting to be ticked
	self.real_ms = 0            -- host's own clock: the sum of every dt passed to advance()
	self.outbox = {}
	self.seq = 0
	self.sel = nil              -- selected colonist id (card)
	self.other = nil            -- inventory "other" container spec
	self.ui_open = false        -- the owner has a colony screen open (full state pushes)
	self.autopilot = nil        -- ai_policy state when the debug autopilot is on
	self.last_policy_t = -1e9
	self.next = { state = 0, hud = 0, clock = 0, autosave = 0 }
	self.in_tokens = self.cfg.server.max_in_per_sec
	self.stats = { in_ok = 0, in_dropped = 0, in_rejected = 0, orders = 0, orders_rejected = 0, batches = 0, events_out = 0, saves = 0, loads = 0, minutes = 0 }
	self.drop_n = 0
	self.debug_n = 0
	return self
end

function Host:log(level, text) self.log_fn(level, text) end
function Host:send(topic, payload) self.send_fn(topic, payload) end

-- ---------------------------------------------------------------------------------------------------------------------
-- game lifecycle
-- ---------------------------------------------------------------------------------------------------------------------
function Host:new_game(seed, profile, colonists)
	local s = self.cfg.server
	seed = math.floor(U.num(seed, s.seed))
	if seed == 0 then seed = (math.floor(self.real_ms) % 100000) + 7 end
	profile = profile or s.profile
	local ok, w = pcall(World.new, { seed = seed, profile = profile, colonists = colonists or s.colonists, max_dt = 1 })
	if not ok then
		self:log("error", "new_game failed: " .. tostring(w))
		return false, tostring(w)
	end
	self.world = w
	self.survival = Survival.new(seed)
	self.acc = 0
	self.sel, self.other = nil, nil
	self.autopilot = nil
	self.outbox = {}
	self:absorb(w:flush_events())
	self:emit_resync(true)
	self:log("info", string.format("new game: seed %d, profile %s, %d colonists", seed, profile, #w.s.colonists))
	return true
end

-- queue OUT events (sim -> client)
function Host:absorb(evs)
	if not evs then return end
	local ob = self.outbox
	for i = 1, #evs do ob[#ob + 1] = evs[i] end
end

local function pos3(x, y) return { x = x, y = y, z = 0 } end

-- events that describe the CURRENT world to a client that has none of it (join, reconnect, load, new game)
function Host:resync_events()
	local w = self.world
	local s = w.s
	local out = {}
	local now = s.t
	local colonist_mod = require("sim.colonist")
	local grid = require("sim.grid")
	for i = 1, #s.colonists do
		local c = s.colonists[i]
		out[#out + 1] = { type = "colonist_joined", t = now, id = c.id, name = c.name, pos = SU.pos_copy(c.pos), traits = SU.copy(c.traits), start = true }
		local v = colonist_mod.view(c, now)
		v.type, v.t = "colonist_state", now
		out[#out + 1] = v
		if c.job and c.job.steps then
			-- the current step's destination, so a restored ped walks somewhere sensible
			local st = c.job.steps[c.job.i or 1]
			if st and st.pos then
				out[#out + 1] = { type = "colonist_task", t = now, id = c.id, kind = c.job.kind, target = SU.copy(c.job.target or { kind = "pos" }), pos = SU.pos_copy(st.pos),
					step = st.act, class = c.job.class or 1 }
			end
		end
	end
	local BP = require("data.blueprints")
	for i = 1, #s.buildings do
		local b = s.buildings[i]
		if b.state == "built" then
			out[#out + 1] = { type = "construction_done", t = now, id = b.id, bp = b.bp, pos = SU.pos_copy(b.pos), restore = true }
		else
			out[#out + 1] = { type = "place_blueprint", t = now, id = b.id, bp = b.bp, pos = SU.pos_copy(b.pos), materials = SU.copy(BP[b.bp].materials), work = BP[b.bp].work }
			if b.pct and b.pct > 0 then out[#out + 1] = { type = "construction_progress", t = now, id = b.id, bp = b.bp, pct = b.pct } end
		end
	end
	local pw, wt = s.grid.power, s.grid.water
	out[#out + 1] = { type = "set_power", t = now, on = pw.ok and true or false, supply = pw.supply, demand = pw.demand, mains = pw.mains_on and true or false, buildings = {} }
	out[#out + 1] = { type = "set_water", t = now, on = wt.ok and true or false, tank = wt.tank, mains = grid.mains_water_on(self.world) }
	out[#out + 1] = { type = "weather", t = now, kind = s.grid.weather.kind, minutes = math.max(0, s.grid.weather.until_t - now) }
	for i = 1, #s.hordes do
		local h = s.hordes[i]
		if h.mat and h.mat.count > 0 then
			out[#out + 1] = { type = "spawn_horde", t = now, id = h.id, cell = { x = h.cx, y = h.cy }, pos = pos3(h.x, h.y), count = h.mat.count, mix = SU.copy(h.mat.mix),
				heading = { x = h.hx, y = h.hy }, top_up = false }
		end
	end
	for i = 1, #s.raids do
		local r = s.raids[i]
		if r.mat and r.mat.count > 0 then
			local fd = FACTIONS.defs[r.faction]
			out[#out + 1] = { type = "spawn_raiders", t = now, id = r.id, faction = r.faction, name = fd and fd.name or r.faction, count = r.mat.count, pos = pos3(r.x, r.y),
				target = pos3(TUNING.base.x, TUNING.base.y) }
		end
	end
	for i = 1, #s.caravans do
		local c = s.caravans[i]
		local fd = FACTIONS.defs[c.faction]
		local stock = {}
		for _, it in ipairs(items.list(c.stock)) do stock[it.id] = it.n end
		out[#out + 1] = { type = "caravan", t = now, phase = "arrive", id = c.id, faction = c.faction, name = fd and fd.name or c.faction, leave_t = c.leave_t, stock = stock,
			pos = pos3(TUNING.base.garage.x + 10, TUNING.base.garage.y + 15) }
	end
	for i = 1, #s.piles do
		local p = s.piles[i]
		local map = {}
		for _, it in ipairs(items.list(p.items)) do map[it.id] = it.n end
		out[#out + 1] = { type = "loot_spawn", t = now, container = "pile:" .. p.id, items = map, source = "restore", pos = SU.pos_copy(p.pos) }
	end
	return out
end

-- queue a full resync; `reset` tells the client to drop everything it has first
function Host:emit_resync(reset)
	if not self.world then return end
	local evs = self:resync_events()
	self:flush_events(reset and true or false, evs)
end

-- ---------------------------------------------------------------------------------------------------------------------
-- network batching
-- ---------------------------------------------------------------------------------------------------------------------
-- send the outbox (or `evs`) in messages of at most max_events_per_msg events. `reset` marks the first message of a resync.
function Host:flush_events(reset, evs)
	local list = evs
	if not list then list = self.outbox; self.outbox = {} end
	if #list == 0 and not reset then return 0 end
	local per = self.cfg.server.max_events_per_msg
	local sent, i = 0, 1
	local first = true
	repeat
		local chunk = {}
		for k = i, math.min(i + per - 1, #list) do chunk[#chunk + 1] = list[k] end
		self.seq = self.seq + 1
		local msg = { seq = self.seq, t = self.world and self.world.s.t or 0, events = chunk }
		if reset and first then msg.reset = true end
		first = false
		self.stats.batches = self.stats.batches + 1
		self.stats.events_out = self.stats.events_out + #chunk
		self:send(P.NET.events, msg)
		sent = sent + #chunk
		i = i + per
	until i > #list
	return sent
end

-- ---------------------------------------------------------------------------------------------------------------------
-- the fixed-step loop
-- ---------------------------------------------------------------------------------------------------------------------
function Host:effective_scale()
	if self.paused or self.speed == 0 then return 0 end
	return self.cfg.server.time_scale * self.speed
end

-- Sim activity of the player for the survival body: resting while the owner stands still is decided by the caller (client reports
-- `player_state`); the host keeps it simple: work while moving, idle otherwise.
function Host:player_activity()
	return self.player_activity_hint or "idle"
end

-- advance the host by `dt_ms` real milliseconds. Returns the number of sim minutes that were ticked.
function Host:advance(dt_ms)
	local w = self.world
	if not w then return 0 end
	dt_ms = math.max(0, math.min(dt_ms, 5000))
	self.real_ms = self.real_ms + dt_ms
	local s = self.cfg.server
	self.in_tokens = math.min(s.max_in_per_sec * 2, self.in_tokens + dt_ms / 1000 * s.max_in_per_sec)
	local ticked = 0
	if not w.s.over then
		self.acc = self.acc + dt_ms / 1000 * self:effective_scale() / 60 -- game minutes
		local due = math.floor(self.acc)
		if due > 0 then
			if due > s.max_catchup_min then
				self.acc = self.acc - due + s.max_catchup_min -- drop the excess: never spiral
				due = s.max_catchup_min
			end
			self.acc = self.acc - due
			for _ = 1, due do
				self:absorb(w:tick(1))
				local notices = self.survival:step(1, self:player_activity(), w.s.t)
				for k = 1, #notices do self:on_survival_notice(notices[k]) end
				ticked = ticked + 1
				if w.s.over then break end
			end
			self.stats.minutes = self.stats.minutes + ticked
			if self.autopilot and w.s.t - self.last_policy_t >= require("sim.ai_policy").CFG.period then
				self.last_policy_t = w.s.t
				local sink = {}
				require("sim.ai_policy").step(w, self.autopilot, sink)
				self:absorb(sink)
			end
		end
	end
	self:flush_events()
	self:push_periodic()
	if s.autosave_s > 0 and self.real_ms >= self.next.autosave then
		self.next.autosave = self.real_ms + s.autosave_s * 1000
		if self.store and not w.s.over then self:save_game("autosave") end
	end
	return ticked
end

function Host:on_survival_notice(n)
	if n.kind == "starving" then self:toast("warn", "You are starving.")
	elseif n.kind == "dehydrated" then self:toast("warn", "You are badly dehydrated.")
	elseif n.kind == "infection_symptomatic" then self:toast("bad", "You feel feverish.")
	elseif n.kind == "infection_terminal" then self:toast("bad", "You are getting much worse.")
	elseif n.kind == "downed" then self:toast("bad", "You are down!")
	elseif n.kind == "died" then self:toast("bad", "You died (" .. tostring(n.cause) .. ").")
		self:absorb(self.world:handle({ type = "ped_died", id = "player", cause = n.cause })) end
end

function Host:toast(level, text) self:send(P.NET.ui, { name = "toast", data = { level = level, text = text } }) end

-- periodic pushes: clock, HUD, and (while a colony screen is open) the full UI state
function Host:push_periodic()
	local s = self.cfg.server
	local w = self.world
	if not w then return end
	local now = self.real_ms
	if now >= self.next.clock then
		self.next.clock = now + 1000
		local t = w.s.t
		self:send(P.NET.clock, { t = t, day = clock.day(t), hour = clock.hour(t), minute = math.floor(clock.minute(t)), scale = self:effective_scale() / 60, speed = self.speed })
	end
	if now >= self.next.hud then
		self.next.hud = now + 1000 / s.hud_hz
		self:send(P.NET.hud, self:hud_payload())
	end
	if self.ui_open and now >= self.next.state then
		self.next.state = now + 1000 / s.ui_hz
		self:push_state()
	end
end

function Host:hud_payload()
	local h = V.hud(self.world, self.survival:view(), { speed = self.speed, paused = self.paused })
	h.fx = self.survival:effects()
	return h
end

function Host:state_view()
	return V.state(self.world, { select = self.sel, speed = self.speed, paused = self.paused or self.speed == 0, scale = self:effective_scale() / 60 })
end

function Host:push_state()
	if not self.world then return end
	self:send(P.NET.state, self:state_view())
end

function Host:push_inventory()
	if not self.world then return end
	self:send(P.NET.ui, { name = "inventory", data = V.inventory(self.world, { other = self.other }) })
end

-- ---------------------------------------------------------------------------------------------------------------------
-- IN events and orders (from the client)
-- ---------------------------------------------------------------------------------------------------------------------
local function take_token(self)
	if self.in_tokens < 1 then self.stats.in_dropped = self.stats.in_dropped + 1; return false end
	self.in_tokens = self.in_tokens - 1
	return true
end

-- one raw IN event table from the client. Returns true if it reached the sim (or the survival body)
function Host:on_client_event(raw)
	if not self.world then return false end
	if not take_token(self) then return false end
	if type(raw) == "table" and raw.type == "player_damage" then
		local amount = U.num(raw.amount)
		local kind = (type(raw.kind) == "string" and #raw.kind < 12) and raw.kind or "blunt"
		if amount and amount > 0 then
			local _, v = self.survival:damage(kind, math.min(amount, 500), type(raw.part) == "string" and raw.part or nil)
			if v and v.kind == "died" then self:on_survival_notice({ kind = "died", cause = v.cause }) end
			self.stats.in_ok = self.stats.in_ok + 1
			return true
		end
		self.stats.in_rejected = self.stats.in_rejected + 1
		return false
	end
	local ev, why = P.sanitize_in(raw)
	if not ev then
		self.stats.in_rejected = self.stats.in_rejected + 1
		if self.cfg.server.debug then self:log("warn", "rejected IN event: " .. tostring(why)) end
		return false
	end
	if ev.type == "player_state" and ev.needs then ev.needs = nil end -- the host owns the player's needs (shared/survival.lua)
	if ev.type == "player_state" then self.player_activity_hint = (raw.moving and "work") or "idle" end
	self:absorb(self.world:handle(ev))
	self.stats.in_ok = self.stats.in_ok + 1
	if ev.type == "ped_died" and ev.id == "player" then self.survival.c.hp = 0; self.survival.c.dead = true end
	return true
end

function Host:on_client_events(list)
	if type(list) ~= "table" then return 0 end
	local n = 0
	for i = 1, math.min(#list, 120) do
		if self:on_client_event(list[i]) then n = n + 1 end
	end
	self:flush_events()
	return n
end

-- one player order (priority, draft, goto, place_blueprint ...). The sim answers with order_result in the next batch.
function Host:on_order(raw)
	if not self.world then return false end
	local ev, why = P.sanitize_order(raw)
	self.stats.orders = self.stats.orders + 1
	if not ev then
		self.stats.orders_rejected = self.stats.orders_rejected + 1
		self:send(P.NET.events, { seq = self.seq, t = self.world.s.t, events = { { type = "order_result", t = self.world.s.t, id = type(raw) == "table" and raw.id or nil,
			kind = type(raw) == "table" and tostring(raw.kind):sub(1, 24) or nil, ok = false, reason = "rejected:" .. tostring(why) } } })
		return false
	end
	if ev.kind == "set_profile" and ev.target ~= "calm" and ev.target ~= "escalating" and ev.target ~= "chaos" then
		self.stats.orders_rejected = self.stats.orders_rejected + 1
		return false
	end
	self:absorb(self.world:handle(ev))
	self:flush_events()
	if self.ui_open then self:push_state() end
	return true
end

-- ---------------------------------------------------------------------------------------------------------------------
-- UI actions (NUI -> host)
-- ---------------------------------------------------------------------------------------------------------------------
local function loc(v)
	if type(v) ~= "table" then return nil end
	local kind, id = v.kind, v.id
	if kind == "player" then return { kind = "player" } end
	if kind == "void" then return { kind = "void" } end
	if (kind == "zone" or kind == "pile" or kind == "colonist" or kind == "container") and type(id) == "string" and #id <= 64 then return { kind = kind, id = id } end
	return nil
end

function Host:ui_action(name, data)
	data = type(data) == "table" and data or {}
	local w = self.world
	if name == "request_catalog" then
		self:send(P.NET.catalog, V.catalog())
		return true
	end
	if not w then return false end
	if name == "request_state" then
		self:push_state(); self:send(P.NET.hud, self:hud_payload())
		return true
	elseif name == "request_summary" then
		self:send(P.NET.ui, { name = "summary", data = V.summary(w) })
		return true
	elseif name == "screens" then
		self.ui_open = data.colony == true
		if self.ui_open then self.next.state = 0 end
		return true
	elseif name == "select" then
		local id = data.id
		if type(id) == "string" and w:colonist(id) then self.sel = id else self.sel = nil end
		self:push_state()
		return true
	elseif name == "inventory" then
		local o = loc(data.other)
		self.other = (o and o.kind ~= "player" and o.kind ~= "void") and o or nil
		self:push_inventory()
		return true
	elseif name == "inventory_move" then
		local from, to = loc(data.from), loc(data.to)
		local item, n = data.item, math.floor(U.num(data.n, 0))
		if not from or not to or type(item) ~= "string" or not ITEMS[item] or n < 1 then return false end
		if n > 999 then n = 999 end
		self:absorb(w:handle({ type = "item_moved", from = from, to = to, item = item, n = n }))
		self:flush_events()
		self:push_inventory()
		self:send(P.NET.hud, self:hud_payload())
		return true
	elseif name == "use_item" then
		local item = data.item
		if type(item) ~= "string" or not ITEMS[item] or items.count(w.s.player.inv, item) < 1 then return false end
		local ok, msg = self.survival:use(item, w.s.t)
		if ok then
			self:absorb(w:handle({ type = "item_moved", from = { kind = "player" }, to = { kind = "void" }, item = item, n = 1 }))
			self:flush_events()
			self:push_inventory()
			self:send(P.NET.hud, self:hud_payload())
		end
		self:toast(ok and "good" or "warn", msg)
		return ok
	elseif name == "drop_item" then
		local item, n = data.item, math.floor(U.num(data.n, 1))
		if type(item) ~= "string" or not ITEMS[item] or n < 1 then return false end
		self.drop_n = self.drop_n + 1
		local ref = "drop:" .. self.drop_n
		self:absorb(w:handle({ type = "item_moved", from = { kind = "player" }, to = { kind = "container", id = ref }, item = item, n = n }))
		local pp = w.s.player.pos or { x = TUNING.base.x, y = TUNING.base.y, z = 0 }
		self:absorb({ { type = "loot_spawn", t = w.s.t, container = ref, items = { [item] = n }, source = "drop", pos = SU.pos_copy(pp) } })
		self:flush_events()
		self:push_inventory()
		return true
	elseif name == "set_speed" then
		local sp = math.floor(U.num(data.speed, 1))
		if not SPEEDS[sp] then return false end
		self.speed = sp
		self.paused = (sp == 0)
		self:push_state()
		return true
	elseif name == "toggle_pause" then
		self.paused = not self.paused
		self:push_state()
		return true
	elseif name == "save" then
		return self:save_game("manual")
	elseif name == "load" then
		return self:load_game()
	elseif name == "new_game" then
		local profile = data.profile
		if profile ~= "calm" and profile ~= "escalating" and profile ~= "chaos" then profile = nil end
		return self:new_game(data.seed, profile, nil)
	elseif name == "player_respawn" then
		self.survival:respawn()
		return true
	elseif name:sub(1, 6) == "debug_" then
		return self:debug(name:sub(7), data)
	end
	return false
end

-- ---------------------------------------------------------------------------------------------------------------------
-- debug / admin tools (guarded by the caller: /outbreak_* commands and the preview's bench panel)
-- ---------------------------------------------------------------------------------------------------------------------
function Host:debug(cmd, a)
	local w = self.world
	if not w then return false, "no world" end
	a = type(a) == "table" and a or {}
	local horde = require("sim.horde")
	local director = require("sim.director")
	if cmd == "horde" then
		-- a horde of n near the base (dist units out), seeking the base. `siege = true` places it on the base ring.
		local n = math.floor(U.clamp(U.num(a.n, 20), 1, 120))
		local dist = U.clamp(U.num(a.dist, 260), 5, 2000)
		local dir = horde.DIRS[(self.debug_n % #horde.DIRS) + 1]
		self.debug_n = self.debug_n + 1
		local mix = { walker = n }
		if n >= 10 then mix.runner = math.floor(n / 5); mix.walker = n - mix.runner end
		if n >= 25 then mix.brute = 1; mix.walker = mix.walker - 1 end
		local b = TUNING.base
		local h = horde.spawn(w, { x = b.x + dir[1] * dist, y = b.y + dir[2] * dist, mix = mix, target = { x = b.x, y = b.y }, src = "debug" })
		if not h then return false, "spawn failed" end
		self:toast("warn", string.format("Debug: horde of %d placed %d m out.", n, dist))
		return true, h.id
	elseif cmd == "event" then
		local id = a.id
		if type(id) ~= "string" or not EVENTS[id] then return false, "unknown event" end
		local d = w.s.director
		local need = EVENTS[id].fixed_cost or EVENTS[id].min_cost or 0
		if d.budget < need then d.budget = need end -- debug top-up so the event can fire
		local detail, why = director.force(w, id)
		self:absorb(w:flush_events())
		self:flush_events()
		if not detail then return false, why end
		return true, detail
	elseif cmd == "give" then
		local item, n = a.item, math.floor(U.num(a.n, 1))
		if type(item) ~= "string" or not ITEMS[item] then return false, "unknown item" end
		self:absorb(w:handle({ type = "item_moved", from = { kind = "void" }, to = { kind = "player" }, item = item, n = math.max(1, n) }))
		self:flush_events()
		return true
	elseif cmd == "player_pos" then
		local x, y = U.num(a.x), U.num(a.y)
		if not x or not y then return false, "bad pos" end
		self:absorb(w:handle({ type = "player_state", pos = { x = x, y = y, z = 0 } }))
		self:flush_events()
		return true
	elseif cmd == "autopilot" then
		if a.on == false then self.autopilot = nil else self.autopilot = require("sim.ai_policy").new() end
		return true, self.autopilot ~= nil
	elseif cmd == "fast_forward" then
		local minutes = math.floor(U.clamp(U.num(a.minutes, 60), 1, 60 * 24 * 40))
		local ticked = 0
		local policy = require("sim.ai_policy")
		while ticked < minutes and not w.s.over do
			local chunk = math.min(10, minutes - ticked)
			self:absorb(w:tick(chunk))
			ticked = ticked + chunk
			if self.autopilot then
				local sink = {}
				policy.step(w, self.autopilot, sink)
				self:absorb(sink)
			end
			if #self.outbox > 400 then self:flush_events() end
		end
		self:flush_events()
		return true, ticked
	elseif cmd == "time_set" then
		self:absorb(w:handle({ type = "time_set", hour = U.num(a.hour, 12), minute = U.num(a.minute, 0), day = a.day and U.num(a.day) or nil }))
		self:flush_events()
		return true
	elseif cmd == "kill_colonist" then
		local c = w:colonist(a.id)
		if not c then return false, "no such colonist" end
		self:absorb(w:handle({ type = "ped_died", id = c.id, cause = "debug" }))
		self:flush_events()
		return true
	elseif cmd == "damage_colonist" then
		self:absorb(w:handle({ type = "ped_damage", id = a.id, amount = U.num(a.amount, 20), kind = type(a.kind) == "string" and a.kind or "bite", part = a.part }))
		self:flush_events()
		return true
	elseif cmd == "audit" then
		local ok, rep = w:audit()
		return ok, rep
	end
	return false, "unknown debug command"
end

-- ---------------------------------------------------------------------------------------------------------------------
-- persistence (versioned wrapper around the sim's own checksummed save)
-- ---------------------------------------------------------------------------------------------------------------------
local function wrap(tbl)
	local body = save.serialize(tbl)
	return string.format("OBHOST %d %d %s\n", Host.SAVE_FMT, #body, SU.hash(body)) .. body
end

local function unwrap(str)
	if type(str) ~= "string" then return nil, "empty slot" end
	local fmt, len, hash, rest = str:match("^OBHOST (%d+) (%d+) (%x+)\n()")
	if not fmt then return nil, "not an Outbreak host save" end
	fmt, len = tonumber(fmt), tonumber(len)
	local body = str:sub(rest)
	if #body ~= len then return nil, "truncated host save" end
	if SU.hash(body) ~= hash then return nil, "corrupt host save (checksum)" end
	if fmt > Host.SAVE_FMT then return nil, "host save is from a newer version (" .. fmt .. ")" end
	local ok, t = pcall(save.deserialize, body)
	if not ok or type(t) ~= "table" then return nil, "unreadable host save" end
	return t
end
Host._wrap, Host._unwrap = wrap, unwrap

local function read_meta(store)
	local raw = store.get(KEY_META)
	if not raw then return nil end
	local ok, t = pcall(save.deserialize, raw)
	if ok and type(t) == "table" then return t end
	return nil
end

-- write to the slot that is NOT the latest, then flip the pointer: a crash mid-write can never destroy the last good save
function Host:save_game(reason)
	if not self.store then return false, "no store" end
	local w = self.world
	if not w then return false, "no world" end
	local ok, blob = pcall(save.save, w)
	if not ok then self:log("error", "save failed: " .. tostring(blob)); return false, tostring(blob) end
	local meta = read_meta(self.store) or { fmt = Host.SAVE_FMT, latest = "b", slots = {} }
	local slot = (meta.latest == "a") and "b" or "a"
	local pack = wrap({ fmt = Host.SAVE_FMT, game = blob, extras = { survival = self.survival:save(), speed = self.speed, drop_n = self.drop_n, debug_n = self.debug_n },
		info = { day = clock.day(w.s.t), t = w.s.t, seed = w.s.seed, profile = w.s.profile, colonists = #w.s.colonists, reason = reason or "manual" } })
	self.store.set(slot == "a" and KEY_A or KEY_B, pack)
	meta.latest = slot
	meta.slots = meta.slots or {}
	meta.slots[slot] = { day = clock.day(w.s.t), t = w.s.t, seed = w.s.seed, bytes = #pack, reason = reason or "manual", hash = w:hash() }
	self.store.set(KEY_META, save.serialize(meta))
	self.stats.saves = self.stats.saves + 1
	self:log("info", string.format("saved (%s) slot %s, %d bytes, day %d", reason or "manual", slot, #pack, clock.day(w.s.t)))
	return true, slot
end

-- load the newest valid slot (falls back to the other one). On failure the current game is untouched.
function Host:load_game()
	if not self.store then return false, "no store" end
	local meta = read_meta(self.store)
	if not meta then return false, "no save found" end
	local order = { meta.latest == "b" and "b" or "a", meta.latest == "b" and "a" or "b" }
	local errs = {}
	for _, slot in ipairs(order) do
		local t, err = unwrap(self.store.get(slot == "a" and KEY_A or KEY_B))
		if t then
			local w, e2 = save.load(t.game, { max_dt = 1 })
			if w then
				local sv = Survival.load(t.extras and t.extras.survival) or Survival.new(w.s.seed)
				self.world = w
				self.survival = sv
				self.speed = (t.extras and SPEEDS[t.extras.speed]) and t.extras.speed or 1
				self.paused = false
				self.drop_n = (t.extras and t.extras.drop_n) or 0
				self.debug_n = (t.extras and t.extras.debug_n) or 0
				self.acc, self.sel, self.other = 0, nil, nil
				self.autopilot = nil
				self.outbox = {}
				self:emit_resync(true)
				self.stats.loads = self.stats.loads + 1
				self:log("info", string.format("loaded slot %s: day %d, hash %s", slot, clock.day(w.s.t), w:hash()))
				return true, slot
			end
			errs[#errs + 1] = slot .. ": " .. tostring(e2)
		else
			errs[#errs + 1] = slot .. ": " .. tostring(err)
		end
	end
	self:log("warn", "load failed: " .. table.concat(errs, "; "))
	return false, table.concat(errs, "; ")
end

function Host:list_saves()
	if not self.store then return {} end
	local meta = read_meta(self.store)
	local out = {}
	if meta and meta.slots then
		for _, k in ipairs(SU.keys(meta.slots)) do
			local m = meta.slots[k]
			out[#out + 1] = { slot = k, latest = (meta.latest == k), day = m.day, seed = m.seed, bytes = m.bytes, reason = m.reason }
		end
	end
	return out
end

function Host:status()
	local w = self.world
	if not w then return { world = false } end
	local s = w.s
	local horde = require("sim.horde")
	return {
		world = true, hash = w:hash(), day = clock.day(s.t), time = clock.fmt(s.t), t = s.t, seed = s.seed, profile = s.profile, over = s.over,
		colonists = #s.colonists, hordes = #s.hordes, materialized = horde.materialized_count(w), raids = #s.raids, buildings = #s.buildings,
		speed = self.speed, paused = self.paused, scale = self:effective_scale(), budget = SU.fmt_num(U.r1(s.director.budget)), autopilot = self.autopilot ~= nil,
		stats = SU.copy(self.stats),
	}
end

return Host
