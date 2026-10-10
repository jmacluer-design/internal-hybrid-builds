-- server/colonists.lua : colonists as peds. The sim is authoritative for time, jobs, health and death; this module animates: it creates a ped per colonist, sends the owner's client a
-- "go" intent for every colonist_task position, plays an animation for the step (building, eating, resting ...), places the ped at the destination when it lags (API.md adapter
-- responsibility 3: the sim never waits for peds), mirrors sim health onto the ped, reports damage / death back, and makes drafted or armed colonists fight and unarmed ones flee.
-- Written here (the FiveM adapter's client/colonists.lua structure on MTA functions; no colonist framework exists to borrow). The animation names were harvested from working MTA
-- scripts (see shared/mta_config.lua).
local ctx = require("server.ctx")
local Peds = require("server.peds")
local Net = require("server.inject")
local Ground = require("server.ground")

local C = { list = {}, order = {}, stats = { created = 0, snaps = 0, damage_reports = 0, deaths_reported = 0, flees = 0, refused = 0 } }
local cfg = ctx.cfg
local config = ctx.config
local SIM_WALK = 80.0 -- sim units per sim minute (TUNING.colonist.walk_speed): how fast the SIM thinks a colonist walks

C.zombie_near = function() return nil end   -- (x, y, z, radius) -> zombie ped | nil   (wired by server/main.lua)
C.raiders_near = function() return false end -- (x, y, radius) -> bool

local function dist2(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

function C.count() local n = 0; for _ in pairs(C.list) do n = n + 1 end; return n end

function C.ped_count()
	local n = 0
	for _, e in pairs(C.list) do if e.ped and isElement(e.ped) then n = n + 1 end end
	return n
end

-- living colonists that have a ped, for the zombies' and raiders' target choice: { { ped, id }, ... }
function C.peds_for_ai()
	local out = {}
	for _, id in ipairs(C.order) do
		local e = C.list[id]
		if e and not e.dead and e.ped and isElement(e.ped) then out[#out + 1] = { ped = e.ped, id = e.id } end
	end
	return out
end

-- ---------------------------------------------------------------------------------------------------------------- ped lifecycle
-- MTA ped health is 0..100: the sim's fraction
local function health_for(e)
	local frac = (e.hp_max and e.hp_max > 0) and (e.hp / e.hp_max) or 1.0
	return math.max(1.0, math.min(100.0, frac * 100.0))
end

local function equip(e)
	local w = e.weapon and config.weapons[e.weapon]
	if w and e.ped then Peds.give_weapon(e.ped, w, config.weapon_ammo.colonist, e.drafted and true or false) end
end

function C.ensure_ped(e)
	if e.ped and isElement(e.ped) then return e.ped end
	if e.state == "away" or e.dead then return nil end
	if C.ped_count() >= cfg.max_colonist_peds then C.stats.refused = C.stats.refused + 1; return nil end
	local x, y = ctx.to_game(e.pos.x, e.pos.y, e.pos.z)
	local ped, why = Peds.create("colonist", cfg.colonist_models, x, y, math.random() * 360.0, e.id)
	if not ped then e.ped_fail = why; return nil end
	e.ped, e.ped_fail = ped, nil
	setElementData(ped, "ob:cid", e.id) -- the owner's client maps a picked ped back to the colonist id with it (the server never reads it back: clients can write element data)
	C.stats.created = C.stats.created + 1
	e.expected_health = health_for(e)
	setElementHealth(ped, e.expected_health)
	equip(e)
	if e.task then C.start_task(e, e.task) end
	return ped
end

function C.remove_ped(e)
	if e.ped then
		Peds.destroy(e.ped)
		e.ped = nil
	end
end

-- ---------------------------------------------------------------------------------------------------------------- tasks
local function allowed_ms(dist)
	local scale = math.max(0.02, ctx.sim_scale or 0.5)
	local sim_ms = dist / SIM_WALK / scale * 1000.0
	return math.min(cfg.snap_max_ms, cfg.snap_grace_ms + sim_ms * 1.5)
end
C.allowed_ms = allowed_ms

local function anim_for(task)
	local a = config.anims
	return a[task.step or ""] or a[task.kind] or a.idle
end

-- what a colonist does once it stands at the destination of a step
function C.perform(e, task)
	local ped = e.ped
	if not ped or not isElement(ped) then return end
	local step = task.step
	e.arrived = true
	e.acted = step or task.kind
	Peds.drive(ped, { m = "stop" }, true)
	if step == "pickup_pile" or step == "take_zone" then
		local a = config.carry_anim
		setPedAnimation(ped, a[1], a[2], -1, a[3], false, false, false)
		return
	elseif step == "drop_zone" or step == "drop_site" or task.kind == "idle" or step == "stand" or step == "noop" then
		setPedAnimation(ped, false)
		return
	end
	local a = anim_for(task)
	if a then setPedAnimation(ped, a[1], a[2], -1, a[3], false, false, false) else setPedAnimation(ped, false) end
end

function C.start_task(e, task)
	e.task = task
	e.arrived, e.acted = false, nil
	if not e.ped or not isElement(e.ped) then return end
	local x, y = ctx.to_game(task.pos.x, task.pos.y, task.pos.z)
	e.dest = { x = x, y = y, z = Ground.z_at(x, y) + 1.0 }
	if task.kind == "idle" then
		C.perform(e, task)
		return
	end
	setPedAnimation(e.ped, false)
	e.walk_started = getTickCount()
	local hurry = (task.class or 1) >= 3 or (ctx.sim_scale or 0.5) >= 1.0
	Peds.drive(e.ped, { m = "go", x = e.dest.x, y = e.dest.y, s = hurry and 3 or 2, r = 1.5 }, true)
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
	local e = C.list[ev.id]
	if not e then return end
	C.start_task(e, { kind = ev.kind, step = ev.step, pos = ev.pos, class = ev.class, target = ev.target })
end)

ctx.on("colonist_state", function(ev)
	local e = C.list[ev.id]
	if not e then return end
	local was_away, was_drafted = e.state == "away", e.drafted
	e.state, e.hp, e.hp_max, e.drafted, e.downed, e.weapon, e.pos = ev.state, ev.hp, ev.hp_max, ev.drafted, ev.downed, ev.weapon, ev.pos
	if e.state == "away" then C.remove_ped(e); return end
	if was_away then C.ensure_ped(e) end
	local ped = e.ped
	if not ped or not isElement(ped) or isPedDead(ped) then return end -- the game killed it: update_one reports the death, the sim's health must not paper over it
	C.report_damage(e) -- damage the game dealt since the last look must reach the sim BEFORE the sim's health overwrites it
	e.expected_health = health_for(e)
	setElementHealth(ped, e.expected_health)
	if e.downed then
		Peds.drive(ped, { m = "stop" }, true)
		setPedAnimation(ped, "RYDER", "RYD_Die_PT1", -1, true, false, false, true)
		e.was_downed = true
	elseif e.was_downed then
		e.was_downed = nil
		setPedAnimation(ped, false)
		if e.task then C.start_task(e, e.task) end
	end
	if e.drafted and not was_drafted then
		equip(e)
		e.fighting = true
	elseif was_drafted and not e.drafted then
		e.fighting = false
		Peds.drive(ped, { m = "stop" }, true)
		if e.task then C.start_task(e, e.task) end
	end
end)

ctx.on("colonist_died", function(ev)
	local e = C.list[ev.id]
	if not e then return end
	e.dead = true -- set BEFORE killing: the onPedWasted handler must not report the sim's own death back to the sim
	if e.ped and isElement(e.ped) then
		Peds.drive(e.ped, { m = "stop" }, true)
		killPed(e.ped)
		Peds.corpse(e.ped, 25000)
	end
end)

ctx.on("colonist_left", function(ev)
	local e = C.list[ev.id]
	if not e then return end
	C.remove_ped(e)
	C.list[ev.id] = nil
	for i = #C.order, 1, -1 do if C.order[i] == ev.id then table.remove(C.order, i) end end
end)

-- ---------------------------------------------------------------------------------------------------------------- upkeep
-- guess what hurt a colonist: a zombie within arm's reach bites / scratches, a fall is a fall, raiders nearby mean bullets, else blunt
local function damage_kind(ped)
	local x, y, z = getElementPosition(ped)
	if C.zombie_near(x, y, z, 3.0) then return math.random() < 0.3 and "bite" or "scratch" end
	if C.raiders_near(x, y, 60.0) then return "bullet" end
	return "blunt"
end

-- the game hurt the ped behind the sim's back: report it, then put the health back where the sim says it is
function C.report_damage(e)
	local ped = e.ped
	local hp = getElementHealth(ped)
	local expect = e.expected_health or hp
	if hp < expect - 0.5 then
		local scale = (e.hp_max or 100) / 100.0
		Net.event({ type = "ped_damage", id = e.id, amount = (expect - hp) * scale, kind = damage_kind(ped) })
		C.stats.damage_reports = C.stats.damage_reports + 1
		setElementHealth(ped, expect)
		return true
	end
	return false
end

-- a ped the game killed (the onPedWasted handler, or the upkeep noticed): tell the sim once
local function report_death(e, killer)
	if e.dead then return end
	C.stats.deaths_reported = C.stats.deaths_reported + 1
	local x, y, z = getElementPosition(e.ped)
	local cause = C.zombie_near(x, y, z, 4.0) and "zombies" or "killed"
	Net.event({ type = "ped_died", id = e.id, cause = cause })
	e.dead = true
	Peds.corpse(e.ped, 25000)
end

function C.on_wasted(ped, killer)
	local rec = Peds.list[ped]
	if not rec or rec.kind ~= "colonist" then return false end
	local e = C.list[rec.tag]
	if e and e.ped == ped then report_death(e, killer) end
	return true
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
	if not isElement(ped) then e.ped = nil; return end
	if e.dead then return end -- the corpse is destroyed by Peds.sweep after 25 s
	if isPedDead(ped) then report_death(e, nil); return end
	C.report_damage(e)
	-- the sim moved on: arrival + placement
	local task = e.task
	if task and e.dest and not e.arrived and not e.fighting and not e.fleeing then
		local px, py = getElementPosition(ped)
		local d = dist2(px, py, e.dest.x, e.dest.y)
		if d <= 2.2 then
			C.perform(e, task)
		elseif e.walk_started and now - e.walk_started > allowed_ms(d) then
			setElementPosition(ped, e.dest.x, e.dest.y, Ground.z_at(e.dest.x, e.dest.y) + 1.0)
			C.stats.snaps = C.stats.snaps + 1
			C.perform(e, task)
		end
	end
	-- the dead are close: fight when armed or drafted, run when not
	if now - (e.threat_t or 0) > 1500 then
		e.threat_t = now
		local px, py, pz = getElementPosition(ped)
		local zp = C.zombie_near(px, py, pz, e.fighting and 25.0 or 14.0)
		if zp then
			local zx, zy = getElementPosition(zp)
			if e.weapon or e.drafted then
				e.fighting = true
				Peds.drive(ped, { m = "attack", x = zx, y = zy, tgt = zp, ranged = e.weapon ~= nil and config.weapons[e.weapon] ~= nil and config.weapons[e.weapon] >= 16, s = 2, r = 10.0 })
			elseif not e.fleeing or now - (e.flee_t or 0) > 3000 then
				e.fleeing, e.flee_t = true, now
				C.stats.flees = C.stats.flees + 1
				local dx, dy = px - zx, py - zy
				local len = math.max(0.1, math.sqrt(dx * dx + dy * dy))
				Peds.drive(ped, { m = "flee", x = px + dx / len * 30.0, y = py + dy / len * 30.0, s = 3, r = 2.0 })
				e.walk_started = nil
			end
		elseif e.fighting and not e.drafted then
			e.fighting = false
			Peds.drive(ped, { m = "stop" }, true)
			if e.task then C.start_task(e, e.task) end
		elseif e.fleeing and now - (e.flee_t or 0) > 5000 then
			e.fleeing = false
			if e.task then C.start_task(e, e.task) end
		end
	end
end

function C.update()
	local now = getTickCount()
	for _, id in ipairs(C.order) do
		local e = C.list[id]
		if e then C.update_one(e, now) end
	end
	Peds.flush_drive()
end

function C.clear()
	for _, id in ipairs(C.order) do
		local e = C.list[id]
		if e then C.remove_ped(e) end
	end
	C.list, C.order = {}, {}
end

function C.start() ctx.every("colonists.update", cfg.colonist_ms, C.update) end

ctx.on_reset("colonists", C.clear)
ctx.on_cleanup("colonists", C.clear)
return C
