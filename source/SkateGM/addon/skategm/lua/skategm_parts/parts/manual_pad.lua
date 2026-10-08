local P = SKATEGM_PARTS
P.Family({
	id = "manual_pad", title = "Manual pad", order = 31, surface = "paint", category = "SkateGM Ledges & rails",
	info = "A low, wide box for manuals.",
	sizes = {
		{ title = "6 high", len = 128, w = 64, h = 6 },
		{ key = "large", title = "large, 8 high", len = 192, w = 96, h = 8 },
	},
	build = function(s) return { P.Box(0, 0, 0, s.len, s.w, s.h) } end,
})
