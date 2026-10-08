local P = SKATEGM_PARTS
P.Family({
	id = "funbox", title = "Funbox", order = 4, category = "SkateGM Ramps",
	info = "Ramps up both ends and a flat top; its edges grind.",
	sizes = {
		{ title = "24 high", len = 256, h = 24, top = 128, w = 96 },
		{ key = "large", title = "large, 36 high", len = 384, h = 36, top = 192, w = 160 },
	},
	build = function(s)
		local a = (s.len - s.top) / 2
		return { P.Prism("y", { { 0, 0 }, { s.len, 0 }, { s.len - a, s.h }, { a, s.h } }, 0, s.w) }
	end,
})
