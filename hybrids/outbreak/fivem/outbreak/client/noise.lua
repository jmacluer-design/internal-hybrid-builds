-- client/noise.lua : turns what the player (and armed colonists) do into `noise` IN events (API.md: footsteps 8, melee 20, vehicle 45, gunshot 110,
-- shotgun 140, rifle 150, explosion 200) and makes MATERIALIZED zombies investigate the same sound. Abstract hordes are attracted by the sim.
-- Detection set (brief): gunshots, explosions, sirens / horns, sprinting, melee. Per-kind throttling keeps the event rate low.
-- IsPedShooting is true for a single frame, so it is polled every frame (RottenV / TP-Advanced-Zombies do the same with Wait(0) / Wait(1)).
local ctx = require("client.ctx")
local Zombies = require("client.zombies")

local N = { last = {}, stats = { sent = 0, throttled = 0 } }
local cfg = ctx.cfg
local LOUD = ctx.config.noise

-- weapon group hashes (UNVERIFIED: from public lists; an unknown group falls back to a generic gunshot)
local GROUP = { [416676503] = "gunshot", [-957766203] = "gunshot", [970310034] = "rifle", [1159398588] = "rifle", [860033945] = "shotgun", [-1212426201] = "rifle",
	[-1569042529] = "explosion", [-728555052] = "melee", [-1609580060] = "melee", [1548507267] = "melee" }

function N.emit(kind, x, y, z, loudness, gap)
	local now = GetGameTimer()
	if now - (N.last[kind] or -1e9) < (gap or cfg.noise_min_gap_ms) then N.stats.throttled = N.stats.throttled + 1; return false end
	N.last[kind] = now
	local sx, sy = ctx.to_sim(x, y)
	ctx.send({ type = "noise", pos = { x = sx, y = sy, z = 0.0 }, loudness = loudness, kind = kind })
	N.stats.sent = N.stats.sent + 1
	Zombies.hear(x, y, z, loudness)
	return true
end

local function weapon_noise(ped)
	local _, hash = GetCurrentPedWeapon(ped, true)
	local kind = GROUP[GetWeapontypeGroup(hash)] or "gunshot"
	local loud = LOUD[kind] or LOUD.gunshot
	if IsPedCurrentWeaponSilenced(ped) then loud = loud * LOUD.suppressed_mult end
	return kind, loud
end

-- every frame: only the cheap shot check for the player
function N.poll_frame()
	local ped = PlayerPedId()
	if IsPedShooting(ped) then
		local kind, loud = weapon_noise(ped)
		local p = GetEntityCoords(ped)
		N.emit(kind, p.x, p.y, p.z, loud, 250)
	end
end

-- ~5 Hz: everything else
function N.poll_slow()
	local ped = PlayerPedId()
	local p = GetEntityCoords(ped)
	if IsPedInAnyVehicle(ped, false) then
		local veh = GetVehiclePedIsIn(ped, false)
		if veh ~= 0 then
			if IsVehicleSirenOn(veh) then N.emit("siren", p.x, p.y, p.z, LOUD.siren, 5000) end
			if IsHornActive(veh) then N.emit("horn", p.x, p.y, p.z, LOUD.horn, 1500) end
			if GetEntitySpeed(veh) > 6.0 then N.emit("vehicle", p.x, p.y, p.z, LOUD.vehicle, 3000) end
		end
	else
		if IsPedSprinting(ped) then N.emit("sprint", p.x, p.y, p.z, LOUD.sprint, 2500) end
		if IsPedInMeleeCombat(ped) then N.emit("melee", p.x, p.y, p.z, LOUD.melee, 1200) end
	end
	if IsExplosionInSphere(-1, p.x, p.y, p.z, 150.0) then
		if N.emit("explosion", p.x, p.y, p.z, LOUD.explosion, 1500) then Zombies.blast(p.x, p.y, p.z, 25.0) end
	end
	-- armed colonists shooting also draws the dead (checked at this slower rate: a burst is long enough to catch)
	local cps = ctx.colonist_peds and ctx.colonist_peds() or {}
	for i = 1, #cps do
		if IsPedShooting(cps[i].ped) then
			local cp = GetEntityCoords(cps[i].ped)
			N.emit("colonist_gunshot", cp.x, cp.y, cp.z, LOUD.gunshot, 900)
			break
		end
	end
end

function N.start_threads()
	ctx.loop("noise.frame", 0, N.poll_frame)
	ctx.loop("noise.slow", 200, N.poll_slow)
end

return N
