-- server/world.lua : the world around the colony and the owner's own body. The game clock follows the sim clock (setTime / setMinuteDuration, a paused sim stops the sky),
-- weather events set the weather, the survival body (shared/survival.lua) is applied to the owner's ped (health, death), the owner is spawned at the base and respawned after a death,
-- and everything global is put back on stop. MTA has no ambient population to suppress (the FiveM adapter had to switch it off): freeroam-style ambient peds and traffic do not exist
-- unless a resource creates them, so there is nothing to do for the ped pool here.
-- Written here (the FiveM adapter's client/world.lua + survival structure on MTA functions). Nothing borrowed.
local ctx = require("server.ctx")
local Ground = require("server.ground")
local Net = require("server.inject")

local W = { team = nil, saved = nil, weather = nil, dead_since = nil, stats = { spawns = 0, respawns = 0, clock_sets = 0 } }
local config = ctx.config

local PAUSED_MS = 3600000 -- one game minute per real hour: the sky is effectively frozen while the sim is paused

-- ---------------------------------------------------------------------------------------------------------------- clock + weather
function W.capture()
	if W.saved then return end
	local ms = getMinuteDuration()
	W.saved = { minute_ms = (type(ms) == "number" and ms > 0) and ms or 1000, weather = getWeather() }
end

-- the host sends { t, day, hour, minute, scale (sim minutes per real second), speed } about once per second
function W.on_clock(msg)
	if type(msg) ~= "table" then return end
	W.capture()
	local scale = msg.scale or 0.5
	ctx.sim_scale = scale
	local ms = (scale <= 0) and PAUSED_MS or math.max(50, math.floor(1000 / scale))
	if ms ~= W.minute_ms then W.minute_ms = ms; setMinuteDuration(ms) end
	local gh, gm = getTime()
	local diff = math.abs((gh * 60 + gm) - (msg.hour * 60 + msg.minute))
	if diff > 720 then diff = 1440 - diff end
	if diff >= 2 then setTime(msg.hour, msg.minute); W.stats.clock_sets = W.stats.clock_sets + 1 end
end

ctx.on("weather", function(ev)
	local id = config.weather[ev.kind] or config.weather.clear
	if W.weather ~= id then
		W.weather = id
		W.capture()
		setWeatherBlended(id)
	end
end)

-- ---------------------------------------------------------------------------------------------------------------- the owner's body
local function base_xyz()
	local x, y = ctx.to_game(4.0, 0.0, 0.0)
	return x, y, Ground.z_at(x, y) + 1.0
end

function W.spawn_owner(player)
	if not isElement(player) then return false end
	local x, y, z = base_xyz()
	local ok = spawnPlayer(player, x, y, z, 0.0, 26)
	if ok then
		fadeCamera(player, true)
		setCameraTarget(player, player)
		W.stats.spawns = W.stats.spawns + 1
		W.dead_since = nil
	end
	return ok
end

function W.join_team(player)
	if not W.team or not isElement(W.team) then
		W.team = createTeam("Outbreak Colony", 80, 170, 120)
		if W.team then setTeamFriendlyFire(W.team, false) end
	end
	if W.team and isElement(player) then setPlayerTeam(player, W.team) end
end

-- the survival body's effects (shared/survival.lua effects()) arrive with every HUD push: { health 0..1, dead, sprint, limp, bleeding }
function W.apply_fx(fx)
	local o = ctx.owner_el()
	if not o or type(fx) ~= "table" or isPedDead(o) then return end
	if fx.dead then
		killPed(o)
		return
	end
	local h = math.max(1.0, math.min(100.0, (tonumber(fx.health) or 1.0) * 100.0))
	if math.abs(getElementHealth(o) - h) > 1.0 then setElementHealth(o, h) end
end

-- onPlayerWasted (server event; source = the player): tell the sim, then respawn at the base after a pause
function W.on_player_wasted(player, killer)
	if player ~= ctx.owner then return end
	if not W.dead_since then
		W.dead_since = getTickCount()
		Net.event({ type = "ped_died", id = "player", cause = "killed" })
		ctx.after(ctx.scfg.respawn_ms, function()
			if ctx.owner and isElement(ctx.owner) then
				if ctx.host and ctx.host.world then ctx.host:ui_action("player_respawn", {}) end
				W.spawn_owner(ctx.owner)
				W.stats.respawns = W.stats.respawns + 1
			end
		end)
	end
end

function W.cleanup()
	if W.saved then
		setMinuteDuration(W.saved.minute_ms)
		if W.saved.weather then setWeather(W.saved.weather) end
		W.saved, W.minute_ms, W.weather = nil, nil, nil
	end
	if W.team and isElement(W.team) then destroyElement(W.team) end
	W.team = nil
end

ctx.on_cleanup("world", W.cleanup)
return W
