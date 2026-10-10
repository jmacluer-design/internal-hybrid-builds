-- determinism inside one process, plus the shape of the cross-runtime hash output (the real cross-runtime comparison is done by tests/run.sh,
-- which runs tests/hash_check.lua under both runtimes and diffs the output).
local T = ...
package.path = T.root .. "/?.lua;" .. T.root .. "/tests/?.lua;" .. package.path
local runner = require("sim.runner")
local save = require("sim.save")

T.group("determinism")

T.test("a 30-day headless run from a fixed seed gives the same state hash every time in this process", function()
	local a = runner.run({ seed = 1, profile = "calm", days = 30, max_dt = 1 })
	local b = runner.run({ seed = 1, profile = "calm", days = 30, max_dt = 1 })
	T.eq(a.world:hash(), b.world:hash())
	T.eq(#a.world:hash(), 16)
	T.eq(a.day_reached, b.day_reached)
	T.truthy(select(1, a.world:audit()))
	local text = save.save(a.world)
	T.eq(save.load(text):hash(), a.world:hash(), "and survives a save/load")
	T.note("%s: calm seed 1, 30 days: hash %s, %d colonists alive on day %d", jit and jit.version or _VERSION, a.world:hash(), a.alive, a.day_reached)
	T.truthy(a.alive >= 0)
end)

T.test("different seeds and profiles give different hashes", function()
	local seen = {}
	local n = 0
	for _, spec in ipairs({ { 1, "calm" }, { 2, "calm" }, { 1, "chaos" }, { 3, "escalating" } }) do
		local r = runner.run({ seed = spec[1], profile = spec[2], days = 4, max_dt = 1 })
		local h = r.world:hash()
		T.falsy(seen[h], "collision")
		seen[h] = true
		n = n + 1
	end
	T.eq(n, 4)
end)

T.test("step size changes the trajectory deterministically (max_dt is part of the configuration, not noise)", function()
	local a = runner.run({ seed = 5, profile = "calm", days = 6, max_dt = 5 })
	local b = runner.run({ seed = 5, profile = "calm", days = 6, max_dt = 5 })
	T.eq(a.world:hash(), b.world:hash())
end)
