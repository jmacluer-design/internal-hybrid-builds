-- Test runner for the MTA adapter. Plain Lua 5.1 (LuaJIT) / 5.4, no dependencies (reuses the sim's tinytest).
--
--   luajit mta/tests/run.lua            lua5.4 mta/tests/run.lua          (any working directory)
--   luajit mta/tests/run.lua host noise  run only files whose name contains one of the words
-- tests/run.sh runs everything under BOTH runtimes plus the sync checks, the function check and the browser test.
local here = (arg and arg[0] or "mta/tests/run.lua"):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local H = require("harness")
local T = require("tinytest")
T.root = H.res
T.H = H

local files = {
	"sync_test",           -- sim / data / shared / ui copies and meta.xml are in sync
	"bootstrap_test",      -- bootstrap_mta.lua: require over the file API, both sides, MTA's disabled require
	"config_test",         -- config, settings in meta.xml, prop model ids against the MTA model-name table
	"json_test",           -- the browser JSON decoder (limits, escapes) and the encoder round trip
	"function_check_test", -- tools/function_check.lua passes on the resource and FAILS on wrong-side / unknown functions, leaked globals, unregistered events
	"mock_test",           -- the mock itself: side filtering, 5.1 library fidelity, event semantics, file API
	"selftest_test",       -- the recorded determinism hash under this runtime
	"server_test",         -- handshake, trust model, persistence, commands, clock, the owner's body
	"peds_test",           -- colonists, hordes, raiders, traders, buildings, piles, ground, ped budget, failure injection
	"client_test",         -- ui bridge, camera, noise, placement, survival, driver, ground
	"integration_test",    -- scripted sim run through server + client + page
	"lifecycle_test",      -- stop / restart / leaks / caps / budgets
}

local only = {}
for i = 1, (arg and #arg or 0) do only[#only + 1] = arg[i] end

for _, name in ipairs(files) do
	local wanted = #only == 0
	for _, o in ipairs(only) do if name:find(o, 1, true) then wanted = true end end
	if wanted then
		print(("== %s"):format(name))
		local chunk, err = loadfile(here .. "/" .. name .. ".lua")
		if not chunk then
			if err and err:find("No such file", 1, true) then
				print("  (not written yet)")
			else
				T.failed = T.failed + 1
				T.failures[#T.failures + 1] = name .. " (failed to load)"
				print("  FAIL  could not load " .. name .. ": " .. tostring(err))
			end
		else
			local ok, e = xpcall(function() return chunk(T, H) end, debug.traceback)
			if not ok then
				T.failed = T.failed + 1
				T.failures[#T.failures + 1] = name .. " (errored)"
				print("  FAIL  " .. name .. " errored: " .. tostring(e))
			end
		end
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
