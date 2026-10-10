-- server/props.lua : loot piles / dropped items as crates on the ground (loot_spawn pile:<id> and drop:<n>, piles_sync) and trade caravans (traders standing at a spot until they leave).
-- Piles live in the sim; a crate object is only a marker, so crates whose pile the sim no longer lists are destroyed. The E-key interaction that opens a pile in the inventory UI is on
-- the client (client/props.lua). Written here (the FiveM adapter's client/props.lua structure on MTA functions). Nothing borrowed.
local ctx = require("server.ctx")
local Peds = require("server.peds")
local Buildings = require("server.buildings")
local Ground = require("server.ground")

local Pr = { props = {}, traders = {}, stats = { piles = 0, drops = 0 } }
local cfg = ctx.cfg
local config = ctx.config

function Pr.ensure(ref, pos, source)
	if Pr.props[ref] then return false end
	local x, y = ctx.to_game(pos.x, pos.y, pos.z or 0.0)
	local obj = Buildings.create_object(config.props._pile, x, y, Ground.z_at(x, y))
	if not obj then return false end -- the next piles_sync retries
	setElementFrozen(obj, true)
	setElementCollisionsEnabled(obj, false) -- a marker: colonists and zombies walk through it
	Pr.props[ref] = { obj = obj, x = x, y = y }
	if source == "drop" then Pr.stats.drops = Pr.stats.drops + 1 else Pr.stats.piles = Pr.stats.piles + 1 end
	return true
end

ctx.on("loot_spawn", function(ev)
	local ref = ev.container
	if type(ref) ~= "string" or ev.pos == nil then return end
	if not (ref:sub(1, 5) == "pile:" or ev.source == "drop") then return end -- world containers are the game's own props, not ours
	Pr.ensure(ref, ev.pos, ev.source)
end)

local function drop_missing(alive)
	local gone = {}
	for ref in pairs(Pr.props) do
		if ref:sub(1, 5) == "pile:" and not alive[ref] then gone[#gone + 1] = ref end
	end
	for _, ref in ipairs(gone) do
		local p = Pr.props[ref]
		Pr.props[ref] = nil
		Buildings.destroy_object(p.obj)
	end
end

-- the host lists every live ground pile whenever the set changes (the sim emits no event when a pile is emptied or created by a death / a cancelled blueprint)
ctx.on("piles_sync", function(ev)
	local alive = {}
	for _, p in ipairs(ev.piles or {}) do alive["pile:" .. p.id] = true end
	drop_missing(alive)
	for _, p in ipairs(ev.piles or {}) do Pr.ensure("pile:" .. p.id, { x = p.x, y = p.y, z = 0.0 }, "pile") end
end)

-- ---------------------------------------------------------------------------------------------------------------- traders
ctx.on("caravan", function(ev)
	if ev.phase == "arrive" then
		if Pr.traders[ev.id] or not ev.pos then return end
		local list = {}
		Pr.traders[ev.id] = list
		local x, y = ctx.to_game(ev.pos.x, ev.pos.y, ev.pos.z)
		local models = cfg.faction_models[ev.faction] or cfg.trader_models
		for i = 1, 2 do
			local ped = Peds.create("trader", models, x + i * 1.5, y, 0.0, ev.id)
			if ped then
				local a = config.anims.idle
				if a then setPedAnimation(ped, a[1], a[2], -1, a[3], false, false, false) end
				list[#list + 1] = ped
			end
		end
	elseif ev.phase == "leave" then
		for _, ped in ipairs(Pr.traders[ev.id] or {}) do Peds.destroy(ped) end
		Pr.traders[ev.id] = nil
	end
end)

function Pr.clear()
	for ref, p in pairs(Pr.props) do Buildings.destroy_object(p.obj); Pr.props[ref] = nil end
	for id, list in pairs(Pr.traders) do
		for _, ped in ipairs(list) do Peds.destroy(ped) end
		Pr.traders[id] = nil
	end
end

ctx.on_reset("props", Pr.clear)
ctx.on_cleanup("props", Pr.clear)
return Pr
