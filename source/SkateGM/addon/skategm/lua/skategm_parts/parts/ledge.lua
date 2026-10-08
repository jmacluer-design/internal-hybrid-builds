local P = SKATEGM_PARTS
P.Family({
	id = "ledge", title = "Ledge", order = 30, category = "SkateGM Ledges & rails",
	info = "A concrete ledge to grind and slide.",
	sizes = {
		{ title = "16 high, 128 long", len = 128, h = 16, w = 24 },
		{ key = "long", title = "12 high, 256 long", len = 256, h = 12, w = 24 },
		{ key = "tall", title = "24 high, 192 long", len = 192, h = 24, w = 32 },
	},
	build = function(s) return { P.Box(0, 0, 0, s.len, s.w, s.h) } end,
})
