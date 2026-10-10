-- clock.lua : minutes since "day 1, 00:00" (t is an integer-valued number of minutes).
-- Day 1 is the first day. Pure functions; time is always passed in (no os.time here).
local TUNING = require("data.tuning")

local M = {}
local floor = math.floor

M.MIN_PER_DAY = 1440
M.MIN_PER_HOUR = 60

function M.day(t) return floor(t / 1440) + 1 end
function M.minute_of_day(t) return t - floor(t / 1440) * 1440 end
function M.hour(t) return floor(M.minute_of_day(t) / 60) end
function M.hour_f(t) return M.minute_of_day(t) / 60 end
function M.minute(t) return M.minute_of_day(t) % 60 end

function M.at(day, hour, minute) return (day - 1) * 1440 + (hour or 0) * 60 + (minute or 0) end

function M.is_night(t)
	local h = M.hour(t)
	local c = TUNING.clock
	return h >= c.night_start or h < c.night_end
end

-- 0 (dark) .. 1 (full daylight); piecewise linear, no trig
function M.daylight(t)
	local c = TUNING.clock
	local h = M.hour_f(t)
	if h >= c.dawn_end and h <= c.dusk_start then return 1 end
	if h >= c.dawn_start and h < c.dawn_end then return (h - c.dawn_start) / (c.dawn_end - c.dawn_start) end
	if h > c.dusk_start and h < c.dusk_end then return 1 - (h - c.dusk_start) / (c.dusk_end - c.dusk_start) end
	return 0
end

local SEASONS = { "spring", "summer", "autumn", "winter" }
function M.season_index(t)
	local len = TUNING.clock.season_len_days
	return floor((M.day(t) - 1) / len) % 4 + 1
end
function M.season(t) return SEASONS[M.season_index(t)] end

function M.fmt(t)
	return string.format("D%d %02d:%02d", M.day(t), M.hour(t), floor(M.minute(t)))
end

-- set the time of day, keeping the day number
function M.with_time_of_day(t, hour, minute)
	return (M.day(t) - 1) * 1440 + hour * 60 + (minute or 0)
end

return M
