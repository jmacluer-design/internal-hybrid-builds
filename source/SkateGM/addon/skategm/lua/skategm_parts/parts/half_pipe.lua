local P = SKATEGM_PARTS
-- a piece mirrored in x about x = m (its profile and convex parts reversed,
-- so they stay wound the same way)
local function Mirror(piece, m)
	local function flip(poly)
		local out = {}
		for i = #poly, 1, -1 do out[#out + 1] = { 2 * m - poly[i][1], poly[i][2] } end
		return out
	end
	local convex
	if piece.convex then
		convex = {}
		for _, c in ipairs(piece.convex) do convex[#convex + 1] = flip(c) end
	end
	if piece.axis == "y" then
		local out = P.Prism("y", flip(piece.profile), piece.from, piece.to, piece.surface, convex)
		out.visual = piece.visual
		return out
	end
	return piece
end
-- two quarter pipes facing each other across a flat bottom (the ground):
-- the left one rises toward -x, the right one toward +x
local function Half(r, w, flat)
	local deck = 48
	local pieces = {}
	for _, piece in ipairs(P.QuarterPieces(r, w, deck)) do
		-- left: mirrored about its own middle, then the right as it is, past the flat
		pieces[#pieces + 1] = Mirror(piece, (r + deck) / 2)
		local right = P.Prism(piece.axis, {}, piece.from, piece.to, piece.surface, nil)
		local shift = r + deck + flat
		local prof = {}
		for _, p in ipairs(piece.profile) do prof[#prof + 1] = { p[1] + shift, p[2] } end
		local convex
		if piece.convex then
			convex = {}
			for _, c in ipairs(piece.convex) do
				local m = {}
				for _, p in ipairs(c) do m[#m + 1] = { p[1] + shift, p[2] } end
				convex[#convex + 1] = m
			end
		end
		right.profile, right.convex, right.visual = prof, convex, piece.visual
		pieces[#pieces + 1] = right
	end
	return pieces
end
local sizes = {}
for _, r in ipairs({ 72, 96, 128 }) do
	for _, flat in ipairs({ 128, 256 }) do
		sizes[#sizes + 1] = { key = r .. "_" .. flat, title = r .. " high, " .. flat .. " flat", r = r, flat = flat }
	end
end
P.Family({
	id = "half_pipe", title = "Half pipe", order = 11, surface = "wood", category = "SkateGM Bowls & pipes",
	info = "Two quarter pipes facing each other across a flat bottom, 256 wide.",
	sizes = sizes,
	build = function(s) return Half(s.r, 256, s.flat) end,
})
