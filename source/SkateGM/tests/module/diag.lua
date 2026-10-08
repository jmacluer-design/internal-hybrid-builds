dofile("env.lua") TEST.open("release")
local function wait(s) local t = os.clock() + s while os.clock() < t do end end
local bytes = TEST.mapBytes()
local cx, cy, cz = TEST.centre[1], TEST.centre[2], TEST.centre[3]
skategm.Load(TEST.data, cx, cy, cz, 0, bytes, 1, 1)
local t0 = os.clock()
repeat wait(0.5) until skategm.Poll().status ~= "loading" or os.clock() - t0 > 120
skategm.Activate(cx, cy, cz, 0) wait(1)
-- find a real floor surface near the centre: a collision triangle facing up
local t = skategm.CollisionNear(cx, cy, cz, 2000, 5000)
for i = 1, #t - 8, 9 do
	local ax, ay, az, bx, by, bz, cx, cy, cz = t[i], t[i+1], t[i+2], t[i+3], t[i+4], t[i+5], t[i+6], t[i+7], t[i+8]
	local ux, uy, uz, vx, vy, vz = bx-ax, by-ay, bz-az, cx-ax, cy-ay, cz-az
	local nx, ny, nz = uy*vz-uz*vy, uz*vx-ux*vz, ux*vy-uy*vx
	local l = math.sqrt(nx*nx+ny*ny+nz*nz)
	if l > 20 and nz / l > 0.99 then
		local px, py, pz = (ax+bx+cx)/3, (ay+by+cy)/3, (az+bz+cz)/3
		print(string.format("a floor at %.0f %.0f %.0f:", px, py, pz))
		for _, line in ipairs(skategm.Diagnose(px, py, pz, 0, 0, 1)) do print("  " .. line) end
		break
	end
end
print("mid-air (nothing there):")
for _, line in ipairs(skategm.Diagnose(cx, cy, cz + 5000, 0, 0, 1)) do print("  " .. line) end
skategm.Stop()
