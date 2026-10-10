-- The mock itself: it must behave like MTA where the code depends on it (sides, Lua 5.1, events, files, elements, timers, browser), or every other test proves nothing.
local T, H = ...
T.group("mock")
local Mock = H.Mock

local function sandbox(side)
	local m = Mock.new({ root = H.res })
	local s = m:make_side(side)
	return m, s, s.env
end

T.test("each sandbox only has the functions that exist on that side in the real MTA source", function()
	local m, srv, se = sandbox("server")
	local mc, cli, ce = sandbox("client")
	T.throws(function() return se.setPedControlState end, "server: setPedControlState is client-only")
	T.throws(function() return se.createBrowser end)
	T.throws(function() return se.triggerServerEvent end)
	T.throws(function() return ce.triggerClientEvent end)
	T.throws(function() return ce.spawnPlayer end)
	T.throws(function() return ce.dbConnect end)
	T.eq(type(se.createPed), "function"); T.eq(type(se.setPedAnimation), "function"); T.eq(type(se.setElementSyncer), "function")
	T.eq(type(ce.setPedControlState), "function"); T.eq(type(ce.createBrowser), "function"); T.eq(type(ce.getGroundPosition), "function")
	T.eq(ce.localPlayer, mc.player)
	T.throws(function() return se.localPlayer end, "localPlayer is a client global")
end)

T.test("every function the resource uses is implemented by the mock on every side that uses it", function()
	local interp = (arg and arg[-1]) or "lua5.4"
	local p = io.popen(string.format("%s %s/function_check.lua --list --resource %s 2>&1", interp, H.tools, H.res))
	local out = p:read("*a")
	p:close()
	local used = {}
	for name, sides in out:gmatch("\n  (%S+)%s+x%d+%s+%[([%a+]+)%]") do used[#used + 1] = { name = name, sides = sides } end
	T.gt(#used, 100, "parsed the function list: " .. out:sub(1, 200))
	local m = Mock.new({ root = H.res })
	local server, client = m:make_side("server"), m:make_side("client")
	local missing = {}
	for _, u in ipairs(used) do
		if u.sides:find("client", 1, true) and rawget(client.env, u.name) == nil then missing[#missing + 1] = "client:" .. u.name end
		if u.sides:find("server", 1, true) and rawget(server.env, u.name) == nil then missing[#missing + 1] = "server:" .. u.name end
	end
	T.eq(#missing, 0, "missing from the mock: " .. table.concat(missing, ", "))
	T.note("%d functions, all implemented by the mock where used", #used)
end)

T.test("Lua 5.1 fidelity: no table.unpack / string.pack / math.type / bit / jit / io, load takes a reader, getfenv and require are disabled stubs, undefined globals are errors", function()
	local m, s, e = sandbox("server")
	T.eq(e.table.unpack, nil); T.eq(e.table.pack, nil); T.eq(e.table.move, nil); T.eq(e.string.pack, nil); T.eq(e.math.type, nil); T.eq(e.os.execute, nil); T.eq(e.os.getenv, nil)
	T.eq(type(e.unpack), "function", "5.1's global unpack")
	T.eq(type(e.math.pow), "function"); T.eq(type(e.math.atan2), "function")
	T.throws(function() return e.bit end); T.throws(function() return e.jit end); T.throws(function() return e.io end); T.throws(function() return e.package end)
	T.throws(function() return e.load("return 1") end)
	T.eq(e.require("x"), false); T.eq(e.getfenv(1), false); T.eq(e.dofile("x"), false)
	T.throws(function() return e.definitelyUndefined end)
	e.new_global_for_test = 1
	T.truthy(m.global_writes.server.new_global_for_test, "global writes are recorded")
end)

T.test("events: remote triggers only reach events added with allowRemoteTrigger; `client` is the sender; `source` is whatever the sender chose", function()
	local m = Mock.new({ root = H.res })
	local srv, cli = m:make_side("server"), m:make_side("client")
	srv.started, cli.started = true, true
	local got = {}
	srv.env.addEvent("t:remote", true); srv.env.addEvent("t:local", false)
	srv.env.addEventHandler("t:remote", m.root, function(a) got[#got + 1] = { "remote", a, rawget(srv.env, "client"), rawget(srv.env, "source") } end)
	srv.env.addEventHandler("t:local", m.root, function(a) got[#got + 1] = { "local", a } end)
	local other = m:add_player("Other")
	m:send_remote("server", "t:remote", m.resourceRoot, m.player, nil, 5)
	m:send_remote("server", "t:local", m.resourceRoot, m.player, nil, 6)
	m:send_remote("server", "t:unknown", m.resourceRoot, m.player, nil, 7)
	m:step(100)
	T.eq(#got, 1); T.eq(got[1][1], "remote"); T.eq(got[1][2], 5); T.eq(got[1][3], m.player, "`client` is the real sender"); T.eq(got[1][4], m.resourceRoot)
	T.eq(#m.net.dropped, 2, "the local-only and the unknown events were refused: " .. table.concat(m.net.dropped, " | "))
	-- spoofing: another player, and a chosen `source`
	m:spoof_server_event(other, "t:remote", other, 9)
	m:step(100)
	T.eq(got[2][3], other); T.eq(got[2][4], other, "the sender picks `source`; handlers must check it")
	-- bad payloads never leave: functions, cycles, destroyed elements
	local ok = m:send_remote("server", "t:remote", m.resourceRoot, m.player, nil, function() end)
	T.falsy(ok); T.truthy(#m.net.bad_payloads >= 1)
	local cyc = {}; cyc.self = cyc
	T.falsy(m:send_remote("server", "t:remote", m.resourceRoot, m.player, nil, cyc))
end)

T.test("events: propagation to ancestors, cancelEvent, handlers die with their element, built-in events exist", function()
	local m = Mock.new({ root = H.res })
	local srv = m:make_side("server")
	srv.started = true
	local e = srv.env
	local log = {}
	e.addEvent("t:evt", false)
	e.addEventHandler("t:evt", m.root, function() log[#log + 1] = "root"; e.cancelEvent() end)
	e.addEventHandler("t:evt", m.resourceRoot, function() log[#log + 1] = "resourceRoot" end)
	e.addEventHandler("t:evt", m.resourceRoot, function() log[#log + 1] = "no-propagate" end, false)
	local child = e.createObject(1448, 0, 0, 0)
	local ok = e.triggerEvent("t:evt", child)
	T.eq(table.concat(log, ","), "resourceRoot,root", "bubbles from the source up; a non-propagating handler on an ancestor is skipped")
	T.falsy(ok, "cancelled")
	T.falsy(e.addEventHandler("onNotAnEvent", m.root, function() end), "unknown event: false")
	T.truthy(e.addEventHandler("onPedWasted", m.root, function() end), "built-in events from the real source")
	local ped = e.createPed(7, 0, 0, 20)
	e.destroyElement(ped)
	T.falsy(e.isElement(ped))
	T.throws(function() e.getElementPosition(ped) end, "using a destroyed element raises")
	T.throws(function() e.setElementHealth(ped, 5) end)
end)

T.test("elements: createPed refuses invalid models and a full ped pool (140), createObject refuses invalid models, getElementsByType filters", function()
	local m = Mock.new({ root = H.res, invalid_ped_models = { [99] = true }, invalid_object_models = { [5] = true }, ambient_peds = 135 })
	local s = m:make_side("server")
	local e = s.env
	T.falsy(e.createPed(99, 0, 0, 0)); T.falsy(e.createPed(9999, 0, 0, 0))
	T.falsy(e.createObject(5, 0, 0, 0)); T.truthy(e.createObject(1448, 0, 0, 0))
	for i = 1, 5 do T.truthy(e.createPed(7, i, 0, 20)) end
	T.falsy(e.createPed(7, 0, 0, 20), "the 141st ped does not exist")
	T.eq(m.pool_overflow, 1)
	T.eq(#e.getElementsByType("ped"), 140)
	T.eq(#e.getElementsByType("object"), 1)
	T.eq(#e.getValidPedModels(), 312 - 1 + 1 - 0, "all ids 0..312 except the invalid one")
end)

T.test("timers: minimum interval 50 ms, repeating and limited, killTimer, errors in a timer are caught", function()
	local m = Mock.new({ root = H.res })
	local s = m:make_side("server")
	local e = s.env
	T.falsy(e.setTimer(function() end, 10, 1))
	local n, once = 0, 0
	local t = e.setTimer(function() n = n + 1 end, 100, 0)
	e.setTimer(function() once = once + 1 end, 100, 3)
	e.setTimer(function() error("boom") end, 100, 1)
	m:step(1000)
	T.ge(n, 9); T.eq(once, 3)
	T.eq(#m.errors, 1)
	T.truthy(e.isTimer(t)); e.killTimer(t); T.falsy(e.isTimer(t))
	local before = n
	m:step(500)
	T.eq(n, before)
end)

T.test("files: reads fall through to the resource folder on the server, the client only sees downloaded files, writes stay in memory, failure injection", function()
	local m = Mock.new({ root = H.res })
	local s, c = m:make_side("server"), m:make_side("client")
	T.truthy(s.env.fileExists("sim/world.lua")); T.falsy(c.env.fileExists("sim/world.lua"), "server-only file")
	T.truthy(c.env.fileExists("shared/util.lua")); T.truthy(c.env.fileExists("ui/mta.html"))
	local f = s.env.fileCreate("save/x.sav")
	T.eq(s.env.fileWrite(f, "hello ", "world"), 11)
	s.env.fileClose(f)
	T.eq(m.open_files, 0)
	local r = s.env.fileOpen("save/x.sav", true)
	T.eq(s.env.fileGetSize(r), 11); T.eq(s.env.fileRead(r, 5), "hello"); T.eq(s.env.fileRead(r, 100), " world"); s.env.fileClose(r)
	T.falsy(c.env.fileCreate("x"), "the client cannot create files in this mock (not needed)")
	m.fail.fileCreate = true
	T.falsy(s.env.fileCreate("save/y.sav")); m.fail.fileCreate = nil
	m.fail.fileWrite = true
	local f2 = s.env.fileCreate("save/z.sav")
	T.eq(s.env.fileWrite(f2, "12345678"), 4, "a short write"); s.env.fileClose(f2); m.fail.fileWrite = nil
	T.truthy(s.env.fileDelete("save/x.sav")); T.falsy(s.env.fileExists("save/x.sav"))
	T.eq(#m:live("file"), 0)
end)

T.test("browser: created asynchronously, loadBrowserURL only after onClientBrowserCreated, JavaScript only after the document is ready, messages decode", function()
	local m = Mock.new({ root = H.res })
	local c = m:make_side("client")
	c.started = true
	local e = c.env
	local events = {}
	local b = e.createBrowser(100, 100, true, true)
	e.addEventHandler("onClientBrowserCreated", b, function() events[#events + 1] = "created"; e.loadBrowserURL(rawget(e, "source"), "http://mta/local/ui/mta.html") end)
	e.addEventHandler("onClientBrowserDocumentReady", b, function() events[#events + 1] = "ready" end)
	T.falsy(e.loadBrowserURL(b, "x"), "too early")
	T.eq(#m.errors, 1)
	T.falsy(e.executeBrowserJavascript(b, "1"), "page not ready")
	m:step(500)
	T.eq(table.concat(events, ","), "created,ready")
	T.truthy(e.executeBrowserJavascript(b, "window.dispatchEvent(new MessageEvent('message',{data:{\"action\":\"x\",\"data\":[1,2]}}))"))
	T.eq(m.browser_msgs[1].action, "x"); T.eq(m.browser_msgs[1].data[2], 2)
	T.truthy(e.isBrowserDomainBlocked("http://example.org/", true)); T.falsy(e.isBrowserDomainBlocked("http://mta/local/ui/mta.html", true))
	T.throws(function() e.createBrowser(0, 0, true) end, "size 0 is a hard error in MTA")
end)
