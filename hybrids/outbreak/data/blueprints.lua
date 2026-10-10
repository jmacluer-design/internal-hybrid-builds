-- data/blueprints.lua : things colonists can build.
--   materials = { item = n }   delivered to the site before work starts, consumed on completion
--   work      = work units; 1 unit = 1 minute for a colonist whose speed factor is 1.0 (construction level 4)
--   skill_min = minimum construction level to build it
--   needs     = { blueprint_id = count }  completed buildings required before it can be PLACED (prerequisites)
--   max       = most that may exist at once (planned + built)
--   power_use / power_gen = watts (see grid.lua); fuel for generators is tracked in minutes of runtime
--   defense / perimeter   = contribution to base defense score / perimeter closure (scaled by hp fraction)
--   tags      = service flags other modules look for (cook_station, craft_station, guard_post, bed, ...)
--   value     = wealth points for the director
-- Original designs only.
local B = {}

local function bp(id, d) d.id = id; d.size = d.size or { 1, 1 }; d.tags = d.tags or {}; d.value = d.value or 2; B[id] = d end

bp("floor", { name = "Plank floor", cat = "structure", materials = { scrap_wood = 1 }, work = 10, skill_min = 0, hp = 60, value = 1 })

bp("wall", { name = "Barrier wall", cat = "defense", materials = { scrap_wood = 3, scrap_metal = 1, nails = 1 }, work = 30,
	skill_min = 0, hp = 220, defense = 8, perimeter = 1, value = 4 })

bp("door", { name = "Reinforced door", cat = "defense", materials = { scrap_wood = 2, scrap_metal = 2, nails = 1 }, work = 40,
	skill_min = 1, needs = { wall = 2 }, hp = 140, defense = 4, perimeter = 1, value = 5 })

bp("barricade", { name = "Barricade", cat = "defense", materials = { scrap_wood = 2, nails = 1 }, work = 15,
	skill_min = 0, hp = 90, defense = 4, perimeter = 0.6, value = 2 })

bp("bed", { name = "Bed", cat = "furniture", materials = { scrap_wood = 2, cloth_scrap = 4 }, work = 25, skill_min = 0,
	hp = 50, tags = { bed = true }, rest_quality = 1.0, value = 4 })

bp("campfire", { name = "Campfire", cat = "production", materials = { firewood = 3 }, work = 10, skill_min = 0, hp = 40,
	tags = { cook_station = true, fire = true }, value = 2 })

bp("workbench", { name = "Workbench", cat = "production", materials = { scrap_wood = 6, scrap_metal = 2, nails = 3 }, work = 60,
	skill_min = 0, hp = 120, power_use = 150, tags = { craft_station = true }, max = 2, value = 8 })

bp("stove", { name = "Electric stove", cat = "production", materials = { scrap_metal = 4, wire = 2, nails = 1 }, work = 60,
	skill_min = 1, needs = { workbench = 1 }, hp = 100, power_use = 800, tags = { cook_station = true, needs_power = true }, max = 2, value = 10 })

bp("generator", { name = "Fuel generator", cat = "power", materials = { scrap_metal = 6, electronics = 2, wire = 2 }, work = 90,
	skill_min = 2, needs = { workbench = 1 }, hp = 120, power_gen = 2400, fuel_cap_min = 720, max = 3, tags = { generator = true }, value = 14 })

bp("watchtower", { name = "Watchtower", cat = "defense", materials = { scrap_wood = 10, scrap_metal = 4, nails = 4 }, work = 150,
	skill_min = 2, needs = { wall = 2, workbench = 1 }, hp = 300, defense = 14, perimeter = 1, tags = { guard_post = true }, guard_slots = 1, max = 4, value = 14 })

bp("crate", { name = "Storage crate", cat = "storage", materials = { scrap_wood = 3, nails = 1 }, work = 20, skill_min = 0, hp = 80,
	storage_g = 40000, tags = { storage = true }, max = 8, value = 3 })

bp("rain_collector", { name = "Rain collector", cat = "water", materials = { scrap_metal = 2, scrap_wood = 2, duct_tape = 1 }, work = 40,
	skill_min = 0, hp = 70, water_collect = 0.45, max = 4, tags = { water = true }, value = 5 })

bp("water_tank", { name = "Water tank", cat = "water", materials = { scrap_metal = 6, nails = 2 }, work = 60, skill_min = 1, hp = 120,
	tank_l = 250, max = 3, tags = { water = true }, value = 6 })

bp("medical_bed", { name = "Medical bed", cat = "furniture", materials = { scrap_wood = 2, cloth_scrap = 6, scrap_metal = 2, electronics = 1 },
	work = 50, skill_min = 2, needs = { workbench = 1, bed = 1 }, hp = 70, power_use = 150, heal_mult = 1.8,
	tags = { bed = true, med_bed = true }, rest_quality = 1.1, max = 2, value = 12 })

bp("lamp", { name = "Work lamp", cat = "utility", materials = { electronics = 1, wire = 1, duct_tape = 1 }, work = 15, skill_min = 1,
	hp = 30, power_use = 40, tags = { light = true }, max = 6, value = 3 })

bp("radio_mast", { name = "Radio mast", cat = "utility", materials = { scrap_metal = 6, electronics = 4, wire = 4 }, work = 120, skill_min = 3,
	needs = { generator = 1 }, hp = 90, power_use = 120, tags = { radio = true }, max = 1, value = 16 })

return B
