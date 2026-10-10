-- client/driver.lua : the ped DRIVER. MTA's server cannot set a ped's control states or aim (setPedControlState / setPedAimTarget are client-only: see tools/function_check.lua),
-- so the server brain (server/zombies.lua, raiders.lua, colonists.lua) sends intents through outbreak:drive and this module, running on the owner's client, turns them into control
-- states every cfg.drive_ms. The movement, chase, stuck, melee-swing and shooting rules are the PROVEN ones of the "slothbot" zombie system that the MTA DayZ gamemodes ran on public
-- servers (client half: sbclient.lua; its server half, which decides when to move, lives in server/zombies.lua here). Our glue: intents instead of element-data status strings, one
-- step loop instead of one timer chain per ped, no path nodes, no second client (the owner is the only client, so the "broadcast the control event to everybody" detour is dropped).
--
-- WARNING: the blocks marked BORROWED-PRIVATE come from repositories WITHOUT a licence. Private use only: never share or redistribute this resource with them in it
-- (mta/tools/list_private_blocks.sh lists them and says how to strip them; mta/THIRD_PARTY.md has one row per block).
--
-- intents (validated here, they come over the network): { ped, m = "stop"|"go"|"wander"|"attack"|"aim"|"flee", x, y, s = 0..3, r = stop radius, tgt = element, ranged = bool }
--   attack + tgt  = chase an element (zombies, raiders, colonists): face it while it is in sight, else its last seen spot; melee swings or ranged bursts when in reach
--   go / flee     = walk to x, y and stop within r        wander = random headings with pauses        aim = hold an aim target        stop = release every control
local ctx = require("client.ctx")
local NET = require("shared.mta_net")
local U = require("shared.util")

local D = {
	intents = {}, count = 0,
	stats = { received = 0, rejected = 0, driven = 0, stuck = 0, arrived = 0, swings = 0, shots = 0, gave_up = 0, los_blocked = 0, hits_reported = 0, stream_in = 0, jumps = 0 },
}
local cfg = ctx.cfg

local MODES = { stop = true, go = true, wander = true, attack = true, aim = true, flee = true }
local CONTROLS = { "forwards", "walk", "sprint", "jump", "fire", "aim_weapon", "left", "right" }
local floor, sqrt, abs = math.floor, math.sqrt, math.abs

-- ---------------------------------------------------------------------------------------------------------------- control-state cache
-- the cache of the control states and rotation we last set per ped: setPedControlState is only called when a state CHANGES (or every REFRESH_MS to heal a state the engine reset, e.g.
-- after a stream-out / stream-in). Without it the loop is ~5000 calls per second with 60 zombies for nothing: the states persist in the engine until they are changed.
-- borrowed (pattern, see THIRD_PARTY.md): multitheftauto/mtasa-resources [gamemodes]/[race]/[addons]/race_ghost/playback_client.lua (MIT): a CLIENT script sets control states on a ped the
-- server created and clears every control name when it resets; clear_controls() is the same idea over our own control list, written here.
local cache = setmetatable({}, { __mode = "k" })
local REFRESH_MS = 1500
local stepping_now = nil -- the tick of the step in progress (one getTickCount per step, not one per call)
local function tick() return stepping_now or getTickCount() end

local function ped_cache(ped)
	local c = cache[ped]
	if not c then c = { ctl = {}, ctl_at = {}, rot = nil, rot_at = -1e9 }; cache[ped] = c end
	return c
end

local function set(ped, control, state)
	local c = ped_cache(ped)
	local now = tick()
	if c.ctl[control] == state and now - (c.ctl_at[control] or -1e9) < REFRESH_MS then return end
	c.ctl[control] = state
	c.ctl_at[control] = now
	setPedControlState(ped, control, state)
end

local function rotate(ped, h, force)
	local c = ped_cache(ped)
	local now = tick()
	if not force and c.rot and abs(((h - c.rot) + 180) % 360 - 180) < 2.0 and now - c.rot_at < 500 then return end
	c.rot, c.rot_at = h, now
	setPedRotation(ped, h)
end

local function clear_controls(ped)
	local c = cache[ped]
	for _, control in ipairs(CONTROLS) do
		if not c or c.ctl[control] ~= false then
			if c then c.ctl[control] = false; c.ctl_at[control] = tick() end
			setPedControlState(ped, control, false)
		end
	end
end
D.clear_controls = clear_controls

-- heading in MTA degrees (0 = north / +y, positive turns left) that faces (dx, dy)
-- BORROWED-PRIVATE (unlicensed upstream, private use only): NullSystemWorks/mtadayz/slothbot/sbclient.lua (the angle formula of chase_move / hunt_move)
local function heading(dx, dy) return (360 - math.deg(math.atan2(dx, dy))) % 360 end
-- END BORROWED-PRIVATE
D.heading = heading

-- speed modes: 1 walk, 2 jog (default forwards), 3 sprint
-- BORROWED-PRIVATE (unlicensed upstream, private use only): NullSystemWorks/mtadayz/slothbot/sbclient.lua (Bforward / Bstop: "forwards" plus the sprint control; walk is ours)
local function move_controls(ped, s)
	set(ped, "forwards", true)
	set(ped, "walk", s == 1)
	set(ped, "sprint", s >= 3)
end
local function stop_moving(ped)
	set(ped, "forwards", false)
	set(ped, "sprint", false)
end
-- END BORROWED-PRIVATE

-- ---------------------------------------------------------------------------------------------------------------- the slothbot rules (data and decisions)
-- line of sight with the flags slothbot uses: buildings and objects block, vehicles / players / dummies do not, from 0.6 above each position
-- BORROWED-PRIVATE (unlicensed upstream, private use only): NullSystemWorks/mtadayz/slothbot/sbclient.lua (chase_move: isLineOfSightClear (px, py, pz+.6, tx, ty, tz+.6, true, false, false, true, false, false, false))
local function in_sight(px, py, pz, tx, ty, tz)
	return isLineOfSightClear(px, py, pz + 0.6, tx, ty, tz + 0.6, true, false, false, true, false, false, false) and true or false
end
-- END BORROWED-PRIVATE

-- how close a ped with a weapon of this SLOT walks before it stands still and shoots (slots: 2 pistol, 3 shotgun, 4 submachine, 5 assault, 6 rifle, 7 heavy, 9 special)
-- BORROWED-PRIVATE (unlicensed upstream, private use only): NullSystemWorks/mtadayz/slothbot/sbserver.lua (chase_move: the tdist < N checks per getPedWeaponSlot, the target-is-a-player branch)
local STOP_BY_SLOT = { [2] = 14, [3] = 10, [4] = 7, [5] = 14, [6] = 22, [7] = 12, [9] = 2 }
-- END BORROWED-PRIVATE
D.STOP_BY_SLOT = STOP_BY_SLOT

-- shooting profile per weapon id: engage within `range`, fire for len_min..len_max ms, then wait: `gap` ms after the burst, or `cycle` ms (absolute) after the burst started
-- BORROWED-PRIVATE (unlicensed upstream, private use only): NullSystemWorks/mtadayz/slothbot/sbclient.lua (chase_shoot: the per-weapon distance, burst length and re-check timers)
local WEAPONS = {
	[22] = { range = 35, len_min = 2100, len_max = 5500, gap = 500 },  -- pistol
	[23] = { range = 35, len_min = 2000, len_max = 5500, gap = 400 },  -- silenced pistol
	[24] = { range = 35, len_min = 2000, len_max = 5500, gap = 400 },  -- desert eagle
	[25] = { range = 27, len_min = 300, len_max = 300, cycle = 1400 }, -- shotgun
	[26] = { range = 20, len_min = 1200, len_max = 1200, cycle = 800 },
	[27] = { range = 25, len_min = 1200, len_max = 1200, cycle = 1800 },
	[28] = { range = 40, len_min = 2100, len_max = 5500, gap = 500 },  -- uzi
	[29] = { range = 55, len_min = 2000, len_max = 5500, gap = 1500 }, -- mp5
	[30] = { range = 60, len_min = 2000, len_max = 5500, gap = 1500 }, -- ak-47
	[31] = { range = 60, len_min = 700, len_max = 700, cycle = 1200 }, -- m4
	[32] = { range = 30, len_min = 2000, len_max = 5500, gap = 600 },  -- tec-9
	[33] = { range = 75, len_min = 400, len_max = 400, cycle = 1600 }, -- country rifle
	[34] = { range = 75, len_min = 400, len_max = 400, cycle = 2000 }, -- sniper
	[37] = { range = 15, len_min = 2000, len_max = 5500, gap = 900 },  -- flamethrower
	[38] = { range = 65, len_min = 2000, len_max = 5500, gap = 900 },  -- minigun
}
-- END BORROWED-PRIVATE
D.WEAPONS = WEAPONS
local SHOT_RECHECK_MS = 1500 -- chase_shoot looks again after this long when it did not fire

-- the melee swing: fire on / off in three jabs while the ped stands still, then it walks on; the next swing starts 2300 ms after the first
-- BORROWED-PRIVATE (unlicensed upstream, private use only): NullSystemWorks/mtadayz/slothbot/sbclient.lua (meleeShoot: fire true at 0, false at 300, true at 800, false at 1100, true at 1400, false at 1700, forwards again at 2000; chase_shoot re-checks after 2300)
local SWING = { jabs = { { 0, 300 }, { 800, 1100 }, { 1400, 1700 } }, hold_ms = 2000, cycle_ms = 2300, reach = 2.0 }
function D.swing_state(elapsed)
	local fire = false
	for _, j in ipairs(SWING.jabs) do if elapsed >= j[1] and elapsed < j[2] then fire = true end end
	return fire, elapsed < SWING.hold_ms
end
-- END BORROWED-PRIVATE
D.SWING = SWING

-- what a stuck ped does (it moved less than a metre since the last check while it should be walking): chasing a target it can SEE it only jumps; otherwise it rolls a die
-- BORROWED-PRIVATE (unlicensed upstream, private use only): NullSystemWorks/mtadayz/slothbot/sbserver.lua (chase_move / hunt_move: math.random(1, 7) or (1, 13): give up / jump / turn to a random angle and walk on 1.2 s)
function D.stuck_decision(visible_chase, roll_max)
	if visible_chase then return "jump" end
	local roll_max_n = roll_max or 7
	local decide = math.random(1, roll_max_n)
	if decide == 1 then return "give_up" end
	if decide < (roll_max_n == 13 and 7 or 4) then return "jump" end
	return "turn"
end
-- END BORROWED-PRIVATE

-- a jump with a melee (slot 1) or heavy (slot 7) weapon in hand does not work, so slothbot swaps to fists for 850 ms around it
-- BORROWED-PRIVATE (unlicensed upstream, private use only): NullSystemWorks/mtadayz/slothbot/sbserver.lua (chase_move: setPedWeaponSlot(ped, 0); bot_Jump; setTimer(setPedWeaponSlot, 850, ...))
local function jump(ped, it, now)
	local slot = getPedWeaponSlot(ped)
	if (slot == 1 or slot == 7) and not it.restore_slot then
		setPedWeaponSlot(ped, 0)
		it.restore_slot, it.restore_at = slot, now + 850
	end
	set(ped, "jump", true)
	it.jump_until = now + 800 -- bot_Jump releases the control after 800 ms
	D.stats.jumps = D.stats.jumps + 1
end
-- END BORROWED-PRIVATE

local function release_timers(ped, it, now, all)
	if it.jump_until and (all or now >= it.jump_until) then it.jump_until = nil; set(ped, "jump", false) end
	if it.restore_at and (all or now >= it.restore_at) then
		local slot = it.restore_slot
		it.restore_slot, it.restore_at = nil, nil
		if slot then setPedWeaponSlot(ped, slot) end
	end
end

-- ---------------------------------------------------------------------------------------------------------------- network
local function valid(it)
	if type(it) ~= "table" or not isElement(it.ped) or getElementType(it.ped) ~= "ped" or not MODES[it.m] then return false end
	if it.x ~= nil and not (U.finite(it.x) and U.finite(it.y)) then return false end
	if it.tgt ~= nil and not isElement(it.tgt) then return false end
	return true
end

local function release(ped, it)
	if it then release_timers(ped, it, 0, true) end
	if isElement(ped) then clear_controls(ped) end
end

function D.on_drive(list)
	stepping_now = nil -- (a step that raised would have left its tick behind)
	if type(list) ~= "table" then return end
	local now = getTickCount()
	for i = 1, math.min(#list, 60) do
		local p = list[i]
		if valid(p) then
			D.stats.received = D.stats.received + 1
			local ped, old = p.ped, D.intents[p.ped]
			if p.m == "stop" then
				if old then D.intents[ped] = nil; D.count = D.count - 1 end
				release(ped, old)
			else
				local s = math.max(0, math.min(3, tonumber(p.s) or 1))
				local r = tonumber(p.r) or 1.5
				if old and old.m == p.m and old.tgt == p.tgt then
					-- the same order again (the server refreshes the target position every second): keep the running state (swing, last seen spot, stuck timer), take the new numbers
					if not (old.x and p.x) or abs(old.x - p.x) > 1.5 or abs(old.y - p.y) > 1.5 then old.next_turn = 0 end -- a new destination: face it now, not after the 700 ms turn timer
					old.x, old.y, old.s, old.r, old.ranged = p.x, p.y, s, r, p.ranged == true
				else
					if old then release_timers(ped, old, 0, true); set(ped, "fire", false) else D.count = D.count + 1 end
					D.intents[ped] = { m = p.m, x = p.x, y = p.y, s = s, r = r, tgt = p.tgt, ranged = p.ranged == true, t = now, next_turn = 0, hold_until = 0, wander_until = 0 }
				end
			end
		else
			D.stats.rejected = D.stats.rejected + 1
		end
	end
end

-- ---------------------------------------------------------------------------------------------------------------- execution
local function finish(ped, why)
	local it = D.intents[ped]
	D.intents[ped] = nil
	D.count = D.count - 1
	release(ped, it)
	if why == "gave_up" then D.stats.gave_up = D.stats.gave_up + 1 else D.stats.arrived = D.stats.arrived + 1 end
end

-- a ped that is trying to move but is not getting anywhere (a wall, a fence, a prop). Returns true when it gave up (the intent is gone)
local function stuck_check(ped, it, px, py, now, visible_chase, roll_max)
	if not it.chk_t then it.chk_t, it.chk_x, it.chk_y = now, px, py; return false end
	if now - it.chk_t < cfg.stuck_ms then return false end
	local moved = sqrt((px - it.chk_x) ^ 2 + (py - it.chk_y) ^ 2)
	it.chk_t, it.chk_x, it.chk_y = now, px, py
	-- slothbot's limits (1 m in a check, 1.2 m when the target is out of sight) are for jogging zombies; a ped that walks (speed 1) covers a third of that in the same time
	local limit = visible_chase and 1.0 or 1.2
	if it.s == 1 then limit = limit * 0.35 end
	if moved >= limit then return false end
	D.stats.stuck = D.stats.stuck + 1
	local what = D.stuck_decision(visible_chase, roll_max)
	if what == "give_up" then finish(ped, "gave_up"); return true end
	if what == "jump" then jump(ped, it, now)
	else
		rotate(ped, math.random(1, 360), true)
		it.hold_until = now + 1200 -- walk a bit in that direction before aiming at the target again
	end
	return false
end

-- weapons: one burst at a time, then a pause that depends on the weapon (sbclient.lua chase_shoot)
local function ranged_fire(ped, it, now, visible, d)
	if it.fire_until then
		if now < it.fire_until then set(ped, "fire", true); return end
		it.fire_until = nil
		set(ped, "fire", false)
	end
	if now < (it.next_shot or 0) then return end
	it.next_shot = now + SHOT_RECHECK_MS
	local prof = WEAPONS[getPedWeapon(ped)]
	if not visible or not prof or d >= prof.range then return end
	local len = (prof.len_min == prof.len_max) and prof.len_min or math.random(prof.len_min, prof.len_max)
	set(ped, "fire", true)
	it.fire_until = now + len
	it.next_shot = now + (prof.cycle or (len + prof.gap))
	D.stats.shots = D.stats.shots + 1
end

local function dist3(ax, ay, az, bx, by, bz)
	local dx, dy, dz = ax - bx, ay - by, az - bz
	return sqrt(dx * dx + dy * dy + dz * dz)
end

local function drive_one(ped, it, now)
	release_timers(ped, it, now, false)
	local px, py, pz = getElementPosition(ped)
	if it.m == "wander" then
		-- DayZ zombies standing about pick a random heading now and then (movement_zombies.lua zombieMovement); ours also shuffle along and pause
		if now >= it.wander_until then
			it.wander_until = now + math.random(3000, 8000)
			it.wander_h = math.random(1, 359)
			it.wander_pause = math.random() < 0.25
		end
		if it.wander_pause then clear_controls(ped) else rotate(ped, it.wander_h); move_controls(ped, 1) end
		return
	end

	-- where is the target, and can the ped see it? (an element target: the real position while in sight, else the last spot it was seen at; a point: the point)
	local tx, ty, tz = it.x, it.y, pz
	local visible = true
	local tgt = it.tgt
	if tgt ~= nil then
		if not isElement(tgt) or isPedDead(tgt) then return finish(ped) end
		local gx, gy, gz = getElementPosition(tgt)
		if now >= (it.vis_t or 0) then
			it.vis = in_sight(px, py, pz, gx, gy, gz)
			it.vis_t = now + 350
			if not it.vis then D.stats.los_blocked = D.stats.los_blocked + 1 end
		end
		visible = it.vis
		if visible then
			it.seen = { x = gx, y = gy, z = gz, ducked = (isPedDucked(tgt) and true or false) }
			tx, ty, tz = gx, gy, gz
		elseif it.seen then
			tx, ty, tz = it.seen.x, it.seen.y, it.seen.z
		else
			tx, ty, tz = it.x or gx, it.y or gy, gz
		end
	end
	if not tx then return finish(ped) end
	local dx, dy = tx - px, ty - py
	local d = dist3(px, py, pz, tx, ty, tz)

	if it.m == "aim" then
		if visible then rotate(ped, heading(dx, dy)); setPedAimTarget(ped, tx, ty, (it.seen and it.seen.ducked) and tz - 0.5 or tz) end
		return
	end

	if (it.m == "go" or it.m == "flee") and d <= it.r then return finish(ped) end
	if it.m == "attack" and tgt ~= nil and not visible and it.seen and d <= 5.0 then return finish(ped, "gave_up") end -- reached the last seen spot and nobody is there: stop chasing

	-- face the target every turn_ms (slothbot re-aims every 700 ms), unless a random turn after a stuck moment is still being walked off
	if now >= it.next_turn and now >= it.hold_until then
		rotate(ped, heading(dx, dy))
		it.next_turn = now + cfg.turn_ms
	end

	local in_range = false
	if it.m == "attack" then
		if it.ranged then
			if visible then setPedAimTarget(ped, tx, ty, (it.seen and it.seen.ducked) and tz - 0.5 or tz) end
			local stop = STOP_BY_SLOT[getPedWeaponSlot(ped)] or it.r
			if visible and d < stop then stop_moving(ped); in_range = true else move_controls(ped, it.s) end
			ranged_fire(ped, it, now, visible, d)
		else
			-- melee: keep pushing on; within reach start a swing (the ped stands still while it jabs)
			if visible and d < SWING.reach and not it.swing_t then it.swing_t = now; D.stats.swings = D.stats.swings + 1 end
			if it.swing_t then
				local elapsed = now - it.swing_t
				local fire, hold = D.swing_state(elapsed)
				set(ped, "fire", fire)
				if hold then stop_moving(ped); in_range = true else move_controls(ped, it.s) end
				if elapsed >= SWING.cycle_ms then it.swing_t = nil; set(ped, "fire", false) end
			else
				move_controls(ped, it.s)
				in_range = visible and d < SWING.reach
			end
		end
	else
		move_controls(ped, it.s)
	end
	if not in_range then
		stuck_check(ped, it, px, py, now, it.m == "attack" and visible, it.m == "attack" and 7 or 13)
	else
		it.chk_t = nil
	end
end

function D.step()
	local now = getTickCount()
	stepping_now = now
	local gone = {}
	for ped, it in pairs(D.intents) do
		if not isElement(ped) or isPedDead(ped) then
			gone[#gone + 1] = ped
		elseif isElementStreamedIn(ped) then
			D.stats.driven = D.stats.driven + 1
			drive_one(ped, it, now)
		end
	end
	stepping_now = nil
	for _, ped in ipairs(gone) do D.intents[ped] = nil; D.count = D.count - 1 end
end

function D.clear()
	for ped, it in pairs(D.intents) do release(ped, it) end
	D.intents, D.count = {}, 0
	cache = setmetatable({}, { __mode = "k" })
end

-- ---------------------------------------------------------------------------------------------------------------- engine events: stream-in, damage
local function ob_kind(el)
	if not isElement(el) then return nil end
	local v = getElementData(el, "ob")
	return type(v) == "string" and v or nil
end
D.ob_kind = ob_kind

-- a ped of ours was streamed in: its control states from before are gone (the engine rebuilt it), it must not talk, and its weapon needs giving again by the server
-- BORROWED-PRIVATE (unlicensed upstream, private use only): NullSystemWorks/mtadayz/slothbot/sbclient.lua (Streamin: "unstreamed peds lose all but 1 bullet" -> ask the server for the weapon again; setPedVoice(source, "PED_TYPE_DISABLED", ""))
function D.on_stream_in()
	local ped = source
	if not isElement(ped) or getElementType(ped) ~= "ped" or not ob_kind(ped) then return end
	D.stats.stream_in = D.stats.stream_in + 1
	cache[ped] = nil
	setPedVoice(ped, "PED_TYPE_DISABLED", "")
	if getElementData(ped, "obw") then triggerServerEvent(NET.stream, resourceRoot, ped) end
end
-- END BORROWED-PRIVATE

-- damage between our peds is scripted by the server (the sim is authoritative), so the engine's own damage from a zombie's fists is cancelled; a zombie the PLAYER hits turns on the player
-- BORROWED-PRIVATE (unlicensed upstream, private use only): NullSystemWorks/mtadayz/slothbot/sbclient.lua (aidamage: when the ped gets hit, switch its target to the shooter; the cancelEvent() of friendly fire)
local hit_sent = setmetatable({}, { __mode = "k" })
function D.on_ped_damage(attacker)
	local ped = source
	local kind = ob_kind(ped)
	if not kind then return end
	if isElement(attacker) and ob_kind(attacker) == "zombie" then cancelEvent(); return end
	if kind == "zombie" and attacker == localPlayer then
		local now = getTickCount()
		if now - (hit_sent[ped] or -1e9) >= 1000 then
			hit_sent[ped] = now
			D.stats.hits_reported = D.stats.hits_reported + 1
			triggerServerEvent(NET.hit, resourceRoot, ped)
		end
	end
end
-- END BORROWED-PRIVATE

function D.start()
	addEvent(NET.drive, true)
	addEventHandler(NET.drive, resourceRoot, function(list) if source == resourceRoot then D.on_drive(list) end end)
	addEventHandler("onClientElementStreamIn", root, D.on_stream_in)
	addEventHandler("onClientPedDamage", root, D.on_ped_damage)
	ctx.on_cleanup("driver events", function()
		removeEventHandler("onClientElementStreamIn", root, D.on_stream_in)
		removeEventHandler("onClientPedDamage", root, D.on_ped_damage)
	end)
	ctx.loop("driver", cfg.drive_ms, D.step)
end

ctx.on_reset("driver", D.clear)
ctx.on_cleanup("driver", D.clear)
return D
