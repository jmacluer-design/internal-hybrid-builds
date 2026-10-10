-- shared/view.lua: view models are read-only, msgpack-safe, JSON-encodable, small and stable.
local T, H = ...
local V = require("shared.view")
local U = require("shared.util")
local json = require("shared.json")
local World = require("sim.world")
local ITEMS = require("data.items")
local BP = require("data.blueprints")
local TUNING = require("data.tuning")
local horde = require("sim.horde")

T.group("view")

-- days > 0: the sim's own AI policy plays the colony (as it does in tests/hash_check.lua), so the world is still populated
local function world(seed, colonists, days)
	if days and days > 0 then
		return require("sim.runner").run({ seed = seed or 3, profile = "escalating", colonists = colonists or 4, days = days, max_dt = 1 }).world
	end
	return World.new({ seed = seed or 3, profile = "escalating", colonists = colonists or 4, max_dt = 1 })
end

local function safe(v, what)
	local ok, why = U.msgpack_safe(v)
	T.truthy(ok, what .. " is msgpack-safe: " .. tostring(why))
	local s = json.encode(v)
	T.truthy(#s > 2, what .. " encodes")
	return s
end

T.test("catalog: every item and blueprint is present, msgpack-safe, small", function()
	local c = V.catalog()
	local s = safe(c, "catalog")
	for id in pairs(ITEMS) do T.truthy(c.items[id], "item " .. id) end
	for id in pairs(BP) do T.truthy(c.blueprints[id], "blueprint " .. id) end
	T.eq(#c.item_order, U.count(ITEMS)); T.eq(#c.blueprint_order, U.count(BP))
	T.truthy(c.tuning.base.build_radius > 0)
	T.truthy(#c.work >= 6, "work types for the priorities grid")
	T.lt(#s, 60000, "catalog JSON stays under 60 KB (is " .. #s .. ")")
	T.note("catalog json %d bytes, %d items, %d blueprints", #s, U.count(c.items), U.count(c.blueprints))
end)

T.test("state: fresh world", function()
	local w = world(3, 4)
	local st = V.state(w, { speed = 1 })
	local s = safe(st, "state")
	T.eq(#st.colonists, 4); T.eq(st.res.colonists, 4); T.eq(st.day, 1); T.eq(st.over, false)
	T.truthy(st.colonists[1].prio and st.colonists[1].prio.cook ~= nil, "priority row per work type")
	T.truthy(st.threat and st.threat.level >= 0)
	T.lt(#s, 24000, "4-colonist state JSON under 24 KB (is " .. #s .. ")")
end)

T.test("state: late world with hordes, raids, buildings, history", function()
	local w = world(2, 6, 12)
	T.truthy(#w.s.colonists > 0, "someone survived 12 days under the sim AI")
	local b = TUNING.base
	horde.spawn(w, { x = b.x + 100, y = b.y, mix = { walker = 30, runner = 6 }, target = { x = b.x, y = b.y }, src = "test" })
	local st = V.state(w, { speed = 4, select = w.s.colonists[1] and w.s.colonists[1].id })
	safe(st, "late state")
	T.truthy(#st.hordes >= 1); T.truthy(st.card, "selected colonist card included")
	T.truthy(#st.history > 0, "history")
	T.truthy(#st.director.log > 0, "director log after 12 days")
	for _, bd in ipairs(st.buildings) do T.truthy(BP[bd.bp], "building blueprint known") end
end)

T.test("state: 30 colonists payload stays small and fast", function()
	local w = world(5, 30, 0)
	T.eq(#w.s.colonists, 30)
	local t0 = os.clock()
	local st
	for _ = 1, 20 do st = V.state(w, { speed = 1 }) end
	local ms = (os.clock() - t0) / 20 * 1000
	local s = safe(st, "30-colonist state")
	T.lt(#s, 120000, "30-colonist JSON under 120 KB (is " .. #s .. ")")
	T.lt(ms, 25, "building the view takes " .. string.format("%.2f", ms) .. " ms")
	T.note("30 colonists: %.2f ms per V.state on %s, %d bytes json", ms, _VERSION, #s)
end)

T.test("views are read-only: the world hash does not change", function()
	local w = world(4, 5, 6)
	local before = w:hash()
	V.state(w, { select = w.s.colonists[1].id }); V.catalog(); V.hud(w, nil, {}); V.summary(w); V.inventory(w, { other = { kind = "zone", id = w.s.zones[1].id } })
	for _, c in ipairs(w.s.colonists) do V.card(w, c) end
	T.eq(w:hash(), before)
end)

T.test("views are deterministic: identical worlds give identical JSON", function()
	local a, b = world(6, 5, 4), world(6, 5, 4)
	T.eq(json.encode(V.state(a, { speed = 2 })), json.encode(V.state(b, { speed = 2 })))
	T.eq(json.encode(V.summary(a)), json.encode(V.summary(b)))
end)

T.test("card: every colonist of a mid-game world", function()
	local w = world(1, 8, 5)
	for _, c in ipairs(w.s.colonists) do
		local card = V.card(w, c)
		safe(card, "card " .. c.id)
		T.truthy(card.skills and #card.skills > 0); T.truthy(card.mood_parts); T.eq(card.id, c.id)
		T.truthy(card.sched and #card.sched == 24, "24 hour schedule")
	end
	T.eq(V.card(w, nil), nil)
end)

T.test("inventory: player container, nearby list, other container", function()
	local w = world(3, 4, 1)
	local z = w.s.zones[1]
	local inv = V.inventory(w, { other = { kind = "zone", id = z.id } })
	safe(inv, "inventory")
	T.eq(inv.player.kind, "player"); T.truthy(inv.player.slots > 0); T.truthy(inv.other and inv.other.id == z.id)
	T.truthy(#inv.nearby >= 1)
	local none = V.inventory(w, { other = { kind = "zone", id = "nope" } })
	T.eq(none.other, nil)
	-- stacks never exceed the stack size of the item
	for _, st in ipairs(inv.other.stacks) do T.le(st.n, ITEMS[st.id].stack) end
end)

T.test("hud: defaults and ranges", function()
	local w = world(3, 4, 1)
	local hud = V.hud(w, nil, { speed = 1 })
	safe(hud, "hud")
	T.eq(hud.hp, 100); T.truthy(hud.clock:match("^%d%d:%d%d$")); T.truthy(hud.threat.label)
	local h2 = V.hud(w, { hp = 12, hp_max = 100, hunger = 80, thirst = 90, fatigue = 70, pain = 40, bleeding = 2.5, infection = "symptomatic", downed = false }, {})
	T.eq(h2.hp, 12); T.eq(h2.bleeding, 2.5); T.eq(h2.infection, "symptomatic")
end)

T.test("summary: after a collapse", function()
	local w = World.new({ seed = 2, profile = "chaos", colonists = 2, max_dt = 1 })
	local guard = 0
	while not w.s.over and guard < 60 do w:tick(1440); guard = guard + 1 end
	local sm = V.summary(w)
	safe(sm, "summary")
	T.eq(sm.over, w.s.over); T.eq(sm.alive, #w.s.colonists); T.eq(sm.colonists_ever, #w.s.colonists + #w.s.dead)
	T.truthy(#sm.history > 0)
	T.note("seed 2 chaos: over=%s after %d days, %d dead", tostring(sm.over), sm.survived_days, #sm.dead)
end)
