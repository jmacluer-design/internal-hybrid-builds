-- client/props.lua : loot piles / dropped items as crates on the ground (loot_spawn pile:<id> and drop:<n>), the E-key interaction that opens them in the
-- inventory UI, and trade caravans (traders standing at a spot until they leave). Piles live in the sim; a prop is only a marker, so props that the colony UI
-- state no longer lists are removed. MOCK-ONLY assumptions: prop models and the scenario names are unverified public names.
local ctx = require("client.ctx")
local Pool = require("client.pool")
local P = require("shared.protocol")

local Pr = { props = {}, traders = {}, stats = { piles = 0, drops = 0, interactions = 0 } }
local cfg = ctx.cfg

local function ref_kind(ref)
	if ref:sub(1, 5) == "pile:" then return "pile", ref:sub(6) end
	return "container", ref
end

ctx.on("loot_spawn", function(ev)
	local ref = ev.container
	if type(ref) ~= "string" or ev.pos == nil then return end
	if not (ref:sub(1, 5) == "pile:" or ev.source == "drop") then return end -- world containers are the game's own props, not ours
	local old = Pr.props[ref]
	if old then return end
	local x, y, z = ctx.to_game(ev.pos.x, ev.pos.y, ev.pos.z)
	z = Pool.ground_z(x, y, z)
	local obj = Pool.create_object(ctx.config.props._pile, x, y, z, true)
	if not obj then return end
	FreezeEntityPosition(obj, true)
	Pr.props[ref] = { obj = obj, x = x, y = y, z = z, born = GetGameTimer() }
	if ev.source == "drop" then Pr.stats.drops = Pr.stats.drops + 1 else Pr.stats.piles = Pr.stats.piles + 1 end
end)

-- the colony UI state lists the live piles: drop props whose pile is gone (hauled away / emptied)
function Pr.sync_piles(piles)
	local alive = {}
	for _, p in ipairs(piles or {}) do alive["pile:" .. p.id] = true end
	local gone = {}
	for ref in pairs(Pr.props) do
		if ref:sub(1, 5) == "pile:" and not alive[ref] then gone[#gone + 1] = ref end
	end
	for _, ref in ipairs(gone) do
		Pool.delete_object(Pr.props[ref].obj)
		Pr.props[ref] = nil
	end
end

function Pr.nearest(x, y, z, radius)
	local best, bd = nil, radius
	for ref, p in pairs(Pr.props) do
		local d = math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2 + (p.z - z) ^ 2)
		if d <= bd then best, bd = ref, d end
	end
	return best
end

-- E key: open the nearest pile / drop in the inventory screen
function Pr.interact()
	local p = GetEntityCoords(PlayerPedId())
	local ref = Pr.nearest(p.x, p.y, p.z, 3.0)
	if not ref then return false end
	Pr.stats.interactions = Pr.stats.interactions + 1
	local kind, id = ref_kind(ref)
	TriggerServerEvent(P.NET.ui_action, "inventory", { other = { kind = kind, id = id } })
	if ctx.nui_send then ctx.nui_send("screen", { name = "inventory", arg = { other = { kind = kind, id = id } } }) end
	return true
end

-- ---------------------------------------------------------------------------------------------------------------- traders
ctx.on("caravan", function(ev)
	if ev.phase == "arrive" then
		if Pr.traders[ev.id] or not ev.pos then return end
		local x, y, z = ctx.to_game(ev.pos.x, ev.pos.y, ev.pos.z)
		local list = {}
		for i = 1, 2 do
			local gz = Pool.ground_z(x + i * 1.5, y, z)
			local ped = Pool.create_ped("trader", ctx.config.client.faction_models[ev.faction] or ctx.config.client.colonist_models, x + i * 1.5, y, gz, 0.0, ev.id)
			if ped then
				SetPedRelationshipGroupHash(ped, ctx.rel.OB_TRADER)
				SetBlockingOfNonTemporaryEvents(ped, true)
				SetPedFleeAttributes(ped, 0, false)
				TaskStartScenarioInPlace(ped, ctx.config.scenarios.idle, 0, true)
				list[#list + 1] = ped
			end
		end
		Pr.traders[ev.id] = list
	elseif ev.phase == "leave" then
		for _, ped in ipairs(Pr.traders[ev.id] or {}) do Pool.delete_ped(ped) end
		Pr.traders[ev.id] = nil
	end
end)

function Pr.clear()
	for ref, p in pairs(Pr.props) do Pool.delete_object(p.obj); Pr.props[ref] = nil end
	for id, list in pairs(Pr.traders) do
		for _, ped in ipairs(list) do Pool.delete_ped(ped) end
		Pr.traders[id] = nil
	end
end

ctx.on_reset("props", Pr.clear)
ctx.on_cleanup("props", Pr.clear)
return Pr
