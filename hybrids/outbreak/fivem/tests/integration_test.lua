-- The REAL server and client Lua of the resource running together inside the mock FiveM (tests/mock.lua): handshake, colonist peds, tasks, orders
-- through the NUI, horde / raider materialization, noise, building ghosts, loot piles, persistence, resync. Everything here proves sequencing, bookkeeping,
-- caps and protocol; it can NOT prove that the real natives behave like the mock (see fivem/README.md "What the mocks cannot prove").
local T, H = ...
local P = require("shared.protocol")
local U = require("shared.util")
local TUNING = require("data.tuning")
local horde = require("sim.horde")

T.group("integration")

local ORIGIN = { x = 1850.0, y = 3700.0, z = 34.0 }

local function client_mod(m) return m.sides.client.env.OutbreakClient() end
local function ctxm(m) return m.sides.client.env.require("client.ctx") end
local function mods(m) return client_mod(m).modules end

local function assert_clean(m, what)
	T.eq(#m.net.bad_payloads, 0, (what or "run") .. ": every payload is msgpack-safe: " .. table.concat(m.net.bad_payloads, "; "))
	T.eq(H.errors_text(m), "", (what or "run") .. ": no thread errors")
	T.eq(next(m.stale_calls or {}), nil, (what or "run") .. ": no native was called with a stale handle: " .. (function()
		local t = {}
		for k, v in pairs(m.stale_calls or {}) do t[#t + 1] = k .. "=" .. v end
		return table.concat(t, ",")
	end)())
end

-- ---------------------------------------------------------------------------------------------------------------------------- handshake
T.test("handshake: the first client becomes the owner, gets hello + catalog + resync + state + hud", function()
	local m = H.boot()
	local host = m:host()
	T.eq(ctxm(m).owner, true)
	T.eq(#m:sent("client", P.NET.hello), 1 + 1 - 1 + (#m:sent("client", P.NET.hello) - 1), "hello sent")
	T.ge(#m:sent("client", P.NET.hello), 1)
	T.ge(#m:sent("client", P.NET.catalog), 1)
	T.ge(#m:sent("client", P.NET.hud), 1)
	local first = m:sent("client", P.NET.events)[1].args[1]
	T.eq(first.reset, true, "the resync starts with a reset flag")
	T.eq(m.script.nui_cb.ready ~= nil, true, "NUI callbacks registered")
	T.truthy(#m:nui_messages("catalog") >= 1 and #m:nui_messages("hud") >= 1)
	T.eq(host.world.s.profile, "escalating")
	assert_clean(m, "handshake")
end)

T.test("handshake: a second client is told it is not the owner and gets nothing else", function()
	local m = H.boot()
	-- another player id says ready
	local before = #m:sent("client", P.NET.events)
	m.player.server_id = 9
	m:spawn(m.sides.client, function() m.sides.client.env.TriggerServerEvent(P.NET.ready) end)
	m:step(300)
	T.eq(#m:sent("client", P.NET.events), before, "no world data for a non-owner")
	-- the mock delivers to the single local client; hello{owner=false} reaches it: it must not tear down the owner state
	m.player.server_id = 7
end)

T.test("hello twice (NUI ready after the first hello) does not duplicate relationship groups or threads", function()
	local m = H.boot()
	local before_groups = U.count(m.rel_groups)
	local before_threads = #m.sides.client.threads
	m:nui("ready", {})
	m:step(1500)
	T.eq(U.count(m.rel_groups), before_groups)
	T.le(#m.sides.client.threads, before_threads + 2, "no new worker threads from a second hello")
	assert_clean(m, "second hello")
end)

-- ---------------------------------------------------------------------------------------------------------------------------- colonists
T.test("colonists: one ped per sim colonist, in the right relationship group, at origin + sim position", function()
	local m = H.boot()
	local w = H.world(m)
	local peds = m:entities("ped", true)
	T.eq(#peds, #w.s.colonists)
	local group = ctxm(m).rel.OB_COLONY
	for _, p in ipairs(peds) do
		T.eq(p.group, group)
		T.eq(p.blocking, true)
		T.truthy(p.maxhealth == 200)
		T.eq(p.health, 200)
		T.truthy(p.cfg.SetPedAccuracy)
	end
	-- every colonist reported its ped to the sim (colonist_ref)
	local refs = m:in_events("colonist_ref")
	T.eq(#refs, #w.s.colonists)
	-- spawned within ~12 m of the sim position + origin (jitter from the ground probe only)
	for _, c in ipairs(w.s.colonists) do
		local gx, gy = c.pos.x + ORIGIN.x, c.pos.y + ORIGIN.y
		local best = 1e9
		for _, p in ipairs(peds) do best = math.min(best, math.sqrt((p.x - gx) ^ 2 + (p.y - gy) ^ 2)) end
		T.lt(best, 15.0, "ped near the colonist " .. c.id .. " (" .. string.format("%.1f", best) .. " m)")
	end
	assert_clean(m, "colonists")
end)

T.test("colonists: tasks become TaskGoToCoordAnyMeans at origin-offset coordinates", function()
	local m = H.boot({ warm_ms = 1000 })
	m:step(30000)
	local tasks = m:out_events("colonist_task")
	T.gt(#tasks, 0, "the sim assigned jobs")
	local goto_calls = {}
	for _, p in ipairs(m:entities("ped", true)) do
		for _, rec in ipairs(p.task_log or {}) do if rec.name == "go_to_coord" then goto_calls[#goto_calls + 1] = rec end end
	end
	T.gt(#goto_calls, 0, "peds were sent walking")
	-- every go_to_coord matches the position of some colonist_task (or a spawn restore) + origin
	local matched = 0
	for _, rec in ipairs(goto_calls) do
		for _, tk in ipairs(tasks) do
			if math.abs(rec.x - (tk.pos.x + ORIGIN.x)) < 1e-6 and math.abs(rec.y - (tk.pos.y + ORIGIN.y)) < 1e-6 then matched = matched + 1; break end
		end
	end
	T.gt(matched, 0)
	T.ge(matched, #goto_calls - 4, "all (bar a few follow-up walks) go_to_coord calls come from a colonist_task: " .. matched .. "/" .. #goto_calls)
	assert_clean(m, "tasks")
end)

T.test("colonists: a ped that lags is snapped to the destination, the sim never waits for it", function()
	local m = H.boot({ warm_ms = 1000 })
	m.walk_scale = 0.01 -- peds barely move: every walk lags
	m:step(120000)
	local c = mods(m).Colonists
	T.gt(c.stats.snaps, 0, "snaps happened: " .. c.stats.snaps)
	-- a snapped ped sits at its destination
	local ok = 0
	for _, e in pairs(c.list) do
		if e.ped and e.dest and e.arrived then
			local p = m.ents[e.ped]
			if math.abs(p.x - e.dest.x) < 1.5 and math.abs(p.y - e.dest.y) < 1.5 then ok = ok + 1 end
		end
	end
	T.gt(ok, 0, "arrived peds are at their destination")
	T.eq(m:host().world.s.t > 480 + 30, true, "sim time kept going")
	assert_clean(m, "snap")
end)

T.test("colonists: the snap deadline follows the sim's own walking time and the time scale", function()
	local m = H.boot({ warm_ms = 500 })
	local C = mods(m).Colonists
	local ctx = ctxm(m)
	ctx.sim_scale = 0.5
	local near, far = C.allowed_ms(10), C.allowed_ms(200)
	T.lt(near, far); T.ge(near, ctxm(m).cfg.snap_grace_ms)
	ctx.sim_scale = 8
	T.lt(C.allowed_ms(200), far, "a faster sim snaps sooner")
	ctx.sim_scale = 0.0001
	T.eq(C.allowed_ms(500), ctx.cfg.snap_max_ms, "capped")
end)

T.test("colonists: sim damage mirrors to ped health; game damage is reported once and the health restored", function()
	local m = H.boot({ warm_ms = 2000 })
	local w = H.world(m)
	local c = w.s.colonists[1]
	local ped = m:entities("ped", true)[1]
	-- the game hurts a ped (as a zombie bite would): the adapter reports ped_damage and puts the health back where the sim says
	local target
	for _, e in pairs(mods(m).Colonists.list) do target = target or e end
	local e = target
	local hp_before = m.ents[e.ped].health
	m:damage(e.ped, 30)
	m:step(1500)
	local dmg = m:in_events("ped_damage")
	T.eq(#dmg, 1, "reported exactly once")
	T.eq(dmg[1].id, e.id); T.near(dmg[1].amount, 30 * (e.hp_max / 100), 1e-6)
	T.eq(m.ents[e.ped].health, hp_before, "health restored to the sim's value")
	m:step(3000)
	T.eq(#m:in_events("ped_damage"), 1, "not reported again")
	-- the sim applied it
	local sim_c = w:colonist(e.id)
	T.truthy(sim_c.hp < sim_c.hp_max or #sim_c.wounds > 0)
	assert_clean(m, "damage")
end)

T.test("colonists: a ped the game kills is reported as ped_died and the sim marks the colonist dead", function()
	local m = H.boot({ warm_ms = 2000 })
	local w = H.world(m)
	local n0 = #w.s.colonists
	local e
	for _, x in pairs(mods(m).Colonists.list) do e = e or x end
	local ped = e.ped
	m:kill(ped)
	m:step(2000)
	local died = m:in_events("ped_died")
	T.eq(#died, 1); T.eq(died[1].id, e.id)
	T.eq(#w.s.colonists, n0 - 1, "the sim removed the colonist")
	T.eq(#w.s.dead, 1)
	-- the corpse is cleaned up later, not instantly
	T.truthy(m.ents[ped].exists)
	m:step(30000)
	T.falsy(m.ents[ped].exists, "corpse deleted after ~25 s")
	assert_clean(m, "death")
end)

T.test("colonists: sim-side death (debug kill) leaves a corpse that is cleaned up", function()
	local m = H.boot({ warm_ms = 2000 })
	local w = H.world(m)
	local id = w.s.colonists[2].id
	m:host():debug("kill_colonist", { id = id })
	m:step(1500)
	T.eq(#m:out_events("colonist_died"), 1)
	m:step(30000)
	local alive_peds = m:count("ped", true)
	T.eq(alive_peds, #w.s.colonists)
	assert_clean(m, "sim death")
end)

-- ---------------------------------------------------------------------------------------------------------------------------- hordes
-- put the mock player on the base and wait until the sim knows (player_state travels client -> server)
local function player_at_base(m, dx, dy)
	m:player_move_to(ORIGIN.x + (dx or 6), ORIGIN.y + (dy or 6))
	m:step(1500)
end

local function zombies_of(m)
	local group = ctxm(m).rel.OB_ZOMBIE
	local out = {}
	for _, p in ipairs(m:entities("ped", true)) do if p.group == group then out[#out + 1] = p end end
	return out
end

local function mat_total(w)
	local n = 0
	for _, h in ipairs(w.s.hordes) do if h.mat then n = n + h.mat.count end end
	return n
end

T.test("hordes: a horde near the player materializes as exactly the sim's number of zombie peds", function()
	local m = H.boot()
	local w = H.world(m)
	player_at_base(m)
	T.truthy(m:host():debug("horde", { n = 30, dist = 120 }))
	m:step(8000)
	local z = zombies_of(m)
	T.gt(mat_total(w), 0, "the sim materialized the horde")
	T.eq(#z, mat_total(w), "zombie peds == sim materialized count")
	T.eq(mods(m).Zombies.alive_total(), #z)
	T.le(#z + 4, ctxm(m).cfg.max_peds)
	local player = m.player.ped
	for _, p in ipairs(z) do
		T.ge(math.sqrt((p.x - player.x) ^ 2 + (p.y - player.y) ^ 2), ctxm(m).cfg.spawn_min_dist - 1.0, "never spawned in the player's face")
		T.eq(p.blocking, true)
		T.truthy(p.cfg.SetPedHearingRange and p.cfg.SetPedSeeingRange and p.cfg.SetPedMovementClipset, "configured like the RottenV recipe")
		T.eq(p.mission, true)
		T.truthy(p.health >= 100)
	end
	-- spawns were spread over ticks (never more than spawn_per_tick per 250 ms step)
	local times = {}
	for _, p in ipairs(z) do times[p.created_t] = (times[p.created_t] or 0) + 1 end
	for t, n in pairs(times) do T.le(n, ctxm(m).cfg.spawn_per_tick * 2, "spawn burst at t=" .. t) end
	assert_clean(m, "horde")
end)

T.test("hordes: deaths are reported once with the horde id and kind, and the sim's horde shrinks", function()
	local m = H.boot()
	local w = H.world(m)
	player_at_base(m)
	m:host():debug("horde", { n = 20, dist = 100 })
	m:step(8000)
	local z = zombies_of(m)
	T.gt(#z, 5)
	local before = mat_total(w)
	local size_before = 0
	for _, h in ipairs(w.s.hordes) do size_before = size_before + h.size end
	m:kill(z[1].handle, m.player.ped.handle)
	m:kill(z[2].handle, m.player.ped.handle)
	m:step(2500)
	local died = m:in_events("ped_died")
	local zd = {}
	for _, e in ipairs(died) do if e.zkind then zd[#zd + 1] = e end end
	T.eq(#zd, 2)
	for _, e in ipairs(zd) do T.truthy(e.id:match("^h%d+$")); T.eq(e.cause, "player") end
	local size_after = 0
	for _, h in ipairs(w.s.hordes) do size_after = size_after + h.size end
	T.eq(size_after, size_before - 2, "the sim removed two zombies from the horde")
	m:step(25000)
	T.falsy(m.ents[z[1].handle].exists, "corpse removed after 5-15 s")
	T.falsy(m.ents[z[2].handle].exists)
	assert_clean(m, "horde deaths")
end)

T.test("hordes: moving away despawns them (despawn_horde), nothing stays behind", function()
	local m = H.boot()
	local w = H.world(m)
	player_at_base(m)
	m:host():debug("horde", { n = 25, dist = 100 })
	m:step(6000)
	T.gt(#zombies_of(m), 0)
	m:player_move_to(ORIGIN.x + 900, ORIGIN.y + 900) -- far outside R_dematerialize
	m:step(6000)
	T.eq(mat_total(w), 0, "the sim dematerialized")
	T.eq(#zombies_of(m), 0, "no zombie peds remain")
	T.eq(mods(m).Zombies.alive_total(), 0)
	assert_clean(m, "despawn")
end)

T.test("hordes: the ped cap holds, the engine is not hammered, and the rest waits", function()
	local m = H.boot({ convars = { outbreak_debug = "true", outbreak_max_peds = "12" } })
	local w = H.world(m)
	player_at_base(m)
	m:host():debug("horde", { n = 60, dist = 100 })
	m:step(12000)
	local created_before = m.calls.CreatePed or 0
	m:step(20000)
	T.eq(ctxm(m).cfg.max_peds, 12, "the server's cap reached the client")
	T.le(m:count("ped", true), 12)
	T.le(mods(m).Pool.n_peds, 12)
	T.gt(mods(m).Pool.stats.refused_cap, 0, "the cap refused creations")
	T.le((m.calls.CreatePed or 0) - created_before, 6, "after hitting the cap the spawner backs off instead of spinning")
	T.gt(mods(m).Zombies.pending_total(), 0, "the rest stays queued")
	-- a colonist ped that cannot be created because zombies filled the cap is retried, not lost
	assert_clean(m, "cap")
end)

T.test("hordes: the CPed pool guard refuses to create peds when the game's pool is nearly full", function()
	local m = H.boot({ convars = { outbreak_debug = "true", outbreak_pool_guard = "130" }, ambient_peds = 128 })
	local w = H.world(m)
	player_at_base(m)
	m:host():debug("horde", { n = 40, dist = 100 })
	m:step(15000)
	T.eq(ctxm(m).cfg.pool_guard, 130)
	T.le(m:count("ped", true) + 128, 131, "the pool never went past the guard")
	T.gt(mods(m).Pool.stats.refused_pool, 0)
	assert_clean(m, "pool guard")
end)

T.test("hordes: zombies notice, chase and bite the player; the damage reaches the survival body and the HUD", function()
	local m = H.boot()
	local host = m:host()
	player_at_base(m)
	host:debug("horde", { n = 30, dist = 110 })
	m:step(7000)
	local z = zombies_of(m)
	T.gt(#z, 3)
	-- stand next to the zombies
	local target = z[1]
	m:player_move_to(target.x + 8, target.y)
	local hp0 = host.survival:view().hp
	local min_hp = hp0
	for _ = 1, 24 do m:step(500); min_hp = math.min(min_hp, host.survival:view().hp) end -- (a dead player respawns after ~6 s, so watch the minimum)
	local gone_to = 0
	for _, p in ipairs(zombies_of(m)) do if p.task == "go_to_entity" or (p.task_log and #p.task_log > 0) then gone_to = gone_to + 1 end end
	T.gt(gone_to, 0, "zombies were tasked to chase")
	T.gt(mods(m).Zombies.stats.attacks, 0, "zombies attacked")
	T.lt(min_hp, hp0, "the bites cost the player health in the host's survival body")
	local dmg = m:in_events("player_damage")
	T.gt(#dmg, 0, "player_damage events were sent")
	-- the HUD message carries it back, and the client applied it to the ped
	local lowest = 100
	for _, msg in ipairs(m:nui_messages("hud")) do lowest = math.min(lowest, msg.data.hp) end
	T.lt(lowest, 100, "the HUD showed the damage")
	assert_clean(m, "chase")
end)

T.test("hordes: sneaking shrinks the detection radius (TP-Advanced-Zombies radii)", function()
	local m = H.boot()
	player_at_base(m)
	m:host():debug("horde", { n = 30, dist = 110 })
	m:step(7000)
	local z = zombies_of(m)
	T.gt(#z, 2)
	local Zm = mods(m).Zombies
	local cfg = ctxm(m).cfg
	-- park the player 25 m from the nearest zombie: walking (35 m) sees it, ducking (10 m) does not
	local target = z[1]
	for _, p in ipairs(z) do p.task_log = {}; p.task = nil end
	m:player_move_to(target.x + 25, target.y)
	m.player.ped.ducking = true
	for _ = 1, 6 do Zm.think(); m:step(100) end
	local chased_ducking = 0
	for _, p in ipairs(z) do for _, r in ipairs(p.task_log or {}) do if r.name == "go_to_entity" then chased_ducking = chased_ducking + 1 end end end
	m.player.ped.ducking = false
	m.player.ped.sprinting = false
	for _, p in ipairs(z) do p.task_log = {}; p.task = nil end
	for _ = 1, 6 do Zm.think(); m:step(100) end
	local chased_walking = 0
	for _, p in ipairs(z) do for _, r in ipairs(p.task_log or {}) do if r.name == "go_to_entity" then chased_walking = chased_walking + 1 end end end
	T.gt(chased_walking, chased_ducking, "walking is noticed from farther away than crouching: " .. chased_walking .. " vs " .. chased_ducking)
	T.eq(cfg.detect.crouch, 10.0); T.eq(cfg.detect.walk, 35.0); T.eq(cfg.detect.sprint, 45.0)
end)

-- ---------------------------------------------------------------------------------------------------------------------------- noise
T.test("noise: a gunshot becomes a noise IN event at the right sim position and zombies nearby investigate", function()
	local m = H.boot()
	player_at_base(m)
	m:host():debug("horde", { n = 30, dist = 110 })
	m:step(7000)
	local z = zombies_of(m)
	T.gt(#z, 0)
	for _, p in ipairs(z) do p.task_log = {}; p.task = nil end
	local px, py = m.player.ped.x, m.player.ped.y
	m:player_shoot(416676503) -- pistol group
	m:step(600)
	local noises = m:in_events("noise")
	T.ge(#noises, 1)
	local n = noises[#noises]
	T.eq(n.kind, "gunshot"); T.eq(n.loudness, ctxm(m).config.noise.gunshot)
	T.near(n.pos.x, px - ORIGIN.x, 0.01); T.near(n.pos.y, py - ORIGIN.y, 0.01)
	local investigating = 0
	for _, p in ipairs(z) do if p.task == "go_to_coord" then investigating = investigating + 1 end end
	T.gt(investigating, 0, "materialized zombies within hearing range went to look")
	assert_clean(m, "gunshot")
end)

T.test("noise: kinds, suppressors and throttling", function()
	local m = H.boot()
	player_at_base(m)
	local Noise = mods(m).Noise
	local base = #m:in_events("noise")
	m:player_shoot(970310034); m:step(400)      -- rifle group
	local r = m:in_events("noise"); T.eq(r[#r].kind, "rifle")
	m:step(600)
	m:player_shoot(416676503, true); m:step(400) -- silenced pistol
	r = m:in_events("noise")
	T.near(r[#r].loudness, ctxm(m).config.noise.gunshot * ctxm(m).config.noise.suppressed_mult, 1e-6)
	-- a burst of 20 shots in 600 ms is throttled to a handful of events
	local n0 = #m:in_events("noise")
	for _ = 1, 20 do m:player_shoot(416676503); m:step(30) end
	m:step(300)
	T.le(#m:in_events("noise") - n0, 4, "throttled")
	-- sprinting and melee come from the slow poll
	m.player.ped.sprinting = true; m:step(800)
	local kinds = {}
	for _, e in ipairs(m:in_events("noise")) do kinds[e.kind] = true end
	T.truthy(kinds.sprint, "sprinting is noise")
	m.player.ped.sprinting = false
	-- an explosion nearby
	m.explosion = { x = m.player.ped.x + 10, y = m.player.ped.y, z = m.player.ped.z }
	m:step(800)
	m.explosion = nil
	kinds = {}
	for _, e in ipairs(m:in_events("noise")) do kinds[e.kind] = e end
	T.truthy(kinds.explosion and kinds.explosion.loudness == ctxm(m).config.noise.explosion)
	-- every noise event is within the clamps the server enforces
	for _, e in ipairs(m:in_events("noise")) do T.truthy(P.sanitize_in(e), "valid noise event") end
	assert_clean(m, "noise")
end)

T.test("noise: the sim's own horde reacts to a loud noise (abstract hordes are attracted by the sim)", function()
	local m = H.boot()
	local w = H.world(m)
	player_at_base(m)
	local b = TUNING.base
	local h = horde.spawn(w, { x = b.x + 400, y = b.y + 400, mix = { walker = 20 }, target = nil, src = "test" })
	m:step(500)
	local state0 = h.state
	m:player_shoot(970310034); m:step(800)
	T.ge(#m:in_events("noise"), 1)
	T.truthy(h.state ~= nil)
	assert_clean(m, "noise attraction")
end)

-- ---------------------------------------------------------------------------------------------------------------------------- raiders
local function raiders_of(m)
	local out = {}
	for _, p in ipairs(m:entities("ped", true)) do if p.weapon and p.group ~= ctxm(m).rel.OB_COLONY and p.group ~= ctxm(m).rel.OB_ZOMBIE then out[#out + 1] = p end end
	return out
end

local function plan_raid_near(m, faction, points, dist)
	local w = H.world(m)
	local factions = require("sim.factions")
	local r = factions.plan_raid(w, points or 60, faction or "rustjaw")
	local b = TUNING.base
	r.x, r.y = b.x + (dist or 120), b.y
	return r
end

T.test("raiders: a raid near the player materializes as armed peds of the faction's relationship group walking to the base", function()
	local m = H.boot()
	local w = H.world(m)
	player_at_base(m)
	local r = plan_raid_near(m, "rustjaw", 80, 120)
	m:step(8000)
	T.truthy(r.mat and r.mat.count > 0, "the sim materialized the raid")
	local rd = raiders_of(m)
	T.eq(#rd, r.mat.count, "raider peds == sim count")
	T.eq(mods(m).Raiders.alive_total(), #rd)
	local group = ctxm(m).rel.OB_RUSTJAW
	local base_game = { x = TUNING.base.x + ORIGIN.x, y = TUNING.base.y + ORIGIN.y }
	for _, p in ipairs(rd) do
		T.eq(p.group, group)
		T.truthy(next(p.weapons), "armed")
		local walks = 0
		for _, rec in ipairs(p.task_log or {}) do
			if rec.name == "go_to_coord" and math.abs(rec.x - base_game.x) < 1e-6 and math.abs(rec.y - base_game.y) < 1e-6 then walks = walks + 1 end
		end
		T.ge(walks, 1, "walks to the base (origin-offset target)")
	end
	assert_clean(m, "raiders")
end)

T.test("raiders: deaths are reported with the raid id; when the last one dies the raid is repelled", function()
	local m = H.boot()
	local w = H.world(m)
	player_at_base(m)
	local r = plan_raid_near(m, "tallow", 50, 100)
	m:step(8000)
	local rd = raiders_of(m)
	T.gt(#rd, 0)
	local rid = r.id
	for _, p in ipairs(rd) do m:kill(p.handle, m.player.ped.handle) end
	m:step(3000)
	local died = 0
	for _, e in ipairs(m:in_events("ped_died")) do if e.id == rid then died = died + 1 end end
	T.eq(died, #rd, "one ped_died per raider, with the raid id")
	T.eq(factions_find and 0 or 0, 0)
	T.eq(require("sim.factions").find_raid(w, rid), nil, "the raid is over in the sim")
	m:step(30000)
	T.eq(#raiders_of(m), 0, "bodies cleaned up")
	assert_clean(m, "raid repelled")
end)

T.test("raiders: raid_report keeps the abstract position in sync", function()
	local m = H.boot()
	player_at_base(m)
	plan_raid_near(m, "rustjaw", 60, 150)
	m:step(12000)
	local reports = m:in_events("raid_report")
	T.gt(#reports, 0)
	for _, e in ipairs(reports) do T.truthy(P.sanitize_in(e)); T.lt(math.abs(e.pos.x), 600) end
	assert_clean(m, "raid report")
end)

-- ---------------------------------------------------------------------------------------------------------------------------- building
local function wall_pos() return { x = TUNING.base.x + 14, y = TUNING.base.y + 10 } end
local function objects(m) return m:entities("object", true) end
-- blueprint ghosts: translucent props without collision (colonists also carry crate props while hauling, so counting every object would be wrong)
local function ghosts(m)
	local out = {}
	for _, e in ipairs(objects(m)) do if e.alpha < 255 and e.collision == false then out[#out + 1] = e end end
	return out
end

T.test("build: an order through the NUI makes a translucent, collision-free ghost that ramps up and turns solid", function()
	local m = H.boot()
	local w = H.world(m)
	local p = wall_pos()
	T.eq(#ghosts(m), 0)
	m:nui("place", { op = "commit", bp = "wall", x = p.x, y = p.y })
	m:step(2500)
	local placed = m:out_events("place_blueprint")
	T.eq(#placed, 1); T.eq(placed[1].bp, "wall")
	T.eq(#ghosts(m), 1)
	local ghost = ghosts(m)[1]
	T.truthy(ghost, "a translucent prop")
	T.eq(ghost.alpha, 90, "ghost alpha floor")
	T.eq(ghost.collision, false, "no collision while it is a ghost")
	T.near(ghost.x, p.x + ORIGIN.x, 0.01); T.near(ghost.y, p.y + ORIGIN.y, 0.01)
	T.eq(ghost.frozen, true)
	-- let the colony build it (the sim's own AI plays)
	m:host():debug("autopilot", { on = true })
	local last_alpha, rose = ghost.alpha, false
	local done = m:wait_until(function()
		if ghost.alpha > last_alpha and ghost.alpha < 255 then rose = true end
		last_alpha = ghost.alpha
		for _, b in ipairs(w.s.buildings) do if b.id == placed[1].id and b.state == "built" then return true end end
		return false
	end, 0)
	m:host():ui_action("set_speed", { speed = 16 })
	done = m:wait_until(function()
		if ghost.alpha > last_alpha and ghost.alpha < 255 then rose = true end
		last_alpha = ghost.alpha
		for _, b in ipairs(w.s.buildings) do if b.id == placed[1].id and b.state == "built" then return true end end
		return false
	end, 240000)
	T.truthy(done, "the colony finished the wall")
	m:step(2000)
	T.truthy(rose, "alpha rose with construction progress")
	T.eq(ghost.alpha, 255, "solid when done")
	T.eq(ghost.collision, true, "collision when done")
	assert_clean(m, "build")
end)

T.test("build: a refused placement comes back as order_result, and no prop is leaked", function()
	local m = H.boot()
	local p = wall_pos()
	m:nui("place", { op = "commit", bp = "wall", x = p.x, y = p.y })
	m:step(2000)
	T.eq(#ghosts(m), 1)
	m:nui("place", { op = "commit", bp = "wall", x = p.x, y = p.y }) -- same spot: blocked
	m:step(2000)
	T.eq(#ghosts(m), 1, "no second ghost")
	local bad
	for _, e in ipairs(m:out_events("order_result")) do if e.ok == false then bad = e end end
	T.truthy(bad and bad.reason == "blocked", "order_result blocked")
	assert_clean(m, "refused placement")
end)

T.test("build: model fallback when the preferred prop model does not exist", function()
	local m = H.boot({ invalid_models = { prop_barrier_work05 = true, prop_conc_blocks01a = true, prop_mp_barrier_02b = true } })
	local ctx = ctxm(m)
	local p = wall_pos()
	m:nui("place", { op = "commit", bp = "wall", x = p.x, y = p.y })
	m:step(3000)
	T.eq(#ghosts(m), 1, "a ghost exists even though the first model names were invalid")
	assert_clean(m, "model fallback")
end)

T.test("build: destroyed buildings lose their prop; a reset clears every prop", function()
	local m = H.boot()
	local w = H.world(m)
	local p = wall_pos()
	m:nui("place", { op = "commit", bp = "wall", x = p.x, y = p.y })
	m:step(2500)
	T.eq(#ghosts(m), 1)
	local id = m:out_events("place_blueprint")[1].id
	m:host():on_order({ id = "colony", kind = "cancel_blueprint", target = { id = id } })
	m:step(2500)
	T.eq(#ghosts(m), 0, "cancelled blueprint prop removed")
	assert_clean(m, "cancel")
end)
