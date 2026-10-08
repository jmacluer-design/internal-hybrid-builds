local P = SKATEGM_PARTS
-- a flat slope rising `h` over `len`, `w` wide, with a short deck behind its
-- top edge (an edge that drops straight off is a rail the board grinds by
-- itself): the deck's edge meets a deck as high
P.Family({
	id = "bank", title = "Bank", order = 3, surface = "concrete", category = "SkateGM Ramps",
	info = "A flat slope; its top edge snaps to a deck as high.",
	sizes = {
		{ key = "24", title = "24 high", len = 64, h = 24, w = 128 },
		{ key = "48", title = "48 high", len = 112, h = 48, w = 128 },
		{ key = "72", title = "72 high", len = 160, h = 72, w = 128 },
	},
	build = function(s) return { P.Prism("y", { { 0, 0 }, { s.len + 16, 0 }, { s.len + 16, s.h }, { s.len, s.h } }, 0, s.w) } end,
})
