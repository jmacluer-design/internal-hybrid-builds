-- shared/selftest.lua : a short seeded colony run whose state hash is known (recorded under LuaJIT AND Lua 5.4 by tools/gen_selftest.lua; tests/selftest_test.lua keeps the
-- recorded value current). The server runs it a moment after start: MTA's Lua is PUC Lua 5.1 (a third runtime this repo cannot run), so this is the one check that tells the
-- owner, inside the real game server, whether the sim is deterministic there (string.format("%d") with big numbers, table.sort, number formatting ...). It also proves that
-- save -> load reproduces the state. Written here; nothing borrowed.
local S = {}

S.PLAN = { seed = 4242, profile = "escalating", days = 2 }

-- returns a result table: { hash, reload_ok, bytes, alive, ms } or { error = "..." }
function S.run()
	local runner = require("sim.runner")
	local save = require("sim.save")
	local t0 = os.clock()
	local ok, res = pcall(runner.run, { seed = S.PLAN.seed, profile = S.PLAN.profile, days = S.PLAN.days, max_dt = 1 })
	if not ok then return { error = tostring(res) } end
	local w = res.world
	local ok2, blob = pcall(save.save, w)
	if not ok2 then return { error = "save failed: " .. tostring(blob) } end
	local back, err = save.load(blob)
	return { hash = w:hash(), reload_ok = (back ~= nil and back:hash() == w:hash()), reload_error = err, bytes = #blob, alive = res.alive, ms = math.floor((os.clock() - t0) * 1000) }
end

-- run and compare with the recorded hash: returns ok, result (result.expected is the recorded hash)
function S.check()
	local r = S.run()
	local data = require("shared.selftest_data")
	r.expected = data.hash
	r.ok = (r.error == nil) and r.hash == data.hash and r.reload_ok == true
	return r.ok, r
end

return S
