-- server/peds.lua : the ONLY place on the server that creates or destroys peds for this resource. Everything it creates is tracked, capped and destroyed on resource stop (MTA also
-- destroys a resource's elements when it stops, but a script that relies on that leaks while it runs). It also batches the "intents" the client-side ped driver executes.
--
-- WHY intents: MTA's SERVER has no setPedControlState / setPedAimTarget / getPedMoveState / isLineOfSightClear (tools/function_check.lua proves it against the mtasa-blue source:
-- they are client-only). A server can create a ped, name its animation and walking style, give it a weapon, move or kill it, but making it WALK, turn or shoot is done by the
-- client that syncs it (that is how the DayZ gamemodes' "slothbot" works: the server decides, the syncer client executes). So the server brain (server/zombies.lua, raiders.lua,
-- colonists.lua) decides what a ped should do and sends small intents { ped, m = mode, x, y, ... } to the owner's client (outbreak:drive), which runs client/driver.lua.
--
-- borrowed (see THIRD_PARTY.md): the cap / budget bookkeeping follows the FiveM adapter's client/pool.lua (own code); the idea "server decides, syncer client moves the ped" is read from
-- NullSystemWorks/mtadayz slothbot (custom licence: reference only, nothing copied).
local ctx = require("server.ctx")
local NET = require("shared.mta_net")
local Ground = require("server.ground")

local Peds = {
	list = {}, n = 0, dead = {}, valid = nil,
	sent = {}, queue = {},
	stats = { created = 0, destroyed = 0, refused_cap = 0, refused_pool = 0, model_fail = 0, create_fail = 0, intents_sent = 0, batches = 0 },
}
local cfg = ctx.cfg

-- ---------------------------------------------------------------------------------------------------------------- models
local function valid_set()
	if not Peds.valid then
		Peds.valid = {}
		local ok, list = pcall(getValidPedModels)
		if ok and type(list) == "table" then for _, id in ipairs(list) do Peds.valid[id] = true end end
		if next(Peds.valid) == nil then Peds.valid = false end -- the list is unavailable: trust the configured ids
	end
	return Peds.valid
end

-- first model of the list that the game accepts (random start so one bad id does not always win)
function Peds.pick_model(list)
	local n = #list
	if n == 0 then return nil end
	local set = valid_set()
	local start = math.random(1, n)
	for i = 0, n - 1 do
		local id = list[(start + i - 1) % n + 1]
		if not set or set[id] then return id end
		Peds.stats.model_fail = Peds.stats.model_fail + 1
	end
	return nil
end

-- ---------------------------------------------------------------------------------------------------------------- lifecycle
function Peds.can_create()
	if Peds.n >= cfg.max_peds then Peds.stats.refused_cap = Peds.stats.refused_cap + 1; return false, "cap" end
	if #getElementsByType("ped") >= cfg.pool_guard then Peds.stats.refused_pool = Peds.stats.refused_pool + 1; return false, "pool" end
	return true
end

-- kind: "zombie" | "raider" | "colonist" | "trader"; tag = owner id (horde id, raid id, colonist id, caravan id). x, y are GAME coordinates; z is chosen from the ground map.
function Peds.create(kind, models, x, y, rot, tag)
	if not ctx.running then return nil, "stopped" end
	local ok, why = Peds.can_create()
	if not ok then return nil, why end
	local model = Peds.pick_model(models)
	if not model then return nil, "model" end
	local gz = Ground.z_at(x, y)
	local ped = createPed(model, x, y, gz + 1.0, rot or 0.0, true)
	if not ped then Peds.stats.create_fail = Peds.stats.create_fail + 1; return nil, "create" end
	Peds.list[ped] = { kind = kind, tag = tag, t = getTickCount() }
	Peds.n = Peds.n + 1
	Peds.stats.created = Peds.stats.created + 1
	Ground.track(ped, 1.0)
	local owner = ctx.owner_el()
	if owner then setElementSyncer(ped, owner, true) end -- the owner's client drives every ped (UNVERIFIED: see README)
	return ped
end

function Peds.destroy(ped)
	if Peds.list[ped] then Peds.list[ped] = nil; Peds.n = Peds.n - 1; Peds.stats.destroyed = Peds.stats.destroyed + 1 end
	Ground.untrack(ped)
	Peds.sent[ped], Peds.dead[ped] = nil, nil
	if isElement(ped) then destroyElement(ped) end
end

function Peds.owns(ped) return Peds.list[ped] ~= nil end
function Peds.kind_of(ped) local r = Peds.list[ped]; return r and r.kind end
function Peds.counts() return { peds = Peds.n, stats = Peds.stats } end

-- a dead ped stays as a corpse for cfg.corpse_ms, then it is destroyed (RottenV: corpses linger 5-15 s)
function Peds.corpse(ped, ms) Peds.dead[ped] = getTickCount() + (ms or cfg.corpse_ms) end
function Peds.sweep()
	local now = getTickCount()
	for ped, due in pairs(Peds.dead) do
		if now >= due or not isElement(ped) then Peds.destroy(ped) end
	end
end

-- ---------------------------------------------------------------------------------------------------------------- intents for the client driver
-- intent fields: m = "stop" | "go" | "wander" | "attack" | "aim" | "flee"; x, y (game space); s = speed 0 stand .. 3 sprint; r = stop radius; tgt = target element (attack / aim);
-- ranged = true when the ped should shoot (raiders, armed colonists); anim = true keeps an animation running (the driver does not fight setPedAnimation)
local function same(a, b)
	if not a or a.m ~= b.m or a.s ~= b.s or a.tgt ~= b.tgt or a.ranged ~= b.ranged then return false end
	if a.x and b.x and (math.abs(a.x - b.x) > 1.5 or math.abs(a.y - b.y) > 1.5) then return false end
	return true
end

function Peds.drive(ped, intent, force)
	if not isElement(ped) then return false end
	local last = Peds.sent[ped]
	local now = getTickCount()
	if not force and last and same(last.i, intent) and now - last.t < 2000 then return false end
	intent.ped = ped
	Peds.sent[ped] = { i = intent, t = now }
	Peds.queue[#Peds.queue + 1] = intent
	return true
end

function Peds.flush_drive()
	local q = Peds.queue
	if #q == 0 then return 0 end
	Peds.queue = {}
	local owner = ctx.owner_el()
	if not owner then return 0 end
	local sent = 0
	local i = 1
	while i <= #q do
		local chunk = {}
		for k = i, math.min(i + 39, #q) do chunk[#chunk + 1] = q[k] end
		triggerClientEvent(owner, NET.drive, resourceRoot, chunk)
		Peds.stats.batches = Peds.stats.batches + 1
		sent = sent + #chunk
		i = i + 40
	end
	Peds.stats.intents_sent = Peds.stats.intents_sent + sent
	return sent
end

function Peds.clear()
	local all = {}
	for ped in pairs(Peds.list) do all[#all + 1] = ped end
	for ped in pairs(Peds.dead) do all[#all + 1] = ped end
	for i = 1, #all do Peds.destroy(all[i]) end
	Peds.queue, Peds.sent = {}, {}
end

ctx.on_cleanup("peds", Peds.clear)
return Peds
