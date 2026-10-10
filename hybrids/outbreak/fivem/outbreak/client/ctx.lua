-- client/ctx.lua : state and small services shared by every client module (config, coordinate mapping, OUT-event bus, IN-event queue).
-- No module keeps a second copy of this: they all `require("client.ctx")`.
local Config = require("shared.config")
local P = require("shared.protocol")
local U = require("shared.util")

local ctx = {
	cfg = Config.client,
	config = Config,
	origin = { x = Config.origin.x, y = Config.origin.y, z = Config.origin.z },
	owner = false,            -- this client is the colony owner (set by outbreak:hello)
	running = true,           -- false after onResourceStop: every thread must exit its loop
	sim_t = 0,                -- sim minutes of the last clock message
	state = nil,              -- latest UI view model (shared/view.lua) while a colony screen is open
	hud = nil,
	player_sim = { x = 0.0, y = 0.0 },   -- last player position in SIM space
	rel = {},                 -- relationship group hashes (client/relations.lua)
	colony_mode = false,
	stats = { events_in = 0, events_out = 0, unknown_events = 0, errors = 0 },
}

-- ---------------------------------------------------------------------------------------------------------------- coordinates
-- sim space <-> game space: a fixed origin offset (API.md, adapter responsibility 6). The sim's z is always 0: callers resolve the
-- real ground height themselves (client/pool.lua ground_z), so z here is only a hint.
function ctx.to_game(x, y, z) return x + ctx.origin.x, y + ctx.origin.y, (z or 0.0) + ctx.origin.z end
function ctx.to_sim(x, y) return x - ctx.origin.x, y - ctx.origin.y end

function ctx.log(level, text)
	print(string.format("[outbreak] %s: %s", level, text))
end

function ctx.now() return GetGameTimer() end

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
-- Modules call ctx.send(ev) with SIM-space positions; a flush thread (client/main.lua) ships the queue once per tick.
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
	TriggerServerEvent(P.NET.inbound, batch)
	return #batch
end

function ctx.queued() return #outq end

-- a worker thread: Wait(ms) then fn(), until the resource stops. The running check is repeated AFTER the Wait so a stop that happens while the thread sleeps
-- never runs one more iteration (which would re-apply a clock override or touch a deleted ped after the cleanup). An error inside fn is caught, counted and
-- logged (the first one and every 100th), and the thread carries on: one bad frame must not stop the zombie AI for the rest of the session.
function ctx.loop(name, wait, fn)
	CreateThread(function()
		local fails = 0
		while ctx.running do
			Wait(wait)
			if not ctx.running then break end
			local ok, err = pcall(fn)
			if not ok then
				ctx.stats.errors = ctx.stats.errors + 1
				fails = fails + 1
				if fails == 1 or fails % 100 == 0 then ctx.log("error", name .. " failed (" .. fails .. "x): " .. tostring(err)) end
			end
		end
	end)
end

-- cleanup registry: every module registers a function; onResourceStop runs them all (LIFO)
local cleanups = {}
function ctx.on_cleanup(name, fn) cleanups[#cleanups + 1] = { name = name, fn = fn } end
function ctx.cleanup_all()
	ctx.running = false
	for i = #cleanups, 1, -1 do
		local ok, err = pcall(cleanups[i].fn)
		if not ok then ctx.log("error", "cleanup " .. cleanups[i].name .. " failed: " .. tostring(err)) end
	end
end

-- reset hook: a `reset` OUT batch (resync, load, new game) asks every module to drop its world
local resets = {}
function ctx.on_reset(name, fn) resets[#resets + 1] = { name = name, fn = fn } end
function ctx.reset_all()
	for i = 1, #resets do
		local ok, err = pcall(resets[i].fn)
		if not ok then ctx.log("error", "reset " .. resets[i].name .. " failed: " .. tostring(err)) end
	end
end

ctx.U = U
return ctx
