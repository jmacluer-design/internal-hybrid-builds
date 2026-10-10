-- client/build.lua : blueprint ghosts and buildings as props. place_blueprint -> translucent ghost, construction_progress -> alpha ramp,
-- construction_done -> solid prop with collision, building_destroyed -> removed. Placement mode: a ghost follows the cursor (camera ray), snaps to the grid, is
-- tinted green / red by shared/placement.lua, and a click sends a `place_blueprint` order. Lamps light up (DrawLightWithRange) when the grid is powered.
-- Object models are best-effort public names (config.props); the first one the game accepts wins, else a crate. Creation is queued and spread over ticks.
local ctx = require("client.ctx")
local Pool = require("client.pool")
local Placement = require("shared.placement")
local P = require("shared.protocol")

local B = { objs = {}, queue = {}, lamps = {}, stats = { ghosts = 0, built = 0, destroyed = 0, placed_orders = 0 } }
local cfg = ctx.cfg
local ALPHA_MIN, ALPHA_MAX = 90, 255

local function models_for(bp) return ctx.config.props[bp] or ctx.config.props._fallback end

local function ramp(pct) return ALPHA_MIN + math.floor((ALPHA_MAX - ALPHA_MIN) * math.max(0, math.min(100, pct)) / 100) end

local function make(item)
	local x, y, z = ctx.to_game(item.pos.x, item.pos.y, item.pos.z)
	z = Pool.ground_z(x, y, z)
	local obj, why = Pool.create_object(models_for(item.bp), x, y, z, true)
	if not obj then
		if why == "model" then obj = Pool.create_object(ctx.config.props._fallback, x, y, z, true) end
		if not obj then return nil, why end
	end
	FreezeEntityPosition(obj, true)
	if item.state == "built" then
		SetEntityCollision(obj, true, true)
		ResetEntityAlpha(obj)
	else
		SetEntityCollision(obj, false, false)
		SetEntityAlpha(obj, ramp(item.pct or 0), false)
	end
	return obj, nil, { x = x, y = y, z = z }
end

local function realize(id)
	local o = B.objs[id]
	if not o or o.obj then return end
	local obj, _, at = make(o)
	if obj then
		o.obj, o.at = obj, at
		if o.bp == "lamp" and o.state == "built" then B.lamps[id] = at end
	else
		o.fail = (o.fail or 0) + 1
	end
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
	if o.obj then Pool.delete_object(o.obj) end
	B.objs[id], B.lamps[id] = nil, nil
	for i = #B.queue, 1, -1 do if B.queue[i] == id then table.remove(B.queue, i) end end
end

ctx.on("place_blueprint", function(ev) B.stats.ghosts = B.stats.ghosts + 1; add(ev.id, ev.bp, ev.pos, "planned", 0) end)

ctx.on("construction_progress", function(ev)
	local o = B.objs[ev.id]
	if not o then return end
	o.pct = ev.pct
	if o.obj and DoesEntityExist(o.obj) then SetEntityAlpha(o.obj, ramp(ev.pct), false) end
end)

ctx.on("construction_done", function(ev)
	B.stats.built = B.stats.built + 1
	local o = add(ev.id, ev.bp, ev.pos, "built", 100)
	if o.obj and DoesEntityExist(o.obj) then
		SetEntityCollision(o.obj, true, true)
		ResetEntityAlpha(o.obj)
		if ev.bp == "lamp" then B.lamps[ev.id] = o.at end
	end
end)

ctx.on("building_destroyed", function(ev) B.stats.destroyed = B.stats.destroyed + 1; remove(ev.id) end)

function B.clear()
	for id in pairs(B.objs) do remove(id) end
	B.objs, B.queue, B.lamps = {}, {}, {}
	B.cancel_placing()
end

-- ---------------------------------------------------------------------------------------------------------------- placement mode
function B.start_placing(bp)
	B.cancel_placing()
	local pl = { bp = bp, pos = nil, ok = false, reason = "ok" }
	ctx.placing = pl
	ctx.placing_commit = B.commit
	ctx.placing_cancel = B.cancel_placing
	return pl
end

function B.cancel_placing()
	local pl = ctx.placing
	if pl and pl.ghost then Pool.delete_object(pl.ghost) end
	ctx.placing, ctx.placing_commit, ctx.placing_cancel = nil, nil, nil
	if ctx.nui_send then ctx.nui_send("place", { cancelled = true }) end
end

local function tint(obj, ok)
	SetEntityDrawOutline(obj, true)
	if ok then SetEntityDrawOutlineColor(53, 211, 154, 255) else SetEntityDrawOutlineColor(255, 93, 108, 255) end
end

-- called every frame by the placement thread with the cursor's ground point (game space) or nil
function B.update_ghost(gx, gy, gz)
	local pl = ctx.placing
	if not pl or not gx then return end
	local sx, sy = ctx.to_sim(gx, gy)
	sx, sy = Placement.snap(sx, cfg.grid), Placement.snap(sy, cfg.grid)
	local ox, oy = ctx.to_game(sx, sy, 0.0)
	pl.pos = { x = sx, y = sy }
	local catalog, state = ctx.catalog, ctx.state
	if catalog and state then pl.ok, pl.reason = Placement.validate(state.buildings, catalog, pl.bp, sx, sy) else pl.ok, pl.reason = true, "ok" end
	if not pl.ghost then
		pl.ghost = Pool.create_object(models_for(pl.bp), ox, oy, gz, false)
		if pl.ghost then SetEntityCollision(pl.ghost, false, false); SetEntityAlpha(pl.ghost, 150, false); FreezeEntityPosition(pl.ghost, true) end
	end
	if pl.ghost then
		SetEntityCoordsNoOffset(pl.ghost, ox, oy, gz, false, false, false)
		tint(pl.ghost, pl.ok)
	end
	if pl.last_ok ~= pl.ok or pl.last_reason ~= pl.reason then
		pl.last_ok, pl.last_reason = pl.ok, pl.reason
		if ctx.nui_send then ctx.nui_send("place", { bp = pl.bp, x = sx, y = sy, ok = pl.ok, reason = pl.reason }) end
	end
end

function B.commit(chain)
	local pl = ctx.placing
	if not pl or not pl.pos then return false end
	if not pl.ok then
		if ctx.nui_send then ctx.nui_send("toast", { level = "warn", text = "Cannot build here: " .. tostring(pl.reason) }) end
		return false
	end
	B.stats.placed_orders = B.stats.placed_orders + 1
	TriggerServerEvent(P.NET.order, { id = "colony", kind = "place_blueprint", target = { bp = pl.bp, pos = { x = pl.pos.x, y = pl.pos.y, z = 0.0 } } })
	if not chain then B.cancel_placing() end
	return true
end

function B.start_threads(camera)
	CreateThread(function()
		while ctx.running do
			Wait(0)
			if ctx.placing and camera.active then
				local gx, gy, gz = camera.ground_at(camera.mouse.x, camera.mouse.y)
				B.update_ghost(gx, gy, gz)
			end
			-- powered lamps light the base (artificial light: the blackout dims the world, the base keeps its own light)
			if ctx.power_on ~= false then
				for _, at in pairs(B.lamps) do DrawLightWithRange(at.x, at.y, at.z + 2.6, 255, 228, 176, 16.0, 1.4) end
			end
		end
	end)
	CreateThread(function()
		while ctx.running do
			Wait(150)
			B.step()
		end
	end)
end

ctx.on_reset("build", B.clear)
ctx.on_cleanup("build", B.clear)
return B
