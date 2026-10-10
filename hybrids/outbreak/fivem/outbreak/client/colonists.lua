-- client/colonists.lua : colonists as peds. The sim is authoritative for time, jobs, health and death; this module animates: it creates a ped per
-- colonist, walks it to every colonist_task position, plays a scenario for the step (hammering, guarding, sleeping, eating ...), carries a prop while
-- hauling, snaps it into place when it lags (API.md adapter responsibility 3), mirrors sim health onto the ped, reports damage / death back, makes
-- drafted colonists fight and unarmed ones flee. Nothing here is borrowed from a colonist framework (none exists); the ped plumbing (mission entity,
-- blocking events, keep-task, give weapon) follows the usual RottenV / TP-Advanced-Zombies ped setup conventions.
local ctx = require("client.ctx")
local Pool = require("client.pool")

local C = { list = {}, order = {}, stats = { created = 0, snaps = 0, damage_reports = 0, deaths_reported = 0, flees = 0 } }
local cfg = ctx.cfg
local WALK, RUN = 1.0, 2.0
local SIM_WALK = 80.0 -- sim units per sim minute (TUNING.colonist.walk_speed): how fast the SIM thinks a colonist walks
local CARRY_DICT, CARRY_ANIM = "anim@heists@box_carry@", "idle"
local CARRY_BONE = 28422 -- right hand

local function dist2(a, b) local dx, dy = a.x - b.x, a.y - b.y; return math.sqrt(dx * dx + dy * dy) end

-- ---------------------------------------------------------------------------------------------------------------- lookup
local function entry(id) return C.list[id] end
function C.peds_for_ai()
	local out = {}
	for _, id in ipairs(C.order) do
		local e = C.list[id]
		if e and e.ped and DoesEntityExist(e.ped) then out[#out + 1] = { ped = e.ped, id = e.id } end
	end
	return out
end
ctx.colonist_peds = C.peds_for_ai
function C.count() local n = 0; for _ in pairs(C.list) do n = n + 1 end; return n end

-- ---------------------------------------------------------------------------------------------------------------- ped lifecycle
local function health_for(e)
	local frac = (e.hp_max and e.hp_max > 0) and (e.hp / e.hp_max) or 1.0
	return 100 + math.floor(math.max(0.0, math.min(1.0, frac)) * 100.0)  -- GTA: 100 = dead, 200 = full
end

local function equip(e)
	local ped = e.ped
	if not ped then return end
	local name = e.weapon and ctx.config.weapons[e.weapon]
	if name then
		local hash = GetHashKey(name)
		GiveWeaponToPed(ped, hash, 120, false, false)
		if e.drafted then SetCurrentPedWeapon(ped, hash, true) end
	end
end

local function configure(e)
	local ped = e.ped
	SetPedRelationshipGroupHash(ped, ctx.rel.OB_COLONY)
	SetBlockingOfNonTemporaryEvents(ped, true) -- ambient reactions must not override the sim's jobs
	SetPedFleeAttributes(ped, 0, false)
	SetPedCombatAttributes(ped, 46, true)
	SetPedCombatAttributes(ped, 5, true)
	SetPedAccuracy(ped, 40)
	SetPedDropsWeaponsWhenDead(ped, false)
	SetPedKeepTask(ped, true)
	SetPedMaxHealth(ped, 200)
	SetEntityMaxHealth(ped, 200)
	SetEntityHealth(ped, health_for(e))
	e.expected_health = health_for(e)
	equip(e)
end

function C.ensure_ped(e)
	if e.ped and DoesEntityExist(e.ped) then return e.ped end
	if e.state == "away" or e.dead or e.creating then return nil end -- `creating`: model streaming yields, so the upkeep thread must not start a second creation
	e.creating = true
	local x, y, z = ctx.to_game(e.pos.x, e.pos.y, e.pos.z)
	z = Pool.ground_z(x, y, z)
	local ped, why = Pool.create_ped("colonist", ctx.cfg.colonist_models, x, y, z + 0.5, math.random() * 360.0, e.id)
	e.creating = nil
	if not ped then e.ped_fail = why; return nil end
	if C.list[e.id] ~= e then Pool.delete_ped(ped); return nil end -- the colonist left / the world was reset while the ped was streaming in
	e.ped, e.ped_fail = ped, nil
	C.stats.created = C.stats.created + 1
	configure(e)
	ctx.send({ type = "colonist_ref", id = e.id, ref = "ped:" .. tostring(ped) })
	if e.task then C.start_task(e, e.task) end
	return ped
end

local function drop_carry(e)
	if e.carry then
		DetachEntity(e.carry, true, true)
		Pool.delete_object(e.carry)
		e.carry = nil
	end
end

function C.remove_ped(e)
	if e.ped then
		drop_carry(e)
		Pool.delete_ped(e.ped)
		e.ped = nil
	end
end

-- ---------------------------------------------------------------------------------------------------------------- tasks
local function walk(e, pos, speed)
	e.walk_started = GetGameTimer()
	TaskGoToCoordAnyMeans(e.ped, pos.x, pos.y, pos.z, speed, 0, false, 786603, 0.0)
end

-- how long (real ms) a ped may take to reach a destination before it is snapped there. The SIM finishes the walk in distance / 80 sim minutes, and a sim
-- minute is only a second or two of real time (ctx.sim_scale = sim minutes per real second), so a ped can never keep pace: it gets what the sim
-- allowed plus a grace period to look like it walked, then it is placed (API.md adapter responsibility 3). A slower time scale = more walking.
local function allowed_ms(dist)
	local scale = math.max(0.02, ctx.sim_scale or 0.5)
	local sim_ms = dist / SIM_WALK / scale * 1000.0
	return math.min(cfg.snap_max_ms, cfg.snap_grace_ms + sim_ms * 1.5)
end
C.allowed_ms = allowed_ms

local function scenario_for(e, task)
	local sc = ctx.config.scenarios
	return sc[task.step or ""] or sc[task.kind] or sc.idle
end

local function carry_on(e)
	if e.carry or not e.ped then return end
	if not Pool.request_anim_dict(CARRY_DICT, 400) then return end
	local c = Pool.create_object(ctx.config.props._pile, 0.0, 0.0, 0.0, false)
	if not c then return end
	SetEntityCollision(c, false, false)
	AttachEntityToEntity(c, e.ped, GetPedBoneIndex(e.ped, CARRY_BONE), 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, true, true, false, true, 1, true)
	TaskPlayAnim(e.ped, CARRY_DICT, CARRY_ANIM, 6.0, -6.0, -1, 49, 0.0, false, false, false)
	e.carry = c
end

-- what a colonist does once it stands at the destination of a step
function C.perform(e, task)
	local ped = e.ped
	if not ped then return end
	local step = task.step
	e.arrived = true
	e.acted = step or task.kind
	if step == "pickup_pile" or step == "take_zone" then
		carry_on(e)
		return
	elseif step == "drop_zone" or step == "drop_site" then
		drop_carry(e)
		ClearPedTasks(ped)
		return
	end
	if task.kind == "idle" or step == "stand" or step == "noop" then
		drop_carry(e)
		ClearPedTasks(ped)
		return
	end
	if e.carry then drop_carry(e) end
	TaskStartScenarioInPlace(ped, scenario_for(e, task), 0, true)
end

function C.start_task(e, task)
	e.task = task
	e.arrived, e.acted = false, nil
	if not e.ped then return end
	local x, y, z = ctx.to_game(task.pos.x, task.pos.y, task.pos.z)
	e.dest = { x = x, y = y, z = z }
	e.dest_ground = false
	if task.kind == "idle" then
		C.perform(e, task)
		return
	end
	ClearPedTasks(e.ped)
	if e.carry then TaskPlayAnim(e.ped, CARRY_DICT, CARRY_ANIM, 6.0, -6.0, -1, 49, 0.0, false, false, false) end
	walk(e, e.dest, ((task.class or 1) >= 3 or (ctx.sim_scale or 0.5) >= 1.0) and RUN or WALK) -- hurry when the sim is running fast
end

ctx.on("colonist_joined", function(ev)
	local e = C.list[ev.id]
	if not e then
		e = { id = ev.id, name = ev.name, pos = ev.pos, state = "idle", hp = 100, hp_max = 100 }
		C.list[ev.id] = e
		C.order[#C.order + 1] = ev.id
	end
	e.name, e.pos = ev.name, ev.pos
	C.ensure_ped(e)
end)

ctx.on("colonist_task", function(ev)
	local e = entry(ev.id)
	if not e then return end
	C.start_task(e, { kind = ev.kind, step = ev.step, pos = ev.pos, class = ev.class, target = ev.target })
end)

ctx.on("colonist_state", function(ev)
	local e = entry(ev.id)
	if not e then return end
	local was_away, was_drafted = e.state == "away", e.drafted
	e.state, e.hp, e.hp_max, e.drafted, e.downed, e.weapon, e.pos = ev.state, ev.hp, ev.hp_max, ev.drafted, ev.downed, ev.weapon, ev.pos
	if e.state == "away" then C.remove_ped(e); return end
	if was_away then C.ensure_ped(e) end
	local ped = e.ped
	if not ped or not DoesEntityExist(ped) then return end
	if IsPedDeadOrDying(ped, true) then return end -- the game killed it: update_one reports the death, the sim's health must not paper over it
	C.report_damage(e) -- damage the game dealt since the last look must reach the sim BEFORE the sim's health overwrites it
	e.expected_health = health_for(e)
	SetEntityHealth(ped, e.expected_health)
	if e.downed then
		SetPedToRagdoll(ped, 4000, 6000, 0, false, false, false)
	end
	if e.drafted and not was_drafted then
		equip(e)
		ClearPedTasks(ped)
		e.fighting = true
		TaskCombatHatedTargetsAroundPed(ped, 60.0, 0)
	elseif was_drafted and not e.drafted then
		e.fighting = false
		ClearPedTasks(ped)
		if e.task then C.start_task(e, e.task) end
	end
end)

ctx.on("colonist_died", function(ev)
	local e = entry(ev.id)
	if not e then return end
	e.dead = true
	if e.ped and DoesEntityExist(e.ped) then
		drop_carry(e)
		SetEntityHealth(e.ped, 0)
		e.corpse_at = GetGameTimer() + 25000
	end
end)

ctx.on("colonist_left", function(ev)
	local e = entry(ev.id)
	if not e then return end
	C.remove_ped(e)
	C.list[ev.id] = nil
	for i = #C.order, 1, -1 do if C.order[i] == ev.id then table.remove(C.order, i) end end
end)

-- ---------------------------------------------------------------------------------------------------------------- per-colonist upkeep
-- guess what hurt a colonist. GetPedSourceOfDamage is server-only in FiveM, so use proximity: a zombie within arm's reach bites / scratches,
-- anything else that is not a fall is a bullet when gang peds are around, else blunt.
local function damage_kind(ped)
	local pos = GetEntityCoords(ped)
	if ctx.nearest_zombie and ctx.nearest_zombie(pos, 3.0) then return math.random() < 0.3 and "bite" or "scratch" end
	if IsPedFalling(ped) then return "fall" end
	if ctx.raiders_near and ctx.raiders_near(pos, 60.0) then return "bullet" end
	return "blunt"
end

-- the game hurt the ped behind the sim's back: report it, then put the health back where the sim says it is
function C.report_damage(e)
	local ped = e.ped
	local hp = GetEntityHealth(ped)
	local expect = e.expected_health or hp
	if hp < expect then
		local scale = (e.hp_max or 100) / 100.0
		ctx.send({ type = "ped_damage", id = e.id, amount = (expect - hp) * scale, kind = damage_kind(ped) })
		C.stats.damage_reports = C.stats.damage_reports + 1
		SetEntityHealth(ped, expect)
		ClearEntityLastDamageEntity(ped)
		return true
	end
	return false
end

function C.update_one(e, now)
	local ped = e.ped
	if not ped then
		if not e.dead and e.state ~= "away" and (not e.ped_retry or now >= e.ped_retry) then
			e.ped_retry = now + 2000
			C.ensure_ped(e)
		end
		return
	end
	if not DoesEntityExist(ped) then e.ped = nil; Pool.delete_ped(ped); return end
	if e.dead then
		if e.corpse_at and now >= e.corpse_at then C.remove_ped(e) end
		return
	end
	-- 1) the game killed it (or hurt it) behind the sim's back: report, then put the health back where the sim says it is
	if IsPedDeadOrDying(ped, true) then
		C.stats.deaths_reported = C.stats.deaths_reported + 1
		local src = GetPedSourceOfDeath(ped)
		local cause = (src and Pool.peds[src] and Pool.peds[src].kind == "zombie") and "zombies" or "killed"
		ctx.send({ type = "ped_died", id = e.id, cause = cause })
		e.dead = true
		e.corpse_at = now + 25000
		return
	end
	C.report_damage(e)
	-- 2) the sim moved on: arrival + snapping
	local task = e.task
	if task and e.dest and not e.arrived and not e.fighting then
		local p = GetEntityCoords(ped)
		local d = dist2(p, e.dest)
		if d <= 2.2 then
			C.perform(e, task)
		else
			if e.walk_started and now - e.walk_started > allowed_ms(d) then
				local z = Pool.ground_z(e.dest.x, e.dest.y, e.dest.z)
				SetEntityCoordsNoOffset(ped, e.dest.x, e.dest.y, z + 0.3, false, false, false)
				C.stats.snaps = C.stats.snaps + 1
				C.perform(e, task)
			end
		end
	end
	-- 3) the dead are close: fight when armed or drafted, run when not
	if not e.fighting and now - (e.threat_t or 0) > 1500 then
		e.threat_t = now
		local zp = ctx.nearest_zombie and ctx.nearest_zombie(GetEntityCoords(ped), 14.0)
		if zp then
			if e.weapon or e.drafted then
				e.fighting = true
				TaskCombatHatedTargetsAroundPed(ped, 40.0, 0)
			else
				C.stats.flees = C.stats.flees + 1
				TaskSmartFleePed(ped, zp, 60.0, 6000, false, false)
				e.walk_started = nil
			end
		end
	elseif e.fighting and not e.drafted and now - (e.threat_t or 0) > 1500 then
		e.threat_t = now
		if not (ctx.nearest_zombie and ctx.nearest_zombie(GetEntityCoords(ped), 25.0)) then
			e.fighting = false
			ClearPedTasks(ped)
			if e.task then C.start_task(e, e.task) end
		end
	end
end

function C.update()
	local now = GetGameTimer()
	for _, id in ipairs(C.order) do
		local e = C.list[id]
		if e then C.update_one(e, now) end
	end
end

function C.clear()
	for _, id in ipairs(C.order) do
		local e = C.list[id]
		if e then C.remove_ped(e) end
	end
	C.list, C.order = {}, {}
end

function C.start_threads()
	ctx.loop("colonists.update", 500, C.update)
end

ctx.on_reset("colonists", C.clear)
ctx.on_cleanup("colonists", C.clear)
return C
