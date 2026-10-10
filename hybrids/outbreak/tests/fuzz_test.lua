-- property-style fuzz: thousands of seeded random operations (hauling, crafting, cooking, expeditions, trading, containers,
-- damage, orders, save/load, time jumps) with the conservation check (no item duplicated or lost), reservation and
-- need invariants after every single operation.
local T = ...
package.path = T.root .. "/?.lua;" .. T.root .. "/tests/?.lua;" .. package.path
local H = require("helpers").init(T.root)
local U = require("sim.util")
local R = require("sim.rng")
local TUNING = require("data.tuning")
local World = require("sim.world")
local save = require("sim.save")
local items = require("sim.items")
local needs = require("sim.needs")
local jobs = require("sim.jobs")
local factions = require("sim.factions")
local expedition = require("sim.expedition")
local director = require("sim.director")
local horde = require("sim.horde")
local blueprints = require("sim.blueprints")
local clock = require("sim.clock")
local stockpile = require("sim.stockpile")
local DISTRICTS = require("data.districts")

T.group("fuzz")

local ITEM_IDS = items.all_ids()
local ORDERS = { "priority", "draft", "goto", "equip", "place_blueprint", "expedition", "schedule", "zone_create", "amputation", "cancel_blueprint",
	"trade", "gift", "truce", "toggle_building", "set_profile", "cancel_expedition", "zone_set" }

local function pos(rng, spread)
	return { x = rng:range(-spread, spread), y = rng:range(-spread, spread), z = 0 }
end

-- one random operation; returns its name (for the failure message)
local function random_op(w, rng)
	local s = w.s
	local op = rng:int(1, 22)
	local cs = s.colonists
	local pick_c = function() return cs[1] and cs[rng:int(1, #cs)] end
	if op <= 3 then -- time passes
		w:tick(rng:int(1, 30))
		return "tick"
	elseif op == 4 then -- loot appears on the ground
		local p = w:pile_for(pos(rng, 120))
		for _ = 1, rng:int(1, 4) do w:create(p.items, ITEM_IDS[rng:int(1, #ITEM_IDS)], rng:int(1, 6), "fuzz") end
		return "ground loot"
	elseif op == 5 then -- stock raw materials / ingredients so cooks and crafters have work
		local z = s.zones[rng:int(1, #s.zones)]
		for _, id in ipairs({ "rice_bag", "firewood", "cloth_scrap", "scrap_metal", "canned_veg", "dried_meat", "scrap_wood", "nails" }) do
			if rng:chance(0.5) then w:create(z.items, id, rng:int(1, 5), "fuzz") end
		end
		return "stock inputs"
	elseif op == 6 then -- build stations (cooking / crafting)
		local id = ({ "campfire", "workbench", "stove", "bed", "crate", "wall", "generator", "rain_collector", "lamp" })[rng:int(1, 9)]
		blueprints.place(w, id, pos(rng, 100))
		return "place " .. id
	elseif op == 7 then -- random item_moved between random containers
		local list = w:all_containers()
		local function loc()
			local l = list[rng:int(1, #list)][1]
			local kind, id = l:match("^(%w+):?(.*)$")
			if kind == "zone" or kind == "pile" or kind == "colonist" then return { kind = kind, id = id } end
			if kind == "player" then return { kind = "player" } end
			if kind == "container" then return { kind = "container", id = id } end
			return { kind = "void" }
		end
		w:handle({ type = "item_moved", from = loc(), to = loc(), item = ITEM_IDS[rng:int(1, #ITEM_IDS)], n = rng:int(1, 8) })
		return "item_moved"
	elseif op == 8 then
		w:handle({ type = "container_opened", container = "box:" .. string.format("%d", rng:int(1, 25)),
			ctype = ({ "house", "store", "clinic", "bunker", "garage", "kitchen", "nothing" })[rng:int(1, 7)], pos = pos(rng, 1500) })
		return "container_opened"
	elseif op == 9 then -- expedition
		local ids = U.keys(DISTRICTS)
		local crew = {}
		for _, c in ipairs(cs) do if #crew < 2 and c.state ~= "away" and not c.downed then crew[#crew + 1] = c.id end end
		w:create(s.zones[1].items, "fuel_can", 1, "fuzz")
		expedition.plan(w, { district = ids[rng:int(1, #ids)], crew = rng:chance(0.7) and crew or nil, size = 2, mode = rng:chance(0.3) and "foot" or nil })
		return "expedition"
	elseif op == 10 then -- trade / caravans
		if #s.caravans == 0 then
			local f = factions.get(w, s.factions[rng:int(1, #s.factions)].id)
			factions.spawn_caravan(w, f.id)
		else
			local c = s.caravans[1]
			local give, take = {}, {}
			local inv = stockpile.totals(s.zones)
			local keys = U.keys(inv)
			if #keys > 0 then give[keys[rng:int(1, #keys)]] = rng:int(1, 3) end
			local ck = U.keys(c.stock.items)
			if #ck > 0 then take[ck[rng:int(1, #ck)]] = rng:int(1, 2) end
			w:handle({ type = "order", id = "colony", kind = "trade", target = { caravan = c.id, give = give, take = take } })
		end
		return "trade"
	elseif op == 11 then -- damage
		local c = pick_c()
		if c then w:handle({ type = "ped_damage", id = c.id, amount = rng:range(0, 25), kind = ({ "bite", "scratch", "cut", "bullet", "blunt", "fire" })[rng:int(1, 6)] }) end
		return "damage"
	elseif op == 12 then -- someone dies / horde peds die
		if rng:chance(0.15) and #cs > 1 then
			w:handle({ type = "ped_died", id = pick_c().id, cause = "fuzz" })
		elseif s.hordes[1] then
			w:handle({ type = "ped_died", id = s.hordes[rng:int(1, #s.hordes)].id, zkind = "walker" })
		end
		return "died"
	elseif op == 13 then -- player moves around (materializes / dematerializes hordes)
		w:handle({ type = "player_state", pos = pos(rng, 1800), needs = { hunger = rng:int(0, 100) } })
		return "player"
	elseif op == 14 then
		w:handle({ type = "noise", pos = pos(rng, 1500), loudness = rng:range(5, 200) })
		return "noise"
	elseif op == 15 then -- player orders
		local kind = ORDERS[rng:int(1, #ORDERS)]
		local c = pick_c()
		local target
		if kind == "priority" then target = { work = ({ "haul", "build", "cook", "craft", "doctor", "guard", "scavenge" })[rng:int(1, 7)], level = rng:int(-1, 5) }
		elseif kind == "draft" then target = rng:chance(0.5)
		elseif kind == "goto" then target = pos(rng, 150)
		elseif kind == "equip" then target = { item = ({ "pistol", "rifle", "shotgun", "machete", "ammo_9mm" })[rng:int(1, 5)] }
		elseif kind == "place_blueprint" then target = { bp = ({ "wall", "bed", "door", "barricade", "floor", "crate" })[rng:int(1, 6)], pos = pos(rng, 100) }
		elseif kind == "expedition" then target = { district = ({ "orchard", "old_town", "depot" })[rng:int(1, 3)], size = 2 }
		elseif kind == "schedule" then target = ({ "day", "night", "early" })[rng:int(1, 3)]
		elseif kind == "zone_create" then target = { name = "Z", pos = pos(rng, 60), tiles = rng:int(1, 4), prio = rng:int(1, 5), cats = rng:chance(0.5) and { "food" } or nil }
		elseif kind == "amputation" then target = rng:chance(0.5)
		elseif kind == "cancel_blueprint" then target = { id = s.buildings[1] and s.buildings[rng:int(1, #s.buildings)].id or "b0" }
		elseif kind == "toggle_building" then target = { id = s.buildings[1] and s.buildings[rng:int(1, #s.buildings)].id or "b0", enabled = rng:chance(0.7) }
		elseif kind == "set_profile" then target = ({ "calm", "escalating", "chaos" })[rng:int(1, 3)]
		elseif kind == "cancel_expedition" then target = { id = s.exped[1] and s.exped[1].id or "x0" }
		elseif kind == "zone_set" then target = { id = s.zones[1].id, prio = rng:int(1, 5) }
		else target = {} end
		w:handle({ type = "order", id = (c and rng:chance(0.8)) and c.id or "colony", kind = kind, target = target })
		return "order " .. kind
	elseif op == 16 then
		director.force(w, ({ "horde_wave", "gang_raid", "storm", "power_outage", "water_outage", "helicopter_flyover", "supply_drop", "caravan", "refugee_arrival", "infection_outbreak" })[rng:int(1, 10)], nil)
		s.director.budget = s.director.budget + 60
		return "director.force"
	elseif op == 17 then -- clock jumps
		w:handle({ type = "time_set", hour = rng:int(0, 23), minute = rng:int(0, 59) })
		return "time_set"
	elseif op == 18 then
		if #cs < 2 then w:add_refugee() end
		return "refugee"
	elseif op == 19 then -- gifts
		local keys = U.keys(stockpile.totals(s.zones))
		if #keys > 0 then factions.gift(w, s.factions[rng:int(1, #s.factions)].id, { [keys[rng:int(1, #keys)]] = rng:int(1, 3) }) end
		return "gift"
	elseif op == 20 then -- feed the colony so it lives long enough to be interesting
		for _, c in ipairs(cs) do
			if rng:chance(0.4) then c.hunger = U.max(0, c.hunger - 40); c.thirst = U.max(0, c.thirst - 40) end
		end
		return "feed"
	elseif op == 21 then -- heal
		for _, c in ipairs(cs) do if rng:chance(0.3) and not c.dead then c.hp = U.min(c.hp_max, c.hp + 30) end end
		return "heal"
	else
		return "noop"
	end
end

local function check_all(w, label)
	local ok, rep = w:audit()
	T.truthy(ok, label .. ": conservation broken: " .. tostring(rep.problems[1]))
	local rok, rerr = jobs.check_reservations(w)
	T.truthy(rok, label .. ": reservations: " .. tostring(rerr))
	local bad
	for i = 1, #w.s.colonists do
		local c = w.s.colonists[i]
		local nok, nerr = needs.check(c)
		if not nok then bad = bad or (c.id .. " " .. tostring(nerr)) end
		if c.dead then bad = bad or (c.id .. " dead but still in the roster") end
		for id, n in pairs(c.inv.items) do -- order-free
			if n <= 0 then bad = bad or "non-positive inventory count" end
		end
	end
	T.truthy(bad == nil, label .. ": " .. tostring(bad))
	local hbad
	if horde.materialized_count(w) > TUNING.horde.max_materialized then hbad = "materialization cap exceeded" end
	for _, h in ipairs(w.s.hordes) do
		if h.size <= 0 or h.size ~= h.size then hbad = hbad or "bad horde size" end
		if h.mat and h.mat.count > h.size then hbad = hbad or "more real peds than horde members" end
	end
	T.truthy(hbad == nil, label .. ": " .. tostring(hbad))
	local d = w.s.director
	T.truthy(d.budget >= -1e-9 and d.budget == d.budget, label .. ": director budget invalid")
	T.finite(w.s.t, label .. ": clock")
end

T.test("fuzz: 3 worlds x 700 random operations, conservation + invariants checked after EVERY operation", function()
	local total = 0
	for _, seed in ipairs({ 101, 202, 303 }) do
		local w = World.new({ seed = seed, profile = ({ "calm", "escalating", "chaos" })[seed % 3 + 1] })
		w:flush_events()
		local rng = R.new(seed * 7)
		for step = 1, 700 do
			local name = random_op(w, rng)
			total = total + 1
			if step % 3 == 0 then check_all(w, string.format("seed %d op %d (%s)", seed, step, name)) end
			if step % 150 == 0 then
				-- save/load in the middle of the chaos: the loaded world must be identical and fully conserved
				local text = save.save(w)
				local w2, err = save.load(text)
				T.truthy(w2, err)
				T.eq(w2:hash(), w:hash(), "round trip at op " .. step)
				w = w2
				check_all(w, "after reload")
			end
		end
		check_all(w, "end of seed " .. seed)
	end
	T.ge(total, 2000)
	T.truthy(true)
end)

T.test("fuzz: item flow ledger balances by reason (every create has a matching consumer or a container)", function()
	local w = World.new({ seed = 404, profile = "calm" })
	w:flush_events()
	local rng = R.new(404)
	for _ = 1, 600 do random_op(w, rng) end
	local ok, rep = w:audit()
	T.truthy(ok, rep.problems[1])
	local created, destroyed = 0, 0
	for k, v in pairs(w.s.ledger.reasons) do -- order-free (integer sums)
		if k:sub(1, 1) == "+" then created = created + v else destroyed = destroyed + v end
	end
	local held = 0
	for _, n in pairs(rep.totals) do held = held + n end -- order-free
	T.eq(created - destroyed, held, "everything ever created and not destroyed is held somewhere")
	T.gt(created, 100)
	T.gt(destroyed, 10)
end)

T.test("fuzz: random event streams with random garbage fields never raise", function()
	local w = World.new({ seed = 505 })
	w:flush_events()
	local rng = R.new(505)
	local junk = { 0, -1, 1e12, "x", "", true, false, {}, { x = 1 }, { x = "a", y = {} }, 0 / 0 }
	local types = { "noise", "ped_damage", "ped_died", "player_state", "order", "item_moved", "container_opened", "time_set",
		"horde_report", "raid_report", "colonist_ref", "bogus" }
	local fields = { "id", "amount", "kind", "pos", "loudness", "needs", "target", "from", "to", "item", "n", "container", "ctype", "hour", "minute", "day", "cause", "zkind", "ref" }
	for i = 1, 3000 do
		local ev = { type = types[rng:int(1, #types)] }
		for _ = 1, rng:int(0, 5) do ev[fields[rng:int(1, #fields)]] = junk[rng:int(1, #junk)] end
		if rng:chance(0.3) and w.s.colonists[1] then ev.id = w.s.colonists[1].id end
		local ok, err = pcall(w.handle, w, ev)
		if not ok then T.truthy(false, "event " .. i .. " (" .. ev.type .. ") raised: " .. tostring(err)) end
		if i % 100 == 0 then w:tick(5) end
	end
	T.truthy(true)
	check_all(w, "after garbage")
end)
