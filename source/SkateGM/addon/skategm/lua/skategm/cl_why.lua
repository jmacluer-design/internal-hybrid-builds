local S = SkateGM
local L = S.L
local PASS, SOURCE_NAMES, Say = L.PASS, L.SOURCE_NAMES, L.Say

---------------------------------------------------------------------------
-- skategm_why: aim at something and ask whether the skater collides with it
---------------------------------------------------------------------------
concommand.Add("skategm_why", function()
	local me = LocalPlayer()
	local origin = S.phase == "on" and S.view and S.view.origin or me:EyePos()
	local dir = (S.phase == "on" and S.view and S.view.angles or me:EyeAngles()):Forward()
	local tr = util.TraceLine({ start = origin, endpos = origin + dir * 6000, filter = me, mask = MASK_PLAYERSOLID })
	if not tr.Hit then Say("skategm_why: not aiming at anything solid for players", true) return end
	local e = tr.Entity
	local what, reason
	if IsValid(e) then
		local cls, mdl = e:GetClass(), e:GetModel() or "?"
		what = string.format("%s  %s", cls, mdl)
		local sf = e:GetSolidFlags()
		if e:IsPlayer() or e:IsNPC() then reason = "players and NPCs become a person-sized block only while you skate near them (skategm_player_collision)"
		elseif e:GetSolid() == SOLID_NONE or bit.band(sf, bit.bor(FSOLID_NOT_SOLID, FSOLID_TRIGGER)) ~= 0 then reason = "the game says it isn't solid"
		elseif PASS[e:GetCollisionGroup()] then reason = "its collision group is one players walk through (debris etc.)"
		elseif S.tiny and S.tiny[string.lower(mdl)] then reason = "it's tiny clutter, left out on purpose (skategm_tiny_props_solid 1 makes it solid)"
		elseif S.boxed and S.boxed[string.lower(mdl)] then reason = "no physics model: it collides as its bounding box" end
	else
		local studio = tr.HitTexture == "**studio**"
		what = studio and "a static prop (part of the map)" or string.format("map brush / displacement, surface %s", tr.HitTexture or "?")
		if not studio and skategm and skategm.Diagnose then
			local lines = skategm.Diagnose(tr.HitPos.x, tr.HitPos.y, tr.HitPos.z, tr.HitNormal.x, tr.HitNormal.y, tr.HitNormal.z)
			for _, l in ipairs(lines) do print("[SkateGM]   " .. l) end
			reason = lines[1]
		end
		if studio and skategm and skategm.StaticPropsNear then
			local near = skategm.StaticPropsNear(tr.HitPos.x, tr.HitPos.y, tr.HitPos.z, 400)
			local sp = near[1]
			if sp then
				what = string.format("static prop %s [%s]", sp.model, sp.solid)
				reason = sp.status
				local fromI = S.shapeFrom and (S.shapeFrom[sp.model] or S.shapeFrom[sp.model .. "#bbox"])
				if fromI then reason = reason .. "; shape: " .. fromI end
				for i, o in ipairs(near) do print(string.format("[SkateGM]   nearby static prop %d: %s [%s] %s (%.0f units away)", i, o.model, o.solid, o.status, o.distance)) end
			end
		end
	end
	-- is there skater collision right there?
	local inCol, tagName = false, nil
	if skategm and skategm.CollisionNear and S.phase == "on" then
		local t, tags = skategm.CollisionNear(tr.HitPos.x, tr.HitPos.y, tr.HitPos.z, 20, 400)
		for i = 1, #t - 8, 9 do
			local a, b, c = Vector(t[i], t[i + 1], t[i + 2]), Vector(t[i + 3], t[i + 4], t[i + 5]), Vector(t[i + 6], t[i + 7], t[i + 8])
			local n = (b - a):Cross(c - a):GetNormalized()
			if math.abs((tr.HitPos - a):Dot(n)) < 3 then inCol, tagName = true, SOURCE_NAMES[tags[(i - 1) / 9 + 1] or 0] break end
		end
	end
	print("[SkateGM] skategm_why: " .. what)
	if S.phase ~= "on" then
		Say("skategm_why: turn Skater mode on first to check the skater's collision", true)
	elseif inCol then
		Say("skategm_why: " .. what .. " - IS solid to the skater (" .. tostring(tagName) .. ")")
	else
		Say("skategm_why: " .. what .. " - NOT in the skater's collision" .. (reason and (": " .. reason) or ""), true)
	end
end)


---------------------------------------------------------------------------
-- Pass-through detector: if the skater goes through something that's solid
-- for GMod players but not in the skater's collision, say what it was (once),
-- so it can be fixed. Intentional exclusions (tiny clutter, water, players,
-- teleports) are ignored.
---------------------------------------------------------------------------
function S.PassThrough(now)
	if S.phase ~= "on" or not (S.P and S.P.HIPS and S.anchor) or not (skategm and skategm.CollisionNear) then S.passLast = nil return end
	-- ten checks a second, each along the path since the last one (every
	-- frame would be wasted work: this only has to notice, not be instant)
	if now < (S.passCheckAt or 0) then return end
	S.passCheckAt = now + 0.1
	local points = { S.P.HIPS, S.anchor + Vector(0, 0, 4) }
	local last = S.passLast
	S.passLast = { Vector(points[1].x, points[1].y, points[1].z), Vector(points[2].x, points[2].y, points[2].z) }
	if not last or now < S.passNext then return end
	for i = 1, 2 do
		local a, b = last[i], points[i]
		local d = (b - a):Length()
		if d > 1 and d < 400 then -- a normal move (a tenth of a second), not a teleport
			local tr = util.TraceLine({ start = a, endpos = b, mask = MASK_PLAYERSOLID, filter = LocalPlayer() })
			if tr.Hit and not tr.HitSky and not tr.StartSolid then
				local e = tr.Entity
				local skip = IsValid(e) and (e:IsPlayer() or e:IsNPC() or (S.tiny and S.tiny[string.lower(e:GetModel() or "")]))
				local has
				if skategm.CollisionHas then
					has = skip or skategm.CollisionHas(tr.HitPos.x, tr.HitPos.y, tr.HitPos.z, 16)
				else
					has = skip or #skategm.CollisionNear(tr.HitPos.x, tr.HitPos.y, tr.HitPos.z, 16, 200) > 0
				end
				if not has then
					local what, key
					if IsValid(e) then
						what = string.format("%s %s (solid %d, group %d)", e:GetClass(), e:GetModel() or "?", e:GetSolid(), e:GetCollisionGroup())
						key = e:GetClass() .. (e:GetModel() or "")
					elseif tr.HitTexture == "**studio**" and skategm.StaticPropsNear then
						local sp = skategm.StaticPropsNear(tr.HitPos.x, tr.HitPos.y, tr.HitPos.z, 400)[1]
						local fromI = sp and S.shapeFrom and (S.shapeFrom[sp.model] or S.shapeFrom[sp.model .. "#bbox"])
						what = sp and string.format("static prop %s [%s] - %s%s", sp.model, sp.solid, sp.status, fromI and ("; shape: " .. fromI) or "") or "a static prop"
						key = sp and sp.model or "studio"
						if sp and S.tiny and S.tiny[sp.model] then what = nil end
					else
						what = string.format("map surface %s", tr.HitTexture or "?")
						key = tr.HitTexture or "?"
						if skategm.Diagnose then
							local lines = skategm.Diagnose(tr.HitPos.x, tr.HitPos.y, tr.HitPos.z, tr.HitNormal.x, tr.HitNormal.y, tr.HitNormal.z)
							for _, l in ipairs(lines) do print("[SkateGM]   " .. l) end
							if lines[1] then what = what .. " (" .. lines[1] .. ")" end
						end
					end
					if what and not S.passSeen[key] then
						S.passSeen[key] = true
						S.passNext = now + 3
						print(string.format("[SkateGM] PASSED THROUGH: %s at %.0f %.0f %.0f (map %s)", what, tr.HitPos.x, tr.HitPos.y, tr.HitPos.z, game.GetMap()))
						Say("your skater went through " .. what .. ", which players collide with", true)
						return
					end
				end
			end
		end
	end
end
