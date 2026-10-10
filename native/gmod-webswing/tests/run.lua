-- Test runner for Web Swing. Plain Lua 5.1+ / LuaJIT, no dependencies.
--
--   luajit tests/run.lua        (from the addon folder; any working directory works)
--   lua5.1 tests/run.lua
--
-- SkateGM ships a LuaJIT for Windows in its harness folder; this runs under it too:
--   <skategm>\harness\win\luajit.exe tests\run.lua
--
-- Runs every tests/*_test.lua. Exit status is non-zero when anything fails.

local here = (arg and arg[0] or "tests/run.lua"):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
local root = here:gsub("/tests$", "")
if root == here then root = here .. "/.." end -- run from inside tests/
package.path = here .. "/?.lua;" .. package.path

local T = require("tinytest")
T.root = root

local files = {
	"swing_test",   -- the pure math (lua/webswing/sh_swing.lua)
	"glue_test",    -- the GMod-facing Lua under a mock GMod (hooks, convars, traces, SkateGM compat)
}
-- run only some: luajit tests/run.lua swing
local only = {}
for i = 1, (arg and #arg or 0) do only[#only + 1] = arg[i] end

local ran = 0
for _, name in ipairs(files) do
	local wanted = #only == 0
	for _, o in ipairs(only) do if name:find(o, 1, true) then wanted = true end end
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

print(("\n%d passed, %d failed (%s)"):format(T.passed, T.failed, _VERSION .. (jit and (" / " .. jit.version) or "")))
if T.failed > 0 then
	for _, f in ipairs(T.failures) do print("  failed: " .. f) end
	os.exit(1)
end
os.exit(0)
