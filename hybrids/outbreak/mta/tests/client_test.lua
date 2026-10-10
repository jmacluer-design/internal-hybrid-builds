-- The REAL client Lua (client/*.lua) in the mock MTA: the CEF bridge, colony camera, placement, noise, survival, the ped driver, ground sampling, world visuals.
local T, H = ...
T.group("client")
local P = require("shared.protocol")
local NET = require("shared.mta_net")

local function C(m) return H.client(m) end
local function mods(m) return H.client(m).modules end
local function cctx(m) return H.creq(m, "client.ctx") end
local function origin(m) return H.sreq(m, "server.ctx").origin end
local function clean(m, what)
	T.eq(#m.errors, 0, (what or "") .. ": errors: " .. H.errors_text(m))
	T.eq(#m.net.bad_payloads, 0, (what or "") .. ": bad payloads: " .. table.concat(m.net.bad_payloads, " | "))
end
-- the page calls the game: a decoded callback arrives as the local event outbreak:ui(name, json)
local function post(m, name, data) return m:browser_trigger(name, data) end
local function enter_colony(m)
	C(m).set_mode("colony")
	m:step(300)
end
local function colonist_peds(m)
	local out = {}
	for _, p in ipairs(m:live("ped")) do if p.data["ob:cid"] then out[#out + 1] = p end end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

-- ------------------------------------------------------------------------------------------------------------------------ the CEF bridge
T.test("ui: the browser is created, loaded only after onClientBrowserCreated, JavaScript runs only after the document is ready, queued messages arrive in order in the right format", function()
	local m = H.boot({ boot = false })
	m:load_side("server"); m:load_side("client")
	m:start_server()
	m:start_client()
	T.eq(m.browser, nil, "no browser before the server has said hello: only the owner gets one, in the mode the server chose")
	m:wait_until(function() return m.browser ~= nil end, 4000)
	local b = m.browser
	T.truthy(b and b.is_local and b.transparent, "a local, transparent browser")
	T.eq(b.type, "webbrowser")
	T.eq(#m:live("gui-browser"), 1, "gui mode is the default: a guiCreateBrowser element")
	T.eq(b.url, nil, "not loaded before it is created")
	m:step(3000)
	T.eq(b.url, "http://mta/local/ui/mta.html")
	T.truthy(b.ready)
	T.eq(#m.errors, 0, "no loadBrowserURL / JavaScript call came too early: " .. H.errors_text(m))
	local order = {}
	for _, msg in ipairs(m:ui_messages()) do order[#order + 1] = msg.action end
	T.truthy(#order > 3, "messages were flushed: " .. table.concat(order, ","))
	local first_catalog, first_state
	for i, a in ipairs(order) do if a == "catalog" and not first_catalog then first_catalog = i end if a == "state" and not first_state then first_state = i end end
	T.truthy(first_catalog and first_state, "catalog and state arrived")
	for _, js in ipairs(m.browser_js) do
		T.truthy(js:find("^window%.dispatchEvent%(new MessageEvent%('message',{data:") and js:find("}%)%)$"), "format: " .. js:sub(1, 70))
	end
	local st = m:ui_messages("state")[1].data
	T.eq(#st.colonists, 4); T.truthy(st.colonists[1].name)
	local cat = m:ui_messages("catalog")[1].data
	T.truthy(cat.items.canned_beans and cat.blueprints.wall)
	clean(m, "ui load")
	m:stop()
end)

T.test("ui: page callbacks reach the server exactly as the FiveM NUI callbacks did (order, ui actions, place commit, ready), through mta.triggerEvent('outbreak:ui', name, json)", function()
	local m = H.boot({})
	local host = H.host(m)
	local n_order = #m:sent("server", NET.order)
	post(m, "order", { id = "c1", kind = "priority", target = { work = "cook", level = 1 } })
	m:step(200)
	local sent = m:sent("server", NET.order)
	T.eq(#sent, n_order + 1)
	local o = sent[#sent].args[1]
	T.eq(o.id, "c1"); T.eq(o.kind, "priority"); T.eq(o.target.work, "cook"); T.eq(o.target.level, 1)
	T.eq(sent[#sent].source, m.resourceRoot, "the source is the resource root")
	local results = m:out_events("order_result")
	T.eq(results[#results].ok, true); T.eq(results[#results].kind, "priority")
	T.eq(host.world:colonist("c1").prio.cook, 1, "the sim has the priority")
	-- ui actions
	local n_ui = #m:sent("server", NET.ui_action)
	post(m, "ui", { name = "set_speed", data = { speed = 4 } })
	post(m, "ui", { name = "request_summary" })
	m:step(300)
	T.eq(#m:sent("server", NET.ui_action), n_ui + 2)
	T.eq(host.speed, 4)
	T.eq(m:sent("server", NET.ui_action)[n_ui + 1].args[1], "set_speed")
	-- the answer of a UI action comes back as a message for the page
	local summaries = m:ui_messages("summary")
	T.gt(#summaries, 0, "request_summary was answered through outbreak:uimsg -> the page")
	-- place commit
	local n2 = #m:sent("server", NET.order)
	post(m, "place", { op = "commit", bp = "wall", x = 30, y = 30 })
	m:step(200)
	local po = m:sent("server", NET.order)[n2 + 1].args[1]
	T.eq(po.kind, "place_blueprint"); T.eq(po.target.bp, "wall"); T.eq(po.target.pos.x, 30)
	-- ready: boot message + a ready event
	local n3 = #m:sent("server", NET.ready)
	post(m, "ready", { v = 1 })
	m:step(200)
	T.eq(#m:sent("server", NET.ready), n3 + 1)
	local boots = m:ui_messages("boot")
	T.eq(boots[#boots].data.resource, "outbreak"); T.eq(boots[#boots].data.preview, false)
	clean(m, "callbacks")
	m:stop()
end)

T.test("ui: only OUR browser may talk to the client: other sources, unknown callbacks, bad or oversized JSON, wrong types are dropped and counted; the event is local-only", function()
	local m = H.boot({})
	local UI = mods(m).UI
	local client = m.sides.client
	local n_order = #m:sent("server", NET.order)
	local before = UI.stats.rejected + UI.stats.decode_errors
	local good = require("shared.json").encode({ id = "c1", kind = "draft", target = true })
	local other_browser = client.env.createBrowser(10, 10, true)
	-- the event is triggered with another browser, the resource root, a ped as source
	for _, src in ipairs({ other_browser, m.resourceRoot, m:live("ped")[1], m.root }) do m:trigger(client, "outbreak:ui", src, "order", good) end
	m:trigger(client, "outbreak:ui", m.browser, "launch_missiles", good)
	m:trigger(client, "outbreak:ui", m.browser, 5, good)
	m:trigger(client, "outbreak:ui", m.browser, "order", 5)
	m:trigger(client, "outbreak:ui", m.browser, "order", "{broken")
	m:trigger(client, "outbreak:ui", m.browser, "order", "[1,2,3]")
	m:trigger(client, "outbreak:ui", m.browser, "order", string.rep("[", 40) .. string.rep("]", 40))
	m:trigger(client, "outbreak:ui", m.browser, "order", '{"a":"' .. string.rep("x", 70000) .. '"}')
	m:trigger(client, "outbreak:ui", m.browser, ("x"):rep(30), good)
	m:step(300)
	T.eq(#m:sent("server", NET.order), n_order, "nothing was forwarded to the server")
	T.eq(UI.stats.rejected + UI.stats.decode_errors - before, 12, "all twelve dropped and counted")
	T.eq(#m.errors, 0, H.errors_text(m))
	-- local only: a server-side remote trigger of outbreak:ui is refused by the engine
	m:send_remote("client", "outbreak:ui", m.resourceRoot, nil, m.player, "order", good)
	m:step(100)
	T.truthy(#m.net.dropped >= 1 and m.net.dropped[#m.net.dropped]:find("not marked as remotely triggerable", 1, true), table.concat(m.net.dropped, "|"))
	m.net.dropped = {}
	m:stop()
end)

T.test("ui: input focus: colony view shows the cursor, focuses the browser, turns the game controls off and binds off while typing; leaving and stopping restore everything", function()
	local m = H.boot({})
	local UI = mods(m).UI
	T.falsy(m.cursor.showing); T.eq(m.input.mode, "allow_binds"); T.truthy(m.input.all_controls)
	enter_colony(m)
	T.truthy(m.cursor.showing); T.eq(m.input.focused_browser, m.browser); T.eq(m.input.mode, "no_binds_when_editing"); T.falsy(m.input.all_controls)
	T.truthy(m.player.frozen)
	post(m, "mode", { mode = "survival" })
	m:step(300)
	T.falsy(m.cursor.showing); T.eq(m.input.focused_browser, nil); T.eq(m.input.mode, "allow_binds"); T.truthy(m.input.all_controls); T.falsy(m.player.frozen)
	-- a modal screen (inventory) also takes focus, even in survival mode
	post(m, "screen", { name = "inventory", open = true })
	T.truthy(m.cursor.showing and not m.input.all_controls)
	post(m, "screen", { name = "inventory", open = false })
	T.falsy(m.cursor.showing); T.truthy(m.input.all_controls)
	-- the page's own mode request (key F6 inside the page) goes through the client too
	post(m, "mode", { mode = "colony" })
	T.truthy(m.cursor.showing)
	-- stop while focused: nothing stays hijacked
	m:stop()
	T.falsy(m.cursor.showing, "cursor hidden"); T.truthy(m.input.all_controls, "controls back"); T.eq(m.input.mode, "allow_binds"); T.eq(m.input.focused_browser, nil)
	T.falsy(m.player.frozen); T.eq(m.cam.matrix_set, false, "the camera is back on the player")
	T.eq(#m:live("webbrowser"), 0); T.eq(#m:live("gui-browser"), 0)
	for _, c in ipairs({ "health", "armour", "breath", "money", "clock", "wanted" }) do T.eq(m.hud[c], true, "HUD part " .. c .. " restored") end
end)

T.test("ui: the dx mode draws the browser every frame and injects mouse input while focused; minimising pauses the browser", function()
	local m = H.boot({ settings = { ui_mode = "dx" } })
	T.eq(m.browser.type, "webbrowser"); T.eq(#m:live("gui-browser"), 0, "createBrowser, not guiCreateBrowser")
	m:step(300)
	T.gt(m.dx.images, 5, "dxDrawImage every frame")
	local b = m.browser
	local env = m.sides.client.env
	m:trigger(m.sides.client, "onClientCursorMove", m.root, 0.5, 0.5, 960, 540)
	T.eq(b.mouse.move, nil, "not injected while the page does not own the mouse")
	enter_colony(m)
	m:trigger(m.sides.client, "onClientCursorMove", m.root, 0.5, 0.5, 960, 540)
	m:trigger(m.sides.client, "onClientClick", m.root, "left", "down", 960, 540)
	m:trigger(m.sides.client, "onClientClick", m.root, "left", "up", 960, 540)
	m:trigger(m.sides.client, "onClientKey", m.root, "mouse_wheel_up", true)
	T.eq(b.mouse.move.x, 960); T.eq(b.mouse.down, "left"); T.eq(b.mouse.up, "left"); T.eq(b.mouse.wheel, 40)
	local images = m.dx.images
	m:trigger(m.sides.client, "onClientMinimize", m.root)
	T.truthy(b.paused)
	m:step(200)
	T.eq(m.dx.images, images, "no drawing while paused")
	m:trigger(m.sides.client, "onClientRestore", m.root)
	T.falsy(b.paused)
	clean(m, "dx")
	m:stop()
end)

T.test("ui: messages pushed before the page is ready are queued with a cap, an unencodable message does not break the pipe, and a destroyed browser is not written to", function()
	local m = H.boot({ boot = false })
	m:load_side("server"); m:load_side("client")
	m:start_client()
	local UI = mods(m).UI
	UI.create()
	for i = 1, 260 do UI.send("toast", { level = "info", text = "t" .. i }) end
	T.eq(#UI.queue, 200, "capped at 200")
	T.eq(UI.stats.dropped, 60)
	local cyc = {}; cyc.self = cyc
	UI.ready = true
	T.falsy(UI.send("toast", cyc), "a cyclic table is refused")
	local json = H.creq(m, "shared.json")
	T.eq(#m.errors, 0, H.errors_text(m))
	UI.ready = false
	m:step(500)
	T.truthy(UI.ready and #UI.queue == 0, "flushed once ready")
	local toasts = m:ui_messages("toast")
	T.eq(toasts[1].data.text, "t61", "the oldest 60 were dropped, the order of the rest is kept")
	m:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ colony camera
T.test("camera: colony mode sets the camera matrix on the focus, freezes the player, reports the focus as the observer; leaving restores everything", function()
	local m = H.boot({})
	local Cam = mods(m).Camera
	local px, py = m.player.x, m.player.y
	enter_colony(m)
	T.truthy(Cam.active and cctx(m).colony_mode)
	T.truthy(m.cam.matrix_set)
	T.near(m.cam.lx, px, 1e-6); T.near(m.cam.ly, py, 1.0)
	T.gt(m.cam.z, m.cam.lz + 30, "the camera is high above the focus")
	T.eq(m.cam.fov, cctx(m).cfg.cam_fov)
	m:step(1500)
	local o = origin(m)
	local states = m:in_events("player_state")
	local last = states[#states]
	T.near(last.pos.x, px - o.x, 1.5, "player_state carries the camera focus in sim space")
	post(m, "mode", { mode = "survival" })
	m:step(300)
	T.falsy(Cam.active); T.falsy(m.cam.matrix_set); T.eq(m.cam.target, m.player); T.falsy(m.player.frozen)
	clean(m, "camera enter/leave")
	m:stop()
end)

T.test("camera: WASD pans along the view direction (shift is faster), Q / E rotate, the wheel zooms within limits, the screen edge pans, the focus is reported to the sim", function()
	local m = H.boot({})
	local Cam = mods(m).Camera
	enter_colony(m)
	local x0, y0 = Cam.f.x, Cam.f.y
	post(m, "key", { k = "w", down = true })
	m:step(1000)
	post(m, "key", { k = "w", down = false })
	T.gt(Cam.f.y - y0, 20, "W moves north along yaw 0")
	T.near(Cam.f.x, x0, 1.0)
	local d_normal = Cam.f.y - y0
	post(m, "key", { k = "shift", down = true }); post(m, "key", { k = "w", down = true })
	local y1 = Cam.f.y
	m:step(1000)
	post(m, "key", { k = "w", down = false }); post(m, "key", { k = "shift", down = false })
	T.gt(Cam.f.y - y1, d_normal * 1.8, "shift pans about 2.4x faster")
	local yaw0 = Cam.yaw
	post(m, "key", { k = "q", down = true }); m:step(500); post(m, "key", { k = "q", down = false })
	T.ne(Cam.yaw, yaw0, "Q rotates")
	for _ = 1, 40 do post(m, "mouse", { type = "wheel", x = 0.5, y = 0.5, dy = 1 }) end
	T.eq(Cam.h, cctx(m).cfg.cam_max_h, "zoom out is capped")
	for _ = 1, 80 do post(m, "mouse", { type = "wheel", x = 0.5, y = 0.5, dy = -1 }) end
	T.eq(Cam.h, cctx(m).cfg.cam_min_h, "zoom in is capped")
	-- edge pan: the mouse at the left edge moves the focus left (relative to yaw)
	Cam.yaw = 0
	local xe = Cam.f.x
	post(m, "mouse", { type = "move", x = 0.001, y = 0.5 })
	m:step(500)
	T.lt(Cam.f.x, xe, "edge pan")
	post(m, "mouse", { type = "move", x = 0.5, y = 0.5 })
	-- unknown keys are ignored, a key still held when the window loses focus is released by the page (key up arrives)
	post(m, "key", { k = "Enter", down = true })
	T.eq(Cam.keys.Enter, nil)
	m:step(1500)
	local states = m:in_events("player_state")
	local o = origin(m)
	T.near(states[#states].pos.x, Cam.f.x - o.x, 2.0)
	clean(m, "camera pan")
	m:stop()
end)

T.test("camera: click selects the colonist under the cursor, shift-click adds, an empty click clears, a drag box selects everyone inside; the selection goes to the page", function()
	local m = H.boot({})
	local Cam = mods(m).Camera
	enter_colony(m)
	Cam.h = 40; Cam.apply()
	local peds = colonist_peds(m)
	T.eq(#peds, 4)
	-- bring the colonists in front of the camera on a line, 5 m apart
	for i, p in ipairs(peds) do p.x, p.y, p.z = Cam.f.x - 7.5 + (i - 1) * 5, Cam.f.y, Cam.f.z + 1.0 end
	local function screen_of(p)
		local sx, sy = m.sides.client.env.getScreenFromWorldPosition(p.x, p.y, p.z)
		return sx / m.screen.w, sy / m.screen.h
	end
	local sx, sy = screen_of(peds[2])
	post(m, "mouse", { type = "down", x = sx, y = sy, button = 0 }); post(m, "mouse", { type = "up", x = sx, y = sy, button = 0 })
	local sel = m:ui_messages("selection")
	T.eq(#sel, 1); T.eq(sel[1].data.ids[1], peds[2].data["ob:cid"])
	local sx3, sy3 = screen_of(peds[3])
	post(m, "mouse", { type = "down", x = sx3, y = sy3, button = 0, shift = true }); post(m, "mouse", { type = "up", x = sx3, y = sy3, button = 0, shift = true })
	sel = m:ui_messages("selection")
	T.eq(#sel[#sel].data.ids, 2, "shift adds")
	-- empty ground clears
	post(m, "mouse", { type = "down", x = 0.9, y = 0.9, button = 0 }); post(m, "mouse", { type = "up", x = 0.9, y = 0.9, button = 0 })
	T.eq(#m:ui_messages("selection")[#m:ui_messages("selection")].data.ids, 0)
	-- a box around the first three
	local ax, ay = screen_of(peds[1])
	local bx, by = screen_of(peds[3])
	post(m, "mouse", { type = "down", x = ax - 0.03, y = ay - 0.05, button = 0 }); post(m, "mouse", { type = "up", x = bx + 0.03, y = by + 0.05, button = 0 })
	sel = m:ui_messages("selection")
	T.eq(#sel[#sel].data.ids, 3, "the box holds three colonists")
	T.eq(Cam.stats.boxes, 1)
	-- the page's own select call tells the server which colonist is shown on the card
	local n = #m:sent("server", NET.ui_action)
	post(m, "ui", { name = "select", data = { id = peds[2].data["ob:cid"] } })
	T.eq(Cam.selected[1], peds[2].data["ob:cid"])
	clean(m, "selection")
	m:stop()
end)

T.test("camera: a right click orders the selection to the ground point under the cursor (sim coordinates, a 3-wide formation), draws a ping, the colonist walks there", function()
	local m = H.boot({})
	local Cam = mods(m).Camera
	enter_colony(m)
	Cam.set_selection({ "c1", "c2" }, false)
	local gx, gy, gz = Cam.ground_at(0.5, 0.5)
	T.truthy(gx, "the screen centre hits the ground")
	T.near(gx, Cam.f.x, 3.0); T.near(gy, Cam.f.y, 3.0)
	T.near(gz, H.Mock.terrain(gx, gy), 1.5)
	local n = #m:sent("server", NET.order)
	post(m, "mouse", { type = "context", x = 0.5, y = 0.5, button = 2 })
	m:step(300)
	local orders = m:sent("server", NET.order)
	T.eq(#orders, n + 2, "one goto per selected colonist")
	local o = origin(m)
	local a, b = orders[n + 1].args[1], orders[n + 2].args[1]
	T.eq(a.kind, "goto"); T.eq(a.id, "c1"); T.eq(b.id, "c2")
	T.near(a.target.x, gx - o.x, 0.01); T.near(a.target.y, gy - o.y, 0.01)
	T.near(b.target.x, gx - o.x + 2.2, 0.01, "the second colonist stands beside the first")
	local results = m:out_events("order_result")
	local gotos = 0
	for _, e in ipairs(results) do if e.kind == "goto" and e.ok then gotos = gotos + 1 end end
	T.eq(gotos, 2, "the sim accepted both orders")
	local lines = m.dx.lines
	m:step(200)
	T.gt(m.dx.lines, lines, "a ping and selection rings are drawn")
	-- no ground under the cursor (looking at the sky): the plane fallback keeps it working, no error
	Cam.pitch = -10; Cam.apply()
	T.no_throw(function() Cam.ground_at(0.5, 0.05) end)
	clean(m, "orders")
	m:stop()
end)

T.test("placement: the page starts it, a ghost object follows the cursor snapped to the grid, is outlined green / red by the shared rules, a click sends the order, right click cancels", function()
	local m = H.boot({})
	local Cam = mods(m).Camera
	local Pl = mods(m).Placement
	enter_colony(m)
	m:step(1500) -- the UI state arrives (the placement rules need the buildings list)
	post(m, "place", { op = "start", bp = "wall" })
	T.truthy(cctx(m).placing)
	post(m, "mouse", { type = "move", x = 0.5, y = 0.5 })
	m:step(300)
	local pl = cctx(m).placing
	T.truthy(pl.ghost and not pl.ghost.destroyed, "a ghost object")
	T.eq(pl.ghost.collisions, false); T.eq(pl.ghost.alpha, 150); T.eq(pl.ghost.created_by, "client", "the preview is local to the owner")
	local o = origin(m)
	local grid = cctx(m).cfg.grid
	T.near(pl.pos.x % grid, 0, 1e-6, "snapped to the grid"); T.near(pl.pos.y % grid, 0, 1e-6)
	T.near(pl.ghost.x, pl.pos.x + o.x, 1e-6)
	local lines = m.dx.lines
	m:step(100)
	T.gt(m.dx.lines, lines, "the outline is drawn every frame")
	-- the camera focus is on the base: placing near the base centre may be 'blocked' by the start buildings or valid; find the reported state
	local places = m:ui_messages("place")
	T.truthy(#places >= 1 and places[#places].data.bp == "wall", "the page was told ok / reason")
	-- move far from the base: too_far
	local far = { type = "move", x = 0.5, y = 0.5 }
	Cam.f.x = Cam.f.x + 400; Cam.apply()
	post(m, "mouse", { type = "move", x = 0.5, y = 0.5 })
	m:step(300)
	T.eq(pl.ok, false); T.eq(pl.reason, "too_far")
	local n = #m:sent("server", NET.order)
	post(m, "mouse", { type = "down", x = 0.5, y = 0.5, button = 0 }); post(m, "mouse", { type = "up", x = 0.5, y = 0.5, button = 0 })
	m:step(200)
	T.eq(#m:sent("server", NET.order), n, "an invalid spot sends nothing")
	local toasts = m:ui_messages("toast")
	T.truthy(toasts[#toasts].data.text:find("Cannot build here", 1, true))
	-- back to the base: valid -> click sends the order and ends placement (no shift)
	Cam.f.x = Cam.f.x - 400; Cam.apply()
	Cam.f.x, Cam.f.y = Cam.f.x + 26, Cam.f.y + 22; Cam.apply()
	post(m, "mouse", { type = "move", x = 0.5, y = 0.5 })
	m:step(300)
	T.eq(pl.ok, true, "valid near the base: " .. tostring(pl.reason))
	post(m, "mouse", { type = "down", x = 0.5, y = 0.5, button = 0 }); post(m, "mouse", { type = "up", x = 0.5, y = 0.5, button = 0 })
	m:step(300)
	local sent = m:sent("server", NET.order)
	T.eq(sent[#sent].args[1].kind, "place_blueprint"); T.eq(sent[#sent].args[1].target.bp, "wall")
	T.eq(cctx(m).placing, nil, "placement ended")
	T.truthy(pl.ghost.destroyed, "the ghost was destroyed")
	-- right click cancels
	post(m, "place", { op = "start", bp = "bed" })
	post(m, "mouse", { type = "move", x = 0.5, y = 0.5 })
	m:step(200)
	local g = cctx(m).placing.ghost
	post(m, "mouse", { type = "down", x = 0.5, y = 0.5, button = 2 }); post(m, "mouse", { type = "up", x = 0.5, y = 0.5, button = 2 })
	post(m, "mouse", { type = "context", x = 0.5, y = 0.5, button = 2 })
	T.eq(cctx(m).placing, nil); T.truthy(g.destroyed)
	-- leaving colony view cancels a running placement
	post(m, "place", { op = "start", bp = "bed" }); post(m, "mouse", { type = "move", x = 0.5, y = 0.5 }); m:step(200)
	local g2 = cctx(m).placing.ghost
	post(m, "mode", { mode = "survival" })
	T.eq(cctx(m).placing, nil); T.truthy(g2.destroyed)
	T.eq(#m:live("object") - 4, #m:live("object") - 4)
	clean(m, "placement")
	m:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ noise
T.test("noise: gunshots, silenced shots, shotguns, rifles, explosions, vehicles, sprinting, melee, shots by other peds: the right loudness at the right sim position, throttled", function()
	local m = H.boot({})
	local o = origin(m)
	m:player_move_to(o.x + 100, o.y + 50)
	m:step(100)
	local function noises() return m:in_events("noise") end
	local function last() local n = noises(); return n[#n] end
	local function shot(weapon) m:player_fire(weapon); m:step(300); m:step(600) end
	local n0 = #noises()
	shot(22); m:step(400)
	T.eq(last().kind, "gunshot"); T.eq(last().loudness, 110); T.near(last().pos.x, 100, 0.5); T.near(last().pos.y, 50, 0.5)
	shot(23); m:step(400)
	T.eq(last().loudness, 110 * 0.35, "a silenced pistol is quiet")
	shot(25); m:step(400); T.eq(last().kind, "shotgun"); T.eq(last().loudness, 140)
	shot(31); m:step(400); T.eq(last().kind, "rifle"); T.eq(last().loudness, 150)
	shot(99); m:step(400); T.eq(last().kind, "gunshot", "an unknown weapon id is a generic gunshot")
	-- throttle: two shots 100 ms apart are one noise
	local n = #noises()
	m:player_fire(22); m:step(100); m:player_fire(22); m:step(600)
	T.eq(#noises(), n + 1, "throttled to one per 250 ms")
	-- other peds' shots and explosions
	m:ped_fire(m:live("ped")[1], 30); m:step(600)
	T.eq(last().kind, "ped_rifle")
	m:explosion(o.x + 100, o.y + 50, 20); m:step(600)
	T.eq(last().kind, "explosion"); T.eq(last().loudness, 200)
	-- other players' shots do not count as ours
	local before = #noises()
	m:trigger(m.sides.client, "onClientPlayerWeaponFire", m:add_player("Other"), 22, 1, 1, 0, 0, 0, nil)
	m:step(600)
	T.eq(#noises(), before)
	-- sprint, melee, vehicle
	m.player_move_state = "sprint"; m:step(700); T.eq(last().kind, "sprint"); T.eq(last().loudness, 8)
	m.player_move_state = "stand"
	m.player.weapon_slot = 0; m.player_control.fire = true; m:step(700); T.eq(last().kind, "melee"); m.player_control.fire = nil
	m.player.vehicle = { }; m.vehicle_state = { siren = true }
	m.player.vehicle = m:new_element("vehicle", {}, m.root)
	m:step(700); T.eq(last().kind, "siren"); T.eq(last().loudness, 70)
	m.vehicle_state = { siren = false }; m.player_control.horn = true; m:step(1800); T.eq(last().kind, "horn"); m.player_control.horn = nil
	m.player.vehicle.vx = 0.2; m:step(3200)
	T.eq(last().kind, "vehicle", "a vehicle above ~6 m/s")
	m.player.vehicle = nil
	-- every noise passes the server's sanitizer and reaches the sim: the sim's own log records them
	for _, e in ipairs(noises()) do T.truthy(P.sanitize_in(e), "valid IN event: " .. tostring(e.kind)) end
	T.gt(#noises(), n0 + 8)
	clean(m, "noise")
	m:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ survival
T.test("survival: the position is reported about once a second and whenever the player moved more than 20 units; the survival effects lock sprint and make the player limp", function()
	local m = H.boot({})
	local o = origin(m)
	m:step(3000)
	local n = #m:in_events("player_state")
	m:step(3500)
	local n2 = #m:in_events("player_state")
	T.ge(n2 - n, 3); T.le(n2 - n, 5, "about one per second when standing still")
	m:player_move_to(o.x + 80, o.y)
	m:step(400)
	local states = m:in_events("player_state")
	T.near(states[#states].pos.x, 80, 1.0, "a big move is reported at once")
	T.eq(states[#states].moving, true)
	-- effects
	T.eq(m.input.controls.sprint, true)
	H.host(m):debug("survival", { fatigue = 99 })
	m:step(1500)
	T.eq(m.input.controls.sprint, false, "exhausted: sprint locked")
	T.eq(m.player.walk_style, 0)
	H.host(m):debug("survival", { fatigue = 10, hp = 10 })
	m:step(1500)
	T.eq(m.player.walk_style, H.creq(m, "shared.mta_config").limp_walk, "badly hurt: limping")
	T.eq(m.input.controls.sprint, false, "and below 20 hp sprinting is locked too")
	clean(m, "survival fx")
	m:stop()
	T.eq(m.player.walk_style, 0, "the walking style is restored on stop")
end)

T.test("survival: damage the GAME dealt (fall, bullet, explosion, fire, melee) is reported with the right kind; zombie bites never come through here; colony view cancels damage", function()
	local m = H.boot({})
	local function dmgs() return m:in_events("player_damage") end
	m:damage_player(15, 54); m:step(400)
	T.eq(#dmgs(), 1); T.eq(dmgs()[1].kind, "fall"); T.eq(dmgs()[1].amount, 15)
	m:damage_player(20, 24); m:damage_player(5, 51); m:damage_player(3, 37); m:damage_player(4, 4); m:damage_player(2, 0)
	m:step(400)
	local kinds = {}
	for i = 2, #dmgs() do kinds[#kinds + 1] = dmgs()[i].kind end
	T.eq(table.concat(kinds, ","), "bullet,explosion,fire,cut,blunt")
	for _, e in ipairs(dmgs()) do T.truthy(P.sanitize_in(e) == nil, "player_damage is its own host path, not a sim IN event") end
	local hp = H.host(m).survival.c.hp
	T.lt(hp, 100)
	enter_colony(m)
	local n = #dmgs()
	local passed = m:damage_player(50, 22)
	T.falsy(passed, "the event was cancelled in colony view")
	m:step(400)
	T.eq(#dmgs(), n, "nothing was reported")
	T.gt(H.host(m).survival.c.hp, hp - 5, "the player's body did not take the 50 damage (only slow bleeding may have ticked)")
	clean(m, "damage")
	m:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ the ped driver
-- (the rules are slothbot's, see client/driver.lua and THIRD_PARTY.md: the tests pin each of them)
local function new_ped(m, x, y)
	local ped = m.sides.server.env.createPed(7, x, y, H.Mock.terrain(x, y) + 1.0)
	ped.syncer = m.player
	ped.data.ob = "zombie" -- one of ours (what server/peds.lua sets)
	return ped
end
local function drive(m, intent) m:send_remote("client", NET.drive, m.resourceRoot, nil, m.player, { intent }); m:step(150) end
-- value: a number (clamped into the asked range) or a function(a, b) -> number
local function force_random(m, value)
	m.sides.client.env.math.random = function(a, b)
		if a == nil then return 0.5 end
		local v = type(value) == "function" and value(a, b) or value
		return math.max(a, math.min(b or a, v))
	end
end
local function dist(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

T.test("driver: a go intent turns the ped toward the target, holds forwards (walk / jog / sprint by speed) and clears the controls on arrival; stop clears at once", function()
	local m = H.boot({})
	local o = origin(m)
	m:player_move_to(o.x, o.y)
	local ped = new_ped(m, o.x + 10, o.y + 10)
	drive(m, { ped = ped, m = "go", x = o.x + 10, y = o.y + 40, s = 1, r = 1.5 })
	T.eq(ped.controls.forwards, true); T.eq(ped.controls.walk, true); T.falsy(ped.controls.sprint)
	T.near(ped.rz, 0, 1.0, "facing north (+y)")
	m:step(3000)
	T.gt(ped.y, o.y + 14, "walked north (and was not taken for stuck while walking: " .. mods(m).Driver.stats.stuck .. " stuck checks)")
	drive(m, { ped = ped, m = "go", x = o.x - 20, y = ped.y, s = 3, r = 1.5 })
	T.eq(ped.controls.sprint, true); T.falsy(ped.controls.walk)
	T.near(ped.rz, 90, 2.0, "facing west: rotation 90 turns left from north")
	drive(m, { ped = ped, m = "go", x = o.x - 20, y = ped.y, s = 2, r = 1.5 })
	T.falsy(ped.controls.walk); T.falsy(ped.controls.sprint); T.eq(ped.controls.forwards, true)
	-- arrival
	m:wait_until(function() return not ped.controls.forwards end, 15000)
	T.falsy(ped.controls.forwards, "stopped on arrival")
	T.lt(math.sqrt((ped.x - (o.x - 20)) ^ 2 + (ped.y - ped.y) ^ 2), 3.0)
	local D = mods(m).Driver
	T.gt(D.stats.arrived, 0)
	drive(m, { ped = ped, m = "go", x = o.x + 100, y = o.y, s = 2, r = 1.5 })
	T.eq(ped.controls.forwards, true)
	drive(m, { ped = ped, m = "stop" })
	T.falsy(ped.controls.forwards); T.eq(D.intents[ped], nil, "the intent is gone")
	clean(m, "driver go")
	m:stop()
end)

T.test("driver: the same order again (the server refreshes a chase every second) keeps the running state; a different order replaces it", function()
	local m = H.boot({})
	local D = mods(m).Driver
	local o = origin(m)
	m:player_move_to(o.x, o.y)
	local z, target = new_ped(m, o.x + 20, o.y), new_ped(m, o.x + 20, o.y + 40)
	drive(m, { ped = z, m = "attack", x = target.x, y = target.y, tgt = target, s = 2, r = 1.0 })
	local first = D.intents[z]
	first.swing_t = 12345; first.seen = { x = 1, y = 2, z = 3 }
	drive(m, { ped = z, m = "attack", x = target.x + 3, y = target.y, tgt = target, s = 3, r = 1.0 })
	T.eq(D.intents[z], first, "same mode and target: the same intent table")
	T.eq(first.swing_t, 12345); T.eq(first.s, 3); T.near(first.x, target.x + 3, 0.01)
	local count = D.count
	drive(m, { ped = z, m = "go", x = o.x, y = o.y, s = 2, r = 1.0 })
	T.ne(D.intents[z], first, "another mode: a new intent")
	T.eq(D.count, count, "(and the ped is still counted once)")
	clean(m, "driver refresh")
	m:stop()
end)

T.test("driver: intents come over the network and are validated: non-tables, destroyed or non-ped elements, unknown modes, NaN coordinates, bad targets are ignored; dead or not streamed-in peds are not driven; a ped synced by another client still gets its control states", function()
	local m = H.boot({})
	local D = mods(m).Driver
	local o = origin(m)
	m:player_move_to(o.x, o.y)
	local ped = new_ped(m, o.x + 10, o.y)
	local obj = m.sides.server.env.createObject(1448, o.x, o.y, 20)
	local dead = new_ped(m, o.x + 12, o.y)
	local rejected = D.stats.rejected
	m:send_remote("client", NET.drive, m.resourceRoot, nil, m.player, { 5, "x", { ped = obj, m = "go", x = 1, y = 1 }, { ped = ped, m = "teleport" }, { ped = ped, m = "go", x = "a", y = 1 },
		{ ped = ped, m = "go", x = 1, y = 1, tgt = 5 }, { m = "go" } })
	m:send_remote("client", NET.drive, m.resourceRoot, nil, m.player, "not a list")
	m:step(200)
	T.eq(D.stats.rejected - rejected, 7); T.eq(D.intents[ped], nil); T.eq(D.intents[obj], nil)
	-- a spoofed source: the handler only accepts the resource root
	m:send_remote("client", NET.drive, m.player, nil, m.player, { { ped = ped, m = "go", x = o.x, y = o.y + 30, s = 2 } })
	m:step(200)
	T.eq(D.intents[ped], nil, "a drive event whose source is not the resource root is dropped")
	drive(m, { ped = ped, m = "go", x = o.x, y = o.y + 30, s = 2 })
	T.truthy(D.intents[ped])
	-- slothbot sets the control states on every client that has the ped; only the syncer's take effect on the movement, so there is no syncer check
	local synced_elsewhere = new_ped(m, o.x + 8, o.y)
	synced_elsewhere.syncer = m:add_player("Other")
	drive(m, { ped = synced_elsewhere, m = "go", x = o.x, y = o.y + 30, s = 2 })
	T.eq(synced_elsewhere.controls.forwards, true, "a ped another client syncs still gets its control states")
	ped.x = o.x + 5000
	ped.controls = {}
	m:step(500)
	T.falsy(ped.controls.forwards, "a ped that is not streamed in is not driven")
	ped.x = o.x + 10
	m:damage_ped(ped, 500)
	m:step(500)
	T.eq(D.intents[ped], nil, "the intent of a dead ped is dropped")
	-- a reset batch clears every driven ped's controls
	local p2 = new_ped(m, o.x + 3, o.y)
	drive(m, { ped = p2, m = "go", x = o.x, y = o.y + 50, s = 2 })
	T.eq(p2.controls.forwards, true)
	m:send_remote("client", NET.events, m.resourceRoot, nil, m.player, { seq = 999, t = 0, reset = true, events = {} })
	m:step(200)
	T.falsy(p2.controls.forwards); T.eq(D.intents[p2], nil)
	clean(m, "driver validation")
	m:stop()
end)

T.test("driver: wander picks headings and pauses; a ranged attack walks to its weapon's firing distance, stands, aims and fires in that weapon's bursts; flee runs; aim holds a target", function()
	local m = H.boot({})
	local D = mods(m).Driver
	local o = origin(m)
	m:player_move_to(o.x, o.y)
	local w = new_ped(m, o.x + 20, o.y + 20)
	drive(m, { ped = w, m = "wander", s = 1 })
	local headings = {}
	for _ = 1, 40 do m:step(1000); headings[math.floor(w.rz / 20)] = true end
	local n = 0
	for _ in pairs(headings) do n = n + 1 end
	T.gt(n, 2, "it turns to different headings over time")
	T.gt(w.walked or 0, 5, "and walks")
	-- ranged attack with a pistol (slot 2: stands still within 14 m, engages within 35 m, bursts of 2.1 to 5.5 s)
	local shooter, target = new_ped(m, o.x + 40, o.y), new_ped(m, o.x + 40, o.y + 30)
	m.sides.server.env.giveWeapon(shooter, 22, 100, true)
	T.eq(shooter.weapon_slot, 2)
	drive(m, { ped = shooter, m = "attack", x = target.x, y = target.y, tgt = target, ranged = true, s = 2, r = 12.0 })
	T.truthy(shooter.aim and math.abs(shooter.aim.y - target.y) < 1.5, "aimed at the target (setPedAimTarget)")
	local fired, longest, run = 0, 0, 0
	for _ = 1, 200 do
		m:step(100)
		if shooter.controls.fire then fired = fired + 1; run = run + 1; longest = math.max(longest, run) else run = 0 end
	end
	T.gt(fired, 5, "it fired")
	T.ge(longest, 18, "in a burst of at least about 2 s (" .. longest .. " steps)")
	T.lt(fired, 190, "with pauses between the bursts")
	T.gt(D.stats.shots, 0)
	-- it stopped at the slot's distance (14 m), not at the intent's radius
	m:wait_until(function() return dist(shooter, target) <= 14.5 end, 20000)
	m:step(1000)
	T.falsy(shooter.controls.forwards, "stopped to shoot at 14 m")
	T.le(dist(shooter, target), 14.5)
	T.gt(dist(shooter, target), 10.0, "(not at the intent's 12 m radius: the weapon slot decides)")
	-- flee: sprint away, finishes at the target point
	local f = new_ped(m, o.x, o.y + 60)
	drive(m, { ped = f, m = "flee", x = o.x - 40, y = o.y + 60, s = 3, r = 2 })
	T.eq(f.controls.sprint, true)
	-- aim: holds a target without walking
	local a = new_ped(m, o.x + 80, o.y)
	local t2 = new_ped(m, o.x + 80, o.y + 10)
	drive(m, { ped = a, m = "aim", tgt = t2 })
	T.falsy(a.controls.forwards); T.truthy(a.aim and math.abs(a.aim.y - t2.y) < 1.0)
	clean(m, "driver modes")
	m:stop()
end)

T.test("driver: the melee swing is slothbot's: within 2 m the ped stands still and jabs (fire on at 0, 800, 1400 ms for 300 ms each), walks on at 2000 ms and swings again at 2300 ms", function()
	local m = H.boot({})
	local D = mods(m).Driver
	-- the pure timeline
	for _, c in ipairs({ { 0, true, true }, { 299, true, true }, { 300, false, true }, { 799, false, true }, { 800, true, true }, { 1100, false, true }, { 1399, false, true }, { 1400, true, true }, { 1700, false, true },
		{ 1999, false, true }, { 2000, false, false }, { 2299, false, false } }) do
		local fire, hold = D.swing_state(c[1])
		T.eq(fire, c[2], "fire at " .. c[1] .. " ms"); T.eq(hold, c[3], "standing still at " .. c[1] .. " ms")
	end
	local o = origin(m)
	m:player_move_to(o.x, o.y)
	local z, target = new_ped(m, o.x + 20, o.y), new_ped(m, o.x + 20, o.y + 1.2)
	drive(m, { ped = z, m = "attack", x = target.x, y = target.y, tgt = target, s = 2, r = 1.0 })
	local fires, forwards, walked_at_1800 = {}, {}, nil
	for i = 1, 60 do
		m:step(50)
		fires[#fires + 1] = z.controls.fire and true or false
		forwards[#forwards + 1] = z.controls.forwards and true or false
		if i == 36 then walked_at_1800 = z.walked end
	end
	T.gt(D.stats.swings, 0, "a swing started")
	local jabs, was = 0, false
	for _, f in ipairs(fires) do if f and not was then jabs = jabs + 1 end was = f end
	T.ge(jabs, 3, "three jabs in about 3 s (" .. jabs .. ")")
	local still = 0
	for i = 1, 36 do if not forwards[i] then still = still + 1 end end
	T.ge(still, 30, "standing still while it jabs (" .. still .. " of the first 36 steps)")
	T.eq(walked_at_1800, nil, "and it did not walk into the target while jabbing")
	clean(m, "swing")
	m:stop()
end)

T.test("driver: chasing a target it can see it faces it; behind a wall it runs to the spot it last saw it at, and gives up there", function()
	local m = H.boot({})
	local D = mods(m).Driver
	local o = origin(m)
	m:player_move_to(o.x, o.y)
	local z, target = new_ped(m, o.x + 20, o.y), new_ped(m, o.x + 20, o.y + 40)
	drive(m, { ped = z, m = "attack", x = target.x, y = target.y, tgt = target, s = 2, r = 1.0 })
	m:step(900)
	T.near(z.rz, 0, 3.0, "facing the target (north) while it is in sight")
	local it = D.intents[z]
	T.truthy(it and it.seen and math.abs(it.seen.y - target.y) < 0.5, "it remembers where it saw it")
	local seen_y = it.seen.y
	-- walls come between them (one in front of the zombie, one behind the last seen spot), the target walks off behind the far one
	m.walls = { { o.x + 10, o.y + 20, o.x + 30, o.y + 21 }, { o.x + 10, o.y + 50, o.x + 30, o.y + 51 } }
	m:step(700)
	T.truthy(D.stats.los_blocked > 0, "the line of sight is blocked")
	target.x, target.y = o.x + 20, o.y + 80
	m:step(1000)
	T.near(it.seen.y, seen_y, 0.5, "it still remembers the OLD spot, not the target's new one")
	T.near(z.rz, 0, 3.0, "and keeps facing it")
	-- standing at the last seen spot with nobody in sight: gives up (the server sends a new order if it still wants the chase)
	z.x, z.y = o.x + 20, seen_y - 3.0
	z.controls = {}
	m:step(1500)
	T.eq(D.intents[z], nil, "gave up at the last seen spot")
	T.gt(D.stats.gave_up, 0)
	T.falsy(z.controls.forwards)
	clean(m, "line of sight")
	m:stop()
end)

T.test("driver: a ped that is blocked by a wall jumps and side-steps (the stuck detector) instead of pushing forever", function()
	local m = H.boot({})
	local D = mods(m).Driver
	local o = origin(m)
	m:player_move_to(o.x, o.y)
	m.walls = { { o.x + 5, o.y + 14, o.x + 9, o.y + 16 } } -- a thin wall across the way, 4 m wide
	-- the dice: a turn (roll 13 of 13) to the east (heading 270), which is how a real ped gets around a short wall
	force_random(m, function(a, b) if b == 13 then return 13 end if b == 360 then return 270 end return a end)
	local ped = new_ped(m, o.x + 7, o.y + 11)
	drive(m, { ped = ped, m = "go", x = o.x + 7, y = o.y + 30, s = 2, r = 1.5 })
	m:step(9000)
	T.gt(D.stats.stuck, 0, "the stuck detector fired")
	T.gt(ped.y, o.y + 16, "and got around the wall after the turn (y " .. string.format("%.1f", ped.y - o.y) .. ")")
	clean(m, "stuck")
	m:stop()
end)

T.test("driver: what a stuck ped does is slothbot's die: seeing its target it only jumps; otherwise 1 in 7 gives up, 2-3 jump, 4-7 turn to a random heading and walk on for 1.2 s (1 in 13 / 5 in 13 / 7 in 13 when walking to a point)", function()
	local m = H.boot({})
	local D = mods(m).Driver
	local env = m.sides.client.env
	for roll = 1, 7 do
		force_random(m, roll)
		T.eq(D.stuck_decision(false, 7), (roll == 1) and "give_up" or (roll < 4 and "jump" or "turn"), "roll " .. roll .. " of 7")
	end
	for roll = 1, 13 do
		force_random(m, roll)
		T.eq(D.stuck_decision(false, 13), (roll == 1) and "give_up" or (roll < 7 and "jump" or "turn"), "roll " .. roll .. " of 13")
	end
	force_random(m, 1)
	T.eq(D.stuck_decision(true, 7), "jump", "a visible target: always a jump")
	-- the whole path in the world: blocked and told to turn: the heading changes and the ped holds it for 1.2 s
	force_random(m, function(a, b) if b == 13 then return 13 end return 200 end)
	local o = origin(m)
	m:player_move_to(o.x, o.y)
	m.walls = { { o.x - 50, o.y + 14, o.x + 50, o.y + 16 } }
	local ped = new_ped(m, o.x, o.y + 12)
	drive(m, { ped = ped, m = "go", x = o.x, y = o.y + 30, s = 2, r = 1.5 })
	m:step(2500)
	T.gt(D.stats.stuck, 0)
	local it = D.intents[ped]
	T.truthy(it and it.hold_until and it.hold_until > 0, "a random turn was taken and is being walked off")
	T.near(ped.rz, 200, 2.0, "the heading is the rolled angle")
	clean(m, "stuck dice")
	m:stop()
end)

T.test("driver: a jump with a melee or heavy weapon in hand swaps to fists for 850 ms first (the jump does not work otherwise); the jump control is released after 800 ms", function()
	local m = H.boot({})
	local D = mods(m).Driver
	local o = origin(m)
	m:player_move_to(o.x, o.y)
	m.walls = { { o.x - 50, o.y + 14, o.x + 50, o.y + 16 } }
	local ped = new_ped(m, o.x, o.y + 12)
	m.sides.server.env.giveWeapon(ped, 5, 1, true) -- a baseball bat: slot 1
	T.eq(ped.weapon_slot, 1)
	force_random(m, 2) -- a roll that jumps
	drive(m, { ped = ped, m = "go", x = o.x, y = o.y + 30, s = 2, r = 1.5 })
	local swapped, restored, jump_on, jump_off = false, false, nil, nil
	for _ = 1, 100 do
		m:step(50)
		if ped.weapon_slot == 0 then swapped = true end
		if swapped and ped.weapon_slot == 1 then restored = true end
		if ped.controls.jump and not jump_on then
			jump_on = m.t
			ped.x, ped.y = o.x + 80, o.y + 22 -- free of the wall now: no second stuck check re-triggers the jump
		end
		if jump_on and not ped.controls.jump and not jump_off then jump_off = m.t end
	end
	T.truthy(swapped, "fists in hand for the jump")
	T.truthy(restored, "the bat is back afterwards")
	T.truthy(jump_on and jump_off and jump_off - jump_on >= 750 and jump_off - jump_on <= 1000, "jump held about 800 ms (" .. tostring(jump_off and jump_on and (jump_off - jump_on)) .. ")")
	clean(m, "jump slot")
	m:stop()
end)

T.test("driver: a ped of ours that streams in loses nothing: its controls are re-asserted, its voice is silenced, and an armed one asks the server for its weapon again (never more than 5 times)", function()
	local m = H.boot({})
	local D = mods(m).Driver
	local o = origin(m)
	m:player_move_to(o.x, o.y)
	local Peds = H.sreq(m, "server.peds")
	local ped = Peds.create("raider", { 100 }, o.x + 30, o.y, 0.0, "r1")
	T.truthy(ped)
	Peds.give_weapon(ped, 22, 50, true)
	T.eq(ped.data.ob, "raider"); T.eq(ped.data.obw, 22)
	m:step(300) -- streamed in at the start
	T.truthy(ped.voice and ped.voice[1] == "PED_TYPE_DISABLED", "setPedVoice(ped, PED_TYPE_DISABLED)")
	local base = D.stats.stream_in
	T.ge(base, 1)
	local asks = #m:sent("server", NET.stream)
	T.ge(asks, 1, "the client asked for the weapon")
	m:step(500)
	T.gt(ped.weapons[22], 50, "and the server gave it again (ammo went up)")
	-- out and in again: another ask, controls re-asserted
	drive(m, { ped = ped, m = "go", x = o.x, y = o.y + 80, s = 2, r = 1.5 })
	T.eq(ped.controls.forwards, true)
	for _ = 1, 8 do
		m:player_move_to(o.x + 5000, o.y); m:step(200)
		ped.controls = {}
		m:player_move_to(o.x, o.y); m:step(300)
	end
	T.eq(ped.controls.forwards, true, "after each stream-in the control states are set again")
	T.le(ped.weapons[22], 50 * 7, "the weapon was given again at most 5 times (" .. tostring(ped.weapons[22]) .. " ammo)")
	-- something that is not ours streaming in is left alone
	local other = m.sides.server.env.createPed(7, o.x + 10, o.y, 3.0)
	local before = D.stats.stream_in
	m:player_move_to(o.x + 5000, o.y); m:step(200); m:player_move_to(o.x, o.y); m:step(300)
	T.eq(other.voice, nil, "a ped without our tag is not touched")
	clean(m, "stream in")
	m:stop()
end)

T.test("driver: damage rules: a zombie's fists never hurt (the server scripts that damage), the player hitting a zombie reports it once a second, nobody else's hits are reported", function()
	local m = H.boot({})
	local D = mods(m).Driver
	local o = origin(m)
	m:player_move_to(o.x, o.y)
	local z1, z2 = new_ped(m, o.x + 10, o.y), new_ped(m, o.x + 12, o.y)
	local colonist = new_ped(m, o.x + 14, o.y); colonist.data.ob = "colonist"
	T.falsy(m:ped_damage_event(colonist, z1, 0, 3, 10), "a zombie punching one of ours is cancelled")
	T.falsy(m:ped_damage_event(z2, z1, 0, 3, 10), "and so is a zombie hitting a zombie")
	T.eq(#m:sent("server", NET.hit), 0)
	T.truthy(m:ped_damage_event(z1, m.player, 22, 3, 10), "the player's bullet is not cancelled")
	m:step(200)
	T.eq(#m:sent("server", NET.hit), 1, "and is reported")
	T.truthy(m:ped_damage_event(z1, m.player, 22, 3, 10))
	m:step(200)
	T.eq(#m:sent("server", NET.hit), 1, "not again within a second")
	m:step(1000)
	m:ped_damage_event(z1, m.player, 22, 3, 10)
	m:step(200)
	T.eq(#m:sent("server", NET.hit), 2, "but a second later it is")
	m:ped_damage_event(colonist, m.player, 22, 3, 10)
	local stranger = new_ped(m, o.x + 3, o.y); stranger.data.ob = nil
	m:ped_damage_event(stranger, m.player, 22, 3, 10)
	m:step(200)
	T.eq(#m:sent("server", NET.hit), 2, "hits on colonists and on peds that are not ours are not reported")
	-- the same rule on the player: a zombie's fist does not reach the sim through onClientPlayerDamage
	local dmgs = function() return m:in_events("player_damage") end
	local n = #dmgs()
	T.falsy(m:trigger(m.sides.client, "onClientPlayerDamage", m.player, z1, 0, 3, 10), "cancelled")
	m:step(300)
	T.eq(#dmgs(), n, "and not reported as the game's damage")
	clean(m, "damage rules")
	m:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ ground, world, props
T.test("ground: the client reports the player's ground and the streamed-in peds / objects that stand at the wrong height, in bounded batches with element references", function()
	local m = H.boot({})
	m:step(3000)
	local items = m:sent("server", NET.ground)
	T.gt(#items, 0)
	for _, item in ipairs(items) do
		local list = item.args[1]
		T.le(#list, 1 + 12, "bounded batches")
		for _, s in ipairs(list) do
			T.eq(type(s.x), "number"); T.eq(type(s.z), "number")
			if s.e then T.truthy(getmetatable(s.e) and s.e.mine, "a reference to one of our elements") end
		end
	end
	-- without collision data (getGroundPosition returns 0) nothing is sent
	m.no_ground = true
	local n = #m:sent("server", NET.ground)
	m:step(3000)
	T.eq(#m:sent("server", NET.ground), n, "no samples when the ground is unknown")
	m:stop()
end)

T.test("world: an outage dims the screen, alerts play a sound, the default HUD parts are hidden while we run", function()
	local m = H.boot({})
	for _, c in ipairs({ "health", "armour", "breath", "money", "clock", "wanted" }) do T.eq(m.hud[c], false, c .. " hidden") end
	local rects = m.dx.rects
	m:step(200)
	T.eq(m.dx.rects, rects, "no dimming while the power is on")
	H.host(m):absorb({ { type = "set_power", t = 0, on = false, supply = 0, demand = 10, mains = false, buildings = {} } })
	H.host(m):flush_events()
	m:step(300)
	T.gt(m.dx.rects, rects, "a dark overlay every frame during the outage")
	H.host(m):absorb({ { type = "set_power", t = 0, on = true, supply = 10, demand = 10, mains = true, buildings = {} }, { type = "play_alert", t = 0, kind = "raid_incoming", faction = "rustjaw" } })
	H.host(m):flush_events()
	m:step(300)
	T.eq(m.sound[#m.sound], H.creq(m, "shared.mta_config").alert_sounds.raid_incoming)
	local r2 = m.dx.rects
	m:step(200)
	T.eq(m.dx.rects, r2, "the lights are back")
	clean(m, "world")
	m:stop()
end)

T.test("props: E near a loot pile opens it in the inventory page (ui_action + screen message); nothing near, or in colony view, does nothing", function()
	local m = H.boot({})
	local w = H.world(m)
	local TUNING = H.sreq(m, "data.tuning")
	local items = require("sim.items")
	local p = w:pile_for({ x = TUNING.base.x + 3, y = TUNING.base.y + 3, z = 0 })
	items.add(p.items, "canned_beans", 3)
	m:step(2500)
	local o = origin(m)
	m:player_move_to(o.x + 1000, o.y + 1000)
	local n = #m:sent("server", NET.ui_action)
	m:press_key("e")
	m:step(200)
	T.eq(#m:sent("server", NET.ui_action), n, "too far from any pile")
	m:player_move_to(o.x + TUNING.base.x + 3.5, o.y + TUNING.base.y + 3)
	m:press_key("e")
	m:step(300)
	local acts = m:sent("server", NET.ui_action)
	T.eq(#acts, n + 1)
	T.eq(acts[#acts].args[1], "inventory"); T.eq(acts[#acts].args[2].other.kind, "pile"); T.eq(acts[#acts].args[2].other.id, p.id)
	local screens = m:ui_messages("screen")
	T.eq(screens[#screens].data.name, "inventory"); T.eq(screens[#screens].data.arg.other.id, p.id)
	enter_colony(m)
	local n2 = #m:sent("server", NET.ui_action)
	m:press_key("e")
	T.eq(#m:sent("server", NET.ui_action), n2, "no pile interaction while the camera is overhead")
	-- an emptied pile is forgotten
	w:remove_pile(p)
	m:step(2500)
	post(m, "mode", { mode = "survival" })
	local n3 = #m:sent("server", NET.ui_action)
	m:press_key("e")
	T.eq(#m:sent("server", NET.ui_action), n3)
	clean(m, "props")
	m:stop()
end)

T.test("keys: F6 toggles colony view, I opens the inventory (not in colony view); MTA key names are lower case; the client commands work", function()
	local m = H.boot({})
	local env = m.sides.client.env
	local seen = {}
	for _, b in ipairs(m.binds) do seen[b.key] = true end
	T.truthy(seen.f6 and seen.i and seen.e, "binds: f6, i, e")
	m:press_key("f6")
	T.truthy(mods(m).Camera.active)
	m:press_key("f6")
	T.falsy(mods(m).Camera.active)
	local n = #m:ui_messages("screen")
	m:press_key("i")
	T.eq(#m:ui_messages("screen"), n + 1)
	m:command("client", m.player, "outbreak_colony")
	T.truthy(mods(m).Camera.active)
	m:press_key("i")
	T.eq(#m:ui_messages("screen"), n + 1, "I does nothing in colony view (the page handles its own keys)")
	m:command("client", m.player, "outbreak_client")
	T.truthy(m.chat[#m.chat].text:find("client: events in", 1, true))
	clean(m, "keys")
	m:stop()
end)
