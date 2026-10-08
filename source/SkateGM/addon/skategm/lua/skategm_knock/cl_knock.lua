KNOCK.recent = KNOCK.recent or {}

function KNOCK.Flagged(e) return IsValid(e) and e.GetNW2Bool and e:GetNW2Bool(KNOCK.FLAG, false) == true end

-- the skater's touch points: the board (trucks, wheels) and the body
function KNOCK.Points(P)
	local out = {}
	for _, name in ipairs({ "TRUCK_FRONT", "TRUCK_BACK", "RIGHT_WHEELFRONT", "LEFT_WHEELFRONT", "RIGHT_WHEELBACK", "LEFT_WHEELBACK" }) do
		if P[name] then out[#out + 1] = { P[name], KNOCK.BOARD_PAD } end
	end
	for _, name in ipairs({ "HIPS", "SPINE2", "HEAD", "RIGHTFOOT", "LEFTFOOT", "RIGHTHAND", "LEFTHAND" }) do
		if P[name] then out[#out + 1] = { P[name], KNOCK.BODY_PAD } end
	end
	return out
end

function KNOCK.Touching(e, points)
	for _, p in ipairs(points) do
		if e:NearestPoint(p[1]):Distance(p[1]) <= p[2] then return true end
	end
	return false
end

function KNOCK.Register()
	local S = SkateGM
	if not S then return nil end
	S.EntitySkippers = S.EntitySkippers or {}
	for _, f in ipairs(S.EntitySkippers) do if f == KNOCK.Skip then return S end end
	S.EntitySkippers[#S.EntitySkippers + 1] = KNOCK.Skip
	return S
end

function KNOCK.Think(now)
	local S = KNOCK.Register()
	if not (S and S.phase == "on" and S.P and S.P.HIPS and KNOCK.cvOn:GetBool()) then return end
	local a = S.API
	local points
	for _, e in ipairs(ents.FindInSphere(S.P.HIPS, 160)) do
		if KNOCK.Flagged(e) and now - (KNOCK.recent[e] or -100) >= KNOCK.COOLDOWN then
			points = points or KNOCK.Points(S.P)
			if KNOCK.Touching(e, points) then
				KNOCK.recent[e] = now
				local v = a.Velocity() or Vector(0, 0, 0)
				net.Start(KNOCK.NET)
				net.WriteEntity(e)
				net.WriteFloat(v.x) net.WriteFloat(v.y) net.WriteFloat(v.z)
				net.SendToServer()
				local k = 0.0254 * (S.loadedScale or 1)
				local loss = KNOCK.SpeedLoss(e:GetNW2Int(KNOCK.MASS, 10))
				if v:LengthSqr() > 1 and a.Launch then a.Launch(-v * k * loss) end
			end
		end
	end
	for e, t in pairs(KNOCK.recent) do
		if not IsValid(e) or now - t > 5 then KNOCK.recent[e] = nil end
	end
end

function KNOCK.Skip(e) return KNOCK.cvOn:GetBool() and KNOCK.Flagged(e) end

hook.Add("Think", "skategm_knock", function() KNOCK.Think(RealTime()) end)
