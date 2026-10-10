-- the sim loads and behaves identically when its modules come through sim/bootstrap.lua (no package.path, no filesystem require)
local T = ...
package.path = T.root .. "/?.lua;" .. T.root .. "/tests/?.lua;" .. package.path
local runner = require("sim.runner")
local boot = require("sim.bootstrap")

T.group("loader")

T.test("make_require loads modules from a host-supplied reader, caches them, and reports missing / circular modules", function()
	local files = {
		["m/a.lua"] = 'local b = require("m.b"); return { name = "a", b = b }',
		["m/b.lua"] = 'return { name = "b" }',
		["m/c.lua"] = 'return require("m.d")',
		["m/d.lua"] = 'return require("m.c")',
		["m/n.lua"] = "x = 1",
		["m/bad.lua"] = "return {",
	}
	local reads = 0
	local req = boot.make_require(function(p) reads = reads + 1; return files[p] end)
	local saved = _G.require
	_G.require = req -- the modules above call the global
	local ok, a = pcall(req, "m.a")
	_G.require = saved
	T.truthy(ok, tostring(a))
	T.eq(a.name, "a")
	T.eq(a.b.name, "b")
	T.eq(req("m.a"), a, "cached")
	T.eq(reads, 2)
	T.throws(function() req("m.nope") end, "missing module")
	T.throws(function() req("m.bad") end, "syntax error is reported")
	_G.require = req
	local cyc = pcall(req, "m.c")
	_G.require = saved
	T.falsy(cyc, "circular require is an error, not an infinite loop")
	T.eq(req("m.n"), true, "modules returning nothing load as true")
	T.eq(boot.install(function() return nil end), _G.require, "install does not replace an existing require")
end)

T.test("a fresh process that loads everything through bootstrap reproduces the normal run's state hash", function()
	local interp = (arg and arg[-1]) or "luajit"
	local expected = runner.run({ seed = 21, profile = "escalating", days = 3, max_dt = 1 }).world:hash()
	local ok, p = pcall(io.popen, string.format('"%s" "%s/tests/loader_check.lua" "%s" 3 2>&1', interp, T.root, T.root))
	if not ok or not p then T.note("io.popen unavailable: skipped the subprocess half"); T.truthy(true); return end
	local out = p:read("*a")
	p:close()
	local hash, reload = out:match("LOADER hash=(%x+) reload=(%a+)")
	T.truthy(hash, "child output: " .. out)
	T.eq(hash, expected, "bootstrap-loaded sim == require-loaded sim")
	T.eq(reload, "true")
end)
