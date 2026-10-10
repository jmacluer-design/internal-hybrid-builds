-- Web Swing: client side. Reconciling the predicted web with the server's, where the rope
-- starts (the hand), drawing everyone's webs, and the diagnostic commands.

if not CLIENT then return end

local WS = WebSwing
local M = WS.Math
local T = WS.T
local CCV = WS.CCV
local Guard = WS.Guard

WS.Client = WS.Client or {}
local CL = WS.Client
CL.lastWebAt = CL.lastWebAt or -100
CL.probe = CL.probe or { ok = false, kind = 0, x = 0, y = 0, z = 0, dist = 0, at = -100 }

local sin, exp, floor, min, max, pi = math.sin, math.exp, math.floor, math.min, math.max, math.pi
local clamp = M.clamp

---------------------------------------------------------------------------
-- What to draw for a player: the local player's own predicted/board state, or
-- the server's word (NW2) for everyone else - and for the local player when the
-- client is not predicting at all (singleplayer).
---------------------------------------------------------------------------
local V = { mode = 0, dive = false, ax = 0, ay = 0, az = 0, L = 0, t0 = 0, age = 0, tension = 0, ledge = false, source = "" }
local function FromState(S, src)
	V.mode = S.mode
	V.dive = S.dive
	if S.mode ~= 0 then
		local x, y, z = WS.AnchorXYZ(S)
		V.ax, V.ay, V.az = x, y, z
		V.L, V.t0, V.ledge = S.L, S.t0, S.zledge
		-- (our own web is timed on the frame clock: prediction runs ahead of CurTime, and the
		-- web should leave the hand the moment the button goes down)
		V.age = RealTime() - S.rt0
	end
	V.tension = S.tension
	V.source = src
	return V
end

function WS.ViewState(ply)
	V.mode, V.dive, V.tension, V.ledge, V.source = 0, false, 0, false, ""
	if ply == LocalPlayer() then
		local B = WS.SkateGM.Board
		if B and B.Active() then return FromState(B.S, "board") end
		local S = ply.WSS
		if S and (S.mode ~= 0 or S.dive) and CurTime() - S.tickAt < 0.25 then return FromState(S, "predicted") end
	end
	V.dive = ply:GetNW2Bool("ws_dive", false)
	local mode = ply:GetNW2Int("ws_mode", 0)
	if mode == 0 then return V end
	V.mode = mode
	V.source = "server"
	local ent = ply:GetNW2Entity("ws_ent")
	if IsValid(ent) and not ent:IsWorld() then
		local w = ent:LocalToWorld(ply:GetNW2Vector("ws_local"))
		V.ax, V.ay, V.az = w.x, w.y, w.z
	else
		local a = ply:GetNW2Vector("ws_anchor")
		if WS.SkateGM.IsSkating(ply) then a = WS.SkateGM.FromAbs(a) end
		V.ax, V.ay, V.az = a.x, a.y, a.z
	end
	V.L = ply:GetNW2Float("ws_len", 0)
	V.t0 = ply:GetNW2Float("ws_t0", 0)
	V.age = CurTime() - V.t0
	V.tension = ply:GetNW2Float("ws_tension", 0)
	V.ledge = ply:GetNW2Bool("ws_ledge", false)
	return V
end

---------------------------------------------------------------------------
-- Where the rope leaves the hand
---------------------------------------------------------------------------
function WS.HandPos(ply)
	if WS.SkateGM.IsSkating(ply) then
		local x, y, z = WS.SkateGM.HandPos(ply)
		if x then return x, y, z end
	end
	if ply == LocalPlayer() and not ply:ShouldDrawLocalPlayer() then
		-- first person: the viewmodel's muzzle attachment if the model has one (the stock
		-- arms do not), otherwise a spot at the lower right of the view
		local vm = ply:GetViewModel(0)
		if IsValid(vm) then
			local att = vm:LookupAttachment("muzzle")
			if att and att > 0 then
				local a = vm:GetAttachment(att)
				if a then return a.Pos.x, a.Pos.y, a.Pos.z end
			end
		end
		local eye, ang = ply:EyePos(), ply:EyeAngles()
		local f, r, u = ang:Forward(), ang:Right(), ang:Up()
		return eye.x + f.x * 14 + r.x * 7 - u.x * 8, eye.y + f.y * 14 + r.y * 7 - u.y * 8, eye.z + f.z * 14 + r.z * 7 - u.z * 8
	end
	local att = ply:LookupAttachment("anim_attachment_RH")
	if att and att > 0 then
		local a = ply:GetAttachment(att)
		if a then return a.Pos.x, a.Pos.y, a.Pos.z end
	end
	local bone = ply:LookupBone("ValveBiped.Bip01_R_Hand")
	if bone then
		local p = ply:GetBonePosition(bone)
		if p then return p.x, p.y, p.z end
	end
	local e = ply:GetShootPos()
	local ang = ply:EyeAngles()
	local r = ang:Right()
	return e.x + r.x * 6, e.y + r.y * 6, e.z - 8
end

---------------------------------------------------------------------------
-- Reconcile: the client predicts the web; the server is the truth
---------------------------------------------------------------------------
-- The server's NW2 state arrives a round trip after the client attached, so a mismatch is
-- normal for that long. Only a mismatch that outlasts the grace period (ping-based) means the
-- server decided differently (it snapped the web, the entity was gone, a different anchor
-- was hit): then the client takes the server's state.
local mismatchSince
local function Adopt(lp, S, nwMode)
	S.mode = nwMode
	S.dive = lp:GetNW2Bool("ws_dive", false)
	if nwMode ~= 0 then
		local ent = lp:GetNW2Entity("ws_ent")
		local a = lp:GetNW2Vector("ws_anchor")
		S.ent = (IsValid(ent) and not ent:IsWorld()) and ent or nil
		S.ax, S.ay, S.az = a.x, a.y, a.z
		if S.ent then local l = lp:GetNW2Vector("ws_local") S.lv.x, S.lv.y, S.lv.z = l.x, l.y, l.z end
		S.L = lp:GetNW2Float("ws_len", S.L)
		S.t0 = lp:GetNW2Float("ws_t0", CurTime())
		S.t = math.max(0, CurTime() - S.t0)
		S.rt0 = RealTime() - S.t
		S.zledge = lp:GetNW2Bool("ws_ledge", false)
	else
		S.ent = nil
	end
end

hook.Add("Think", "webswing_reconcile", Guard("Think", function()
	local lp = LocalPlayer()
	if not IsValid(lp) then return end
	local now = CurTime()
	local nwMode = lp:GetNW2Int("ws_mode", 0)
	if nwMode ~= 0 or lp:GetNW2Bool("ws_dive", false) then CL.lastWebAt = now end
	local B = WS.SkateGM.Board
	if B and B.Active() then CL.lastWebAt = now end
	local S = lp.WSS
	if not S then return end
	if (S.mode ~= 0 or S.dive) then CL.lastWebAt = math.max(CL.lastWebAt, S.lastUse) end
	if now - S.tickAt > 0.25 then mismatchSince = nil return end -- not predicting (singleplayer): nothing to reconcile
	if WS.SkateGM.IsSkating(lp) then mismatchSince = nil return end -- board mode: this client is the authority
	local nwDive = lp:GetNW2Bool("ws_dive", false)
	local differs = S.mode ~= nwMode or S.dive ~= nwDive
	if not differs and S.mode == 1 and not S.ent then
		-- same mode: the same anchor? (a prop that moved the web is fine; a different hit is not)
		local a = lp:GetNW2Vector("ws_anchor")
		if (a.x - S.ax) ^ 2 + (a.y - S.ay) ^ 2 + (a.z - S.az) ^ 2 > 24 * 24 and S.t > 0.5 then differs = true end
	end
	if not differs then mismatchSince = nil return end
	mismatchSince = mismatchSince or now
	local grace = 0.3 + lp:Ping() / 1000 * 2
	if now - mismatchSince > grace then
		if CCV.debug:GetBool() then print(string.format("[WebSwing] reconcile: predicted mode %d, server %d: taking the server's", S.mode, nwMode)) end
		Adopt(lp, S, nwMode)
		mismatchSince = nil
	end
end))

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
local matRope = Material("cable/rope")
local matGlow = Material("sprites/light_glow02_add")
local ropeColor = Color(235, 240, 255, 255)
local zipColor = Color(200, 230, 255, 255)
local tmp = Vector()
local nearColor = Color(255, 255, 255, 255)

local function DrawWeb(ply, now)
	local V = WS.ViewState(ply)
	local mode = V.mode
	local hx, hy, hz
	if mode == 0 then
		-- a web that just missed: a short flick toward where it was aimed
		local S = (ply == LocalPlayer()) and (WS.SkateGM.Board.Active() and WS.SkateGM.Board.S or ply.WSS) or nil
		if not S or now - S.whiffT > 0.18 or S.whiffT < 0 then return end
		hx, hy, hz = WS.HandPos(ply)
		local k = clamp((now - S.whiffT) / 0.18, 0, 1) -- (prediction runs ahead of CurTime: never negative)
		local dx, dy, dz = (S.whiffX - hx) * 0.35, (S.whiffY - hy) * 0.35, (S.whiffZ - hz) * 0.35
		ropeColor.a = floor(255 * (1 - k))
		render.SetMaterial(matRope)
		render.StartBeam(2)
		tmp.x, tmp.y, tmp.z = hx, hy, hz
		render.AddBeam(tmp, 1.2, 0, ropeColor)
		tmp.x, tmp.y, tmp.z = hx + dx * (0.4 + k), hy + dy * (0.4 + k), hz + dz * (0.4 + k)
		render.AddBeam(tmp, 0.6, 1, ropeColor)
		render.EndBeam()
		ropeColor.a = 255
		return
	end
	hx, hy, hz = WS.HandPos(ply)
	local ax, ay, az = V.ax, V.ay, V.az
	local dx, dy, dz = ax - hx, ay - hy, az - hz
	local dist = M.len(dx, dy, dz)
	if dist < 8 then return end
	local age = V.age
	local frac = (mode == 2) and 1 or clamp(age / 0.07, 0, 1) -- the web travels out to the anchor
	local ex, ey, ez = hx + dx * frac, hy + dy * frac, hz + dz * frac
	local width = 1.6 * CCV.rope_width:GetFloat() * (mode == 2 and 1.7 or 1)
	local segs = clamp(floor(dist / 140), 5, 22)
	local sag = M.sagAmount(dist, V.L, 90) * CCV.rope_sag:GetFloat() * frac
	local wobAmp = CCV.rope_wobble:GetFloat() * 10 * exp(-max(age, 0) * 3.5)
	if mode == 2 then sag, wobAmp = 0, 0 end
	-- a direction perpendicular to the rope for the wobble
	local nx, ny, nz = M.norm(dx, dy, dz)
	local px, py, pz = M.cross(nx, ny, nz, 0, 0, 1)
	local pl = M.len(px, py, pz)
	if pl < 1e-3 then px, py, pz = 1, 0, 0 else px, py, pz = px / pl, py / pl, pz / pl end
	render.SetMaterial(matRope)
	local col = mode == 2 and zipColor or ropeColor
	render.StartBeam(segs + 1)
	for i = 0, segs do
		local t = i / segs
		local x, y, z = hx + (ex - hx) * t, hy + (ey - hy) * t, hz + (ez - hz) * t
		local w = sin(t * pi) * wobAmp * sin(now * 22 + t * 9)
		tmp.x, tmp.y, tmp.z = x + px * w, y + py * w, z + pz * w - M.sagOffset(t, sag)
		render.AddBeam(tmp, width, t * dist / 64, col)
	end
	render.EndBeam()
	if frac >= 1 then
		render.SetMaterial(matGlow)
		tmp.x, tmp.y, tmp.z = ax, ay, az
		render.DrawSprite(tmp, 14, 14, nearColor)
	end
end

local function DrawAll(depth, skybox, skybox3d)
	if depth or skybox or skybox3d then return end
	local now = CurTime()
	if player.Iterator then
		for _, ply in player.Iterator() do
			if ply:Alive() and not ply:IsDormant() then DrawWeb(ply, now) end
		end
	else
		for _, ply in ipairs(player.GetAll()) do
			if ply:Alive() and not ply:IsDormant() then DrawWeb(ply, now) end
		end
	end
end
hook.Add("PostDrawTranslucentRenderables", "webswing_rope", Guard("PostDrawTranslucentRenderables", DrawAll))

---------------------------------------------------------------------------
-- Console: status and a self-test for the first run
---------------------------------------------------------------------------
local function Say(good, fmt, ...)
	local msg = string.format(fmt, ...)
	MsgC(good == true and Color(120, 255, 160) or (good == false and Color(255, 120, 100) or Color(200, 200, 200)), msg .. "\n")
end

concommand.Add("ws_status", function()
	local lp = LocalPlayer()
	local C = WS.SkateGM
	Say(nil, "[WebSwing] v%s  enabled=%s  range=%d  assist=%s  boost x%.2f  swing gravity x%.2f", WS.VERSION, tostring(T.enabled), T.maxDist, tostring(T.assist), T.boostMult, T.gravityScale)
	local S = lp.WSS
	if S then
		Say(nil, "  foot: mode=%d dive=%s rope=%.0f tension=%.2fg  last predicted tick %.2fs ago", S.mode, tostring(S.dive), S.L, S.tension, CurTime() - S.tickAt)
	else
		Say(nil, "  foot: no web used yet (hold the Web Shooters and click)")
	end
	Say(nil, "  server says: mode=%d dive=%s", lp:GetNW2Int("ws_mode", 0), tostring(lp:GetNW2Bool("ws_dive", false)))
	local api = C.API()
	if not api then
		Say(nil, "  SkateGM: not installed (that is fine: foot mode only)")
	else
		local B = C.Board
		Say(nil, "  SkateGM: installed. skating=%s  state=%s  speed=%.1f m/s", tostring(api.IsSkating()), tostring(api.State and api.State() or "?"), api.Speed and api.Speed() or -1)
		Say(B.err == nil, "  board web: mode=%d  pushes accepted=%d rejected=%d  %s", B.S.mode, B.pushes, B.rejected, B.err and ("DISABLED: " .. B.err) or "ok")
		Say(nil, "  board inputs: fire=%s zip=%s dive=%s reel=%s  (ignored because: %s)", tostring(B.keys.fire), tostring(B.keys.zip), tostring(B.keys.dive), tostring(B.keys.reel), tostring(B.blockedBy or "nothing"))
	end
	Say(WS.lastError == nil, "  last error: %s", tostring(WS.lastError))
end, nil, "Web Swing: client status")

concommand.Add("ws_selftest", function()
	Say(nil, "[WebSwing] self-test (checks this game, not the swing feel)")
	local lp = LocalPlayer()
	-- math runs in GMod's Lua
	do
		local g, dt, L = 600, 1 / 66, 1000
		local px, py, pz, vx, vy, vz = 866, 0, 1000, 0, 0, 0
		local ax, ay, az = 0, 0, 1500
		local worst = 0
		for i = 1, 660 do
			vx, vy, vz = M.constrain(px, py, pz, vx, vy, vz, ax, ay, az, L, dt, g)
			vz = vz - 0.5 * g * dt
			px, py, pz = px + vx * dt, py + vy * dt, pz + vz * dt
			vz = vz - 0.5 * g * dt
			worst = max(worst, M.dist(px, py, pz, ax, ay, az) - L)
		end
		Say(worst < 0.01, "  rope math: 10 s pendulum, worst over-length %.2e units", worst)
	end
	for _, name in ipairs({ "cable/rope", "sprites/light_glow02_add" }) do
		local m = Material(name)
		Say(not m:IsError(), "  material %s: %s", name, m:IsError() and "MISSING (the rope falls back to the error texture)" or "ok")
	end
	local seen = {}
	for _, path in pairs(WS.SOUNDS) do
		if not seen[path] then
			seen[path] = true
			local ok = file.Exists("sound/" .. path, "GAME")
			Say(ok, "  sound %s: %s", path, ok and "ok" or "missing (that sound is just silent)")
		end
	end
	local okm = file.Exists("models/weapons/c_arms.mdl", "GAME")
	Say(okm, "  viewmodel models/weapons/c_arms.mdl: %s", okm and "ok" or "missing (the SWEP would have no hands)")
	local att = lp:LookupAttachment("anim_attachment_RH")
	local bone = lp:LookupBone("ValveBiped.Bip01_R_Hand")
	Say(att > 0 or bone ~= nil, "  your player model: hand attachment %s, hand bone %s", att > 0 and "yes" or "no", bone and "yes" or "no")
	local needed = { "ws_enabled", "ws_max_dist", "ws_assist", "ws_boost", "ws_gravity_scale", "ws_hud" }
	for _, n in ipairs(needed) do Say(GetConVar(n) ~= nil, "  convar %s: %s", n, GetConVar(n) and "ok" or "MISSING") end
	local C = WS.SkateGM
	local api = C.API()
	if api then
		for _, fn in ipairs({ "IsSkating", "IsLoading", "State", "SkaterPos", "Velocity", "Launch", "Tick", "View", "PoseOf", "StartSkating", "CanSkate" }) do
			Say(type(api[fn]) == "function", "  SkateGM.API.%s: %s", fn, type(api[fn]) == "function" and "ok" or "MISSING")
		end
		local s = rawget(_G, "SkateGM")
		Say(nil, "  SkateGM internals (optional): loadedScale=%s renderP=%s InputBlockWanted=%s ToAbs=%s", tostring(s.loadedScale), tostring(s.renderP ~= nil), tostring(type(s.InputBlockWanted)), tostring(type(s.ToAbs)))
		Say(nil, "  (loadedScale other than 1 is untested; set skategm_world_scale 1)")
	else
		Say(nil, "  SkateGM not found: board mode is off, foot mode works on its own")
	end
	Say(nil, "[WebSwing] done. Run ws_status_sv in the server console for the server's view.")
end, nil, "Web Swing: check assets, convars and the SkateGM API")
