-- A scripted sim run through the whole chain: sim -> host -> server modules (peds, objects, clock) -> network -> client modules -> the page (JavaScript pushes), and back
-- (orders from the page, noise, deaths). Asserts call sequences, budgets and invariants over days of in-game time. Mock only: see tests/mock_mta.lua for what that cannot prove.
local T, H = ...
T.group("integration")
local NET = require("shared.mta_net")
local P = require("shared.protocol")
local U = require("shared.util")

local function sctx(m) return H.sreq(m, "server.ctx") end
local function alive_kind(m, kind)
	local out = {}
	local Peds = H.sreq(m, "server.peds")
	for ped, rec in pairs(Peds.list) do if rec.kind == kind and not ped.destroyed and not ped.dead then out[#out + 1] = ped end end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

T.test("scripted run: three chaos days on autopilot with a player who shoots zombies: invariants hold at every step (budgets, one ped per colonist, item audit, no errors, no leaks)", function()
	local m = H.boot({ settings = { profile = "chaos", colonists = "5", seed = "31" } })
	local host = H.host(m)
	local w = host.world
	local TUN = H.sreq(m, "data.tuning")
	local Peds = H.sreq(m, "server.peds")
	local cfg = sctx(m).cfg
	local o = sctx(m).origin
	m:player_move_to(o.x + 6, o.y + 6)
	host:ui_action("set_speed", { speed = 16 })
	host:debug("autopilot", { on = true })
	local stats = { peak_hostile = 0, peak_all = 0, steps = 0, spawned_hordes = 0, raids = 0, shots = 0, audits = 0 }
	local seen_events = {}
	local last_day = 0
	local target_t = w.s.t + 3 * 1440
	local deaths_by_player = 0
	while w.s.t < target_t and not w.s.over do
		m:step(1000)
		stats.steps = stats.steps + 1
		-- the player keeps the horde pressure on: shoot the nearest zombie now and then
		if stats.steps % 3 == 0 then
			local z = alive_kind(m, "zombie")
			if z[1] then m:damage_ped(z[1], 500, m.player); stats.shots = stats.shots + 1 end
			m:player_fire(22)
		end
		local hostile = #alive_kind(m, "zombie") + #alive_kind(m, "raider")
		stats.peak_hostile = math.max(stats.peak_hostile, hostile)
		stats.peak_all = math.max(stats.peak_all, Peds.n)
		T.le(hostile, TUN.horde.max_materialized, "the sim's ped cap holds at step " .. stats.steps)
		T.le(Peds.n, cfg.max_peds)
		T.eq(m.pool_overflow, nil)
		if #m.errors > 0 then break end
		local day = math.floor(w.s.t / 1440)
		if day ~= last_day then
			last_day = day
			local ok, rep = w:audit()
			stats.audits = stats.audits + 1
			T.truthy(ok, "item conservation at the start of day " .. day .. ": " .. tostring(rep and table.concat(rep.problems or {}, ";")))
		end
	end
	T.eq(#m.errors, 0, H.errors_text(m))
	T.eq(#m.net.bad_payloads, 0, table.concat(m.net.bad_payloads, " | "))
	T.eq(#m.net.dropped, 0, table.concat(m.net.dropped, " | "))
	T.ge(w.s.t, target_t - 1, "the run reached day 4")
	-- one ped per colonist that is at home
	local at_home = 0
	for _, c in ipairs(w.s.colonists) do if c.state ~= "away" and not c.dead then at_home = at_home + 1 end end
	local colonist_peds = 0
	for ped, rec in pairs(Peds.list) do if rec.kind == "colonist" and not ped.dead then colonist_peds = colonist_peds + 1 end end
	T.le(colonist_peds, at_home)
	T.ge(colonist_peds, math.min(at_home, cfg.max_colonist_peds) - 1, "a ped for (nearly) every colonist at home: " .. colonist_peds .. " of " .. at_home)
	-- the director did things and the adapter showed them
	local counts = {}
	for _, e in ipairs(m:out_events()) do counts[e.type] = (counts[e.type] or 0) + 1 end
	T.gt(counts.spawn_horde or 0, 0, "hordes materialized")
	T.gt(counts.colonist_task or 0, 20, "colonists worked")
	T.gt(counts.director_log or 0, 0)
	T.gt(stats.shots, 0)
	T.gt(stats.peak_hostile, 10, "the run really had pressure: peak hostile peds " .. stats.peak_hostile)
	local kinds = {}
	for k in pairs(counts) do kinds[#kinds + 1] = k end
	table.sort(kinds)
	T.note("3 chaos days: %d mock steps, peak hostile peds %d (cap %d), peak all peds %d (hard cap %d), %d player shots, %d audits, event types: %s", stats.steps, stats.peak_hostile,
		TUN.horde.max_materialized, stats.peak_all, cfg.max_peds, stats.shots, stats.audits, table.concat(kinds, " "))
	-- the page saw the same events, in order and in batches, without a single JS error
	m:step(200)
	local ui_events = 0
	for _, msg in ipairs(m:ui_messages("events")) do ui_events = ui_events + #msg.data end
	T.eq(ui_events, #m:out_events(), "every OUT event reached the page")
	T.eq(#m.errors, 0)
	-- leak check on stop
	m:stop()
	T.eq(#m:live(), 0, "nothing the resource created is still alive after stop: " .. (function() local t = {} for _, e in ipairs(m:live()) do t[#t + 1] = e.type end return table.concat(t, ",") end)())
	T.eq(m:live_timers(), 0, "no timer is left")
	T.eq(m.open_files, 0)
end)

T.test("sequences: place_blueprint -> progress -> done -> destroyed produce object create -> alpha ramp -> collision on -> destroy, in that order (a wall, built by the colony then dismantled)", function()
	local m = H.boot({ settings = { profile = "calm" } })
	local host = H.host(m)
	local w = host.world
	local TUNING = H.sreq(m, "data.tuning")
	local B = H.sreq(m, "server.buildings")
	local log = {}
	-- record every object state change per building id by polling each frame
	local last = {}
	local function snapshot()
		for id, o in pairs(B.objs) do
			local obj = o.obj
			if obj and not obj.destroyed then
				local key = string.format("%s:%s:%s", obj.alpha, tostring(obj.collisions), o.state)
				if last[id] ~= key then last[id] = key; log[#log + 1] = { id = id, alpha = obj.alpha, collisions = obj.collisions, state = o.state } end
			end
		end
	end
	local pos = { x = TUNING.base.x + 14, y = TUNING.base.y + 10 }
	m:send_remote("server", NET.order, m.resourceRoot, m.player, nil, { id = "colony", kind = "place_blueprint", target = { bp = "wall", pos = { x = pos.x, y = pos.y, z = 0 } } })
	host:ui_action("set_speed", { speed = 16 })
	host:debug("autopilot", { on = true })
	for _ = 1, 600 do
		m:step(500); snapshot()
		local done = false
		for _, b in ipairs(w.s.buildings) do if b.bp == "wall" and b.state == "built" and math.abs(b.pos.x - pos.x) < 0.5 and math.abs(b.pos.y - pos.y) < 0.5 then done = true end end
		if done then break end
	end
	m:step(1000); snapshot()
	local mine
	for _, b in ipairs(w.s.buildings) do if b.bp == "wall" and math.abs(b.pos.x - pos.x) < 0.5 and math.abs(b.pos.y - pos.y) < 0.5 then mine = b end end
	T.truthy(mine and mine.state == "built", "the colony built the wall")
	local seq = {}
	for _, e in ipairs(log) do if e.id == mine.id then seq[#seq + 1] = e end end
	T.ge(#seq, 2, "at least the ghost and the solid state")
	T.eq(seq[1].collisions, false); T.lt(seq[1].alpha, 255)
	T.eq(seq[#seq].collisions, true); T.eq(seq[#seq].alpha, 255)
	for i = 2, #seq do T.ge(seq[i].alpha, seq[i - 1].alpha, "alpha never decreases") end
	-- the OUT event order the server saw: place_blueprint before any progress before construction_done
	local order = {}
	for _, e in ipairs(m:out_events()) do if e.id == mine.id then order[#order + 1] = e.type end end
	local pb, cd = nil, nil
	for i, t in ipairs(order) do if t == "place_blueprint" and not pb then pb = i end if t == "construction_done" then cd = i end end
	T.truthy(pb and cd and pb < cd, "place_blueprint then construction_done: " .. table.concat(order, ","))
	for i, t in ipairs(order) do if t == "construction_progress" then T.truthy(i > pb and i < cd) end end
	-- and the last step of the sequence: dismantling the building destroys its object (and frees its slot)
	local obj = B.objs[mine.id] and B.objs[mine.id].obj
	T.truthy(obj and not obj.destroyed, "the built wall has a live object")
	m:send_remote("server", NET.order, m.resourceRoot, m.player, nil, { id = "colony", kind = "cancel_blueprint", target = { id = mine.id } })
	m:step(3000)
	T.truthy(obj.destroyed, "cancelling the building destroyed its object")
	T.eq(B.objs[mine.id], nil, "and the module forgot it")
	T.eq(#m.errors, 0, H.errors_text(m))
	m:stop()
end)

T.test("round trip: a priority click in the page reaches the sim and the order_result comes back into the page; a banned order comes back as a failure toast payload", function()
	local m = H.boot({})
	local host = H.host(m)
	local before = #m:ui_messages("events")
	m:browser_trigger("order", { id = "c2", kind = "priority", target = { work = "haul", level = 2 } })
	m:step(300)
	T.eq(host.world:colonist("c2").prio.haul, 2)
	local found
	for i = before + 1, #m:ui_messages("events") do
		for _, e in ipairs(m:ui_messages("events")[i].data) do if e.type == "order_result" and e.kind == "priority" then found = e end end
	end
	T.truthy(found and found.ok and found.level == 2, "order_result {ok, level 2} was pushed into the page")
	m:browser_trigger("order", { id = "c2", kind = "launch_missiles" })
	m:step(300)
	local rejected
	for i = before + 1, #m:ui_messages("events") do
		for _, e in ipairs(m:ui_messages("events")[i].data) do if e.type == "order_result" and e.ok == false and e.reason:find("rejected:", 1, true) then rejected = e end end
	end
	T.truthy(rejected, "the server answered the junk order with ok = false, reason rejected:...")
	-- inventory moves round-trip too: a drop from the player's inventory
	host:debug("give", { item = "canned_beans", n = 3 })
	m:browser_trigger("ui", { name = "inventory", data = { other = nil } })
	m:step(300)
	local inv = m:ui_messages("inventory")
	T.gt(#inv, 0, "the inventory view model was pushed")
	T.eq(#m.errors, 0, H.errors_text(m))
	m:stop()
end)

T.test("round trip: a rifle shot at the player's position reaches the sim and an abstract horde in range turns toward it (and one out of range does not)", function()
	local m = H.boot({})
	local host = H.host(m)
	local w = host.world
	local o = sctx(m).origin
	local horde = require("sim.horde")
	local near = horde.spawn(w, { x = 800, y = 0, mix = { walker = 10 }, target = { x = 800, y = 0 }, src = "test" })
	local far = horde.spawn(w, { x = 1600, y = 0, mix = { walker = 10 }, target = { x = 1600, y = 0 }, src = "test" })
	near.tx, far.tx = nil, nil
	m:player_move_to(o.x + 400, o.y) -- 400 from the near horde: abstract (R_materialize is 220) but inside 150 * 3
	m:step(1500)
	T.eq(near.mat, nil, "abstract")
	m:player_fire(31)
	m:step(1500)
	T.truthy(near.tx, "the near horde took the noise as its target")
	T.near(near.tx, 400, 25, "heading for the shot (sim x 400)")
	T.eq(near.state, "seek")
	T.eq(far.tx, nil, "1200 units away: out of range")
	local last = w.s.noise[#w.s.noise]
	T.eq(last.kind, "rifle"); T.eq(last.loud, 150)
	T.eq(#m.errors, 0, H.errors_text(m))
	m:stop()
end)
