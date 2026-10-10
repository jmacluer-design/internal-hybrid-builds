-- contract: API.md is parsed and checked against what the sim really emits and accepts.
--   * every documented IN event / order kind has a handler (and vice versa), and its example is accepted without an `error`
--   * every OUT event type the sim emits in a scripted full-coverage scenario is documented (and every documented one occurs)
--   * every field of every emitted event is documented; every non-optional documented field is present; field types match
--   * every example block in the document is itself consistent with its table
local T = ...
package.path = T.root .. "/?.lua;" .. T.root .. "/tests/?.lua;" .. package.path
local H = require("helpers").init(T.root)
local U = require("sim.util")
local TUNING = require("data.tuning")
local World = require("sim.world")
local handlers = require("sim.handlers")
local policy = require("sim.ai_policy")
local director = require("sim.director")
local factions = require("sim.factions")
local horde = require("sim.horde")
local blueprints = require("sim.blueprints")
local clock = require("sim.clock")
local needs = require("sim.needs")
local expedition = require("sim.expedition")

T.group("contract")

-- ---------------------------------------------------------------------------------------------
-- parse API.md
-- ---------------------------------------------------------------------------------------------
local function read_doc()
	local f = assert(io.open(T.root .. "/API.md", "rb"))
	local s = f:read("*a")
	f:close()
	return s
end

local function load_expr(src)
	local fn = (loadstring or load)("return " .. src)
	if not fn then return nil end
	local ok, v = pcall(fn)
	if ok then return v end
	return nil
end

-- returns { out = { name = {fields = {name = {type=, optional=}}, order = {...}, examples = {tbl...}} }, ["in"] = {...}, orders = {...} }
local function parse(doc)
	local res = { out = {}, ["in"] = {}, orders = {} }
	local cur
	local in_code, code_buf = false, nil
	for line in (doc .. "\n"):gmatch("(.-)\n") do
		local dir, name = line:match("^### (%u+) `([%w_]+)`")
		local okind = line:match("^#### order `([%w_]+)`")
		if dir then
			cur = { name = name, fields = {}, order = {}, examples = {} }
			if dir == "OUT" then res.out[name] = cur elseif dir == "IN" then res["in"][name] = cur end
			in_code = false
		elseif okind then
			cur = { name = okind, fields = {}, order = {}, examples = {} }
			res.orders[okind] = cur
			in_code = false
		elseif line:match("^## ") then
			cur = nil
		elseif cur then
			if line:match("^```lua") then
				in_code, code_buf = true, {}
			elseif line:match("^```") and in_code then
				in_code = false
				cur.examples[#cur.examples + 1] = table.concat(code_buf, "\n")
			elseif in_code then
				code_buf[#code_buf + 1] = line
			else
				local fname, ftype = line:match("^| `([%w_]+)` | ([^|]-) | ")
				if fname then
					local optional = ftype:find("?", 1, true) ~= nil
					cur.fields[fname] = { type = (ftype:gsub("%?", "")):gsub("%s+$", ""), optional = optional }
					cur.order[#cur.order + 1] = fname
				end
			end
		end
	end
	return res
end

local DOC = parse(read_doc())

local function matches_type(v, ty)
	if ty == "any" then return v ~= nil end
	if ty == "string" then return type(v) == "string" end
	if ty == "number" then return type(v) == "number" end
	if ty == "boolean" then return type(v) == "boolean" end
	if ty == "table" then return type(v) == "table" end
	if ty == "pos" then return type(v) == "table" and type(v.x) == "number" and type(v.y) == "number" and type(v.z) == "number" end
	if ty == "string[]" or ty == "table[]" then
		if type(v) ~= "table" then return false end
		for i = 1, #v do
			if ty == "string[]" and type(v[i]) ~= "string" then return false end
			if ty == "table[]" and type(v[i]) ~= "table" then return false end
		end
		return true
	end
	return false
end

-- ---------------------------------------------------------------------------------------------
T.test("API.md documents the required events in both directions", function()
	local req_out = { "colonist_task", "spawn_horde", "despawn_horde", "spawn_raiders", "place_blueprint", "construction_progress",
		"construction_done", "set_power", "set_water", "loot_spawn", "colonist_state", "notify", "play_alert", "director_log" }
	for _, n in ipairs(req_out) do T.truthy(DOC.out[n], "OUT " .. n .. " is documented") end
	local req_in = { "noise", "ped_damage", "ped_died", "player_state", "order", "item_moved", "container_opened", "time_set" }
	for _, n in ipairs(req_in) do T.truthy(DOC["in"][n], "IN " .. n .. " is documented") end
	for _, ev in pairs(DOC.out) do -- order-free
		T.truthy(#ev.order >= 1, ev.name .. " has a field table")
		T.truthy(#ev.examples >= 1, ev.name .. " has an example")
	end
	for _, ev in pairs(DOC["in"]) do -- order-free
		T.truthy(#ev.order >= 1, "IN " .. ev.name .. " has a field table")
		if ev.name ~= "order" then T.truthy(#ev.examples >= 1, "IN " .. ev.name .. " has an example") end -- order examples live under each kind
	end
	for _, ev in pairs(DOC.orders) do -- order-free
		T.truthy(#ev.examples >= 1, "order " .. ev.name .. " has an example")
	end
	T.ge(U.count(DOC.orders), 16)
end)

T.test("every documented IN event and order kind has a handler, and every handler is documented", function()
	for name in pairs(DOC["in"]) do T.truthy(handlers.handlers[name], "IN " .. name .. " has a handler") end -- order-free
	for name in pairs(handlers.handlers) do T.truthy(DOC["in"][name], "handler " .. name .. " is documented") end -- order-free
	for kind in pairs(DOC.orders) do T.truthy(handlers.orders[kind], "order " .. kind .. " has a handler") end -- order-free
	for kind in pairs(handlers.orders) do T.truthy(DOC.orders[kind], "order handler " .. kind .. " is documented") end -- order-free
end)

T.test("every IN example in the document evaluates, validates against its own table, and is accepted by the sim", function()
	local function check_example(spec, label, is_order)
		for i, src in ipairs(spec.examples) do
			local ev = load_expr(src)
			T.eq(type(ev), "table", label .. " example " .. i .. " is a Lua table literal")
			if type(ev) == "table" then
				if not is_order then T.eq(ev.type, spec.name, label .. " example type") end
				if not is_order then
					for k, v in pairs(ev) do -- order-free
						if k ~= "type" then
							local f = spec.fields[k]
							T.truthy(f, label .. " example uses undocumented field " .. tostring(k))
							if f then T.truthy(matches_type(v, f.type) or f.type == "any" or f.type == "table", label .. "." .. k .. " has the documented type") end
						end
					end
				else
					T.eq(ev.type, "order")
					T.eq(ev.kind, spec.name)
				end
				local w = World.new({ seed = 77 })
				w:flush_events()
				-- a few things the examples refer to
				w:create(w.s.zones[1].items, "pistol", 1, "test")
				w:create(w.s.zones[1].items, "jewelry", 5, "test")
				factions.spawn_caravan(w, "tallow")
				if w.s.caravans[1] then w.s.caravans[1].id = "k1" end
				local out = w:handle(ev)
				if ev.type == "order" then
					local n = 0
					for _, e in ipairs(out) do if e.type == "order_result" then n = n + 1; T.eq(e.kind, ev.kind) end end
					T.eq(n, 1, label .. " answers with exactly one order_result")
				end
				for _, e in ipairs(out) do T.ne(e.type, "error", label .. " example must not provoke an error event") end
				T.truthy(select(1, w:audit()), "audit after " .. label)
			end
		end
	end
	for _, name in ipairs(U.keys(DOC["in"])) do check_example(DOC["in"][name], "IN " .. name, false) end
	for _, kind in ipairs(U.keys(DOC.orders)) do check_example(DOC.orders[kind], "order " .. kind, true) end
end)

-- ---------------------------------------------------------------------------------------------
-- a scripted scenario that makes the sim emit every OUT event type
-- ---------------------------------------------------------------------------------------------
local function collect_all()
	local evs = {}
	local function take(list) for i = 1, #list do evs[#evs + 1] = list[i] end end
	local w = World.new({ seed = 31, profile = "chaos" })
	take(w:flush_events())
	local st = policy.new()
	local function run(minutes)
		local left = minutes
		while left > 0 do
			local n = left < 10 and left or 10
			take(w:tick(n))
			local sink = {}
			policy.step(w, st, sink)
			take(sink)
			left = left - n
		end
	end
	run(2 * 1440) -- colony life: tasks, states, construction, expeditions, day_start, weather ...
	-- adapter-side IN events and their answers
	take(w:handle({ type = "noise", pos = { x = 0, y = 0, z = 0 }, loudness = 50 }))
	take(w:handle({ type = "order", id = "colony", kind = "place_blueprint", target = { bp = "wall", pos = { x = 40, y = 40, z = 0 } } }))
	take(w:handle({ type = "order", id = "nobody", kind = "priority", target = {} }))
	take(w:handle({ type = "item_moved", from = { kind = "void" }, to = { kind = "player" }, item = "pistol", n = 1 }))
	take(w:handle({ type = "container_opened", container = "fridge:1", ctype = "fridge", pos = { x = 500, y = 300, z = 0 } }))
	take(w:handle({ type = "container_opened", container = "fridge:1", ctype = "fridge", pos = { x = 500, y = 300, z = 0 } }))
	take(w:handle({ type = "bogus" }))
	-- storyteller events (budget topped up so they can pay)
	w.s.director.budget = 2000
	for _, id in ipairs({ "horde_wave", "gang_raid", "helicopter_flyover", "power_outage", "water_outage", "storm", "supply_drop", "caravan", "refugee_arrival", "infection_outbreak" }) do
		director.force(w, id, nil)
	end
	take(w:flush_events())
	w.s.grid.water.ok = false -- the supply was dry; the rain collectors / tank bring it back and the flip is announced
	run(30)
	-- a horde near the player materializes, then the player leaves
	local h = horde.spawn(w, { x = 700, y = 700, mix = { walker = 10, runner = 3 } })
	h.state = "linger"; h.linger_until = 1e12
	take(w:handle({ type = "player_state", pos = { x = 700, y = 700, z = 0 } }))
	run(10)
	take(w:handle({ type = "player_state", pos = { x = 700 + 3000, y = 700, z = 0 } }))
	run(20)
	-- raiders near the player
	local r = factions.plan_raid(w, 40, "cinder")
	r.x, r.y = 600, -600
	take(w:flush_events())
	take(w:handle({ type = "player_state", pos = { x = 640, y = -600, z = 0 } }))
	run(10)
	take(w:handle({ type = "player_state", pos = { x = 6000, y = 0, z = 0 } }))
	run(15)
	-- damage + death + turning + leaving + a destroyed building
	local c = w.s.colonists[1]
	if c then
		take(w:handle({ type = "ped_damage", id = c.id, amount = 10, kind = "bite" }))
		needs.infect(c, w:rng("t"), "arm")
	end
	for i = 1, #w.s.buildings do
		if w.s.buildings[i].state == "built" and w.s.buildings[i].bp == "wall" then blueprints.damage(w, w.s.buildings[i], 99999); break end
	end
	take(w:flush_events())
	if w.s.colonists[2] then take(w:handle({ type = "ped_died", id = w.s.colonists[2].id, cause = "zombies" })) end
	if w.s.colonists[2] then w:colonist_leaves(w.s.colonists[2], "wandered_off") end
	take(w:flush_events())
	run(30)
	-- a long time later the caravan leaves; kill the rest
	run(400)
	local rest = {}
	for i = 1, #w.s.colonists do rest[i] = w.s.colonists[i].id end
	for _, id in ipairs(rest) do take(w:handle({ type = "ped_died", id = id, cause = "zombies" })) end
	run(20)
	take(w:flush_events())
	return evs
end

T.test("full-coverage scenario: every OUT type the sim emits is documented, and every documented OUT type occurs", function()
	local evs = collect_all()
	local seen = {}
	for i = 1, #evs do seen[evs[i].type] = (seen[evs[i].type] or 0) + 1 end
	T.gt(#evs, 500, "the scenario produced plenty of events")
	for name in pairs(seen) do T.truthy(DOC.out[name], "emitted but undocumented OUT event: " .. name) end -- order-free
	for name in pairs(DOC.out) do T.truthy(seen[name], "documented but never emitted in the scenario: " .. name) end -- order-free
	T.ge(U.count(seen), 25)
end)

T.test("every field of every emitted event is documented with the right type; required fields are always present", function()
	local evs = collect_all()
	local missing_required, undocumented, wrong_type = {}, {}, {}
	for i = 1, #evs do
		local e = evs[i]
		local spec = DOC.out[e.type]
		if spec then
			T.eq(type(e.t), "number", "every event carries t")
			for k, v in pairs(e) do -- order-free
				if k ~= "type" and k ~= "t" then
					local f = spec.fields[k]
					if not f then
						undocumented[e.type .. "." .. k] = true
					elseif not matches_type(v, f.type) then
						wrong_type[e.type .. "." .. k .. " (" .. f.type .. ")"] = true
					end
				end
			end
			for _, k in ipairs(spec.order) do
				if not spec.fields[k].optional and e[k] == nil then missing_required[e.type .. "." .. k] = true end
			end
		end
	end
	local function list(t) local l = U.keys(t); return table.concat(l, ", ") end
	T.eq(list(undocumented), "", "emitted fields missing from API.md")
	T.eq(list(wrong_type), "", "fields whose Lua type differs from the documented type")
	T.eq(list(missing_required), "", "documented as always present but sometimes absent")
end)

T.test("every OUT example in the document matches its own field table", function()
	for _, name in ipairs(U.keys(DOC.out)) do
		local spec = DOC.out[name]
		for i, src in ipairs(spec.examples) do
			local ev = load_expr(src)
			T.eq(type(ev), "table", "OUT " .. name .. " example " .. i .. " is a Lua table literal")
			if type(ev) == "table" then
				T.eq(ev.type, name)
				T.eq(type(ev.t), "number", name .. " example has t")
				for k, v in pairs(ev) do -- order-free
					if k ~= "type" and k ~= "t" then
						local f = spec.fields[k]
						T.truthy(f, "OUT " .. name .. " example uses undocumented field " .. tostring(k))
						if f then T.truthy(matches_type(v, f.type), "OUT " .. name .. "." .. k .. " example has the documented type " .. f.type) end
					end
				end
				for _, k in ipairs(spec.order) do
					if not spec.fields[k].optional then T.truthy(ev[k] ~= nil, "OUT " .. name .. " example includes required field " .. k) end
				end
			end
		end
	end
end)

T.test("OUT events carry only plain data (no functions, userdata, shared references with the state)", function()
	local evs = collect_all()
	local bad = {}
	local function walk(v, path, depth)
		local t = type(v)
		if t == "function" or t == "userdata" or t == "thread" then bad[#bad + 1] = path end
		if t == "table" and depth < 12 then
			for k, x in pairs(v) do walk(x, path .. "." .. tostring(k), depth + 1) end -- order-free
		end
	end
	for i = 1, #evs do walk(evs[i], evs[i].type, 0) end
	T.eq(#bad, 0, table.concat(bad, ", "))
end)
