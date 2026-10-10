-- client/pool.lua : the ONLY place that creates or deletes game entities for this resource. Everything it creates is tracked, capped and
-- released on resource stop, so nothing leaks. Streaming helpers (model / anim requests with a timeout) are borrowed from ox_lib.
--
-- borrowed: overextended/ox_lib/imports/streamingRequest/client.lua, requestModel/client.lua, requestAnimDict/client.lua (LGPL-3.0, Linden):
--   the "request, then poll HasXLoaded with a timeout" pattern and the invalid-model check; re-implemented without ox_lib's `lib` table.
local ctx = require("client.ctx")
local U = require("shared.util")

local Pool = {
	peds = {}, objects = {}, blips = {}, n_peds = 0, n_objects = 0,
	stats = { created_peds = 0, created_objects = 0, deleted = 0, refused_cap = 0, refused_pool = 0, model_fail = 0, ground_fail = 0 },
}
local cfg = ctx.cfg

-- ---------------------------------------------------------------------------------------------------------------- streaming
local function wait_loaded(has_loaded, asset, timeout)
	local deadline = GetGameTimer() + (timeout or cfg.model_timeout_ms)
	while not has_loaded(asset) do
		if GetGameTimer() > deadline then return false end
		Wait(0)
	end
	return true
end

-- returns the model hash, or nil + reason ("invalid" | "timeout")
function Pool.request_model(model, timeout)
	local hash = type(model) == "number" and model or GetHashKey(model)
	if HasModelLoaded(hash) then return hash end
	if not IsModelValid(hash) or not IsModelInCdimage(hash) then return nil, "invalid" end
	RequestModel(hash)
	if wait_loaded(HasModelLoaded, hash, timeout) then return hash end
	return nil, "timeout"
end

-- first model of the list that streams in (random start so a bad entry does not always win)
function Pool.pick_model(list, timeout)
	local n = #list
	if n == 0 then return nil end
	local start = math.random(1, n)
	for i = 0, n - 1 do
		local name = list[(start + i - 1) % n + 1]
		local hash = Pool.request_model(name, timeout)
		if hash then return hash, name end
		Pool.stats.model_fail = Pool.stats.model_fail + 1
	end
	return nil
end

function Pool.request_anim_dict(dict, timeout)
	if HasAnimDictLoaded(dict) then return true end
	if not DoesAnimDictExist(dict) then return false end
	RequestAnimDict(dict)
	return wait_loaded(HasAnimDictLoaded, dict, timeout)
end

function Pool.request_anim_set(set, timeout)
	if HasAnimSetLoaded(set) then return true end
	RequestAnimSet(set)
	return wait_loaded(HasAnimSetLoaded, set, timeout)
end

-- ---------------------------------------------------------------------------------------------------------------- ground height
-- returns z (a hint is used when the ground cannot be probed in time)
function Pool.ground_z(x, y, hint)
	hint = hint or ctx.origin.z
	RequestCollisionAtCoord(x, y, hint)
	local deadline = GetGameTimer() + cfg.ground_timeout_ms
	repeat
		for _, probe in ipairs({ hint + 40.0, hint + 150.0, 800.0 }) do
			local found, gz = GetGroundZFor_3dCoord(x, y, probe, false)
			if found then return gz end
		end
		Wait(0)
	until GetGameTimer() > deadline
	Pool.stats.ground_fail = Pool.stats.ground_fail + 1
	return hint
end

-- ---------------------------------------------------------------------------------------------------------------- peds
function Pool.ped_budget()
	return cfg.max_peds - Pool.n_peds
end

function Pool.can_create_ped()
	if Pool.n_peds >= cfg.max_peds then Pool.stats.refused_cap = Pool.stats.refused_cap + 1; return false, "cap" end
	local pool = GetGamePool("CPed")
	if #pool >= cfg.pool_guard then Pool.stats.refused_pool = Pool.stats.refused_pool + 1; return false, "pool" end
	return true
end

-- kind: "zombie" | "raider" | "colonist" | "trader"; tag: owner id (horde id, raid id, colonist id)
function Pool.create_ped(kind, models, x, y, z, heading, tag)
	if not ctx.running then return nil, "stopped" end
	local ok, why = Pool.can_create_ped()
	if not ok then return nil, why end
	local hash = Pool.pick_model(models)
	if not hash then return nil, "model" end
	if not ctx.running then return nil, "stopped" end -- the resource stopped while the model was streaming: never create anything after the cleanup ran
	local ped = CreatePed(4, hash, x, y, z, heading or 0.0, false, false) -- isNetwork = false: the owner's client owns the ped
	SetModelAsNoLongerNeeded(hash)
	if not ped or ped == 0 or not DoesEntityExist(ped) then return nil, "create" end
	SetEntityAsMissionEntity(ped, true, true) -- stop the engine's own cleanup from deleting it behind our back
	Pool.peds[ped] = { kind = kind, tag = tag, t = GetGameTimer() }
	Pool.n_peds = Pool.n_peds + 1
	Pool.stats.created_peds = Pool.stats.created_peds + 1
	return ped
end

function Pool.delete_ped(ped)
	if Pool.peds[ped] then Pool.peds[ped] = nil; Pool.n_peds = Pool.n_peds - 1; Pool.stats.deleted = Pool.stats.deleted + 1 end
	if DoesEntityExist(ped) then
		SetEntityAsMissionEntity(ped, true, true)
		DeleteEntity(ped)
	end
end

function Pool.owns_ped(ped) return Pool.peds[ped] ~= nil end

-- ---------------------------------------------------------------------------------------------------------------- objects
function Pool.create_object(models, x, y, z, ground)
	if Pool.n_objects >= cfg.max_objects then Pool.stats.refused_cap = Pool.stats.refused_cap + 1; return nil, "cap" end
	local hash = Pool.pick_model(models)
	if not hash then return nil, "model" end
	if not ctx.running then return nil, "stopped" end
	local obj = CreateObjectNoOffset(hash, x, y, z, false, false, false)
	SetModelAsNoLongerNeeded(hash)
	if not obj or obj == 0 or not DoesEntityExist(obj) then return nil, "create" end
	SetEntityAsMissionEntity(obj, true, true)
	if ground then PlaceObjectOnGroundProperly(obj) end
	Pool.objects[obj] = { t = GetGameTimer() }
	Pool.n_objects = Pool.n_objects + 1
	Pool.stats.created_objects = Pool.stats.created_objects + 1
	return obj
end

function Pool.delete_object(obj)
	if Pool.objects[obj] then Pool.objects[obj] = nil; Pool.n_objects = Pool.n_objects - 1; Pool.stats.deleted = Pool.stats.deleted + 1 end
	if DoesEntityExist(obj) then
		SetEntityAsMissionEntity(obj, true, true)
		DeleteEntity(obj)
	end
end

-- ---------------------------------------------------------------------------------------------------------------- blips
function Pool.add_blip(x, y, z, sprite, colour, label, scale)
	local b = AddBlipForCoord(x, y, z)
	SetBlipSprite(b, sprite)
	SetBlipColour(b, colour)
	SetBlipScale(b, scale or 0.9)
	SetBlipAsShortRange(b, true)
	BeginTextCommandSetBlipName("STRING")
	AddTextComponentSubstringPlayerName(label or "Outbreak")
	EndTextCommandSetBlipName(b)
	Pool.blips[b] = true
	return b
end

function Pool.remove_blip(b)
	if Pool.blips[b] then Pool.blips[b] = nil; RemoveBlip(b) end
end

-- ---------------------------------------------------------------------------------------------------------------- release everything
function Pool.release_all()
	local peds, objs, blips = {}, {}, {}
	for p in pairs(Pool.peds) do peds[#peds + 1] = p end -- snapshot: deleting mutates the table
	for o in pairs(Pool.objects) do objs[#objs + 1] = o end
	for b in pairs(Pool.blips) do blips[#blips + 1] = b end
	for i = 1, #peds do Pool.delete_ped(peds[i]) end
	for i = 1, #objs do Pool.delete_object(objs[i]) end
	for i = 1, #blips do Pool.remove_blip(blips[i]) end
	return #peds, #objs, #blips
end

function Pool.counts() return { peds = Pool.n_peds, objects = Pool.n_objects, stats = Pool.stats } end

ctx.on_cleanup("pool", Pool.release_all)
return Pool
