-- shared/raymath.lua : camera ray math for the overhead colony camera (pure Lua, no natives, unit-tested on lua5.4 and luajit).
-- GTA conventions: rotation in DEGREES as (pitch x, roll y, yaw z), rotation order 2 (ZXY); yaw 0 looks along +Y (north), positive yaw turns left;
-- forward = (-sin(yaw) * |cos(pitch)|, cos(yaw) * |cos(pitch)|, sin(pitch)).  (Same direction formula as ox_lib's lib.raycast, LGPL-3.0.)
local M = {}
local rad, sin, cos, tan, sqrt, abs, deg = math.rad, math.sin, math.cos, math.tan, math.sqrt, math.abs, math.deg
local atan2 = math.atan2 or math.atan

local function norm(x, y, z)
	local l = sqrt(x * x + y * y + z * z)
	if l < 1e-9 then return 0, 0, 1 end
	return x / l, y / l, z / l
end

-- forward / right / up unit vectors of a camera with the given rotation (degrees; roll ignored)
function M.basis(rx, rz)
	local pitch, yaw = rad(rx), rad(rz)
	local c = abs(cos(pitch))
	local fx, fy, fz = -sin(yaw) * c, cos(yaw) * c, sin(pitch)
	local rx_, ry_, rz_ = cos(yaw), sin(yaw), 0.0
	-- up = right x forward
	local ux, uy, uz = ry_ * fz - rz_ * fy, rz_ * fx - rx_ * fz, rx_ * fy - ry_ * fx
	return { fx, fy, fz }, { rx_, ry_, rz_ }, { ux, uy, uz }
end

-- direction of the ray through normalised screen coordinates (sx, sy in 0..1, origin top-left)
-- fov = vertical field of view in degrees, aspect = width / height
function M.screen_ray(rx, rz, fov, aspect, sx, sy)
	local f, r, u = M.basis(rx, rz)
	local th = tan(rad(fov) / 2)
	local px = (sx - 0.5) * 2 * th * aspect
	local py = (0.5 - sy) * 2 * th
	return norm(f[1] + r[1] * px + u[1] * py, f[2] + r[2] * px + u[2] * py, f[3] + r[3] * px + u[3] * py)
end

-- intersection of a ray with the horizontal plane z = plane_z; returns x, y, z, t or nil when the ray points away / is parallel
function M.hit_plane(ox, oy, oz, dx, dy, dz, plane_z)
	if abs(dz) < 1e-6 then return nil end
	local t = (plane_z - oz) / dz
	if t <= 0 then return nil end
	return ox + dx * t, oy + dy * t, plane_z, t
end

-- project a world point to normalised screen coordinates; returns sx, sy, depth or nil when behind the camera
function M.project(cx, cy, cz, rx, rz, fov, aspect, x, y, z)
	local f, r, u = M.basis(rx, rz)
	local dx, dy, dz = x - cx, y - cy, z - cz
	local depth = dx * f[1] + dy * f[2] + dz * f[3]
	if depth <= 0.01 then return nil end
	local th = tan(rad(fov) / 2)
	local px = (dx * r[1] + dy * r[2] + dz * r[3]) / depth
	local py = (dx * u[1] + dy * u[2] + dz * u[3]) / depth
	return 0.5 + px / (2 * th * aspect), 0.5 - py / (2 * th), depth
end

-- distance from point (x,y,z) to the ray (origin o, unit direction d); returns distance, along (t)
function M.point_ray_distance(ox, oy, oz, dx, dy, dz, x, y, z)
	local vx, vy, vz = x - ox, y - oy, z - oz
	local t = vx * dx + vy * dy + vz * dz
	if t < 0 then return sqrt(vx * vx + vy * vy + vz * vz), 0 end
	local px, py, pz = ox + dx * t, oy + dy * t, oz + dz * t
	local ex, ey, ez = x - px, y - py, z - pz
	return sqrt(ex * ex + ey * ey + ez * ez), t
end

-- camera rotation (pitch, yaw) that looks from (cx,cy,cz) towards (tx,ty,tz)
function M.look_at(cx, cy, cz, tx, ty, tz)
	local dx, dy, dz = tx - cx, ty - cy, tz - cz
	local flat = sqrt(dx * dx + dy * dy)
	local pitch = deg(atan2(dz, flat))
	local yaw = deg(atan2(-dx, dy))
	return pitch, yaw
end

return M
