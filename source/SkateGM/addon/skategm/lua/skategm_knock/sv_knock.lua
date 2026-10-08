util.AddNetworkString(KNOCK.NET)

function KNOCK.Knockable(ent)
	if not (IsValid(ent) and KNOCK.cvOn:GetBool() and KNOCK.CLASSES[ent:GetClass()]) then return false end
	if ent.SkateGMMelon or ent.SkateGMPart then return false end
	local phys = ent:GetPhysicsObject()
	if not IsValid(phys) or not phys:IsMotionEnabled() then return false end
	if phys:GetMass() > KNOCK.cvMass:GetFloat() then return false end
	if constraint and constraint.HasConstraints and constraint.HasConstraints(ent) then return false end
	return true
end

-- every half second, tell clients which props are knockable (only while anyone skates)
function KNOCK.Refresh()
	local anyone = false
	for _, p in ipairs(player.GetAll()) do if p.SkateGM then anyone = true break end end
	if not anyone then return end
	for class in pairs(KNOCK.CLASSES) do
		for _, ent in ipairs(ents.FindByClass(class)) do
			local k = KNOCK.Knockable(ent)
			if ent:GetNW2Bool(KNOCK.FLAG, false) ~= k then ent:SetNW2Bool(KNOCK.FLAG, k) end
			if k then
				local m = math.Round(ent:GetPhysicsObject():GetMass())
				if ent:GetNW2Int(KNOCK.MASS, -1) ~= m then ent:SetNW2Int(KNOCK.MASS, m) end
			end
		end
	end
end
timer.Create("skategm_knock_refresh", 0.5, 0, KNOCK.Refresh)

function KNOCK.Hit(ply, ent, vel, now)
	if not (IsValid(ply) and ply.SkateGM and KNOCK.Knockable(ent)) then return false end
	if now - (ent.SkateGMKnockAt or -100) < KNOCK.COOLDOWN then return false end
	local hips = ply.SkateGMHips
	if not hips or ent:NearestPoint(hips):Distance(hips) > KNOCK.SLACK then return false end
	if not (vel and vel.x == vel.x and vel.y == vel.y and vel.z == vel.z) then return false end
	if vel:Length() > KNOCK.MAX_SPEED then vel = vel:GetNormalized() * KNOCK.MAX_SPEED end
	ent.SkateGMKnockAt = now
	local phys = ent:GetPhysicsObject()
	local speed = vel:Length()
	phys:Wake()
	phys:SetVelocity(phys:GetVelocity() + vel * 1.15 + Vector(0, 0, math.min(speed * 0.35, 600)))
	phys:AddAngleVelocity(VectorRand() * math.min(speed, 900))
	if ent.SetPhysicsAttacker then ent:SetPhysicsAttacker(ply, 5) end
	return true
end

net.Receive(KNOCK.NET, function(_, ply)
	local ent = net.ReadEntity()
	local vel = Vector(net.ReadFloat(), net.ReadFloat(), net.ReadFloat())
	KNOCK.Hit(ply, ent, vel, CurTime())
end)
