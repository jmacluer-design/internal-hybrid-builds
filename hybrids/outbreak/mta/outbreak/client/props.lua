-- client/props.lua : loot piles for the E-key interaction. The crates are server objects (server/props.lua); the client only remembers where the live piles are (from piles_sync and
-- loot_spawn events) so that pressing E near one opens it in the inventory page. Written here (the FiveM adapter's client/props.lua interaction on MTA functions). Nothing borrowed.
local ctx = require("client.ctx")
local NET = require("shared.mta_net")

local Pr = { piles = {}, stats = { interactions = 0 } }

local function ref_kind(ref)
	if ref:sub(1, 5) == "pile:" then return "pile", ref:sub(6) end
	return "container", ref
end

ctx.on("loot_spawn", function(ev)
	local ref = ev.container
	if type(ref) ~= "string" or ev.pos == nil then return end
	if not (ref:sub(1, 5) == "pile:" or ev.source == "drop") then return end
	Pr.piles[ref] = { x = ev.pos.x, y = ev.pos.y }
end)

ctx.on("piles_sync", function(ev)
	local alive = {}
	for _, p in ipairs(ev.piles or {}) do alive["pile:" .. p.id] = { x = p.x, y = p.y } end
	for ref in pairs(Pr.piles) do if ref:sub(1, 5) == "pile:" and not alive[ref] then Pr.piles[ref] = nil end end
	for ref, pos in pairs(alive) do Pr.piles[ref] = pos end
end)

-- the nearest pile within `radius` metres of the player (game space), by sim position
function Pr.nearest(radius)
	local px, py = getElementPosition(localPlayer)
	local sx, sy = ctx.to_sim(px, py)
	local best, bd = nil, radius
	for ref, p in pairs(Pr.piles) do
		local d = math.sqrt((p.x - sx) ^ 2 + (p.y - sy) ^ 2)
		if d <= bd then best, bd = ref, d end
	end
	return best
end

-- E key: open the nearest pile / drop in the inventory screen
function Pr.interact()
	if not ctx.owner or ctx.colony_mode then return false end
	local ref = Pr.nearest(3.0)
	if not ref then return false end
	Pr.stats.interactions = Pr.stats.interactions + 1
	local kind, id = ref_kind(ref)
	triggerServerEvent(NET.ui_action, resourceRoot, "inventory", { other = { kind = kind, id = id } })
	if ctx.nui_send then ctx.nui_send("screen", { name = "inventory", arg = { other = { kind = kind, id = id } } }) end
	return true
end

function Pr.clear() Pr.piles = {} end

ctx.on_reset("props", Pr.clear)
ctx.on_cleanup("props", Pr.clear)
return Pr
