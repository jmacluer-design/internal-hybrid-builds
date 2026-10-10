-- save: canonical serializer, versioned header, round-trip hash equality, migrations.
local T = ...
package.path = T.root .. "/?.lua;" .. T.root .. "/tests/?.lua;" .. package.path
local H = require("helpers").init(T.root)
local U = require("sim.util")
local World = require("sim.world")
local save = require("sim.save")
local policy = require("sim.ai_policy")
local runner = require("sim.runner")
local clock = require("sim.clock")
local horde = require("sim.horde")
local factions = require("sim.factions")
local expedition = require("sim.expedition")
local rng_mod = require("sim.rng")
local jobs = require("sim.jobs")

T.group("save")

T.test("serializer is canonical: insertion order does not matter, output is compact and stable", function()
	local a = { zeta = 1, alpha = { 3, 2, 1 }, mid = { x = 0.5, y = -2 }, flag = true, name = "hi" }
	local b = {}
	b.name = "hi"; b.flag = true; b.mid = { y = -2, x = 0.5 }; b.alpha = { 3, 2, 1 }; b.zeta = 1
	local sa, sb = save.serialize(a), save.serialize(b)
	T.eq(sa, sb)
	T.eq(sa, '{"alpha":[3,2,1],"flag":true,"mid":{"x":0.5,"y":-2},"name":"hi","zeta":1}')
	T.eq(save.serialize({}), "[]")
	T.eq(save.serialize({ {}, {} }), "[[],[]]")
	T.eq(save.serialize(3.0), "3")
	T.eq(save.serialize(-0.0), "0")
	T.eq(save.serialize("a\"b\\c\n"), '"a\\x22b\\x5cc\\x0a"')
	-- a big map hashes the same however it was built
	local m1, m2 = {}, {}
	for i = 1, 300 do m1["k" .. string.format("%d", i)] = i end
	for i = 300, 1, -1 do m2["k" .. string.format("%d", i)] = i end
	T.eq(save.serialize(m1), save.serialize(m2))
end)

T.test("round trip of values: numbers exact, strings with awkward bytes, nesting, empties", function()
	local vals = { 0.1, 1 / 3, 123456789.123456789, 1e-7, -1e15, 2 ^ 52 + 1, 12345, -7, 0, 1e300, 5e-324 }
	for _, v in ipairs(vals) do
		local back = save.deserialize(save.serialize({ v }))[1]
		T.eq(back, v, "number " .. U.fmt_num(v))
	end
	local weird = "line1\nline2\ttab \"quote\" back\\slash \0 nul \1\2\3 end é ü 日本"
	T.eq(save.deserialize(save.serialize({ s = weird })).s, weird)
	local nested = { a = { { b = { 1, { 2, 3 }, {} }, c = false } }, e = {}, str = "" }
	local back = save.deserialize(save.serialize(nested))
	T.eq(save.serialize(back), save.serialize(nested))
	T.eq(back.a[1].b[2][2], 3)
	T.eq(back.a[1].c, false)
	T.eq(back.str, "")
	T.eq(type(back.e), "table")
end)

T.test("the serializer refuses what cannot be saved (and says so)", function()
	T.throws(function() save.serialize({ f = function() end }) end, "functions")
	T.throws(function() save.serialize({ n = 0 / 0 }) end, "NaN")
	T.throws(function() save.serialize({ n = math.huge }) end, "inf")
	T.throws(function() save.serialize({ [1.5] = 1, x = 2 }) end, "non-string map key")
	T.throws(function() save.serialize({ 1, 2, nil, 4, x = 1 }) end, "mixed/sparse tables")
	T.throws(function() save.serialize({ [1] = "a", [3] = "c" }) end, "sparse array")
	local cyc = {}
	cyc.me = cyc
	T.throws(function() save.serialize(cyc) end, "cycles")
	T.throws(function() save.serialize(coroutine.create(function() end)) end, "threads")
end)

T.test("the parser fails cleanly on malformed input", function()
	local bad = { "", "  ", "{", "[1,2", '{"a":}', '{"a" 1}', '"abc', "tru", "[1,,2]", '{"a":1}x', '"\\q"', "-", "[1 2]", '{1:2}' }
	for _, s in ipairs(bad) do
		local ok = pcall(save.deserialize, s)
		T.falsy(ok, "should reject: " .. s)
	end
end)

local function midgame(seed, profile, days)
	local res = runner.run({ seed = seed, profile = profile, days = days, max_dt = 1 })
	return res.world
end

T.test("save/load round-trips a fresh world and a mid-game world to an identical state hash", function()
	local fresh = World.new({ seed = 3 })
	fresh:flush_events()
	local s1 = save.save(fresh)
	local back = save.load(s1)
	T.truthy(back)
	T.eq(back:hash(), fresh:hash())
	T.eq(save.save(back), s1, "saving the loaded world reproduces the same bytes")
	for _, spec in ipairs({ { 4, "calm", 6 }, { 5, "chaos", 5 }, { 6, "escalating", 9 } }) do
		local w = midgame(spec[1], spec[2], spec[3])
		local text = save.save(w)
		local w2, err = save.load(text)
		T.truthy(w2, err)
		T.eq(w2:hash(), w:hash(), string.format("seed %d %s day %d", spec[1], spec[2], spec[3]))
		T.eq(save.save(w2), text)
		T.truthy(select(1, w2:audit()), "loaded world conserves items")
		T.truthy(select(1, jobs.check_reservations(w2)), "reservations rebuilt")
		T.eq(#w2.s.colonists, #w.s.colonists)
	end
end)

T.test("a loaded world is fully live: rng streams re-attached, indexes rebuilt, ticking and handling work", function()
	local w = midgame(7, "calm", 5)
	local w2 = save.load(save.save(w))
	for _, name in ipairs(U.keys(w2.s.rngs)) do T.eq(getmetatable(w2.s.rngs[name]), rng_mod, "rng " .. name) end
	if w2.s.colonists[1] then T.eq(w2:colonist(w2.s.colonists[1].id), w2.s.colonists[1]) end
	if w2.s.buildings[1] then T.eq(w2:building(w2.s.buildings[1].id), w2.s.buildings[1]) end
	T.eq(w2:zone(w2.s.zones[1].id), w2.s.zones[1])
	T.no_throw(function() w2:tick(120) end)
	local out = w2:handle({ type = "noise", pos = { x = 0, y = 0, z = 0 }, loudness = 80 })
	T.eq(type(out), "table")
	T.truthy(select(1, w2:audit()))
	-- items caches (w, s) are recomputed from the counts, not trusted
	local text = save.save(w)
	local tampered = save.unpack(text)
	tampered.zones[1].items.w = 1
	local w3 = World.restore(tampered)
	T.truthy(select(1, require("sim.items").check(w3.s.zones[1].items)), "cached weight was rebuilt")
end)

T.test("save then continue == never saved: the loaded world evolves exactly like the original", function()
	local seeds = { { 8, "calm" }, { 9, "escalating" }, { 10, "chaos" } }
	for _, spec in ipairs(seeds) do
		local a = World.new({ seed = spec[1], profile = spec[2] })
		a:flush_events()
		local st = policy.new()
		local function advance(w, st2, minutes)
			local left = minutes
			while left > 0 do
				local n = left < 10 and left or 10
				w:tick(n)
				policy.step(w, st2, nil)
				left = left - n
			end
		end
		advance(a, st, 3 * 1440)
		local text = save.save(a)
		local b = save.load(text)
		local st_b = {}
		for k, v in pairs(st) do st_b[k] = (type(v) == "table") and U.deepcopy(v) or v end -- order-free
		advance(a, st, 2 * 1440)
		advance(b, st_b, 2 * 1440)
		T.eq(a:hash(), b:hash(), string.format("%s seed %d diverged after loading", spec[2], spec[1]))
	end
end)

T.test("hostile or damaged save files are rejected, never half-loaded", function()
	local w = World.new({ seed = 11 })
	w:flush_events()
	local good = save.save(w)
	T.truthy(save.load(good))
	local function rejects(text, why)
		local r, err = save.load(text)
		T.eq(r, nil, why)
		T.eq(type(err), "string", why .. " (returns an error string)")
	end
	rejects("", "empty")
	rejects("hello", "not a save")
	rejects(good:sub(1, #good - 100), "truncated")
	local i = good:find("\n") + 50
	rejects(good:sub(1, i - 1) .. (good:sub(i, i) == "a" and "b" or "a") .. good:sub(i + 1), "one flipped byte")
	rejects(good:gsub("^OUTBREAK%-SAVE %d+", "OUTBREAK-SAVE 99"), "newer version")
	rejects((good:gsub("^(OUTBREAK%-SAVE %d+ )%d+", "%1" .. "5")), "wrong length")
	rejects(save.pack({ version = 2 }, 0), "version 0 has no migration")
	rejects("OUTBREAK-SAVE 2 5 0000000000000000\n[1,2,", "payload hash mismatch")
	-- a valid envelope around a non-table payload
	rejects(save.pack({}, 2):gsub("%[%]$", "5"), "payload not a table")
	T.eq(select(2, save.unpack("nope")), "not a save file")
end)

T.test("migration stub: a version-1 save loads, is upgraded, and keeps running", function()
	local w = midgame(12, "calm", 3)
	local state = save.deserialize(save.serialize(w.s)) -- deep copy through the serializer
	state.version = 1
	state.history = nil -- v1 predates the daily history and the cached day number
	state.day = nil
	local v1 = save.pack(state, 1)
	T.truthy(v1:find("^OUTBREAK%-SAVE 1 "))
	T.truthy(save.migrations[1], "a v1 -> v2 migration exists")
	local w2, err = save.load(v1)
	T.truthy(w2, err)
	T.eq(w2.s.version, save.CURRENT_VERSION)
	T.eq(type(w2.s.history), "table")
	T.eq(w2.s.day, clock.day(w2.s.t))
	T.eq(#w2.s.colonists, #w.s.colonists)
	T.no_throw(function() w2:tick(60) end)
	-- migrating in place preserves everything else
	local direct = save.migrate(save.deserialize(save.serialize(state)), 1)
	T.eq(direct.version, 2)
	T.eq(direct.seed, w.s.seed)
	-- a gap in the chain is an error, not silent corruption
	local saved = save.migrations[1]
	save.migrations[1] = nil
	local r, e = save.load(v1)
	save.migrations[1] = saved
	T.eq(r, nil)
	T.truthy(e:find("migration"))
	T.eq(save.CURRENT_VERSION, World.STATE_VERSION)
end)

T.test("states mid-event (materialized hordes, raids, caravans, expeditions) save and load", function()
	local w = World.new({ seed = 13, profile = "chaos" })
	w:flush_events()
	horde.spawn(w, { x = 300, y = 0, mix = { walker = 30, runner = 4 } })
	w:handle({ type = "player_state", pos = { x = 300, y = 0, z = 0 } })
	w:tick(5)
	T.truthy(horde.materialized_count(w) > 0)
	factions.plan_raid(w, 40, "cinder")
	factions.spawn_caravan(w, "lantern")
	expedition.plan(w, { district = "orchard", size = 2 })
	w:tick(30)
	local text = save.save(w)
	local w2 = save.load(text)
	T.eq(w2:hash(), w:hash())
	T.eq(horde.materialized_count(w2), horde.materialized_count(w))
	T.eq(#w2.s.raids, #w.s.raids)
	T.eq(#w2.s.caravans, #w.s.caravans)
	T.eq(#w2.s.exped, #w.s.exped)
	w:tick(300)
	w2:tick(300)
	T.eq(w2:hash(), w:hash(), "they stay in lockstep afterwards")
end)

T.test("save size stays bounded over a month (no unbounded state growth)", function()
	local w = World.new({ seed = 14, profile = "calm" })
	w:flush_events()
	local st = policy.new()
	local sizes = {}
	for day = 1, 30 do
		for _ = 1, 144 do
			w:tick(10)
			policy.step(w, st, nil)
		end
		if day == 10 or day == 20 or day == 30 then sizes[#sizes + 1] = #save.save(w) end
		if w.s.over then break end
	end
	if #sizes == 3 then
		T.lt(sizes[3], sizes[1] * 2.2, "day-30 save is not wildly bigger than the day-10 save")
	end
	T.gt(#sizes, 0)
end)
