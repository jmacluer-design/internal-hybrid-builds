-- data/loot.lua : weighted loot tables.
--   rolls   = { min, max } number of weighted draws per container
--   entries = { { item, weight, min, max, rare = true } ... }   (rare entries get better with district danger)
-- container_types maps an adapter container type (container_opened.ctype) onto a table.
local L = { tables = {}, container_types = {} }

local function tbl(id, rolls, entries) L.tables[id] = { id = id, rolls = rolls, entries = entries } end
local function e(item, w, mn, mx, rare) return { item = item, w = w, min = mn or 1, max = mx or mn or 1, rare = rare } end

tbl("residential", { 2, 5 }, {
	e("canned_beans", 10, 1, 3), e("canned_veg", 8, 1, 3), e("canned_fruit", 5, 1, 2), e("soda_can", 6, 1, 3), e("water_bottle", 8, 1, 3),
	e("rice_bag", 5, 1, 1), e("cloth_scrap", 8, 2, 6), e("bandage", 4, 1, 3), e("painkillers", 3, 1, 2), e("scrap_wood", 3, 1, 2),
	e("duct_tape", 3, 1, 1), e("baseball_bat", 1, 1, 1, true), e("pistol", 0.7, 1, 1, true), e("ammo_9mm", 2, 6, 18), e("energy_bar", 4, 1, 4),
	e("firewood", 4, 1, 3), e("jewelry", 1, 1, 2, true), e("electronics", 2, 1, 2), e("antibiotics", 0.6, 1, 1, true),
})
tbl("commercial", { 3, 6 }, {
	e("canned_beans", 7, 1, 4), e("canned_veg", 6, 1, 4), e("canned_fruit", 5, 1, 3), e("energy_bar", 8, 2, 6), e("soda_can", 8, 2, 6),
	e("water_bottle", 8, 2, 6), e("cloth_scrap", 8, 2, 8), e("electronics", 5, 1, 3), e("duct_tape", 4, 1, 2), e("jewelry", 3, 1, 3, true),
	e("radio_set", 1, 1, 1, true), e("wire", 4, 1, 3), e("toolbox", 1, 1, 1, true), e("bandage", 3, 1, 3), e("rice_bag", 4, 1, 2),
})
tbl("industrial", { 3, 6 }, {
	e("scrap_metal", 12, 1, 4), e("scrap_wood", 8, 1, 4), e("nails", 8, 1, 3), e("wire", 7, 1, 3), e("concrete_bag", 4, 1, 2),
	e("fuel_can", 4, 1, 2), e("duct_tape", 5, 1, 2), e("electronics", 4, 1, 3), e("toolbox", 2, 1, 1, true), e("crowbar", 2, 1, 1, true),
	e("sandbag", 4, 1, 4), e("firewood", 3, 1, 3), e("cloth_scrap", 3, 2, 4),
})
tbl("medical", { 3, 6 }, {
	e("bandage", 12, 2, 6), e("painkillers", 8, 1, 4), e("antibiotics", 5, 1, 2, true), e("first_aid_kit", 4, 1, 2, true),
	e("surgical_kit", 1, 1, 1, true), e("cloth_scrap", 5, 2, 6), e("water_bottle", 5, 1, 3), e("canned_fruit", 2, 1, 2),
})
tbl("military", { 3, 6 }, {
	e("ration_pack", 8, 1, 4), e("ammo_9mm", 8, 10, 30), e("ammo_rifle", 6, 8, 24), e("ammo_shell", 4, 5, 15), e("pistol", 3, 1, 1, true),
	e("rifle", 1.5, 1, 1, true), e("shotgun", 1.5, 1, 1, true), e("first_aid_kit", 3, 1, 1, true), e("radio_set", 2, 1, 1),
	e("fuel_can", 3, 1, 2), e("sandbag", 5, 2, 6), e("machete", 1, 1, 1, true), e("water_bottle", 4, 2, 5),
})
tbl("rural", { 2, 5 }, {
	e("canned_veg", 6, 1, 4), e("rice_bag", 6, 1, 3), e("dried_meat", 6, 1, 4), e("firewood", 8, 2, 5), e("fuel_can", 4, 1, 2),
	e("water_bottle", 4, 1, 3), e("scrap_wood", 5, 1, 3), e("ammo_shell", 2, 4, 10), e("shotgun", 1, 1, 1, true), e("machete", 1, 1, 1, true),
	e("cloth_scrap", 3, 1, 4),
})
tbl("garage", { 2, 4 }, {
	e("fuel_can", 10, 1, 2), e("scrap_metal", 6, 1, 3), e("toolbox", 3, 1, 1, true), e("duct_tape", 4, 1, 2), e("crowbar", 3, 1, 1, true),
	e("soda_can", 5, 1, 3), e("energy_bar", 4, 1, 3), e("wire", 3, 1, 2),
})
tbl("police", { 2, 5 }, {
	e("pistol", 4, 1, 1, true), e("ammo_9mm", 10, 8, 24), e("shotgun", 2, 1, 1, true), e("baseball_bat", 2, 1, 1), e("first_aid_kit", 2, 1, 1, true),
	e("energy_bar", 3, 1, 3), e("bandage", 3, 1, 3), e("radio_set", 1, 1, 1, true),
})
tbl("pantry", { 2, 4 }, {
	e("canned_beans", 10, 1, 4), e("canned_veg", 8, 1, 4), e("canned_fruit", 6, 1, 3), e("rice_bag", 6, 1, 2), e("dried_meat", 4, 1, 3),
	e("water_bottle", 6, 1, 4), e("soda_can", 5, 1, 4), e("energy_bar", 4, 1, 4), e("ration_pack", 1, 1, 2, true),
})

L.container_types = {
	house = "residential", apartment = "residential", store = "commercial", shop = "commercial", warehouse = "industrial",
	factory = "industrial", clinic = "medical", hospital = "medical", pharmacy = "medical", bunker = "military",
	barracks = "military", farm = "rural", barn = "rural", garage = "garage", fuel_station = "garage", police = "police",
	kitchen = "pantry", fridge = "pantry", pantry = "pantry", crate = "industrial", locker = "residential",
}

return L
