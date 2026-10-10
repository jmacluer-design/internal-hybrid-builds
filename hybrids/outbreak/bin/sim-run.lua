-- bin/sim-run.lua : run a headless colony with the default AI policy and print a per-day report.
--
--   luajit bin/sim-run.lua --days 30 --seed 7 --profile escalating [--colonists 4] [--step 1] [--no-policy] [--hash]
--   lua5.4 bin/sim-run.lua ...        (same output on both runtimes)
local here = (arg and arg[0] or "bin/sim-run.lua"):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
local root = here .. "/.."
package.path = root .. "/?.lua;" .. package.path

local runner = require("sim.runner")
local save = require("sim.save")
local U = require("sim.util")

local opts = { days = 30, seed = 1, profile = "calm", max_dt = 1, policy = true }
local show_hash = false
local quiet = false
local i = 1
while i <= #arg do
	local a = arg[i]
	local function val() i = i + 1; return arg[i] end
	if a == "--days" then opts.days = tonumber(val())
	elseif a == "--seed" then opts.seed = tonumber(val())
	elseif a == "--profile" then opts.profile = val()
	elseif a == "--colonists" then opts.colonists = tonumber(val())
	elseif a == "--step" then opts.max_dt = tonumber(val())
	elseif a == "--no-policy" then opts.policy = false
	elseif a == "--hash" then show_hash = true
	elseif a == "--quiet" then quiet = true
	elseif a == "--help" or a == "-h" then
		print("usage: sim-run.lua --days N --seed S --profile calm|escalating|chaos [--colonists K] [--step M] [--no-policy] [--hash] [--quiet]")
		os.exit(0)
	else io.stderr:write("unknown argument: " .. a .. "\n"); os.exit(2) end
	i = i + 1
end
if not (opts.profile == "calm" or opts.profile == "escalating" or opts.profile == "chaos") then
	io.stderr:write("profile must be calm, escalating or chaos\n"); os.exit(2)
end

if not quiet then
	print(string.format("outbreak sim-run: seed=%d profile=%s days=%d colonists=%s step=%d policy=%s", opts.seed, opts.profile, opts.days,
		opts.colonists and string.format("%d", opts.colonists) or "default", opts.max_dt, opts.policy and "on" or "off"))
	print("day  col  mood  food drink wealth  hordes(size) raids  def  enc  dir(thr/haz/boon)  hurt  deaths  tasks  notes")
	opts.on_day = function(row, w)
		local sn, c = row.snap, row.counts
		local died = c.colonist_died or 0
		local notes = {}
		if (c.spawn_horde or 0) > 0 then notes[#notes + 1] = "horde-materialized" end
		if (c.spawn_raiders or 0) > 0 then notes[#notes + 1] = "raiders" end
		if (c.caravan or 0) > 0 then notes[#notes + 1] = "caravan" end
		if (c.colonist_joined or 0) > 0 then notes[#notes + 1] = "arrival" end
		if (c.loot_spawn or 0) > 0 then notes[#notes + 1] = "loot" end
		print(string.format("%3d  %3d  %4.1f  %4d %5d %6d  %3d(%5d)  %4d  %4.1f %4.2f  %d/%d/%d              %4d  %6d  %5d  %s",
			row.day, sn.colonists, sn.mood, sn.food, sn.drink, sn.wealth, sn.hordes, sn.horde_size, sn.raids, sn.defense, sn.enclosure,
			c.dir_threat or 0, c.dir_hazard or 0, c.dir_boon or 0, sn.hurt, died, c.colonist_task or 0, table.concat(notes, ",")))
	end
end

local res = runner.run(opts)
local w = res.world
print(string.format("result: %s after %d day(s); colonists alive %d; director events %d (threat days %d, quiet days %d)",
	res.survived and "SURVIVED" or "COLONY FELL", res.day_reached - 1 < opts.days and res.day_reached or opts.days,
	res.alive, res.director_events, res.threat_days, res.quiet_days))
local keys = {}
for k, v in pairs(res.stats) do keys[#keys + 1] = k end -- order-free: sorted next
table.sort(keys)
local parts = {}
for _, k in ipairs(keys) do parts[#parts + 1] = string.format("%s=%s", k, U.fmt_num(res.stats[k])) end
print("stats: " .. table.concat(parts, " "))
for _, d in ipairs(res.dead) do print(string.format("  dead: %s (%s) day %d cause %s%s", d.name, d.id, d.day, d.cause, d.turns and " [turned]" or "")) end
local ok, rep = w:audit()
print("item conservation audit: " .. (ok and "OK" or ("FAILED: " .. rep.problems[1])))
if show_hash then print("state hash: " .. w:hash()) end
os.exit(ok and 0 or 1)
