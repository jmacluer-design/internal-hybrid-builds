-- server/raiders.lua : gang raiders (spawn_raiders / despawn_raiders). Armed hostile peds of one faction that walk to the base and fight the player and the colonists. MTA has no
-- relationship groups (the FiveM adapter used them), so hostility is custom logic: a raider hunts the nearest of {player, colonists} and ignores zombies. Deaths are reported with
-- the raid id; when the last one dies the sim declares the raid repelled. Shares the ped cap and pool guard with the zombies through server/peds.lua. Locomotion, aiming and
-- shooting are executed by the owner's client from the intents sent here (client/driver.lua); bullets hit natively and the server sees the health change.
-- Written here (the FiveM adapter's client/raiders.lua structure, not its natives). Nothing borrowed.
local ctx = require("server.ctx")
local Peds = require("server.peds")
local Net = require("server.inject")

local Rd = { groups = {}, order = {}, stats = { spawned = 0, killed = 0, failed = 0 } }
local cfg = ctx.cfg
local config = ctx.config

local function weapon_list(faction)
	return config.raider_weapons[faction] or config.raider_weapons.rustjaw
end

local function group_of(id)
	local g = Rd.groups[id]
	if not g then
		g = { id = id, pending = 0, peds = {}, alive = 0, backoff_until = 0, last_report = 0 }
		Rd.groups[id] = g
		Rd.order[#Rd.order + 1] = id
	end
	return g
end

-- weapons that shoot (everything except the melee ids 1-15)
local function is_ranged(weapon) return weapon >= 16 end

ctx.on("spawn_raiders", function(ev)
	local g = group_of(ev.id)
	g.faction, g.name = ev.faction, ev.name
	local x, y, z = ctx.to_game(ev.pos.x, ev.pos.y, ev.pos.z)
	local tx, ty, tz = ctx.to_game(ev.target.x, ev.target.y, ev.target.z)
	g.center, g.target = { x = x, y = y, z = z }, { x = tx, y = ty, z = tz }
	g.pending = g.pending + ev.count
end)

local function remove_group(id)
	local g = Rd.groups[id]
	if not g then return 0 end
	local n = 0
	for ped in pairs(g.peds) do Peds.destroy(ped); n = n + 1 end
	Rd.groups[id] = nil
	for i = #Rd.order, 1, -1 do if Rd.order[i] == id then table.remove(Rd.order, i) end end
	return n
end
ctx.on("despawn_raiders", function(ev) remove_group(ev.id) end)

function Rd.spawn_step()
	local now = getTickCount()
	local budget = cfg.spawn_per_tick
	for _, id in ipairs(Rd.order) do
		local g = Rd.groups[id]
		while g and budget > 0 and g.pending > 0 and now >= g.backoff_until do
			local a = math.random() * 6.2831853
			local r = 3.0 + math.random() * 8.0
			local x, y = g.center.x + math.cos(a) * r, g.center.y + math.sin(a) * r
			local models = cfg.faction_models[g.faction] or cfg.faction_models.rustjaw
			local ped, why = Peds.create("raider", models, x, y, math.random() * 360.0, g.id)
			if ped then
				local weapons = weapon_list(g.faction)
				local w = weapons[math.random(1, #weapons)]
				giveWeapon(ped, w, config.weapon_ammo.raider, true)
				g.peds[ped] = { ped = ped, born = now, weapon = w, ranged = is_ranged(w) }
				g.alive, g.pending = g.alive + 1, g.pending - 1
				Rd.stats.spawned = Rd.stats.spawned + 1
				budget = budget - 1
				Peds.drive(ped, { m = "go", x = g.target.x, y = g.target.y, s = 2, r = 4.0 }) -- walk to the base
			elseif why == "cap" or why == "pool" then
				g.backoff_until = now + 1500
				budget = 0
			else
				g.pending = g.pending - 1
				Rd.stats.failed = Rd.stats.failed + 1
				budget = budget - 1
			end
		end
	end
end

local function death(g, r, killer)
	if not g.peds[r.ped] then return end
	Rd.stats.killed = Rd.stats.killed + 1
	Net.event({ type = "ped_died", id = g.id, cause = (killer ~= nil and killer == ctx.owner) and "player" or "other" })
	g.peds[r.ped] = nil
	g.alive = g.alive - 1
	Peds.corpse(r.ped)
end

function Rd.on_wasted(ped, killer)
	local rec = Peds.list[ped]
	if not rec or rec.kind ~= "raider" then return false end
	local g = Rd.groups[rec.tag]
	local r = g and g.peds[ped]
	if r then death(g, r, killer) end
	return true
end

-- colonist targets are registered by server/colonists.lua: function() -> list of { ped, id }
Rd.colonist_targets = function() return {} end

local function dist2(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

-- the nearest hostile of a raider within 80 m: the player (unless in colony view) or a colonist
local function pick_target(px, py, pinfo)
	local best, bd
	if pinfo.alive then
		local d = dist2(px, py, pinfo.x, pinfo.y)
		if d < 80.0 then best, bd = ctx.owner_el(), d end
	end
	local list = Rd.colonist_targets()
	for i = 1, #list do
		local t = list[i]
		if isElement(t.ped) and not isPedDead(t.ped) then
			local tx, ty = getElementPosition(t.ped)
			local d = dist2(px, py, tx, ty)
			if d < 80.0 and (not bd or d < bd) then best, bd = t.ped, d end
		end
	end
	return best
end

-- decisions + deaths + centroid report (every brain step)
function Rd.think(pinfo)
	local now = getTickCount()
	for _, id in ipairs(Rd.order) do
		local g = Rd.groups[id]
		local sx, sy, n = 0.0, 0.0, 0
		for ped, r in pairs(g.peds) do
			if not isElement(ped) then
				g.peds[ped] = nil; g.alive = g.alive - 1; Peds.destroy(ped)
			elseif isPedDead(ped) then
				death(g, r, nil)
			else
				local px, py = getElementPosition(ped)
				sx, sy, n = sx + px, sy + py, n + 1
				local dt = dist2(px, py, g.target.x, g.target.y)
				local dp = pinfo.alive and dist2(px, py, pinfo.x, pinfo.y) or 1e9
				if r.fighting or dt < 70.0 or dp < 45.0 then
					r.fighting = true
					local tgt = pick_target(px, py, pinfo)
					if tgt then
						local tx, ty = getElementPosition(tgt)
						Peds.drive(ped, { m = "attack", x = tx, y = ty, tgt = tgt, ranged = r.ranged, s = 2, r = r.ranged and 12.0 or 1.5 })
					else
						Peds.drive(ped, { m = "go", x = g.target.x, y = g.target.y, s = 2, r = 4.0 })
					end
				end
			end
		end
		if n > 0 and now - g.last_report >= 5000 then
			g.last_report = now
			local cx, cy = ctx.to_sim(sx / n, sy / n)
			Net.event({ type = "raid_report", id = g.id, pos = { x = cx, y = cy, z = 0.0 } })
		end
	end
end

-- any live raider within `radius` metres of (x, y) (colonists use it to name the likely source of damage)
function Rd.near(x, y, radius)
	for _, id in ipairs(Rd.order) do
		for ped in pairs(Rd.groups[id].peds) do
			if isElement(ped) then
				local px, py = getElementPosition(ped)
				if dist2(px, py, x, y) <= radius then return true end
			end
		end
	end
	return false
end

function Rd.alive_total()
	local n = 0
	for _, id in ipairs(Rd.order) do n = n + Rd.groups[id].alive end
	return n
end

function Rd.clear()
	local ids = {}
	for i, id in ipairs(Rd.order) do ids[i] = id end
	for _, id in ipairs(ids) do remove_group(id) end
end

function Rd.start() ctx.every("raiders.spawn", cfg.spawn_ms, Rd.spawn_step) end

ctx.on_reset("raiders", Rd.clear)
ctx.on_cleanup("raiders", Rd.clear)
return Rd
