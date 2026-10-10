-- server/buildings.lua : blueprint sites and buildings as server-created objects. place_blueprint -> translucent object without collision, construction_progress -> alpha ramp,
-- construction_done -> solid object with collision, building_destroyed -> removed. Object models are SA model ids from shared/mta_config.lua (first one the game accepts wins, else a crate).
-- Creation is queued and spread over ticks. Unlike the FiveM adapter (client-side props) these are SERVER objects: they are synced to every client, have collision for everybody and
-- are destroyed by the server on stop / reset. The client only owns the placement ghost (client/placement.lua).
-- Written here (the FiveM adapter's client/build.lua structure on MTA functions). Nothing borrowed.
local ctx = require("server.ctx")
local Ground = require("server.ground")

local B = { objs = {}, queue = {}, live = {}, n = 0, stats = { ghosts = 0, built = 0, destroyed = 0, refused_cap = 0, model_fail = 0 } }
local cfg = ctx.cfg
local config = ctx.config
local ALPHA_MIN, ALPHA_MAX = 90, 255

local function models_for(bp) return config.props[bp] or config.props._fallback end
local function ramp(pct) return ALPHA_MIN + math.floor((ALPHA_MAX - ALPHA_MIN) * math.max(0, math.min(100, pct)) / 100) end

-- first model of the list that createObject accepts; returns the object or nil, reason. Piles (server/props.lua) create their crates through here so one ceiling covers every object.
function B.create_object(models, x, y, z)
	if B.n >= cfg.max_objects then B.stats.refused_cap = B.stats.refused_cap + 1; return nil, "cap" end
	for i = 1, #models do
		local obj = createObject(models[i], x, y, z)
		if obj then
			B.live[obj] = true
			B.n = B.n + 1
			Ground.track(obj, 0.0)
			return obj
		end
		B.stats.model_fail = B.stats.model_fail + 1
	end
	return nil, "model"
end

function B.destroy_object(obj)
	Ground.untrack(obj)
	if B.live[obj] then B.live[obj] = nil; B.n = B.n - 1 end
	if isElement(obj) then destroyElement(obj) end
end

local function make(item)
	local x, y = ctx.to_game(item.pos.x, item.pos.y, item.pos.z)
	local z = Ground.z_at(x, y)
	local obj, why = B.create_object(models_for(item.bp), x, y, z)
	if not obj and why == "model" then obj, why = B.create_object(config.props._fallback, x, y, z) end
	if not obj then return nil, why end
	setElementFrozen(obj, true)
	if item.state == "built" then
		setElementCollisionsEnabled(obj, true)
		setElementAlpha(obj, 255)
	else
		setElementCollisionsEnabled(obj, false)
		setElementAlpha(obj, ramp(item.pct or 0))
	end
	return obj
end

local function realize(id)
	local o = B.objs[id]
	if not o or o.obj then return end
	local obj = make(o)
	if obj then o.obj = obj else o.fail = (o.fail or 0) + 1 end
end

-- spread creation over ticks so a resync of 60 buildings does not hitch
function B.step()
	local n = 0
	while #B.queue > 0 and n < 3 do
		local id = table.remove(B.queue, 1)
		realize(id)
		local o = B.objs[id]
		if o and not o.obj and (o.fail or 0) < 3 then B.queue[#B.queue + 1] = id end -- retry a few times
		n = n + 1
	end
end

local function add(id, bp, pos, state, pct)
	local o = B.objs[id]
	if o then
		o.bp, o.pos, o.state, o.pct = bp, pos, state, pct or o.pct
	else
		o = { id = id, bp = bp, pos = pos, state = state, pct = pct or 0 }
		B.objs[id] = o
		B.queue[#B.queue + 1] = id
	end
	return o
end

local function remove(id)
	local o = B.objs[id]
	if not o then return end
	if o.obj then B.destroy_object(o.obj) end
	B.objs[id] = nil
	for i = #B.queue, 1, -1 do if B.queue[i] == id then table.remove(B.queue, i) end end
end

ctx.on("place_blueprint", function(ev) B.stats.ghosts = B.stats.ghosts + 1; add(ev.id, ev.bp, ev.pos, "planned", 0) end)

ctx.on("construction_progress", function(ev)
	local o = B.objs[ev.id]
	if not o then return end
	o.pct = ev.pct
	if o.obj and isElement(o.obj) then setElementAlpha(o.obj, ramp(ev.pct)) end
end)

ctx.on("construction_done", function(ev)
	B.stats.built = B.stats.built + 1
	local o = add(ev.id, ev.bp, ev.pos, "built", 100)
	if o.obj and isElement(o.obj) then
		setElementCollisionsEnabled(o.obj, true)
		setElementAlpha(o.obj, 255)
	end
end)

ctx.on("building_destroyed", function(ev) B.stats.destroyed = B.stats.destroyed + 1; remove(ev.id) end)

function B.count() return B.n end

function B.clear()
	local ids = {}
	for id in pairs(B.objs) do ids[#ids + 1] = id end
	for _, id in ipairs(ids) do remove(id) end
	B.objs, B.queue = {}, {}
end

function B.start() ctx.every("buildings.step", 150, B.step) end

ctx.on_reset("buildings", B.clear)
ctx.on_cleanup("buildings", B.clear)
return B
