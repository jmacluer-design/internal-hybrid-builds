-- server/main.lua : FiveM glue for shared/host.lua. The SERVER owns the sim (loaded through sim/bootstrap.lua over LoadResourceFile), runs the fixed-step
-- clock (config server.tick_ms / time_scale), batches OUT events to the owner's client (msgpack-safe plain tables), validates everything the client sends,
-- persists to KVP (versioned, two rotating slots) and exposes the /outbreak_* admin and debug commands. All game-agnostic logic is in shared/host.lua.
-- Written against docs, tested against mocks only: it has never run inside a real FiveM server.
local Config = require("shared.config")
local P = require("shared.protocol")
local U = require("shared.util")
local Host = require("shared.host")
local V = require("shared.view")

Config.apply(function(name, default) return GetConvar(name, tostring(default)) end)
local cfg = Config.server

local owner = nil          -- server id of the colony owner (single-player colony: the first client that says `ready`)
local running = true
local host

local function log(level, text) print(string.format("[outbreak] %s: %s", level, text)) end

-- ---------------------------------------------------------------------------------------------------------------- send / store
local function send(topic, payload)
	if not owner then return end
	if cfg.debug then
		local ok, why = U.msgpack_safe(payload)
		if not ok then log("error", "payload for " .. topic .. " is not msgpack-safe: " .. tostring(why)); return end
	end
	TriggerClientEvent(topic, owner, payload)
end

local store = {
	get = function(k) return GetResourceKvpString(k) end,
	set = function(k, v) SetResourceKvp(k, v) end,
	del = function(k) DeleteResourceKvp(k) end,
}

host = Host.new({ cfg = Config, send = send, store = store, log = log })

-- ---------------------------------------------------------------------------------------------------------------- game start
local function start_game()
	if cfg.autoload and host:load_game() then return end
	host:new_game(cfg.seed, cfg.profile, cfg.colonists)
end

local function greet(src)
	TriggerClientEvent(P.NET.hello, src, { owner = true, origin = Config.origin,
		client = { max_peds = Config.client.max_peds, pool_guard = Config.client.pool_guard, max_objects = Config.client.max_objects, colony_key = Config.client.colony_key } })
	TriggerClientEvent(P.NET.catalog, src, V.catalog())
	host:emit_resync(true)   -- reset + the current world (colonists, buildings, power, weather, live hordes ...)
	host:push_state()
	TriggerClientEvent(P.NET.hud, src, host:hud_payload())
end

RegisterNetEvent(P.NET.ready)
AddEventHandler(P.NET.ready, function()
	local src = source
	if not src or src == 0 then return end
	if owner and owner ~= src then
		TriggerClientEvent(P.NET.hello, src, { owner = false })
		return
	end
	owner = src
	greet(src)
end)

RegisterNetEvent(P.NET.inbound)
AddEventHandler(P.NET.inbound, function(list)
	if source ~= owner then return end
	host:on_client_events(list)
end)

RegisterNetEvent(P.NET.order)
AddEventHandler(P.NET.order, function(ev)
	if source ~= owner then return end
	host:on_order(ev)
end)

RegisterNetEvent(P.NET.ui_action)
AddEventHandler(P.NET.ui_action, function(name, data)
	if source ~= owner or type(name) ~= "string" then return end
	if name:sub(1, 6) == "debug_" and not (cfg.debug or cfg.owner_admin) then return end -- debug actions: owner only, and only when allowed
	host:ui_action(name, data)
end)

AddEventHandler("playerDropped", function()
	if source == owner then
		host:save_game("owner left")
		owner = nil
	end
end)

-- ---------------------------------------------------------------------------------------------------------------- the fixed-step loop
CreateThread(function()
	start_game()
	local last = GetGameTimer()
	while running do
		Wait(cfg.tick_ms)
		local now = GetGameTimer()
		host:advance(now - last)
		last = now
	end
end)

AddEventHandler("onResourceStop", function(name)
	if name ~= GetCurrentResourceName() then return end
	running = false
	if host.world and not host.world.s.over then host:save_game("resource stop") end
end)

-- ---------------------------------------------------------------------------------------------------------------- commands
local function reply(src, text)
	if src == 0 then print("[outbreak] " .. text) else TriggerClientEvent("chat:addMessage", src, { args = { "outbreak", text } }) end
end

local function allowed(src)
	if src == 0 then return true end
	if cfg.owner_admin and src == owner then return true end
	return IsPlayerAceAllowed(tostring(src), "outbreak.admin")
end

local function command(name, help, fn)
	RegisterCommand(name, function(src, args, raw)
		if not allowed(src) then reply(src, "not allowed (give the player the `outbreak.admin` ace or use the server console)"); return end
		local ok, err = pcall(fn, src, args)
		if not ok then reply(src, name .. " failed: " .. tostring(err)) end
	end, false)
end

command("outbreak_status", "show the colony status", function(src)
	local st = host:status()
	if not st.world then return reply(src, "no world") end
	reply(src, string.format("%s day %d seed %d %s | colonists %d hordes %d (live %d) raids %d buildings %d | speed %s scale %.0f | hash %s | owner %s",
		st.time, st.day, st.seed, st.profile, st.colonists, st.hordes, st.materialized, st.raids, st.buildings, st.paused and "paused" or tostring(st.speed), st.scale, st.hash, tostring(owner)))
end)
command("outbreak_save", "save now", function(src) reply(src, tostring(host:save_game("command"))) end)
command("outbreak_load", "load the latest save", function(src) local ok, why = host:load_game(); reply(src, ok and ("loaded slot " .. tostring(why)) or ("load failed: " .. tostring(why))) end)
command("outbreak_new", "outbreak_new [seed] [calm|escalating|chaos]", function(src, args) reply(src, tostring(host:new_game(tonumber(args[1]), args[2], nil))) end)
command("outbreak_pause", "toggle the clock", function(src) host:ui_action("toggle_pause", {}); reply(src, host.paused and "paused" or "running") end)
command("outbreak_speed", "outbreak_speed 0|1|2|4|8|16", function(src, args) reply(src, tostring(host:ui_action("set_speed", { speed = tonumber(args[1]) }))) end)
command("outbreak_profile", "outbreak_profile calm|escalating|chaos", function(src, args) host:on_order({ id = "colony", kind = "set_profile", target = args[1] }); reply(src, "profile requested: " .. tostring(args[1])) end)
command("outbreak_horde", "outbreak_horde [size] [distance]", function(src, args) local ok, r = host:debug("horde", { n = tonumber(args[1]) or 20, dist = tonumber(args[2]) or 200 }); reply(src, tostring(ok) .. " " .. tostring(r)) end)
command("outbreak_event", "outbreak_event <director event id>", function(src, args) local ok, r = host:debug("event", { id = args[1] }); reply(src, tostring(ok) .. " " .. tostring(r)) end)
command("outbreak_give", "outbreak_give <item id> [n]", function(src, args) local ok, r = host:debug("give", { item = args[1], n = tonumber(args[2]) or 1 }); reply(src, tostring(ok) .. " " .. tostring(r or "")) end)
command("outbreak_day", "outbreak_day <hour> [minute] [day]", function(src, args) local ok = host:debug("time_set", { hour = tonumber(args[1]) or 12, minute = tonumber(args[2]) or 0, day = tonumber(args[3]) }); reply(src, tostring(ok)) end)
command("outbreak_autopilot", "outbreak_autopilot on|off (the sim's own AI plays the colony)", function(src, args) local _, on = host:debug("autopilot", { on = args[1] ~= "off" }); reply(src, "autopilot " .. tostring(on)) end)
command("outbreak_ff", "outbreak_ff <minutes>  fast-forward the sim", function(src, args) local ok, n = host:debug("fast_forward", { minutes = tonumber(args[1]) or 60 }); reply(src, tostring(ok) .. " " .. tostring(n)) end)
command("outbreak_hash", "print the sim state hash", function(src) reply(src, host.world and host.world:hash() or "no world") end)
command("outbreak_audit", "item conservation check", function(src) local ok, rep = host:debug("audit", {}); reply(src, ok and "audit OK" or ("audit FAILED: " .. table.concat(rep.problems or {}, "; "))) end)

-- exposed for the test harness and other resources
function OutbreakHost() return host end

log("info", "server module loaded (" .. Config.VERSION .. ")")
