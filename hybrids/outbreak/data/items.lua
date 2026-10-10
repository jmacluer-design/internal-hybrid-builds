-- data/items.lua : every item the sim knows. Weights are integer GRAMS (so container weight
-- arithmetic is exact), `stack` is the max stack size in a slot, `value` is abstract wealth
-- points (barter + director wealth; there is no currency item on purpose).
--
--   food   = { hunger = points removed from hunger, thirst = points removed from thirst,
--              mood = thought id added when eaten (optional), pref = eating preference (higher first) }
--   med    = { kind = "bandage" | "kit" | "antibiotic" | "painkiller" | "surgery", power = potency }
--   weapon = { kind = "melee" | "ranged", power = combat power, ammo = item id (ranged), noise = loudness }
--   fuel_l = litres of fuel (generator); burn_min = campfire burn minutes
-- Original content only: nothing here is taken from any game's item list.
local I = {}

local function def(id, d) d.id = id; I[id] = d end

-- food ------------------------------------------------------------------------------------
def("canned_beans", { name = "Canned beans", cat = "food", w = 400, stack = 8, value = 3, food = { hunger = 30, mood = "ate_canned", pref = 3 } })
def("canned_veg", { name = "Canned vegetables", cat = "food", w = 400, stack = 8, value = 3, food = { hunger = 26, mood = "ate_canned", pref = 3 } })
def("canned_fruit", { name = "Canned fruit", cat = "food", w = 350, stack = 8, value = 3, food = { hunger = 20, thirst = 6, mood = "ate_sweet", pref = 4 } })
def("ration_pack", { name = "Ration pack", cat = "food", w = 500, stack = 6, value = 5, food = { hunger = 45, mood = "ate_canned", pref = 5 } })
def("energy_bar", { name = "Energy bar", cat = "food", w = 80, stack = 20, value = 2, food = { hunger = 12, mood = "ate_sweet", pref = 2 } })
def("dried_meat", { name = "Dried meat strips", cat = "food", w = 150, stack = 12, value = 4, food = { hunger = 26, mood = "ate_canned", pref = 3 } })
def("stew", { name = "Hot stew", cat = "food", w = 600, stack = 6, value = 6, food = { hunger = 55, mood = "ate_fine_meal", pref = 9 } })
def("cooked_rice", { name = "Cooked rice", cat = "food", w = 500, stack = 6, value = 4, food = { hunger = 40, mood = "ate_cooked", pref = 7 } })
def("rice_bag", { name = "Bag of rice", cat = "ingredient", w = 1000, stack = 5, value = 3 })

-- drink -----------------------------------------------------------------------------------
def("water_bottle", { name = "Bottled water", cat = "drink", w = 500, stack = 12, value = 2, food = { thirst = 45, pref = 5 } })
def("soda_can", { name = "Soda can", cat = "drink", w = 350, stack = 12, value = 1, food = { thirst = 16, hunger = 4, mood = "ate_sweet", pref = 3 } })

-- medical ---------------------------------------------------------------------------------
def("bandage", { name = "Bandage", cat = "medical", w = 50, stack = 20, value = 4, med = { kind = "bandage", power = 1 } })
def("first_aid_kit", { name = "First-aid kit", cat = "medical", w = 600, stack = 4, value = 12, med = { kind = "kit", power = 2 } })
def("antibiotics", { name = "Antibiotics course", cat = "medical", w = 80, stack = 10, value = 12, med = { kind = "antibiotic", power = 1 } })
def("painkillers", { name = "Painkillers", cat = "medical", w = 40, stack = 20, value = 5, med = { kind = "painkiller", power = 1 } })
def("surgical_kit", { name = "Surgical kit", cat = "medical", w = 1500, stack = 2, value = 20, med = { kind = "surgery", power = 1 } })
def("cloth_scrap", { name = "Cloth scrap", cat = "material", w = 60, stack = 30, value = 1 })

-- weapons + ammo --------------------------------------------------------------------------
def("baseball_bat", { name = "Wooden bat", cat = "weapon", w = 900, stack = 1, value = 4, weapon = { kind = "melee", power = 3, noise = 20 } })
def("crowbar", { name = "Crowbar", cat = "weapon", w = 1100, stack = 1, value = 5, weapon = { kind = "melee", power = 3.5, noise = 25 } })
def("machete", { name = "Machete", cat = "weapon", w = 700, stack = 1, value = 8, weapon = { kind = "melee", power = 5, noise = 15 } })
def("pistol", { name = "Pistol", cat = "weapon", w = 900, stack = 1, value = 12, weapon = { kind = "ranged", power = 5, ammo = "ammo_9mm", noise = 110 } })
def("shotgun", { name = "Pump shotgun", cat = "weapon", w = 3200, stack = 1, value = 18, weapon = { kind = "ranged", power = 9, ammo = "ammo_shell", noise = 140 } })
def("rifle", { name = "Scoped rifle", cat = "weapon", w = 3600, stack = 1, value = 20, weapon = { kind = "ranged", power = 10, ammo = "ammo_rifle", noise = 150 } })
def("ammo_9mm", { name = "9mm rounds", cat = "ammo", w = 12, stack = 60, value = 1 })
def("ammo_shell", { name = "Shotgun shells", cat = "ammo", w = 35, stack = 25, value = 2 })
def("ammo_rifle", { name = "Rifle rounds", cat = "ammo", w = 20, stack = 40, value = 2 })

-- materials -------------------------------------------------------------------------------
def("scrap_wood", { name = "Scrap lumber", cat = "material", w = 2000, stack = 10, value = 1 })
def("scrap_metal", { name = "Scrap metal", cat = "material", w = 1500, stack = 10, value = 2 })
def("nails", { name = "Box of nails", cat = "material", w = 200, stack = 20, value = 2 })
def("sandbag", { name = "Sandbag", cat = "material", w = 1500, stack = 10, value = 2 })
def("wire", { name = "Wire spool", cat = "material", w = 300, stack = 10, value = 2 })
def("concrete_bag", { name = "Concrete mix", cat = "material", w = 3000, stack = 4, value = 3 })
def("electronics", { name = "Electronic parts", cat = "material", w = 150, stack = 20, value = 6 })
def("duct_tape", { name = "Duct tape", cat = "material", w = 200, stack = 10, value = 2 })

-- fuel ------------------------------------------------------------------------------------
def("fuel_can", { name = "Fuel can", cat = "fuel", w = 4000, stack = 4, value = 8, fuel_l = 20 })
def("firewood", { name = "Firewood", cat = "fuel", w = 1500, stack = 10, value = 1, burn_min = 90 })

-- tools + valuables -----------------------------------------------------------------------
def("toolbox", { name = "Toolbox", cat = "tool", w = 3000, stack = 1, value = 10 })
def("jewelry", { name = "Jewelry", cat = "valuable", w = 50, stack = 20, value = 10 })
def("radio_set", { name = "Hand radio", cat = "valuable", w = 500, stack = 2, value = 9 })

return I
