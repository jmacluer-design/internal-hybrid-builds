local S = SkateGM
local L = S.L

---------------------------------------------------------------------------
-- Sound: stock Source/HL2 sounds driven by the engine's own states. The same
-- code runs for every skater you can see (yours, other players', the ghost),
-- positioned on their model so it fades with distance.
---------------------------------------------------------------------------
local cvSounds = CreateClientConVar("skategm_sounds", "1", true, false, "Skateboard sounds", 0, 1)
local cvVolume = CreateClientConVar("skategm_sound_volume", "1", true, false, "Skateboard sound volume", 0, 2)

local function Numbered(fmt, n) local t = {} for i = 1, n do t[i] = string.format(fmt, i) end return t end
local SND = {
	roll       = "physics/plastic/plastic_barrel_scrape_smooth_loop1.wav", -- urethane wheels
	slide      = "physics/plastic/plastic_barrel_scrape_rough_loop1.wav",  -- powerslide
	grindMetal = "physics/metal/metal_box_scrape_smooth_loop1.wav",        -- trucks on a rail/ledge
	grindWood  = "physics/wood/wood_box_scrape_rough_loop1.wav",           -- deck on an edge
	drag       = "physics/concrete/concrete_scrape_smooth_loop1.wav",      -- foot braking
	pop        = Numbered("physics/wood/wood_plank_impact_hard%d.wav", 5),
	land       = Numbered("physics/wood/wood_box_impact_hard%d.wav", 3),
	landHard   = Numbered("physics/wood/wood_crate_impact_hard%d.wav", 5),
	grindOn    = Numbered("physics/metal/metal_solid_impact_hard%d.wav", 5),
	bail       = Numbered("physics/body/body_medium_impact_hard%d.wav", 6),
	clatter    = Numbered("physics/wood/wood_box_impact_soft%d.wav", 3),
	step       = Numbered("player/footsteps/concrete%d.wav", 4),
	-- ragdoll (bails)
	bodyHard   = Numbered("physics/body/body_medium_impact_hard%d.wav", 6),
	bodySoft   = Numbered("physics/body/body_medium_impact_soft%d.wav", 7),
	bodySlide  = "physics/body/body_medium_scrape_smooth_loop1.wav",
	boardHard  = Numbered("physics/wood/wood_box_impact_hard%d.wav", 3),
	boardSoft  = Numbered("physics/wood/wood_box_impact_soft%d.wav", 3),
}

-- bones whose tumbling makes the body sounds during a bail
local RAGDOLL_BONES = { "HEAD", "SPINE2", "HIPS", "RIGHTHAND", "LEFTHAND", "RIGHTFOOT", "LEFTFOOT" }
S.SND = SND

local function Category(state)
	if not state then return "ground" end
	if state == "SlideGround" then return "slide" end
	if string.sub(state, 1, 5) == "Grind" then
		if state == "GrindBoardslide" or state == "GrindTipslide" or state == "GrindDarkslide" then return "woodgrind" end
		return "metalgrind"
	end
	if state == "WipeoutGround" then return "wipeout" end
	if state == "BipedAir" then return "walkair" end
	if string.sub(state, 1, 5) == "Biped" or state == "OffBoardPushing" then return "walk" end
	if string.find(state, "Air", 1, true) then return "air" end
	return "ground" -- PhysicsGround, RevertGround, landings, plants...
end
local ROLLING = { ground = true, slide = true, metalgrind = true, woodgrind = true }

local audio = {} -- skater key -> sound state

local function OneShot(ent, list, vol, pitch)
	if not IsValid(ent) then return end
	local v = vol * cvVolume:GetFloat()
	if v <= 0.01 then return end
	ent:EmitSound(list[math.random(#list)], 75, pitch or math.random(95, 105), math.min(v, 1))
end

local function Loop(A, ent, name, path, on, vol, pitch)
	local L = A.loops[name]
	A.paths = A.paths or {}
	if L and A.paths[name] ~= path then
		L:Stop()
		L, A.loops[name] = nil, nil
	end
	A.paths[name] = path
	if on and cvSounds:GetBool() then
		if not L then
			local ok, snd = pcall(CreateSound, ent, path)
			if not ok or not snd then return end
			L = snd
			A.loops[name] = L
			L:PlayEx(0, pitch)
		elseif not L:IsPlaying() then
			L:PlayEx(0, pitch)
		end
		L:ChangeVolume(math.Clamp(vol * cvVolume:GetFloat(), 0, 1), 0.1)
		L:ChangePitch(math.Clamp(pitch, 30, 250), 0.1)
	elseif L then
		L:FadeOut(0.15)
		A.loops[name] = nil
	end
end

function S.RollSoundFor(key)
	local look = BOARD and BOARD.client and IsValid(key) and key.GetNW2String and BOARD.client.LookFor(key)
	return look and look.rollSound
end

function S.StopSounds(key)
	local A = audio[key]
	if not A then return end
	for _, L in pairs(A.loops) do L:Stop() end
	audio[key] = nil
end


-- Ragdoll sound during a bail: a bone that was falling (or flying) and
-- suddenly stops has hit something. Velocities are smoothed so the steps
-- between other players' network snapshots don't read as hits.
local function RagdollSound(A, ent, P, centre, dt, now)
	A.rag = A.rag or { bones = {}, budget = { body = 3, board = 2 } }
	local R = A.rag
	-- at most ~10 body hits and ~5 board hits a second (the board is its own object)
	R.budget.body = math.min(8, R.budget.body + dt * 10)
	R.budget.board = math.min(4, R.budget.board + dt * 5)
	local function track(key, pos, pool)
		local b = R.bones[key]
		if not b then
			b = { pos = pos, v = Vector(0, 0, 0), fall = 0, peak = 0, next = 0 }
			R.bones[key] = b
			return nil
		end
		local raw = (pos - b.pos) / dt
		b.pos = pos
		if raw:LengthSqr() > 3000 * 3000 then return nil end -- teleport
		b.v = LerpVector(math.min(1, dt * 30), b.v, raw)
		-- remembered peaks fade steadily, so gradual slowing never counts as a hit
		b.fall = math.min(0, b.fall + dt * 800, b.v.z) -- fastest recent fall, fading back towards 0
		local speed = b.v:Length()
		b.peak = math.max(speed, b.peak - dt * 600)
		local hit
		if b.fall < -150 and b.v.z > b.fall * 0.3 then hit = -b.fall end   -- was falling, stopped
		if b.peak > 300 and speed < b.peak * 0.4 then hit = math.max(hit or 0, b.peak) end -- slammed into something
		if hit then
			b.fall, b.peak = b.v.z < 0 and b.v.z or 0, speed
			if now > b.next and R.budget[pool] >= 1 then
				b.next = now + 0.18
				R.budget[pool] = R.budget[pool] - 1
				return hit
			end
		end
		return nil
	end
	for _, name in ipairs(RAGDOLL_BONES) do
		local pos = P[name]
		if pos then
			local hit = track(name, pos, "body")
			if hit and cvSounds:GetBool() then
				OneShot(ent, hit > 500 and SND.bodyHard or SND.bodySoft, math.Clamp(hit / 700, 0.25, 1), math.random(90, 110))
			end
		end
	end
	-- the board bounces on its own
	local hit = track("board", centre, "board")
	if hit and cvSounds:GetBool() then
		OneShot(ent, hit > 400 and SND.boardHard or SND.boardSoft, math.Clamp(hit / 600, 0.25, 0.9), math.random(95, 115))
	end
	-- sliding along the ground: hips moving fast sideways but hardly up or down
	local hips = R.bones.HIPS
	local flat = hips and Vector(hips.v.x, hips.v.y, 0):Length() or 0
	local sliding = hips and flat > 90 and math.abs(hips.v.z) < 70
	Loop(A, ent, "bodySlide", SND.bodySlide, sliding, math.Clamp(flat / 600, 0.1, 0.6), 90 + math.min(flat, 800) * 0.03)
end

-- per frame, per visible skater
function S.UpdateSound(key, ent, P, state, now, stale)
	if not (IsValid(ent) and P and P.HIPS) then return end
	local A = audio[key]
	if not A then
		A = { loops = {}, feet = {}, speed = 0, vz = 0, accel = 0, minVz = 0 }
		audio[key] = A
	end
	local w = P.RIGHT_WHEELFRONT and P.LEFT_WHEELFRONT and P.RIGHT_WHEELBACK and P.LEFT_WHEELBACK
	local centre = w and (P.RIGHT_WHEELFRONT + P.LEFT_WHEELFRONT + P.RIGHT_WHEELBACK + P.LEFT_WHEELBACK) / 4 or P.HIPS
	-- Only react to a pose that actually changed. The engine ticks at 60 Hz, so
	-- at higher frame rates (and on the second update in a frame) the pose is
	-- the same as last time; measuring those frames would read speed as zero.
	-- Unchanged for longer than an engine tick (~17 ms) means it really stopped
	-- (e.g. a ragdoll hitting the ground), so that is processed.
	if A.t and A.hips and (P.HIPS - A.hips):LengthSqr() < 1e-8 and (centre - A.centre):LengthSqr() < 1e-8
		and state == A.state and now - A.t < 0.03 then
		return
	end
	local dt = A.t and now - A.t or 0
	A.t, A.state = now, state
	if A.centre and dt > 1e-4 then
		local speed = (centre - A.centre):Length() / dt
		local hips = P.HIPS - A.hips
		local vz = hips.z / dt
		local hipsFlat = Vector(hips.x, hips.y, 0):Length() / dt
		if speed < 3000 and hipsFlat < 3000 then -- ignore teleports / respawns
			local k = math.min(1, dt * 8)
			local before = A.speed
			A.speed = Lerp(k, A.speed, speed)
			A.walkSpeed = Lerp(k, A.walkSpeed or 0, hipsFlat)
			A.vz = Lerp(math.min(1, dt * 12), A.vz, vz)
			A.accel = Lerp(k, A.accel, (A.speed - before) / dt)
		end
	end
	A.centre, A.hips, A.hipsZ = centre, Vector(P.HIPS.x, P.HIPS.y, P.HIPS.z), P.HIPS.z

	local cat = Category(state)
	local prev = A.cat
	if prev and prev ~= cat and cvSounds:GetBool() then
		if ROLLING[prev] and cat == "air" and A.vz > 40 then
			OneShot(ent, SND.pop, 0.8)                                   -- ollie / pop out
		end
		if prev == "air" and ROLLING[cat] then
			local impact = -A.minVz
			if cat == "metalgrind" or cat == "woodgrind" then
				OneShot(ent, SND.grindOn, 0.6)                           -- locking into a grind
			elseif impact > 80 then
				OneShot(ent, impact > 450 and SND.landHard or SND.land, math.Clamp(impact / 500, 0.35, 1))
			end
		end
		if cat == "wipeout" then
			OneShot(ent, SND.bail, 0.9)
			OneShot(ent, SND.clatter, 0.7)
		end
	end
	if cat == "air" then
		if prev ~= "air" then A.minVz = 0 end
		A.minVz = math.min(A.minVz, A.vz)
	end
	A.cat = cat

	if cat == "wipeout" and dt > 1e-4 then
		-- a late network snapshot freezes a remote skater, which looks like a
		-- sudden stop; don't read hits from those frames
		if not stale then RagdollSound(A, ent, P, centre, dt, now) end
	elseif A.rag then
		A.rag = nil
		Loop(A, ent, "bodySlide", SND.bodySlide, false, 0, 100)
	end

	local sp = A.speed
	Loop(A, ent, "roll", S.RollSoundFor(key) or SND.roll, cat == "ground" and sp > 20, math.Clamp(0.1 + sp / 900, 0.15, 0.65), 60 + math.min(sp, 1400) * 0.05)
	Loop(A, ent, "slide", SND.slide, cat == "slide" and sp > 20, math.Clamp(sp / 500, 0.15, 0.6), 80 + math.min(sp, 1500) * 0.03)
	Loop(A, ent, "grindMetal", SND.grindMetal, cat == "metalgrind", math.Clamp(0.25 + sp / 800, 0.25, 0.7), 85 + math.min(sp, 1800) * 0.03)
	Loop(A, ent, "grindWood", SND.grindWood, cat == "woodgrind", math.Clamp(0.25 + sp / 800, 0.25, 0.7), 80 + math.min(sp, 1800) * 0.03)

	-- Feet. A step is a foot that was swinging coming to rest near the ground;
	-- a planted foot is nearly still in the world (when pushing, the board rolls
	-- away from it), however little it lifted. On the board, only feet off to
	-- the side of it count (pushing, braking), not the ones standing on it.
	local ground
	if ROLLING[cat] and w then
		ground = (P.RIGHT_WHEELFRONT.z + P.LEFT_WHEELFRONT.z + P.RIGHT_WHEELBACK.z + P.LEFT_WHEELBACK.z) / 4 - 1.1
	elseif cat == "walk" or cat == "walkair" then
		local low = math.min((P.RIGHTTOEBASE or P.HIPS).z, (P.LEFTTOEBASE or P.HIPS).z)
		A.walkGround = math.min((A.walkGround or low) + dt * 40, low)
		ground = A.walkGround
	end
	local dragging = false
	for _, name in ipairs({ "RIGHTTOEBASE", "LEFTTOEBASE" }) do
		local f = P[name]
		local F = A.feet[name]
		if type(F) ~= "table" then F = {} A.feet[name] = F end
		if f and F.pos and dt > 1e-4 then
			local v = (f - F.pos) / dt
			if v:LengthSqr() < 3000 * 3000 then F.v = LerpVector(math.min(1, dt * 20), F.v or v, v) end
		end
		F.pos = Vector(f and f.x or 0, f and f.y or 0, f and f.z or 0)
		local speed = F.v and F.v:Length() or 0
		local off = cat == "walk" or (f and Vector(f.x - centre.x, f.y - centre.y, 0):Length() > 9)
		local near = f and ground and off and f.z - ground < 6
		local planted = near and speed < 45
		if speed > 70 or (f and ground and f.z - ground > 6) then F.swung = true end
		if planted and not F.planted and F.swung and cvSounds:GetBool() and (cat == "walk" or ROLLING[cat]) then
			OneShot(ent, SND.step, cat == "walk" and 0.9 or 1.0) -- walking / pushing
			F.swung = false
		end
		F.planted = planted
		-- braking: a foot beside the board, near the ground, sliding along with it
		if near and ROLLING[cat] and speed > 60 then dragging = true end
	end
	-- landing from an off-board jump: both feet
	if prev == "walkair" and cat == "walk" and cvSounds:GetBool() then
		OneShot(ent, SND.step, 1.0)
		OneShot(ent, SND.step, 0.8)
	end
	Loop(A, ent, "drag", SND.drag, dragging and sp > 60 and A.accel < -60, math.Clamp(sp / 500, 0.2, 0.7), 90 + math.min(sp, 1000) * 0.02)
end

L.cvSounds, L.cvVolume = cvSounds, cvVolume
