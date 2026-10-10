-- client/ctx.lua : state and small services shared by every client module (config, coordinate mapping, OUT-event bus, IN-event queue, timers, render hooks, cleanup).
-- No module keeps a second copy of this: they all require("client.ctx"). Same shape as the FiveM adapter's client/ctx.lua, on MTA functions.
local Config = require("shared.mta_config")
local NET = require("shared.mta_net")

local ctx = {
	cfg = Config.client,
	config = Config,
	origin = { x = Config.origin.x, y = Config.origin.y, z = Config.origin.z },
	owner = false,            -- this client is the colony owner (set by outbreak:hello)
	running = true,           -- false after onClientResourceStop: every callback must return at once
	sim_t = 0,                -- sim minutes of the last clock message
	sim_scale = 0.5,          -- sim minutes per real second (0 when paused)
	state = nil,              -- latest UI view model (shared/view.lua) while a colony screen is open
	catalog = nil,
	hud = nil,
	player_sim = { x = 0.0, y = 0.0 },   -- last player position in SIM space (the camera focus in colony view)
	colony_mode = false,
	stats = { events_in = 0, events_out = 0, unknown_events = 0, errors = 0 },
}

-- ---------------------------------------------------------------------------------------------------------------- coordinates
-- sim space <-> game space: a fixed origin offset (API.md, adapter responsibility 6). The sim's z is always 0: callers resolve the real ground height themselves.
function ctx.to_game(x, y, z) return x + ctx.origin.x, y + ctx.origin.y, (z or 0.0) + ctx.origin.z end
function ctx.to_sim(x, y) return x - ctx.origin.x, y - ctx.origin.y end

function ctx.log(level, text) outputDebugString(string.format("[outbreak] %s: %s", level, text), level == "error" and 1 or (level == "warn" and 2 or 3)) end

function ctx.now() return getTickCount() end

-- ---------------------------------------------------------------------------------------------------------------- OUT event bus
-- modules register for OUT event types (API.md section 3); unknown types are ignored (the contract only grows)
local handlers = {}
function ctx.on(ev_type, fn)
	local l = handlers[ev_type]
	if not l then l = {}; handlers[ev_type] = l end
	l[#l + 1] = fn
end

function ctx.dispatch(ev)
	if type(ev) ~= "table" or type(ev.type) ~= "string" then return end
	local l = handlers[ev.type]
	if not l then ctx.stats.unknown_events = ctx.stats.unknown_events + 1; return end
	for i = 1, #l do
		local ok, err = pcall(l[i], ev)
		if not ok then ctx.stats.errors = ctx.stats.errors + 1; ctx.log("error", ev.type .. " handler failed: " .. tostring(err)) end
	end
end

-- ---------------------------------------------------------------------------------------------------------------- IN event queue
-- Modules call ctx.send(ev) with SIM-space positions; a flush timer (client/main.lua) ships the queue once per tick (one network message, never one per event).
local outq = {}
function ctx.send(ev)
	if #outq >= 200 then table.remove(outq, 1) end -- never grow without bound while the server is away
	outq[#outq + 1] = ev
	ctx.stats.events_out = ctx.stats.events_out + 1
end

function ctx.flush()
	if #outq == 0 then return 0 end
	local batch = outq
	outq = {}
	triggerServerEvent(NET.inbound, resourceRoot, batch)
	return #batch
end

function ctx.queued() return #outq end

-- ---------------------------------------------------------------------------------------------------------------- timers and render hooks
-- a repeating worker: setTimer(fn, ms, 0). The running check is inside the callback, so a stop that happens between two ticks never runs one more iteration. An error inside fn is
-- caught, counted and logged (the first one and every 100th); the timer carries on: one bad step must not stop the driver for the rest of the session.
local timers, frames = {}, {}
function ctx.loop(name, ms, fn)
	local fails = 0
	local t = setTimer(function()
		if not ctx.running then return end
		local ok, err = pcall(fn)
		if not ok then
			ctx.stats.errors = ctx.stats.errors + 1
			fails = fails + 1
			if fails == 1 or fails % 100 == 0 then ctx.log("error", name .. " failed (" .. fails .. "x): " .. tostring(err)) end
		end
	end, math.max(50, ms), 0)
	if t then timers[#timers + 1] = t end
	return t
end

function ctx.after(ms, fn)
	local t = setTimer(function() if ctx.running then fn() end end, math.max(50, ms), 1)
	if t then timers[#timers + 1] = t end
	return t
end

-- a per-frame hook: event "onClientRender" (draw) or "onClientPreRender" (logic; receives the time slice in ms). Errors are caught like in loop().
function ctx.frame(event, name, fn)
	local fails = 0
	local handler = function(...)
		if not ctx.running then return end
		local ok, err = pcall(fn, ...)
		if not ok then
			ctx.stats.errors = ctx.stats.errors + 1
			fails = fails + 1
			if fails == 1 or fails % 500 == 0 then ctx.log("error", name .. " failed (" .. fails .. "x): " .. tostring(err)) end
		end
	end
	if event == "onClientPreRender" then addEventHandler("onClientPreRender", root, handler) else addEventHandler("onClientRender", root, handler) end
	frames[#frames + 1] = { event = event, fn = handler }
end

-- ---------------------------------------------------------------------------------------------------------------- cleanup / reset registries
-- cleanup: every module registers a function; onClientResourceStop runs them all (LIFO). reset: a `reset` OUT batch (resync, load, new game) asks every module to drop its world.
local cleanups, resets = {}, {}
function ctx.on_cleanup(name, fn) cleanups[#cleanups + 1] = { name = name, fn = fn } end
function ctx.on_reset(name, fn) resets[#resets + 1] = { name = name, fn = fn } end

function ctx.cleanup_all()
	ctx.running = false
	for i = #cleanups, 1, -1 do
		local ok, err = pcall(cleanups[i].fn)
		if not ok then ctx.log("error", "cleanup " .. cleanups[i].name .. " failed: " .. tostring(err)) end
	end
	for i = #timers, 1, -1 do if isTimer(timers[i]) then killTimer(timers[i]) end timers[i] = nil end
	for i = #frames, 1, -1 do removeEventHandler(frames[i].event, root, frames[i].fn); frames[i] = nil end
end

function ctx.reset_all()
	for i = 1, #resets do
		local ok, err = pcall(resets[i].fn)
		if not ok then ctx.log("error", "reset " .. resets[i].name .. " failed: " .. tostring(err)) end
	end
end

return ctx
