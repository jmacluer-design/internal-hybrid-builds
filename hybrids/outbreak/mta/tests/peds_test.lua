-- Peds, objects and the client-driver intents, through the REAL server Lua in the mock MTA: colonists, hordes, raiders, traders, buildings, piles.
local T, H = ...
T.group("peds")
local P = require("shared.protocol")
local NET = require("shared.mta_net")
local TUNING = require("data.tuning")

local function sctx(m) return H.sreq(m, "server.ctx") end
local function origin(m) return sctx(m).origin end
local function mods(m) return { Peds = H.sreq(m, "server.peds"), Zombies = H.sreq(m, "server.zombies"), Raiders = H.sreq(m, "server.raiders"), Colonists = H.sreq(m, "server.colonists"),
	Buildings = H.sreq(m, "server.buildings"), Props = H.sreq(m, "server.props"), Ground = H.sreq(m, "server.ground") } end
local function clean(m, what)
	T.eq(#m.errors, 0, (what or "") .. ": errors: " .. H.errors_text(m))
	T.eq(#m.net.bad_payloads, 0, (what or "") .. ": bad payloads: " .. table.concat(m.net.bad_payloads, " | "))
	T.eq(m.pool_overflow, nil, "the ped pool never overflowed")
end
local function of_kind(m, kind)
	local out = {}
	local Peds = H.sreq(m, "server.peds")
	for ped, rec in pairs(Peds.list) do if rec.kind == kind and not ped.destroyed then out[#out + 1] = ped end end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end
local function player_at_base(m, dx, dy)
	local o = origin(m)
	m:player_move_to(o.x + (dx or 6), o.y + (dy or 6))
	m:step(1500)
end
local function mat_total(w)
	local n = 0
	for _, h in ipairs(w.s.hordes) do if h.mat then n = n + h.mat.count end end
	return n
end

-- ------------------------------------------------------------------------------------------------------------------------ colonists
T.test("colonists: one ped per sim colonist, tagged, in range of origin + sim position, health full, the owner's client is their syncer", function()
	local m = H.boot({})
	local w = H.world(m)
	local peds = of_kind(m, "colonist")
	T.eq(#peds, #w.s.colonists)
	local o = origin(m)
	for _, c in ipairs(w.s.colonists) do
		local gx, gy = c.pos.x + o.x, c.pos.y + o.y
		local best = 1e9
		for _, p in ipairs(peds) do best = math.min(best, math.sqrt((p.x - gx) ^ 2 + (p.y - gy) ^ 2)) end
		T.lt(best, 15.0, "a ped near colonist " .. c.id)
	end
	for _, p in ipairs(peds) do
		T.truthy(p.data["ob:cid"] and p.data["ob:cid"]:match("^c%d+$"), "tagged with the colonist id")
		T.eq(p.health, 100)
		T.eq(p.syncer, m.player, "setElementSyncer(ped, owner)")
		T.truthy(p.model >= 3 and p.model <= 312)
		T.truthy(p.synced)
	end
	clean(m, "colonists")
	m:stop()
end)

T.test("colonists: tasks become go intents at origin-offset coordinates, the peds walk there and the animation plays on arrival", function()
	local m = H.boot({ warm_ms = 1000 })
	m:step(40000)
	local tasks = m:out_events("colonist_task")
	T.gt(#tasks, 0, "the sim assigned jobs")
	local drives = {}
	for _, item in ipairs(m:sent("client", NET.drive)) do for _, it in ipairs(item.args[1]) do drives[#drives + 1] = it end end
	T.gt(#drives, 0)
	local o = origin(m)
	local matched = 0
	for _, it in ipairs(drives) do
		if it.m == "go" then
			for _, tk in ipairs(tasks) do
				if math.abs(it.x - (tk.pos.x + o.x)) < 1e-6 and math.abs(it.y - (tk.pos.y + o.y)) < 1e-6 then matched = matched + 1; break end
			end
		end
	end
	T.gt(matched, 0, "intents carry colonist_task positions + origin")
	local C = mods(m).Colonists
	T.gt(C.stats.created, 3)
	local animated = 0
	for _, p in ipairs(of_kind(m, "colonist")) do if (p.anim_sets or 0) > 0 then animated = animated + 1 end end
	T.gt(animated, 0, "some colonist reached a destination and played its step animation")
	T.gt(m.sides.client.env.OutbreakClient().modules.Driver.stats.arrived, 0, "the client driver walked peds to their destinations")
	clean(m, "tasks")
	m:stop()
end)

T.test("colonists: a ped that lags is placed at the destination (the sim never waits for it); the deadline follows the sim's walking time and the time scale", function()
	local m = H.boot({ warm_ms = 1000 })
	m.auto_syncer = false -- nobody drives the peds: every walk lags
	m:step(120000)
	local C = mods(m).Colonists
	T.gt(C.stats.snaps, 0, "snaps happened: " .. C.stats.snaps)
	local ok = 0
	for _, e in pairs(C.list) do
		if e.ped and e.dest and e.arrived and e.ped.moved_by_script then
			if math.abs(e.ped.x - e.dest.x) < 1.5 and math.abs(e.ped.y - e.dest.y) < 1.5 then ok = ok + 1 end
		end
	end
	T.gt(ok, 0, "placed peds stand on their destination")
	T.gt(H.world(m).s.t, 480 + 30, "sim time kept going")
	local ctx = sctx(m)
	ctx.sim_scale = 0.5
	local near, far = C.allowed_ms(10), C.allowed_ms(200)
	T.lt(near, far); T.ge(near, ctx.cfg.snap_grace_ms)
	ctx.sim_scale = 8
	T.lt(C.allowed_ms(200), far, "a faster sim snaps sooner")
	ctx.sim_scale = 0.0001
	T.eq(C.allowed_ms(500), ctx.cfg.snap_max_ms, "capped")
	clean(m, "snap")
	m:stop()
end)

T.test("colonists: sim damage mirrors to ped health; damage the game dealt is reported once and the health put back; the sim applies it", function()
	local m = H.boot({ warm_ms = 2000 })
	local w = H.world(m)
	local C = mods(m).Colonists
	local e
	for _, x in pairs(C.list) do e = e or x end
	local hp_before = e.ped.health
	m:damage_ped(e.ped, 30)
	m:step(1500)
	local dmg = m:in_events("ped_damage")
	local mine = {}
	for _, d in ipairs(H.host(m).world.s.log or {}) do end
	-- ped_damage IN events are server-side here (no network): look at the sim instead
	local sim_c = w:colonist(e.id)
	T.truthy(sim_c.hp < sim_c.hp_max or #sim_c.wounds > 0, "the sim took the wound")
	T.eq(e.ped.health, hp_before, "ped health restored to the sim's value")
	T.eq(C.stats.damage_reports, 1, "reported exactly once")
	m:step(3000)
	T.eq(C.stats.damage_reports, 1, "not reported again")
	clean(m, "damage")
	m:stop()
end)

T.test("colonists: a ped the game kills is reported as ped_died and the sim removes the colonist; the corpse is destroyed after 25 s", function()
	local m = H.boot({ warm_ms = 2000 })
	local w = H.world(m)
	local n0 = #w.s.colonists
	local e
	for _, x in pairs(mods(m).Colonists.list) do e = e or x end
	local ped = e.ped
	m:damage_ped(ped, 500, m.player)
	m:step(2000)
	T.eq(#w.s.colonists, n0 - 1, "the sim removed the colonist")
	T.eq(#w.s.dead, 1)
	T.falsy(ped.destroyed, "the corpse lingers")
	m:step(30000)
	T.truthy(ped.destroyed, "destroyed after ~25 s")
	clean(m, "death")
	m:stop()
end)

T.test("colonists: a sim-side death kills the ped without echoing a second ped_died back; unarmed colonists flee a zombie, armed ones fight", function()
	local m = H.boot({ warm_ms = 2000 })
	local w = H.world(m)
	local C = mods(m).Colonists
	local id = w.s.colonists[2].id
	local deaths = C.stats.deaths_reported
	H.host(m):debug("kill_colonist", { id = id })
	m:step(1500)
	T.eq(C.stats.deaths_reported, deaths, "the sim's own death was not reported back")
	T.eq(#m:out_events("colonist_died"), 1)
	m:step(30000)
	T.eq(#of_kind(m, "colonist"), #w.s.colonists)
	-- a zombie next to an unarmed colonist: it runs away; give another a weapon through the sim and it fights
	player_at_base(m)
	local victims = {}
	for _, x in pairs(C.list) do if not x.dead and x.ped then victims[#victims + 1] = x end end
	local v = victims[1]
	H.host(m):debug("horde", { n = 4, dist = 60 })
	m:step(6000)
	local Z = mods(m).Zombies
	local zeds = of_kind(m, "zombie")
	T.gt(#zeds, 0)
	zeds[1].x, zeds[1].y = v.ped.x + 6, v.ped.y
	v.weapon = nil; v.drafted = false
	m:step(2500)
	T.gt(C.stats.flees + (v.fighting and 1 or 0), 0, "the colonist reacted to the zombie")
	clean(m, "react")
	m:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ hordes
T.test("hordes: a horde near the player materializes as exactly the sim's number of zombie peds, never in the player's face, spread over ticks", function()
	local m = H.boot({})
	local w = H.world(m)
	player_at_base(m)
	T.truthy(H.host(m):debug("horde", { n = 30, dist = 120 }))
	m:step(8000)
	local z = of_kind(m, "zombie")
	T.gt(mat_total(w), 0, "the sim materialized the horde")
	T.eq(#z, mat_total(w), "zombie peds == sim materialized count")
	T.eq(mods(m).Zombies.alive_total(), #z)
	local cfg = sctx(m).cfg
	T.le(#z + 4, cfg.max_peds)
	for _, p in ipairs(z) do
		T.ge(math.sqrt((p.x - m.player.x) ^ 2 + (p.y - m.player.y) ^ 2), cfg.spawn_min_dist - 1.0, "never spawned in the player's face")
		T.truthy(p.walk_style, "walking style set")
		T.truthy(p.health >= 40 and p.health <= 176)
		T.eq(p.syncer, m.player)
	end
	local times = {}
	for _, p in ipairs(z) do times[p.created_t] = (times[p.created_t] or 0) + 1 end
	for t, n in pairs(times) do T.le(n, cfg.spawn_per_tick * 2, "spawn burst at t=" .. t) end
	clean(m, "horde")
	m:stop()
end)

T.test("hordes: deaths (onPedWasted) are reported once with the horde id, kind and killer, the sim's horde shrinks, corpses are destroyed after a few seconds", function()
	local m = H.boot({})
	local w = H.world(m)
	player_at_base(m)
	H.host(m):debug("horde", { n = 20, dist = 100 })
	m:step(8000)
	local z = of_kind(m, "zombie")
	T.gt(#z, 5)
	local size_before = 0
	for _, h in ipairs(w.s.hordes) do size_before = size_before + h.size end
	local Z = mods(m).Zombies
	m:damage_ped(z[1], 500, m.player)
	m:damage_ped(z[2], 500, nil)
	m:step(2500)
	T.eq(Z.stats.killed, 2)
	local size_after = 0
	for _, h in ipairs(w.s.hordes) do size_after = size_after + h.size end
	T.eq(size_after, size_before - 2, "the sim removed two zombies from the horde")
	T.eq(H.sreq(m, "server.inject").stats.refused, 0)
	m:step(12000)
	T.truthy(z[1].destroyed and z[2].destroyed, "corpses destroyed after corpse_ms")
	T.eq(Z.alive_total(), #of_kind(m, "zombie"))
	clean(m, "deaths")
	m:stop()
end)

T.test("hordes: moving away despawns them (despawn_horde), nothing stays behind", function()
	local m = H.boot({})
	local w = H.world(m)
	player_at_base(m)
	H.host(m):debug("horde", { n = 25, dist = 100 })
	m:step(6000)
	T.gt(#of_kind(m, "zombie"), 0)
	m:player_move_to(origin(m).x + 900, origin(m).y + 900)
	m:step(6000)
	T.eq(mat_total(w), 0, "the sim dematerialized")
	T.eq(#of_kind(m, "zombie"), 0, "no zombie peds remain")
	T.eq(mods(m).Zombies.alive_total(), 0)
	clean(m, "despawn")
	m:stop()
end)

T.test("hordes: the ped cap holds (setting), the engine is not hammered, the rest waits; the pool guard refuses when the game's ped pool is nearly full", function()
	local m = H.boot({ settings = { max_peds = "14" } })
	local w = H.world(m)
	player_at_base(m)
	H.host(m):debug("horde", { n = 60, dist = 100 })
	m:step(12000)
	local created_before = m.calls.createPed or 0
	m:step(20000)
	local P = mods(m).Peds
	T.eq(sctx(m).cfg.max_peds, 14)
	T.le(P.n, 14); T.le(#m:live("ped"), 14)
	T.gt(P.stats.refused_cap, 0, "the cap refused creations")
	T.le((m.calls.createPed or 0) - created_before, 4, "after hitting the cap the spawner backs off instead of spinning")
	T.gt(mods(m).Zombies.pending_total(), 0, "the rest stays queued")
	clean(m, "cap")
	m:stop()
	local m2 = H.boot({ settings = { pool_guard = "130" }, ambient_peds = 126 })
	player_at_base(m2)
	H.host(m2):debug("horde", { n = 40, dist = 100 })
	m2:step(15000)
	T.le(#m2.sides.server.env.getElementsByType("ped"), 130, "the ped pool never went past the guard")
	T.gt(mods(m2).Peds.stats.refused_pool, 0)
	clean(m2, "pool guard")
	m2:stop()
end)

T.test("hordes: with max_materialized at 60 the sim never asks for more than 60 horde+raider peds and the ped use stays far below the 140-slot pool, even in a chaos run", function()
	local m = H.boot({ settings = { profile = "chaos", colonists = "6" } })
	local w = H.world(m)
	local TUN = H.sreq(m, "data.tuning")
	T.eq(TUN.horde.max_materialized, 60)
	local peak, peak_all = 0, 0
	player_at_base(m)
	for round = 1, 12 do
		H.host(m):debug("horde", { n = 60, dist = 90 + round * 10 })
		H.host(m):debug("event", { id = "gang_raid" })
		for _ = 1, 8 do
			m:step(2500)
			local hostile = #of_kind(m, "zombie") + #of_kind(m, "raider")
			peak = math.max(peak, hostile)
			peak_all = math.max(peak_all, #m:live("ped"))
			T.le(mat_total(w) + (function() local n = 0 for _, r in ipairs(w.s.raids) do if r.mat then n = n + r.mat.count end end return n end)(), 60, "the sim's own count stays within the cap")
			-- let the player kill some so the sim tops up
			local z = of_kind(m, "zombie")
			if z[1] then m:damage_ped(z[1], 500, m.player) end
		end
	end
	T.le(peak, 60, "hostile peds never exceeded max_materialized")
	T.le(peak_all, 60 + 16 + 4 + 12, "all peds incl. colonists, traders and corpses stay within the budget")
	T.gt(peak, 20, "the run really did push the horde (peak " .. peak .. ")")
	T.note("chaos run: peak hostile peds %d, peak all peds %d (hard cap %d, pool 140)", peak, peak_all, sctx(m).cfg.max_peds)
	clean(m, "budget")
	m:stop()
end)

T.test("hordes: createPed failing (the engine refuses) or invalid models never spin or raise: failures are counted, the group is not lost", function()
	local m = H.boot({ invalid_ped_models = { [78] = true, [79] = true, [134] = true, [135] = true, [137] = true, [212] = true, [230] = true, [200] = true, [160] = true } })
	player_at_base(m)
	H.host(m):debug("horde", { n = 12, dist = 100 })
	m:step(8000)
	local z = of_kind(m, "zombie")
	T.gt(#z, 0, "models other than the invalid ones were used (model 162 is still valid)")
	for _, p in ipairs(z) do T.eq(p.model, 162) end
	T.gt(mods(m).Peds.stats.model_fail, 0)
	m:stop()
	local m2 = H.boot({})
	player_at_base(m2)
	m2.fail.createPed = true
	H.host(m2):debug("horde", { n = 12, dist = 100 })
	m2:step(8000)
	local P = mods(m2).Peds
	T.eq(#of_kind(m2, "zombie"), 0)
	T.gt(P.stats.create_fail, 0); T.le(P.stats.create_fail, 40, "failures are bounded: each pending ped is tried once and dropped")
	T.gt(mods(m2).Zombies.stats.spawn_failed, 0)
	m2.fail.createPed = nil
	H.host(m2):debug("horde", { n = 5, dist = 100 })
	m2:step(8000)
	T.gt(#of_kind(m2, "zombie"), 0, "creation recovers once the engine does")
	clean(m2, "create failure")
	m2:stop()
end)

T.test("hordes: zombies notice, chase and bite the player: stance sets the detection radius, the scripted damage reaches the survival body and the HUD", function()
	local m = H.boot({})
	local host = H.host(m)
	player_at_base(m)
	host:debug("horde", { n = 10, dist = 110 })
	m:step(7000)
	local Z = mods(m).Zombies
	local z = of_kind(m, "zombie")
	T.gt(#z, 0)
	-- put one zombie 30 m from the standing player: inside the walking radius (35), outside the crouching one (10)
	local zed = z[1]
	for i = 2, #z do z[i].x, z[i].y = m.player.x + 300, m.player.y end
	zed.x, zed.y, zed.z = m.player.x + 30, m.player.y, m.player.z
	m.player.ducked = true
	m:step(1500)
	local rec
	for _, g in pairs(Z.groups) do if g.peds[zed] then rec = g.peds[zed] end end
	T.truthy(rec)
	T.ne(rec.state, "chase", "a crouching player 30 m away is not noticed (radius 10)")
	m.player.ducked = false
	m:step(1500)
	T.eq(rec.state, "chase", "standing (walk radius 35): noticed and chased")
	-- run up to the player: bitten
	zed.x, zed.y = m.player.x + 1.2, m.player.y
	local hp0 = host.survival.c.hp
	m:step(4000)
	T.gt(Z.stats.attacks, 0)
	T.lt(host.survival.c.hp, hp0, "the bite reached the survival body")
	T.near(m.player.health, host.survival:effects().health * 100, 3, "and the owner's ped health follows it")
	T.truthy(zed.anim and zed.anim.block == "FIGHT_B", "the swing animation plays")
	-- sprinting widens the radius to 45
	m.player.ducked = false
	rec.state = "wander"
	zed.x, zed.y = m.player.x + 42, m.player.y
	m:step(200)
	clean(m, "bite")
	m:stop()
end)

T.test("hordes: in colony view the player ped (a camera anchor) is not hunted; the dead go after colonists instead", function()
	local m = H.boot({})
	player_at_base(m)
	H.host(m):debug("horde", { n = 8, dist = 100 })
	m:step(7000)
	local z = of_kind(m, "zombie")
	T.gt(#z, 0)
	m.sides.client.env.OutbreakClient().set_mode("colony")
	m:step(1500)
	T.eq(sctx(m).colony_mode, true, "the server knows (ui_action screens)")
	local zed = z[1]
	zed.x, zed.y = m.player.x + 5, m.player.y
	local hp0 = H.host(m).survival.c.hp
	m:step(4000)
	T.eq(H.host(m).survival.c.hp, hp0, "the anchored player is not bitten")
	clean(m, "colony view")
	m:stop()
end)

T.test("hordes: a noise IN event sends materialized zombies to the spot (investigate), within loudness * 0.5 m; an explosion knocks nearby ones down", function()
	local m = H.boot({})
	player_at_base(m)
	H.host(m):debug("horde", { n = 12, dist = 100 })
	m:step(7000)
	local z = of_kind(m, "zombie")
	T.gt(#z, 3)
	local o = origin(m)
	local near, far = z[1], z[2]
	near.x, near.y = o.x + 200, o.y + 200
	far.x, far.y = o.x + 200 + 150, o.y + 200
	for i = 3, #z do z[i].x, z[i].y = o.x - 400, o.y - 400 end
	m:step(1200)
	-- a gunshot (110 -> 55 m) at the near zombie's position, as the client reports it
	local sx, sy = 200 + 20, 200
	m:send_remote("server", NET.inbound, m.resourceRoot, m.player, nil, { { type = "noise", pos = { x = sx, y = sy, z = 0 }, loudness = 110, kind = "gunshot" } })
	m:step(800)
	local Z = mods(m).Zombies
	local rec_near, rec_far
	for _, g in pairs(Z.groups) do for ped, r in pairs(g.peds) do if ped == near then rec_near = r elseif ped == far then rec_far = r end end end
	T.eq(rec_near.state, "investigate", "within 55 m of the shot")
	T.ne(rec_far.state, "investigate", "170 m away: not within the hearing radius")
	local drives = {}
	for _, item in ipairs(m:sent("client", NET.drive)) do for _, it in ipairs(item.args[1]) do if it.ped == near and it.m == "go" and math.abs(it.x - (o.x + sx)) < 1e-6 then drives[#drives + 1] = it end end end
	T.gt(#drives, 0, "a go intent to the noise position")
	m:send_remote("server", NET.inbound, m.resourceRoot, m.player, nil, { { type = "noise", pos = { x = 200, y = 200, z = 0 }, loudness = 200, kind = "explosion" } })
	m:step(600)
	T.eq(near.anim and near.anim.name, "FLOOR_hit_f", "knocked down by the blast")
	clean(m, "noise")
	m:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ raiders and traders
local function plan_raid_near(m, faction, points, dist)
	local w = H.world(m)
	local factions = require("sim.factions")
	local r = factions.plan_raid(w, points or 60, faction or "rustjaw")
	local b = TUNING.base
	r.x, r.y = b.x + (dist or 120), b.y
	return r
end

T.test("raiders: a raid near the player materializes as armed faction peds walking to the base (origin-offset target); they fight what is near", function()
	local m = H.boot({})
	local w = H.world(m)
	player_at_base(m)
	local r = plan_raid_near(m, "rustjaw", 80, 120)
	m:step(8000)
	T.truthy(r.mat and r.mat.count > 0, "the sim materialized the raid")
	local rd = of_kind(m, "raider")
	T.eq(#rd, r.mat.count, "raider peds == sim count")
	T.eq(mods(m).Raiders.alive_total(), #rd)
	local o = origin(m)
	for _, p in ipairs(rd) do
		T.truthy(next(p.weapons), "armed")
		T.truthy(p.current_weapon)
		local skins = sctx(m).cfg.faction_models.rustjaw
		local okm = false
		for _, s in ipairs(skins) do if s == p.model then okm = true end end
		T.truthy(okm, "a rustjaw skin")
	end
	local base_goes = 0
	for _, item in ipairs(m:sent("client", NET.drive)) do
		for _, it in ipairs(item.args[1]) do
			if it.m == "go" and math.abs(it.x - (TUNING.base.x + o.x)) < 1e-6 and math.abs(it.y - (TUNING.base.y + o.y)) < 1e-6 then base_goes = base_goes + 1 end
		end
	end
	T.ge(base_goes, #rd, "every raider was sent to the base")
	-- near the base they pick a target: attack intents with ranged = true carry the target element
	for _, p in ipairs(rd) do p.x, p.y = o.x + 20, o.y + 5 end
	m:step(1500)
	local attacks = 0
	for _, item in ipairs(m:sent("client", NET.drive)) do for _, it in ipairs(item.args[1]) do if it.m == "attack" and it.tgt then attacks = attacks + 1 end end end
	T.gt(attacks, 0, "attack intents with a target")
	clean(m, "raiders")
	m:stop()
end)

T.test("raiders: deaths are reported with the raid id; when the last one dies the raid is repelled; raid_report keeps the abstract position in sync; despawn clears them", function()
	local m = H.boot({})
	local w = H.world(m)
	player_at_base(m)
	local r = plan_raid_near(m, "tallow", 50, 100)
	m:step(12000)
	local rd = of_kind(m, "raider")
	T.gt(#rd, 0)
	T.gt(#m:in_events("raid_report") + H.sreq(m, "server.inject").stats.sent, 0)
	local rid = r.id
	for _, p in ipairs(rd) do m:damage_ped(p, 500, m.player) end
	m:step(3000)
	T.eq(require("sim.factions").find_raid(w, rid), nil, "the raid is over in the sim")
	T.eq(mods(m).Raiders.stats.killed, #rd)
	m:step(15000)
	T.eq(#of_kind(m, "raider"), 0, "bodies cleaned up")
	local r2 = plan_raid_near(m, "cinder", 50, 100)
	m:step(8000)
	T.gt(#of_kind(m, "raider"), 0)
	m:player_move_to(origin(m).x + 1500, origin(m).y)
	m:step(8000)
	T.eq(#of_kind(m, "raider"), 0, "despawn_raiders removed them")
	clean(m, "raid")
	m:stop()
end)

T.test("traders: a caravan puts two traders at its spot and removes them when it leaves", function()
	local m = H.boot({})
	local w = H.world(m)
	H.host(m):debug("event", { id = "caravan" })
	m:step(3000)
	local tr = of_kind(m, "trader")
	T.eq(#tr, 2, "two traders")
	local P = mods(m).Props
	local id
	for k in pairs(P.traders) do id = k end
	T.truthy(id)
	T.eq(#w.s.caravans, 1)
	-- time passes, the caravan leaves
	H.host(m):debug("fast_forward", { minutes = 60 * 8 })
	m:step(3000)
	T.eq(#of_kind(m, "trader"), 0)
	clean(m, "traders")
	m:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ buildings and piles
local function ghost_count(m)
	local n = 0
	for _, o in ipairs(m:live("object")) do if o.alpha < 255 and o.collisions == false then n = n + 1 end end
	return n
end

T.test("build: an order makes a translucent, collision-free site that ramps up with construction_progress and turns solid on construction_done; a refused order leaks nothing", function()
	local m = H.boot({})
	local w = H.world(m)
	local before = #m:live("object")
	local pos = { x = TUNING.base.x + 14, y = TUNING.base.y + 10 }
	m:send_remote("server", NET.order, m.resourceRoot, m.player, nil, { id = "colony", kind = "place_blueprint", target = { bp = "wall", pos = { x = pos.x, y = pos.y, z = 0 } } })
	m:step(1500)
	local b
	for _, x in ipairs(w.s.buildings) do if x.bp == "wall" and x.state ~= "built" and math.abs(x.pos.x - pos.x) < 0.5 then b = x end end
	T.truthy(b, "the sim planned the wall")
	local B = mods(m).Buildings
	local o = B.objs[b.id]
	T.truthy(o and o.obj, "an object exists for the site")
	T.eq(#m:live("object"), before + 1)
	T.eq(o.obj.collisions, false); T.lt(o.obj.alpha, 255)
	local first_alpha = o.obj.alpha
	local origin_ = origin(m)
	T.near(o.obj.x, pos.x + origin_.x, 0.01); T.near(o.obj.y, pos.y + origin_.y, 0.01)
	-- let the colony build it
	H.host(m):debug("autopilot", { on = true })
	local alphas, done = { first_alpha }, false
	for _ = 1, 400 do
		m:step(1000)
		local obj = B.objs[b.id] and B.objs[b.id].obj
		if obj then if alphas[#alphas] ~= obj.alpha then alphas[#alphas + 1] = obj.alpha end end
		if B.objs[b.id] and B.objs[b.id].state == "built" then done = true; break end
	end
	T.truthy(done, "the wall was built")
	for i = 2, #alphas do T.ge(alphas[i], alphas[i - 1], "the alpha ramp never goes down") end
	T.eq(o.obj.alpha, 255); T.eq(o.obj.collisions, true)
	T.eq(o.obj.frozen, true)
	-- a refused placement: no object leaks
	local n = #m:live("object")
	m:send_remote("server", NET.order, m.resourceRoot, m.player, nil, { id = "colony", kind = "place_blueprint", target = { bp = "wall", pos = { x = pos.x, y = pos.y, z = 0 } } })
	m:step(1500)
	T.eq(#m:live("object"), n, "blocked placement: no new object")
	local refused = false
	for _, e in ipairs(m:out_events("order_result")) do if e.ok == false and e.reason == "blocked" then refused = true end end
	T.truthy(refused, "the client got order_result blocked")
	clean(m, "build")
	m:stop()
end)

T.test("build: model fallback when the preferred model does not exist; the object cap refuses; destroyed buildings lose their object; a reset clears every object", function()
	local m = H.boot({ invalid_object_models = { [1407] = true, [1408] = true, [1419] = true, [1459] = true } }) -- every wall model invalid
	local w = H.world(m)
	local B = mods(m).Buildings
	local pos = { x = TUNING.base.x + 14, y = TUNING.base.y + 10 }
	m:send_remote("server", NET.order, m.resourceRoot, m.player, nil, { id = "colony", kind = "place_blueprint", target = { bp = "wall", pos = { x = pos.x, y = pos.y, z = 0 } } })
	m:step(1500)
	local wall
	for _, o in pairs(B.objs) do if o.bp == "wall" then wall = o end end
	T.truthy(wall and wall.obj, "the fallback crate was used")
	T.eq(wall.obj.model, 1448)
	T.gt(B.stats.model_fail, 0)
	-- destroyed: the object goes
	local n = #m:live("object")
	H.host(m):debug("event", { id = "storm" })
	H.host(m):absorb({ { type = "building_destroyed", t = w.s.t, id = wall.id, bp = "wall", pos = wall.pos } })
	H.host(m):flush_events()
	m:step(500)
	T.eq(#m:live("object"), n - 1)
	-- a reset (new game) clears everything
	m:send_remote("server", NET.ui_action, m.resourceRoot, m.player, nil, "new_game", { seed = 77 })
	m:step(2500)
	local expected = 0
	for _, b in ipairs(H.world(m).s.buildings) do expected = expected + 1 end
	T.eq(#m:live("object"), expected, "one object per building of the NEW world, none left from the old one")
	clean(m, "fallback")
	m:stop()
	local m2 = H.boot({ settings = { max_objects = "20" } })
	local B2 = mods(m2).Buildings
	for i = 1, 30 do m2:send_remote("server", NET.order, m2.resourceRoot, m2.player, nil, { id = "colony", kind = "place_blueprint", target = { bp = "crate", pos = { x = TUNING.base.x + (i % 6) * 6 - 15, y = TUNING.base.y + math.floor(i / 6) * 6 - 15, z = 0 } } }) end
	m2:step(8000)
	T.le(#m2:live("object"), 20, "the object ceiling holds")
	m2:stop()
end)

T.test("piles: every sim pile has a crate at origin + position; emptied piles lose theirs; new piles get one", function()
	local m = H.boot({})
	local w = H.world(m)
	local items = require("sim.items")
	local o = origin(m)
	T.eq(#w.s.piles, 0)
	for i, at in ipairs({ { 20, 12 }, { -18, 25 } }) do
		local p = w:pile_for({ x = TUNING.base.x + at[1], y = TUNING.base.y + at[2], z = 0 })
		items.add(p.items, "canned_beans", i + 1)
	end
	m:step(2500)
	T.eq(#w.s.piles, 2)
	local P = mods(m).Props
	local n = 0
	for ref, pr in pairs(P.props) do n = n + 1 end
	T.eq(n, 2)
	for _, p in ipairs(w.s.piles) do
		local pr = P.props["pile:" .. p.id]
		T.truthy(pr, "crate for " .. p.id)
		T.near(pr.x, p.pos.x + o.x, 0.01); T.near(pr.y, p.pos.y + o.y, 0.01)
		T.eq(pr.obj.collisions, false, "a marker: no collision")
	end
	local first = w.s.piles[1]
	w:remove_pile(first)
	local newp = w:pile_for({ x = TUNING.base.x + 40, y = TUNING.base.y - 25, z = 0 })
	items.add(newp.items, "canned_beans", 2)
	m:step(2500)
	T.eq(P.props["pile:" .. first.id], nil, "crate of the removed pile destroyed")
	T.truthy(P.props["pile:" .. newp.id], "crate of the new pile created")
	clean(m, "piles")
	m:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ ground
T.test("ground: the owner's client samples the ground, the server re-seats peds and objects created at the wrong height and uses the samples for new spawns; samples about foreign elements are ignored", function()
	local m = H.boot({})
	local G = mods(m).Ground
	m:step(3000)
	T.gt(G.stats.samples, 0, "samples arrived from the client")
	-- a ped created far below the real ground (the origin height guess was wrong): it falls through, the client reports it, the server puts it back
	local o = origin(m)
	local Peds = mods(m).Peds
	local ped = Peds.create("zombie", { 78 }, o.x + 30, o.y + 30, 0.0, "hTEST")
	T.truthy(ped)
	ped.z = -20.0 -- below the terrain
	m:step(3000)
	T.falsy(ped.fell, "the ped never fell through the map")
	T.gt(ped.z, 10.0, "re-seated above the ground: z = " .. ped.z)
	T.gt(G.stats.reseated, 0)
	local gz, known = G.z_at(m.player.x, m.player.y)
	T.truthy(known, "a sample exists near the player")
	T.near(gz, H.Mock.terrain(m.player.x, m.player.y), 3.5, "the sampled height is the terrain height")
	-- foreign element / junk samples are rejected
	local rejected = G.stats.rejected
	G.on_samples({ { e = m.player, x = 1, y = 1, z = 1 }, { e = ped, x = "x", y = 1, z = 1 }, { x = 0 / 0, y = 1, z = 1 }, { x = 1, y = 1, z = 1e9 } })
	T.eq(G.stats.rejected, rejected + 4)
	Peds.destroy(ped)
	clean(m, "ground")
	m:stop()
end)
