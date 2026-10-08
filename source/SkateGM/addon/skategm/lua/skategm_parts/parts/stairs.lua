local P = SKATEGM_PARTS
-- n steps up (each 8 high, 16 deep) to a platform 64 long
local function Stairs(n, w)
	local top, back = n * 8, n * 16 + 64
	local profile = { { 0, 0 }, { back, 0 }, { back, top } }
	for i = n, 1, -1 do
		profile[#profile + 1] = { (i - 1) * 16, i * 8 }
		if i > 1 then profile[#profile + 1] = { (i - 1) * 16, (i - 1) * 8 } end
	end
	local convex = {}
	for i = 1, n do
		local x0, x1 = (i - 1) * 16, i == n and back or i * 16
		convex[#convex + 1] = { { x0, 0 }, { x1, 0 }, { x1, i * 8 }, { x0, i * 8 } }
	end
	return { P.Prism("y", profile, 0, w, nil, convex) }
end
P.Family({
	id = "stairs", title = "Stair set", order = 33, category = "SkateGM Ledges & rails",
	info = "Steps up to a platform: ollie down them or grind the edges.",
	sizes = {
		{ title = "3 steps", n = 3, w = 96 },
		{ key = "5", title = "5 steps", n = 5, w = 128 },
	},
	build = function(s) return Stairs(s.n, s.w) end,
})
