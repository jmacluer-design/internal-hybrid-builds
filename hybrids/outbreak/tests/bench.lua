-- Performance bench: 30 colonists, ~200 item stacks, 12 hordes, one tick per game minute.
--   luajit tests/bench.lua        lua5.4 tests/bench.lua
-- Prints ms per tick (wall clock via os.clock, which the sim itself never uses) for the bare sim and for the sim driven by
-- the default AI policy. Target: < 2 ms/tick on LuaJIT; the script flags anything worse. Also usable as a module (returns M.run).
local M = {}

function M.run(root, ticks)
	package.path = root .. "/?.lua;" .. package.path
	local World = require("sim.world")
	local policy = require("sim.ai_policy")
	local TUNING = require("data.tuning")
	local items = require("sim.items")
	local blueprints = require("sim.blueprints")
	local U = require("sim.util")
	local stockpile = require("sim.stockpile")
	ticks = ticks or 1440

	local function build(seed)
		local w = World.new({ seed = seed, profile = "escalating", colonists = 30, ambient = 0, max_dt = 1 })
		w:flush_events()
		-- exactly 12 hordes spread around the base (far enough apart that they do not merge)
		local horde = require("sim.horde")
		for i = 1, 12 do
			local dir = horde.DIRS[(i - 1) % 16 + 1]
			local dist = 1000 + (i % 3) * 450
			horde.spawn(w, { x = dir[1] * dist, y = dir[2] * dist, mix = { walker = 12 + i, runner = i % 4 }, src = "ambient" })
		end
		-- 200+ item stacks: five extra zones each holding one stack of every item id, plus a big main store with plenty of
		-- food and water so the colony stays active for the whole run
		local ids = items.all_ids()
		local z = w.s.zones[1]
		z.items.cap = nil
		for zi = 1, 5 do
			local extra = stockpile.new(w:new_id("z"), "Bench " .. string.format("%d", zi), { x = -40 + zi * 15, y = 70, z = 0 }, 2, 1, {})
			extra.items.cap = nil
			w:add_zone(extra)
			for i = 1, #ids do w:create(extra.items, ids[i], 2 + (i + zi) % 4, "bench") end
		end
		w:create(z.items, "canned_beans", 400, "bench")
		w:create(z.items, "water_bottle", 400, "bench")
		for i = 1, 8 do
			local p = w:pile_for({ x = -90 + i * 20, y = 60, z = 0 })
			w:create(p.items, ids[(i * 11) % #ids + 1], 4, "bench")
		end
		for i = 1, 10 do blueprints.place(w, (i % 2 == 0) and "wall" or "bed", { x = -60 + i * 9, y = -40, z = 0 }) end
		return w
	end

	local function stack_count(w)
		local n = 0
		for i = 1, #w.s.zones do n = n + U.count(w.s.zones[i].items.items) end
		return n
	end

	local function measure(use_policy)
		local w = build(42)
		local st = policy.new()
		-- warm up (JIT, caches, job board)
		for _ = 1, 180 do
			w:tick(1)
			if use_policy and w.s.t % 10 == 0 then policy.step(w, st, nil) end
		end
		local t0 = os.clock()
		local events, busy_samples, busy = 0, 0, 0
		for i = 1, ticks do
			local evs = w:tick(1)
			events = events + #evs
			if use_policy and w.s.t % 10 == 0 then policy.step(w, st, nil) end
			if i % 10 == 0 then
				busy_samples = busy_samples + #w.s.colonists
				for k = 1, #w.s.colonists do if w.s.colonists[k].job then busy = busy + 1 end end
			end
		end
		local dt = os.clock() - t0
		local alive = #w.s.colonists
		return { ms_per_tick = dt * 1000 / ticks, seconds = dt, colonists = alive, hordes = #w.s.hordes, stacks = stack_count(w),
			events_per_tick = events / ticks, busy = (busy_samples > 0) and busy / busy_samples or 0 }
	end
	local raw = measure(false)
	local with_policy = measure(true)
	return { raw = raw, policy = with_policy, ticks = ticks }
end

-- run as a script
local here = (arg and arg[0] or "tests/bench.lua"):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
if arg and arg[0] and arg[0]:find("bench%.lua$") then
	local root = here:gsub("/tests$", "")
	if root == here then root = here .. "/.." end
	local rt = jit and jit.version or _VERSION
	local r = M.run(root, tonumber(arg[1]) or 1440)
	print(string.format("bench (%s): 30 colonists, 12 hordes, %d ticks at 1 tick per game minute", rt, r.ticks))
	for _, row in ipairs({ { "bare sim      ", r.raw }, { "with AI policy", r.policy } }) do
		print(string.format("  %s: %.3f ms/tick  (%.2f s total; %d colonists alive, %.0f%% busy, %d hordes, %d item stacks, %.2f events/tick)", row[1],
			row[2].ms_per_tick, row[2].seconds, row[2].colonists, row[2].busy * 100, row[2].hordes, row[2].stacks, row[2].events_per_tick))
	end
	local target = 2.0
	local worst = math.max(r.raw.ms_per_tick, r.policy.ms_per_tick)
	if jit then
		print(worst < target and string.format("  OK: under the %.1f ms/tick LuaJIT target", target) or string.format("  FLAG: over the %.1f ms/tick LuaJIT target", target))
	else
		print(string.format("  (PUC Lua: informational; the %.1f ms/tick target applies to LuaJIT)", target))
	end
end

return M
