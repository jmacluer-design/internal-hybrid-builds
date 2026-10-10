-- client/raiders.lua : gang raiders (spawn_raiders / despawn_raiders). Armed hostile peds of one faction group that walk to the base and fight whatever
-- they hate (player, colonists, zombies). Each faction is a relationship group (client/relations.lua). Deaths are reported with the raid id; when the last
-- one dies the sim declares the raid repelled. Shares the ped cap / pool guard with the zombies through client/pool.lua.
local ctx = require("client.ctx")
local Pool = require("client.pool")
local Relations = require("client.relations")

local Rd = { groups = {}, order = {}, dead = {}, stats = { spawned = 0, killed = 0, failed = 0 } }
local cfg = ctx.cfg

local function weapon_list(faction)
	return ctx.config.raider_weapons[faction] or ctx.config.raider_weapons.rustjaw
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

local function configure(ped, g)
	SetPedRelationshipGroupHash(ped, Relations.group_for_faction(g.faction))
	SetPedAccuracy(ped, 35)
	SetPedCombatAttributes(ped, 46, true)
	SetPedCombatAttributes(ped, 5, true)
	SetPedCombatRange(ped, 2)
	SetPedCombatMovement(ped, 2)
	SetPedAlertness(ped, 3)
	SetPedFleeAttributes(ped, 0, false)
	SetPedDropsWeaponsWhenDead(ped, false) -- loot is handled by the sim (raiders carry loot in the ledger), not by dropped guns
	SetBlockingOfNonTemporaryEvents(ped, true)
	local weapons = weapon_list(g.faction)
	local name = weapons[math.random(1, #weapons)]
	local hash = GetHashKey(name)
	GiveWeaponToPed(ped, hash, 240, false, true)
	SetCurrentPedWeapon(ped, hash, true)
	local t = g.target
	TaskGoToCoordAnyMeans(ped, t.x, t.y, t.z, 2.0, 0, false, 786603, 0.0)
end

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
	for ped in pairs(g.peds) do Pool.delete_ped(ped); n = n + 1 end
	Rd.groups[id] = nil
	for i = #Rd.order, 1, -1 do if Rd.order[i] == id then table.remove(Rd.order, i) end end
	return n
end
ctx.on("despawn_raiders", function(ev) remove_group(ev.id) end)

function Rd.spawn_step()
	local now = GetGameTimer()
	local budget = cfg.spawn_per_tick
	for _, id in ipairs(Rd.order) do
		local g = Rd.groups[id]
		while g and budget > 0 and g.pending > 0 and now >= g.backoff_until do
			local a = math.random() * 6.2831853
			local r = 3.0 + math.random() * 8.0
			local x, y = g.center.x + math.cos(a) * r, g.center.y + math.sin(a) * r
			local z = Pool.ground_z(x, y, g.center.z)
			local models = ctx.config.client.faction_models[g.faction] or ctx.config.client.faction_models.rustjaw
			local ped, why = Pool.create_ped("raider", models, x, y, z, math.random() * 360.0, g.id)
			if ped then
				configure(ped, g)
				g.peds[ped] = { ped = ped, born = now }
				g.alive, g.pending = g.alive + 1, g.pending - 1
				Rd.stats.spawned = Rd.stats.spawned + 1
				budget = budget - 1
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

-- deaths + fight trigger + centroid report
function Rd.think()
	local now = GetGameTimer()
	local player = GetEntityCoords(PlayerPedId())
	for _, id in ipairs(Rd.order) do
		local g = Rd.groups[id]
		local sx, sy, n = 0.0, 0.0, 0
		for ped, r in pairs(g.peds) do
			if not DoesEntityExist(ped) then
				g.peds[ped] = nil; g.alive = g.alive - 1; Pool.delete_ped(ped)
			elseif IsPedDeadOrDying(ped, true) then
				Rd.stats.killed = Rd.stats.killed + 1
				ctx.send({ type = "ped_died", id = g.id, cause = (GetPedSourceOfDeath(ped) == PlayerPedId()) and "player" or "other" })
				g.peds[ped] = nil; g.alive = g.alive - 1
				Rd.dead[#Rd.dead + 1] = { ped = ped, at = now + math.random(8000, 20000) }
			else
				local p = GetEntityCoords(ped)
				sx, sy, n = sx + p.x, sy + p.y, n + 1
				local dt = math.sqrt((p.x - g.target.x) ^ 2 + (p.y - g.target.y) ^ 2)
				local dp = math.sqrt((p.x - player.x) ^ 2 + (p.y - player.y) ^ 2)
				if not r.fighting and (dt < 70.0 or dp < 45.0) then
					r.fighting = true
					TaskCombatHatedTargetsAroundPed(ped, 150.0, 0) -- engine AI picks the closest hated target (relationship groups)
				end
			end
		end
		if n > 0 and now - g.last_report >= 5000 then
			g.last_report = now
			local cx, cy = ctx.to_sim(sx / n, sy / n)
			ctx.send({ type = "raid_report", id = g.id, pos = { x = cx, y = cy, z = 0.0 } })
		end
	end
	for i = #Rd.dead, 1, -1 do
		if now >= Rd.dead[i].at then Pool.delete_ped(Rd.dead[i].ped); table.remove(Rd.dead, i) end
	end
end

-- any live raider within `radius` metres of pos (colonists use it to name the likely source of damage)
function Rd.near(pos, radius)
	for _, id in ipairs(Rd.order) do
		for ped in pairs(Rd.groups[id].peds) do
			if DoesEntityExist(ped) then
				local p = GetEntityCoords(ped)
				if math.sqrt((p.x - pos.x) ^ 2 + (p.y - pos.y) ^ 2) <= radius then return true end
			end
		end
	end
	return false
end
ctx.raiders_near = Rd.near

function Rd.alive_total()
	local n = 0
	for _, id in ipairs(Rd.order) do n = n + Rd.groups[id].alive end
	return n
end

function Rd.clear()
	local ids = {}
	for i, id in ipairs(Rd.order) do ids[i] = id end
	for _, id in ipairs(ids) do remove_group(id) end
	for i = #Rd.dead, 1, -1 do Pool.delete_ped(Rd.dead[i].ped); Rd.dead[i] = nil end
end

function Rd.start_threads()
	CreateThread(function()
		while ctx.running do
			Wait(300)
			Rd.spawn_step()
			Rd.think()
		end
	end)
end

ctx.on_reset("raiders", Rd.clear)
ctx.on_cleanup("raiders", Rd.clear)
return Rd
