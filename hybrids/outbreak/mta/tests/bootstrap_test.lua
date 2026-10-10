-- bootstrap_mta.lua: `require` over fileExists / fileOpen / fileRead / loadstring, on both sides, in the mock's MTA-faithful sandboxes.
local T, H = ...
T.group("bootstrap")

local function fresh_side(m, name)
	local side = m.sides[name] or m:make_side(name)
	m:load_script(side, "bootstrap_mta.lua")
	return side
end

T.test("before install, `require` is MTA's disabled stub; after install it loads resource files on the server", function()
	local m = H.Mock.new({ root = H.res, defs = false })
	local side = fresh_side(m, "server")
	local env = side.env
	T.eq(env.require("sim.world"), false, "MTA's stock require is a disabled stub that returns false")
	env.OB_BOOT.install()
	local World = env.require("sim.world")
	T.eq(type(World.new), "function")
	T.eq(env.require("sim.world"), World, "cached")
	local ok, err = pcall(env.require, "sim.no_such_module")
	T.falsy(ok)
	T.truthy(tostring(err):find("not found", 1, true) and tostring(err):find("meta.xml", 1, true), "the error names the path and the likely cause: " .. tostring(err))
end)

T.test("the loaded sim is the real thing: it runs a colony and reproduces the recorded self-test hash", function()
	local m = H.Mock.new({ root = H.res, defs = false })
	local side = fresh_side(m, "server")
	side.env.OB_BOOT.install()
	local S = side.env.require("shared.selftest")
	local ok, r = S.check()
	T.truthy(ok, "selftest under the 5.1-faithful sandbox: " .. tostring(r.error) .. " hash " .. tostring(r.hash) .. " expected " .. tostring(r.expected))
	T.eq(r.reload_ok, true)
end)

T.test("circular requires are an error, modules are loaded once, a module's return value (or true) is what require gives back", function()
	local fs = { server = { ["a.lua"] = 'return require("b")', ["b.lua"] = 'return require("a")', ["c.lua"] = "_G.x_loaded = (rawget(_G, \"x_loaded\") or 0) + 1", ["d.lua"] = "return { n = 5 }" }, client = {} }
	local m = H.Mock.new({ root = H.res, defs = false, fs = fs })
	local side = fresh_side(m, "server")
	local req = side.env.OB_BOOT.install()
	local ok, err = pcall(req, "a")
	T.falsy(ok); T.truthy(tostring(err):find("circular", 1, true), tostring(err))
	T.eq(req("c"), true, "a module that returns nothing gives true")
	T.eq(req("c"), true)
	T.eq(rawget(side.env, "x_loaded"), 1, "loaded once")
	T.eq(req("d").n, 5)
	-- a syntax error is reported with the chunk name
	m.fs.server["e.lua"] = "local x = = 1"
	local ok2, err2 = pcall(req, "e")
	T.falsy(ok2); T.truthy(tostring(err2):find("e.lua", 1, true), tostring(err2))
end)

T.test("the client only sees the files it downloaded: client / shared modules load, server-only modules do not", function()
	local m = H.Mock.new({ root = H.res, defs = false })
	local side = fresh_side(m, "client")
	local req = side.env.OB_BOOT.install()
	T.eq(type(req("shared.util").clamp), "function")
	T.eq(type(req("shared.protocol").sanitize_in), "function")
	T.eq(type(req("shared.mta_net").hello), "string")
	for _, name in ipairs({ "sim.world", "data.tuning", "shared.host", "shared.view", "shared.survival", "server.main", "shared.selftest" }) do
		local ok, err = pcall(req, name)
		T.falsy(ok, name .. " is server-only and must not be readable on the client")
		T.truthy(tostring(err):find("not found", 1, true), tostring(err))
	end
end)

T.test("the file API is used correctly: every opened file is closed, only read mode, a missing file is nil not an error", function()
	local m = H.Mock.new({ root = H.res, defs = false })
	local side = fresh_side(m, "server")
	T.eq(side.env.OB_BOOT.read_file("sim/world.lua") ~= nil, true)
	T.eq(side.env.OB_BOOT.read_file("sim/missing.lua"), nil)
	T.eq(m.open_files, 0, "no file handle leaked")
	T.eq(#m:live("file"), 0)
end)

T.test("MTA 5.1 sandbox: load() takes a reader function, loadstring rejects precompiled chunks", function()
	local m = H.Mock.new({ root = H.res, defs = false })
	local side = fresh_side(m, "server")
	T.throws(function() side.env.load("return 1") end)
	local fn = side.env.loadstring("return 41 + 1")
	T.eq(fn(), 42)
	T.eq((side.env.loadstring("\27Lua garbage")), nil)
end)
