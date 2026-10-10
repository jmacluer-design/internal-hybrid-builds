-- factions.lua : four original gangs + a survivor camp. Relations (goodwill -100..100), raids,
-- trade caravans, and deals (trade, gift, truce).
--
-- s.factions = { { id, goodwill, base_goodwill, truce_until, raids, trades } ... }
-- s.raids    = { { id, faction, count, x, y, state = "approach"|"attack"|"retreat", rounds, loot, mat } ... }
-- s.caravans = { { id, faction, t0, leave_t, stock = <container> } ... }
-- Raids that nobody is near are resolved abstractly (siege.resolve); raids near an observer materialize
-- as real raiders (spawn_raiders) and the game decides the fight (ped_died events).
local U = require("sim.util")
local TUNING = require("data.tuning")
local FD = require("data.factions")
local items = require("sim.items")
local loot = require("sim.loot")
local horde = require("sim.horde")
local siege = require("sim.siege")
local stockpile = require("sim.stockpile")
local clock = require("sim.clock")

local M = {}
local FT = TUNING.factions
local H = TUNING.horde

function M.def(id) return FD.defs[id] end

function M.init(w)
	local list = {}
	for i = 1, #FD.order do
		local d = FD.defs[FD.order[i]]
		list[#list + 1] = { id = d.id, goodwill = d.goodwill, base_goodwill = d.goodwill, truce_until = 0, raids = 0, trades = 0 }
	end
	w.s.factions = list
	w.s.raids = {}
	w.s.caravans = {}
end

function M.get(w, id)
	local fs = w.s.factions
	for i = 1, #fs do if fs[i].id == id then return fs[i] end end
	return nil
end

function M.adjust(w, id, delta)
	local f = M.get(w, id)
	if not f then return nil end
	f.goodwill = U.clamp(f.goodwill + delta, -100, 100)
	return f.goodwill
end

function M.is_hostile(w, f)
	local d = FD.defs[f.id]
	return d.kind == "gang" and f.goodwill < 0
end

-- how likely a faction is to be the one that raids (0 = never)
function M.raid_weight(w, f)
	local d = FD.defs[f.id]
	if d.kind ~= "gang" or d.aggression <= 0 then return 0 end
	if w.s.t < f.truce_until then return 0 end
	local wgt = d.aggression * U.clamp((FT.raid_goodwill_ceiling - f.goodwill) / 40, 0, 2)
	return wgt
end

-- ---------------------------------------------------------------------------------------------
-- raids
-- ---------------------------------------------------------------------------------------------
function M.find_raid(w, id)
	local rs = w.s.raids
	for i = 1, #rs do if rs[i].id == id then return rs[i] end end
	return nil
end

-- plan a raid costing `points` of threat. Returns raid, or nil + reason
function M.plan_raid(w, points, faction_id)
	local s = w.s
	local rng = w:rng("fac")
	local f
	if faction_id then
		f = M.get(w, faction_id)
	else
		local cands = {}
		for i = 1, #s.factions do
			local wgt = M.raid_weight(w, s.factions[i])
			if wgt > 0 then cands[#cands + 1] = { f = s.factions[i], w = wgt } end
		end
		local pick = rng:weighted(cands, "w")
		f = pick and pick.f
	end
	if not f then return nil, "no_raiding_faction" end
	local d = FD.defs[f.id]
	local n = U.round(points * d.raid_power * FT.raiders_per_point)
	n = U.clamp(n, FT.raid_min, FT.raid_max)
	local dv = horde.DIRS[rng:int(1, #horde.DIRS)]
	local dist = rng:range(FT.raid_spawn_dist[1], FT.raid_spawn_dist[2])
	local b = TUNING.base
	local r = { id = w:new_id("r"), faction = f.id, count = n, x = b.x + dv[1] * dist, y = b.y + dv[2] * dist, state = "approach",
		rounds = 0, loot = items.new(), born = s.t, spent = points }
	s.raids[#s.raids + 1] = r
	f.raids = f.raids + 1
	local eta = math.ceil(dist / FT.raid_speed)
	w:emit({ type = "play_alert", kind = "raid_incoming", faction = f.id })
	w:notify("warn", string.format("%s raiders (%d) spotted heading for the base. ETA about %d minutes.", d.name, n, eta))
	return r
end

local function remove_raid(w, r)
	if r.mat then
		w:emit({ type = "despawn_raiders", id = r.id, faction = r.faction, count = r.mat.count, reason = "removed" })
		r.mat = nil
	end
	-- anything still carried leaves with them
	for _, it in ipairs(items.list(r.loot)) do w:destroy(r.loot, it.id, it.n, "stolen") end
	for i = 1, #w.s.raids do
		if w.s.raids[i] == r then table.remove(w.s.raids, i); return end
	end
end

-- raiders grab what they like most from the stockpile
local function steal(w, r)
	local d = FD.defs[r.faction]
	local budget = r.count * FT.steal_g_per_raider
	local zs = w.s.zones
	local function grab(pred)
		for zi = 1, #zs do
			local z = zs[zi]
			for _, id in ipairs(U.keys(z.items.items)) do
				if budget <= 0 then return end
				local def = items.defs[id]
				if pred(def) then
					local can = math.floor(budget / def.w)
					if can > 0 then
						local moved = items.transfer(z.items, r.loot, id, can)
						budget = budget - moved * def.w
					end
				end
			end
		end
	end
	for i = 1, #d.steals do
		local cat = d.steals[i]
		grab(function(def) return def.cat == cat end)
	end
	grab(function(def) return def.cat ~= "weapon" end)
	local n = items.total_count(r.loot)
	if n > 0 then
		w:notify("bad", string.format("%s raiders made off with %d items.", d.name, n))
		w:stat("items_stolen", n)
	end
end

local function raid_resolved(w, r, how)
	local f = M.get(w, r.faction)
	if how == "repelled" then
		w:on_attack_repelled("raid", r.count)
		w:notify("good", string.format("%s raiders were driven off.", FD.defs[r.faction].name))
	end
	remove_raid(w, r)
end

function M.on_ped_died(w, id)
	local r = M.find_raid(w, id)
	if not r then return false end
	r.count = r.count - 1
	if r.mat then r.mat.count = r.mat.count - 1 end
	M.adjust(w, r.faction, FT.kill_goodwill)
	w:stat("raiders_killed", 1)
	if r.count <= 0 then raid_resolved(w, r, "repelled") end
	return true
end

function M.report(w, id, pos)
	local r = M.find_raid(w, id)
	if not r then return false end
	r.x, r.y = pos.x, pos.y
	return true
end

local function step_raids(w, dt)
	local s = w.s
	local now = s.t
	local b = TUNING.base
	local obs = w:observers()
	local i = 1
	while i <= #s.raids do
		local r = s.raids[i]
		local gone = false
		-- materialization with the same hysteresis as hordes
		local d
		for k = 1, #obs do
			local dd = U.dist2(r.x, r.y, obs[k].x, obs[k].y)
			if not d or dd < d then d = dd end
		end
		if not r.mat then
			if d and d <= H.R_materialize and horde.cap_room(w) > 0 then
				local n = r.count
				local room = horde.cap_room(w)
				if n > room then n = room end
				if n > H.per_horde_max then n = H.per_horde_max end
				r.mat = { t0 = now, count = n }
				w:emit({ type = "spawn_raiders", id = r.id, faction = r.faction, name = FD.defs[r.faction].name, count = n,
					pos = { x = r.x, y = r.y, z = b.z }, target = { x = b.x, y = b.y, z = b.z } })
			end
		elseif (not d or d > H.R_dematerialize) and now - r.mat.t0 >= H.min_dwell then
			w:emit({ type = "despawn_raiders", id = r.id, faction = r.faction, count = r.mat.count, reason = "far" })
			r.mat = nil
		end
		if not r.mat then
			local dbase = U.dist2(r.x, r.y, b.x, b.y)
			if r.state == "approach" then
				local dx, dy = b.x - r.x, b.y - r.y
				local dl = math.sqrt(dx * dx + dy * dy)
				local stp = FT.raid_speed * dt
				if dl <= H.assault_radius or stp >= dl then
					r.x, r.y = b.x + (dx == 0 and 0 or -dx / dl * H.assault_radius * 0.9), b.y + (dy == 0 and 0 or -dy / dl * H.assault_radius * 0.9)
					r.state = "attack"
					r.last_round = now - H.assault_round_min
				else
					r.x, r.y = r.x + dx / dl * stp, r.y + dy / dl * stp
				end
			elseif r.state == "attack" then
				if now - r.last_round >= H.assault_round_min then
					r.last_round = now
					r.rounds = r.rounds + 1
					local res = siege.resolve(w, { raider = r.count }, { rounds = H.assault_rounds, source = "raid" })
					local left = res.attackers_left.raider or 0
					local killed = r.count - left
					if killed > 0 then M.adjust(w, r.faction, FT.kill_goodwill * killed) end
					r.count = left
					if r.count <= 0 then
						raid_resolved(w, r, "repelled")
						gone = true
					elseif res.outcome == "overrun" or r.rounds >= FT.rounds_before_retreat then
						if res.outcome == "overrun" then steal(w, r) end
						r.state = "retreat"
					end
				end
			elseif r.state == "retreat" then
				local dx, dy = r.x - b.x, r.y - b.y
				local dl = math.sqrt(dx * dx + dy * dy)
				if dl < 1 then dx, dy, dl = 1, 0, 1 end
				local stp = FT.retreat_speed * dt
				r.x, r.y = r.x + dx / dl * stp, r.y + dy / dl * stp
				if dl > FT.raid_spawn_dist[2] then
					remove_raid(w, r)
					gone = true
				end
			end
		end
		if not gone then i = i + 1 end
	end
end

-- ---------------------------------------------------------------------------------------------
-- caravans + trade
-- ---------------------------------------------------------------------------------------------
function M.find_caravan(w, id)
	local cs = w.s.caravans
	for i = 1, #cs do if cs[i].id == id then return cs[i] end end
	return nil
end

function M.spawn_caravan(w, faction_id)
	local s = w.s
	local f = M.get(w, faction_id)
	if not f then return nil, "unknown_faction" end
	if f.goodwill < FT.caravan_min_goodwill then return nil, "hostile" end
	local d = FD.defs[faction_id]
	for i = 1, #s.caravans do if s.caravans[i].faction == faction_id then return nil, "already_here" end end
	local c = { id = w:new_id("k"), faction = faction_id, t0 = s.t, leave_t = s.t + FT.caravan_stay, stock = items.new() }
	local day = clock.day(s.t)
	local bundle = loot.roll(w:rng("fac"), d.stock, { danger = 1, mult = 1 + day * FT.caravan_day_growth })
	for _, id in ipairs(U.keys(bundle)) do w:create(c.stock, id, bundle[id], "caravan") end
	s.caravans[#s.caravans + 1] = c
	w:emit({ type = "caravan", phase = "arrive", id = c.id, faction = faction_id, name = d.name, leave_t = c.leave_t,
		stock = bundle, pos = { x = TUNING.base.x + 25, y = TUNING.base.y + 25, z = TUNING.base.z } })
	w:emit({ type = "play_alert", kind = "caravan", faction = faction_id })
	w:notify("info", string.format("A %s caravan has arrived to trade (stays about %d hours).", d.name, FT.caravan_stay / 60))
	return c
end

local function remove_caravan(w, c)
	for _, it in ipairs(items.list(c.stock)) do w:destroy(c.stock, it.id, it.n, "caravan_leave") end
	for i = 1, #w.s.caravans do
		if w.s.caravans[i] == c then table.remove(w.s.caravans, i); break end
	end
	w:emit({ type = "caravan", phase = "leave", id = c.id, faction = c.faction })
end

-- price in points of n of item. we_sell = the colony sells it to the faction
function M.price(w, faction_id, item_id, n, we_sell)
	local f = M.get(w, faction_id)
	local d = FD.defs[faction_id]
	local def = items.def(item_id)
	local base = def.value * n
	local gw = 1 + (we_sell and 1 or -1) * f.goodwill / FT.price_goodwill
	if we_sell then
		local p = base / d.markup * gw
		if d.wants[def.cat] then p = p * FT.want_premium end
		return p
	end
	return base * d.markup * gw
end

local function map_value(w, faction_id, map, we_sell)
	local v = 0
	for _, id in ipairs(U.keys(map)) do v = v + M.price(w, faction_id, id, map[id], we_sell) end
	return v
end

-- quote for a proposed trade: returns give_value, take_value
function M.quote(w, cid, give, take)
	local c = M.find_caravan(w, cid)
	if not c then return nil end
	return map_value(w, c.faction, give, true), map_value(w, c.faction, take, false)
end

-- execute a trade with a caravan. give = items from our zones, take = items from the caravan.
-- Returns ok, reason.
function M.trade(w, cid, give, take)
	local s = w.s
	local c = M.find_caravan(w, cid)
	if not c then return false, "no_such_caravan" end
	for _, id in ipairs(U.keys(give)) do
		if not items.exists(id) or give[id] <= 0 or give[id] ~= math.floor(give[id]) then return false, "bad_item" end
		if stockpile.total(s.zones, id) < give[id] then return false, "not_enough:" .. id end
	end
	for _, id in ipairs(U.keys(take)) do
		if not items.exists(id) or take[id] <= 0 or take[id] ~= math.floor(take[id]) then return false, "bad_item" end
		if (c.stock.items[id] or 0) < take[id] then return false, "caravan_lacks:" .. id end
	end
	local gv, tv = M.quote(w, cid, give, take)
	if gv + 1e-9 < tv then return false, "offer_too_low" end
	-- move our goods to the caravan
	for _, id in ipairs(U.keys(give)) do
		local left = give[id]
		for zi = 1, #s.zones do
			if left <= 0 then break end
			left = left - items.transfer(s.zones[zi].items, c.stock, id, left)
		end
	end
	-- their goods onto the ground at the garage for hauling
	local pile = w:pile_for(w:garage_pos())
	local got = {}
	for _, id in ipairs(U.keys(take)) do
		local moved = items.transfer(c.stock, pile.items, id, take[id])
		if moved > 0 then got[id] = moved end
	end
	local f = M.get(w, c.faction)
	f.trades = f.trades + 1
	M.adjust(w, c.faction, U.min(FT.trade_goodwill_cap, tv * FT.trade_goodwill_gain))
	w:stat("trades", 1)
	w:emit({ type = "loot_spawn", container = "pile:" .. pile.id, items = got, source = "trade", faction = c.faction, pos = U.pos_copy(pile.pos) })
	w:add_thought_all("caravan_trade")
	return true, "ok", gv, tv
end

-- give items away (destroyed) for goodwill
function M.gift(w, faction_id, give)
	local f = M.get(w, faction_id)
	if not f then return false, "unknown_faction" end
	local s = w.s
	for _, id in ipairs(U.keys(give)) do
		if not items.exists(id) or give[id] <= 0 then return false, "bad_item" end
		if stockpile.total(s.zones, id) < give[id] then return false, "not_enough:" .. id end
	end
	local value = 0
	for _, id in ipairs(U.keys(give)) do
		local left = give[id]
		for zi = 1, #s.zones do
			if left <= 0 then break end
			left = left - w:destroy(s.zones[zi].items, id, left, "gift")
		end
		value = value + items.def(id).value * give[id]
	end
	M.adjust(w, faction_id, U.min(FT.gift_goodwill_cap, value * FT.gift_goodwill_per_value))
	return true, "ok", value
end

-- pay a hostile gang for a ceasefire
function M.truce(w, faction_id, give)
	local f = M.get(w, faction_id)
	if not f then return false, "unknown_faction" end
	local d = FD.defs[faction_id]
	if d.kind ~= "gang" then return false, "not_a_gang" end
	local value = 0
	for _, id in ipairs(U.keys(give)) do value = value + items.def(id).value * give[id] end
	local need = FT.truce_min_value + U.max(0, -f.goodwill) * FT.truce_per_hostility
	if value < need then return false, "offer_too_low" end
	local ok, why = M.gift(w, faction_id, give)
	if not ok then return false, why end
	f.truce_until = w.s.t + FT.truce_days * 1440
	w:notify("info", string.format("%s agreed to a ceasefire for %d days.", d.name, FT.truce_days))
	return true, "ok"
end

-- ---------------------------------------------------------------------------------------------
function M.step(w, dt)
	local s = w.s
	step_raids(w, dt)
	local i = 1
	while i <= #s.caravans do
		local c = s.caravans[i]
		if s.t >= c.leave_t then remove_caravan(w, c) else i = i + 1 end
	end
	if s.t % 1440 < dt then -- daily drift back toward each faction's starting attitude
		for k = 1, #s.factions do
			local f = s.factions[k]
			f.goodwill = f.goodwill + (f.base_goodwill - f.goodwill) * FT.goodwill_drift
		end
	end
end

return M
