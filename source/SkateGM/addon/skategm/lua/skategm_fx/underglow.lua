local GLOW = BOARD.RegisterEffect({
	id = "underglow", title = "Underglow", order = 1,
	fields = {
		{ key = "on", kind = "bool", convar = "skategm_underglow", default = false, label = "Underglow: a light under the board" },
		{ key = "mode", kind = "choice", convar = "skategm_underglow_mode", choices = BOARD.COLOUR_MODES, default = 1, label = "Underglow colour" },
		{ key = "color", kind = "color", convar = "skategm_underglow_color", default = "0 200 255", label = "Underglow: custom colour", showWhen = { "mode", 3 } },
		{ key = "bright", kind = "number", convar = "skategm_underglow_bright", min = 1, max = 10, default = 5, decimals = 0, label = "Underglow brightness" },
	},
})

if not CLIENT then return end

function GLOW.enabled(o) return o.on == true end

local mat
function GLOW.draw(ctx)
	local o, B = ctx.opts, ctx.B
	local col = ctx.C.FxColour(o.mode, o.color, ctx.ply, ctx.now)
	local bright = o.bright or 5
	if ctx.newFrame and DynamicLight and IsValid(ctx.ply) and ctx.ply.EntIndex then
		local dl = DynamicLight(8192 + ctx.ply:EntIndex())
		if dl then
			dl.pos, dl.r, dl.g, dl.b = B.centre - B.up * 3, col.r, col.g, col.b
			dl.brightness, dl.Decay, dl.Size, dl.DieTime = 0.5 + bright * 0.35, 1000, 70 + bright * 14, CurTime() + 0.1
		end
	end
	mat = mat or Material("sprites/light_glow02_add")
	render.SetMaterial(mat)
	local c = B.centre - B.up * 0.6
	local L, W = B.fwd * (B.half + 10 + bright), B.right * (8 + bright * 0.8)
	local a = Color(col.r, col.g, col.b, math.min(255, 120 + bright * 13))
	render.DrawQuad(c + L + W, c - L + W, c - L - W, c + L - W, a)
	render.DrawQuad(c + L - W, c - L - W, c - L + W, c + L + W, a)
end
