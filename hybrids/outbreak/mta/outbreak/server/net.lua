-- server/net.lua : everything that crosses the network on the server side. Outgoing: Net.send (the `send` of shared/host.lua) routes OUT events to the server's own modules
-- (peds, objects, clock) and to the owner's client with triggerClientEvent. Incoming: remote events from clients, each of them validated before it touches the sim.
--
-- TRUST MODEL (MTA events): a remote event is only delivered to events registered with addEvent(name, true) (allowRemoteTrigger); the `client` global inside the handler is the
-- player the SERVER received the packet from (it cannot be forged), but `source` is whatever element the sender chose, so a handler must check it too. Every handler here requires
-- (1) the sender is a real player, (2) it is the colony owner, (3) source == resourceRoot (a spoofer cannot pick another element, e.g. one of our peds, as the source), and (4)
-- the payload passes shared/protocol.lua sanitize_in / sanitize_order and the flood guards. A second player who says `ready` first becomes the owner only if owner_name allows it.
-- Written here (the FiveM adapter's server/main.lua handlers plus the MTA trust rules above). Nothing borrowed.
local ctx = require("server.ctx")
local NET = require("shared.mta_net")
local P = require("shared.protocol")
local U = require("shared.util")
local V = require("shared.view")
local Zombies = require("server.zombies")
local Ground = require("server.ground")
local World = require("server.world")
local Peds = require("server.peds")
local Raiders = require("server.raiders")
local Colonists = require("server.colonists")

local Net = { stats = { rejected = 0, rejected_reasons = {}, in_batches = 0, orders = 0, ui_actions = 0, flood_dropped = 0 } }
local scfg = ctx.scfg

local function reject(why)
	Net.stats.rejected = Net.stats.rejected + 1
	Net.stats.rejected_reasons[why] = (Net.stats.rejected_reasons[why] or 0) + 1
	if scfg.debug then ctx.log("warn", "rejected a client event: " .. why) end
	return false
end

-- ---------------------------------------------------------------------------------------------------------------- outgoing
-- the `send(topic, payload)` of shared/host.lua. OUT events (and a resync marked reset) also drive the server's own modules, unless this is a client-only resync (a client that
-- joined or whose page reloaded must be brought up to date without touching the peds and objects the server already has).
function Net.send(topic, payload)
	if topic == P.NET.events and type(payload) == "table" and not ctx.client_only then
		if payload.reset then ctx.reset_all() end
		local evs = payload.events
		if type(evs) == "table" then for i = 1, #evs do ctx.dispatch(evs[i]) end end
	elseif topic == P.NET.clock then
		World.on_clock(payload)
	elseif topic == P.NET.hud and type(payload) == "table" then
		World.apply_fx(payload.fx)
	end
	local owner = ctx.owner_el()
	if not owner then return end
	if scfg.debug then
		local ok, why = U.msgpack_safe(payload)
		if not ok then ctx.log("error", "payload for " .. topic .. " is not msgpack-safe: " .. tostring(why)); return end
	end
	ctx.stats.events_out = (ctx.stats.events_out or 0) + 1
	triggerClientEvent(owner, NET.wire(topic), resourceRoot, payload)
end

-- ---------------------------------------------------------------------------------------------------------------- greeting
local function greet(player)
	local host = ctx.host
	triggerClientEvent(player, NET.hello, resourceRoot, { owner = true, origin = { x = ctx.origin.x, y = ctx.origin.y, z = ctx.origin.z },
		client = { colony_key = ctx.config.client.colony_key, ui_mode = ctx.config.client.ui_mode, grid = ctx.config.client.grid } })
	triggerClientEvent(player, NET.catalog, resourceRoot, V.catalog())
	ctx.client_only = true
	local ok, err = pcall(host.emit_resync, host, true) -- reset + the current world (colonists, buildings, power, weather, live hordes ...) to THIS client only
	ctx.client_only = false
	if not ok then ctx.log("error", "resync failed: " .. tostring(err)) end
	host:push_state()
	triggerClientEvent(player, NET.hud, resourceRoot, host:hud_payload())
end

-- ---------------------------------------------------------------------------------------------------------------- incoming guards
-- the `client` and `source` globals exist inside a handler of a remotely triggered event
local function from_player()
	return client ~= nil and isElement(client) and getElementType(client) == "player" and source == resourceRoot
end

local function from_owner()
	if not from_player() then return reject("not from a player on resourceRoot") end
	if client ~= ctx.owner then return reject("not the owner") end
	if not ctx.host or not ctx.host.world then return reject("no world") end
	return true
end

-- a token bucket for orders and UI actions (the host rate-limits IN events itself)
local ui_tokens, ui_last = scfg.max_ui_per_sec, nil
local function ui_token()
	local now = getTickCount()
	if ui_last then ui_tokens = math.min(scfg.max_ui_per_sec * 2, ui_tokens + (now - ui_last) / 1000 * scfg.max_ui_per_sec) end
	ui_last = now
	if ui_tokens < 1 then Net.stats.flood_dropped = Net.stats.flood_dropped + 1; return false end
	ui_tokens = ui_tokens - 1
	return true
end

local ground_tokens, ground_last = 20, nil
local function ground_token()
	local now = getTickCount()
	if ground_last then ground_tokens = math.min(40, ground_tokens + (now - ground_last) / 1000 * 20) end
	ground_last = now
	if ground_tokens < 1 then return false end
	ground_tokens = ground_tokens - 1
	return true
end

-- ---------------------------------------------------------------------------------------------------------------- registration
function Net.register()
	-- remote events (client -> server): allowRemoteTrigger = true
	addEvent(NET.ready, true)
	addEvent(NET.inbound, true)
	addEvent(NET.order, true)
	addEvent(NET.ui_action, true)
	addEvent(NET.ground, true)

	addEventHandler(NET.ready, resourceRoot, function()
		if not from_player() then return reject("ready: not from a player on resourceRoot") end
		local player = client
		if scfg.owner_name ~= "" and getPlayerName(player) ~= scfg.owner_name then
			triggerClientEvent(player, NET.hello, resourceRoot, { owner = false })
			return reject("ready: not the configured owner")
		end
		if ctx.owner and ctx.owner ~= player and isElement(ctx.owner) then
			triggerClientEvent(player, NET.hello, resourceRoot, { owner = false })
			return
		end
		ctx.owner = player
		Peds.assign_all()
		World.join_team(player)
		if scfg.spawn_player and (isPedDead(player) or not ctx.spawned) then World.spawn_owner(player); ctx.spawned = true end
		greet(player)
	end)

	addEventHandler(NET.inbound, resourceRoot, function(list)
		if not from_owner() then return end
		if type(list) ~= "table" then return reject("inbound: not a table") end
		Net.stats.in_batches = Net.stats.in_batches + 1
		ctx.host:on_client_events(list)
		-- loud noises also make the zombies that are already in the world go and look (abstract hordes are moved by the sim)
		for i = 1, math.min(#list, 120) do
			local ev = type(list[i]) == "table" and list[i].type == "noise" and P.sanitize_in(list[i]) or nil
			if ev then
				local gx, gy = ctx.to_game(ev.pos.x, ev.pos.y, 0.0)
				Zombies.hear(gx, gy, Ground.z_at(gx, gy), ev.loudness)
				if ev.kind == "explosion" then Zombies.blast(gx, gy, Ground.z_at(gx, gy), 25.0) end
			end
		end
	end)

	addEventHandler(NET.order, resourceRoot, function(ev)
		if not from_owner() then return end
		if not ui_token() then return end
		Net.stats.orders = Net.stats.orders + 1
		local ok, err = pcall(ctx.host.on_order, ctx.host, ev)
		if not ok then ctx.log("error", "order failed: " .. tostring(err)) end
	end)

	addEventHandler(NET.ui_action, resourceRoot, function(name, data)
		if not from_owner() then return end
		if type(name) ~= "string" or #name > 32 then return reject("ui_action: bad name") end
		if not ui_token() then return end
		if name:sub(1, 6) == "debug_" and not (scfg.debug or scfg.owner_admin) then return reject("ui_action: debug refused") end
		Net.stats.ui_actions = Net.stats.ui_actions + 1
		if name == "screens" and type(data) == "table" then ctx.colony_mode = data.colony == true end -- in colony view the player ped is only a camera anchor
		local ok, err = pcall(ctx.host.ui_action, ctx.host, name, data)
		if not ok then ctx.log("error", "ui_action " .. name .. " failed: " .. tostring(err)) end
	end)

	-- one of our armed peds streamed in on the owner's client: give its weapon again; the ped must be one of ours, the sender the owner, the source the resource root
	-- BORROWED-PRIVATE (unlicensed upstream, private use only): NullSystemWorks/mtadayz/slothbot/sbserver.lua (the "StreamWeapon" server event; our trust checks are added)
	addEvent(NET.stream, true)
	addEventHandler(NET.stream, resourceRoot, function(ped)
		if not from_owner() then return end
		if not isElement(ped) or not Peds.owns(ped) then return reject("stream: not one of our peds") end
		Peds.restore_weapon(ped)
	end)
	-- END BORROWED-PRIVATE

	-- the player hit one of our zombies: it turns on the player. Same trust rules; a token bucket stops a flood
	-- BORROWED-PRIVATE (unlicensed upstream, private use only): NullSystemWorks/mtadayz/slothbot/sbserver.lua (the "onBotFindEnemy" server event: the ped takes the player as its target; our trust checks are added)
	addEvent(NET.hit, true)
	addEventHandler(NET.hit, resourceRoot, function(ped)
		if not from_owner() then return end
		if not isElement(ped) or Peds.kind_of(ped) ~= "zombie" then return reject("hit: not one of our zombies") end
		if not ui_token() then return end
		Zombies.on_hit(ped)
	end)
	-- END BORROWED-PRIVATE

	addEventHandler(NET.ground, resourceRoot, function(list)
		if not from_owner() then return end
		if not ground_token() then return end
		Ground.on_samples(list)
	end)

	-- built-in server events
	addEventHandler("onPedWasted", root, function(ammo, killer)
		if not Peds.owns(source) then return end
		local ped = source
		if not (Zombies.on_wasted(ped, killer) or Raiders.on_wasted(ped, killer) or Colonists.on_wasted(ped, killer)) then Peds.corpse(ped) end
	end)

	addEventHandler("onPlayerWasted", root, function(ammo, killer) World.on_player_wasted(source, killer) end)

	addEventHandler("onPlayerQuit", root, function()
		if source == ctx.owner then
			if ctx.host and ctx.host.world then pcall(ctx.host.save_game, ctx.host, "owner left") end
			ctx.owner, ctx.colony_mode, ctx.spawned = nil, false, false
		end
	end)
end

return Net
