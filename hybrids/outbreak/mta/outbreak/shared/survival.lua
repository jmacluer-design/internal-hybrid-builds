-- shared/survival.lua : the PLAYER's body (hunger, thirst, fatigue, bleeding, pain, infection).
-- The sim core simulates colonists only (the player is just an observer with an inventory), so this module re-uses the sim's own
-- `needs` rules (same rates, same wound / infection state machine) on a colonist-shaped record that lives in the host, not in the
-- sim state. It is saved in the host's extras. Pure Lua; game-agnostic.
local U = require("shared.util")
local SU = require("sim.util")
local TUNING = require("data.tuning")
local ITEMS = require("data.items")
local needs = require("sim.needs")
local rng_mod = require("sim.rng")

local S = {}
S.__index = S

local function new_record()
	local c = { hp_max = TUNING.colonist.hp_max, traits = {}, maimed = 0, dead = false, downed = false }
	needs.init(c)
	c.hunger, c.thirst, c.fatigue = 15, 15, 10
	return c
end

function S.new(seed)
	local self = setmetatable({}, S)
	self.c = new_record()
	self.rng = rng_mod.new((seed or 1) * 7 + 13)
	self.t = 0
	self.deaths = 0
	return self
end

-- plain-data form for the save file
function S:save() return { c = self.c, rng = { seed = self.rng.seed, s = self.rng.s }, t = self.t, deaths = self.deaths } end

function S.load(data)
	if type(data) ~= "table" or type(data.c) ~= "table" then return nil end
	local self = setmetatable({}, S)
	self.c = data.c
	needs.init(self.c)
	self.c.traits = self.c.traits or {}
	self.rng = rng_mod.attach(data.rng or { seed = 1, s = 1 })
	self.t = data.t or 0
	self.deaths = data.deaths or 0
	return self
end

-- advance `dt` minutes. activity: "idle" | "work" | "rest" | "sleep". Returns an array of {kind=...} notices.
function S:step(dt, activity, now)
	local c = self.c
	if c.dead or dt <= 0 then return {} end
	self.t = now or (self.t + dt)
	local env = { now = self.t, activity = activity or "idle", rest_q = 1, rng = self.rng, heal_mult = 1 }
	local evs = needs.step(c, dt, env) or {}
	local out = {}
	for i = 1, #evs do
		local k = evs[i].kind
		if k == "died" then self.deaths = self.deaths + 1 end
		out[#out + 1] = { kind = k, cause = evs[i].cause }
	end
	return out
end

-- game damage to the player. kind: bite scratch cut bullet blunt fall fire explosion
function S:damage(kind, amount, part)
	local c = self.c
	if c.dead then return nil end
	local info = needs.wound(c, self.rng, kind, U.clamp(amount, 0, 500), part)
	local v = needs.check_vitals(c)
	return info, v
end

-- consume an item's effect. Returns ok, message. (The caller removes the item from the inventory.)
function S:use(item_id, now)
	local c = self.c
	local d = ITEMS[item_id]
	if not d then return false, "unknown item" end
	if c.dead then return false, "you are dead" end
	if d.food then
		needs.eat(c, d.food)
		return true, "ate " .. d.name
	end
	if d.med then
		local k = d.med.kind
		if k == "bandage" then
			local closed = needs.treat_bleeding(c, self.rng, 1)
			return true, closed > 0 and "bleeding stopped" or "bandage applied"
		elseif k == "kit" then
			needs.treat_bleeding(c, self.rng, 2)
			needs.heal(c, 25)
			return true, "wounds treated"
		elseif k == "antibiotic" then
			if c.inf.stage == "none" then return true, "course taken (nothing to treat)" end
			local cured = needs.treat_infection(c, self.rng, 0, 0)
			return true, cured and "infection cured" or "infection slowed"
		elseif k == "painkiller" then
			needs.take_painkiller(c, now or self.t)
			return true, "pain dulled"
		end
		return false, "cannot use that alone"
	end
	return false, "nothing happens"
end

function S:respawn()
	self.c = new_record()
end

function S:view()
	local c = self.c
	local inf = c.inf.stage
	if inf == "incubating" then inf = "none" end -- hidden, like for colonists
	return {
		hp = c.hp, hp_max = c.hp_max, hunger = c.hunger, thirst = c.thirst, fatigue = c.fatigue, pain = needs.perceived_pain(c, self.t),
		bleeding = needs.bleeding(c), infection = inf, downed = c.downed, dead = c.dead,
	}
end

-- what the client needs to apply to the ped: health 0..1, bleeding flag, sprint allowed
function S:effects()
	local c = self.c
	local v = self:view()
	return {
		health = U.clamp(c.hp / c.hp_max, 0, 1), bleeding = v.bleeding > 0.02, sprint = c.fatigue < 85 and c.hp > 20 and not c.downed,
		limp = c.hp < c.hp_max * 0.3, dead = c.dead,
	}
end

return S
