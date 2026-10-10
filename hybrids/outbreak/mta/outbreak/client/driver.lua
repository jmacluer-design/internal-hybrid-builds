-- client/driver.lua : the ped DRIVER. MTA's server cannot set a ped's control states or aim (setPedControlState / setPedAimTarget are client-only: see tools/function_check.lua),
-- so the server brain (server/zombies.lua, raiders.lua, colonists.lua) sends intents through outbreak:drive and this module, running on the owner's client (the ped's syncer),
-- turns them into control states every cfg.drive_ms: face the target, hold "forwards" (+ "walk" or "sprint"), stop within the stop radius, get unstuck by jumping and side-stepping,
-- and for ranged intents aim and fire in bursts. Collision and line of sight exist only here, which is why the movement belongs to the client.
--
-- intents (validated here, they come over the network): { ped, m = "stop"|"go"|"wander"|"attack"|"aim"|"flee", x, y, s = 0..3, r = stop radius, tgt = element, ranged = bool }
-- borrowed: the technique (face the target with setPedRotation, hold the "forwards" control, sprint / walk modifiers, fire in timed bursts, notice a stuck ped by its distance covered)
--   is read from NullSystemWorks/mtadayz and mta-resources/deadwalkers "slothbot" (client side) which have no usable licence, so NOTHING is copied: this is a fresh implementation.
local ctx = require("client.ctx")
local NET = require("shared.mta_net")
local U = require("shared.util")

local D = { intents = {}, count = 0, stats = { received = 0, rejected = 0, driven = 0, stuck = 0, not_syncer = 0, arrived = 0 } }
local cfg = ctx.cfg

local MODES = { stop = true, go = true, wander = true, attack = true, aim = true, flee = true }
local CONTROLS = { "forwards", "walk", "sprint", "jump", "fire", "aim_weapon", "left", "right" }

local function clear_controls(ped)
	for _, c in ipairs(CONTROLS) do setPedControlState(ped, c, false) end
end
D.clear_controls = clear_controls

-- heading in MTA degrees (0 = north / +y, positive turns left) that faces (dx, dy)
local function heading(dx, dy) return (360 - math.deg(math.atan2(dx, dy))) % 360 end
D.heading = heading

-- speed modes: 1 walk, 2 jog (default forwards), 3 sprint
local function move_controls(ped, s)
	setPedControlState(ped, "forwards", true)
	setPedControlState(ped, "walk", s == 1)
	setPedControlState(ped, "sprint", s >= 3)
end

-- ---------------------------------------------------------------------------------------------------------------- network
function D.on_drive(list)
	if type(list) ~= "table" then return end
	for i = 1, math.min(#list, 60) do
		local it = list[i]
		if type(it) == "table" and isElement(it.ped) and getElementType(it.ped) == "ped" and MODES[it.m] then
			local ok = true
			if it.x ~= nil and not (U.finite(it.x) and U.finite(it.y)) then ok = false end
			if it.tgt ~= nil and not isElement(it.tgt) then ok = false end
			if ok then
				D.stats.received = D.stats.received + 1
				if it.m == "stop" then
					if D.intents[it.ped] then D.intents[it.ped] = nil; D.count = D.count - 1 end
					clear_controls(it.ped)
				else
					if not D.intents[it.ped] then D.count = D.count + 1 end
					D.intents[it.ped] = { m = it.m, x = it.x, y = it.y, s = math.max(0, math.min(3, tonumber(it.s) or 1)), r = tonumber(it.r) or 1.5, tgt = it.tgt, ranged = it.ranged == true,
						t = getTickCount(), wander_until = 0, last_x = nil }
				end
			else
				D.stats.rejected = D.stats.rejected + 1
			end
		else
			D.stats.rejected = D.stats.rejected + 1
		end
	end
end

-- ---------------------------------------------------------------------------------------------------------------- execution
local function finish(ped)
	D.intents[ped] = nil
	D.count = D.count - 1
	clear_controls(ped)
	D.stats.arrived = D.stats.arrived + 1
end

-- notice a ped that is trying to move but is not getting anywhere (a wall, a fence, a prop): jump, then turn aside for a moment
local function unstick(ped, it, px, py, now)
	if not it.chk_t then it.chk_t, it.chk_x, it.chk_y = now, px, py; return end
	if now - it.chk_t < cfg.stuck_ms then return end
	local moved = math.sqrt((px - it.chk_x) ^ 2 + (py - it.chk_y) ^ 2)
	it.chk_t, it.chk_x, it.chk_y = now, px, py
	if moved < 0.35 then
		D.stats.stuck = D.stats.stuck + 1
		it.side_until = now + 700
		it.side_dir = (math.random() < 0.5) and 70.0 or -70.0
		setPedControlState(ped, "jump", true)
		setTimer(function() if isElement(ped) then setPedControlState(ped, "jump", false) end end, 250, 1)
	end
end

local function drive_one(ped, it, now)
	local px, py, pz = getElementPosition(ped)
	local tx, ty = it.x, it.y
	local tz = pz
	if (it.m == "attack" or it.m == "aim") and it.tgt and isElement(it.tgt) then tx, ty, tz = getElementPosition(it.tgt) end
	if it.m == "wander" then
		if now >= it.wander_until then
			it.wander_until = now + math.random(3000, 8000)
			it.wander_h = math.random() * 360.0
			it.wander_pause = math.random() < 0.25
		end
		if it.wander_pause then clear_controls(ped) else setPedRotation(ped, it.wander_h); move_controls(ped, 1) end
		return
	end
	if not tx then return finish(ped) end
	local dx, dy = tx - px, ty - py
	local d = math.sqrt(dx * dx + dy * dy)
	if it.m == "aim" then
		setPedRotation(ped, heading(dx, dy)); setPedAimTarget(ped, tx, ty, tz); setPedControlState(ped, "aim_weapon", true)
		return
	end
	if it.m == "go" or it.m == "flee" then
		if d <= it.r then return finish(ped) end
	end
	local h = heading(dx, dy)
	if it.side_until and now < it.side_until then h = (h + it.side_dir) % 360 end
	setPedRotation(ped, h)
	if it.m == "attack" then
		if it.ranged then
			setPedAimTarget(ped, tx, ty, tz + 0.3)
			setPedControlState(ped, "aim_weapon", true)
			if d <= it.r + 25.0 then
				-- bursts: 700 ms firing, 700 ms pause
				setPedControlState(ped, "fire", (math.floor(now / 700) % 2) == 0)
			end
			if d > it.r then move_controls(ped, it.s) else setPedControlState(ped, "forwards", false); setPedControlState(ped, "sprint", false) end
		else
			if d > it.r then move_controls(ped, it.s) else setPedControlState(ped, "forwards", false) end
		end
	else
		move_controls(ped, it.s)
	end
	if d > it.r + 1.0 then unstick(ped, it, px, py, now) end
end

function D.step()
	local now = getTickCount()
	local gone = {}
	for ped, it in pairs(D.intents) do
		if not isElement(ped) or isPedDead(ped) then
			gone[#gone + 1] = ped
		elseif isElementStreamedIn(ped) then
			if isElementSyncer(ped) then
				D.stats.driven = D.stats.driven + 1
				drive_one(ped, it, now)
			else
				D.stats.not_syncer = D.stats.not_syncer + 1 -- control states of a ped we do not sync would only act locally
			end
		end
	end
	for _, ped in ipairs(gone) do D.intents[ped] = nil; D.count = D.count - 1 end
end

function D.clear()
	for ped in pairs(D.intents) do if isElement(ped) then clear_controls(ped) end end
	D.intents, D.count = {}, 0
end

function D.start()
	addEvent(NET.drive, true)
	addEventHandler(NET.drive, resourceRoot, function(list) if source == resourceRoot then D.on_drive(list) end end)
	ctx.loop("driver", cfg.drive_ms, D.step)
end

ctx.on_reset("driver", D.clear)
ctx.on_cleanup("driver", D.clear)
return D
