-- server/main.lua : MTA:SA glue for shared/host.lua. The SERVER owns the sim (loaded through bootstrap_mta.lua over fileOpen / loadstring), runs the fixed-step clock (setTimer),
-- batches OUT events to the owner's client (plain tables through triggerClientEvent), validates everything the client sends (server/net.lua), persists through server/store.lua
-- (versioned, two rotating slots), creates and drives the world's peds and objects, exposes the /outbreak_* commands and destroys everything it created on stop.
-- All game-agnostic logic is in shared/host.lua (reused unchanged from the FiveM adapter). Written against docs and the MTA source lists, tested against mocks only: it has never
-- run inside a real MTA server.
OB_BOOT.install()

local Config = require("shared.mta_config")
local U = require("shared.util")
local Host = require("shared.host")
local TUNING = require("data.tuning")

local ctx = require("server.ctx")
local Store = require("server.store")
local Net = require("server.net")
local Zombies = require("server.zombies")
local Raiders = require("server.raiders")
local Colonists = require("server.colonists")
local Buildings = require("server.buildings")
local Props = require("server.props")
local Peds = require("server.peds")
local World = require("server.world")
local Cmd = require("server.commands")
local Phone = require("server.phone")
local Selftest = require("shared.selftest")

local host

local function start_game()
	local s = ctx.scfg
	if s.autoload and host:load_game() then return end
	host:new_game(s.seed, s.profile, s.colonists)
end

local function say_owner(text)
	local o = ctx.owner_el()
	if o then outputChatBox("[outbreak] " .. text, o) else outputServerLog("[outbreak] " .. text) end
end

local function run_selftest()
	local ok, r = Selftest.check()
	if ok then
		ctx.log("info", string.format("selftest OK: this Lua reproduces the recorded sim hash %s (%d ms)", r.hash, r.ms or 0))
	else
		ctx.log("error", string.format("selftest FAILED: hash %s, recorded %s, save->load %s%s. The sim may not be deterministic in this MTA build; saves still work but results can differ from the tests.",
			tostring(r.hash), tostring(r.expected), tostring(r.reload_ok), r.error and (" error: " .. r.error) or ""))
		say_owner("selftest FAILED, see the server log")
	end
	ctx.selftest = r
end

local function on_start()
	-- settings from meta.xml <settings> (get() returns false for a missing one)
	Config.apply(function(name, default)
		local v = get(name)
		if v == nil or v == false then return default end
		return v
	end)
	TUNING.horde.max_materialized = Config.server.max_materialized -- the sim's ped budget (API.md section 6); set before the world exists
	ctx.log("info", string.format("starting %s: origin %.1f,%.1f,%.1f, max_materialized %d, max_peds %d, store %s", Config.VERSION, ctx.origin.x, ctx.origin.y, ctx.origin.z,
		TUNING.horde.max_materialized, ctx.cfg.max_peds, ctx.scfg.store))

	local store = Store.open(ctx.scfg.store)
	host = Host.new({ cfg = Config, send = Net.send, store = store, log = ctx.log })
	ctx.host = host

	-- cross-module wiring (kept here so the modules do not require each other)
	Zombies.colonist_targets = Colonists.peds_for_ai
	Raiders.colonist_targets = Colonists.peds_for_ai
	Colonists.zombie_near = Zombies.nearest
	Colonists.raiders_near = Raiders.near
	Buildings.start(); Zombies.start(); Raiders.start(); Colonists.start()
	ctx.every("brain.raiders", ctx.cfg.brain_ms, function()
		Raiders.think(Zombies.pinfo)
		Peds.flush_drive()
	end)

	Net.register()
	Phone.register()
	Cmd.register()
	start_game()

	-- the fixed-step loop
	local last = getTickCount()
	ctx.every("host", ctx.scfg.tick_ms, function()
		local now = getTickCount()
		local dt = now - last
		last = now
		host:advance(dt)
	end)

	if ctx.scfg.selftest then ctx.after(1500, run_selftest) end
	ctx.log("info", "server module loaded")
end

local function on_stop()
	if not ctx.running then return end
	ctx.running = false -- every timer callback returns at once from here on
	Cmd.cancel_ff()
	if host and host.world and not host.world.s.over then pcall(host.save_game, host, "resource stop") end
	ctx.cleanup_all()
end

addEventHandler("onResourceStart", resourceRoot, on_start)
addEventHandler("onResourceStop", resourceRoot, on_stop)

-- exposed for the test harness and other resources
function OutbreakHost() return host end

-- the phone companion's HTTP entry point (meta.xml <export function="phoneApi" type="server" http="true"/>): POST /outbreak/call/phoneApi with a JSON array body [op, sid, a, b].
-- MTA has already logged the caller in (HTTP Basic -> account) and checked resource.outbreak.http; server/phone.lua checks the phone_view / phone_control rights and the CSRF header.
function phoneApi(op, sid, a, b) return Phone.api(op, sid, a, b) end
