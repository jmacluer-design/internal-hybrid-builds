-- client/ui.lua : the bridge to the CEF page (the UNCHANGED vanilla Outbreak UI, copied by tools/sync_ui.sh, plus ui/mta-bridge.js).
--
--   Lua -> page:  executeBrowserJavascript(browser, "window.dispatchEvent(new MessageEvent('message',{data:<json>}))") with data = { action, data } (js/main.js routes it).
--   page -> Lua:  the bridge turns the page's fetch('https://outbreak/<name>') into mta.triggerEvent('outbreak:ui', '<name>', '<json>'), a LOCAL event (addEvent(name, false))
--                 whose source is the browser element. Only that browser is accepted (an event triggered by any other element or resource is dropped), the JSON is decoded
--                 with a size / depth limit, and the callback names are the FiveM adapter's NUI callbacks: ready order ui mode mouse key focus place screen close.
--   CEF requirements (README "CEF"): MTA client 1.5.1 or newer, Settings > Web Browser > "Enable remote websites" is NOT needed (the page is local: http://mta/local/ui/mta.html),
--   the page and its css / js / fonts are listed as <file> in meta.xml, GPU rendering of the browser needs the player's "Enable CEF" setting on (default).
--   Two ways to show the page (setting ui_mode): "gui" = guiCreateBrowser (a full-screen transparent CEGUI browser: the engine routes mouse and keyboard) or "dx" = createBrowser drawn
--   with dxDrawImage and fed by injectBrowserMouse*. Input focus: while a colony screen or modal screen is open the cursor is shown, the browser is focused, all game controls are
--   off and binds are off while typing (guiSetInputMode); otherwise the page is only displayed (the HUD) and the game owns the keyboard and mouse.
--
-- borrowed: multitheftauto/mtasa-resources [gameplay]/webbrowser (MIT): the browser life cycle (guiCreateBrowser -> onClientBrowserCreated -> load -> onClientBrowserDocumentReady,
--   showCursor + guiSetInputMode, the blocked-domain check and requestBrowserDomains flow), re-done without its GUI window and OOP classes.
-- Written here: the message queue, the callback router, focus handling, the dx fallback.
local ctx = require("client.ctx")
local NET = require("shared.mta_net")
local Json = require("shared.json")
local JsonDecode = require("shared.json_decode")

local UI = {
	browser = nil, gui = nil, created = false, ready = false, queue = {}, focus = false, screen = nil, paused = false, handlers = {},
	stats = { sent = 0, queued = 0, dropped = 0, callbacks = 0, rejected = 0, bytes = 0, decode_errors = 0 },
}
local cfg = ctx.cfg

local MAX_QUEUE, MAX_JS = 200, 1000000
local PREFIX = "window.dispatchEvent(new MessageEvent('message',{data:"
local SUFFIX = "}))"

-- ---------------------------------------------------------------------------------------------------------------- Lua -> page
local function push_js(msg)
	local ok, json = pcall(Json.encode, msg)
	if not ok then ctx.stats.errors = ctx.stats.errors + 1; ctx.log("error", "cannot encode UI message " .. tostring(msg.action) .. ": " .. tostring(json)); return false end
	local js = PREFIX .. json .. SUFFIX
	if #js > MAX_JS then UI.stats.dropped = UI.stats.dropped + 1; ctx.log("warn", "UI message " .. tostring(msg.action) .. " is too large (" .. #js .. " bytes), dropped"); return false end
	UI.stats.sent = UI.stats.sent + 1
	UI.stats.bytes = UI.stats.bytes + #js
	return executeBrowserJavascript(UI.browser, js)
end

-- send one message to the page; queued until the document is ready (then flushed in order)
function UI.send(action, data)
	local msg = { action = action, data = data }
	if UI.ready and UI.browser and isElement(UI.browser) then return push_js(msg) end
	if #UI.queue >= MAX_QUEUE then table.remove(UI.queue, 1); UI.stats.dropped = UI.stats.dropped + 1 end
	UI.queue[#UI.queue + 1] = msg
	UI.stats.queued = UI.stats.queued + 1
	return false
end
ctx.nui_send = UI.send

local function flush_queue()
	local q = UI.queue
	UI.queue = {}
	for i = 1, #q do push_js(q[i]) end
end

-- ---------------------------------------------------------------------------------------------------------------- page -> Lua
function UI.handle(name, data)
	local h = UI.handlers[name]
	if not h then return false end
	UI.stats.callbacks = UI.stats.callbacks + 1
	local ok, err = pcall(h, data or {})
	if not ok then ctx.stats.errors = ctx.stats.errors + 1; ctx.log("error", "UI callback " .. name .. " failed: " .. tostring(err)) end
	return ok
end

local function on_browser_event(name, json)
	if source ~= UI.browser then UI.stats.rejected = UI.stats.rejected + 1; return end -- only OUR browser element may talk to us
	if type(name) ~= "string" or #name > 24 or type(json) ~= "string" then UI.stats.rejected = UI.stats.rejected + 1; return end
	if not UI.handlers[name] then UI.stats.rejected = UI.stats.rejected + 1; return end
	local ok, data = pcall(JsonDecode.decode, json, { max_len = 65536, max_depth = 12 })
	if not ok or type(data) ~= "table" then UI.stats.decode_errors = UI.stats.decode_errors + 1; return end
	UI.handle(name, data)
end

-- handlers are bound by client/main.lua, which owns the module wiring: `h` = { set_mode = fn, camera = module, build = module (placement) }
function UI.register(h)
	local function ok_cb() end
	UI.handlers.ready = function()
		UI.page_ready = true
		UI.send("boot", { preview = false, resource = getResourceName(getThisResource()), version = ctx.config.VERSION })
		triggerServerEvent(NET.ready, resourceRoot)
	end
	UI.handlers.order = function(d) triggerServerEvent(NET.order, resourceRoot, d) end
	UI.handlers.ui = function(d)
		local name = d.name
		if type(name) ~= "string" then return end
		local data = type(d.data) == "table" and d.data or {}
		if name == "select" and h.camera and data.id and data.id ~= "" then h.camera.set_selection({ data.id }, false) end
		triggerServerEvent(NET.ui_action, resourceRoot, name, data)
	end
	UI.handlers.mode = function(d) h.set_mode(d.mode) end
	UI.handlers.mouse = function(d) h.camera.on_mouse(d) end
	UI.handlers.key = function(d) h.camera.on_key(d) end
	UI.handlers.focus = function(d)
		if tonumber(d.x) and tonumber(d.y) then
			local gx, gy = ctx.to_game(tonumber(d.x), tonumber(d.y), 0.0)
			h.camera.focus(gx, gy)
		end
	end
	UI.handlers.place = function(d)
		if d.op == "start" and type(d.bp) == "string" then h.build.start_placing(d.bp)
		elseif d.op == "cancel" then h.build.cancel_placing()
		elseif d.op == "commit" and tonumber(d.x) and tonumber(d.y) then
			triggerServerEvent(NET.order, resourceRoot, { id = "colony", kind = "place_blueprint", target = { bp = d.bp, pos = { x = tonumber(d.x), y = tonumber(d.y), z = 0.0 } } })
		end
	end
	UI.handlers.screen = function(d)
		UI.screen = d.open and (d.name or "screen") or nil
		UI.update_focus()
	end
	UI.handlers.close = function() UI.screen = nil; UI.update_focus() end

	addEvent(NET.browser, false) -- LOCAL only: the server (or another client) cannot trigger it remotely
	addEventHandler(NET.browser, root, on_browser_event)
end

-- ---------------------------------------------------------------------------------------------------------------- creation
local function load_page()
	local url = cfg.ui_url
	local function go() if UI.browser and isElement(UI.browser) then loadBrowserURL(UI.browser, url) end end
	-- a local page is never blocked; this is the mtasa-resources webbrowser flow for the day it is (the player's browser settings)
	if isBrowserDomainBlocked(url, true) then
		requestBrowserDomains({ url }, true, function(accepted) if accepted then go() else ctx.log("warn", "the browser domain request was declined: the UI will not load") end end)
	else
		go()
	end
end

function UI.create()
	if UI.browser then return UI.browser end
	local sw, sh = guiGetScreenSize()
	if cfg.ui_mode == "dx" then
		UI.browser = createBrowser(sw, sh, true, true)
	else
		UI.gui = guiCreateBrowser(0, 0, 1, 1, true, true, true)
		UI.browser = UI.gui and guiGetBrowser(UI.gui) or nil
	end
	if not UI.browser then ctx.log("error", "cannot create the browser (Settings > Web Browser / CEF disabled?)"); return nil end
	addEventHandler("onClientBrowserCreated", UI.browser, function()
		UI.created = true
		load_page()
	end)
	addEventHandler("onClientBrowserDocumentReady", UI.browser, function()
		if UI.ready then return end
		UI.ready = true
		flush_queue()
	end)
	if cfg.ui_mode == "dx" then
		ctx.frame("onClientRender", "ui.draw", function()
			if UI.browser and isElement(UI.browser) and not UI.paused then dxDrawImage(0, 0, sw, sh, UI.browser, 0, 0, 0, tocolor(255, 255, 255, 255), true) end
		end)
		addEventHandler("onClientCursorMove", root, function(_, _, ax, ay) if UI.focus and UI.browser and isElement(UI.browser) then injectBrowserMouseMove(UI.browser, ax, ay) end end)
		addEventHandler("onClientClick", root, function(button, state)
			if not (UI.focus and UI.browser and isElement(UI.browser)) then return end
			if state == "down" then injectBrowserMouseDown(UI.browser, button) else injectBrowserMouseUp(UI.browser, button) end
		end)
		addEventHandler("onClientKey", root, function(key, press)
			if UI.focus and press and UI.browser and isElement(UI.browser) and (key == "mouse_wheel_up" or key == "mouse_wheel_down") then
				injectBrowserMouseWheel(UI.browser, key == "mouse_wheel_up" and 40 or -40, 0)
			end
		end)
	end
	return UI.browser
end

-- ---------------------------------------------------------------------------------------------------------------- input focus
-- the page owns the keyboard and mouse while a colony screen or a modal screen is open; otherwise it is only displayed
function UI.update_focus()
	local want = ctx.colony_mode or UI.screen ~= nil
	if want == UI.focus then return end
	UI.focus = want
	if not UI.browser or not isElement(UI.browser) then return end
	showCursor(want)
	if want then
		focusBrowser(UI.browser)
		guiSetInputMode("no_binds_when_editing")
		toggleAllControls(false)
	else
		focusBrowser(nil)
		guiSetInputMode("allow_binds")
		toggleAllControls(true)
	end
end

-- stop drawing and processing when the game window is minimised (setBrowserRenderingPaused: the MTA wiki warns it can misbehave on low-RAM PCs, so it is only used for that)
function UI.pause(paused)
	UI.paused = paused and true or false
	if UI.browser and isElement(UI.browser) then setBrowserRenderingPaused(UI.browser, UI.paused) end
end

function UI.cleanup()
	if UI.focus then
		UI.focus = false
		showCursor(false)
		if UI.browser and isElement(UI.browser) then focusBrowser(nil) end
		guiSetInputMode("allow_binds")
		toggleAllControls(true)
	end
	UI.screen = nil
	if UI.gui and isElement(UI.gui) then destroyElement(UI.gui) end
	if UI.browser and isElement(UI.browser) then destroyElement(UI.browser) end
	UI.gui, UI.browser, UI.ready, UI.created = nil, nil, false, false
end

ctx.on_cleanup("ui", UI.cleanup)
return UI
