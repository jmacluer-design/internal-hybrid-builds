-- server/ctx.lua : state and small services shared by every server module (config, coordinate mapping, OUT-event bus, timers, cleanup registry).
-- The server owns the sim (shared/host.lua) AND the world it drives: peds, objects, the clock. The FiveM adapter kept those on the client; MTA's server can create and
-- destroy synced elements, so they live here (see README "Architecture": which side does what, and why locomotion is still executed by the owner's client).
local Config = require("shared.mta_config")

local ctx = {
	config = Config,
	scfg = Config.server,       -- server settings (shared/host.lua reads these)
	cfg = Config.peds,          -- ped / object budgets and behaviour numbers
	origin = Config.origin,     -- sim -> game offset (live table: Config.apply may replace the fields)
	owner = nil,                -- the colony owner's player element (the first client that says `ready`)
	running = true,             -- false after onResourceStop: every timer callback returns at once
	host = nil,                 -- shared/host.lua Host (set by server/main.lua)
	player_sim = { x = 0.0, y = 0.0 },   -- last player position in SIM space as reported by the client (the sim's observer)
	stats = { events_in = 0, errors = 0, unknown_events = 0 },
}

-- ---------------------------------------------------------------------------------------------------------------- coordinates
-- sim space <-> game space: a fixed origin offset (API.md, adapter responsibility 6). The sim's z is always 0; the real height comes from server/ground.lua.
function ctx.to_game(x, y, z) return x + ctx.origin.x, y + ctx.origin.y, (z or 0.0) + ctx.origin.z end
function ctx.to_sim(x, y) return x - ctx.origin.x, y - ctx.origin.y end

function ctx.log(level, text)
	outputServerLog(string.format("[outbreak] %s: %s", level, text))
end

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

-- ---------------------------------------------------------------------------------------------------------------- timers
-- a repeating worker: setTimer(fn, ms, 0). The running check is repeated INSIDE the callback so a stop that happens between two ticks never runs one more iteration (which would
-- touch a destroyed element after the cleanup). An error inside fn is caught, counted and logged (the first one and every 100th), and the timer carries on.
local timers = {}
function ctx.every(name, ms, fn)
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

-- a one-shot delayed call that is cancelled at stop
function ctx.after(ms, fn)
	local t = setTimer(function() if ctx.running then fn() end end, math.max(50, ms), 1)
	if t then timers[#timers + 1] = t end
	return t
end

-- ---------------------------------------------------------------------------------------------------------------- cleanup / reset registries
-- cleanup: every module registers a function; onResourceStop runs them all (LIFO). reset: a `reset` OUT batch (resync, load, new game) asks every module to drop its world.
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
end

function ctx.reset_all()
	for i = 1, #resets do
		local ok, err = pcall(resets[i].fn)
		if not ok then ctx.log("error", "reset " .. resets[i].name .. " failed: " .. tostring(err)) end
	end
end

-- the owner's player element if it is still valid
function ctx.owner_el()
	local o = ctx.owner
	if o and isElement(o) then return o end
	return nil
end

return ctx
