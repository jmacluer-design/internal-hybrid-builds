local P = SKATEGM_PARTS
-- two quarter pipes back to back, meeting at a shared coping
local function Spine(r, w)
	local curve = P.QuarterCurve(0, r, math.max(12, math.floor(r / 6)))
	local other = {}
	for i = #curve, 1, -1 do other[#other + 1] = { 2 * r - curve[i][1], curve[i][2] } end
	local profile = {}
	for _, p in ipairs(curve) do profile[#profile + 1] = p end
	for i = 2, #other do profile[#profile + 1] = other[i] end
	local convex = P.UnderCurve(curve)
	for _, slab in ipairs(P.UnderCurve(other)) do convex[#convex + 1] = slab end
	return { P.Prism("y", profile, 0, w, nil, convex), P.Coping("y", 0, w, r, r, 1.4) }
end
P.Family({
	id = "spine", title = "Spine", order = 12, surface = "wood", category = "SkateGM Bowls & pipes",
	info = "Two quarter pipes back to back: transfer over the shared coping.",
	sizes = {
		{ key = "72", title = "72 high", r = 72, w = 128 },
		{ key = "96", title = "96 high", r = 96, w = 128 },
	},
	build = function(s) return Spine(s.r, s.w) end,
})
