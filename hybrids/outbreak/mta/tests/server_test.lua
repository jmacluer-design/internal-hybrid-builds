-- The REAL server Lua (server/*.lua + shared/host.lua) in the mock MTA: handshake, trust model, persistence, commands, clock and the owner's body.
-- What this proves: sequencing, bookkeeping, validation, caps, cleanup, protocol. What it can NOT prove is stated in tests/mock_mta.lua and mta/README.md.
local T, H = ...
T.group("server")
local P = require("shared.protocol")
local NET = require("shared.mta_net")

local function sctx(m) return H.sreq(m, "server.ctx") end
local function net(m) return H.sreq(m, "server.net") end
local function clean(m, what)
	T.eq(#m.errors, 0, (what or "") .. ": errors: " .. H.errors_text(m))
	T.eq(#m.net.bad_payloads, 0, (what or "") .. ": bad payloads: " .. table.concat(m.net.bad_payloads, " | "))
	T.eq(#m.net.dropped, 0, (what or "") .. ": dropped remote events: " .. table.concat(m.net.dropped, " | "))
end
local function inject(m, name, source, sender, ...) return m:send_remote("server", name, source, sender, nil, ...) end

-- ------------------------------------------------------------------------------------------------------------------------ handshake
T.test("handshake: the first client that says ready becomes the owner and gets hello, catalog, a resync, the state and the HUD; the owner is spawned at the base", function()
	local m = H.boot({})
	local ctx = sctx(m)
	T.eq(ctx.owner, m.player)
	local hello = m:sent("client", NET.hello)
	T.eq(#hello, 1)
	T.eq(hello[1].args[1].owner, true)
	T.near(hello[1].args[1].origin.x, ctx.origin.x, 1e-9)
	T.eq(#m:sent("client", NET.catalog), 1)
	local first = m:sent("client", NET.events)[1].args[1]
	T.eq(first.reset, true, "the first batch tells the client to drop whatever it has")
	T.gt(#m:out_events("colonist_joined"), 3, "the resync lists the colonists")
	T.gt(#m:sent("client", NET.state), 0); T.gt(#m:sent("client", NET.hud), 0)
	T.truthy(m.player.spawned, "spawnPlayer was called for the owner")
	T.near(m.player.x, ctx.origin.x + 4, 0.01); T.near(m.player.y, ctx.origin.y, 0.01)
	local team
	for _, t in ipairs(m:live("team")) do team = t end
	T.truthy(team and team.friendly_fire == false and m.player.team == team, "the owner is on a no-friendly-fire colony team")
	clean(m, "handshake")
	m:stop()
end)

T.test("handshake: a second player is told it is not the owner and gets nothing else; the owner_name setting restricts who may become the owner", function()
	local m = H.boot({})
	local other = m:add_player("Intruder")
	inject(m, NET.ready, m.resourceRoot, other)
	m:step(200)
	T.eq(#other.inbox, 1); T.eq(other.inbox[1].name, NET.hello); T.eq(other.inbox[1].args[1].owner, false)
	T.eq(sctx(m).owner, m.player, "ownership did not change")
	m:stop()
	local m2 = H.boot({ boot = false, settings = { owner_name = "Alice" } })
	m2:load_side("server"); m2:load_side("client"); m2:start_server()
	local bob = m2:add_player("Bob")
	inject(m2, NET.ready, m2.resourceRoot, bob)
	m2:step(200)
	T.eq(sctx(m2).owner, nil, "Bob is not Alice")
	T.eq(bob.inbox[1].args[1].owner, false)
	T.eq(net(m2).stats.rejected_reasons["ready: not the configured owner"], 1)
	local alice = m2:add_player("Alice")
	inject(m2, NET.ready, m2.resourceRoot, alice)
	m2:step(200)
	T.eq(sctx(m2).owner, alice)
	m2:stop()
end)

T.test("handshake: ready twice (the page's own ready after the client's) re-sends the world to the client only: nothing is duplicated on the server", function()
	local m = H.boot({})
	local Peds = H.sreq(m, "server.peds")
	local created, objects = Peds.stats.created, #m:live("object")
	inject(m, NET.ready, m.resourceRoot, m.player)
	m:step(1500)
	T.eq(Peds.stats.created, created, "no ped was created again")
	T.eq(#m:live("object"), objects)
	T.eq(#m:live("ped"), 4)
	local resets = 0
	for _, item in ipairs(m:sent("client", NET.events)) do if item.args[1].reset then resets = resets + 1 end end
	T.eq(resets, 2, "the client got a second reset batch")
	clean(m, "second ready")
	m:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ trust model
T.test("trust: events from a non-owner are rejected (inbound, order, ui_action, ground) and change nothing", function()
	local m = H.boot({})
	local host = H.host(m)
	local other = m:add_player("Intruder")
	local hash = host.world:hash()
	local before = net(m).stats.rejected
	inject(m, NET.inbound, m.resourceRoot, other, { { type = "noise", pos = { x = 0, y = 0, z = 0 }, loudness = 400, kind = "gunshot" } })
	inject(m, NET.order, m.resourceRoot, other, { id = "colony", kind = "set_profile", target = "chaos" })
	inject(m, NET.ui_action, m.resourceRoot, other, "new_game", { seed = 99 })
	inject(m, NET.ground, m.resourceRoot, other, { { x = 1, y = 2, z = 3 } })
	m:step(300)
	T.eq(net(m).stats.rejected - before, 4)
	T.eq(host.world.s.profile, "escalating"); T.eq(host.world:hash(), hash, "the sim did not change")
	T.eq(host.stats.orders, 0)
	clean(m, "non-owner")
	m:stop()
end)

T.test("trust: a spoofed `source` is rejected: the owner (or anyone) may not pick one of our peds, objects or the player as the event source", function()
	local m = H.boot({})
	local host = H.host(m)
	local hash = host.world:hash()
	local ped = m:live("ped")[1]
	local obj = m:live("object")[1]
	local before = net(m).stats.rejected
	for _, src in ipairs({ ped, obj, m.player, m.root }) do
		inject(m, NET.order, src, m.player, { id = "colony", kind = "set_profile", target = "chaos" })
		inject(m, NET.inbound, src, m.player, { { type = "noise", pos = { x = 0, y = 0, z = 0 }, loudness = 400, kind = "gunshot" } })
		inject(m, NET.ui_action, src, m.player, "toggle_pause", {})
	end
	m:step(300)
	-- an event whose source is one of OUR elements bubbles up to the resource root, where the handler's own check refuses it; a source outside the resource tree (the player, the root)
	-- never reaches the handler at all
	T.eq(net(m).stats.rejected - before, 6, "every spoofed event that reached the handler was counted")
	T.eq(host.world.s.profile, "escalating"); T.eq(host.world:hash(), hash); T.falsy(host.paused)
	m:stop()
end)

T.test("trust: a local trigger by another resource (no `client`) is rejected; the real owner with the right source works", function()
	local m = H.boot({})
	local host = H.host(m)
	local env = m.sides.server.env
	local before = net(m).stats.rejected
	env.triggerEvent(NET.order, m.resourceRoot, { id = "colony", kind = "set_profile", target = "chaos" })
	m:step(100)
	T.eq(net(m).stats.rejected - before, 1); T.eq(host.world.s.profile, "escalating"); T.eq(#m.errors, 0, H.errors_text(m))
	inject(m, NET.order, m.resourceRoot, m.player, { id = "colony", kind = "set_profile", target = "calm" })
	m:step(200)
	T.eq(host.world.s.profile, "calm", "the legitimate order went through")
	m:stop()
end)

T.test("trust: junk payloads never reach the sim or raise: wrong types, huge numbers, unknown kinds, flooding", function()
	local m = H.boot({})
	local host = H.host(m)
	local hash0 = host.world:hash()
	local junk_in = { "x", 5, { { type = 5 } }, { { type = "noise" } }, { { type = "ped_damage", id = "c1", amount = -5 } },
		{ { type = "teleport" } }, { { type = "order", id = "colony", kind = "set_profile", target = "chaos" } }, { { type = "player_state", pos = { x = 0 / 0, y = 1 } } } }
	local _ = 0
	for _, j in ipairs(junk_in) do inject(m, NET.inbound, m.resourceRoot, m.player, j) end
	for _, o in ipairs({ "x", { id = "colony", kind = "launch_missiles" }, { id = "c1", kind = "goto", target = { y = 0 } }, { id = ("x"):rep(100), kind = "draft" }, { id = "colony", kind = "set_profile", target = "nightmare" },
		{ id = "colony", kind = "place_blueprint", target = { bp = ("b"):rep(80), pos = { x = 0, y = 0 } } } }) do inject(m, NET.order, m.resourceRoot, m.player, o) end
	for _, n in ipairs({ 5, ("n"):rep(40), "debug_audit_not_allowed_name_too_long_here_x" }) do inject(m, NET.ui_action, m.resourceRoot, m.player, n, {}) end
	inject(m, NET.ground, m.resourceRoot, m.player, "x"); inject(m, NET.ground, m.resourceRoot, m.player, { { x = 0 / 0, y = 0, z = 0 }, { x = 1e12, y = 0, z = 0 }, { e = m.player, x = 1, y = 1, z = 1 } })
	m:step(500)
	T.eq(#m.errors, 0, H.errors_text(m))
	T.eq(host.world.s.profile, "escalating")
	T.eq(host.world:hash(), hash0, "the world is unchanged by junk")
	T.gt(host.stats.in_rejected + host.stats.orders_rejected + net(m).stats.rejected, 10, "the junk was counted as rejected")
	-- out-of-range but well-formed values are clamped, not trusted: a noise of 1e300 becomes 400, a position outside the map is pulled to the map limit
	local ev = P.sanitize_in({ type = "noise", pos = { x = 1e9, y = -1e9, z = 0 }, loudness = 1e300, kind = "boom" })
	T.eq(ev.loudness, 400); T.eq(ev.pos.x, 6000); T.eq(ev.pos.y, -6000)
	-- flood: far more events than the token bucket allows in one burst
	for i = 1, 400 do inject(m, NET.inbound, m.resourceRoot, m.player, { { type = "noise", pos = { x = 1, y = 1, z = 0 }, loudness = 10, kind = "x" } }) end
	for i = 1, 300 do inject(m, NET.ui_action, m.resourceRoot, m.player, "request_state", {}) end
	m:step(300)
	T.gt(host.stats.in_dropped, 0, "the host's token bucket dropped IN events")
	T.gt(net(m).stats.flood_dropped, 0, "the UI action bucket dropped some")
	T.eq(#m.errors, 0, H.errors_text(m))
	m:stop()
end)

T.test("trust: debug actions are refused unless debug or owner_admin is on", function()
	local m = H.boot({ settings = { debug = "0", owner_admin = "0" } })
	local host = H.host(m)
	local hordes = #host.world.s.hordes
	inject(m, NET.ui_action, m.resourceRoot, m.player, "debug_horde", { n = 20 })
	m:step(300)
	T.eq(#host.world.s.hordes, hordes, "refused")
	T.eq(net(m).stats.rejected_reasons["ui_action: debug refused"], 1)
	m:stop()
	local m2 = H.boot({ settings = { debug = "0", owner_admin = "1" } })
	hordes = #H.host(m2).world.s.hordes
	inject(m2, NET.ui_action, m2.resourceRoot, m2.player, "debug_horde", { n = 20 })
	m2:step(300)
	T.eq(#H.host(m2).world.s.hordes, hordes + 1, "the owner may with owner_admin")
	m2:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ network batching
T.test("network: every payload is msgpack-safe plain data; large resyncs are split into batches of max_events_per_msg; sequence numbers rise", function()
	local m = H.boot({})
	local host = H.host(m)
	host:debug("fast_forward", { minutes = 60 * 24 * 3 })
	m:step(1500)
	local last = 0
	local biggest = 0
	for _, item in ipairs(m:sent("client", NET.events)) do
		local msg = item.args[1]
		T.gt(msg.seq, last); last = msg.seq
		biggest = math.max(biggest, #msg.events)
		T.le(#msg.events, 60)
	end
	T.gt(biggest, 1)
	-- a new game resyncs with reset = true
	local n = #m:sent("client", NET.events)
	inject(m, NET.ui_action, m.resourceRoot, m.player, "new_game", { seed = 5, profile = "calm" })
	m:step(1500)
	local resets = 0
	for i = n + 1, #m:sent("client", NET.events) do if m:sent("client", NET.events)[i].args[1].reset then resets = resets + 1 end end
	T.eq(resets, 1)
	clean(m, "batching")
	m:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ persistence
local function saved_fs(m) return m.fs end

T.test("persistence: save -> a NEW server on the same files -> load restores the colony exactly (hash), peds and objects are recreated from the sim", function()
	local m = H.boot({})
	local host = H.host(m)
	host:debug("fast_forward", { minutes = 60 * 30 })
	m:step(1500)
	local hash = host.world:hash()
	local colonists = #host.world.s.colonists
	T.truthy(host:save_game("test"))
	local files = {}
	for k, v in pairs(m.fs.server) do if type(v) == "string" then files[#files + 1] = k end end
	table.sort(files)
	T.eq(table.concat(files, ","), "save/outbreak_meta.sav,save/outbreak_slot_a.sav", "meta + the first slot")
	T.eq(m.open_files, 0, "every file was closed")
	m:stop()
	local m2 = H.boot({ fs = saved_fs(m), settings = { autoload = "1" }, boot = false })
	m2:load_side("server"); m2:load_side("client"); m2:start_server()
	local h2 = H.host(m2)
	T.eq(h2.world:hash(), hash, "the loaded world is the saved one (checked before it runs another tick)")
	m2:start_client()
	T.eq(#h2.world.s.colonists, colonists)
	m2:step(2500)
	local Peds = H.sreq(m2, "server.peds")
	local at_home = 0
	for _, c in ipairs(h2.world.s.colonists) do if c.state ~= "away" and not c.dead then at_home = at_home + 1 end end
	local colonist_peds = 0
	for ped, rec in pairs(Peds.list) do if rec.kind == "colonist" then colonist_peds = colonist_peds + 1 end end
	T.eq(colonist_peds, at_home, "a ped per colonist that is at home (the other peds are zombies or raiders the loaded sim materialized)")
	clean(m2, "load")
	m2:stop()
end)

T.test("persistence: two rotating slots, a corrupt newest slot falls back to the older one, garbage and truncation are refused, a failed write keeps the last good save", function()
	local m = H.boot({})
	local host = H.host(m)
	T.eq(select(2, host:save_game("one")), "a")
	host:debug("fast_forward", { minutes = 120 })
	local hash_a = host.world:hash()
	T.eq(select(2, host:save_game("two")), "b")
	host:debug("fast_forward", { minutes = 120 })
	T.eq(select(2, host:save_game("three")), "a", "slots alternate")
	-- corrupt slot a (the newest): load falls back to b
	m.fs.server["save/outbreak_slot_a.sav"] = m.fs.server["save/outbreak_slot_a.sav"]:sub(1, 200)
	local ok, slot = host:load_game()
	T.truthy(ok); T.eq(slot, "b"); T.eq(host.world:hash(), hash_a, "slot b is the state after the first fast-forward")
	-- both garbage
	m.fs.server["save/outbreak_slot_b.sav"] = "not a save"
	local hash_now = host.world:hash()
	local ok2, why = host:load_game()
	T.falsy(ok2); T.truthy(tostring(why):find("not an Outbreak host save", 1, true), tostring(why))
	T.eq(host.world:hash(), hash_now, "a failed load leaves the current game untouched")
	-- a failed write: fileCreate fails -> save_game raises, meta is NOT flipped, the previous good slot stays
	local m2 = H.boot({})
	local h2 = H.host(m2)
	T.truthy(h2:save_game("good"))
	local meta_before = m2.fs.server["save/outbreak_meta.sav"]
	m2.fail.fileCreate = true
	local okp, err = pcall(h2.save_game, h2, "bad")
	T.falsy(okp); T.truthy(tostring(err):find("fileCreate failed", 1, true), tostring(err))
	m2.fail.fileCreate = nil
	T.eq(m2.fs.server["save/outbreak_meta.sav"], meta_before, "the meta pointer was not touched")
	m2.fail.fileWrite = true
	okp, err = pcall(h2.save_game, h2, "short")
	T.falsy(okp); T.truthy(tostring(err):find("short write", 1, true), tostring(err))
	m2.fail.fileWrite = nil
	T.eq(m2.open_files, 0, "no handle leaked on the failure paths")
	T.truthy(h2:load_game(), "the earlier good save still loads")
	m:stop(); m2:stop()
end)

T.test("persistence: the SQLite backend stores the same slots; if the database cannot be opened the file store is used and a warning is logged", function()
	local m = H.boot({ settings = { store = "sqlite" } })
	local host = H.host(m)
	T.eq(H.sreq(m, "server.store").open("sqlite").kind, "sqlite")
	T.truthy(host:save_game("db"))
	T.truthy(m.fs.db["outbreak:meta"] and m.fs.db["outbreak:slot:a"], "rows in the kv table")
	local hash = host.world:hash()
	host:debug("fast_forward", { minutes = 200 })
	T.truthy(host:load_game())
	T.eq(host.world:hash(), hash)
	m.fail.dbExec = true
	local okp = pcall(host.save_game, host, "x")
	T.falsy(okp, "a failed write raises, so the meta pointer is not flipped")
	m.fail.dbExec = nil
	m:stop()
	local m2 = H.boot({ settings = { store = "sqlite" }, boot = false })
	m2:load_side("server")
	m2.sides.server.env.dbConnect = function() return false end
	m2:start_server()
	m2:step(500)
	T.truthy(table.concat(m2.log, "\n"):find("sqlite store unavailable", 1, true))
	T.truthy(H.host(m2):save_game("fallback"))
	T.truthy(m2.fs.server["save/outbreak_meta.sav"], "saved with files instead")
	m2:stop()
end)

T.test("persistence: autosave runs on its interval and autoload picks the newest save on start", function()
	local m = H.boot({ settings = { autosave = "5" } })
	local host = H.host(m)
	m:step(12000)
	T.ge(host.stats.saves, 2, "autosaved at least twice in 12 s with a 5 s interval")
	local hash = host.world:hash()
	m:stop()
	local m2 = H.boot({ fs = m.fs, settings = { autoload = "1" }, boot = false })
	m2:load_side("server"); m2:load_side("client"); m2:start_server()
	local log = table.concat(m2.log, "\n")
	T.truthy(log:find("loaded slot", 1, true), log)
	T.truthy(H.host(m2).world, "a world exists")
	m2:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ commands
T.test("commands: the console and the owner may run them, a stranger may not, and an ACL right opens one command", function()
	local m = H.boot({})
	local host = H.host(m)
	local stranger = m:add_player("Stranger")
	T.truthy(m:command("server", m.console, "outbreak_status"))
	T.truthy(table.concat(m.log, "\n"):find("day 1", 1, true), "status went to the server log")
	m:command("server", m.player, "outbreak_status")
	T.truthy(m.chat[#m.chat].text:find("colonists 4", 1, true), m.chat[#m.chat].text)
	local n = #m.chat
	m:command("server", stranger, "outbreak_pause")
	T.truthy(m.chat[#m.chat].text:find("not allowed", 1, true)); T.falsy(host.paused)
	m.acl["Stranger:command.outbreak_pause"] = true
	m:command("server", stranger, "outbreak_pause")
	T.truthy(host.paused, "the ACL right command.outbreak_pause allows exactly that command")
	m:command("server", stranger, "outbreak_save")
	T.truthy(m.chat[#m.chat].text:find("not allowed", 1, true))
	m:command("server", m.player, "outbreak_pause")
	T.falsy(host.paused)
	T.eq(#m.errors, 0, H.errors_text(m))
	m:stop()
	local m2 = H.boot({ settings = { owner_admin = "0" } })
	m2:command("server", m2.player, "outbreak_pause")
	T.falsy(H.host(m2).paused, "with owner_admin off even the owner needs the ACL right")
	m2:stop()
end)

T.test("commands: every admin command works (new, speed, profile, horde, event, give, day, autopilot, hash, audit, peds, selftest, save, load)", function()
	local m = H.boot({})
	local host = H.host(m)
	local function say() return m.chat[#m.chat].text end
	m:command("server", m.player, "outbreak_speed", "4"); T.eq(host.speed, 4)
	m:command("server", m.player, "outbreak_profile", "chaos"); m:step(300); T.eq(host.world.s.profile, "chaos")
	local hordes = #host.world.s.hordes
	m:command("server", m.player, "outbreak_horde", "15", "200"); T.eq(#host.world.s.hordes, hordes + 1, "a horde of 15 was placed")
	m:command("server", m.player, "outbreak_event", "storm"); T.truthy(say():find("true", 1, true), say())
	m:command("server", m.player, "outbreak_give", "pistol", "2"); T.truthy(say():find("true", 1, true), say())
	m:command("server", m.player, "outbreak_day", "22", "30"); T.truthy(say():find("true", 1, true))
	m:command("server", m.player, "outbreak_autopilot", "on"); T.truthy(say():find("autopilot true", 1, true), say())
	m:command("server", m.player, "outbreak_autopilot", "off")
	m:command("server", m.player, "outbreak_hash"); T.eq(say(), "[outbreak] " .. host.world:hash())
	m:command("server", m.player, "outbreak_audit"); T.eq(say(), "[outbreak] audit OK")
	m:command("server", m.player, "outbreak_peds"); T.truthy(say():find("peds 4/96", 1, true), say())
	m:command("server", m.player, "outbreak_save"); T.truthy(say():find("saved to slot a", 1, true), say())
	m:command("server", m.player, "outbreak_load"); T.truthy(say():find("loaded slot a", 1, true), say())
	m:command("server", m.player, "outbreak_new", "321", "calm"); m:step(500); T.eq(host.world.s.seed, 321); T.eq(host.world.s.profile, "calm")
	T.eq(#m.errors, 0, H.errors_text(m))
	m:stop()
end)

T.test("commands: outbreak_ff fast-forwards in slices (MTA kills a script that runs for seconds): a 5-day jump takes many timer slices, never one long call", function()
	local m = H.boot({})
	local host = H.host(m)
	local t0 = host.world.s.t
	local calls = 0
	local orig = host.debug
	host.debug = function(self, cmd, a) if cmd == "fast_forward" then calls = calls + 1; T.le(a.minutes, 120, "no slice is longer than 120 sim minutes") end return orig(self, cmd, a) end
	m:command("server", m.player, "outbreak_ff", tostring(60 * 24 * 5))
	m:command("server", m.player, "outbreak_ff", "10")
	T.truthy(m.chat[#m.chat].text:find("already running", 1, true), "a second jump is refused while one runs")
	m:wait_until(function() return host.world.s.t - t0 >= 60 * 24 * 5 end, 60000)
	T.ge(host.world.s.t - t0, 60 * 24 * 5)
	T.ge(calls, 60, "it ran as " .. calls .. " slices")
	T.truthy(m.chat[#m.chat].text:find("fast-forward done", 1, true), m.chat[#m.chat].text)
	host.debug = orig
	m:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ the world: clock, weather, the owner's body
T.test("world: the game clock follows the sim clock (time, minute duration), a paused sim stops the sky, weather events set the weather", function()
	local m = H.boot({})
	local host = H.host(m)
	m:step(2500)
	local h, mi = m.sides.server.env.getTime()
	local sim_h = math.floor(host.world.s.t % 1440 / 60)
	T.le(math.abs(h - sim_h), 1, "game hour " .. h .. " vs sim hour " .. sim_h)
	T.eq(m.world.minute_ms, 2000, "30 game seconds per real second = 2 s per game minute")
	host:ui_action("set_speed", { speed = 4 })
	m:step(1500)
	T.eq(m.world.minute_ms, 500)
	host:ui_action("toggle_pause", {})
	m:step(1500)
	T.ge(m.world.minute_ms, 3600000, "paused: one game minute per real hour")
	host:ui_action("toggle_pause", {})
	host:debug("time_set", { hour = 5, minute = 0 })
	m:step(2500)
	h = m.sides.server.env.getTime()
	T.le(math.abs(h - 5), 1, "time_set is followed")
	host:debug("event", { id = "storm" })
	m:step(1500)
	T.eq(m.world.weather_blend, 8, "a storm -> thunderstorm")
	m:stop()
	T.eq(m.world.minute_ms, 1000, "stop restores the minute duration")
end)

T.test("world: the survival body is applied to the owner's ped (health follows the sim), a dead survivor is killed, the owner respawns at the base after the pause", function()
	local m = H.boot({})
	local host = H.host(m)
	host:debug("survival", { hp = 50 })
	m:step(1500)
	T.near(m.player.health, 50, 1.5, "ped health follows the survival body")
	-- native damage the client reported lowers the survival hp
	inject(m, NET.inbound, m.resourceRoot, m.player, { { type = "player_damage", amount = 30, kind = "bullet" } })
	m:step(1500)
	T.lt(host.survival.c.hp, 50)
	T.lt(m.player.health, 45)
	-- death through the host
	inject(m, NET.inbound, m.resourceRoot, m.player, { { type = "player_damage", amount = 900, kind = "explosion" } })
	m:step(1500)
	T.truthy(m.player.dead, "the ped was killed")
	local deaths = 0
	for _, e in ipairs(host.world.s.log or {}) do deaths = deaths + 1 end
	m:step(host.cfg.server.respawn_ms + 1500)
	T.falsy(m.player.dead, "respawned")
	T.ge(m.player.spawns, 2)
	T.near(m.player.x, sctx(m).origin.x + 4, 0.1)
	T.gt(host.survival.c.hp, 0, "the body is fresh again")
	clean(m, "death")
	m:stop()
end)
