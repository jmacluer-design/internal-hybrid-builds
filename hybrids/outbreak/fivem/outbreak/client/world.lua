-- client/world.lua : the world around the colony. Population / scenario suppression (so the ped pool is ours), outage visuals (blackout),
-- time-of-day sync from the sim clock, weather, alert sounds, and cleanup that puts every global setting back.
--
-- borrowed: squarerootof49/7_popmanager client.lua (GPL-3.0): the scenario type list, the population budgets and dispatch / wanted-level switches, and
--           its restore-on-stop block (the original calls SetPedNonCreationArea/AddScenarioBlockingArea again on stop; we remove what we added instead).
--           Blumlaut/RottenV client/gameplay/nopeds.lua (MIT): the *DensityMultiplierThisFrame(0.0) loop, SetBlackout, scenario groups.
local ctx = require("client.ctx")

local W = { saved = {}, blocking = {}, clock = { t = 0, at = 0, scale = 0.5 }, weather = nil, blackout = false }

-- scenarios that spawn ambient traffic / peds (subset of 7_popmanager's list: the ones that matter for the ped pool)
local SCENARIOS = {
	"DRIVE", "WORLD_VEHICLE_DRIVE_SOLO", "WORLD_VEHICLE_DRIVE_PASSENGERS", "WORLD_VEHICLE_POLICE", "WORLD_VEHICLE_POLICE_CAR", "WORLD_VEHICLE_POLICE_BIKE",
	"WORLD_VEHICLE_BIKER", "WORLD_VEHICLE_EMPTY", "WORLD_VEHICLE_PARK_PARALLEL", "WORLD_VEHICLE_PARK_PERPENDICULAR_NOSE_IN", "WORLD_VEHICLE_SALTON",
	"WORLD_VEHICLE_BUSINESSMEN", "WORLD_VEHICLE_TOURBUS", "WORLD_VEHICLE_STREETRACE", "WORLD_HUMAN_HANG_OUT_STREET", "WORLD_HUMAN_SMOKING", "WORLD_HUMAN_DRINKING",
	"WORLD_HUMAN_GUARD_STAND", "WORLD_HUMAN_LEANING", "WORLD_HUMAN_PAPARAZZI", "WORLD_HUMAN_CLIPBOARD", "WORLD_HUMAN_HIKER", "PROP_HUMAN_SEAT_CHAIR",
}
local WEATHER = { clear = "EXTRASUNNY", rain = "RAIN", storm = "THUNDER" }
local ALERT_SOUNDS = { -- UNVERIFIED sound names (public lists); a wrong name is simply silent
	horde_near = { "CHECKPOINT_MISSED", "HUD_MINI_GAME_SOUNDSET" }, raid_incoming = { "Beep_Red", "DLC_HEIST_HACKING_SNAKE_SOUNDS" },
	caravan = { "PURCHASE", "HUD_LIQUOR_STORE_SOUNDSET" }, helicopter = { "TIMER_STOP", "HUD_MINI_GAME_SOUNDSET" }, supply_drop = { "CONFIRM_BEEP", "HUD_MINI_GAME_SOUNDSET" },
}

-- ---------------------------------------------------------------------------------------------------------------- population
function W.setup_population()
	for i = 1, #SCENARIOS do SetScenarioTypeEnabled(SCENARIOS[i], false) end
	SetPedPopulationBudget(0)
	SetVehiclePopulationBudget(1)
	SetNumberOfParkedVehicles(2)
	SetRandomBoats(false)
	SetRandomTrains(false)
	SetGarbageTrucks(false)
	SetCreateRandomCops(false)
	SetCreateRandomCopsNotOnScenarios(false)
	SetCreateRandomCopsOnScenarios(false)
	for i = 1, 15 do EnableDispatchService(i, false) end
	SetDispatchCopsForPlayer(PlayerId(), false)
	SetMaxWantedLevel(0)
	SetPlayerHealthRechargeMultiplier(PlayerId(), 0.0) -- the survival body owns health (shared/survival.lua)
	W.population_set = true
end

-- every frame: keep ambient peds out of the pool so our own peds fit (RottenV nopeds.lua)
function W.frame()
	SetPedDensityMultiplierThisFrame(0.0)
	SetScenarioPedDensityMultiplierThisFrame(0.0, 0.0)
	SetVehicleDensityMultiplierThisFrame(0.25)
	SetRandomVehicleDensityMultiplierThisFrame(0.25)
	SetParkedVehicleDensityMultiplierThisFrame(0.25)
end

function W.restore_population()
	if not W.population_set then return end
	for i = 1, #SCENARIOS do SetScenarioTypeEnabled(SCENARIOS[i], true) end
	SetPedPopulationBudget(3)
	SetVehiclePopulationBudget(3)
	SetNumberOfParkedVehicles(3)
	SetRandomBoats(true)
	SetRandomTrains(true)
	SetGarbageTrucks(true)
	SetCreateRandomCops(true)
	SetCreateRandomCopsNotOnScenarios(true)
	SetCreateRandomCopsOnScenarios(true)
	for i = 1, 15 do EnableDispatchService(i, true) end
	SetDispatchCopsForPlayer(PlayerId(), true)
	SetMaxWantedLevel(5)
	SetPlayerHealthRechargeMultiplier(PlayerId(), 1.0)
	W.population_set = false
end

-- ---------------------------------------------------------------------------------------------------------------- outage / weather / clock
ctx.on("set_power", function(ev)
	local dark = not ev.on
	if dark ~= W.blackout then W.blackout = dark; SetBlackout(dark) end
	ctx.power_on = ev.on
end)

ctx.on("weather", function(ev)
	local name = WEATHER[ev.kind] or WEATHER.clear
	if W.weather ~= name then
		W.weather = name
		SetWeatherTypeNowPersist(name)
	end
end)

ctx.on("play_alert", function(ev)
	local s = ALERT_SOUNDS[ev.kind]
	if s then PlaySoundFrontend(-1, s[1], s[2], true) end
end)

-- sim clock -> game clock. `scale` = sim minutes per real second (0 when paused); we extrapolate between messages so the sky moves smoothly.
function W.on_clock(msg)
	local c = W.clock
	c.t, c.at, c.scale = msg.t, GetGameTimer(), msg.scale or 0.5
	ctx.sim_scale = c.scale
	if c.scale <= 0 then PauseClock(true) else PauseClock(false); SetMillisecondsPerGameMinute(math.max(100, math.floor(1000 / c.scale))) end
end

function W.apply_clock()
	local c = W.clock
	local t = c.t + (c.scale > 0 and (GetGameTimer() - c.at) / 1000 * c.scale or 0)
	local mod = t % 1440
	NetworkOverrideClockTime(math.floor(mod / 60) % 24, math.floor(mod % 60), math.floor((mod % 1) * 60))
	ctx.sim_t = t
end

function W.start_threads()
	CreateThread(function()
		while ctx.running do
			Wait(0)
			if ctx.owner then W.frame() end
		end
	end)
	CreateThread(function()
		while ctx.running do
			Wait(250)
			if ctx.owner and W.clock.at > 0 then W.apply_clock() end
		end
	end)
end

function W.cleanup()
	W.restore_population()
	if W.blackout then SetBlackout(false); W.blackout = false end
	NetworkClearClockTimeOverride()
	PauseClock(false)
	SetMillisecondsPerGameMinute(2000)
	if W.weather then ClearWeatherTypePersist(); W.weather = nil end
end

ctx.on_cleanup("world", W.cleanup)
return W
