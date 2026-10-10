-- data/recipes.lua : cooking (campfire / stove) and crafting (workbench) recipes.
--   work_type = "cook" | "craft" (which colonist work priority runs it)
--   station   = building tag required ("cook_station" or "craft_station")
--   inputs/outputs = { item = n }      work = minutes at speed 1.0       skill/skill_min = driving skill + minimum level
--   want = { item, n }: only produced while the colony holds fewer than n of that item (demand target)
local R = {}

local function rc(id, d) d.id = id; R[id] = d end

rc("cooked_rice", { work_type = "cook", station = "cook_station", inputs = { rice_bag = 1 }, outputs = { cooked_rice = 4 }, work = 20,
	skill = "cooking", skill_min = 0, want = { "cooked_rice", 8 } })
rc("stew", { work_type = "cook", station = "cook_station", inputs = { canned_veg = 1, dried_meat = 1 }, outputs = { stew = 2 }, work = 25,
	skill = "cooking", skill_min = 1, want = { "stew", 6 } })

rc("bandage", { work_type = "craft", station = "craft_station", inputs = { cloth_scrap = 2 }, outputs = { bandage = 2 }, work = 10,
	skill = "medicine", skill_min = 0, want = { "bandage", 10 } })
rc("nails", { work_type = "craft", station = "craft_station", inputs = { scrap_metal = 1 }, outputs = { nails = 6 }, work = 15,
	skill = "construction", skill_min = 0, want = { "nails", 8 } })
rc("ammo_9mm", { work_type = "craft", station = "craft_station", inputs = { scrap_metal = 2 }, outputs = { ammo_9mm = 15 }, work = 30,
	skill = "construction", skill_min = 3, want = { "ammo_9mm", 45 } })

return R
