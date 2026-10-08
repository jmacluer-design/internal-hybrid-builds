local P = SKATEGM_PARTS
-- a steep kicker for big air, with a short deck behind the lip (a curve that
-- drops straight off its lip is a rail the board grinds by itself)
local function Launch(len, h, w, deck)
	local curve = P.CurveUp(0, len, h, 1.8, math.max(8, math.floor(len / 8)))
	local back = len + deck
	local profile = { { back, 0 } }
	for _, p in ipairs(curve) do profile[#profile + 1] = p end
	profile[#profile + 1] = { back, h }
	local convex = P.UnderCurve(curve)
	convex[#convex + 1] = { { len, 0 }, { back, 0 }, { back, h }, { len, h } }
	return { P.Prism("y", profile, 0, w, nil, convex) }
end
P.Family({
	id = "launch_ramp", title = "Launch ramp", order = 2, surface = "wood", category = "SkateGM Ramps",
	info = "A steep kicker for big air, with a short deck behind the lip.",
	sizes = {
		{ title = "36 high", len = 96, h = 36, w = 64, deck = 16 },
		{ key = "large", title = "large, 56 high", len = 144, h = 56, w = 96, deck = 24 },
	},
	build = function(s) return Launch(s.len, s.h, s.w, s.deck) end,
})
