local P = SKATEGM_PARTS
-- a quarter pipe of radius r (its height) rising toward +x, a deck behind it,
-- coping on the lip
function P.QuarterPieces(r, w, deck)
	local curve = P.QuarterCurve(0, r, math.max(12, math.floor(r / 6)))
	local profile = { { r + deck, 0 } }
	for _, p in ipairs(curve) do profile[#profile + 1] = p end
	profile[#profile + 1] = { r + deck, r }
	local convex = P.UnderCurve(curve)
	convex[#convex + 1] = { { r, 0 }, { r + deck, 0 }, { r + deck, r }, { r, r } }
	return {
		P.Prism("y", profile, 0, w, nil, convex),
		P.Coping("y", 0, w, r - 0.6, r, 1.4),
	}
end
local sizes = {}
for _, r in ipairs({ 48, 72, 96, 128 }) do
	for _, w in ipairs({ 128, 256 }) do
		local default = r == 96 and w == 128
		sizes[#sizes + 1] = { key = (not default) and (r .. "x" .. w) or nil, title = r .. " high, " .. w .. " wide", r = r, w = w }
	end
end
P.Family({
	id = "quarter_pipe", title = "Quarter pipe", order = 10, surface = "wood", category = "SkateGM Bowls & pipes",
	info = "A quarter pipe with a deck and coping. Its deck edge snaps to a deck or a quarter pipe as high.",
	sizes = sizes,
	build = function(s) return P.QuarterPieces(s.r, s.w, 48) end,
})
