-- server/zombies.lua : materialize / dematerialize horde members as server-created peds (spawn_horde / despawn_horde) and run their perception and decisions (the "brain").
-- The sim decides WHEN peds exist and how many (TUNING.horde.max_materialized, set from the max_materialized setting); this module also enforces the engine-side limits
-- (cfg.max_peds hard cap + the ped-element guard in server/peds.lua) and never creates more than allowed. Locomotion and the swing animation are executed by the owner's client
-- (client/driver.lua) from the intents this module sends through server/peds.lua; damage is scripted here (the same model as the FiveM adapter: range + cooldown) and fed to the sim.
--
-- borrowed (see THIRD_PARTY.md):
--   TitansProductions/TP-Advanced-Zombies (Apache-2.0): distance based detection (crouching 10 / walking 35 / sprinting 45 m, +15 for a fast vehicle), the chase-the-target loop,
--     the melee attack cadence; the numbers are in shared/mta_config.lua. Changed here: decisions run on the MTA server, perception uses the owner's speed (the server has no
--     getPedMoveState), the attack is scripted damage plus an animation.
--   Blumlaut/RottenV (MIT): corpses linger a few seconds, then are deleted; walker / runner / brute / screamer presets (adapted numbers).
--   NullSystemWorks/mtadayz + mta-resources/deadwalkers (custom / no licence: REFERENCE ONLY, nothing copied): read to learn that MTA zombies are ordinary peds whose syncer client sets
--     control states, that they use setPedWalkingStyle / setPedAnimation for the shamble, and which animation names work. Everything below is written fresh.
-- Written here: group bookkeeping, spawn queue with backoff, batching of the think loop, noise investigation, colonist targets, sim reporting.
local ctx = require("server.ctx")
local Peds = require("server.peds")
local Net = require("server.inject")

local Z = { groups = {}, order = {}, cursor = 1, flat = {}, stats = { spawned = 0, killed = 0, attacks = 0, spawn_failed = 0, investigated = 0 } }
local cfg = ctx.cfg
local KINDS = ctx.config.zombie_kinds
local KIND_ORDER = { "walker", "runner", "brute", "screamer" }
local anims = ctx.config.anims

local function dist3(ax, ay, az, bx, by, bz)
	local dx, dy, dz = ax - bx, ay - by, (az or 0.0) - (bz or 0.0)
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

local function pending_total(g)
	local n = 0
	for _, k in ipairs(KIND_ORDER) do n = n + (g.pending[k] or 0) end
	return n
end

-- ---------------------------------------------------------------------------------------------------------------- the player (the sim's observer is the client's report; the target is the real ped)
local PI = { x = nil, y = nil, z = nil, t = 0, speed = 0.0, ducked = false, in_vehicle = false, alive = false }
Z.pinfo = PI

function Z.update_player()
	local o = ctx.owner_el()
	PI.alive = false
	if not o or isPedDead(o) or ctx.colony_mode then return end -- in colony view the player ped is only a camera anchor: the dead do not hunt it
	local x, y, z = getElementPosition(o)
	local now = getTickCount()
	if PI.x and now > PI.t then
		local inst = math.sqrt((x - PI.x) ^ 2 + (y - PI.y) ^ 2) / ((now - PI.t) / 1000)
		PI.speed = PI.speed * 0.5 + inst * 0.5
	end
	PI.x, PI.y, PI.z, PI.t = x, y, z, now
	PI.ducked = isPedDucked(o) and true or false
	PI.in_vehicle = isPedInVehicle(o) and true or false
	PI.alive = true
end

-- distance within which a zombie notices the player (TP-Advanced-Zombies: crouching 10, walking 35, sprinting 45)
local function detect_radius(preset)
	local d = cfg.detect
	local r = d.walk
	if PI.ducked then r = d.crouch
	elseif PI.speed > 4.5 then r = d.sprint end
	if PI.in_vehicle and PI.speed > 4.0 then r = d.sprint + 15.0 end
	return r * preset.detect
end

-- ---------------------------------------------------------------------------------------------------------------- ped setup
local function configure(ped, kind)
	local k = KINDS[kind] or KINDS.walker
	if k.stat24 then setPedStat(ped, 24, k.stat24) end -- max-health stat: brutes can have more than 100 hp
	setElementHealth(ped, math.random(k.hp[1], k.hp[2]))
	setPedWalkingStyle(ped, k.walk)
end

-- a point near the group centre, never inside the player's face (spawn_min_dist)
local function spawn_point(g, total)
	local c = g.center
	local radius = 2.0 + math.sqrt(math.max(1, total)) * 1.4
	local x, y
	for _ = 1, 4 do
		local a = math.random() * 6.2831853
		local r = math.sqrt(math.random()) * radius
		x, y = c.x + math.cos(a) * r, c.y + math.sin(a) * r
		if not PI.x then break end
		local dx, dy = x - PI.x, y - PI.y
		local len = math.sqrt(dx * dx + dy * dy)
		if len >= cfg.spawn_min_dist then break end
		if len < 0.5 then dx, dy, len = 1.0, 0.0, 1.0 end
		x, y = PI.x + dx / len * cfg.spawn_min_dist, PI.y + dy / len * cfg.spawn_min_dist -- push out to the minimum distance
	end
	return x, y
end

local function spawn_one(g, kind)
	local x, y = spawn_point(g, g.alive + pending_total(g))
	local models = (kind == "brute" and #cfg.brute_models > 0) and cfg.brute_models or cfg.zombie_models
	local ped, why = Peds.create("zombie", models, x, y, math.random() * 360.0, g.id)
	if not ped then return false, why end
	configure(ped, kind)
	g.peds[ped] = { ped = ped, kind = kind, state = "wander", born = getTickCount(), last_attack = 0, last_task = 0, scream_t = 0 }
	g.alive = g.alive + 1
	Z.stats.spawned = Z.stats.spawned + 1
	return true
end

-- called every cfg.spawn_ms
function Z.spawn_step()
	Z.update_player()
	local now = getTickCount()
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
	Peds.sweep()
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
	for ped in pairs(g.peds) do Peds.destroy(ped); n = n + 1 end
	drop_group(id)
	return n
end

ctx.on("despawn_horde", function(ev) remove_group(ev.id) end)

-- ---------------------------------------------------------------------------------------------------------------- perception and decisions
-- colonist targets are registered by server/colonists.lua: function() -> list of { ped, id }
Z.colonist_targets = function() return {} end

local function nearest_target(px, py, pz, preset)
	local best, bd
	if PI.alive then
		local d = dist3(px, py, pz, PI.x, PI.y, PI.z)
		if d <= detect_radius(preset) then best, bd = { ped = ctx.owner_el(), kind = "player" }, d end
	end
	local list = Z.colonist_targets()
	for i = 1, #list do
		local t = list[i]
		if isElement(t.ped) and not isPedDead(t.ped) then
			local tx, ty, tz = getElementPosition(t.ped)
			local d = dist3(px, py, pz, tx, ty, tz)
			local reach = detect_radius(preset) * 0.6
			if d <= reach and (not bd or d < bd) then best, bd = { ped = t.ped, kind = "colonist", id = t.id }, d end
		end
	end
	return best, bd
end

-- a zombie that has noticed something moves one speed step faster than it shambles (walker 1 -> 2, runner 2 -> 3)
local function hunt_speed(kind) return math.min(3, KINDS[kind].speed + 1) end

local function chase(z, target, tx, ty)
	z.state, z.target, z.last_task = "chase", target, getTickCount()
	Peds.drive(z.ped, { m = "go", x = tx, y = ty, s = hunt_speed(z.kind), r = 1.0 })
end

local function attack(z, target, now)
	local k = KINDS[z.kind]
	z.last_attack = now
	Z.stats.attacks = Z.stats.attacks + 1
	local a = anims.attack
	if a then setPedAnimation(z.ped, a[1], a[2], 500, false, false, false, false) end
	local dmg = math.random(k.dmg[1], k.dmg[2])
	local kind = (math.random() < 0.3) and "bite" or "scratch"
	if target.kind == "player" then
		Net.event({ type = "player_damage", amount = dmg, kind = kind })
	else
		Net.event({ type = "ped_damage", id = target.id, amount = dmg, kind = kind })
	end
end

-- one zombie dies (the onPedWasted handler or the think loop noticed): report once with the horde id and kind, keep the corpse a few seconds
local function report_death(g, z, killer)
	if not g.peds[z.ped] then return end
	Z.stats.killed = Z.stats.killed + 1
	local cause = (killer ~= nil and killer == ctx.owner) and "player" or "other"
	Net.event({ type = "ped_died", id = g.id, zkind = z.kind, cause = cause })
	g.peds[z.ped] = nil
	g.alive = g.alive - 1
	Peds.corpse(z.ped)
end

function Z.on_wasted(ped, killer)
	local rec = Peds.list[ped]
	if not rec or rec.kind ~= "zombie" then return false end
	local g = Z.groups[rec.tag]
	local z = g and g.peds[ped]
	if z then report_death(g, z, killer) end
	return true
end

-- one decision step over a batch of zombies (round robin so the cost stays flat with 60 peds)
function Z.think()
	Z.update_player()
	local now = getTickCount()
	local flat = Z.flat
	for i = #flat, 1, -1 do flat[i] = nil end
	for _, id in ipairs(Z.order) do
		local g = Z.groups[id]
		if g then for _, z in pairs(g.peds) do flat[#flat + 1] = { g = g, z = z } end end
	end
	if #flat == 0 then Peds.flush_drive(); return 0 end
	local n = math.min(cfg.brain_batch, #flat)
	for step = 1, n do
		local idx = (Z.cursor + step - 2) % #flat + 1
		local item = flat[idx]
		local g, z = item.g, item.z
		if g.peds[z.ped] then
			local ped = z.ped
			if not isElement(ped) then
				g.peds[ped] = nil; g.alive = g.alive - 1; Peds.destroy(ped)
			elseif isPedDead(ped) then
				report_death(g, z, nil)
			else
				local k = KINDS[z.kind]
				local px, py, pz = getElementPosition(ped)
				local target, d = nearest_target(px, py, pz, k)
				if target then
					local tx, ty, tz = getElementPosition(target.ped)
					if z.state ~= "chase" or z.target ~= target.ped or now - z.last_task > 700 then
						chase(z, target.ped, tx, ty)
						z.target = target.ped
						if k.screams and now - z.scream_t > 20000 then
							z.scream_t = now
							local sx, sy = ctx.to_sim(px, py)
							Net.event({ type = "noise", pos = { x = sx, y = sy, z = 0.0 }, loudness = ctx.config.noise.scream, kind = "scream" })
						end
					end
					if d <= cfg.attack_range and now - z.last_attack >= cfg.attack_cooldown_ms then attack(z, target, now) end
				elseif z.state == "chase" and now - z.last_task > 8000 then
					z.state, z.target = "wander", nil -- lost them
					Peds.drive(ped, { m = "wander", s = 1 })
				elseif z.state == "investigate" and z.dest then
					if dist3(px, py, pz, z.dest.x, z.dest.y, z.dest.z) < 3.0 or now - z.last_task > 15000 then
						z.state, z.dest = "wander", nil
						Peds.drive(ped, { m = "wander", s = 1 })
					end
				elseif z.state == "wander" then
					Peds.drive(ped, { m = "wander", s = 1 }) -- (suppressed while unchanged)
				end
			end
		end
	end
	Z.cursor = (Z.cursor + n - 1) % math.max(1, #flat) + 1
	Peds.flush_drive()
	return n
end

-- something loud happened (a noise IN event, converted to game space): materialized zombies within loudness * 0.5 m go and look (RottenV: hearing range 65 m)
function Z.hear(x, y, z, loudness)
	local radius = math.min(loudness * 0.5, cfg.hear_gunshot)
	local n = 0
	for _, id in ipairs(Z.order) do
		local g = Z.groups[id]
		for ped, zz in pairs(g.peds) do
			if zz.state ~= "chase" and isElement(ped) and not isPedDead(ped) then
				local px, py, pz = getElementPosition(ped)
				if dist3(px, py, pz, x, y, z) <= radius then
					zz.state, zz.last_task, zz.dest = "investigate", getTickCount(), { x = x, y = y, z = z }
					Peds.drive(ped, { m = "go", x = x, y = y, s = hunt_speed(zz.kind), r = 2.0 })
					n = n + 1
				end
			end
		end
	end
	Z.stats.investigated = Z.stats.investigated + n
	Peds.flush_drive()
	return n
end

-- explosions knock nearby zombies down for a moment (FLOOR_hit_f, an animation that is known to work); brutes shrug it off
function Z.blast(x, y, z, radius)
	local n = 0
	for _, id in ipairs(Z.order) do
		for ped, zz in pairs(Z.groups[id].peds) do
			if isElement(ped) and not KINDS[zz.kind].boss then
				local px, py, pz = getElementPosition(ped)
				if dist3(px, py, pz, x, y, z) <= radius then
					setPedAnimation(ped, "PED", "FLOOR_hit_f", 2500, false, false, false, false)
					Peds.drive(ped, { m = "stop" }, true)
					zz.last_task = 0
					n = n + 1
				end
			end
		end
	end
	return n
end

-- send each materialized horde's centroid back so the abstract position stays in sync (API.md horde_report), at most once per 5 s per horde
function Z.report()
	local now = getTickCount()
	for _, id in ipairs(Z.order) do
		local g = Z.groups[id]
		if g.alive > 0 and now - g.last_report >= 5000 then
			g.last_report = now
			local sx, sy, n = 0.0, 0.0, 0
			for ped in pairs(g.peds) do
				if isElement(ped) then local px, py = getElementPosition(ped); sx, sy, n = sx + px, sy + py, n + 1 end
			end
			if n > 0 then
				local cx, cy = ctx.to_sim(sx / n, sy / n)
				Net.event({ type = "horde_report", id = id, pos = { x = cx, y = cy, z = 0.0 } })
			end
		end
	end
end

-- nearest live zombie within `radius` metres of (x, y, z) (colonists use it to choose between fight and flight)
function Z.nearest(x, y, z, radius)
	local best, bd = nil, radius
	for _, id in ipairs(Z.order) do
		for ped in pairs(Z.groups[id].peds) do
			if isElement(ped) and not isPedDead(ped) then
				local px, py, pz = getElementPosition(ped)
				local d = dist3(px, py, pz, x, y, z)
				if d <= bd then best, bd = ped, d end
			end
		end
	end
	return best
end

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
end

function Z.start()
	ctx.every("zombies.spawn", cfg.spawn_ms, Z.spawn_step)
	ctx.every("zombies.think", cfg.brain_ms, function() Z.think(); Z.report() end)
end

ctx.on_reset("zombies", Z.clear)
ctx.on_cleanup("zombies", Z.clear)
return Z
