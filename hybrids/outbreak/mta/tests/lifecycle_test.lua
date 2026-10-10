-- Resource stop / restart, leak accounting, resilience to failures, call budgets. Mock only (tests/mock_mta.lua says what that cannot prove).
local T, H = ...
T.group("lifecycle")
local NET = require("shared.mta_net")
local TUNING = require("data.tuning")

local function origin(m) return H.sreq(m, "server.ctx").origin end
local function describe(list) local t = {} for _, e in ipairs(list) do t[#t + 1] = e.type end return table.concat(t, ",") end

-- a busy world: hordes, a raid, a caravan, piles, buildings, colony view with a ghost, UI open
local function busy(m)
	local host = H.host(m)
	local w = host.world
	local o = origin(m)
	m:player_move_to(o.x + 6, o.y + 6)
	m:step(1500)
	host:debug("horde", { n = 25, dist = 100 })
	host:debug("event", { id = "caravan" })
	local factions = require("sim.factions")
	local r = factions.plan_raid(w, 60, "rustjaw")
	r.x, r.y = TUNING.base.x + 110, TUNING.base.y
	local p = w:pile_for({ x = TUNING.base.x + 20, y = TUNING.base.y + 10, z = 0 })
	require("sim.items").add(p.items, "canned_beans", 3)
	for i = 1, 3 do m:send_remote("server", NET.order, m.resourceRoot, m.player, nil, { id = "colony", kind = "place_blueprint", target = { bp = "crate", pos = { x = TUNING.base.x + i * 7, y = TUNING.base.y + 18, z = 0 } } }) end
	m:step(6000)
	H.client(m).set_mode("colony")
	m:browser_trigger("place", { op = "start", bp = "wall" })
	m:browser_trigger("mouse", { type = "move", x = 0.5, y = 0.5 })
	m:step(1000)
end

T.test("stop: after a busy session nothing the resource created is alive (peds, objects, team, browser, ghost, files), no timer is left, every global setting is back", function()
	local m = H.boot({})
	busy(m)
	T.gt(#m:live("ped"), 8)
	T.gt(#m:live("object"), 4)
	local saved_before = m.fs.server["save/outbreak_meta.sav"]
	m:stop()
	T.eq(#m:live(), 0, "alive after stop: " .. describe(m:live()))
	T.eq(m:live_timers(), 0, "timers left: " .. m:live_timers())
	T.eq(m.open_files, 0)
	T.eq(#m.errors, 0, H.errors_text(m))
	T.truthy(m.fs.server["save/outbreak_meta.sav"] ~= saved_before, "a save was written on stop")
	-- client side
	T.falsy(m.cursor.showing); T.truthy(m.input.all_controls); T.eq(m.input.mode, "allow_binds"); T.eq(m.input.focused_browser, nil); T.falsy(m.player.frozen)
	T.eq(m.cam.matrix_set, false)
	for _, c in ipairs({ "health", "armour", "breath", "money", "clock", "wanted" }) do T.eq(m.hud[c], true) end
	T.eq(m.world.minute_ms, 1000, "the minute duration is restored")
	T.eq(m.player.walk_style, 0)
	-- the engine's own cleanup has nothing left to do (the script did it itself)
	m:engine_cleanup()
	T.eq(#m:live(), 0)
	-- running the stop handlers a second time is harmless too (a stray double call must not raise)
	for _, name in ipairs({ "client", "server" }) do
		m:trigger(m.sides[name], name == "client" and "onClientResourceStop" or "onResourceStop", m.resourceRoot, m.resource)
	end
	T.eq(#m.errors, 0, H.errors_text(m))
end)

T.test("stop during a fast-forward, while placing, with the UI focused and a page callback in flight: no error, no late timer touches destroyed elements", function()
	local m = H.boot({})
	busy(m)
	m:command("server", m.player, "outbreak_ff", tostring(60 * 24 * 10))
	m:step(120)
	m:browser_trigger("order", { id = "c1", kind = "draft", target = true })
	m:send_remote("server", NET.order, m.resourceRoot, m.player, nil, { id = "c1", kind = "draft", target = false }) -- still in the network queue when the resource stops
	m:stop()
	m:send_remote("server", NET.order, m.resourceRoot, m.player, nil, { id = "c1", kind = "draft", target = true }) -- and one that arrives after the stop
	m:send_remote("server", NET.ready, m.resourceRoot, m.player, nil)
	m:step(5000)
	T.eq(#m.errors, 0, H.errors_text(m))
	T.eq(#m:live(), 0)
	T.eq(m:live_timers(), 0)
	T.truthy(#m.net.dropped >= 1, "the in-flight order arrived after the stop and was dropped: " .. table.concat(m.net.dropped, " | "))
	local late = 0
	for _, d in ipairs(m.net.dropped) do if d:find("after the resource stopped", 1, true) then late = late + 1 end end
	T.ge(late, 1, "recorded as arriving after the stop")
end)

T.test("restart: a new server on the same files loads the colony and rebuilds the world; the owner reconnecting gets the world back; no duplicates", function()
	local m = H.boot({})
	busy(m)
	local hash = H.host(m):save_game("t") and H.world(m):hash()
	local peds_before, objects_before = #m:live("ped"), #m:live("object")
	m:stop()
	local m2 = H.boot({ fs = m.fs, settings = { autoload = "1" }, warm_ms = 8000 })
	T.eq(#m2.errors, 0, H.errors_text(m2))
	local Peds = H.sreq(m2, "server.peds")
	local ids = {}
	for _, c in ipairs(H.world(m2).s.colonists) do ids[c.id] = true end
	local by_id = {}
	for ped, rec in pairs(Peds.list) do
		if rec.kind == "colonist" and not ped.dead then T.eq(by_id[rec.tag], nil, "one ped per colonist"); by_id[rec.tag] = ped end
	end
	local n = 0
	for id in pairs(by_id) do T.truthy(ids[id]); n = n + 1 end
	T.gt(n, 0)
	T.le(#m2:live("object"), objects_before + 6)
	-- the owner leaves and comes back: ownership is cleared, the sim is saved, the world is untouched, the new session gets everything
	local ctx = H.sreq(m2, "server.ctx")
	m2:trigger(m2.sides.server, "onPlayerQuit", m2.player, "Quit")
	T.eq(ctx.owner, nil)
	local saves = H.host(m2).stats.saves
	T.ge(saves, 1, "saved when the owner left")
	m2:step(3000)
	T.eq(#m2.errors, 0, H.errors_text(m2))
	local newcomer = m2:add_player("Newcomer")
	m2:send_remote("server", NET.ready, m2.resourceRoot, newcomer, nil)
	m2:step(500)
	T.eq(ctx.owner, newcomer, "a new owner may take over once the old one is gone")
	T.truthy(newcomer.spawned, "and is spawned at the base")
	for ped in pairs(Peds.list) do T.eq(ped.syncer, newcomer, "the new owner's client became the syncer") end
	m2:stop()
	T.eq(#m2:live(), 0)
end)

T.test("resilience: an error inside the host tick, a bad frame in the client, an element destroyed by another resource, and a failing engine call are all survived; the loops keep running", function()
	local m = H.boot({})
	busy(m)
	local host = H.host(m)
	-- 1. the host tick raises three times
	local orig = host.advance
	local raised = 0
	host.advance = function(self, dt) if raised < 3 then raised = raised + 1; error("injected tick failure") end return orig(self, dt) end
	local t0 = host.world.s.t
	m:step(6000)
	host.advance = orig
	T.eq(raised, 3)
	m:step(3000)
	T.gt(host.world.s.t, t0, "the clock kept running after the failures")
	T.gt(H.sreq(m, "server.ctx").stats.errors, 0, "the failures were counted")
	local log = table.concat(m.log, "\n")
	T.truthy(log:find("host failed (1x)", 1, true), "and logged once, not per tick")
	-- 2. a client frame handler fails for a while
	local env = m.sides.client.env
	local real = rawget(env, "getCameraMatrix")
	rawset(env, "getCameraMatrix", function() error("injected camera failure") end)
	m:step(1500)
	rawset(env, "getCameraMatrix", real)
	local errs = H.creq(m, "client.ctx").stats.errors
	T.gt(errs, 0)
	m:step(1500)
	T.eq(H.creq(m, "client.ctx").stats.errors, errs, "once the engine works again no more errors")
	-- 3. another resource destroys our elements under us
	local destroyed = 0
	for _, e in ipairs(m:live("ped")) do if destroyed < 6 then m:destroy_element(e); destroyed = destroyed + 1 end end
	for _, e in ipairs(m:live("object")) do if destroyed < 9 then m:destroy_element(e); destroyed = destroyed + 1 end end
	m:step(8000)
	-- 4. an engine call refusing (createObject / createPed fail for a while)
	m.fail.createObject = true; m.fail.createPed = true
	m:send_remote("server", NET.order, m.resourceRoot, m.player, nil, { id = "colony", kind = "place_blueprint", target = { bp = "bed", pos = { x = TUNING.base.x - 14, y = TUNING.base.y - 12, z = 0 } } })
	host:debug("horde", { n = 10, dist = 90 })
	m:step(6000)
	m.fail.createObject = nil; m.fail.createPed = nil
	m:step(8000)
	local real_errors = {}
	for _, e in ipairs(m.errors) do real_errors[#real_errors + 1] = e end
	T.eq(#real_errors, 0, "no uncaught Lua error anywhere: " .. table.concat(real_errors, " | "))
	m:stop()
	T.eq(#m:live(), 0)
end)

T.test("budget: with 60 zombies, 4 colonists and the colony camera the MTA function calls per second stay within a sane bound on both sides", function()
	local m = H.boot({})
	local o = origin(m)
	m:player_move_to(o.x + 6, o.y + 6)
	m:step(1500)
	local host = H.host(m)
	for i = 1, 3 do host:debug("horde", { n = 28, dist = 100 + i * 20 }) end
	m:step(15000)
	local zombies = 0
	for ped, rec in pairs(H.sreq(m, "server.peds").list) do if rec.kind == "zombie" then zombies = zombies + 1 end end
	T.ge(zombies, 40, "a big horde is out: " .. zombies)
	H.client(m).set_mode("colony")
	m:step(2000)
	local before = {}
	for k, v in pairs(m.calls) do before[k] = v end
	local seconds = 20
	m:step(seconds * 1000)
	local total, top = 0, {}
	for k, v in pairs(m.calls) do
		local d = v - (before[k] or 0)
		total = total + d
		top[#top + 1] = { k = k, n = d }
	end
	table.sort(top, function(a, b) return a.n > b.n end)
	local per_s = total / seconds
	local parts = {}
	for i = 1, 6 do if top[i] then parts[#parts + 1] = string.format("%s %.0f/s", top[i].k, top[i].n / seconds) end end
	T.note("%d zombies: %.0f MTA function calls per second in total (%s)", zombies, per_s, table.concat(parts, ", "))
	T.lt(per_s, 9000, "calls per second")
	-- network: events per second and bytes of JSON the page receives
	local js = 0
	for _, s in ipairs(m.browser_js) do js = js + #s end
	T.note("the page received %d JavaScript pushes, %.1f KB in total", #m.browser_js, js / 1024)
	local sent = 0
	for _, list in pairs(m.captured) do sent = sent + #list end
	T.note("%d network messages in %.0f s of mock time", sent, m.t / 1000)
	T.eq(#m.errors, 0, H.errors_text(m))
	m:stop()
end)
