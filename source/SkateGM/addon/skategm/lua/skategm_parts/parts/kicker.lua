local P = SKATEGM_PARTS
-- a curved kicker rising `h` over `len`, `w` wide
local function Kicker(len, h, w)
	local curve = P.CurveUp(0, len, h, 1.5, math.max(6, math.floor(len / 8)))
	local profile = { { len, 0 } }
	for _, p in ipairs(curve) do profile[#profile + 1] = p end
	return { P.Prism("y", profile, 0, w, nil, P.UnderCurve(curve)) }
end
P.Family({
	id = "kicker", title = "Kicker", order = 1, surface = "wood", category = "SkateGM Ramps",
	info = "A small curved kicker.",
	sizes = {
		{ key = "small", title = "small, 8 high", len = 32, h = 8, w = 48 },
		{ title = "16 high", len = 64, h = 16, w = 48 },
		{ key = "large", title = "large, 24 high", len = 96, h = 24, w = 64 },
	},
	build = function(s) return Kicker(s.len, s.h, s.w) end,
})
