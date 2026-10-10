-- data/traits.lua : original colonist traits.
--   mul    = multiplicative modifiers (multiplied together over all of a colonist's traits)
--   add    = additive modifiers (summed)
--   skill_mul = { skill = xp+speed multiplier }
--   thoughts  = { thought_id = multiplier on that thought's value }
--   blocks    = work types the colonist can never do (priority forced to 0)
--   excludes  = trait ids that cannot be rolled together with this one
--   schedule  = "day" | "night" | "early" sleep pattern preset
-- Known keys:
--   mul: hunger_rate thirst_rate fatigue_rate pain_taken infection_progress work_speed_night work_speed_day
--        combat_power loot_luck_mul   add: mood_base carry_g hp_max loot_luck cure_bonus crowd_pen social_bonus
local TR = {}

local function tr(id, d) d.id = id; TR[id] = d end

tr("iron_gut", { name = "Iron gut", desc = "Eats anything. Slower hunger, does not mind tinned food.",
	mul = { hunger_rate = 0.85 }, thoughts = { ate_canned = 0 }, excludes = { "glutton" } })
tr("glutton", { name = "Glutton", desc = "Hungry often, but a good meal means a lot.",
	mul = { hunger_rate = 1.2 }, thoughts = { ate_fine_meal = 1.6, ate_sweet = 1.5, ate_canned = 1.5 }, excludes = { "iron_gut" } })
tr("night_owl", { name = "Night owl", desc = "Sharper after dark, groggy at noon. Sleeps by day.",
	mul = { work_speed_night = 1.15, work_speed_day = 0.95 }, schedule = "night", excludes = { "early_bird" } })
tr("early_bird", { name = "Early bird", desc = "Up before dawn and tires a little slower.",
	mul = { fatigue_rate = 0.95 }, schedule = "early", excludes = { "night_owl" } })
tr("steady_hands", { name = "Steady hands", desc = "Careful with bandages and tools.",
	skill_mul = { medicine = 1.15, construction = 1.1 }, add = { cure_bonus = 0.04 } })
tr("jumpy", { name = "Jumpy", desc = "Quick on the trigger, rattled by hordes.",
	skill_mul = { shooting = 1.1 }, thoughts = { horde_near = 2.0, saw_death = 1.3 } })
tr("packrat", { name = "Packrat", desc = "Carries a lot.", add = { carry_g = 6000 } })
tr("lucky", { name = "Lucky", desc = "Finds a little extra on every run.", add = { loot_luck = 0.15 } })
tr("pacifist", { name = "Pacifist", desc = "Will not stand guard or fight unless cornered.",
	blocks = { "guard" }, mul = { combat_power = 0.35 }, skill_mul = { shooting = 0.5, melee = 0.5 },
	thoughts = { saw_death = 1.5 }, excludes = { "bloodthirsty" } })
tr("thick_skinned", { name = "Thick skinned", desc = "Pain barely registers.",
	mul = { pain_taken = 0.6 }, thoughts = { bitten = 0.7, close_call = 0.7 } })
tr("loner", { name = "Loner", desc = "Crowds wear them down.", add = { mood_base = 2, crowd_pen = 0.9 }, excludes = { "sociable" } })
tr("sociable", { name = "Sociable", desc = "Likes company.", add = { social_bonus = 0.8 }, excludes = { "loner" } })
tr("optimist", { name = "Optimist", desc = "Sees the bright side.", add = { mood_base = 8 }, excludes = { "pessimist" } })
tr("pessimist", { name = "Pessimist", desc = "Expects the worst.", add = { mood_base = -7 }, excludes = { "optimist" } })
tr("tinkerer", { name = "Tinkerer", desc = "Good with hands and stoves.",
	skill_mul = { construction = 1.2, cooking = 1.15 } })
tr("bloodthirsty", { name = "Bloodthirsty", desc = "Enjoys a fight. Death rolls off them.",
	skill_mul = { melee = 1.25, shooting = 1.1 }, mul = { combat_power = 1.15 },
	thoughts = { saw_death = 0.2, survived_attack = 1.5 }, excludes = { "pacifist" } })
tr("sickly", { name = "Sickly", desc = "Fragile. Infections run faster.",
	mul = { infection_progress = 1.25 }, add = { hp_max = -15 }, excludes = { "hardy" } })
tr("hardy", { name = "Hardy", desc = "Tough constitution.",
	mul = { infection_progress = 0.8 }, add = { hp_max = 10 }, excludes = { "sickly" } })

return TR
