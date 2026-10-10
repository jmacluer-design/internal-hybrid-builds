-- bin/balance.lua : run many seeds per pacing profile and print survival-to-day-30 and median events/day.
--
--   luajit bin/balance.lua [--seeds 200] [--days 30] [--step 5] [--first 1] [--profiles calm,escalating,chaos] [--colonists 4]
--
-- "Survival" = at least one colonist is still alive when day <days> ends (the colony has not fallen).
-- "Events/day" = director events (threat + hazard + boon) fired per in-game day; the median is over seeds.
-- Targets (TUNING balance goals): calm 85-95% survive, escalating 35-60%, chaos 20-45%.
-- --step is the internal time step in minutes (default 5 for speed; the soak test and the hash test use 1).
local here = (arg and arg[0] or "bin/balance.lua"):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local runner = require("sim.runner")

local opts = { seeds = 200, days = 30, step = 5, first = 1, colonists = nil, profiles = { "calm", "escalating", "chaos" } }
local i = 1
while i <= #arg do
	local a = arg[i]
	local function val() i = i + 1; return arg[i] end
	if a == "--seeds" then opts.seeds = tonumber(val())
	elseif a == "--days" then opts.days = tonumber(val())
	elseif a == "--step" then opts.step = tonumber(val())
	elseif a == "--first" then opts.first = tonumber(val())
	elseif a == "--colonists" then opts.colonists = tonumber(val())
	elseif a == "--profiles" then
		opts.profiles = {}
		for p in val():gmatch("[^,]+") do opts.profiles[#opts.profiles + 1] = p end
	elseif a == "--help" or a == "-h" then
		print("usage: balance.lua [--seeds N] [--days N] [--step M] [--first S] [--profiles a,b,c] [--colonists K]")
		os.exit(0)
	else io.stderr:write("unknown argument: " .. a .. "\n"); os.exit(2) end
	i = i + 1
end

local function median(list)
	table.sort(list)
	local n = #list
	if n == 0 then return 0 end
	if n % 2 == 1 then return list[(n + 1) / 2] end
	return (list[n / 2] + list[n / 2 + 1]) / 2
end

local TARGETS = { calm = { 85, 95 }, escalating = { 35, 60 }, chaos = { 20, 45 } }

print(string.format("balance: %d seeds x %d days per profile, step %d min, colonists %s", opts.seeds, opts.days, opts.step,
	opts.colonists and string.format("%d", opts.colonists) or "default"))
print("profile      survive   target    alive(avg) events/day(median)  threat-days(med)  quiet-days(med)  mean last-day  deaths(zomb/infect/other)")
local summary = {}
for _, profile in ipairs(opts.profiles) do
	local survived, alive_sum = 0, 0
	local epd, tdays, qdays, lastday = {}, {}, {}, 0
	local d_zomb, d_inf, d_other = 0, 0, 0
	for k = 0, opts.seeds - 1 do
		local r = runner.run({ seed = opts.first + k, profile = profile, days = opts.days, colonists = opts.colonists, max_dt = opts.step })
		if r.survived then survived = survived + 1 end
		alive_sum = alive_sum + r.alive
		local days_run = math.min(r.day_reached, opts.days)
		epd[#epd + 1] = r.director_events / math.max(1, days_run)
		tdays[#tdays + 1] = r.threat_days
		qdays[#qdays + 1] = r.quiet_days
		lastday = lastday + days_run
		for _, d in ipairs(r.dead) do
			if d.left then d_other = d_other + 1
			elseif d.cause == "zombies" then d_zomb = d_zomb + 1
			elseif d.cause == "infection" then d_inf = d_inf + 1
			else d_other = d_other + 1 end
		end
	end
	local rate = 100 * survived / opts.seeds
	local t = TARGETS[profile]
	local tgt = t and string.format("%d-%d%%", t[1], t[2]) or "-"
	local flag = (t and rate >= t[1] and rate <= t[2]) and "in range" or (t and "OUT OF RANGE" or "")
	print(string.format("%-11s  %5.1f%%   %-8s  %6.2f     %8.2f             %6.1f            %6.1f          %5.1f         %d/%d/%d   %s",
		profile, rate, tgt, alive_sum / opts.seeds, median(epd), median(tdays), median(qdays), lastday / opts.seeds, d_zomb, d_inf, d_other, flag))
	summary[profile] = rate
end
