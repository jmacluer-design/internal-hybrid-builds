-- performance bench: 30 colonists, 200+ item stacks, 12 hordes, one tick per game minute. Numbers are printed; the LuaJIT
-- target is < 2 ms/tick (anything worse fails this test, i.e. is flagged). Run tests/bench.lua directly for the same table.
local T = ...
package.path = T.root .. "/?.lua;" .. T.root .. "/tests/?.lua;" .. package.path
local bench = require("bench")

T.group("bench")

T.test("30 colonists / 200+ item stacks / 12 hordes: ms per tick at 1 tick per game minute", function()
	local r = bench.run(T.root, 1440)
	local runtime = jit and jit.version or _VERSION
	T.note("%s: bare sim %.3f ms/tick, with AI policy %.3f ms/tick (%d colonists, %d hordes, %d stacks, %.0f%% busy)", runtime,
		r.raw.ms_per_tick, r.policy.ms_per_tick, r.raw.colonists, r.raw.hordes, r.raw.stacks, r.raw.busy * 100)
	T.finite(r.raw.ms_per_tick)
	T.finite(r.policy.ms_per_tick)
	T.eq(r.raw.colonists, 30, "the whole colony stayed alive for the measurement")
	T.ge(r.raw.stacks, 200, "at least 200 item stacks in play")
	T.ge(r.raw.hordes, 10, "about a dozen hordes in play")
	local worst = math.max(r.raw.ms_per_tick, r.policy.ms_per_tick)
	if jit then
		if worst >= 2.0 then T.note("FLAG: %.3f ms/tick is over the 2 ms LuaJIT target", worst) end
		T.lt(worst, 2.0, "LuaJIT target: < 2 ms/tick")
	else
		T.lt(worst, 10.0, "PUC Lua sanity bound")
	end
end)
