-- tools/function_check.lua: passes on the resource, and FAILS on the mistakes it exists to catch. The checker is tested like any other code.
local T, H = ...
T.group("function_check")
local interp = (arg and arg[-1]) or "lua5.4"
local tool = H.tools .. "/function_check.lua"

local function run(args)
	local p = io.popen(string.format('%s %s %s 2>&1; echo "EXIT:$?"', interp, tool, args))
	local out = p:read("*a")
	p:close()
	return tonumber(out:match("EXIT:(%d+)%s*$")), out
end

local function resource(files)
	local d = os.tmpname()
	os.remove(d)
	os.execute("mkdir -p " .. d .. "/server " .. d .. "/client " .. d .. "/shared")
	for path, text in pairs(files) do
		local f = assert(io.open(d .. "/" .. path, "wb"))
		f:write(text)
		f:close()
	end
	return d
end

local function check(files, args)
	local d = resource(files)
	local code, out = run("--resource " .. d .. " " .. (args or ""))
	os.execute("rm -rf " .. d)
	return code, out
end

T.test("the resource passes, and the checker reports how many MTA functions it checked", function()
	local code, out = run("--resource " .. H.res)
	T.eq(code, 0, out)
	T.truthy(out:find("every function exists on the side that uses it", 1, true), out)
	local n = tonumber(out:match("(%d+) distinct MTA functions used"))
	T.truthy(n and n >= 100, "checked " .. tostring(n) .. " distinct functions")
	local ev = tonumber(out:match("(%d+) remote event names checked"))
	T.truthy(ev and ev >= 12, "checked " .. tostring(ev) .. " remote event names")
	T.note("function_check: %s distinct MTA functions, %s remote events, exit 0", tostring(n), tostring(ev))
end)

T.test("the side lists come from the real MTA source: the brief's server-side ped control does NOT exist there", function()
	package.path = H.tools .. "/?.lua;" .. package.path
	local D = require("mta_defs")
	local defs = assert(D.load())
	T.eq(defs.server.setPedControlState, nil, "setPedControlState is client-only")
	T.eq(defs.server.setPedAimTarget, nil, "setPedAimTarget is client-only")
	T.eq(defs.server.getPedMoveState, nil)
	T.eq(defs.server.getGroundPosition, nil)
	T.eq(defs.server.processLineOfSight, nil)
	T.eq(defs.client.setPedControlState, true)
	T.eq(defs.server.createPed and defs.client.createPed, true)
	T.eq(defs.server.setPedAnimation, true); T.eq(defs.server.setPedWalkingStyle, true); T.eq(defs.server.setElementSyncer, true)
	T.eq(defs.client.triggerClientEvent, nil); T.eq(defs.server.triggerServerEvent, nil)
	T.eq(defs.client.createBrowser, true); T.eq(defs.server.createBrowser, nil)
	T.truthy(defs.events.client.onClientRender and defs.events.server.onPedWasted and defs.events.server.onResourceStart)
	T.gt(defs.counts.client, 1000); T.gt(defs.counts.server, 700)
end)

T.test("an unknown function fails the check; so do a client-only function on the server and a server-only function on the client", function()
	local code, out = check({ ["client/a.lua"] = "local p = getElementPosition(localPlayer)\nlocal y = definitelyNotAFunction(p)\n" })
	T.eq(code, 1, out); T.truthy(out:find("UNKNOWN function or global definitelyNotAFunction", 1, true), out)
	-- the exact mistake of the original plan: ped control from the server
	code, out = check({ ["server/a.lua"] = "local ped = createPed(7, 0, 0, 3)\nsetPedControlState(ped, 'forwards', true)\nsetPedAimTarget(ped, 1, 2, 3)\n" })
	T.eq(code, 1, out)
	T.truthy(out:find("setPedControlState is not available on the SERVER", 1, true), out)
	T.truthy(out:find("setPedAimTarget is not available on the SERVER", 1, true), out)
	T.falsy(out:find("createPed is not available", 1, true), "createPed exists on the server")
	code, out = check({ ["client/a.lua"] = "triggerClientEvent(localPlayer, 'x', root)\nlocal r = spawnPlayer(localPlayer, 0, 0, 0)\ndbConnect('sqlite', 'a.db')\n" })
	T.eq(code, 1, out)
	T.truthy(out:find("triggerClientEvent is not available on the CLIENT", 1, true), out)
	T.truthy(out:find("spawnPlayer is not available on the CLIENT", 1, true), out)
	T.truthy(out:find("dbConnect is not available on the CLIENT", 1, true), out)
	-- shared code runs on both sides, so a one-sided function in it fails on the other side
	code, out = check({ ["shared/a.lua"] = "local x = giveWeapon(nil, 1, 1)\n" })
	T.eq(code, 1, out); T.truthy(out:find("giveWeapon is not available on the CLIENT", 1, true), out)
end)

T.test("a leaked global, a missing Lua 5.1 library function and the disabled stubs are caught", function()
	local code, out = check({ ["server/a.lua"] = "local function f() end\nleaked = 5\nfunction alsoLeaked() end\n" })
	T.eq(code, 1, out)
	T.truthy(out:find("GLOBAL WRITE leaked at server/a.lua:2", 1, true), out)
	T.truthy(out:find("GLOBAL WRITE alsoLeaked", 1, true), out)
	code, out = check({ ["server/a.lua"] = "leaked = 5\n" }, "--allow-global leaked")
	T.eq(code, 0, out)
	code, out = check({ ["server/a.lua"] = "local t = table.unpack({1})\nlocal u = string.pack('i', 1)\nlocal k = math.type(1)\nlocal e = os.execute('ls')\n" })
	T.eq(code, 1, out)
	for _, what in ipairs({ "table.unpack", "string.pack", "math.type", "os.execute" }) do T.truthy(out:find("NOT IN MTA's Lua 5.1: " .. what, 1, true), what .. ": " .. out) end
	code, out = check({ ["server/a.lua"] = "local a = bit.band(1, 2)\nlocal b = jit.status()\nlocal f = io.open('x')\nlocal p = package.path\n" })
	T.eq(code, 1, out)
	for _, g in ipairs({ "bit", "jit", "io", "package" }) do T.truthy(out:find("NOT IN MTA's Lua 5.1: " .. g, 1, true), g .. ": " .. out) end
	code, out = check({ ["server/a.lua"] = "dofile('x')\nlocal m = require('y')\nlocal e = getfenv(1)\n" })
	T.eq(code, 1, out)
	T.truthy(out:find("DISABLED in MTA: dofile", 1, true) and out:find("DISABLED in MTA: require", 1, true) and out:find("DISABLED in MTA: getfenv", 1, true), out)
	-- `require` counts as defined only when bootstrap_mta.lua really replaces it
	code, out = check({ ["server/a.lua"] = "local m = require('y')\n", ["bootstrap_mta.lua"] = "_G.require = function() end\n" })
	T.eq(code, 0, out)
end)

T.test("no false alarms: locals, parameters, fields, strings, comments, the portable unpack idiom, own globals, MTA's event variables", function()
	local code, out = check({
		["server/a.lua"] = table.concat({
			"local setTimer = 1",                                    -- a local that shadows an MTA name
			"local function run(getTickCount, cb) cb(getTickCount) end",   -- parameters
			"local M = { createPed = function() end }",
			"M.createPed(); M:createPed()",                           -- fields
			"local s = 'triggerClientEvent(nope)'",                   -- a string
			"-- spawnPlayer(x) in a comment",
			"local u = table.unpack or unpack",                       -- portable idiom
			"function OutbreakHost() return source, client, root, resourceRoot, eventName end",
			"local x = getElementPosition(root)",
		}, "\n"),
		["client/a.lua"] = "local p = localPlayer\nlocal y = guiRoot\nlocal z = getElementPosition(p)\n",
	}, "--allow-global OutbreakHost")
	T.eq(code, 0, out)
end)

local NET = 'return { evt_a = "t:a", evt_b = "t:b", TO_CLIENT = { "t:a" } }\n'

T.test("events: every triggerClientEvent / triggerServerEvent name must be registered with addEvent(name, true) on the receiving side", function()
	local code, out = check({
		["shared/mta_net.lua"] = NET,
		["server/a.lua"] = "local NET = require('shared.mta_net')\naddEvent(NET.evt_b, true)\ntriggerClientEvent(root, NET.evt_a, root)\ntriggerClientEvent(root, 't:literal', root)\n",
		["client/a.lua"] = "local NET = require('shared.mta_net')\naddEvent(NET.evt_a, true)\ntriggerServerEvent(NET.evt_b, resourceRoot)\n",
	}, "--allow-global none")
	T.eq(code, 1, out)
	T.truthy(out:find("EVENT t:literal is sent with triggerClientEvent", 1, true), out)
	T.falsy(out:find("EVENT t:a ", 1, true), "t:a is registered on the client")
	T.falsy(out:find("EVENT t:b ", 1, true), "t:b is registered on the server")
	code, out = check({
		["shared/mta_net.lua"] = NET,
		["server/a.lua"] = "local NET = require('shared.mta_net')\naddEvent(NET.evt_b, true)\n",
		["client/a.lua"] = "local NET = require('shared.mta_net')\naddEvent(NET.evt_a, true)\ntriggerServerEvent(NET.evt_b, resourceRoot)\ntriggerServerEvent(NET.evt_a, resourceRoot)\n",
	})
	T.eq(code, 1, out); T.truthy(out:find("EVENT t:a is sent with triggerServerEvent", 1, true), out)
	-- registered for local use only (allowRemoteTrigger = false): a remote trigger would be rejected by MTA
	code, out = check({
		["shared/mta_net.lua"] = NET,
		["server/a.lua"] = "local NET = require('shared.mta_net')\naddEvent(NET.evt_b, false)\n",
		["client/a.lua"] = "local NET = require('shared.mta_net')\ntriggerServerEvent(NET.evt_b, resourceRoot)\n",
	})
	T.eq(code, 1, out); T.truthy(out:find("allowRemoteTrigger", 1, true), out)
	-- a name the checker cannot resolve is an error, not a silent pass
	code, out = check({ ["client/a.lua"] = "local name = 'x'\ntriggerServerEvent(name, resourceRoot)\n" })
	T.eq(code, 1, out); T.truthy(out:find("CANNOT RESOLVE the event name expression `name`", 1, true), out)
	-- handlers for built-in events must name real built-in events of that side
	code, out = check({ ["server/a.lua"] = "addEventHandler('onPedWasted', root, function() end)\naddEventHandler('onClientRender', root, function() end)\naddEventHandler('onNotAnEvent', root, function() end)\n" })
	T.eq(code, 1, out)
	T.truthy(out:find("EVENT HANDLER for onClientRender", 1, true) and out:find("EVENT HANDLER for onNotAnEvent", 1, true), out)
	T.falsy(out:find("EVENT HANDLER for onPedWasted", 1, true), out)
end)

T.test("the checker does not run without its sources: a missing MTA source tree or resource is exit 2, not a pass", function()
	local code, out = run("--resource " .. H.res .. " --src /nonexistent/mtasa-blue")
	T.eq(code, 2, out)
	code, out = run("--resource /nonexistent/resource")
	T.eq(code, 2, out)
	code, out = run("--resource " .. H.res .. " --luac /nonexistent/luac")
	T.ne(code, 0, out)
end)

T.test("--list and --markdown print every function with its side (the README's function list is generated from it)", function()
	local code, out = run("--resource " .. H.res .. " --list")
	T.eq(code, 0, out)
	T.truthy(out:find("setPedControlState", 1, true) and out:find("[client]", 1, true), out)
	T.truthy(out:find("createPed", 1, true) and out:find("[server]", 1, true), out)
	code, out = run("--resource " .. H.res .. " --markdown")
	T.eq(code, 0, out)
	T.truthy(out:find("| `triggerClientEvent` | server |", 1, true), out)
	T.truthy(out:find("| `setPedControlState` | client |", 1, true), out)
end)
