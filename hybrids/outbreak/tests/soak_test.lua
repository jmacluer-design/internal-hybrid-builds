-- soak: 30 in-game days x 20 seeds with the default AI policy at 1-minute steps. Asserts no errors, no NaN, no negative inventory,
-- item conservation, reservation invariants, and bounded memory / state growth.
local T = ...
package.path = T.root .. "/?.lua;" .. T.root .. "/tests/?.lua;" .. package.path
local U = require("sim.util")
local runner = require("sim.runner")
local needs = require("sim.needs")
local jobs = require("sim.jobs")
local save = require("sim.save")
local clock = require("sim.clock")
local items = require("sim.items")
local horde = require("sim.horde")
local TUNING = require("data.tuning")

T.group("soak")

local function scan_numbers(v, path, depth, bad)
	local t = type(v)
	if t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then bad[#bad + 1] = path end
	elseif t == "table" and depth < 30 then
		for k, x in pairs(v) do scan_numbers(x, path .. "." .. tostring(k), depth + 1, bad) end -- order-free
	end
end

T.test("30 days x 20 seeds: no errors, NaN, negative inventories; conservation and reservations hold; state and memory stay bounded", function()
	local profiles = { "calm", "escalating", "chaos" }
	local survived, died_early = 0, 0
	local sizes_day10, sizes_day30 = {}, {}
	local heap10, heap30 = {}, {}
	local total_ticks, total_events = 0, 0
	for seed = 1, 20 do
		local profile = profiles[seed % 3 + 1]
		local errors = {}
		local snap10, snap30
		local res
		local ok, err = pcall(function()
			res = runner.run({ seed = 7000 + seed, profile = profile, days = 30, max_dt = 1,
				on_events = function(evs) total_events = total_events + #evs end,
				on_chunk = function(w)
					total_ticks = total_ticks + 10
					local t = w.s.t
					if t % 360 == 0 then -- every six hours: cheap invariants
						local ok1, rep = w:audit()
						if not ok1 then errors[#errors + 1] = "audit: " .. tostring(rep.problems[1]) end
						local ok2, why = jobs.check_reservations(w)
						if not ok2 then errors[#errors + 1] = "reservations: " .. tostring(why) end
						for i = 1, #w.s.colonists do
							local ok3, e3 = needs.check(w.s.colonists[i])
							if not ok3 then errors[#errors + 1] = w.s.colonists[i].id .. ": " .. tostring(e3) end
							for id, n in pairs(w.s.colonists[i].inv.items) do -- order-free
								if n <= 0 or n ~= math.floor(n) then errors[#errors + 1] = "bad inventory count" end
							end
						end
						if horde.materialized_count(w) > TUNING.horde.max_materialized then errors[#errors + 1] = "cap" end
					end
					if t % 1440 == 0 then
						local d = clock.day(t)
						if d == 10 and not snap10 then collectgarbage(); collectgarbage(); snap10 = { heap = collectgarbage("count"), size = #save.save(w) } end
						if d == 30 and not snap30 then collectgarbage(); collectgarbage(); snap30 = { heap = collectgarbage("count"), size = #save.save(w) } end
					end
				end })
		end)
		T.truthy(ok, string.format("seed %d (%s) raised: %s", 7000 + seed, profile, tostring(err)))
		if ok then
			T.eq(#errors, 0, string.format("seed %d (%s): %s", 7000 + seed, profile, errors[1] or ""))
			local bad = {}
			scan_numbers(res.world.s, "s", 0, bad)
			T.eq(#bad, 0, "NaN/inf in state: " .. (bad[1] or ""))
			local aok, arep = res.world:audit()
			T.truthy(aok, "final audit: " .. tostring(arep.problems[1]))
			T.truthy(select(1, save.load(save.save(res.world)) ~= nil))
			if res.survived then survived = survived + 1 else died_early = died_early + 1 end
			if snap10 and snap30 then
				sizes_day10[#sizes_day10 + 1] = snap10.size; sizes_day30[#sizes_day30 + 1] = snap30.size
				heap10[#heap10 + 1] = snap10.heap; heap30[#heap30 + 1] = snap30.heap
			end
		end
	end
	T.note("%d colonies survived 30 days, %d fell; %d ticks, %d events (%.1f events per tick)", survived, died_early, total_ticks, total_events, total_events / math.max(1, total_ticks))
	T.gt(survived + died_early, 19)
	-- bounded growth for colonies that were still alive on day 30
	T.gt(#sizes_day30, 0, "at least one colony reached day 30 alive")
	for i = 1, #sizes_day30 do
		T.lt(sizes_day30[i], sizes_day10[i] * 2.5 + 20000, "save size at day 30 vs day 10")
		T.lt(heap30[i], heap10[i] * 2.5 + 4000, "Lua heap (KB) at day 30 vs day 10")
	end
end)
