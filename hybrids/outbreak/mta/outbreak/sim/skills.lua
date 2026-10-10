-- skills.lua : six skills, xp and a level curve. c.skills[name] = { l = level, xp = total xp }.
local U = require("sim.util")
local TUNING = require("data.tuning")
local traits = require("sim.traits")

local M = {}

M.list = { "shooting", "melee", "construction", "medicine", "scavenging", "cooking" }

-- total xp needed to REACH level L (L = 0 needs none): unit * L * (L + 1) / 2
function M.xp_for_level(L)
	if L <= 0 then return 0 end
	return TUNING.skills.xp_unit * L * (L + 1) / 2
end

function M.max_level() return TUNING.skills.max_level end

function M.level_for_xp(xp)
	local L = 0
	local max = TUNING.skills.max_level
	while L < max and xp >= M.xp_for_level(L + 1) do L = L + 1 end
	return L
end

function M.new(rng, focus)
	local sk = {}
	for i = 1, #M.list do
		local name = M.list[i]
		local lvl = rng:int(0, TUNING.skills.start_level_max)
		if focus and focus == name then lvl = U.min(TUNING.skills.max_level, lvl + 2) end
		sk[name] = { l = lvl, xp = M.xp_for_level(lvl) }
	end
	return sk
end

function M.level(c, name)
	local s = c.skills[name]
	return s and s.l or 0
end

-- speed multiplier from level (0.6 at level 0 .. 1.6 at level 10 by default) x trait multiplier
function M.speed(c, name)
	local t = TUNING.skills
	return (t.speed_base + t.speed_per_level * M.level(c, name)) * traits.skill_mul(c, name)
end

-- add xp (trait multiplier applies); returns number of levels gained
function M.add_xp(c, name, amount)
	local s = c.skills[name]
	if not s or amount <= 0 then return 0 end
	s.xp = s.xp + amount * traits.skill_mul(c, name)
	local gained = 0
	local max = TUNING.skills.max_level
	while s.l < max and s.xp >= M.xp_for_level(s.l + 1) do
		s.l = s.l + 1
		gained = gained + 1
	end
	if s.l >= max then s.xp = U.max(s.xp, M.xp_for_level(max)) end
	return gained
end

return M
