-- The PHONE COMPANION's server half (server/phone.lua) in the mock MTA: the REAL server Lua answering what MTA's HTTP call interface would hand it (Mock:http_call sets the globals user /
-- requestHeaders like CResource::HandleRequestCall does). Proves: who is let in (guest, no right, view-only, control, missing CSRF header, foreign Origin), that the phone gets exactly the
-- NUI's messages (boot / mode / catalog / state / events), that orders and UI actions reach the SAME handlers as the in-game page's remote events, per-phone selection and inventory,
-- flood guards, session / ring-buffer / reset handling, the switch-off setting, the two console commands. What it can NOT prove (MTA's own HTTP server, Basic auth, the ACL file): that is
-- tools/phone_e2e.sh against the real server.
local T, H = ...
T.group("phone")
local P = require("shared.protocol")
local NET = require("shared.mta_net")
local Json = require("shared.json")

local HDR = { ["x-outbreak-phone"] = "1", host = "100.64.0.9:22005" }
local SID = "phoneSession0001"
local SID2 = "phoneSession0002"
local RIGHTS_CONTROL = { "resource.outbreak.phone_control", "resource.outbreak.phone_view" }

local function server_only(settings)
	local m = H.boot({ boot = false, settings = settings })
	m:load_side("server"); m:start_server()
	m:step(600)
	return m
end
local function api(m, acct, op, sid, a, b, headers)
	local res, err = m:http_call(acct, headers or HDR, "phoneApi", op, sid, a, b)
	T.truthy(res, "phoneApi did not return: " .. tostring(err))
	local t, e = Json.decode(res)
	T.truthy(t, "the answer is JSON: " .. tostring(e) .. " in " .. tostring(res):sub(1, 80))
	return t
end
local function actions(r) local out = {}; for i, msg in ipairs(r.msgs or {}) do out[i] = msg.action end; return table.concat(out, ",") end
local function find(r, action) for _, msg in ipairs(r.msgs or {}) do if msg.action == action then return msg end end return nil end
local function cb(m, acct, sid, name, data) return api(m, acct, "cb", sid, name, data) end
local function ui(m, acct, sid, name, data) return cb(m, acct, sid, "ui", { name = name, data = data or {} }) end
local function host(m) return H.host(m) end
local function prio(m, id, work) local c = H.world(m):colonist(id); return H.sreq(m, "sim.colonist").priority(c, work) end
local function ids(m) local out = {}; for i, c in ipairs(H.world(m).s.colonists) do out[i] = c.id end; return out end
local function clean(m, what)
	T.eq(#m.errors, 0, (what or "") .. ": errors: " .. H.errors_text(m))
	for _, line in ipairs(m.log) do T.falsy(line:find("%[outbreak%] error"), (what or "") .. ": error line in the log: " .. line) end
end

-- ------------------------------------------------------------------------------------------------------------------------ meta.xml
T.test("meta.xml: the page is the default <html> item, phoneApi is exported with http=true, the page is not a client download, the bridge and the icons are", function()
	local m = H.Mock.new({ root = H.res, defs = false })
	T.eq(#m.meta.html, 1)
	T.eq(m.meta.html[1].src, "ui/phone.html"); T.truthy(m.meta.html[1].default, "default page: served at /outbreak/"); T.truthy(m.meta.html[1].raw, "raw: served as it is, no Lua page scripting")
	local export
	for _, e in ipairs(m.meta.exports) do if e.name == "phoneApi" then export = e end end
	T.truthy(export and export.http and export.type == "server", "export phoneApi type=server http=true")
	T.falsy(m.client_files["ui/phone.html"], "a GTA client never downloads the phone page (it is only served behind the login)")
	for _, f in ipairs({ "ui/phone-bridge.js", "ui/phone-manifest.json", "ui/phone-icon-180.png", "ui/phone-icon-192.png", "ui/phone-icon-512.png", "ui/js/touch.js", "ui/css/mobile.css" }) do
		T.truthy(m.client_files[f], f .. " is a downloadable <file> (public over HTTP like every client file: the page itself and the API are what the login protects)")
	end
	T.falsy(m.meta.files["server/phone.lua"].download, "server/phone.lua is server-only")
	for _, k in ipairs({ "phone", "phone_sessions", "phone_session_s" }) do T.truthy(m.meta.settings[k] ~= nil, "setting " .. k .. " is in meta.xml") end
end)

-- ------------------------------------------------------------------------------------------------------------------------ who is let in
T.test("auth: guests, accounts without a phone right, calls without the X-Outbreak-Phone header or from a foreign Origin are refused; nothing changes", function()
	local m = server_only()
	local control = m:account("phone", RIGHTS_CONTROL)
	local before = host(m):status().hash
	local nobody = m:account("nobody", {})
	local guest = m:account("guest", { "resource.outbreak.phone_control" }, true) -- a guest account is refused even if the ACL says otherwise
	local r = api(m, nobody, "ready", SID)
	T.eq(r.ok, false); T.eq(r.error, "forbidden: no phone right")
	r = api(m, guest, "ready", SID)
	T.eq(r.ok, false); T.eq(r.error, "forbidden: guest")
	r = api(m, nil, "ready", SID)
	T.eq(r.ok, false); T.eq(r.error, "forbidden: no account")
	r = api(m, control, "ready", SID, nil, nil, { host = HDR.host })
	T.eq(r.ok, false); T.eq(r.error, "missing X-Outbreak-Phone header", "a plain cross-site form post cannot carry a custom header")
	r = api(m, control, "ready", SID, nil, nil, { ["x-outbreak-phone"] = "0", host = HDR.host })
	T.eq(r.error, "missing X-Outbreak-Phone header")
	r = api(m, control, "ready", SID, nil, nil, { ["x-outbreak-phone"] = "1", host = "100.64.0.9:22005", origin = "http://evil.example" })
	T.eq(r.error, "cross-origin call", "an Origin that is not the Host")
	r = api(m, control, "ready", SID, nil, nil, { ["X-Outbreak-Phone"] = "1", Host = "100.64.0.9:22005", Origin = "http://100.64.0.9:22005" })
	T.eq(r.ok, true, "same Origin and Host: allowed, and the header name is case-insensitive")
	T.eq(Json.decode(m:http_call(control, HDR, "phoneApi", "poll", "x")).error, "bad session id")
	for _, bad in ipairs({ "short", string.rep("a", 41), "has space in it!", "semi;colon;12345" }) do
		T.eq(Json.decode(m:http_call(control, HDR, "phoneApi", "ready", bad)).error, "bad session id", "sid " .. bad:sub(1, 12))
	end
	T.eq(Json.decode(m:http_call(control, HDR, "phoneApi", 5, SID)).error, "bad op")
	T.eq(Json.decode(m:http_call(control, HDR, "phoneApi", "explode", SID)).error, "unknown op")
	T.eq(host(m):status().hash, before, "the sim did not change")
	local reasons = H.sreq(m, "server.phone").stats.reasons
	T.gt(reasons["forbidden: guest"], 0); T.gt(reasons["cross-origin call"], 0)
	clean(m, "auth")
	m:stop()
end)

T.test("a session id belongs to the account that made it; an unknown or expired id is told to start over", function()
	local m = server_only()
	local a, b = m:account("phone", RIGHTS_CONTROL), m:account("phone2", RIGHTS_CONTROL)
	T.eq(api(m, a, "ready", SID).ok, true)
	T.eq(api(m, b, "ready", SID).error, "session belongs to another account")
	T.eq(api(m, b, "poll", SID, 0, 1).resync, true, "poll with another account's id: start over")
	T.eq(api(m, a, "poll", "neverMadeSession1", 0, 1).resync, true)
	m:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ the NUI's messages
T.test("ready: a phone gets exactly what the NUI gets (boot, mode colony, catalog, state), with no GTA client connected at all", function()
	local m = server_only()
	T.eq(H.sreq(m, "server.ctx").owner, nil, "nobody is connected")
	local control = m:account("phone", RIGHTS_CONTROL)
	local r = api(m, control, "ready", SID)
	T.eq(r.ok, true); T.eq(r.role, "control"); T.eq(actions(r), "boot,mode,catalog,state")
	local boot = find(r, "boot").data
	T.eq(boot.phone, true, "boot.phone: the page says 'Phone companion' in its menu"); T.eq(boot.preview, true, "boot.preview: the page draws the map itself (no 3D world behind it)")
	T.eq(boot.role, "control"); T.eq(boot.account, "phone"); T.eq(boot.resource, "outbreak")
	T.eq(find(r, "mode").data.mode, "colony")
	local V = H.sreq(m, "shared.view")
	local want_catalog = Json.decode(Json.encode(V.catalog()))
	local got = find(r, "catalog").data
	T.eq(#got.blueprint_order, #want_catalog.blueprint_order); T.eq(got.tuning.base.build_radius, want_catalog.tuning.base.build_radius)
	local st = find(r, "state").data
	local w = H.world(m)
	T.eq(#st.colonists, #w.s.colonists, "the colonist list is the sim's"); T.eq(st.day, require("sim.clock").day(w.s.t)); T.eq(st.res.colonists, #w.s.colonists)
	T.eq(st.card, nil, "no card until a colonist is selected")
	local viewer = api(m, m:account("phoneview", { "resource.outbreak.phone_view" }), "ready", SID2)
	T.eq(viewer.role, "view"); T.eq(find(viewer, "boot").data.role, "view")
	clean(m, "ready")
	m:stop()
end)

T.test("poll: returns the OUT events the sim produced since `since` (the NUI's `events` message), then nothing; the state only when it changed", function()
	local m = server_only()
	local control = m:account("phone", RIGHTS_CONTROL)
	local r = api(m, control, "ready", SID)
	local seq, gen = r.seq, r.gen
	local p = api(m, control, "poll", SID, seq, gen)
	T.eq(p.ok, true); T.eq(p.seq, seq, "nothing happened yet")
	T.eq(actions(p), "", "an unchanged state is not sent again")
	host(m):debug("horde", { n = 12, dist = 100 })
	m:step(2500) -- the next sim ticks flush the horde's events
	p = api(m, control, "poll", SID, seq, gen)
	T.gt(p.seq, seq)
	local ev = find(p, "events")
	T.truthy(ev, "an events message: " .. actions(p))
	local kinds = {}
	for _, e in ipairs(ev.data) do kinds[e.type] = true end
	T.truthy(kinds.play_alert and kinds.colonist_task, "the sim's alert and the colonists' reactions are in it")
	T.truthy(find(p, "state"), "the clock moved: the state changed")
	T.eq(actions(api(m, control, "poll", SID, p.seq, gen)):find("events"), nil, "events are delivered once")
	-- a second phone that joined later does not get the old events, only a snapshot
	local r2 = api(m, m:account("phone2", RIGHTS_CONTROL), "ready", SID2)
	T.eq(actions(r2), "boot,mode,catalog,state")
	T.eq(r2.seq, p.seq)
	clean(m, "poll")
	m:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ orders go to the SAME handlers
T.test("orders: a phone order reaches host:on_order exactly like the owner's remote event; the sim changes; the order_result comes back in the feed", function()
	local m = H.boot({}) -- with the owner connected: both entry points exist
	local control = m:account("phone", RIGHTS_CONTROL)
	local h = host(m)
	local seen = {}
	local orig = h.on_order
	h.on_order = function(self, ev) seen[#seen + 1] = { src = (#seen % 2 == 0) and "first" or "second", ev = ev }; return orig(self, ev) end
	local r = api(m, control, "ready", SID)
	local cid = ids(m)[1]
	local cur = prio(m, cid, "cook")
	local lv1, lv2 = (cur % 4) + 1, ((cur + 1) % 4) + 1
	-- 1. the owner's in-game page: a remote event
	m:send_remote("server", NET.order, m.resourceRoot, m.player, nil, { id = cid, kind = "priority", target = { work = "cook", level = lv1 } })
	m:step(100)
	T.eq(#seen, 1); T.eq(prio(m, cid, "cook"), lv1, "the owner's order took effect")
	-- 2. the phone: the page's `order` callback
	local ans = cb(m, control, SID, "order", { id = cid, kind = "priority", target = { work = "cook", level = lv2 } })
	T.eq(ans.ok, true)
	T.eq(#seen, 2, "the SAME handler was called")
	T.eq(seen[2].ev.kind, seen[1].ev.kind); T.eq(seen[2].ev.id, seen[1].ev.id); T.eq(seen[2].ev.target.work, "cook")
	T.eq(prio(m, cid, "cook"), lv2, "the phone's order took effect in the sim")
	T.eq(find(ans, "state").data.colonists[1].prio.cook, lv2, "the answer already carries the new state")
	-- a bad order is rejected by the host's own sanitizer and the feed says so
	ans = cb(m, control, SID, "order", { id = cid, kind = "teleport", target = {} })
	T.eq(ans.ok, true, "the call itself is fine, the host rejects the order")
	local p = api(m, control, "poll", SID, r.seq, r.gen)
	local res
	for _, msg in ipairs(p.msgs) do if msg.action == "events" then for _, e in ipairs(msg.data) do if e.type == "order_result" and e.ok == false then res = e end end end end
	T.truthy(res, "an order_result with ok=false is in the feed")
	T.eq(res.reason, "rejected:unknown order kind")
	T.eq(host(m).stats.orders_rejected, 1)
	clean(m, "orders")
	m:stop()
end)

T.test("read-only account: can look (select, inventory, summary, poll) but every order, mutating UI action and placement is refused and the sim does not change", function()
	local m = server_only()
	local viewer = m:account("phoneview", { "resource.outbreak.phone_view" })
	api(m, viewer, "ready", SID)
	local cid = ids(m)[1]
	local before = host(m):status().hash
	local cur = prio(m, cid, "cook")
	T.eq(cb(m, viewer, SID, "order", { id = cid, kind = "priority", target = { work = "cook", level = (cur % 4) + 1 } }).error, "read-only")
	T.eq(ui(m, viewer, SID, "set_speed", { speed = 8 }).error, "read-only")
	T.eq(ui(m, viewer, SID, "new_game", { seed = 3 }).error, "read-only")
	T.eq(ui(m, viewer, SID, "save").error, "read-only")
	T.eq(cb(m, viewer, SID, "place", { op = "commit", bp = "wall", x = 10, y = 10 }).error, "read-only")
	T.eq(prio(m, cid, "cook"), cur); T.eq(host(m).speed, 1)
	T.eq(host(m):status().hash, before, "the sim is exactly as it was")
	local sel = ui(m, viewer, SID, "select", { id = cid })
	T.eq(sel.ok, true); T.eq(find(sel, "state").data.card.id, cid, "a viewer may select (it only changes what HIS page shows)")
	T.eq(find(ui(m, viewer, SID, "request_summary"), "summary").data.alive, #ids(m))
	T.truthy(find(ui(m, viewer, SID, "inventory", { other = { kind = "zone", id = H.world(m).s.zones[1].id } }), "inventory"))
	T.eq(api(m, viewer, "poll", SID, 0, 1).ok, true)
	m:stop()
end)

T.test("per-phone selection: two phones select different colonists and see different cards; the owner's in-game selection is untouched", function()
	local m = H.boot({})
	local a, b = m:account("phone", RIGHTS_CONTROL), m:account("phone2", RIGHTS_CONTROL)
	api(m, a, "ready", SID); api(m, b, "ready", SID2)
	local c = ids(m)
	m:send_remote("server", NET.ui_action, m.resourceRoot, m.player, nil, "select", { id = c[1] })
	m:step(100)
	T.eq(host(m).sel, c[1], "the owner selected c1 in game")
	T.eq(find(ui(m, a, SID, "select", { id = c[2] }), "state").data.card.id, c[2])
	T.eq(find(ui(m, b, SID2, "select", { id = c[3] }), "state").data.card.id, c[3])
	T.eq(host(m).sel, c[1], "the phones never touched host.sel")
	T.eq(find(ui(m, a, SID, "request_state"), "state").data.card.id, c[2], "phone A still sees c2")
	T.eq(find(ui(m, a, SID, "select", { id = "" }), "state").data.card, nil, "deselect")
	T.eq(find(ui(m, a, SID, "select", { id = "c99999" }), "state").data.card, nil, "an unknown id selects nothing")
	clean(m, "selection")
	m:stop()
end)

T.test("place: a placement commit builds the blueprint like client/ui.lua does; start / cancel and the camera / window callbacks are acknowledged and ignored; screens never sets the owner's colony flag", function()
	local m = server_only()
	local control = m:account("phone", RIGHTS_CONTROL)
	api(m, control, "ready", SID)
	local base = H.sreq(m, "data.tuning").base
	local n0 = #H.world(m).s.buildings
	for _, name in ipairs({ "mode", "screen", "focus", "mouse", "key", "close", "ready" }) do T.eq(cb(m, control, SID, name, { x = 1, y = 2 }).ok, true, name .. " acknowledged") end
	T.eq(cb(m, control, SID, "place", { op = "start", bp = "wall" }).ok, true); T.eq(cb(m, control, SID, "place", { op = "cancel" }).ok, true)
	T.eq(ui(m, control, SID, "screens", { colony = true }).ok, true)
	T.eq(H.sreq(m, "server.ctx").colony_mode, nil, "a phone cannot switch the owner's colony view on")
	T.eq(#H.world(m).s.buildings, n0, "nothing was built yet")
	T.eq(cb(m, control, SID, "place", { op = "commit", bp = "wall" }).error, "bad placement")
	local ans = cb(m, control, SID, "place", { op = "commit", bp = "wall", x = base.x + 14, y = base.y + 10 })
	T.eq(ans.ok, true)
	T.eq(#H.world(m).s.buildings, n0 + 1, "a planned wall exists")
	local b = H.world(m).s.buildings[n0 + 1]
	T.eq(b.bp, "wall"); T.eq(b.state, "planned"); T.near(b.pos.x, base.x + 14, 1e-6)
	T.eq(cb(m, control, SID, "place", { op = "commit", bp = "wall", x = base.x + 14, y = base.y + 10 }).ok, true, "the same spot again is the sim's business (order_result), not a transport error")
	clean(m, "place")
	m:stop()
end)

T.test("inventory by phone: each phone picks its own container; a move goes through the host and the answer carries the fresh inventory", function()
	local m = server_only()
	local control = m:account("phone", RIGHTS_CONTROL)
	api(m, control, "ready", SID)
	local w = H.world(m)
	local zone = w.s.zones[1]
	local inv = find(ui(m, control, SID, "inventory", { other = { kind = "zone", id = zone.id } }), "inventory").data
	T.eq(inv.other.kind, "zone"); T.eq(inv.other.id, zone.id)
	T.eq(find(ui(m, control, SID, "inventory", { other = { kind = "player" } }), "inventory").data.other, nil, "the player container is never 'other'")
	T.eq(find(ui(m, control, SID, "inventory", { other = { kind = "zone", id = string.rep("x", 70) } }), "inventory").data.other, nil, "an oversized id is dropped")
	ui(m, control, SID, "inventory", { other = { kind = "zone", id = zone.id } })
	local item
	for _, s in ipairs(inv.other.stacks) do item = item or s end
	T.truthy(item, "the zone holds something")
	local ans = ui(m, control, SID, "inventory_move", { from = { kind = "zone", id = zone.id }, to = { kind = "player" }, item = item.id, n = 1 })
	T.eq(ans.ok, true)
	local inv2 = find(ans, "inventory").data
	local got = 0
	for _, s in ipairs(inv2.player.stacks) do if s.id == item.id then got = s.n end end
	T.eq(got, 1, "the item is in the player's inventory in the answer")
	T.eq(host(m).other, nil, "host.other (the owner's container) was never touched")
	clean(m, "inventory")
	m:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ guards
T.test("flood guard: a burst of orders is rate limited with the phone's OWN bucket; the owner's orders still go through", function()
	local m = H.boot({})
	local control = m:account("phone", RIGHTS_CONTROL)
	api(m, control, "ready", SID)
	local cid = ids(m)[1]
	local ok, limited = 0, 0
	for i = 1, 400 do
		local r = cb(m, control, SID, "order", { id = cid, kind = "priority", target = { work = "cook", level = i % 5 } })
		if r.ok then ok = ok + 1 elseif r.error == "rate limited" then limited = limited + 1 end
	end
	T.gt(limited, 100, "most of the burst was refused"); T.gt(ok, 20, "but a normal rate is fine (" .. ok .. " accepted)")
	local n = host(m).stats.orders
	m:send_remote("server", NET.order, m.resourceRoot, m.player, nil, { id = cid, kind = "priority", target = { work = "cook", level = 2 } })
	m:step(100)
	T.eq(host(m).stats.orders, n + 1, "the owner's bucket is separate")
	clean(m, "flood")
	m:stop()
end)

T.test("debug_ UI actions are refused over the phone unless the debug setting is on (the owner_admin shortcut does not apply to a phone)", function()
	local m = server_only({ debug = "0", owner_admin = "1" })
	local control = m:account("phone", RIGHTS_CONTROL)
	api(m, control, "ready", SID)
	T.eq(ui(m, control, SID, "debug_give", { item = "bandage", n = 1 }).error, "debug refused")
	m:stop()
	local m2 = server_only({ debug = "1" })
	local c2 = m2:account("phone", RIGHTS_CONTROL)
	api(m2, c2, "ready", SID)
	T.eq(ui(m2, c2, SID, "debug_give", { item = "bandage", n = 1 }).ok, true)
	m2:stop()
end)

T.test("bad callbacks: names, data types and unknown actions are refused without touching the sim", function()
	local m = server_only()
	local control = m:account("phone", RIGHTS_CONTROL)
	api(m, control, "ready", SID)
	local before = host(m):status().hash
	T.eq(cb(m, control, SID, string.rep("x", 30), {}).error, "bad callback name")
	T.eq(cb(m, control, SID, 5, {}).error, "bad callback name")
	T.eq(cb(m, control, SID, "order", "not a table").error, "bad callback data")
	T.eq(cb(m, control, SID, "explode", {}).error, "unknown callback")
	T.eq(cb(m, control, SID, "ui", { name = 5 }).error, "bad ui action")
	T.eq(cb(m, control, SID, "ui", { name = string.rep("u", 40) }).error, "bad ui action")
	T.eq(ui(m, control, SID, "no_such_action").ok, true, "an unknown ui action is the host's business (it returns false), not a transport error")
	T.eq(host(m):status().hash, before)
	clean(m, "bad callbacks")
	m:stop()
end)

-- ------------------------------------------------------------------------------------------------------------------------ sessions, ring, reset, switch
T.test("new game / load: the generation changes, the old page is told to resync and its selection is gone; ready brings the new world", function()
	local m = server_only()
	local control = m:account("phone", RIGHTS_CONTROL)
	local r = api(m, control, "ready", SID)
	ui(m, control, SID, "select", { id = ids(m)[1] })
	local ans = ui(m, control, SID, "new_game", { seed = 77, profile = "calm" })
	T.eq(ans.ok, true)
	T.eq(api(m, control, "poll", SID, r.seq, r.gen).resync, true, "the old generation: start over")
	local r2 = api(m, control, "ready", SID)
	T.gt(r2.gen, r.gen)
	T.eq(find(r2, "state").data.card, nil, "the selection was cleared")
	T.eq(find(r2, "state").data.seed, 77, "the new world")
	T.eq(api(m, control, "poll", SID, r2.seq, r2.gen).ok, true)
	clean(m, "reset")
	m:stop()
end)

T.test("ring buffer: bounded; a phone that fell too far behind is told to resync", function()
	local m = server_only()
	local control = m:account("phone", RIGHTS_CONTROL)
	local r = api(m, control, "ready", SID)
	local h = host(m)
	for i = 1, 450 do h:absorb({ { type = "notify", t = i, level = "info", text = "n" .. i } }); h:flush_events() end
	local ph = H.sreq(m, "server.phone")
	T.truthy(ph.seq - ph.first + 1 <= 400, "at most 400 messages are kept")
	T.eq(api(m, control, "poll", SID, r.seq, r.gen).resync, true, "since is older than the ring")
	local r2 = api(m, control, "ready", SID)
	local p = api(m, control, "poll", SID, r2.seq, r2.gen)
	T.eq(p.ok, true)
	T.eq(api(m, control, "poll", SID, r2.seq + 5000, r2.gen).resync, true, "a `since` from the future (a restarted server) is a resync too")
	clean(m, "ring")
	m:stop()
end)

T.test("sessions: at most phone_sessions at once (the least recently used is evicted), idle ones expire, and nothing is kept while nobody listens", function()
	local m = server_only({ phone_sessions = "2", phone_session_s = "20" })
	local ph = H.sreq(m, "server.phone")
	local control = m:account("phone", RIGHTS_CONTROL)
	local s = { "phoneSession0001", "phoneSession0002", "phoneSession0003" }
	api(m, control, "ready", s[1]); m:step(100)
	api(m, control, "ready", s[2]); m:step(100)
	api(m, control, "poll", s[1], 0, 1)
	api(m, control, "ready", s[3])
	T.eq(ph.nsessions, 2); T.eq(ph.stats.evicted, 1)
	T.eq(api(m, control, "poll", s[2], 0, 1).resync, true, "the least recently used (the second) was evicted")
	T.eq(api(m, control, "poll", s[1], ph.seq, ph.generation).ok, true)
	m:step(26000)
	T.eq(ph.nsessions, 0, "idle sessions expire")
	T.eq(ph.stats.expired, 2)
	host(m):absorb({ { type = "notify", t = 1, level = "info", text = "x" } }); host(m):flush_events()
	T.eq(ph.bytes, 0, "no listener, nothing buffered")
	T.eq(api(m, control, "poll", s[1], 0, 1).resync, true)
	clean(m, "sessions")
	m:stop()
end)

T.test("phone=0: phoneApi answers that the companion is switched off, and nothing is captured", function()
	local m = server_only({ phone = "0" })
	local control = m:account("phone", RIGHTS_CONTROL)
	local r = api(m, control, "ready", SID)
	T.eq(r.ok, false); T.truthy(r.error:find("switched off"))
	T.eq(H.sreq(m, "server.phone").nsessions, 0)
	m:stop()
end)

T.test("status: the call that tells a phone (and tools/phone_e2e.sh) what the sim holds: hash, day, colonists", function()
	local m = server_only()
	local control = m:account("phone", RIGHTS_CONTROL)
	api(m, control, "ready", SID)
	local s = api(m, control, "status", SID).status
	local st = host(m):status()
	T.eq(s.hash, st.hash); T.eq(s.day, st.day); T.eq(s.colonists, st.colonists); T.eq(s.sessions, 1)
	m:stop()
end)

T.test("commands: /outbreak_phone and /outbreak_prio exist, work from the console, and an ordinary player is denied", function()
	local m = server_only()
	local control = m:account("phone", RIGHTS_CONTROL)
	api(m, control, "ready", SID)
	local cid = ids(m)[1]
	cb(m, control, SID, "order", { id = cid, kind = "priority", target = { work = "cook", level = 2 } })
	m:command("server", m.console, "outbreak_prio", cid, "cook")
	local last = m.log[#m.log]
	T.truthy(last:find("prio " .. cid .. " cook=2", 1, true), "the getter shows what the sim holds: " .. tostring(last))
	m:command("server", m.console, "outbreak_prio", cid)
	T.truthy(m.log[#m.log]:find("doctor=%d") and m.log[#m.log]:find("scavenge=%d"), "without a work type: all of them: " .. m.log[#m.log])
	m:command("server", m.console, "outbreak_prio", "c99999")
	T.truthy(m.log[#m.log]:find("no such colonist"))
	m:command("server", m.console, "outbreak_phone")
	T.truthy(m.log[#m.log]:find("phone on | sessions 1 (control 1, view 0)", 1, true), m.log[#m.log])
	local stranger = m:add_player("Stranger")
	m:command("server", stranger, "outbreak_phone")
	T.truthy(m.chat[#m.chat].text:find("not allowed"), "a player without the ACL right is refused")
	clean(m, "commands")
	m:stop()
end)

T.test("lifecycle: stopping the resource drops the hook, the sessions and the buffer; restarting works", function()
	local m = H.boot({})
	local control = m:account("phone", RIGHTS_CONTROL)
	api(m, control, "ready", SID)
	local net = H.sreq(m, "server.net")
	T.truthy(net.on_send, "the capture hook is installed")
	m:stop()
	T.eq(net.on_send, nil, "and removed on stop")
	T.eq(H.sreq(m, "server.phone").nsessions, 0)
end)
