-- client/nui.lua : the bridge to the NUI page. Lua -> page: SendNUIMessage({action, data}) (names in shared/protocol.lua NUI_OUT). Page -> Lua: NUI
-- callbacks (fetch https://<resource>/<name>): ready, order, ui, mode, mouse, key, place, focus, screen, close. The page owns keyboard + mouse while it has
-- NUI focus (colony view or any modal screen), so the game never sees those keys; the camera gets WASD / mouse through `key` / `mouse` callbacks.
local ctx = require("client.ctx")
local P = require("shared.protocol")

local Nui = { focus = false, screen = nil, ready = false, stats = { sent = 0, callbacks = 0 } }

function Nui.send(action, data)
	Nui.stats.sent = Nui.stats.sent + 1
	SendNUIMessage({ action = action, data = data })
end
ctx.nui_send = Nui.send

function Nui.update_focus()
	local want = ctx.colony_mode or Nui.screen ~= nil
	if want ~= Nui.focus then
		Nui.focus = want
		SetNuiFocus(want, want)
	end
end

-- handlers are bound by client/main.lua, which owns the module wiring: `h` = { set_mode = fn, camera = module, build = module }
function Nui.register(h)
	local function cb_ok(cb, extra) cb(extra or { ok = true }) end
	RegisterNUICallback("ready", function(_, cb)
		Nui.ready = true
		Nui.send("boot", { preview = false, resource = GetCurrentResourceName(), version = ctx.config.VERSION })
		TriggerServerEvent(P.NET.ready)
		cb_ok(cb)
	end)
	RegisterNUICallback("order", function(d, cb)
		Nui.stats.callbacks = Nui.stats.callbacks + 1
		TriggerServerEvent(P.NET.order, d)
		cb_ok(cb)
	end)
	RegisterNUICallback("ui", function(d, cb)
		Nui.stats.callbacks = Nui.stats.callbacks + 1
		local name = d and d.name
		if type(name) == "string" then
			if name == "select" and h.camera and d.data and d.data.id and d.data.id ~= "" then h.camera.set_selection({ d.data.id }, false) end
			TriggerServerEvent(P.NET.ui_action, name, d.data or {})
		end
		cb_ok(cb)
	end)
	RegisterNUICallback("mode", function(d, cb) h.set_mode(d and d.mode); cb_ok(cb) end)
	RegisterNUICallback("mouse", function(d, cb) h.camera.on_mouse(d or {}); cb_ok(cb) end)
	RegisterNUICallback("key", function(d, cb) h.camera.on_key(d or {}); cb_ok(cb) end)
	RegisterNUICallback("focus", function(d, cb)
		if d and tonumber(d.x) and tonumber(d.y) then
			local gx, gy = ctx.to_game(tonumber(d.x), tonumber(d.y), 0.0)
			h.camera.focus(gx, gy)
		end
		cb_ok(cb)
	end)
	RegisterNUICallback("place", function(d, cb)
		d = d or {}
		if d.op == "start" and type(d.bp) == "string" then h.build.start_placing(d.bp)
		elseif d.op == "cancel" then h.build.cancel_placing()
		elseif d.op == "commit" and tonumber(d.x) and tonumber(d.y) then
			TriggerServerEvent(P.NET.order, { id = "colony", kind = "place_blueprint", target = { bp = d.bp, pos = { x = tonumber(d.x), y = tonumber(d.y), z = 0.0 } } })
		end
		cb_ok(cb)
	end)
	RegisterNUICallback("screen", function(d, cb)
		d = d or {}
		Nui.screen = d.open and (d.name or "screen") or nil
		Nui.update_focus()
		cb_ok(cb)
	end)
	RegisterNUICallback("close", function(_, cb) Nui.screen = nil; Nui.update_focus(); cb_ok(cb) end)
end

ctx.on_cleanup("nui", function()
	Nui.screen = nil
	if Nui.focus then Nui.focus = false; SetNuiFocus(false, false) end
end)
return Nui
