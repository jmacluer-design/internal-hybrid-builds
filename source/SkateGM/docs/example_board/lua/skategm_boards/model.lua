local MODEL = BOARD.RegisterType({
	id = "model", title = "Any model", order = 2,
	fields = {
		{ key = "path", kind = "model", convar = "skategm_board_model", default = "models/props_debris/wood_board04a.mdl", label = "Model path" },
		{ key = "scale", kind = "number", convar = "skategm_board_model_scale", min = 0.05, max = 4, default = 1, decimals = 2, label = "Scale" },
		{ key = "up", kind = "number", convar = "skategm_board_model_up", min = -48, max = 48, default = 0, decimals = 1, label = "Up / down" },
		{ key = "forward", kind = "number", convar = "skategm_board_model_forward", min = -48, max = 48, default = 0, decimals = 1, label = "Forward / back" },
		{ key = "yaw", kind = "number", convar = "skategm_board_model_yaw", min = -180, max = 180, default = 0, decimals = 0, label = "Turn" },
		{ key = "pitch", kind = "number", convar = "skategm_board_model_pitch", min = -180, max = 180, default = 0, decimals = 0, label = "Tilt (pitch)" },
		{ key = "roll", kind = "number", convar = "skategm_board_model_roll", min = -180, max = 180, default = 0, decimals = 0, label = "Roll" },
		{ key = "wheels", kind = "bool", convar = "skategm_board_model_wheels", default = true, label = "Keep the trucks and wheels" },
	},
	presets = {
		{ "Wooden plank", "models/props_debris/wood_board04a.mdl" },
		{ "Door", "models/props_c17/door01_left.mdl" },
		{ "Car door", "models/props_vehicles/carparts_door01a.mdl" },
		{ "Bathtub", "models/props_interiors/BathTub01a.mdl" },
		{ "Sawblade", "models/props_junk/sawblade001a.mdl" },
		{ "Shopping cart", "models/props_junk/PushCart01a.mdl" },
		{ "Watermelon", "models/props_junk/watermelon01.mdl" },
	},
})

if not CLIENT then return end

MODEL.ents = MODEL.ents or {}

function MODEL.Entity(ply, path)
	local cur = MODEL.ents[ply]
	if cur and cur.path == path and (cur.bad or IsValid(cur.ent)) then return cur.ent end
	if cur and IsValid(cur.ent) then cur.ent:Remove() end
	MODEL.ents[ply] = nil
	if not BOARD.ValidModel(path) or (util.IsValidModel and not util.IsValidModel(path)) then
		MODEL.ents[ply] = { path = path, bad = true }
		return nil
	end
	local ent = ClientsideModel(path, RENDERGROUP_OPAQUE)
	if not IsValid(ent) then return nil end
	ent:SetNoDraw(true)
	MODEL.ents[ply] = { path = path, ent = ent }
	return ent
end

function MODEL.Placement(P, m)
	local tf, tb = P.TRUCK_FRONT, P.TRUCK_BACK
	local rf, lf, rb, lb = P.RIGHT_WHEELFRONT, P.LEFT_WHEELFRONT, P.RIGHT_WHEELBACK, P.LEFT_WHEELBACK
	if not (tf and tb and rf and lf and rb and lb) then return nil end
	local fwd = (tf - tb):GetNormalized()
	local right = ((rf + rb) - (lf + lb)):GetNormalized()
	local up = right:Cross(fwd):GetNormalized()
	local wheels = (rf + lf + rb + lb) / 4
	local mid = (tf + tb) / 2
	local pos = mid - up * (mid - wheels):Dot(up) + up * (2 + (m.up or 0)) + fwd * (m.forward or 0)
	local ang = fwd:AngleEx(up)
	ang:RotateAroundAxis(ang:Up(), m.yaw or 0)
	ang:RotateAroundAxis(ang:Right(), m.pitch or 0)
	ang:RotateAroundAxis(ang:Forward(), m.roll or 0)
	return pos, ang
end

function MODEL.draw(ctx)
	local m = ctx.opts
	local ent = MODEL.Entity(ctx.ply, m.path)
	if not ent then return false end
	local pos, ang = MODEL.Placement(ctx.P, m)
	if not pos then return false end
	ent:SetPos(pos)
	ent:SetAngles(ang)
	if ent.Sk8Scale ~= m.scale then
		ent.Sk8Scale = m.scale
		ent:SetModelScale(m.scale or 1, 0)
	end
	ent:DrawModel()
	local look = ctx.look or {}
	ctx.DrawBoard(ctx.P, { graphic = ctx.graphic, wheel = look.wheels, rocket = ctx.rocket, deck = false, trucks = m.wheels })
	return true
end

-- extra rows on the controller's Settings > Board page (its fields get rows
-- of their own): the presets, as a list to pick from
function MODEL.rows(List)
	local names = {}
	for i, p in ipairs(MODEL.presets) do names[i] = p[1] end
	return { List.Choice("Model", names, function()
		local current = GetConVar("skategm_board_model"):GetString()
		for i, p in ipairs(MODEL.presets) do if p[2] == current then return i end end
		return 1
	end, function(i) RunConsoleCommand("skategm_board_model", MODEL.presets[i][2]) end) }
end

hook.Add("Think", "skategm_board_models", function()
	if RealTime() < (MODEL.nextSweep or 0) then return end
	MODEL.nextSweep = RealTime() + 1
	for ply, m in pairs(MODEL.ents) do
		if not IsValid(ply) then
			if IsValid(m.ent) then m.ent:Remove() end
			MODEL.ents[ply] = nil
		end
	end
end)
