-- client/placement.lua : blueprint PLACEMENT on the owner's client. A ghost (a client-side object, translucent, no collision) follows the cursor, snaps to the grid, is outlined green / red
-- by shared/placement.lua (the same rules as the sim's why_not), and a click sends a `place_blueprint` order. The sites and buildings themselves are SERVER objects
-- (server/buildings.lua: translucent while building, alpha ramp with construction_progress, solid when done); only this preview is local.
-- Written here (the FiveM adapter's placement mode on MTA functions); the validity rules are shared/placement.lua, reused unchanged. Nothing borrowed.
local ctx = require("client.ctx")
local NET = require("shared.mta_net")
local Placement = require("shared.placement")
local Camera = require("client.camera")

local B = { stats = { placed_orders = 0, ghosts = 0 } }
local cfg = ctx.cfg

local function models_for(bp) return ctx.config.props[bp] or ctx.config.props._fallback end

local function make_ghost(bp, x, y, z)
	for _, model in ipairs(models_for(bp)) do
		local obj = createObject(model, x, y, z)
		if obj then
			setElementCollisionsEnabled(obj, false)
			setElementAlpha(obj, 150)
			setElementFrozen(obj, true)
			B.stats.ghosts = B.stats.ghosts + 1
			return obj
		end
	end
	return nil
end

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
	if pl and pl.ghost and isElement(pl.ghost) then destroyElement(pl.ghost) end
	ctx.placing, ctx.placing_commit, ctx.placing_cancel = nil, nil, nil
	if ctx.nui_send then ctx.nui_send("place", { cancelled = true }) end
end

-- every frame while placing: the cursor's ground point (game space) or nil
function B.update_ghost(gx, gy, gz)
	local pl = ctx.placing
	if not pl or not gx then return end
	local sx, sy = ctx.to_sim(gx, gy)
	sx, sy = Placement.snap(sx, cfg.grid), Placement.snap(sy, cfg.grid)
	local ox, oy = ctx.to_game(sx, sy, 0.0)
	pl.pos = { x = sx, y = sy }
	pl.gz = gz
	local catalog, state = ctx.catalog, ctx.state
	if catalog and state then pl.ok, pl.reason = Placement.validate(state.buildings, catalog, pl.bp, sx, sy) else pl.ok, pl.reason = true, "ok" end
	if not pl.ghost or not isElement(pl.ghost) then pl.ghost = make_ghost(pl.bp, ox, oy, gz) end
	if pl.ghost then setElementPosition(pl.ghost, ox, oy, gz) end
	pl.ox, pl.oy = ox, oy
	if pl.last_ok ~= pl.ok or pl.last_reason ~= pl.reason then
		pl.last_ok, pl.last_reason = pl.ok, pl.reason
		if ctx.nui_send then ctx.nui_send("place", { bp = pl.bp, x = sx, y = sy, ok = pl.ok, reason = pl.reason }) end
	end
end

-- the outline: a green / red rectangle on the ground around the ghost (MTA objects cannot be tinted without shaders)
function B.draw()
	local pl = ctx.placing
	if not pl or not pl.ox then return end
	local d = pl.size or 1.5
	local z = (pl.gz or 0.0) + 0.15
	local c = pl.ok and tocolor(53, 211, 154, 230) or tocolor(255, 93, 108, 230)
	local x0, y0, x1, y1 = pl.ox - d, pl.oy - d, pl.ox + d, pl.oy + d
	dxDrawLine3D(x0, y0, z, x1, y0, z, c, 4.0); dxDrawLine3D(x1, y0, z, x1, y1, z, c, 4.0)
	dxDrawLine3D(x1, y1, z, x0, y1, z, c, 4.0); dxDrawLine3D(x0, y1, z, x0, y0, z, c, 4.0)
end

function B.commit(chain)
	local pl = ctx.placing
	if not pl or not pl.pos then return false end
	if not pl.ok then
		if ctx.nui_send then ctx.nui_send("toast", { level = "warn", text = "Cannot build here: " .. tostring(pl.reason) }) end
		return false
	end
	B.stats.placed_orders = B.stats.placed_orders + 1
	triggerServerEvent(NET.order, resourceRoot, { id = "colony", kind = "place_blueprint", target = { bp = pl.bp, pos = { x = pl.pos.x, y = pl.pos.y, z = 0.0 } } })
	if not chain then B.cancel_placing() end
	return true
end

function B.start()
	ctx.frame("onClientRender", "placement.draw", function()
		if ctx.placing and Camera.active then
			local gx, gy, gz = Camera.ground_at(Camera.mouse.x, Camera.mouse.y)
			B.update_ghost(gx, gy, gz)
			B.draw()
		end
	end)
end

ctx.on_reset("placement", B.cancel_placing)
ctx.on_cleanup("placement", B.cancel_placing)
return B
