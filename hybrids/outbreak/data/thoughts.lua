-- data/thoughts.lua : mood thoughts. value = mood points (+/-), dur = minutes the thought lasts,
-- decay_start = minutes before the value starts fading linearly to 0 at `dur` (default: dur, i.e. no fade),
-- stack = how many copies may be active at once (default 1: re-adding just refreshes the timer).
-- (Idea only taken from Cataclysm-DDA's morale entries: bonus / duration / decay_start / capped stacking.)
local TH = {}

local function th(id, d) d.id = id; TH[id] = d end

th("ate_fine_meal", { label = "Had a hot meal", value = 8, dur = 600, decay_start = 240 })
th("ate_cooked", { label = "Cooked food", value = 5, dur = 480, decay_start = 180 })
th("ate_sweet", { label = "Something sweet", value = 4, dur = 360, decay_start = 120 })
th("ate_canned", { label = "Tinned food again", value = -2, dur = 240 })
th("slept_in_bed", { label = "Slept in a bed", value = 5, dur = 720, decay_start = 300 })
th("slept_on_floor", { label = "Slept on the floor", value = -6, dur = 720, decay_start = 300 })
th("saw_death", { label = "Saw someone die", value = -9, dur = 2880, decay_start = 720, stack = 3 })
th("friend_died", { label = "Lost a colonist", value = -14, dur = 4320, decay_start = 1440, stack = 2 })
th("survived_attack", { label = "Survived an attack", value = 6, dur = 1440, decay_start = 600 })
th("raid_repelled", { label = "Drove off raiders", value = 8, dur = 2000, decay_start = 800 })
th("close_call", { label = "Nearly died", value = -8, dur = 1200, decay_start = 400 })
th("bitten", { label = "Got bitten", value = -14, dur = 2880, decay_start = 1000 })
th("infected_fear", { label = "Watching someone sicken", value = -8, dur = 1440, decay_start = 600, stack = 2 })
th("lights_out", { label = "Lights out", value = -4, dur = 300 })
th("thirsty_long", { label = "Dry mouth", value = -3, dur = 240 })
th("new_arrival", { label = "A new face", value = 4, dur = 1440, decay_start = 600 })
th("secure_walls", { label = "Walls hold", value = 5, dur = 1440, decay_start = 900 })
th("horde_near", { label = "Hordes nearby", value = -8, dur = 120 })
th("painkillers_high", { label = "Painkillers", value = 6, dur = 240, decay_start = 120 })
th("break_relief", { label = "Got it out of the system", value = 8, dur = 720, decay_start = 300 })
th("caravan_trade", { label = "Trading day", value = 3, dur = 720, decay_start = 300 })
th("helicopter_hope", { label = "Heard a helicopter", value = 3, dur = 600 })
th("amputated", { label = "Lost a limb", value = -10, dur = 4320, decay_start = 1440 })

return TH
