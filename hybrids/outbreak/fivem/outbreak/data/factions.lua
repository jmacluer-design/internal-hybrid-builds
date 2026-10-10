-- data/factions.lua : four original gangs + a survivor camp. All names, ideas and numbers are original.
--   kind        "gang" (can raid) or "survivor" (never raids)
--   goodwill    starting relation -100 (blood feud) .. +100 (allies)
--   aggression  weight when the director picks who raids; raid_power scales raider count per threat point
--   markup      price multiplier when they sell to you (they pay price / markup when buying)
--   wants       item categories they pay a premium for        steals   categories raiders grab first
--   stock       caravan goods (loot-table format)
local F = { order = { "rustjaw", "hollow_choir", "tallow", "cinder", "lantern" } }

local function e(item, w, mn, mx) return { item = item, w = w, min = mn or 1, max = mx or mn or 1 } end

F.defs = {
	rustjaw = { id = "rustjaw", name = "Rustjaw Reavers", kind = "gang", goodwill = -18, aggression = 0.9, raid_power = 1.1, markup = 1.35,
		blurb = "Scrap-bike crews who strip anything with a motor.",
		wants = { fuel = true, weapon = true }, steals = { "fuel", "weapon", "ammo" },
		stock = { rolls = { 3, 5 }, entries = { e("scrap_metal", 8, 2, 5), e("fuel_can", 5, 1, 2), e("wire", 5, 1, 3), e("crowbar", 2, 1, 1), e("machete", 1, 1, 1), e("ammo_9mm", 3, 10, 25) } } },
	hollow_choir = { id = "hollow_choir", name = "Hollow Choir", kind = "gang", goodwill = -28, aggression = 0.7, raid_power = 0.9, markup = 1.6,
		blurb = "A noisy cult that believes the dead are singing.",
		wants = { valuable = true, medical = true }, steals = { "medical", "valuable", "food" }, screams = true,
		stock = { rolls = { 2, 4 }, entries = { e("jewelry", 4, 1, 2), e("cloth_scrap", 6, 3, 8), e("painkillers", 4, 1, 3), e("dried_meat", 4, 2, 4) } } },
	tallow = { id = "tallow", name = "Tallow Syndicate", kind = "gang", goodwill = 8, aggression = 0.35, raid_power = 1.0, markup = 1.15,
		blurb = "Smugglers who would rather sell to you than shoot you.",
		wants = { valuable = true, material = true }, steals = { "valuable", "medical", "ammo" },
		stock = { rolls = { 4, 7 }, entries = { e("bandage", 6, 2, 5), e("antibiotics", 3, 1, 2), e("ammo_9mm", 5, 12, 30), e("ammo_shell", 3, 6, 14), e("ration_pack", 4, 1, 3), e("electronics", 4, 1, 3), e("first_aid_kit", 2, 1, 1) } } },
	cinder = { id = "cinder", name = "Cinder Union", kind = "gang", goodwill = -6, aggression = 0.55, raid_power = 1.25, markup = 1.25,
		blurb = "Dock-workers turned militia. Disciplined, proud, hungry for power.",
		wants = { fuel = true, material = true }, steals = { "fuel", "material", "food" },
		stock = { rolls = { 3, 6 }, entries = { e("canned_beans", 6, 2, 5), e("canned_veg", 5, 2, 5), e("sandbag", 5, 2, 6), e("concrete_bag", 3, 1, 2), e("water_bottle", 5, 2, 5), e("rice_bag", 4, 1, 2) } } },
	lantern = { id = "lantern", name = "Lantern Camp", kind = "survivor", goodwill = 24, aggression = 0, raid_power = 0, markup = 1.0,
		blurb = "A walled camp of survivors. Neighbours, if you treat them fairly.",
		wants = { medical = true, ammo = true }, steals = {},
		stock = { rolls = { 3, 5 }, entries = { e("canned_veg", 6, 2, 4), e("water_bottle", 6, 2, 5), e("firewood", 5, 2, 5), e("rice_bag", 4, 1, 2), e("cloth_scrap", 4, 2, 6) } } },
}

return F
