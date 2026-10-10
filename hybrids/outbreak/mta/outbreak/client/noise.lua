-- client/noise.lua : turns what the player (and armed peds) do into `noise` IN events (API.md: footsteps 8, melee 20, vehicle 45, gunshot 110, shotgun 140, rifle 150, explosion 200).
-- The sim attracts abstract hordes with them; the server also sends materialized zombies to the same spot (server/net.lua -> server/zombies.lua hear).
-- Detection set (brief): gunshots (onClientPlayerWeaponFire), explosions (onClientExplosion), vehicle sirens / horns / speed, sprinting, melee, and shots fired by other peds
-- (colonists, raiders: onClientPedWeaponFire). Per-kind throttling keeps the event rate low. MTA weapon ids classify the shot (shared/mta_config.lua weapon_noise).
-- Written here (the FiveM adapter's client/noise.lua structure on MTA events; the weapon-id table is the SA weapon list). Nothing borrowed.
local ctx = require("client.ctx")

local N = { last = {}, stats = { sent = 0, throttled = 0 } }
local cfg = ctx.cfg
local LOUD = ctx.config.noise

function N.emit(kind, x, y, loudness, gap)
	local now = getTickCount()
	if now - (N.last[kind] or -1e9) < (gap or cfg.noise_min_gap_ms) then N.stats.throttled = N.stats.throttled + 1; return false end
	N.last[kind] = now
	local sx, sy = ctx.to_sim(x, y)
	ctx.send({ type = "noise", pos = { x = sx, y = sy, z = 0.0 }, loudness = loudness, kind = kind })
	N.stats.sent = N.stats.sent + 1
	return true
end

-- what a weapon id sounds like: kind, loudness
local function weapon_noise(weapon)
	local kind = ctx.config.weapon_noise[weapon] or "gunshot"
	local loud = LOUD[kind] or LOUD.gunshot
	if ctx.config.silenced[weapon] then loud = loud * LOUD.suppressed_mult end
	return kind, loud
end
N.weapon_noise = weapon_noise

-- the local player (and every other player) fires: source = the shooter
function N.on_player_fire(weapon)
	if source ~= localPlayer then return end
	local kind, loud = weapon_noise(weapon)
	local x, y = getElementPosition(localPlayer)
	N.emit(kind, x, y, loud, 250)
end

-- peds that shoot (colonists defending the base, raiders attacking it) are loud too, at their own position
function N.on_ped_fire(weapon)
	local ped = source
	if not isElement(ped) then return end
	local kind, loud = weapon_noise(weapon)
	local x, y = getElementPosition(ped)
	N.emit("ped_" .. kind, x, y, loud, 900)
end

function N.on_explosion(x, y, z)
	N.emit("explosion", x, y, LOUD.explosion, 1500)
end

-- ~5 Hz: everything that is a state rather than an event
function N.poll_slow()
	local x, y = getElementPosition(localPlayer)
	if isPedInVehicle(localPlayer) then
		local veh = getPedOccupiedVehicle(localPlayer)
		if veh then
			if getVehicleSirensOn(veh) then N.emit("siren", x, y, LOUD.siren, 5000) end
			if getControlState("horn") then N.emit("horn", x, y, LOUD.horn, 1500) end
			local vx, vy, vz = getElementVelocity(veh)
			if math.sqrt(vx * vx + vy * vy + vz * vz) * 50.0 > 6.0 then N.emit("vehicle", x, y, LOUD.vehicle, 3000) end -- 1 velocity unit = 50 m/s
		end
	else
		if getPedMoveState(localPlayer) == "sprint" then N.emit("sprint", x, y, LOUD.sprint, 2500) end
		if getPedWeaponSlot(localPlayer) <= 1 and getControlState("fire") then N.emit("melee", x, y, LOUD.melee, 1200) end
	end
end

function N.start()
	addEventHandler("onClientPlayerWeaponFire", root, N.on_player_fire)
	addEventHandler("onClientPedWeaponFire", root, N.on_ped_fire)
	addEventHandler("onClientExplosion", root, N.on_explosion)
	ctx.loop("noise.slow", 200, N.poll_slow)
end

return N
