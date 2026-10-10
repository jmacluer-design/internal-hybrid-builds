-- items / containers / loot tables / data validation.
local T = ...
package.path = T.root .. "/?.lua;" .. package.path
local U = require("sim.util")
local R = require("sim.rng")
local items = require("sim.items")
local loot = require("sim.loot")
local blueprints = require("sim.blueprints")
local stockpile = require("sim.stockpile")
local RECIPES = require("data.recipes")
local FD = require("data.factions")
local DISTRICTS = require("data.districts")

T.group("items+loot")

T.test("item data: sane weights, stacks, values; categories used by other modules exist", function()
	local cats = {}
	for _, id in ipairs(items.all_ids()) do
		local d = items.def(id)
		T.truthy(d.w > 0 and d.w == math.floor(d.w), id .. " weight must be a positive integer number of grams")
		T.truthy(d.stack >= 1 and d.stack == math.floor(d.stack), id .. " stack")
		T.truthy(d.value >= 0, id .. " value")
		T.truthy(d.name and d.cat, id .. " name/cat")
		cats[d.cat] = true
		if d.weapon then T.truthy(d.weapon.kind == "melee" or d.weapon.kind == "ranged", id .. " weapon kind") end
		if d.weapon and d.weapon.kind == "ranged" then T.truthy(items.exists(d.weapon.ammo), id .. " ammo item exists") end
	end
	for _, c in ipairs({ "food", "drink", "medical", "ammo", "weapon", "material", "fuel", "tool", "valuable", "ingredient" }) do
		T.truthy(cats[c], "category " .. c .. " has items")
	end
	T.throws(function() items.def("no_such_item") end)
end)

T.test("add/remove respect the weight cap and keep the cached weight exact", function()
	local c = items.new(5000)
	T.eq(items.add(c, "canned_beans", 5), 5)         -- 5 x 400 g = 2000
	T.eq(c.w, 2000)
	T.eq(items.add(c, "scrap_wood", 5), 1)           -- only 1 x 2000 g fits in the 3000 g left... then 1000 left
	T.eq(c.w, 4000)
	T.eq(items.add(c, "scrap_wood", 5), 0)
	T.eq(items.remove(c, "canned_beans", 2), 2)
	T.eq(c.w, 3200)
	T.eq(items.remove(c, "canned_beans", 99), 3, "removal is capped at what is there")
	T.eq(items.count(c, "canned_beans"), 0)
	T.eq(c.items.canned_beans, nil, "zero counts are deleted")
	T.eq(items.add(c, "scrap_wood", 0), 0)
	local ok, err = items.check(c)
	T.truthy(ok, err)
end)

T.test("slot caps follow stack sizes", function()
	local c = items.new(nil, 2)             -- two slots, no weight cap
	T.eq(items.add(c, "ammo_9mm", 100), 100) -- stack 60 -> 2 slots
	T.eq(c.s, 2)
	T.eq(items.add(c, "ammo_9mm", 100), 20, "fills the last partial stack only")
	T.eq(items.add(c, "bandage", 1), 0, "no free slot")
	T.eq(items.remove(c, "ammo_9mm", 70), 70)
	T.eq(c.s, 1)
	T.eq(items.add(c, "pistol", 3), 1, "non-stacking weapons need a slot each")
	local ok, err = items.check(c)
	T.truthy(ok, err)
end)

T.test("transfer is atomic: exactly what the target accepts moves", function()
	local a, b = items.new(), items.new(1000)
	items.add(a, "canned_beans", 10)
	T.eq(items.transfer(a, b, "canned_beans", 10), 2, "1000 g holds only two 400 g cans")
	T.eq(items.count(a, "canned_beans"), 8)
	T.eq(items.count(b, "canned_beans"), 2)
	T.eq(items.transfer(a, b, "canned_beans", 5), 0)
	T.eq(items.transfer(a, b, "pistol", 1), 0, "nothing to move")
	T.eq(items.count(a, "canned_beans") + items.count(b, "canned_beans"), 10)
end)

T.test("bad counts are rejected loudly (no silent duplication)", function()
	local c = items.new()
	T.throws(function() items.add(c, "bandage", -1) end)
	T.throws(function() items.add(c, "bandage", 1.5) end)
	T.throws(function() items.add(c, "bandage", 0 / 0) end)
	T.throws(function() items.remove(c, "bandage", 0.5) end)
	T.throws(function() items.add(c, "unknown_thing", 1) end)
	T.eq(items.total_count(c), 0)
end)

T.test("has_all / take_all / add_map / list / value / count_cat", function()
	local c = items.new()
	items.add_map(c, { canned_beans = 3, bandage = 2, pistol = 1 })
	T.truthy(items.has_all(c, { canned_beans = 3, bandage = 1 }))
	T.falsy(items.has_all(c, { canned_beans = 4 }))
	T.falsy(items.take_all(c, { canned_beans = 1, bandage = 5 }), "all-or-nothing")
	T.eq(items.count(c, "canned_beans"), 3)
	T.truthy(items.take_all(c, { canned_beans = 1, bandage = 2 }))
	T.eq(items.count(c, "bandage"), 0)
	local l = items.list(c)
	T.eq(l[1].id, "canned_beans")
	T.eq(l[2].id, "pistol")
	T.eq(items.value(c), 2 * 3 + 12)
	T.eq(items.count_cat(c, "food"), 2)
	T.eq(items.find(c, function(id, d) return d.cat == "weapon" end), "pistol")
end)

T.test("container fuzz: 4000 random add/remove/transfer ops conserve every item and keep invariants", function()
	local rng = R.new(2026)
	local ids = items.all_ids()
	local boxes = { items.new(), items.new(20000), items.new(nil, 6), items.new(9000, 5) }
	local created, destroyed = {}, {}
	for step = 1, 4000 do
		local id = ids[rng:int(1, #ids)]
		local n = rng:int(1, 12)
		local op = rng:int(1, 3)
		local a, b = boxes[rng:int(1, 4)], boxes[rng:int(1, 4)]
		if op == 1 then
			local k = items.add(a, id, n)
			created[id] = (created[id] or 0) + k
		elseif op == 2 then
			local k = items.remove(a, id, n)
			destroyed[id] = (destroyed[id] or 0) + k
		else
			items.transfer(a, b, id, n)
		end
		if step % 250 == 0 then
			for i = 1, 4 do
				local ok, err = items.check(boxes[i])
				T.truthy(ok, "box " .. i .. ": " .. tostring(err))
			end
		end
	end
	for _, id in ipairs(ids) do
		local have = 0
		for i = 1, 4 do have = have + items.count(boxes[i], id) end
		T.eq(have, (created[id] or 0) - (destroyed[id] or 0), "conservation of " .. id)
	end
end)

T.test("rebuild() restores caches from counts alone", function()
	local c = items.new(10000, 10)
	items.add_map(c, { canned_beans = 9, ammo_9mm = 70 })
	local w, s = c.w, c.s
	c.w, c.s = 0, 0
	items.rebuild(c)
	T.eq(c.w, w)
	T.eq(c.s, s)
end)

T.test("loot tables: every item exists, container types map to tables, validation passes", function()
	local ok, err = loot.validate()
	T.truthy(ok, err)
	for _, tid in ipairs(loot.table_ids()) do
		local t = loot.tables[tid]
		T.truthy(t.rolls[1] >= 1 and t.rolls[2] >= t.rolls[1], tid .. " rolls")
		local wsum = 0
		for i = 1, #t.entries do wsum = wsum + t.entries[i].w end
		T.truthy(wsum > 0, tid .. " has weight")
	end
	T.eq(loot.table_for_container("house"), "residential")
	T.eq(loot.table_for_container("nope"), nil)
end)

T.test("loot.roll is deterministic per (seed, table) and only drops known items", function()
	local a = loot.roll(R.new(9), "residential", { danger = 2 })
	local b = loot.roll(R.new(9), "residential", { danger = 2 })
	T.eq(U.hash(require("sim.save").serialize(a)), U.hash(require("sim.save").serialize(b)))
	for seed = 1, 60 do
		for _, tid in ipairs(loot.table_ids()) do
			local bundle = loot.roll(R.new(seed), tid, { danger = (seed % 5) + 1 })
			for id, n in pairs(bundle) do -- order-free
				if not items.exists(id) or n < 1 or n ~= math.floor(n) then T.truthy(false, "bad drop " .. id) end
			end
		end
	end
	T.truthy(true)
	T.throws(function() loot.roll(R.new(1), "no_such_table") end)
end)

T.test("danger tilts rare items upward; luck adds rolls; rolls override works", function()
	local function rare_share(danger)
		local rare, total = 0, 0
		local r = R.new(4242)
		for _ = 1, 3000 do
			local bundle = loot.roll(r, "military", { danger = danger, rolls = 4 })
			for id, n in pairs(bundle) do -- order-free
				total = total + n
				local d = items.def(id)
				if id == "pistol" or id == "rifle" or id == "shotgun" or id == "first_aid_kit" or id == "machete" then rare = rare + n end
			end
		end
		return rare / total
	end
	T.gt(rare_share(5), rare_share(1) * 1.2, "danger 5 should drop clearly more rare items than danger 1")
	local luckless, lucky = 0, 0
	local r1, r2 = R.new(5), R.new(5)
	for _ = 1, 2000 do
		luckless = luckless + U.sum_map(loot.roll(r1, "pantry", { rolls = 3 }))
		lucky = lucky + U.sum_map(loot.roll(r2, "pantry", { rolls = 3, luck = 1 }))
	end
	T.gt(lucky, luckless, "luck=1 adds a roll")
	T.eq(loot.nearest_district({ x = 500, y = 300 }).id, "orchard")
end)

T.test("blueprint, recipe, faction and district data reference real items", function()
	local ok, err = blueprints.validate()
	T.truthy(ok, err)
	local bp_count = #blueprints.ids()
	T.ge(bp_count, 12, "at least 12 blueprints")
	for _, id in ipairs(U.keys(RECIPES)) do
		local r = RECIPES[id]
		for item, n in pairs(r.inputs) do T.truthy(items.exists(item) and n > 0, id .. " input " .. item) end -- order-free
		for item, n in pairs(r.outputs) do T.truthy(items.exists(item) and n > 0, id .. " output " .. item) end -- order-free
		T.truthy(items.exists(r.want[1]), id .. " want item")
	end
	for _, fid in ipairs(FD.order) do
		local f = FD.defs[fid]
		for i = 1, #f.stock.entries do T.truthy(items.exists(f.stock.entries[i].item), fid .. " stock item") end
		T.truthy(f.markup >= 1, fid .. " markup")
	end
	for _, did in ipairs(U.keys(DISTRICTS)) do
		T.truthy(loot.tables[DISTRICTS[did].loot], did .. " loot table")
		T.truthy(DISTRICTS[did].danger >= 1 and DISTRICTS[did].danger <= 5, did .. " danger")
	end
	T.ge(#FD.order, 5, "four gangs + survivors")
end)

T.test("stockpile zones: filters, priorities, capacity", function()
	local pos = { x = 0, y = 0, z = 0 }
	local all = stockpile.new("z1", "All", pos, 1, 2, {})
	local meds = stockpile.new("z2", "Meds", { x = 5, y = 0, z = 0 }, 1, 4, { cats = { medical = true } })
	local deny = stockpile.new("z3", "NoBeans", { x = 9, y = 0, z = 0 }, 1, 5, { deny = { canned_beans = true } })
	local zs = { all, meds, deny }
	T.truthy(stockpile.accepts(meds, "bandage"))
	T.falsy(stockpile.accepts(meds, "canned_beans"))
	T.truthy(stockpile.accepts(all, "canned_beans"))
	T.falsy(stockpile.accepts(deny, "canned_beans"))
	T.truthy(stockpile.accepts(deny, "bandage"))
	T.eq(stockpile.find_dest(zs, "bandage", pos).id, "z3", "highest priority that accepts wins (deny zone has prio 5)")
	T.eq(stockpile.find_dest(zs, "canned_beans", pos).id, "z1")
	items.add(all.items, "canned_beans", 3)
	items.add(meds.items, "bandage", 4)
	T.eq(stockpile.total(zs, "bandage"), 4)
	T.eq(stockpile.find_source(zs, "bandage", pos).id, "z2")
	T.eq(stockpile.totals(zs).canned_beans, 3)
	T.eq(stockpile.cat_total(zs, "food"), 3)
	T.eq(stockpile.wealth(zs), 3 * 3 + 4 * 4)
	-- a full zone stops accepting
	local tiny = stockpile.new("z9", "Tiny", pos, 1, 5, {})
	tiny.items.cap = 700
	items.add(tiny.items, "canned_beans", 1)
	T.eq(stockpile.find_dest({ tiny }, "canned_beans", pos), nil, "not enough room for another 400 g can")
end)
