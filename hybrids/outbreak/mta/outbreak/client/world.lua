-- client/world.lua : the owner's screen. An outage dims the view (the base is dark when the grid is down), alerts play a frontend sound, the default GTA HUD parts that the page replaces
-- (health, money, clock, wanted level) are hidden and shown again on stop. The sky, the clock and the weather are set by the server (server/world.lua); MTA has no ambient population to switch off.
-- Written here (the FiveM adapter's client/world.lua on MTA functions). Nothing borrowed.
local ctx = require("client.ctx")

local W = { dark = false, hidden = {}, stats = { alerts = 0 } }

local HUD_HIDE = { "health", "armour", "breath", "money", "clock", "wanted" }

ctx.on("set_power", function(ev) W.dark = not ev.on end)

ctx.on("play_alert", function(ev)
	local id = ctx.config.alert_sounds[ev.kind]
	if id then playSoundFrontEnd(id); W.stats.alerts = W.stats.alerts + 1 end
end)

-- the sim clock message: remember the scale (colonists' snap deadline uses it on the server; the client only keeps it for the UI)
function W.on_clock(msg)
	ctx.sim_t = msg.t or ctx.sim_t
	ctx.sim_scale = msg.scale or ctx.sim_scale
end

function W.hide_hud()
	for _, c in ipairs(HUD_HIDE) do setPlayerHudComponentVisible(c, false); W.hidden[#W.hidden + 1] = c end
end

function W.restore_hud()
	for _, c in ipairs(W.hidden) do setPlayerHudComponentVisible(c, true) end
	W.hidden = {}
end

function W.draw()
	if not W.dark then return end
	local w, h = guiGetScreenSize()
	dxDrawRectangle(0, 0, w, h, tocolor(0, 0, 8, 110), false)
end

function W.start()
	W.hide_hud()
	ctx.frame("onClientRender", "world.draw", W.draw)
end

ctx.on_cleanup("world", function() W.restore_hud(); W.dark = false end)
return W
