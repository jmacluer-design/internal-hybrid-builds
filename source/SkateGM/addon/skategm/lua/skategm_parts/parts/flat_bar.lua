local P = SKATEGM_PARTS
-- a round rail `h` up on posts, one post about every 128 units
local function Bar(len, h)
	local pieces = { P.Pipe("x", 0, len, 0, h, 1.2) }
	local posts = math.max(2, math.floor(len / 128) + 1)
	for i = 0, posts - 1 do
		local x = 14 + (len - 32) * i / (posts - 1)
		pieces[#pieces + 1] = P.Box(x, -1, 0, x + 4, 1, h - 1)
	end
	return pieces
end
P.Family({
	id = "flat_bar", title = "Flat bar", order = 32, surface = "metal", category = "SkateGM Ledges & rails",
	info = "A low round rail on posts.",
	sizes = {
		{ title = "160 long", len = 160, h = 14 },
		{ key = "long", title = "320 long", len = 320, h = 14 },
		{ key = "high", title = "high, 24 up", len = 192, h = 24 },
	},
	build = function(s) return Bar(s.len, s.h) end,
})
