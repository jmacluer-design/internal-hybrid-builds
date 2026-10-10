-- helpers shared by the test files: small deterministic worlds for focused tests.
local H = {}

local U, TUNING, World, colonist, stockpile, blueprints, items

function H.init(root)
	package.path = root .. "/?.lua;" .. package.path
	U = require("sim.util")
	TUNING = require("data.tuning")
	World = require("sim.world")
	colonist = require("sim.colonist")
	stockpile = require("sim.stockpile")
	blueprints = require("sim.blueprints")
	items = require("sim.items")
	return H
end

-- An empty world (no colonists, no hordes, no zones) with one big stockpile zone at the base.
function H.world(opts)
	opts = opts or {}
	local w = World.new({ seed = opts.seed or 1, profile = opts.profile or "calm", scenario = "empty", max_dt = opts.max_dt or 1 })
	local z = stockpile.new(w:new_id("z"), "Main", { x = 10, y = 10, z = 0 }, 20, 3, {})
	z.main = true
	w:add_zone(z)
	w:flush_events()
	return w
end

-- add a healthy, well-fed colonist who works every hour and never needs to sleep during short tests
function H.colonist(w, opts)
	opts = opts or {}
	local rng = w:rng("test_setup")
	local c = colonist.new(rng, { id = w:new_id("c"), traits = opts.traits or {}, pos = opts.pos or { x = 12, y = 10, z = 0 },
		focus = opts.focus, joined = w.s.t })
	c.sched = string.rep("W", 24)
	c.hunger, c.thirst, c.fatigue = 5, 5, 5
	for _, wt in ipairs(colonist.WORK) do colonist.set_priority(c, wt, opts.prio or 3) end
	if opts.skills then
		for k, lvl in pairs(opts.skills) do c.skills[k] = { l = lvl, xp = require("sim.skills").xp_for_level(lvl) } end -- order-free
	end
	w:add_colonist(c)
	return c
end

-- put items into the main zone through the ledger (so audits stay valid)
function H.stock(w, map)
	local z = w.s.zones[1]
	for _, id in ipairs(U.keys(map)) do w:create(z.items, id, map[id], "test") end
end

-- place and instantly finish a building (no materials consumed)
function H.force_build(w, bp, pos)
	local b = assert(blueprints.place(w, bp, pos or { x = 20 + #w.s.buildings * 3, y = 20, z = 0 }))
	blueprints.complete(w, b)
	return b
end

-- keep colonists fed/rested so needs never interfere with a focused scenario
function H.keep_fed(w)
	for i = 1, #w.s.colonists do
		local c = w.s.colonists[i]
		c.hunger, c.thirst, c.fatigue = 5, 5, 5
	end
end

-- advance minutes; returns every event produced
function H.run(w, minutes, per_step)
	local all = {}
	local left = minutes
	while left > 0 do
		local n = left < 10 and left or 10
		local evs = w:tick(n)
		for i = 1, #evs do all[#all + 1] = evs[i] end
		if per_step then per_step(w) end
		left = left - n
	end
	return all
end

function H.count(events, type_name)
	local n = 0
	for i = 1, #events do if events[i].type == type_name then n = n + 1 end end
	return n
end

function H.find(events, type_name, pred)
	for i = 1, #events do
		if events[i].type == type_name and (not pred or pred(events[i])) then return events[i] end
	end
	return nil
end

function H.audit_ok(T, w, label)
	local ok, rep = w:audit()
	T.truthy(ok, (label or "audit") .. ": " .. tostring(rep.problems[1]))
end

return H
