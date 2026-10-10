-- Lifecycle and failure injection: resource stop leaves nothing behind (peds, props, blips, cameras, relationship groups, population / clock / weather /
-- blackout / NUI focus settings), a restart resumes the saved colony, and the client survives bad models, slow streaming, failing creation, missing ground
-- and hostile / malformed events. Plus a native-call budget per frame under load.
local T, H = ...
local P = require("shared.protocol")
local U = require("shared.util")
local TUNING = require("data.tuning")

T.group("lifecycle")

local ORIGIN = { x = 1850.0, y = 3700.0, z = 34.0 }
local function client_mod(m) return m.sides.client.env.OutbreakClient() end
local function ctxm(m) return m.sides.client.env.require("client.ctx") end
local function mods(m) return client_mod(m).modules end

local function total_calls(m)
	local n = 0
	for _, v in pairs(m.calls) do n = n + v end
	return n
end

local function mine_alive(m)
	local n = { ped = 0, object = 0, blip = 0, cam = 0 }
	for _, e in pairs(m.ents) do
		if e.exists and e.mine and n[e.kind] then n[e.kind] = n[e.kind] + 1 end
	end
	return n
end

-- a busy world: horde, raid, ghost, colony camera with a placement ghost, storm + blackout, traders, piles, a carried crate
local function busy_world(m)
	local w = m:host().world
	m:player_move_to(ORIGIN.x + 6, ORIGIN.y + 6)
	m:step(1500)
	local host = m:host()
	host:debug("horde", { n = 30, dist = 110 })
	local r = require("sim.factions").plan_raid(w, 60, "rustjaw")
	r.x, r.y = TUNING.base.x + 120, TUNING.base.y
	m:nui("place", { op = "commit", bp = "wall", x = TUNING.base.x + 14, y = TUNING.base.y + 10 })
	host:debug("event", { id = "storm" })
	host:debug("event", { id = "power_outage" })
	local p = w:pile_for({ x = TUNING.base.x + 20, y = TUNING.base.y + 12, z = 0 })
	require("sim.items").add(p.items, "canned_beans", 3)
	require("sim.factions").spawn_caravan(w, "lantern")
	m:step(9000)
	m:nui("mode", { mode = "colony" })
	m:step(1500)
	m:nui("place", { op = "start", bp = "wall" })
	m:nui("mouse", { type = "move", x = 0.5, y = 0.5 })
	m:step(800)
end

T.test("stop: after a busy session nothing of ours is left in the game and every global setting is restored", function()
	local m = H.boot()
	busy_world(m)
	local before = mine_alive(m)
	T.gt(before.ped, 20); T.gt(before.object, 3); T.eq(before.cam, 1)
	T.truthy(m.env.blackout and m.env.weather and m.env.clock and ctxm(m).placing and m.env.nui_focus)
	T.gt(U.count(m.rel_groups), 0)
	m:fire_resource_stop()
	m:step(3000)
	local after = mine_alive(m)
	T.eq(after.ped, 0, "peds"); T.eq(after.object, 0, "objects"); T.eq(after.blip, 0, "blips"); T.eq(after.cam, 0, "cameras")
	T.eq(U.count(m.rel_groups), 0, "relationship groups removed")
	T.eq(m.cams.rendering, false); T.eq(m.cams.active, nil); T.eq(m.focus, nil)
	local e = m.env
	T.eq(e.nui_focus, false, "NUI focus released")
	T.eq(e.blackout, false); T.eq(e.clock, nil, "clock override cleared"); T.eq(e.clock_paused, false); T.eq(e.ms_per_min, 2000); T.eq(e.weather, nil)
	T.eq(e.ped_budget, 3); T.eq(e.veh_budget, 3); T.eq(e.random_cops, true); T.eq(e.wanted, 5); T.eq(e.health_recharge, 1.0)
	for i = 1, 15 do T.eq(e.dispatch[i], true, "dispatch service " .. i .. " back on") end
	for name, on in pairs(e.scenarios) do T.eq(on, true, "scenario " .. name .. " back on") end
	local pl = m.player.ped
	T.eq(pl.frozen, false); T.eq(pl.invincible, false)
	T.eq(pl.cfg.SetPedMoveRateOverride, 1.0, "movement rate restored")
	T.eq(m.player.sprint_allowed, true)
	T.eq(ctxm(m).running, false)
	-- the server saved on stop
	T.truthy(m.kvp["outbreak:meta"], "autosaved on resource stop")
	-- every thread of both sides ended
	for _, name in ipairs({ "server", "client" }) do
		for _, th in ipairs(m.sides[name].threads) do T.truthy(th.dead or coroutine.status(th.co) == "dead", name .. " thread still alive after stop") end
	end
	-- and nothing calls a native any more
	local calls = total_calls(m)
	m:step(10000)
	T.eq(total_calls(m), calls, "no native calls after the stop")
	T.eq(next(m.stale_calls or {}), nil, "no stale-handle calls during cleanup")
	T.eq(H.errors_text(m), "")
	T.eq(#m.net.bad_payloads, 0)
end)

T.test("stop while models are still streaming: nothing is created after the cleanup", function()
	local m = H.boot({ model_load_ms = 1500, warm_ms = 700 })
	m:step(400)
	m:fire_resource_stop()
	m:step(8000)
	local after = mine_alive(m)
	T.eq(after.ped, 0); T.eq(after.object, 0)
	T.eq(next(m.stale_calls or {}), nil)
	T.eq(H.errors_text(m), "")
end)

T.test("late network events after the stop are ignored", function()
	local m = H.boot()
	m:fire_resource_stop()
	m:step(500)
	m:spawn(m.sides.server, function()
		m.sides.server.env.TriggerClientEvent(P.NET.events, 7, { seq = 99, t = 1, events = { { type = "spawn_horde", id = "h99", pos = { x = 0, y = 0, z = 0 }, count = 5, mix = { walker = 5 } },
			{ type = "colonist_joined", id = "c99", name = "Late", pos = { x = 1, y = 1, z = 0 } } } })
	end)
	m:step(3000)
	T.eq(mine_alive(m).ped, 0)
end)

T.test("restart: a fresh server with the same KVP resumes the saved colony and the client rebuilds its peds", function()
	local m = H.boot()
	m:host():debug("fast_forward", { minutes = 300 })
	m:host():debug("autopilot", { on = true })
	m:step(3000)
	local hash_before = m:host().world:hash()
	m:fire_resource_stop()
	local saved = m.kvp
	T.truthy(saved["outbreak:slot:a"] or saved["outbreak:slot:b"])
	local m2 = H.boot({ kvp = saved })
	m2:step(2000)
	local w2 = m2:host().world
	T.eq(w2.s.seed, 7, "same seed")
	T.ge(w2.s.t, 480 + 300, "the saved time was restored")
	T.eq(m2:count("ped", true), #w2.s.colonists, "one ped per colonist again")
	T.eq(next(m2.stale_calls or {}), nil)
	-- a second restart is stable too (the autosave on this stop is loadable)
	m2:fire_resource_stop()
	local m3 = H.boot({ kvp = m2.kvp })
	T.truthy(m3:host().world.s.t >= w2.s.t)
	T.eq(H.errors_text(m2), ""); T.eq(H.errors_text(m3), "")
end)

-- ---------------------------------------------------------------------------------------------------------------------------- failure injection
T.test("failure: no colonist model exists -> no peds, no errors, the client keeps retrying and recovers", function()
	local invalid = {}
	local cfg = require("shared.config").client
	for _, name in ipairs(cfg.colonist_models) do invalid[name:lower()] = true end
	local m = H.boot({ invalid_models = invalid, warm_ms = 4000 })
	T.eq(m:count("ped", true), 0, "no ped could be created")
	T.eq(H.errors_text(m), "")
	local C = mods(m).Colonists
	local failing = 0
	for _, e in pairs(C.list) do if e.ped_fail then failing = failing + 1 end end
	T.eq(failing, 4, "every colonist records why it has no ped")
	local created = m.calls.CreatePed or 0
	T.eq(created, 0)
	-- the models appear (e.g. a streaming asset finished loading): the retry creates them without a new event
	m.invalid_models = {}
	m:step(6000)
	T.eq(m:count("ped", true), 4)
	T.eq(next(m.stale_calls or {}), nil)
end)

T.test("failure: streaming slower than the timeout -> clean timeout, no leak, recovers when it speeds up", function()
	local m = H.boot({ model_load_ms = 99999, warm_ms = 9000 })
	T.eq(m:count("ped", true), 0)
	T.gt(mods(m).Pool.stats.model_fail, 0, "timeouts counted")
	T.eq(H.errors_text(m), "")
	m.model_load_ms = 60
	for _, mm in pairs(m.models) do mm.req_t = nil end
	m:step(8000)
	T.eq(m:count("ped", true), 4)
end)

T.test("failure: CreatePed returns 0 -> handled as a failure, retried, no handle leak", function()
	local m = H.boot({ warm_ms = 500 })
	m:fire_resource_stop()
	local m2 = H.boot({ setup = function(mm) mm.refuse_create_ped = true end, warm_ms = 4000 })
	T.eq(m2:count("ped", true), 0)
	T.eq(H.errors_text(m2), "")
	m2.refuse_create_ped = false
	m2:step(6000)
	T.eq(m2:count("ped", true), 4)
	T.eq(mods(m2).Pool.n_peds, 4, "bookkeeping matches reality")
end)

T.test("failure: no ground under the base (collision not loaded) -> falls back to the hint height, counted, no error", function()
	local m = H.boot({ setup = function(mm) mm.no_ground = true end, warm_ms = 9000 })
	T.eq(m:count("ped", true), 4)
	T.gt(mods(m).Pool.stats.ground_fail, 0)
	for _, p in ipairs(m:entities("ped", true)) do T.near(p.z0, ORIGIN.z + 0.5, 0.01, "created at the hint height") end
	T.eq(H.errors_text(m), "")
end)

T.test("failure: malformed / hostile events do not break the client", function()
	local m = H.boot()
	local ctx = ctxm(m)
	local errors0 = ctx.stats.errors
	for _, ev in ipairs({ { type = "colonist_task", id = "c1" }, { type = "colonist_joined" }, { type = "spawn_horde" }, { type = "spawn_raiders", id = "r1" },
		{ type = "place_blueprint", id = "b1" }, { type = "construction_progress", id = "nope", pct = 5 }, { type = "weather" }, { type = "caravan", phase = "arrive", id = "x" },
		{ type = "unknown_future_event", foo = 1 }, { type = 5 }, "string", 5, true }) do
		ctx.dispatch(ev)
	end
	for _, msg in ipairs({ 5, "x", {}, { events = "no" }, { events = { 1, "a", {} } } }) do
		m:spawn(m.sides.server, function() m.sides.server.env.TriggerClientEvent(P.NET.events, 7, msg) end)
	end
	m:step(3000)
	T.gt(ctx.stats.errors, errors0, "handler errors were caught and counted")
	T.eq(H.errors_text(m), "", "but no thread died")
	T.eq(m:count("ped", true), 4)
end)

T.test("failure: the server never answers (no hello) -> the client stays inert and calm", function()
	local m = H.Mock.new({ root = H.res })
	m.capture = true
	m:boot_client() -- no server side at all
	m:step(10000)
	T.eq(ctxm(m).owner, false)
	T.eq(m:count("ped", true), 0)
	T.eq(H.errors_text(m), "")
	T.le(m.net.to_server["outbreak:ready"] or 0, 2, "the ready ping is not spammed")
	m:fire_resource_stop()
	T.eq(H.errors_text(m), "")
end)

T.test("failure: the IN queue is bounded while the server is away", function()
	local ctx_m = H.boot()
	local ctx = ctxm(ctx_m)
	for i = 1, 1000 do ctx.send({ type = "noise", pos = { x = i, y = 0, z = 0 }, loudness = 5 }) end
	T.le(ctx.queued(), 200)
end)

-- ---------------------------------------------------------------------------------------------------------------------------- budget
T.test("budget: native calls per frame under load stay within a sane budget (40 zombies, 4 colonists, colony camera, raid)", function()
	local m = H.boot({ convars = { outbreak_debug = "true", outbreak_max_peds = "48" } })
	busy_world(m)
	m:step(4000)
	local peds = mine_alive(m).ped
	T.gt(peds, 30, "a busy scene: " .. peds .. " peds")
	local c0, f0 = total_calls(m), m.frame_no
	local per_native0 = {}
	for k, v in pairs(m.calls) do per_native0[k] = v end
	m:step(10000)
	local frames = m.frame_no - f0
	local per_frame = (total_calls(m) - c0) / frames
	local top = {}
	for k, v in pairs(m.calls) do top[#top + 1] = { k, v - (per_native0[k] or 0) } end
	table.sort(top, function(a, b) return a[2] > b[2] end)
	local line = {}
	for i = 1, 6 do line[#line + 1] = string.format("%s %.1f", top[i][1], top[i][2] / frames) end
	T.note("%.0f native calls per frame with %d peds (per frame: %s)", per_frame, peds, table.concat(line, ", "))
	T.lt(per_frame, 250, "native calls per 33 ms frame")
	T.eq(H.errors_text(m), "")
	T.eq(next(m.stale_calls or {}), nil)
	T.eq(#m.net.bad_payloads, 0)
end)

T.test("budget: network traffic is small (events per second, bytes of JSON per second the NUI page receives)", function()
	local m = H.boot()
	busy_world(m)
	local json = require("shared.json")
	local n0 = #m.nui_msgs
	local out0 = 0
	for _, item in ipairs(m:sent("client", P.NET.events)) do out0 = out0 + #item.args[1].events end
	m:step(20000)
	local bytes, msgs = 0, 0
	for i = n0 + 1, #m.nui_msgs do bytes = bytes + #json.encode(m.nui_msgs[i]); msgs = msgs + 1 end
	local out1 = 0
	for _, item in ipairs(m:sent("client", P.NET.events)) do out1 = out1 + #item.args[1].events end
	T.note("20 s: %d NUI messages, %.1f KB json (%.1f KB/s), %d OUT events", msgs, bytes / 1024, bytes / 1024 / 20, out1 - out0)
	T.lt(bytes / 20, 60 * 1024, "NUI traffic under 60 KB/s with the colony screen open")
end)
