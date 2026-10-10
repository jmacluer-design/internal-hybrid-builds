-- Test runner for the FiveM adapter. Plain Lua 5.4 / LuaJIT, no dependencies (reuses the sim's tinytest).
--
--   lua5.4 fivem/tests/run.lua           luajit fivem/tests/run.lua          (any working directory)
--   lua5.4 fivem/tests/run.lua host raymath      run only files whose name contains one of the words
-- tests/run.sh runs everything under BOTH runtimes plus tools/native_check.lua and the sim-copy check.
local here = (arg and arg[0] or "fivem/tests/run.lua"):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local H = require("harness")
local T = require("tinytest")
T.root = H.res
T.H = H

local files = {
	"util_test",           -- util + json + msgpack_safe
	"protocol_test",       -- sanitizers, order whitelist
	"raymath_test",        -- camera ray / projection / plane hit
	"placement_test",      -- Lua placement validity vs the real sim on random placements
	"view_test",           -- view models: shape, msgpack safety, size
	"host_test",           -- tick accumulator, catch-up cap, rate limit, orders, inventory, save / load / corruption / rotation, resync, debug
	"native_check_test",   -- tools/native_check.lua: passes on the resource, fails on a bad file
	"native_coverage_test",-- every native the resource uses is implemented by the mock
	"integration_test",    -- server + client in the mock FiveM
	"lifecycle_test",      -- stop / restart / leak accounting / caps / failure injection
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
