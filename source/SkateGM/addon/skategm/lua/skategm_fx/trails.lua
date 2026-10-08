local STYLES = {
	{ "Off" },
	{ "Neon", "trails/laser" },
	{ "Plasma", "trails/plasma" },
	{ "Electric", "trails/electric" },
	{ "Smoke", "trails/smoke" },
	{ "Tube", "trails/tube" },
	{ "Physgun beam", "trails/physbeam" },
	{ "Hearts", "trails/love" },
	{ "LOL", "trails/lol" },
}

local TRAIL = BOARD.RegisterEffect({
	id = "trails", title = "Trails", order = 2, styles = STYLES,
	fields = {
		{ key = "style", kind = "choice", convar = "skategm_trail", choices = STYLES, default = 1, label = "Trail" },
		{ key = "mode", kind = "choice", convar = "skategm_trail_mode", choices = BOARD.COLOUR_MODES, default = 1, label = "Trail colour" },
		{ key = "color", kind = "color", convar = "skategm_trail_color", default = "255 60 200", label = "Trail: custom colour", showWhen = { "mode", 3 } },
		{ key = "length", kind = "number", convar = "skategm_trail_length", min = 0.2, max = 3, default = 0.8, decimals = 1, label = "Trail length (seconds)" },
		{ key = "width", kind = "number", convar = "skategm_trail_width", min = 1, max = 16, default = 4, decimals = 0, label = "Trail width" },
	},
})

if not CLIENT then return end

TRAIL.MAX_POINTS = 120
TRAIL.mats = TRAIL.mats or {}

function TRAIL.enabled(o) return (o.style or 1) > 1 end

function TRAIL.Sources(B)
	local lift = B.up * 0.8
	return { B.rb + lift, B.lb + lift }
end

function TRAIL.Record(data, B, now, length, jumped)
	local pts = data.points or {}
	data.points = pts
	if jumped then for i = #pts, 1, -1 do pts[i] = nil end end
	local src = TRAIL.Sources(B)
	local last = pts[#pts]
	if not last or (src[1] - last[1]):LengthSqr() > 1 then
		pts[#pts + 1] = { src[1], src[2], now }
		if #pts > TRAIL.MAX_POINTS then table.remove(pts, 1) end
	else
		last[1], last[2], last[3] = src[1], src[2], now
	end
	while pts[1] and now - pts[1][3] > length do table.remove(pts, 1) end
	return pts
end

function TRAIL.draw(ctx)
	local o = ctx.opts
	local style = TRAIL.styles[o.style or 1]
	if not (style and style[2]) then return end
	local length = o.length or 0.8
	local pts = ctx.newFrame and TRAIL.Record(ctx.data, ctx.B, ctx.now, length, ctx.jumped) or ctx.data.points or {}
	if #pts < 2 then return end
	local m = TRAIL.mats[style[2]]
	if not m then m = Material(style[2]) TRAIL.mats[style[2]] = m end
	render.SetMaterial(m)
	local width = (o.width or 4) * math.Clamp(0.4 + ctx.speed / 400, 0.4, 1.3)
	for side = 1, 2 do
		render.StartBeam(#pts)
		for i, p in ipairs(pts) do
			local age = (ctx.now - p[3]) / length
			local col = ctx.C.FxColour(o.mode, o.color, ctx.ply, p[3], side * 40)
			col = Color(col.r, col.g, col.b, math.Clamp(255 * (1 - age), 0, 255))
			render.AddBeam(p[side], width * (1 - age * 0.6), i / #pts, col)
		end
		render.EndBeam()
	end
end
