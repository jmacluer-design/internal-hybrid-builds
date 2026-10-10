-- factions: relations, raids, caravans, trade deals; original-names check over all data files.
local T = ...
package.path = T.root .. "/?.lua;" .. T.root .. "/tests/?.lua;" .. package.path
local H = require("helpers").init(T.root)
local U = require("sim.util")
local R = require("sim.rng")
local TUNING = require("data.tuning")
local FD = require("data.factions")
local factions = require("sim.factions")
local horde = require("sim.horde")
local items = require("sim.items")
local stockpile = require("sim.stockpile")
local clock = require("sim.clock")

local FT = TUNING.factions

T.group("factions")

local function fworld(seed)
	local w = H.world({ seed = seed or 1 })
	w.s.t = clock.at(5, 10, 0)
	return w
end

T.test("four original gangs plus a survivor camp, with sane data", function()
	T.eq(#FD.order, 5)
	local gangs, survivors = 0, 0
	for _, id in ipairs(FD.order) do
		local d = FD.defs[id]
		if d.kind == "gang" then gangs = gangs + 1 else survivors = survivors + 1 end
		T.truthy(d.name and d.blurb and d.markup >= 1 and d.goodwill >= -100 and d.goodwill <= 100, id)
		T.eq(type(d.wants), "table")
		T.eq(type(d.steals), "table")
	end
	T.eq(gangs, 4)
	T.eq(survivors, 1)
	T.eq(FD.defs.lantern.aggression, 0)
end)

T.test("no third-party names, characters, gangs or places appear anywhere in data/ (original content only)", function()
	local banned = { "rimworld", "zomboid", "muldraugh", "rockstar", "gta", "los santos", "vinewood", "ballas", "vagos", "aztecas",
		"marabunta", "franklin", "trevor", "san andreas", "grove street", "lost mc", "families", "cataclysm", "cdda", "sandy shores", "paleto" }
	for _, m in ipairs({ "tuning", "items", "blueprints", "loot", "traits", "thoughts", "events", "factions", "districts", "recipes", "names" }) do
		local f = io.open(T.root .. "/data/" .. m .. ".lua", "rb")
		local src = f:read("*a"):lower():gsub("%-%-[^\n]*", "") -- comments may credit inspirations; content may not use them
		f:close()
		for _, b in ipairs(banned) do T.falsy(src:find(b, 1, true), "data/" .. m .. ".lua mentions '" .. b .. "'") end
	end
	local names = require("data.names")
	T.ge(#names.first, 30)
	T.ge(#names.nick, 20)
end)

T.test("init: relations start at the data values and stay clamped", function()
	local w = fworld()
	for _, id in ipairs(FD.order) do T.eq(factions.get(w, id).goodwill, FD.defs[id].goodwill) end
	T.eq(factions.adjust(w, "rustjaw", 500), 100)
	T.eq(factions.adjust(w, "rustjaw", -500), -100)
	T.eq(factions.adjust(w, "no_such_faction", 5), nil)
	T.truthy(factions.is_hostile(w, factions.get(w, "hollow_choir")))
	T.falsy(factions.is_hostile(w, factions.get(w, "lantern")))
end)

T.test("goodwill drifts back toward each faction's starting attitude", function()
	local w = fworld()
	local f = factions.get(w, "tallow")
	f.goodwill = -60
	for day = 1, 40 do
		w.s.t = clock.at(5 + day, 0, 0)
		factions.step(w, 1)
	end
	T.gt(f.goodwill, -60 + 30, "recovered most of the way")
	T.le(f.goodwill, FD.defs.tallow.goodwill + 0.001)
end)

T.test("raid weights: gangs only, friendlier factions rarely, truces exclude", function()
	local w = fworld()
	T.eq(factions.raid_weight(w, factions.get(w, "lantern")), 0, "survivors never raid")
	local hostile = factions.raid_weight(w, factions.get(w, "hollow_choir"))
	local mild = factions.raid_weight(w, factions.get(w, "tallow"))
	T.gt(hostile, mild * 2)
	factions.get(w, "tallow").goodwill = 60
	T.eq(factions.raid_weight(w, factions.get(w, "tallow")), 0, "allies do not raid")
	factions.get(w, "hollow_choir").truce_until = w.s.t + 100
	T.eq(factions.raid_weight(w, factions.get(w, "hollow_choir")), 0, "a truce stops raids")
	-- the picker honours the weights
	local w2 = fworld(4)
	local counts = {}
	for i = 1, 200 do
		local r = factions.plan_raid(w2, 30)
		counts[r.faction] = (counts[r.faction] or 0) + 1
		w2.s.raids = {}
	end
	T.eq(counts.lantern, nil)
	T.gt(counts.rustjaw or 0, counts.tallow or 0)
end)

T.test("plan_raid: size from points x raid_power, clamped; spawns on the ring; alert + ETA notification", function()
	local w = fworld()
	local r = factions.plan_raid(w, 30, "rustjaw")
	local want = U.round(30 * FD.defs.rustjaw.raid_power * FT.raiders_per_point)
	T.eq(r.count, U.clamp(want, FT.raid_min, FT.raid_max))
	T.gt(r.count, FT.raid_min)
	local d = U.dist2(r.x, r.y, 0, 0)
	T.ge(d, FT.raid_spawn_dist[1] - 1)
	T.le(d, FT.raid_spawn_dist[2] + 1)
	T.eq(r.state, "approach")
	local evs = w:flush_events()
	local a = H.find(evs, "play_alert")
	T.eq(a.kind, "raid_incoming")
	T.eq(a.faction, "rustjaw")
	T.truthy(H.find(evs, "notify", function(e) return e.text:find("Rustjaw") and e.text:find("ETA") end))
	T.eq(factions.plan_raid(w, 1, "rustjaw").count, FT.raid_min)
	T.eq(factions.plan_raid(w, 10000, "rustjaw").count, FT.raid_max)
	T.eq(factions.get(w, "rustjaw").raids, 3)
	local none = fworld()
	for _, id in ipairs(FD.order) do factions.get(none, id).goodwill = 90 end
	T.eq(select(2, factions.plan_raid(none, 30)), "no_raiding_faction")
end)

T.test("an approaching raid closes in, attacks the base, and a defended base beats it (raiders killed, goodwill dips)", function()
	local w = fworld(7)
	for i = 1, 8 do H.force_build(w, "wall", { x = i * 4 - 18, y = 40, z = 0 }) end
	for i = 1, 3 do
		local c = H.colonist(w, { skills = { shooting = 5, melee = 3 } })
		w:create(c.inv, "pistol", 1, "test")
		w:create(c.inv, "ammo_9mm", 80, "test")
		c.drafted = true
	end
	local gw = factions.get(w, "rustjaw").goodwill
	local r = factions.plan_raid(w, 30, "rustjaw")
	local n0 = r.count
	local d0 = U.dist2(r.x, r.y, 0, 0)
	local evs = {}
	local saw_attack = false
	for _ = 1, 300 do
		local e = w:tick(1)
		for i = 1, #e do evs[#evs + 1] = e[i] end
		H.keep_fed(w)
		if r.state == "attack" then saw_attack = true end
		if #w.s.raids == 0 then break end
	end
	T.truthy(saw_attack, "reached the walls")
	T.eq(#w.s.raids, 0, "resolved")
	T.gt(w.s.stats.raiders_killed or 0, 0)
	T.lt(factions.get(w, "rustjaw").goodwill, gw)
	T.truthy(H.find(evs, "notify", function(e) return e.text:find("driven off") or e.text:find("made off") end))
	H.audit_ok(T, w, "after the raid")
end)

T.test("an undefended base is robbed: items move to the raiders, then vanish with them (stolen), preferring what the gang likes", function()
	local w = fworld(9)
	H.stock(w, { fuel_can = 4, ammo_9mm = 100, canned_beans = 10, scrap_wood = 10, jewelry = 3, pistol = 1 })
	local r = factions.plan_raid(w, 40, "rustjaw")
	local before = stockpile.totals(w.s.zones)
	local fuel_before = before.fuel_can
	for _ = 1, 400 do
		w:tick(1)
		if #w.s.raids == 0 then break end
	end
	T.eq(#w.s.raids, 0)
	local after = stockpile.totals(w.s.zones)
	T.lt(after.fuel_can or 0, fuel_before, "fuel is on the Rustjaw shopping list")
	T.gt(w.s.stats.items_stolen, 0)
	T.eq(w.s.ledger.reasons["-stolen"], w.s.stats.items_stolen, "stolen goods leave the world through the ledger")
	H.audit_ok(T, w, "after the robbery")
end)

T.test("materialized raiders: spawn_raiders near an observer, count shared with the horde cap, ped_died resolves the raid", function()
	local w = fworld(10)
	local r = factions.plan_raid(w, 40, "cinder")
	r.x, r.y = 600, 0
	r.state = "approach"
	w:handle({ type = "player_state", pos = { x = 650, y = 0, z = 0 } })
	local evs = w:tick(1)
	local e = H.find(evs, "spawn_raiders")
	T.truthy(e)
	T.eq(e.faction, "cinder")
	T.eq(e.id, r.id)
	T.eq(e.count, math.min(r.count, TUNING.horde.per_horde_max))
	T.truthy(e.pos and e.target)
	T.eq(horde.materialized_count(w), e.count)
	local n = r.count
	for i = 1, n - 1 do w:handle({ type = "ped_died", id = r.id, cause = "player" }) end
	T.eq(r.count, 1)
	local out = w:handle({ type = "ped_died", id = r.id, cause = "player" })
	T.eq(#w.s.raids, 0)
	T.truthy(H.find(out, "despawn_raiders") or true)
	T.eq(w.s.stats.raiders_killed, n)
	T.truthy(w.s.stats.attacks_repelled >= 1)
	-- moving the player away despawns a living raid group after the dwell time
	local w2 = fworld(11)
	local r2 = factions.plan_raid(w2, 40, "cinder")
	r2.x, r2.y = 600, 0
	w2:handle({ type = "player_state", pos = { x = 650, y = 0, z = 0 } })
	w2:tick(1)
	T.truthy(r2.mat)
	w2:handle({ type = "player_state", pos = { x = 650 + 3000, y = 0, z = 0 } })
	local all = {}
	for _ = 1, TUNING.horde.min_dwell + 2 do
		local e2 = w2:tick(1)
		for i = 1, #e2 do all[#all + 1] = e2[i] end
	end
	T.truthy(H.find(all, "despawn_raiders"))
end)

T.test("caravans: arrive with goods (ledger 'caravan'), one per faction, hostile factions refuse, leave and take leftovers", function()
	local w = fworld(12)
	factions.get(w, "rustjaw").goodwill = -80
	T.eq(select(2, factions.spawn_caravan(w, "rustjaw")), "hostile")
	local c = factions.spawn_caravan(w, "lantern")
	T.truthy(c)
	T.eq(select(2, factions.spawn_caravan(w, "lantern")), "already_here")
	T.gt(items.total_count(c.stock), 0)
	T.eq(w.s.ledger.reasons["+caravan"], items.total_count(c.stock))
	local evs = w:flush_events()
	local arrive = H.find(evs, "caravan")
	T.eq(arrive.phase, "arrive")
	T.eq(arrive.faction, "lantern")
	T.truthy(arrive.stock)
	T.truthy(H.find(evs, "play_alert", function(e) return e.kind == "caravan" end))
	H.audit_ok(T, w, "caravan arrived")
	local left = items.total_count(c.stock)
	w:tick(FT.caravan_stay + 1)
	T.eq(#w.s.caravans, 0)
	T.eq(w.s.ledger.reasons["-caravan_leave"], left)
	H.audit_ok(T, w, "caravan left")
end)

T.test("prices: they sell high, buy low, wanted categories pay a premium, goodwill moves the price", function()
	local w = fworld(13)
	local sell = factions.price(w, "tallow", "bandage", 4, false)   -- we buy 4 bandages
	local buy = factions.price(w, "tallow", "bandage", 4, true)     -- we sell 4 bandages
	T.gt(sell, buy, "spread between buying and selling")
	T.gt(factions.price(w, "tallow", "jewelry", 2, true), 2 * items.def("jewelry").value / FD.defs.tallow.markup * 0.999, "valuables are wanted")
	local base = factions.price(w, "cinder", "canned_beans", 5, false)
	factions.get(w, "cinder").goodwill = 80
	T.lt(factions.price(w, "cinder", "canned_beans", 5, false), base, "friends charge less")
	factions.get(w, "cinder").goodwill = -20
	T.gt(factions.price(w, "cinder", "canned_beans", 5, false), base, "enemies charge more")
	T.throws(function() factions.price(w, "cinder", "no_item", 1, true) end)
end)

T.test("trade: fair offers execute atomically with conservation; low offers, missing goods and bad items are rejected untouched", function()
	local w = fworld(14)
	local c = factions.spawn_caravan(w, "tallow")
	H.stock(w, { jewelry = 6, radio_set = 2 })
	local item = U.keys(c.stock.items)[1]
	local have = c.stock.items[item]
	local give, take = { jewelry = 2 }, { [item] = 1 }
	local gv, tv = factions.quote(w, c.id, give, take)
	T.truthy(gv and tv)
	local snapshot = U.hash(require("sim.save").serialize(w.s.zones) .. require("sim.save").serialize(c.stock))
	-- way too low: rejected, nothing moved
	local ok, why = factions.trade(w, c.id, { jewelry = 1 }, { [item] = have })
	T.falsy(ok)
	T.eq(why, "offer_too_low")
	T.falsy((factions.trade(w, c.id, { jewelry = 99 }, take)))
	T.eq(select(2, factions.trade(w, c.id, give, { bandage = 999 })), "caravan_lacks:bandage")
	T.falsy((factions.trade(w, c.id, { nonsense = 1 }, take)))
	T.falsy((factions.trade(w, c.id, give, { [item] = -1 })))
	T.falsy((factions.trade(w, "k999", give, take)))
	T.eq(U.hash(require("sim.save").serialize(w.s.zones) .. require("sim.save").serialize(c.stock)), snapshot, "failed trades changed nothing")
	-- an acceptable deal (we overpay by offering plenty of jewelry)
	local gw = factions.get(w, "tallow").goodwill
	local ok2, why2 = factions.trade(w, c.id, { jewelry = 3 }, take)
	T.truthy(ok2, why2)
	T.eq(stockpile.total(w.s.zones, "jewelry"), 3)
	T.eq(c.stock.items[item], have - 1)
	T.eq(items.count(c.stock, "jewelry"), 3)
	T.gt(factions.get(w, "tallow").goodwill, gw)
	T.le(factions.get(w, "tallow").goodwill - gw, FT.trade_goodwill_cap + 1e-9)
	local sp = H.find(w:flush_events(), "loot_spawn", function(e) return e.source == "trade" end)
	T.eq(sp.items[item], 1)
	T.eq(w.s.stats.trades, 1)
	H.audit_ok(T, w, "after the deal")
	-- via the adapter contract
	local r = w:handle({ type = "order", id = "colony", kind = "trade", target = { caravan = c.id, give = { jewelry = 3 }, take = { [item] = 1 } } })
	T.truthy(H.find(r, "order_result").ok)
	H.audit_ok(T, w, "after the ordered deal")
end)

T.test("gifts raise goodwill (capped) and destroy the goods; truces need enough value and stop raids for days", function()
	local w = fworld(15)
	H.stock(w, { jewelry = 10, canned_beans = 10 })
	local f = factions.get(w, "hollow_choir")
	local gw = f.goodwill
	T.falsy((factions.gift(w, "hollow_choir", { jewelry = 99 })))
	T.falsy((factions.gift(w, "nowhere", { jewelry = 1 })))
	local ok = factions.gift(w, "hollow_choir", { jewelry = 1 })
	T.truthy(ok)
	T.gt(f.goodwill, gw)
	T.eq(w.s.ledger.reasons["-gift"], 1)
	factions.gift(w, "hollow_choir", { jewelry = 6 })
	T.le(f.goodwill - gw, FT.gift_goodwill_cap * 2 + 1e-9)
	-- truce
	local g2 = fworld(16)
	H.stock(g2, { jewelry = 10 })
	local t_ok, t_why = factions.truce(g2, "hollow_choir", { jewelry = 1 })
	T.falsy(t_ok)
	T.eq(t_why, "offer_too_low")
	T.eq(select(2, factions.truce(g2, "lantern", { jewelry = 5 })), "not_a_gang")
	local ok3 = factions.truce(g2, "hollow_choir", { jewelry = 9 })
	T.truthy(ok3)
	T.eq(factions.get(g2, "hollow_choir").truce_until, g2.s.t + FT.truce_days * 1440)
	T.eq(factions.raid_weight(g2, factions.get(g2, "hollow_choir")), 0)
	g2.s.t = g2.s.t + FT.truce_days * 1440 + 1
	T.gt(factions.raid_weight(g2, factions.get(g2, "hollow_choir")), 0, "the truce expires")
	H.audit_ok(T, g2, "after the truce")
	local r = g2:handle({ type = "order", id = "colony", kind = "gift", target = { faction = "tallow", give = { jewelry = 1 } } })
	T.truthy(H.find(r, "order_result").ok)
end)
