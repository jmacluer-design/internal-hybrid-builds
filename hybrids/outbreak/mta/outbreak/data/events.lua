-- data/events.lua : the director's event table.
--   cat          "threat" (spends threat budget, counts as a threat day) | "hazard" (small cost, not a threat day) | "boon" (free, own timer)
--   weight       base selection weight (pacing profiles multiply it, see TUNING.director.profiles)
--   min_day      first day the event may fire            cooldown_days  minimum days between two of the same event
--   min_cost     budget needed to fire (threat events spend  clamp(budget * spend_frac, min_cost, max_cost))
--   fixed_cost   hazard/threat events with a fixed price      minutes = { lo, hi } duration where relevant
local E = {}

local function ev(id, d) d.id = id; E[id] = d end

ev("horde_wave", { cat = "threat", weight = 10, min_day = 2, cooldown_days = 0.5, min_cost = 12, max_cost = 600,
	desc = "A horde heads for the base." })
ev("gang_raid", { cat = "threat", weight = 6, min_day = 4, cooldown_days = 1.5, min_cost = 20, max_cost = 400,
	desc = "A gang raids the base." })
ev("infection_outbreak", { cat = "threat", weight = 2.5, min_day = 3, cooldown_days = 3, fixed_cost = 10,
	desc = "Contaminated supplies: colonists fall sick." })
ev("helicopter_flyover", { cat = "threat", weight = 2.5, min_day = 3, cooldown_days = 3, fixed_cost = 8,
	desc = "A helicopter flies over: the noise draws hordes." })
ev("power_outage", { cat = "hazard", weight = 4, min_day = 2, cooldown_days = 2, fixed_cost = 4, minutes = { 120, 420 },
	desc = "The power goes out." })
ev("water_outage", { cat = "hazard", weight = 3, min_day = 3, cooldown_days = 2.5, fixed_cost = 4, minutes = { 180, 480 },
	desc = "The water stops." })
ev("storm", { cat = "hazard", weight = 4, min_day = 2, cooldown_days = 2, fixed_cost = 3, minutes = { 90, 240 },
	desc = "A storm batters the base." })
ev("caravan", { cat = "boon", weight = 8, min_day = 3, cooldown_days = 2,
	desc = "A trade caravan arrives." })
ev("supply_drop", { cat = "boon", weight = 4, min_day = 4, cooldown_days = 4,
	desc = "A supply crate drops nearby (noisy!)." })
ev("refugee_arrival", { cat = "boon", weight = 5, min_day = 2, cooldown_days = 3,
	desc = "A survivor asks to join." })

E.order = { "horde_wave", "gang_raid", "infection_outbreak", "helicopter_flyover", "power_outage", "water_outage", "storm",
	"caravan", "supply_drop", "refugee_arrival" }

return E
