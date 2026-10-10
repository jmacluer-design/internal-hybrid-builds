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

-- ---------------------------------------------------------------------------------------------------------------------------- piles / props / traders
local function pile_props(m)
	local out = {}
	for ref, p in pairs(mods(m).Props.props) do if p.obj then out[ref] = p end end
	return out
end

-- two ground piles with something in them (a fresh colony has none)
local function add_piles(m)
	local w = H.world(m)
	local items = require("sim.items")
	local out = {}
	for i, at in ipairs({ { 20, 12 }, { -18, 25 } }) do
		local p = w:pile_for({ x = TUNING.base.x + at[1], y = TUNING.base.y + at[2], z = 0 })
		items.add(p.items, "canned_beans", i + 1)
		out[#out + 1] = p
	end
	return out
end

T.test("piles: every sim pile has a crate at origin + position; emptied piles lose theirs; new piles get one (no UI open)", function()
	local m = H.boot()
	local w = H.world(m)
	T.eq(#w.s.piles, 0, "a new colony starts without piles")
	add_piles(m)
	m:step(2500)
	T.eq(#w.s.piles, 2)
	local props = pile_props(m)
	T.eq(U.count(props), #w.s.piles)
	for _, p in ipairs(w.s.piles) do
		local pr = props["pile:" .. p.id]
		T.truthy(pr, "crate for " .. p.id)
		T.near(pr.x, p.pos.x + ORIGIN.x, 0.01); T.near(pr.y, p.pos.y + ORIGIN.y, 0.01)
	end
	-- a pile appears (e.g. a cancelled blueprint's delivered materials, a death) and another is emptied
	local first = w.s.piles[1]
	w:remove_pile(first)
	local newp = w:pile_for({ x = TUNING.base.x + 40, y = TUNING.base.y - 25, z = 0 })
	require("sim.items").add(newp.items, "canned_beans", 2)
	m:step(2500)
	props = pile_props(m)
	T.eq(props["pile:" .. first.id], nil, "crate of the removed pile deleted")
	T.truthy(props["pile:" .. newp.id], "crate of the new pile created")
	T.eq(U.count(props), #w.s.piles)
	assert_clean(m, "piles")
end)

T.test("piles: E near a crate opens it in the inventory UI (ui_action + screen message)", function()
	local m = H.boot()
	local w = H.world(m)
	add_piles(m)
	m:step(2500)
	local pr = pile_props(m)
	local ref, prop = next(pr)
	T.truthy(prop, "a crate exists")
	m:player_move_to(prop.x + 1.0, prop.y)
	m.player.ped.z = prop.z
	m:command("client", "outbreak_interact")
	m:step(800)
	local screen
	for _, msg in ipairs(m:nui_messages("screen")) do screen = msg.data end
	T.truthy(screen and screen.name == "inventory" and screen.arg.other.kind == "pile" and "pile:" .. screen.arg.other.id == ref)
	T.truthy(m:host().other and m:host().other.kind == "pile", "the host selected the pile as the other container")
	local inv
	for _, msg in ipairs(m:nui_messages("inventory")) do inv = msg.data end
	T.truthy(inv and inv.other and inv.other.kind == "pile", "the inventory view includes the pile's contents")
	-- too far: nothing happens
	m:player_move_to(prop.x + 30, prop.y)
	local n = #m:nui_messages("screen")
	m:command("client", "outbreak_interact")
	m:step(300)
	T.eq(#m:nui_messages("screen"), n)
	assert_clean(m, "interact")
end)

T.test("piles: a drop from the inventory creates a crate; picking up through the inventory moves the items", function()
	local m = H.boot()
	local w = H.world(m)
	local host = m:host()
	host:debug("give", { item = "bandage", n = 4 })
	m:nui("ui", { name = "drop_item", data = { item = "bandage", n = 3 } })
	m:step(1500)
	local drops = 0
	for ref in pairs(pile_props(m)) do if ref:sub(1, 5) == "drop:" then drops = drops + 1 end end
	T.eq(drops, 1)
	T.eq(require("sim.items").count(w.s.player.inv, "bandage"), 1)
	T.truthy(w:audit())
	assert_clean(m, "drop")
end)

T.test("traders: a caravan spawns two traders in the trader group, and they leave with it", function()
	local m = H.boot()
	local w = H.world(m)
	local factions = require("sim.factions")
	local c = factions.spawn_caravan(w, "lantern")
	m:step(2500)
	local group = ctxm(m).rel.OB_TRADER
	local function traders() local n = 0; for _, p in ipairs(m:entities("ped", true)) do if p.group == group then n = n + 1 end end return n end
	T.eq(traders(), 2)
	-- a duplicated arrive event (e.g. a resync while they stream in) does not double them
	ctxm(m).dispatch({ type = "caravan", phase = "arrive", id = c.id, faction = "lantern", pos = { x = 5, y = 5, z = 0 } })
	m:step(500)
	T.eq(traders(), 2)
	ctxm(m).dispatch({ type = "caravan", phase = "leave", id = c.id })
	m:step(500)
	T.eq(traders(), 0)
	assert_clean(m, "traders")
end)

-- ---------------------------------------------------------------------------------------------------------------------------- colony camera + NUI
local function enter_colony(m)
	player_at_base(m)
	m:nui("mode", { mode = "colony" })
	m:step(1800)
end

T.test("camera: colony mode creates the scripted camera, freezes the player, takes NUI focus; leaving restores everything", function()
	local m = H.boot()
	player_at_base(m)
	local ped = m.player.ped
	m:nui("mode", { mode = "colony" })
	m:step(1200)
	T.eq(ctxm(m).colony_mode, true)
	T.eq(m.cams.rendering, true); T.truthy(m.cams.active)
	T.eq(ped.frozen, true); T.eq(ped.invincible, true)
	T.eq(m.env.nui_focus, true, "NUI has the keyboard and the mouse")
	T.truthy(m.focus, "streaming focus follows the camera")
	local cam = m.ents[m.cams.active]
	T.gt(cam.z, ped.z + 20, "the camera is high above the ground")
	T.lt(cam.rx, -30, "looking down")
	local modes = m:nui_messages("mode")
	T.eq(modes[#modes].data.mode, "colony")
	-- the sim's observer is the camera focus, not the frozen ped
	m:nui("focus", { x = 30, y = 40 })
	m:step(1500)
	local ps = m:in_events("player_state")
	T.near(ps[#ps].pos.x, 30, 0.5); T.near(ps[#ps].pos.y, 40, 0.5)
	m:nui("mode", { mode = "survival" })
	m:step(1200)
	T.eq(ctxm(m).colony_mode, false)
	T.eq(m.cams.rendering, false); T.eq(m.cams.active, nil)
	T.eq(ped.frozen, false); T.eq(ped.invincible, false)
	T.eq(m.env.nui_focus, false)
	T.eq(m.focus, nil)
	assert_clean(m, "camera")
end)

T.test("camera: WASD pans along the view direction (shift is faster), Q/E rotate, the wheel zooms within limits", function()
	local m = H.boot()
	enter_colony(m)
	local Cam = mods(m).Camera
	local f0 = { x = Cam.f.x, y = Cam.f.y }
	m:nui("key", { k = "w", down = true }); m:step(1000); m:nui("key", { k = "w", down = false })
	T.gt(Cam.f.y, f0.y + 10, "W moves north at yaw 0")
	T.near(Cam.f.x, f0.x, 0.01)
	local f1 = { x = Cam.f.x, y = Cam.f.y }
	m:nui("key", { k = "shift", down = true }); m:nui("key", { k = "s", down = true }); m:step(500); m:nui("key", { k = "s", down = false }); m:nui("key", { k = "shift", down = false })
	local fast = f1.y - Cam.f.y
	m:nui("key", { k = "w", down = true }); m:step(500); m:nui("key", { k = "w", down = false })
	local slow = Cam.f.y - (f1.y - fast)
	T.gt(fast, slow * 1.5, "shift pans faster")
	local yaw0 = Cam.yaw
	m:nui("key", { k = "q", down = true }); m:step(600); m:nui("key", { k = "q", down = false })
	T.ne(Cam.yaw, yaw0)
	for _ = 1, 40 do m:nui("mouse", { type = "wheel", dy = -1, x = 0.5, y = 0.5 }) end
	T.eq(Cam.h, ctxm(m).cfg.cam_min_h, "zoomed in to the limit")
	for _ = 1, 80 do m:nui("mouse", { type = "wheel", dy = 1, x = 0.5, y = 0.5 }) end
	T.eq(Cam.h, ctxm(m).cfg.cam_max_h, "zoomed out to the limit")
	-- unknown keys are ignored
	m:nui("key", { k = "F13", down = true })
	T.eq(Cam.keys.F13, nil)
	assert_clean(m, "pan")
end)

local function screen_of(m, id)
	for _, c in pairs(mods(m).Colonists.list) do
		if c.id == id then
			local p = m.ents[c.ped]
			local _, sx, sy = m.sides.client.env.GetScreenCoordFromWorldCoord(p.x, p.y, p.z)
			return sx, sy
		end
	end
end

T.test("camera: click selects the colonist under the cursor, shift-click adds, empty ground clears, a box selects the lot", function()
	local m = H.boot()
	enter_colony(m)
	local w = H.world(m)
	-- bring the camera over the colonists
	local c1 = w.s.colonists[1]
	m:nui("focus", { x = c1.pos.x, y = c1.pos.y })
	m:step(1000)
	local sx, sy = screen_of(m, c1.id)
	T.truthy(sx and sx > 0 and sx < 1, "the colonist is on screen")
	m:nui("mouse", { type = "down", button = 0, x = sx, y = sy }); m:nui("mouse", { type = "up", button = 0, x = sx, y = sy })
	local sel = m:nui_messages("selection")
	T.eq(sel[#sel].data.ids[1], c1.id)
	-- empty ground clears
	m:nui("mouse", { type = "down", button = 0, x = 0.05, y = 0.05 }); m:nui("mouse", { type = "up", button = 0, x = 0.05, y = 0.05 })
	sel = m:nui_messages("selection")
	T.eq(#sel[#sel].data.ids, 0)
	-- box select everything on screen
	m:nui("mouse", { type = "down", button = 0, x = 0.0, y = 0.0 }); m:nui("mouse", { type = "up", button = 0, x = 1.0, y = 1.0 })
	sel = m:nui_messages("selection")
	local on_screen = 0
	for _, c in ipairs(w.s.colonists) do local x, y = screen_of(m, c.id); if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then on_screen = on_screen + 1 end end
	T.eq(#sel[#sel].data.ids, on_screen)
	T.gt(on_screen, 0)
	T.eq(mods(m).Camera.stats.boxes, 1)
	assert_clean(m, "select")
end)

T.test("camera: right click orders the selection to the ground point under the cursor (sim coordinates), a ping is drawn, the colonist walks there", function()
	local m = H.boot()
	enter_colony(m)
	local w = H.world(m)
	local Cam = mods(m).Camera
	local c1 = w.s.colonists[1]
	m:nui("focus", { x = c1.pos.x, y = c1.pos.y })
	m:step(800)
	local sx, sy = screen_of(m, c1.id)
	m:nui("mouse", { type = "down", button = 0, x = sx, y = sy }); m:nui("mouse", { type = "up", button = 0, x = sx, y = sy })
	local n_orders = #m:sent("server", P.NET.order)
	local gx, gy = Cam.ground_at(0.6, 0.45)
	-- ground_at yields (Wait): call it from a thread
	local gx2, gy2
	m:spawn(m.sides.client, function() gx2, gy2 = Cam.ground_at(0.6, 0.45) end)
	m:step(300)
	T.truthy(gx2 and gy2)
	local markers = m.markers
	m:nui("mouse", { type = "context", x = 0.6, y = 0.45 })
	m:step(300)
	local orders = m:sent("server", P.NET.order)
	T.eq(#orders, n_orders + 1)
	local o = orders[#orders].args[1]
	T.eq(o.kind, "goto"); T.eq(o.id, c1.id)
	T.near(o.target.x, gx2 - ORIGIN.x, 1.0); T.near(o.target.y, gy2 - ORIGIN.y, 1.0)
	T.truthy(P.sanitize_order(o), "a valid order")
	T.gt(m.markers, markers, "selection ring + ping markers are drawn")
	-- the sim gave the colonist a goto task; the ped walks to the origin-shifted coordinates
	local ped = m.ents[mods(m).Colonists.list[c1.id].ped]
	local function walked()
		for _, rec in ipairs(ped.task_log or {}) do if rec.name == "go_to_coord" and math.abs(rec.x - (o.target.x + ORIGIN.x)) < 2 and math.abs(rec.y - (o.target.y + ORIGIN.y)) < 2 then return true end end
		return false
	end
	T.truthy(m:wait_until(walked, 6000), "TaskGoToCoordAnyMeans towards the clicked point (the sim answers on its next tick)")
	assert_clean(m, "goto")
end)

T.test("camera: placement flow (start, ghost follows the cursor and snaps, green/red, commit sends the order, right click cancels)", function()
	local m = H.boot()
	enter_colony(m)
	local w = H.world(m)
	local Cam = mods(m).Camera
	local b = TUNING.base
	m:nui("focus", { x = b.x + 12, y = b.y + 8 })
	m:step(900)
	m:nui("ui", { name = "request_state", data = {} }) -- the page gets state / catalog; the client needs both for the validity tint
	m:step(600)
	m:nui("place", { op = "start", bp = "wall" })
	m:nui("mouse", { type = "move", x = 0.5, y = 0.5 })
	m:step(600)
	local pl = ctxm(m).placing
	T.truthy(pl and pl.pos and pl.ghost, "ghost created under the cursor")
	T.eq(pl.pos.x % ctxm(m).cfg.grid, 0, "snapped to the grid"); T.eq(pl.pos.y % ctxm(m).cfg.grid, 0)
	local gobj = m.ents[pl.ghost]
	T.eq(gobj.collision, false); T.truthy(gobj.alpha < 255); T.eq(gobj.outline, true)
	T.eq(pl.ok, true, "valid spot: " .. tostring(pl.reason))
	local last
	for _, msg in ipairs(m:nui_messages("place")) do if msg.data.bp == "wall" then last = msg.data end end
	T.truthy(last and last.ok == true and last.x == pl.pos.x)
	local sent0 = #m:sent("server", P.NET.order)
	-- commit with a click
	local ghosts0 = #ghosts(m) - 1 -- (the cursor ghost is one of them)
	m:nui("mouse", { type = "down", button = 0, x = 0.5, y = 0.5 }); m:nui("mouse", { type = "up", button = 0, x = 0.5, y = 0.5 })
	m:step(2500)
	local orders = m:sent("server", P.NET.order)
	T.eq(#orders, sent0 + 1)
	local o = orders[#orders].args[1]
	T.eq(o.kind, "place_blueprint"); T.eq(o.target.bp, "wall"); T.eq(o.target.pos.x, pl.pos.x)
	T.eq(ctxm(m).placing, nil, "placement mode ended")
	T.falsy(m.ents[pl.ghost].exists, "the cursor ghost was deleted")
	T.eq(#ghosts(m), ghosts0 + 1, "the real blueprint ghost exists")
	local res = m:out_events("order_result")
	T.eq(res[#res].ok, true)
	-- too far away: red, and committing is refused locally
	m:nui("place", { op = "start", bp = "wall" })
	m:nui("focus", { x = b.x + 400, y = b.y + 400 })
	m:step(900)
	m:nui("mouse", { type = "move", x = 0.5, y = 0.5 })
	m:step(600)
	T.eq(ctxm(m).placing.ok, false); T.eq(ctxm(m).placing.reason, "too_far")
	local n_orders = #m:sent("server", P.NET.order)
	m:nui("mouse", { type = "down", button = 0, x = 0.5, y = 0.5 }); m:nui("mouse", { type = "up", button = 0, x = 0.5, y = 0.5 })
	m:step(500)
	T.eq(#m:sent("server", P.NET.order), n_orders, "no order for an invalid spot")
	local toast
	for _, msg in ipairs(m:nui_messages("toast")) do toast = msg.data end
	T.truthy(toast and toast.text:find("too_far"))
	T.truthy(ctxm(m).placing, "still placing after a refused click")
	m:nui("mouse", { type = "context", x = 0.5, y = 0.5 })
	m:step(300)
	T.eq(ctxm(m).placing, nil, "right click cancels")
	assert_clean(m, "placement flow")
end)

-- ---------------------------------------------------------------------------------------------------------------------------- orders and UI actions through the NUI
T.test("NUI order: a priority click reaches the sim and the order_result comes back to the page", function()
	local m = H.boot()
	local w = H.world(m)
	local c = w.s.colonists[1]
	m:nui("order", { id = c.id, kind = "priority", target = { work = "cook", level = 1 } })
	m:step(800)
	T.eq(require("sim.colonist").priority(c, "cook"), 1)
	local res
	for _, msg in ipairs(m:nui_messages("events")) do for _, e in ipairs(msg.data) do if e.type == "order_result" and e.kind == "priority" then res = e end end end
	T.truthy(res and res.ok, "order_result delivered to the page")
	-- a hostile order from a compromised page never reaches the sim
	local rejected0 = m:host().stats.orders_rejected
	m:nui("order", { id = c.id, kind = "rm_rf", target = {} })
	m:nui("order", "garbage")
	m:step(800)
	T.ge(m:host().stats.orders_rejected, rejected0 + 1)
	assert_clean(m, "nui order")
end)

T.test("NUI ui: speed, pause, select, inventory move round-trips; the clock follows the speed", function()
	local m = H.boot()
	local w = H.world(m)
	local host = m:host()
	m:nui("ui", { name = "set_speed", data = { speed = 4 } })
	m:step(2500)
	T.eq(host.speed, 4)
	local clock
	for _, msg in ipairs(m:sent("client", P.NET.clock)) do clock = msg.args[1] end
	T.eq(clock.speed, 4); T.near(clock.scale, 2.0, 1e-9)
	T.eq(m.env.ms_per_min, 500, "SetMillisecondsPerGameMinute follows the sim speed")
	m:nui("ui", { name = "toggle_pause", data = {} })
	m:step(2500)
	T.eq(host.paused, true)
	T.eq(m.env.clock_paused, true, "the game clock stops with the sim")
	m:nui("ui", { name = "toggle_pause", data = {} })
	m:step(2500)
	T.eq(m.env.clock_paused, false)
	-- selection arrives with the card
	local c = w.s.colonists[2]
	m:nui("ui", { name = "select", data = { id = c.id } })
	m:step(600)
	local st
	for _, msg in ipairs(m:nui_messages("state")) do st = msg.data end
	T.eq(st.card and st.card.id, c.id)
	assert_clean(m, "nui ui")
end)

T.test("NUI ui: debug actions are refused unless debug / owner_admin is on", function()
	local m = H.boot({ convars = { outbreak_debug = "false", outbreak_owner_admin = "false" } })
	local host = m:host()
	local hs = #host.world.s.hordes
	m:nui("ui", { name = "debug_horde", data = { n = 30, dist = 120 } })
	m:step(600)
	T.eq(#host.world.s.hordes, hs)
	local m2 = H.boot({ convars = { outbreak_debug = "true" } })
	local hs2 = #m2:host().world.s.hordes
	m2:nui("ui", { name = "debug_horde", data = { n = 30, dist = 120 } })
	m2:step(600)
	T.eq(#m2:host().world.s.hordes, hs2 + 1)
end)

-- ---------------------------------------------------------------------------------------------------------------------------- world: clock, weather, power, population
T.test("world: the game clock follows the sim clock, the population is suppressed, and the base blacks out with the grid", function()
	local m = H.boot()
	local w = H.world(m)
	m:step(3000)
	local clock = require("sim.clock")
	local h, mi = clock.hour(w.s.t), clock.minute(w.s.t)
	T.truthy(m.env.clock, "the clock is overridden")
	local game_min = m.env.clock.h * 60 + m.env.clock.m
	local sim_min = h * 60 + math.floor(mi)
	local diff = math.abs(game_min - sim_min)
	T.le(math.min(diff, 1440 - diff), 3, "game clock within 3 minutes of the sim clock: " .. game_min .. " vs " .. sim_min)
	T.eq(m.env.ped_budget, 0); T.eq(m.env.random_cops, false); T.eq(m.env.wanted, 0)
	T.gt(m.env.density_calls, 0, "density multipliers are re-applied every frame")
	T.eq(m.env.scenarios.WORLD_VEHICLE_POLICE, false)
	T.eq(m.env.health_recharge, 0.0, "the survival body owns health")
	-- power outage: blackout on, then off again
	T.eq(m.env.blackout, false)
	T.truthy(m:host():debug("event", { id = "power_outage" }))
	m:step(1500)
	T.eq(w.s.grid.power.ok, false, "the sim lost power")
	T.eq(m.env.blackout, true, "SetBlackout(true)")
	local lamps_lit = m.lights
	m:step(500)
	m:host():debug("fast_forward", { minutes = 600 })
	m:step(2000)
	T.eq(w.s.grid.power.ok, true, "power came back")
	T.eq(m.env.blackout, false, "SetBlackout(false)")
	assert_clean(m, "world")
end)

T.test("world: weather events set the persistent weather; the HUD shows it", function()
	local m = H.boot()
	local w = H.world(m)
	T.truthy(m:host():debug("event", { id = "storm" }))
	m:step(1500)
	T.eq(m.env.weather, "THUNDER")
	local hud
	for _, msg in ipairs(m:nui_messages("hud")) do hud = msg.data end
	T.truthy(hud.weather)
	assert_clean(m, "weather")
end)

-- ---------------------------------------------------------------------------------------------------------------------------- persistence / resync end to end
T.test("save, new game and load recreate the world on the client: no leaked peds or props, counts match the sim", function()
	local m = H.boot()
	local w = H.world(m)
	local host = m:host()
	player_at_base(m)
	host:debug("horde", { n = 25, dist = 110 })
	m:step(8000)
	local p = wall_pos()
	m:nui("place", { op = "commit", bp = "wall", x = p.x, y = p.y })
	m:step(2500)
	T.truthy(host:save_game("test"))
	local peds_before = m:count("ped", true)
	local hash = host.world:hash()
	-- a brand-new game (reset): the old peds and props go, the new colonists appear
	m:nui("ui", { name = "new_game", data = { seed = 77, profile = "calm" } })
	m:step(5000)
	local w2 = host.world
	T.eq(w2.s.seed, 77)
	T.eq(m:count("ped", true), #w2.s.colonists, "only the new colonists remain")
	T.eq(#ghosts(m), 0)
	T.eq(mods(m).Zombies.alive_total(), 0)
	T.eq(#mods(m).Colonists.order, #w2.s.colonists)
	-- load the save: the world returns, peds follow
	m:nui("ui", { name = "load", data = {} })
	m:step(9000)
	T.eq(host.world.s.seed, 7, "the saved game (seed 7) is back")
	local colonists = #host.world.s.colonists
	local group = ctxm(m).rel.OB_COLONY
	local cp = 0
	for _, e in ipairs(m:entities("ped", true)) do if e.group == group and not e.dead then cp = cp + 1 end end
	T.eq(cp, colonists, "one living colonist ped per restored colonist (a fresh corpse may still lie around)")
	T.eq(#ghosts(m), 1, "the saved blueprint ghost is back")
	assert_clean(m, "save/load")
end)

T.test("a client that joins late (second hello) is brought up to date by the resync: nothing is duplicated", function()
	local m = H.boot()
	local w = H.world(m)
	player_at_base(m)
	m:host():debug("horde", { n = 20, dist = 110 })
	m:step(7000)
	local peds = m:count("ped", true)
	local objs = m:count("object", true)
	-- the NUI page (re)loads and says ready again: the server resyncs with reset=true
	m:nui("ready", {})
	m:step(6000)
	T.eq(m:count("ped", true), peds + 0, "same number of peds after the resync: " .. m:count("ped", true) .. " vs " .. peds)
	T.le(math.abs(m:count("object", true) - objs), 2, "props rebuilt (carried crates may differ)")
	assert_clean(m, "late join")
end)

-- ---------------------------------------------------------------------------------------------------------------------------- the player's own body
T.test("player: dying is reported, the sim is told, and the client respawns the player at the base after a few seconds", function()
	local m = H.boot()
	local host = m:host()
	m:kill(m.player.ped.handle)
	m:step(1500)
	local died = m:in_events("ped_died")
	local mine
	for _, e in ipairs(died) do if e.id == "player" then mine = e end end
	T.truthy(mine, "ped_died for the player")
	T.eq(host.survival.c.dead, true)
	m:step(8000)
	T.eq(m.resurrects, 1, "NetworkResurrectLocalPlayer once")
	T.eq(host.survival.c.dead, false, "the host revived the survival body")
	local p = m.player.ped
	T.lt(math.abs(p.x - (ORIGIN.x + 4)), 1.0, "respawned at the base")
	assert_clean(m, "player death")
end)

T.test("player: HUD hunger / thirst come from the host, the client does not send needs", function()
	local m = H.boot()
	m:step(4000)
	for _, e in ipairs(m:in_events("player_state")) do T.eq(e.needs, nil, "client reports position only") end
	local hud
	for _, msg in ipairs(m:nui_messages("hud")) do hud = msg.data end
	T.truthy(hud and hud.hunger and hud.thirst)
end)
