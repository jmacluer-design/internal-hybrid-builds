-- client/camera.lua : the overhead colony camera. Toggle with F6 (or the NUI). While active the player ped is frozen + invincible and the SIM's observer
-- (player_state) becomes the camera focus, so hordes materialize where you are looking. Controls arrive through the NUI page (it owns the keyboard and
-- the mouse while NUI focus is on): WASD / arrows pan (Shift = fast), Q / E rotate, mouse wheel zooms, the screen edge pans, left click selects the colonist
-- under the cursor (a ray from the camera), drag box-selects (projection of every colonist), right click orders the selection to the ground point under
-- the cursor. Ray / projection maths lives in shared/raymath.lua (unit-tested); the ground pick uses a shape-test probe with a plane fallback.
--
-- borrowed: overextended/ox_lib imports/raycast/client.lua (LGPL-3.0): the "StartShapeTestLosProbe then poll the result each frame" loop and the
--           rotation -> forward vector formula (see shared/raymath.lua).
local ctx = require("client.ctx")
local Pool = require("client.pool")
local P = require("shared.protocol")
local Ray = require("shared.raymath")

local Cam = {
	active = false, cam = nil, f = { x = 0.0, y = 0.0, z = 0.0 }, h = 60.0, yaw = 0.0, pitch = -60.0, fov = 50.0,
	keys = {}, mouse = { x = 0.5, y = 0.5 }, down = nil, selected = {}, pings = {}, pos = { x = 0.0, y = 0.0, z = 0.0 },
	stats = { clicks = 0, boxes = 0, orders = 0 }, ground_t = 0, hover = nil,
}
local cfg = ctx.cfg
local PAN_KEYS = { w = true, a = true, s = true, d = true, q = true, e = true, ArrowUp = true, ArrowDown = true, ArrowLeft = true, ArrowRight = true, shift = true }

-- ---------------------------------------------------------------------------------------------------------------- placement of the camera
function Cam.apply()
	local yaw = math.rad(Cam.yaw)
	local back = Cam.h / math.tan(math.rad(-Cam.pitch))
	local cx, cy, cz = Cam.f.x + math.sin(yaw) * back, Cam.f.y - math.cos(yaw) * back, Cam.f.z + Cam.h
	Cam.pos.x, Cam.pos.y, Cam.pos.z = cx, cy, cz
	if Cam.cam then
		SetCamCoord(Cam.cam, cx, cy, cz)
		SetCamRot(Cam.cam, Cam.pitch, 0.0, Cam.yaw, 2)
		SetCamFov(Cam.cam, Cam.fov)
	end
	SetFocusArea(Cam.f.x, Cam.f.y, Cam.f.z, 0.0, 0.0, 0.0) -- stream the world under the camera, not under the frozen player
	local sx, sy = ctx.to_sim(Cam.f.x, Cam.f.y)
	ctx.player_sim.x, ctx.player_sim.y = sx, sy
end

function Cam.enter()
	if Cam.active then return end
	local ped = PlayerPedId()
	local p = GetEntityCoords(ped)
	Cam.f.x, Cam.f.y, Cam.f.z = p.x, p.y, p.z
	Cam.cam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
	Cam.apply()
	SetCamActive(Cam.cam, true)
	RenderScriptCams(true, true, 600, true, false)
	FreezeEntityPosition(ped, true)
	SetEntityInvincible(ped, true)
	Cam.active, ctx.colony_mode = true, true
end

function Cam.leave()
	if not Cam.active then return end
	Cam.active, ctx.colony_mode = false, false
	RenderScriptCams(false, true, 600, true, false)
	if Cam.cam then DestroyCam(Cam.cam, false); Cam.cam = nil end
	ClearFocus()
	local ped = PlayerPedId()
	FreezeEntityPosition(ped, false)
	SetEntityInvincible(ped, false)
	Cam.keys, Cam.down = {}, nil
end

function Cam.focus(gx, gy)
	Cam.f.x, Cam.f.y = gx, gy
	Cam.f.z = Pool.ground_z(gx, gy, Cam.f.z)
	if Cam.active then Cam.apply() end
end

-- ---------------------------------------------------------------------------------------------------------------- picking
local function aspect() return GetAspectRatio(false) end

-- ground point under normalised screen coordinates, or nil. A shape test gives the real terrain; the plane z = focus z is the fallback.
function Cam.ground_at(sx, sy)
	local dx, dy, dz = Ray.screen_ray(Cam.pitch, Cam.yaw, Cam.fov, aspect(), sx, sy)
	local fx, fy, fz = Ray.hit_plane(Cam.pos.x, Cam.pos.y, Cam.pos.z, dx, dy, dz, Cam.f.z)
	if not fx then return nil end
	local far = 400.0
	local handle = StartShapeTestLosProbe(Cam.pos.x, Cam.pos.y, Cam.pos.z, Cam.pos.x + dx * far, Cam.pos.y + dy * far, Cam.pos.z + dz * far, 1, 0, 4)
	for _ = 1, 6 do
		local ret, hit, end_coords = GetShapeTestResult(handle)
		if ret ~= 1 then
			if hit == 1 or hit == true then return end_coords.x, end_coords.y, end_coords.z end
			break
		end
		Wait(0)
	end
	return fx, fy, fz
end

function Cam.pick_colonist(sx, sy)
	local dx, dy, dz = Ray.screen_ray(Cam.pitch, Cam.yaw, Cam.fov, aspect(), sx, sy)
	local best, bd = nil, 1.4
	for _, c in ipairs(ctx.colonist_peds and ctx.colonist_peds() or {}) do
		local p = GetEntityCoords(c.ped)
		local d = Ray.point_ray_distance(Cam.pos.x, Cam.pos.y, Cam.pos.z, dx, dy, dz, p.x, p.y, p.z)
		if d < bd then best, bd = c.id, d end
	end
	return best
end

function Cam.pick_box(x0, y0, x1, y1)
	local lx, hx, ly, hy = math.min(x0, x1), math.max(x0, x1), math.min(y0, y1), math.max(y0, y1)
	local ids = {}
	for _, c in ipairs(ctx.colonist_peds and ctx.colonist_peds() or {}) do
		local p = GetEntityCoords(c.ped)
		local on, sx, sy = GetScreenCoordFromWorldCoord(p.x, p.y, p.z)
		if on and sx >= lx and sx <= hx and sy >= ly and sy <= hy then ids[#ids + 1] = c.id end
	end
	return ids
end

function Cam.set_selection(ids, notify)
	Cam.selected = ids
	if notify and ctx.nui_send then ctx.nui_send("selection", { ids = ids }) end
end

-- ---------------------------------------------------------------------------------------------------------------- NUI input
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
					TriggerServerEvent(P.NET.order, { id = id, kind = "goto", target = { x = sx + ((i - 1) % 3) * 2.2, y = sy - math.floor((i - 1) / 3) * 2.2, z = 0.0 } })
				end
				Cam.pings[#Cam.pings + 1] = { x = gx, y = gy, z = gz, until_t = GetGameTimer() + 1200 }
			end
		end
	end
end

-- ---------------------------------------------------------------------------------------------------------------- per-frame
function Cam.frame()
	if not Cam.active then return end
	HideHudAndRadarThisFrame()
	local dt = GetFrameTime()
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
	local now = GetGameTimer()
	if now - Cam.ground_t > 600 then
		Cam.ground_t = now
		Cam.f.z = Pool.ground_z(Cam.f.x, Cam.f.y, Cam.f.z)
		Cam.apply()
	end
	-- selection rings under selected colonists, pings for move orders
	for _, id in ipairs(Cam.selected) do
		for _, c in ipairs(ctx.colonist_peds and ctx.colonist_peds() or {}) do
			if c.id == id then
				local p = GetEntityCoords(c.ped)
				DrawMarker(25, p.x, p.y, p.z - 0.95, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.1, 1.1, 1.0, 255, 211, 138, 170, false, false, 2, false, nil, nil, false)
			end
		end
	end
	for i = #Cam.pings, 1, -1 do
		local pg = Cam.pings[i]
		if now > pg.until_t then table.remove(Cam.pings, i)
		else DrawMarker(25, pg.x, pg.y, pg.z + 0.05, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.6, 1.6, 1.0, 53, 211, 154, 160, false, false, 2, false, nil, nil, false) end
	end
end

function Cam.start_threads()
	ctx.loop("camera.frame", 0, function() if Cam.active then Cam.frame() end end)
end

ctx.on_cleanup("camera", Cam.leave)
return Cam
