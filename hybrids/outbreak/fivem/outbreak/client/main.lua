-- client/main.lua : wires the client modules together. Network events from the server -> modules + NUI; flush thread for IN events; key mappings; cleanup on
-- resource stop (every module registered a cleanup with client/ctx.lua, so nothing leaks: peds, props, blips, cameras, relationship groups, population settings,
-- clock / weather overrides, NUI focus). Everything game-facing here was written blind against docs and is tested against mocks only (see README).
local ctx = require("client.ctx")
local P = require("shared.protocol")
local Config = require("shared.config")

local Pool = require("client.pool")
local Relations = require("client.relations")
local Zombies = require("client.zombies")
local Raiders = require("client.raiders")
local Colonists = require("client.colonists")
local Noise = require("client.noise")
local Camera = require("client.camera")
local Build = require("client.build")
local Props = require("client.props")
local World = require("client.world")
local Nui = require("client.nui")
local Survival = require("client.survival")

local M = { started = false, mode = "survival", seq = 0 }

-- ---------------------------------------------------------------------------------------------------------------- mode
function M.set_mode(mode)
	mode = (mode == "colony") and "colony" or "survival"
	if not ctx.owner then return end
	if mode == M.mode then Nui.send("mode", { mode = mode }); return end
	M.mode = mode
	if mode == "colony" then Camera.enter() else Camera.leave(); Build.cancel_placing() end
	Nui.update_focus()
	Nui.send("mode", { mode = mode })
end

-- ---------------------------------------------------------------------------------------------------------------- startup (after the server says hello)
local function start(msg)
	if msg.origin then ctx.origin = { x = msg.origin.x, y = msg.origin.y, z = msg.origin.z } end
	if type(msg.client) == "table" then
		for k, v in pairs(msg.client) do if ctx.cfg[k] ~= nil and type(v) == type(ctx.cfg[k]) then ctx.cfg[k] = v end end
	end
	ctx.owner = msg.owner == true
	if not ctx.owner then return end
	Relations.setup()
	World.setup_population()
	if not M.started then
		M.started = true
		Zombies.start_threads(); Raiders.start_threads(); Colonists.start_threads(); Noise.start_threads(); Camera.start_threads()
		Build.start_threads(Camera); World.start_threads(); Survival.start_threads()
		ctx.loop("flush", 250, ctx.flush) -- IN event flush (one network message per tick, never per event)
		ctx.loop("compass", 100, function() -- compass heading for the HUD
			local yaw
			if ctx.colony_mode then yaw = Camera.yaw else yaw = GetGameplayCamRot(2).z end
			Nui.send("compass", { heading = (-yaw) % 360.0 })
		end)
	end
end

-- ---------------------------------------------------------------------------------------------------------------- network events
local function on_hello(msg) if type(msg) == "table" then start(msg) end end

local function on_events(msg)
	if not ctx.running or type(msg) ~= "table" or type(msg.events) ~= "table" then return end
	ctx.stats.events_in = ctx.stats.events_in + #msg.events
	if msg.reset then ctx.reset_all() end
	for i = 1, #msg.events do ctx.dispatch(msg.events[i]) end
	Nui.send("events", msg.events)
end

local function on_state(msg)
	if type(msg) ~= "table" then return end
	ctx.state = msg
	Props.sync_piles(msg.piles)
	Nui.send("state", msg)
end

local function on_hud(msg)
	if type(msg) ~= "table" then return end
	ctx.hud = msg
	Nui.send("hud", msg)
	Survival.apply_fx(msg.fx)
end

RegisterNetEvent(P.NET.hello, on_hello)
RegisterNetEvent(P.NET.events, on_events)
RegisterNetEvent(P.NET.state, on_state)
RegisterNetEvent(P.NET.hud, on_hud)
RegisterNetEvent(P.NET.clock, function(msg) if type(msg) == "table" then World.on_clock(msg) end end)
RegisterNetEvent(P.NET.catalog, function(msg) if type(msg) == "table" then ctx.catalog = msg; Nui.send("catalog", msg) end end)
RegisterNetEvent(P.NET.ui, function(msg)
	if type(msg) == "table" and type(msg.name) == "string" then Nui.send(msg.name, msg.data) end
end)

-- ---------------------------------------------------------------------------------------------------------------- NUI wiring, keys, commands
Nui.register({ set_mode = M.set_mode, camera = Camera, build = Build })

RegisterCommand("outbreak_colony", function() M.set_mode(M.mode == "colony" and "survival" or "colony") end, false)
RegisterKeyMapping("outbreak_colony", "Outbreak: colony view", "keyboard", ctx.cfg.colony_key)
RegisterCommand("outbreak_inventory", function() if ctx.owner then Nui.send("screen", { name = "inventory" }) end end, false)
RegisterKeyMapping("outbreak_inventory", "Outbreak: inventory", "keyboard", ctx.cfg.inventory_key)
RegisterCommand("outbreak_interact", function() if ctx.owner then Props.interact() end end, false)
RegisterKeyMapping("outbreak_interact", "Outbreak: open nearby pile", "keyboard", "E")

RegisterCommand("outbreak_client", function()
	local c = Pool.counts()
	print(string.format("[outbreak] client: peds %d/%d objects %d/%d zombies %d (pending %d) raiders %d colonists %d | refused cap %d pool %d | events in %d out %d",
		c.peds, ctx.cfg.max_peds, c.objects, ctx.cfg.max_objects, Zombies.alive_total(), Zombies.pending_total(), Raiders.alive_total(), Colonists.count(),
		c.stats.refused_cap, c.stats.refused_pool, ctx.stats.events_in, ctx.stats.events_out))
end, false)

-- ---------------------------------------------------------------------------------------------------------------- stop
AddEventHandler("onResourceStop", function(name)
	if name ~= GetCurrentResourceName() then return end
	ctx.cleanup_all()
end)

-- tell the server we are here (the NUI's own `ready` callback does the same when the page loads later)
CreateThread(function()
	Wait(1000)
	if ctx.running then TriggerServerEvent(P.NET.ready) end
end)

-- exposed for the test harness and other resources (the server does the same with OutbreakHost)
function OutbreakClient() return M end

M.modules = { Pool = Pool, Zombies = Zombies, Raiders = Raiders, Colonists = Colonists, Noise = Noise, Camera = Camera, Build = Build, Props = Props, World = World, Nui = Nui, Survival = Survival }
return M
