-- client/main.lua : wires the client modules together. Network events from the server -> modules + the CEF page; a flush timer for IN events; key binds; cleanup on resource stop (every
-- module registered a cleanup with client/ctx.lua, so nothing leaks: browser, ghost, controls, cursor, HUD parts, driven peds). The client renders the UI, runs the colony camera, detects
-- noise, applies the survival body to the controls and DRIVES the server's peds (client/driver.lua). Written against docs and the MTA source lists, tested against mocks only.
OB_BOOT.install()

local ctx = require("client.ctx")
local NET = require("shared.mta_net")
local UI = require("client.ui")
local Camera = require("client.camera")
local Placement = require("client.placement")
local Noise = require("client.noise")
local Survival = require("client.survival")
local Driver = require("client.driver")
local Ground = require("client.ground")
local World = require("client.world")
local Props = require("client.props")

local M = { started = false, mode = "survival", last_heading = -1 }

-- ---------------------------------------------------------------------------------------------------------------- mode
function M.set_mode(mode)
	mode = (mode == "colony") and "colony" or "survival"
	if not ctx.owner then return end
	if mode == M.mode then UI.send("mode", { mode = mode }); return end
	M.mode = mode
	if mode == "colony" then Camera.enter() else Camera.leave(); Placement.cancel_placing() end
	UI.update_focus()
	UI.send("mode", { mode = mode })
end

-- ---------------------------------------------------------------------------------------------------------------- startup (after the server says hello)
local function start(msg)
	if type(msg.origin) == "table" and tonumber(msg.origin.x) and tonumber(msg.origin.y) and tonumber(msg.origin.z) then
		ctx.origin.x, ctx.origin.y, ctx.origin.z = msg.origin.x, msg.origin.y, msg.origin.z
	end
	ctx.owner = msg.owner == true
	if not ctx.owner then return end
	if not M.started then
		M.started = true
		World.start(); Noise.start(); Survival.start(); Camera.start(); Placement.start(); Driver.start(); Ground.start()
		ctx.loop("flush", 250, ctx.flush) -- IN event flush (one network message per tick, never per event)
		ctx.loop("compass", 100, function() -- compass heading for the HUD, from the camera matrix
			local x, y, _, lx, ly = getCameraMatrix()
			if not x then return end
			local yaw = math.deg(math.atan2(-(lx - x), ly - y))
			local heading = (-yaw) % 360.0
			if math.abs(heading - M.last_heading) > 0.5 then M.last_heading = heading; UI.send("compass", { heading = heading }) end
		end)
	end
end

-- ---------------------------------------------------------------------------------------------------------------- network events
local function on_events(msg)
	if not ctx.running or type(msg) ~= "table" or type(msg.events) ~= "table" then return end
	ctx.stats.events_in = ctx.stats.events_in + #msg.events
	if msg.reset then ctx.reset_all() end
	for i = 1, #msg.events do ctx.dispatch(msg.events[i]) end
	UI.send("events", msg.events)
end

local function register_network()
	-- remote events (server -> client): allowRemoteTrigger = true; the source is always the resource root (checked in every handler)
	addEvent(NET.hello, true)
	addEvent(NET.events, true)
	addEvent(NET.state, true)
	addEvent(NET.hud, true)
	addEvent(NET.clock, true)
	addEvent(NET.catalog, true)
	addEvent(NET.ui_msg, true)

	addEventHandler(NET.hello, resourceRoot, function(msg) if source == resourceRoot and type(msg) == "table" then start(msg) end end)
	addEventHandler(NET.events, resourceRoot, function(msg) if source == resourceRoot then on_events(msg) end end)
	addEventHandler(NET.state, resourceRoot, function(msg)
		if source ~= resourceRoot or type(msg) ~= "table" then return end
		ctx.state = msg
		UI.send("state", msg)
	end)
	addEventHandler(NET.hud, resourceRoot, function(msg)
		if source ~= resourceRoot or type(msg) ~= "table" then return end
		ctx.hud = msg
		UI.send("hud", msg)
		Survival.apply_fx(msg.fx)
	end)
	addEventHandler(NET.clock, resourceRoot, function(msg) if source == resourceRoot and type(msg) == "table" then World.on_clock(msg) end end)
	addEventHandler(NET.catalog, resourceRoot, function(msg)
		if source == resourceRoot and type(msg) == "table" then ctx.catalog = msg; UI.send("catalog", msg) end
	end)
	addEventHandler(NET.ui_msg, resourceRoot, function(msg)
		if source == resourceRoot and type(msg) == "table" and type(msg.name) == "string" then UI.send(msg.name, msg.data) end
	end)
end

-- ---------------------------------------------------------------------------------------------------------------- startup of the resource
local function on_start()
	register_network()
	UI.register({ set_mode = M.set_mode, camera = Camera, build = Placement })
	UI.create()

	bindKey(ctx.cfg.colony_key:lower(), "down", function() if ctx.owner then M.set_mode(M.mode == "colony" and "survival" or "colony") end end)
	bindKey(ctx.cfg.inventory_key, "down", function() if ctx.owner and not ctx.colony_mode then UI.send("screen", { name = "inventory" }) end end)
	bindKey(ctx.cfg.interact_key, "down", function() if ctx.owner then Props.interact() end end)

	addCommandHandler("outbreak_colony", function() if ctx.owner then M.set_mode(M.mode == "colony" and "survival" or "colony") end end)
	addCommandHandler("outbreak_client", function()
		outputChatBox(string.format("[outbreak] client: events in %d out %d, UI sent %d (queued %d dropped %d), drive intents %d (driven %d stuck %d), ground samples %d, errors %d",
			ctx.stats.events_in, ctx.stats.events_out, UI.stats.sent, UI.stats.queued, UI.stats.dropped, Driver.count, Driver.stats.driven, Driver.stats.stuck, Ground.stats.samples, ctx.stats.errors))
	end)

	addEventHandler("onClientMinimize", root, function() UI.pause(true) end)
	addEventHandler("onClientRestore", root, function() UI.pause(false) end)

	-- tell the server we are here (the page's own `ready` callback does the same when it finishes loading)
	ctx.after(1000, function() triggerServerEvent(NET.ready, resourceRoot) end)
end

local function on_stop()
	ctx.cleanup_all()
end

addEventHandler("onClientResourceStart", resourceRoot, on_start)
addEventHandler("onClientResourceStop", resourceRoot, on_stop)

-- exposed for the test harness and other resources (the server does the same with OutbreakHost)
M.modules = { UI = UI, Camera = Camera, Placement = Placement, Noise = Noise, Survival = Survival, Driver = Driver, Ground = Ground, World = World, Props = Props }
function OutbreakClient() return M end
