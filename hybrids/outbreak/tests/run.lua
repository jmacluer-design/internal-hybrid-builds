-- Test runner for the Outbreak sim core. Plain Lua 5.1+ / LuaJIT / Lua 5.4, no dependencies.
--
--   luajit tests/run.lua            lua5.4 tests/run.lua          (any working directory)
--   luajit tests/run.lua fast       skip the slow soak / bench files
--   luajit tests/run.lua rng jobs   run only files whose name contains one of the words
--
-- Runs every tests/*_test.lua listed below. Exit status is non-zero when anything fails.
-- tests/run.sh runs the whole suite under BOTH runtimes and compares the cross-runtime hash.

local here = (arg and arg[0] or "tests/run.lua"):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
local root = here:gsub("/tests$", "")
if root == here then root = here .. "/.." end -- run from inside tests/
package.path = here .. "/?.lua;" .. root .. "/?.lua;" .. package.path

local T = require("tinytest")
T.root = root

local files = {
	"rng_test",        -- Park-Miller stream: determinism, distribution, forks
	"util_test",       -- util, clock, portability lint of every source file
	"loader_test",     -- sim/bootstrap.lua: loading the sim without package.path (FiveM-style) gives identical results
	"items_test",      -- items/containers/loot + data validation
	"needs_test",      -- needs, infection state machine, mood, skills, traits, colonist
	"build_test",      -- blueprints, prerequisites, power + water networks
	"jobs_test",       -- job board, priorities, reservations, interruption, starvation bound
	"horde_test",      -- hordes: drift, noise, materialize hysteresis, cap, combat
	"expedition_test", -- expeditions
	"faction_test",    -- factions: relations, raids, caravans, trade
	"director_test",   -- director budgets, cooldowns, profiles
	"world_test",      -- orchestrator, IN events, orders, determinism
	"save_test",       -- serializer, round trip, migrations
	"fuzz_test",       -- property-style fuzz: conservation under 1000+ random operations
	"contract_test",   -- API.md vs the events the sim really emits / accepts
	"hash_test",       -- same-process determinism + fixed-seed hash (compared across runtimes by run.sh)
	"soak_test",       -- 30 days x 20 seeds  (slow)
	"bench_test",      -- performance bench   (slow)
}
local slow = { soak_test = true, bench_test = true }

local only, fast = {}, false
for i = 1, (arg and #arg or 0) do
	if arg[i] == "fast" then fast = true else only[#only + 1] = arg[i] end
end

local ran = 0
for _, name in ipairs(files) do
	local wanted = #only == 0
	for _, o in ipairs(only) do if name:find(o, 1, true) then wanted = true end end
	if fast and slow[name] then wanted = false end
	if wanted then
		print(("== %s"):format(name))
		local chunk, err = loadfile(here .. "/" .. name .. ".lua")
		if not chunk then
			T.failed = T.failed + 1
			T.failures[#T.failures + 1] = name .. " (failed to load)"
			print("  FAIL  could not load " .. name .. ": " .. tostring(err))
		else
			local ok, e = xpcall(function() return chunk(T) end, debug.traceback) -- (5.1's xpcall takes no extra arguments)
			if not ok then
				T.failed = T.failed + 1
				T.failures[#T.failures + 1] = name .. " (errored)"
				print("  FAIL  " .. name .. " errored: " .. tostring(e))
			end
		end
		ran = ran + 1
	end
end

print("\nassertions per group:")
local names = {}
for g in pairs(T.groups) do names[#names + 1] = g end
table.sort(names)
for _, g in ipairs(names) do print(("  %-28s %5d assertions in %3d tests"):format(g, T.groups[g].asserts, T.groups[g].tests)) end

print(("\n%d tests passed, %d failed, %d assertions (%s)"):format(T.passed, T.failed, T.asserts, _VERSION .. (jit and (" / " .. jit.version) or "")))
if T.failed > 0 then
	for _, f in ipairs(T.failures) do print("  failed: " .. f) end
	os.exit(1)
end
os.exit(0)
