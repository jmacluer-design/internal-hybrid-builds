-- Cross-runtime determinism check: prints the state hash of fixed 30-day headless runs (default AI policy, 1-minute steps).
-- tests/run.sh runs this under luajit and lua5.4 and fails unless the outputs are byte-identical.
--   luajit tests/hash_check.lua [days]
local here = (arg and arg[0] or "tests/hash_check.lua"):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
local root = here:gsub("/tests$", "")
if root == here then root = here .. "/.." end
package.path = root .. "/?.lua;" .. package.path

local runner = require("sim.runner")
local save = require("sim.save")
local U = require("sim.util")

local days = tonumber(arg and arg[1]) or 30
local runs = {
	{ seed = 1, profile = "calm" },
	{ seed = 2, profile = "escalating" },
	{ seed = 3, profile = "chaos" },
	{ seed = 11, profile = "calm" },
}
for _, r in ipairs(runs) do
	local res = runner.run({ seed = r.seed, profile = r.profile, days = days, max_dt = 1 })
	local w = res.world
	local saved = save.save(w)
	local back = save.load(saved)
	print(string.format("HASH %-10s seed=%-3d days=%d alive=%d day_reached=%d hash=%s save_bytes=%d reload_equal=%s",
		r.profile, r.seed, days, res.alive, res.day_reached, w:hash(), #saved, tostring(back:hash() == w:hash())))
	local keys = U.keys(res.stats)
	local parts = {}
	for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. U.fmt_num(res.stats[k]) end
	print("  stats " .. table.concat(parts, " "))
end
