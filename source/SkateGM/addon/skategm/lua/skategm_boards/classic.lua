local PATTERNS = {
	{ "None" },
	{ "Stripes", "skategm/grip/stripes" },
	{ "Diagonal stripes", "skategm/grip/diagonal" },
	{ "Checkerboard", "skategm/grip/checker" },
	{ "Polka dots", "skategm/grip/dots" },
	{ "Camo", "skategm/grip/camo" },
	{ "Zigzag", "skategm/grip/zigzag" },
	{ "Grid", "skategm/grip/grid" },
	{ "Stars", "skategm/grip/stars" },
}

local CLASSIC = BOARD.RegisterType({
	id = "classic", title = "Skateboard", order = 1, image = true, patterns = PATTERNS,
	fields = {
		{ key = "pattern", kind = "choice", convar = "skategm_grip_pattern", choices = PATTERNS, default = 1, label = "Grip tape pattern" },
		{ key = "pattern_color", kind = "color", convar = "skategm_grip_pattern_color", default = "255 255 255", label = "Pattern colour" },
		{ key = "fit", kind = "choice", convar = "skategm_board_image_fit", choices = { { "Stretch" }, { "Fill" } }, default = 1, label = "Image fit" },
	},
})

if not CLIENT then return end

CLASSIC.mats = CLASSIC.mats or {}
function CLASSIC.Pattern(opts)
	local p = PATTERNS[opts and opts.pattern or 1]
	local path = p and p[2]
	if not path or not Material then return nil end
	local m = CLASSIC.mats[path]
	if m == nil then
		m = Material(path)
		if not m or (m.IsError and m:IsError()) then m = false end
		CLASSIC.mats[path] = m
	end
	return m or nil
end

function CLASSIC.draw(ctx)
	local look, opts = ctx.look or {}, ctx.opts or {}
	local pc = BOARD.ParseColor(opts.pattern_color)
	ctx.DrawBoard(ctx.P, { graphic = ctx.graphic, wheel = look.wheels, under = look.mat, grip = look.deck, rocket = ctx.rocket, trucks = not ctx.hover, underFit = opts.fit == 2,
		pattern = CLASSIC.Pattern(opts), patternColor = pc and Color(pc[1], pc[2], pc[3]) or nil })
	return true
end
