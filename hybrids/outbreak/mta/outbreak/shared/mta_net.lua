-- shared/mta_net.lua : the names of every MTA event this resource uses, in one place (tools/function_check.lua loads this file to resolve names written as NET.xxx and
-- checks that each triggerClientEvent / triggerServerEvent name is registered with addEvent on the receiving side).
-- The network topics are the FiveM adapter's own (shared/protocol.lua P.NET) so shared/host.lua is reused unchanged. One name differs: P.NET.ui is "outbreak:ui", but in MTA
-- that name is taken by the BROWSER -> client event (mta.triggerEvent('outbreak:ui', name, json), see ui/mta-bridge.js), so the server -> client "UI result" message is renamed.
local P = require("shared.protocol")

local N = {
	-- server -> client (remote events: the client registers them with addEvent(name, true))
	hello = P.NET.hello,          -- { owner = true, origin = {..}, client = {..} }
	events = P.NET.events,        -- { seq, t, events = { OUT event, ... }, reset? }
	state = P.NET.state,          -- UI view model (shared/view.lua)
	hud = P.NET.hud,              -- survival HUD numbers + effects
	clock = P.NET.clock,          -- { t, day, hour, minute, scale, speed }
	catalog = P.NET.catalog,      -- static UI data
	ui_msg = "outbreak:uimsg",    -- { name, data }: results of UI actions (toast, inventory, summary ...)
	drive = "outbreak:drive",     -- list of ped intents for the client-side ped driver (client/driver.lua)
	-- client -> server (remote events: the server registers them with addEvent(name, true))
	ready = P.NET.ready,
	inbound = P.NET.inbound,      -- { IN event, ... } validated by shared/protocol.lua sanitize_in
	order = P.NET.order,
	ui_action = P.NET.ui_action,
	ground = "outbreak:ground",   -- { {x, y, z}, ... } ground height samples
	stream = "outbreak:stream",   -- ped element: one of our armed peds streamed in on the client, give its weapon again (slothbot "StreamWeapon")
	hit = "outbreak:hit",         -- ped element: the player hit one of our zombies, it turns on the player (slothbot aidamage)
	-- browser -> client Lua (a LOCAL event: addEvent(name, false); the source is always the browser element)
	browser = "outbreak:ui",
}

N.TO_CLIENT = { N.hello, N.events, N.state, N.hud, N.clock, N.catalog, N.ui_msg, N.drive }
N.TO_SERVER = { N.ready, N.inbound, N.order, N.ui_action, N.ground, N.stream, N.hit }

-- the server's `send(topic, payload)` is called with P.NET topics; this maps them to the wire name (only ui differs)
function N.wire(topic)
	if topic == P.NET.ui then return N.ui_msg end
	return topic
end

return N
