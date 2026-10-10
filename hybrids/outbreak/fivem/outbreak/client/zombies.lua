-- client/zombies.lua : materialize / dematerialize horde members as peds (spawn_horde / despawn_horde) and run their perception, chase, attack and
-- ragdoll logic. The sim decides WHEN peds exist and how many (TUNING.horde.max_materialized); this module also enforces the engine-side limits
-- (cfg.max_peds hard cap + the CPed pool guard in client/pool.lua) and never asks the sim for more than it can create.
--
-- borrowed (see THIRD_PARTY.md):
--   Blumlaut/RottenV client/spawners/zombiespawner.lua (MIT): the ped configuration recipe (SetPedSeeingRange / SetPedHearingRange, combat and flee
--     attributes 16/17/46/5, config flags 100/33, drunk movement clipsets, damage packs, "dies when injured" off), boss presets, corpse delete queue.
--   TitansProductions/TP-Advanced-Zombies client/tp-client_main.lua (Apache-2.0): distance based detection (crouching / walking / sprinting radii),
--     TaskGoToEntity chase, gunshot attraction, the stumble-animation melee attack with a cooldown, per-model health / damage tables.
-- Written here: the group bookkeeping, spawn queue with backoff, batching of the think loop, noise investigation, colonist targets, sim reporting.
local ctx = require("client.ctx")
local Pool = require("client.pool")

local Z = { groups = {}, order = {}, dead = {}, flat = {}, cursor = 1, stats = { spawned = 0, killed = 0, attacks = 0, ragdolls = 0, spawn_failed = 0 } }
local cfg = ctx.cfg

-- per-kind presets (numbers adapted from RottenV / TP-Advanced-Zombies; the sim's own combat numbers are not used for real peds)
local KINDS = {
	walker = { health = { 160, 260 }, clipset = "move_m@drunk@verydrunk", rate = 1.0, see = 20.0, hear = 65.0, speed = 1.0, dmg = { 6, 12 }, detect = 1.0 },
	runner = { health = { 110, 170 }, clipset = "move_m@drunk@moderatedrunk", rate = 1.35, see = 30.0, hear = 80.0, speed = 2.0, dmg = { 5, 9 }, detect = 1.25 },
	brute = { health = { 700, 1000 }, clipset = "move_m@drunk@verydrunk", rate = 1.1, see = 25.0, hear = 60.0, speed = 1.0, dmg = { 14, 24 }, detect = 1.0, boss = true },
	screamer = { health = { 100, 150 }, clipset = "move_m@drunk@moderatedrunk", rate = 1.0, see = 35.0, hear = 90.0, speed = 1.0, dmg = { 4, 8 }, detect = 1.6, screams = true },
}
Z.KINDS = KINDS
local KIND_ORDER = { "walker", "runner", "brute", "screamer" }
local DAMAGE_PACKS = { "BigHitByVehicle", "SCR_Dumpster", "SCR_Torture" }
local ATTACK_DICT, ATTACK_ANIM = "misscarsteal4@actor", "stumble"

local function dist3(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0.0) - (b.z or 0.0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function group_of(id)
	local g = Z.groups[id]
	if not g then
		g = { id = id, pending = {}, peds = {}, alive = 0, center = nil, last_report = 0, backoff_until = 0 }
		Z.groups[id] = g
		Z.order[#Z.order + 1] = id
	end
	return g
end

local function drop_group(id)
	Z.groups[id] = nil
	for i = #Z.order, 1, -1 do if Z.order[i] == id then table.remove(Z.order, i) end end
end

-- ---------------------------------------------------------------------------------------------------------------- ped setup
local function configure(ped, kind)
	local k = KINDS[kind] or KINDS.walker
	local hp = math.random(k.health[1], k.health[2])
	SetPedMaxHealth(ped, hp)
	SetEntityHealth(ped, hp)
	SetPedSeeingRange(ped, k.see)
	SetPedHearingRange(ped, k.hear)
	SetPedAccuracy(ped, 25)
	SetPedFleeAttributes(ped, 0, false)
	SetPedCombatAttributes(ped, 16, true)
	SetPedCombatAttributes(ped, 17, false)
	SetPedCombatAttributes(ped, 46, true)
	SetPedCombatAttributes(ped, 5, true)
	SetPedCombatRange(ped, 0)
	SetPedCombatMovement(ped, 0)
	SetPedAlertness(ped, 0)
	SetPedRelationshipGroupHash(ped, ctx.rel.OB_ZOMBIE)
	DisablePedPainAudio(ped, true)
	StopPedSpeaking(ped, true)
	SetPedDiesWhenInjured(ped, false)
	SetPedConfigFlag(ped, 100, true)
	SetPedConfigFlag(ped, 33, false)
	SetBlockingOfNonTemporaryEvents(ped, true)
	if k.boss then
		SetPedSuffersCriticalHits(ped, false)
		SetPedRagdollBlockingFlags(ped, 1)
	end
	if Pool.request_anim_set(k.clipset, 1500) then SetPedMovementClipset(ped, k.clipset, 1.0) end
	if k.rate ~= 1.0 then SetPedMoveRateOverride(ped, k.rate) end
	for i = 1, #DAMAGE_PACKS do ApplyPedDamagePack(ped, DAMAGE_PACKS[i], 0.0, 9.0) end
	TaskWanderStandard(ped, 10.0, 10)
end

-- a point near the group centre, never inside the player's face (spawn_min_dist) and on real ground
local function spawn_point(g, total)
	local player = GetEntityCoords(PlayerPedId())
	local c = g.center or player
	local radius = 2.0 + math.sqrt(math.max(1, total)) * 1.4
	local x, y
	for _ = 1, 4 do
		local a = math.random() * 6.2831853
		local r = math.sqrt(math.random()) * radius
		x, y = c.x + math.cos(a) * r, c.y + math.sin(a) * r
		local dx, dy = x - player.x, y - player.y
		if math.sqrt(dx * dx + dy * dy) >= cfg.spawn_min_dist then break end
		local len = math.sqrt(dx * dx + dy * dy)
		if len < 0.5 then dx, dy, len = 1.0, 0.0, 1.0 end
		x, y = player.x + dx / len * cfg.spawn_min_dist, player.y + dy / len * cfg.spawn_min_dist -- push out to the minimum distance
	end
	return x, y, Pool.ground_z(x, y, c.z or ctx.origin.z)
end

local function pending_total(g)
	local n = 0
	for _, k in ipairs(KIND_ORDER) do n = n + (g.pending[k] or 0) end
	return n
end

local function spawn_one(g, kind)
	local x, y, z = spawn_point(g, g.alive + pending_total(g))
	local models = (kind == "brute" and #cfg.brute_models > 0) and cfg.brute_models or cfg.zombie_models
	local ped, why = Pool.create_ped("zombie", models, x, y, z, math.random() * 360.0, g.id)
	if not ped then return false, why end
	configure(ped, kind)
	g.peds[ped] = { ped = ped, kind = kind, state = "wander", born = GetGameTimer(), last_attack = 0, last_task = 0, scream_t = 0 }
	g.alive = g.alive + 1
	Z.stats.spawned = Z.stats.spawned + 1
	return true
end

-- called from the spawner thread every ~250 ms
function Z.spawn_step()
	local now = GetGameTimer()
	local budget = cfg.spawn_per_tick
	for _, id in ipairs(Z.order) do
		local g = Z.groups[id]
		if g and now >= g.backoff_until then
			for _, kind in ipairs(KIND_ORDER) do
				while budget > 0 and (g.pending[kind] or 0) > 0 do
					local ok, why = spawn_one(g, kind)
					if ok then
						g.pending[kind] = g.pending[kind] - 1
						budget = budget - 1
					elseif why == "cap" or why == "pool" then
						g.backoff_until = now + 1500 -- the engine (or our cap) is full: try again later, never spin
						budget = 0
						break
					else
						g.pending[kind] = g.pending[kind] - 1 -- a model or create failure: give this one up
						Z.stats.spawn_failed = Z.stats.spawn_failed + 1
						budget = budget - 1
					end
				end
			end
		end
		if budget <= 0 then break end
	end
end

-- ---------------------------------------------------------------------------------------------------------------- OUT events
ctx.on("spawn_horde", function(ev)
	local g = group_of(ev.id)
	local x, y, z = ctx.to_game(ev.pos.x, ev.pos.y, ev.pos.z)
	g.center = { x = x, y = y, z = z }
	g.heading = ev.heading
	for kind, n in pairs(ev.mix or {}) do
		if KINDS[kind] then g.pending[kind] = (g.pending[kind] or 0) + n end
	end
end)

local function remove_group(id)
	local g = Z.groups[id]
	if not g then return 0 end
	local n = 0
	for ped in pairs(g.peds) do Pool.delete_ped(ped); n = n + 1 end
	drop_group(id)
	return n
end

ctx.on("despawn_horde", function(ev) remove_group(ev.id) end)

-- ---------------------------------------------------------------------------------------------------------------- perception
-- distance within which a zombie notices a target (TP-Advanced-Zombies: crouching 10, walking 35, sprinting 45)
local function detect_radius(preset, ped)
	local d = cfg.detect
	local r = d.walk
	if IsPedDucking(ped) or GetPedStealthMovement(ped) then r = d.crouch
	elseif IsPedSprinting(ped) then r = d.sprint end
	if IsPedInAnyVehicle(ped, false) then
		local veh = GetVehiclePedIsIn(ped, false)
		if veh ~= 0 and GetEntitySpeed(veh) > 4.0 then r = d.sprint + 15.0 end
	end
	return r * preset.detect
end

local function nearest_target(pos, targets, preset)
	local best, bd
	for i = 1, #targets do
		local t = targets[i]
		if not IsPedDeadOrDying(t.ped, true) then
			local d = dist3(pos, GetEntityCoords(t.ped))
			local reach = t.kind == "player" and detect_radius(preset, t.ped) or (detect_radius(preset, t.ped) * 0.6)
			if d <= reach and (not bd or d < bd) then best, bd = t, d end
		end
	end
	return best, bd
end

local function chase(z, target)
	z.state, z.target, z.last_task = "chase", target, GetGameTimer()
	TaskGoToEntity(z.ped, target.ped, -1, 0.0, KINDS[z.kind].speed, 1073741824, 0)
end

local function attack(z, target, now)
	local k = KINDS[z.kind]
	z.last_attack = now
	Z.stats.attacks = Z.stats.attacks + 1
	if Pool.request_anim_dict(ATTACK_DICT, 200) then TaskPlayAnim(z.ped, ATTACK_DICT, ATTACK_ANIM, 1.0, 1.0, 500, 9, 1.0, false, false, false) end
	local dmg = math.random(k.dmg[1], k.dmg[2])
	local kind = (math.random() < 0.3) and "bite" or "scratch"
	if target.kind == "player" then
		ctx.send({ type = "player_damage", amount = dmg, kind = kind })
		ShakeGameplayCam("SMALL_EXPLOSION_SHAKE", 0.04)
	else
		ctx.send({ type = "ped_damage", id = target.id, amount = dmg, kind = kind })
	end
	-- keep chasing after the swing (TP-Advanced-Zombies re-issues the task so a zombie never freezes)
	TaskGoToEntity(z.ped, target.ped, -1, 0.0, k.speed, 1073741824, 0)
end

local function report_death(g, z)
	Z.stats.killed = Z.stats.killed + 1
	local killer = GetPedSourceOfDeath(z.ped)
	ctx.send({ type = "ped_died", id = g.id, zkind = z.kind, cause = (killer == PlayerPedId()) and "player" or "other" })
	g.peds[z.ped] = nil
	g.alive = g.alive - 1
	Z.dead[#Z.dead + 1] = { ped = z.ped, at = GetGameTimer() + math.random(5000, 15000) } -- RottenV: corpses linger 5-15 s
end

-- one perception step over a batch of zombies (round robin so cost stays flat with 40 peds)
function Z.think()
	local now = GetGameTimer()
	-- flatten the groups into one array once per call
	local flat = Z.flat
	for i = #flat, 1, -1 do flat[i] = nil end
	for _, id in ipairs(Z.order) do
		local g = Z.groups[id]
		if g then for _, z in pairs(g.peds) do flat[#flat + 1] = { g = g, z = z } end end
	end
	if #flat == 0 then return 0 end
	local player = PlayerPedId()
	local targets = {}
	if not IsPedDeadOrDying(player, true) then targets[1] = { ped = player, kind = "player" } end
	local cps = ctx.colonist_peds and ctx.colonist_peds() or {}
	for i = 1, #cps do targets[#targets + 1] = { ped = cps[i].ped, kind = "colonist", id = cps[i].id } end
	local n = math.min(cfg.ai_batch, #flat)
	for step = 1, n do
		local idx = (Z.cursor + step - 2) % #flat + 1
		local item = flat[idx]
		local g, z = item.g, item.z
		if g.peds[z.ped] then
			local ped = z.ped
			if not DoesEntityExist(ped) then
				g.peds[ped] = nil; g.alive = g.alive - 1; Pool.delete_ped(ped)
			elseif IsPedDeadOrDying(ped, true) then
				report_death(g, z)
			else
				local k = KINDS[z.kind]
				local pos = GetEntityCoords(ped)
				-- ragdoll on damage (a hit that did not kill): TP/RottenV keep zombies on their feet, we let some stumble
				if HasEntityBeenDamagedByAnyPed(ped) then
					ClearEntityLastDamageEntity(ped)
					if not k.boss and math.random() < cfg.ragdoll_chance then
						SetPedToRagdoll(ped, 1200, 2200, 0, false, false, false)
						Z.stats.ragdolls = Z.stats.ragdolls + 1
						z.last_task = 0
					end
				end
				local target, d = nearest_target(pos, targets, k)
				if target then
					if z.state ~= "chase" or z.target ~= target or now - z.last_task > 4000 then
						chase(z, target)
						if k.screams and now - z.scream_t > 20000 then
							z.scream_t = now
							local sx, sy = ctx.to_sim(pos.x, pos.y)
							ctx.send({ type = "noise", pos = { x = sx, y = sy, z = 0.0 }, loudness = 90, kind = "scream" })
						end
					end
					if d <= cfg.attack_range and now - z.last_attack >= cfg.attack_cooldown_ms and not IsPedRagdoll(ped) then attack(z, target, now) end
				elseif z.state == "chase" and now - z.last_task > 8000 then
					z.state, z.target = "wander", nil -- lost them
					TaskWanderStandard(ped, 10.0, 10)
				end
			end
		end
	end
	Z.cursor = (Z.cursor + n - 1) % math.max(1, #flat) + 1
	return n
end

-- something loud happened (client/noise.lua): materialized zombies within loudness * 0.5 m go and look (RottenV: hearing range 65 m)
function Z.hear(x, y, z, loudness)
	local radius = math.min(loudness * 0.5, cfg.hear_gunshot)
	local n = 0
	for _, id in ipairs(Z.order) do
		local g = Z.groups[id]
		for ped, zz in pairs(g.peds) do
			if zz.state ~= "chase" and DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then
				local p = GetEntityCoords(ped)
				if dist3(p, { x = x, y = y, z = z }) <= radius then
					zz.state, zz.last_task = "investigate", GetGameTimer()
					TaskGoToCoordAnyMeans(ped, x, y, z, KINDS[zz.kind].speed, 0, false, 786603, 0.0)
					n = n + 1
				end
			end
		end
	end
	return n
end

-- explosions throw nearby zombies to the ground
function Z.blast(x, y, z, radius)
	local n = 0
	for _, id in ipairs(Z.order) do
		for ped, zz in pairs(Z.groups[id].peds) do
			if DoesEntityExist(ped) and dist3(GetEntityCoords(ped), { x = x, y = y, z = z }) <= radius and not KINDS[zz.kind].boss then
				SetPedToRagdoll(ped, 2500, 4000, 0, false, false, false); n = n + 1
			end
		end
	end
	return n
end

-- delete corpses whose time has come
function Z.sweep_dead()
	local now = GetGameTimer()
	for i = #Z.dead, 1, -1 do
		if now >= Z.dead[i].at then Pool.delete_ped(Z.dead[i].ped); table.remove(Z.dead, i) end
	end
end

-- send each materialized horde's centroid back so the abstract position stays in sync (API.md horde_report)
function Z.report()
	local now = GetGameTimer()
	for _, id in ipairs(Z.order) do
		local g = Z.groups[id]
		if g.alive > 0 and now - g.last_report >= 5000 then
			g.last_report = now
			local sx, sy, n = 0.0, 0.0, 0
			for ped in pairs(g.peds) do
				if DoesEntityExist(ped) then local p = GetEntityCoords(ped); sx, sy, n = sx + p.x, sy + p.y, n + 1 end
			end
			if n > 0 then
				local cx, cy = ctx.to_sim(sx / n, sy / n)
				ctx.send({ type = "horde_report", id = id, pos = { x = cx, y = cy, z = 0.0 } })
			end
		end
	end
end

-- nearest live zombie ped within `radius` metres of pos (used by colonists to decide between fight and flight)
function Z.nearest(pos, radius)
	local best, bd = nil, radius
	for _, id in ipairs(Z.order) do
		for ped in pairs(Z.groups[id].peds) do
			if DoesEntityExist(ped) and not IsPedDeadOrDying(ped, true) then
				local d = dist3(GetEntityCoords(ped), pos)
				if d <= bd then best, bd = ped, d end
			end
		end
	end
	return best
end
ctx.nearest_zombie = Z.nearest

function Z.alive_total()
	local n = 0
	for _, id in ipairs(Z.order) do n = n + Z.groups[id].alive end
	return n
end

function Z.pending_total()
	local n = 0
	for _, id in ipairs(Z.order) do n = n + pending_total(Z.groups[id]) end
	return n
end

function Z.clear()
	local ids = {}
	for i, id in ipairs(Z.order) do ids[i] = id end
	for _, id in ipairs(ids) do remove_group(id) end
	for i = #Z.dead, 1, -1 do Pool.delete_ped(Z.dead[i].ped); Z.dead[i] = nil end
end

function Z.start_threads()
	CreateThread(function()
		while ctx.running do
			Wait(250)
			Z.spawn_step()
			Z.sweep_dead()
		end
	end)
	CreateThread(function()
		while ctx.running do
			Wait(cfg.ai_ms)
			Z.think()
			Z.report()
		end
	end)
end

ctx.on_reset("zombies", Z.clear)
ctx.on_cleanup("zombies", Z.clear)
return Z
