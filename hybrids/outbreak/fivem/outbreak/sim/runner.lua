-- runner.lua : drive a headless colony with the default AI policy. Shared by bin/sim-run.lua, bin/balance.lua,
-- the soak test and the determinism check. Time is advanced in `period`-minute chunks; the policy runs after each.
local U = require("sim.util")
local clock = require("sim.clock")
local World = require("sim.world")
local policy = require("sim.ai_policy")
local director = require("sim.director")

local M = {}

-- opts = { seed, profile, days, colonists, max_dt, policy = true|false, on_events = fn(events), on_day = fn(row, w),
--          on_chunk = fn(w) }
-- The run covers day 1 08:00 up to the end of day `days` (D<days+1> 00:00).
function M.run(opts)
	local days = opts.days or 30
	local w = World.new({ seed = opts.seed or 1, profile = opts.profile or "calm", colonists = opts.colonists, max_dt = opts.max_dt or 1,
		ambient = opts.ambient })
	local st = policy.new()
	local use_policy = opts.policy ~= false
	local end_t = clock.at(days + 1, 0, 0)
	local counts = {}
	local day_counts = {}
	local rows = {}
	local sink = {}
	local first = w:flush_events()
	local function absorb(evs)
		for i = 1, #evs do
			local e = evs[i]
			counts[e.type] = (counts[e.type] or 0) + 1
			day_counts[e.type] = (day_counts[e.type] or 0) + 1
			if e.type == "director_log" then
				local k = "dir_" .. e.cat
				day_counts[k] = (day_counts[k] or 0) + 1
			elseif e.type == "day_start" then
				local sn = w:snapshot()
				local row = { day = e.day - 1, snap = sn, counts = day_counts }
				rows[#rows + 1] = row
				if opts.on_day then opts.on_day(row, w) end
				day_counts = {}
			end
		end
		if opts.on_events then opts.on_events(evs) end
	end
	absorb(first)
	local period = policy.CFG.period
	while w.s.t < end_t and not w.s.over do
		local chunk = period
		if w.s.t + chunk > end_t then chunk = end_t - w.s.t end
		absorb(w:tick(chunk))
		if use_policy then
			for i = 1, #sink do sink[i] = nil end
			policy.step(w, st, sink)
			if #sink > 0 then absorb(sink) end
		end
		if opts.on_chunk then opts.on_chunk(w) end
	end
	local snap = w:snapshot()
	local stats = director.stats(w, days)
	return {
		world = w, survived = (#w.s.colonists > 0), alive = #w.s.colonists, day_reached = clock.day(w.s.t), rows = rows, counts = counts,
		director_events = stats.events, threat_days = stats.threat_days, quiet_days = stats.quiet_days, snapshot = snap,
		stats = w.s.stats, dead = w.s.dead,
	}
end

return M
