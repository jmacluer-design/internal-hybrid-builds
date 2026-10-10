-- client/camera.lua : the overhead colony camera. Toggle with F6 (or the page). While active the player ped is frozen and the SIM's observer (player_state) is the camera focus, so
-- hordes materialize where you are looking. Controls arrive through the browser page (it owns the keyboard and the mouse while the cursor is shown): WASD / arrows pan (Shift = fast),
-- Q / E rotate, the wheel zooms, the screen edge pans, left click selects the colonist under the cursor (a ray from the camera), a drag box-selects (projection of every colonist),
-- right click orders the selection to the ground point under the cursor. Picking uses getWorldFromScreenPosition + processLineOfSight and getScreenFromWorldPosition, with a ground
-- plane as the fallback; the ray maths for distance-to-ray is shared/raymath.lua (unit-tested, reused unchanged from the FiveM adapter).
--
-- borrowed: the FiveM adapter's client/camera.lua (own code: pan / zoom / select logic), which itself took the ray formulas from overextended/ox_lib imports/raycast (LGPL-3.0, see
-- THIRD_PARTY.md); the MTA functions replace the natives. MTA's setCameraMatrix takes a position and a look-at point, not a rotation, so the camera is placed from (focus, height, yaw).
local ctx = require("client.ctx")
local NET = require("shared.mta_net")
local Ray = require("shared.raymath")
local Colonists = require("client.colonists_view")

local Cam = {
	active = false, f = { x = 0.0, y = 0.0, z = 0.0 }, h = 60.0, yaw = 0.0, pitch = -60.0,
	keys = {}, mouse = { x = 0.5, y = 0.5 }, down = nil, selected = {}, pings = {}, pos = { x = 0.0, y = 0.0, z = 0.0 },
	stats = { clicks = 0, boxes = 0, orders = 0, matrix_sets = 0 }, ground_t = 0,
}
local cfg = ctx.cfg
local PAN_KEYS = { w = true, a = true, s = true, d = true, q = true, e = true, ArrowUp = true, ArrowDown = true, ArrowLeft = true, ArrowRight = true, shift = true }

local function screen_size() return guiGetScreenSize() end

-- ---------------------------------------------------------------------------------------------------------------- placement of the camera
function Cam.apply()
	local yaw = math.rad(Cam.yaw)
	local back = Cam.h / math.tan(math.rad(-Cam.pitch))
	local cx, cy, cz = Cam.f.x + math.sin(yaw) * back, Cam.f.y - math.cos(yaw) * back, Cam.f.z + Cam.h
	Cam.pos.x, Cam.pos.y, Cam.pos.z = cx, cy, cz
	if Cam.active then
		setCameraMatrix(cx, cy, cz, Cam.f.x, Cam.f.y, Cam.f.z, 0.0, cfg.cam_fov)
		Cam.stats.matrix_sets = Cam.stats.matrix_sets + 1
	end
	local sx, sy = ctx.to_sim(Cam.f.x, Cam.f.y)
	ctx.player_sim.x, ctx.player_sim.y = sx, sy
end

function Cam.enter()
	if Cam.active then return end
	local x, y, z = getElementPosition(localPlayer)
	Cam.f.x, Cam.f.y, Cam.f.z = x, y, z
	Cam.active, ctx.colony_mode = true, true
	Cam.apply()
	setElementFrozen(localPlayer, true)
end

function Cam.leave()
	if not Cam.active then return end
	Cam.active, ctx.colony_mode = false, false
	setCameraTarget(localPlayer)
	setElementFrozen(localPlayer, false)
	Cam.keys, Cam.down = {}, nil
end

-- a ground height sample of 0 means "no collision loaded here" in MTA, so it never replaces a known height
local function ground(x, y, z)
	local gz = getGroundPosition(x, y, z + 50.0)
	if type(gz) == "number" and gz ~= 0 then return gz end
	return nil
end
Cam.ground = ground

function Cam.focus(gx, gy)
	Cam.f.x, Cam.f.y = gx, gy
	Cam.f.z = ground(gx, gy, Cam.f.z) or Cam.f.z
	if Cam.active then Cam.apply() end
end

-- ---------------------------------------------------------------------------------------------------------------- picking
-- unit direction of the ray through normalised screen coordinates (0..1, top-left origin), from the camera position
local function ray_dir(sx, sy)
	local w, h = screen_size()
	local wx, wy, wz = getWorldFromScreenPosition(sx * w, sy * h, 100.0)
	local dx, dy, dz = wx - Cam.pos.x, wy - Cam.pos.y, wz - Cam.pos.z
	local len = math.sqrt(dx * dx + dy * dy + dz * dz)
	if len < 1e-6 then return nil end
	return dx / len, dy / len, dz / len
end

-- ground point under normalised screen coordinates, or nil. A line of sight against the world gives the real terrain; the plane z = focus z is the fallback.
function Cam.ground_at(sx, sy)
	local dx, dy, dz = ray_dir(sx, sy)
	if not dx then return nil end
	local far = 600.0
	local hit, hx, hy, hz = processLineOfSight(Cam.pos.x, Cam.pos.y, Cam.pos.z, Cam.pos.x + dx * far, Cam.pos.y + dy * far, Cam.pos.z + dz * far, true, false, false, false, false, false, false, false)
	if hit then return hx, hy, hz end
	local fx, fy, fz = Ray.hit_plane(Cam.pos.x, Cam.pos.y, Cam.pos.z, dx, dy, dz, Cam.f.z)
	if fx then return fx, fy, fz end
	return nil
end

function Cam.pick_colonist(sx, sy)
	local dx, dy, dz = ray_dir(sx, sy)
	if not dx then return nil end
	local best, bd = nil, 1.4
	for _, c in ipairs(Colonists.list()) do
		local px, py, pz = getElementPosition(c.ped)
		local d = Ray.point_ray_distance(Cam.pos.x, Cam.pos.y, Cam.pos.z, dx, dy, dz, px, py, pz)
		if d < bd then best, bd = c.id, d end
	end
	return best
end

function Cam.pick_box(x0, y0, x1, y1)
	local lx, hx, ly, hy = math.min(x0, x1), math.max(x0, x1), math.min(y0, y1), math.max(y0, y1)
	local w, h = screen_size()
	local ids = {}
	for _, c in ipairs(Colonists.list()) do
		local px, py, pz = getElementPosition(c.ped)
		local sx, sy = getScreenFromWorldPosition(px, py, pz)
		if sx and sx / w >= lx and sx / w <= hx and sy / h >= ly and sy / h <= hy then ids[#ids + 1] = c.id end
	end
	return ids
end

function Cam.set_selection(ids, notify)
	Cam.selected = ids
	if notify and ctx.nui_send then ctx.nui_send("selection", { ids = ids }) end
end

-- ---------------------------------------------------------------------------------------------------------------- page input
function Cam.on_key(d)
	local k = tostring(d.k or "")
	if k ~= "" and PAN_KEYS[k] then Cam.keys[k] = d.down and true or nil end
end

local function placing() return ctx.placing end

function Cam.on_mouse(d)
	if not Cam.active then return end
	local x, y = tonumber(d.x) or 0.5, tonumber(d.y) or 0.5
	Cam.mouse.x, Cam.mouse.y = x, y
	local t = d.type
	if t == "wheel" then
		Cam.h = math.max(cfg.cam_min_h, math.min(cfg.cam_max_h, Cam.h * (d.dy and d.dy > 0 and 1.12 or 1 / 1.12)))
		Cam.apply()
	elseif t == "down" and d.button == 0 then
		Cam.down = { x = x, y = y, shift = d.shift }
	elseif t == "up" and d.button == 0 and Cam.down then
		local s = Cam.down
		Cam.down = nil
		local moved = math.abs(x - s.x) + math.abs(y - s.y) > 0.012
		if placing() then
			if not moved and ctx.placing_commit then ctx.placing_commit(s.shift) end
		elseif moved then
			Cam.stats.boxes = Cam.stats.boxes + 1
			local ids = Cam.pick_box(s.x, s.y, x, y)
			if s.shift then for _, id in ipairs(Cam.selected) do ids[#ids + 1] = id end end
			Cam.set_selection(ids, true)
		else
			Cam.stats.clicks = Cam.stats.clicks + 1
			local id = Cam.pick_colonist(x, y)
			if id then
				local ids = {}
				if s.shift then for _, v in ipairs(Cam.selected) do ids[#ids + 1] = v end end
				ids[#ids + 1] = id
				Cam.set_selection(ids, true)
			elseif not s.shift then
				Cam.set_selection({}, true)
			end
		end
	elseif t == "context" then
		if placing() and ctx.placing_cancel then ctx.placing_cancel(); return end
		if #Cam.selected > 0 then
			local gx, gy, gz = Cam.ground_at(x, y)
			if gx then
				local sx, sy = ctx.to_sim(gx, gy)
				for i, id in ipairs(Cam.selected) do
					Cam.stats.orders = Cam.stats.orders + 1
					triggerServerEvent(NET.order, resourceRoot, { id = id, kind = "goto", target = { x = sx + ((i - 1) % 3) * 2.2, y = sy - math.floor((i - 1) / 3) * 2.2, z = 0.0 } })
				end
				Cam.pings[#Cam.pings + 1] = { x = gx, y = gy, z = gz, until_t = getTickCount() + 1200 }
			end
		end
	end
end

-- ---------------------------------------------------------------------------------------------------------------- per-frame
local function ring(x, y, z, r, color)
	local px, py
	for i = 0, 12 do
		local a = i / 12 * 6.2831853
		local nx, ny = x + math.cos(a) * r, y + math.sin(a) * r
		if px then dxDrawLine3D(px, py, z, nx, ny, z, color, 3.0) end
		px, py = nx, ny
	end
end

-- logic every frame (onClientPreRender, dt in ms)
function Cam.frame(dt_ms)
	if not Cam.active then return end
	local dt = dt_ms / 1000
	local k = Cam.keys
	local fast = k.shift and 2.4 or 1.0
	local speed = cfg.cam_pan_speed * (Cam.h / 60.0) * fast
	local fwd, right = 0.0, 0.0
	if k.w or k.ArrowUp then fwd = fwd + 1.0 end
	if k.s or k.ArrowDown then fwd = fwd - 1.0 end
	if k.d or k.ArrowRight then right = right + 1.0 end
	if k.a or k.ArrowLeft then right = right - 1.0 end
	local m = Cam.mouse
	if not Cam.down then -- edge pan (not while dragging a selection box)
		local e = cfg.edge_pan
		if m.y < e then fwd = fwd + 1.0 elseif m.y > 1 - e then fwd = fwd - 1.0 end
		if m.x < e then right = right - 1.0 elseif m.x > 1 - e then right = right + 1.0 end
	end
	local rot = 0.0
	if k.q then rot = rot + 1.0 end
	if k.e then rot = rot - 1.0 end
	if fwd ~= 0.0 or right ~= 0.0 or rot ~= 0.0 then
		Cam.yaw = (Cam.yaw + rot * 70.0 * dt) % 360.0
		local yaw = math.rad(Cam.yaw)
		Cam.f.x = Cam.f.x + (-math.sin(yaw) * fwd + math.cos(yaw) * right) * speed * dt
		Cam.f.y = Cam.f.y + (math.cos(yaw) * fwd + math.sin(yaw) * right) * speed * dt
		Cam.apply()
	end
	local now = getTickCount()
	if now - Cam.ground_t > 600 then
		Cam.ground_t = now
		Cam.f.z = ground(Cam.f.x, Cam.f.y, Cam.f.z) or Cam.f.z
		Cam.apply()
	end
end

-- drawing every frame (onClientRender): selection rings under selected colonists, pings for move orders
function Cam.draw()
	if not Cam.active then return end
	local now = getTickCount()
	for _, id in ipairs(Cam.selected) do
		for _, c in ipairs(Colonists.list()) do
			if c.id == id then
				local px, py, pz = getElementPosition(c.ped)
				ring(px, py, pz - 0.95, 0.9, tocolor(255, 211, 138, 200))
			end
		end
	end
	for i = #Cam.pings, 1, -1 do
		local pg = Cam.pings[i]
		if now > pg.until_t then table.remove(Cam.pings, i) else ring(pg.x, pg.y, pg.z + 0.05, 1.2, tocolor(53, 211, 154, 190)) end
	end
end

function Cam.start()
	ctx.frame("onClientPreRender", "camera.frame", Cam.frame)
	ctx.frame("onClientRender", "camera.draw", Cam.draw)
end

ctx.on_cleanup("camera", Cam.leave)
return Cam
