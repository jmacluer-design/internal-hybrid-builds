-- shared/raymath.lua: the overhead camera's ray / projection / plane maths.
local T, H = ...
local R = require("shared.raymath")

T.group("raymath")

local function near3(a, b, tol, msg) T.near(a[1], b[1], tol, msg); T.near(a[2], b[2], tol, msg); T.near(a[3], b[3], tol, msg) end

T.test("basis: yaw 0 looks north (+Y), positive yaw turns left, pitch looks down", function()
	local f = R.basis(0, 0)
	near3(f, { 0, 1, 0 }, 1e-9, "north")
	near3((R.basis(0, 90)), { -1, 0, 0 }, 1e-9, "yaw 90 -> west")
	local f2 = R.basis(-90, 0)
	T.near(f2[3], -1, 1e-9, "straight down")
	local f3, r3, u3 = R.basis(-45, 30)
	T.near(f3[1] ^ 2 + f3[2] ^ 2 + f3[3] ^ 2, 1, 1e-9)
	T.near(f3[1] * r3[1] + f3[2] * r3[2] + f3[3] * r3[3], 0, 1e-9, "forward is orthogonal to right")
	T.near(f3[1] * u3[1] + f3[2] * u3[2] + f3[3] * u3[3], 0, 1e-9, "forward is orthogonal to up")
	T.gt(u3[3], 0, "up points up")
end)

T.test("the centre of the screen is the forward direction", function()
	local dx, dy, dz = R.screen_ray(-50, 25, 50, 16 / 9, 0.5, 0.5)
	local f = R.basis(-50, 25)
	near3({ dx, dy, dz }, f, 1e-9)
end)

T.test("project is the inverse of screen_ray (round trip on a grid of screen points)", function()
	local cx, cy, cz = 100, 200, 90
	for _, rot in ipairs({ { -60, 0 }, { -45, 37 }, { -70, 200 }, { -35, 310 } }) do
		for sx = 0.05, 0.95, 0.15 do
			for sy = 0.05, 0.95, 0.15 do
				local dx, dy, dz = R.screen_ray(rot[1], rot[2], 50, 16 / 9, sx, sy)
				local hx, hy, hz = R.hit_plane(cx, cy, cz, dx, dy, dz, 30)
				if hx then
					local px, py = R.project(cx, cy, cz, rot[1], rot[2], 50, 16 / 9, hx, hy, hz)
					T.near(px, sx, 1e-6, "sx"); T.near(py, sy, 1e-6, "sy")
				end
			end
		end
	end
end)

T.test("hit_plane: hits the ground in front, misses when pointing up or parallel", function()
	local x, y, z, t = R.hit_plane(0, 0, 100, 0, 0, -1, 30)
	T.near(x, 0, 1e-9); T.near(z, 30, 1e-9); T.near(t, 70, 1e-9)
	T.eq(R.hit_plane(0, 0, 100, 0, 1, 0, 30), nil, "parallel")
	T.eq(R.hit_plane(0, 0, 100, 0, 0, 1, 30), nil, "away")
	T.eq(R.hit_plane(0, 0, 10, 0, 0, -1, 30), nil, "plane behind the origin")
end)

T.test("project: behind the camera is nil, the target in front is on screen", function()
	T.eq(R.project(0, 0, 50, -60, 0, 50, 16 / 9, 0, -500, 50), nil, "behind")
	local pitch, yaw = R.look_at(0, -40, 60, 0, 0, 30)
	local sx, sy = R.project(0, -40, 60, pitch, yaw, 50, 16 / 9, 0, 0, 30)
	T.near(sx, 0.5, 1e-6); T.near(sy, 0.5, 1e-6)
end)

T.test("look_at: pitch and yaw point at the target", function()
	local pitch, yaw = R.look_at(0, 0, 100, 100, 0, 0) -- target to the east and below
	T.lt(pitch, 0, "looks down")
	T.near(yaw, -90, 1e-6, "east is yaw -90 (GTA: positive yaw turns left)")
	local f = R.basis(pitch, yaw)
	local len = math.sqrt(100 ^ 2 + 100 ^ 2)
	near3(f, { 100 / len, 0, -100 / len }, 1e-9)
end)

T.test("point_ray_distance: on the ray = 0, off the ray, behind the origin", function()
	local d, t = R.point_ray_distance(0, 0, 0, 0, 1, 0, 0, 10, 0)
	T.near(d, 0, 1e-9); T.near(t, 10, 1e-9)
	T.near((R.point_ray_distance(0, 0, 0, 0, 1, 0, 3, 10, 4)), 5, 1e-9)
	local db = R.point_ray_distance(0, 0, 0, 0, 1, 0, 0, -5, 0)
	T.near(db, 5, 1e-9, "behind the origin: distance to the origin")
end)

T.test("picking: a colonist under the cursor is found by the ray and by projection", function()
	local cam = { x = 1850, y = 3640, z = 90, pitch = -55, yaw = 12, fov = 50 }
	local px, py, pz = 1855, 3690, 34
	local sx, sy = R.project(cam.x, cam.y, cam.z, cam.pitch, cam.yaw, cam.fov, 16 / 9, px, py, pz)
	T.truthy(sx and sx > 0 and sx < 1 and sy > 0 and sy < 1, "on screen")
	local dx, dy, dz = R.screen_ray(cam.pitch, cam.yaw, cam.fov, 16 / 9, sx, sy)
	T.lt(R.point_ray_distance(cam.x, cam.y, cam.z, dx, dy, dz, px, py, pz), 1e-6)
	local dx2, dy2, dz2 = R.screen_ray(cam.pitch, cam.yaw, cam.fov, 16 / 9, sx + 0.2, sy)
	T.gt(R.point_ray_distance(cam.x, cam.y, cam.z, dx2, dy2, dz2, px, py, pz), 1.4, "a click 20% of the screen away misses")
end)
