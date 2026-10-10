-- Web Swing: shared core. State per player, finding anchors, and the predicted
-- movement hook that holds the rope.
--
-- HOW THE ROPE IS HELD (foot mode)
--   SetupMove runs on the server for every usercmd and on the client for the local
--   player's predicted usercmds, with the same buttons and view angles, so both
--   realms run the same code on the same inputs. It never teleports: it reads the
--   movedata's origin and velocity, adds the swing forces, asks WebSwing.Math
--   .constrain() for the velocity that keeps the body inside the rope this tick, and
--   writes that velocity back. The engine then does its normal gravity, air movement
--   and collision with it. Nothing is stored in the player's networked fields except
--   what other clients need to DRAW the web (see Publish).
--   Re-prediction: when the server's correction arrives the client replays commands,
--   so everything that changes state (timers, rope length, attach, release) happens
--   only when IsFirstTimePredicted(); replays just re-apply the forces.

local WS = WebSwing
local M = WS.Math
local T = WS.T
local Guard = WS.Guard

local band = bit.band
local sqrt, max, min, abs = math.sqrt, math.max, math.min, math.abs
local IsValid = IsValid

local CHEST, CHEST_DUCK = 40, 26 -- the rope's hold on the body: this far above the feet
WS.CHEST = CHEST
local STAND = 58                 -- body centre above a ledge when a zip lands on it
local svGravity = GetConVar("sv_gravity")
local svMaxVel = GetConVar("sv_maxvelocity")

WS.MODE_NONE, WS.MODE_WEB, WS.MODE_ZIP = 0, 1, 2
local MODE_NONE, MODE_WEB, MODE_ZIP = 0, 1, 2

local SOUNDS = {
	fire = "weapons/slam/throw.wav",
	attach = "weapons/crossbow/hit1.wav",
	whiff = "weapons/slam/throw.wav",
	release = "ambient/wind/windgust.wav",
	zip = "weapons/crossbow/fire1.wav",
	vault = "physics/metal/metal_solid_impact_soft1.wav",
	dive = "ambient/wind/windgust.wav",
}
WS.SOUNDS = SOUNDS

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
function WS.NewState()
	return {
		mode = MODE_NONE, dive = false,
		ax = 0, ay = 0, az = 0,       -- world anchor (re-evaluated every tick when on an entity)
		ent = nil, lv = Vector(),     -- anchor entity and the anchor in ITS local space
		L = 0, t = 0, t0 = 0,         -- rope length, seconds attached, time of attach
		gox = 0, goy = 0, goz = 0,    -- zip goal relative to the anchor
		zspeed = 0, zt = 0, zledge = false, zinx = 0, ziny = 0, zd = 0, zdAt = 0,
		losT = 0, nextLos = 0,
		airT = 0, relT = 0, lastUse = -100, nextFire = 0, nextNW = 0,
		tension = 0, boost = 0, kind = 0,
		nx = 0, ny = 0, nz = 1,       -- normal of the surface the web hangs on
		tickAt = -100, fireLatch = false,
		whiffT = -100, whiffX = 0, whiffY = 0, whiffZ = 0,
	}
end
function WS.GetState(ply)
	local S = ply.WSS
	if not S then S = WS.NewState() ply.WSS = S end
	return S
end

-- the anchor in the world now. Third result false: the entity it hangs on is gone
-- (the last known position is returned).
local function AnchorXYZ(S)
	local ent = S.ent
	if ent ~= nil then
		if IsValid(ent) then
			local w = ent:LocalToWorld(S.lv)
			S.ax, S.ay, S.az = w.x, w.y, w.z
			return S.ax, S.ay, S.az, true
		end
		return S.ax, S.ay, S.az, false
	end
	return S.ax, S.ay, S.az, true
end
WS.AnchorXYZ = AnchorXYZ

local function SetAnchor(S, hx, hy, hz, ent)
	S.ax, S.ay, S.az = hx, hy, hz
	if IsValid(ent) and not ent:IsWorld() then
		S.ent = ent
		local lp = ent:WorldToLocal(Vector(hx, hy, hz))
		S.lv.x, S.lv.y, S.lv.z = lp.x, lp.y, lp.z
	else
		S.ent = nil
	end
end
WS.SetAnchor = SetAnchor

-- Server: tell everyone how to draw this player's web. Only on state changes
-- (a moving prop carries the rope on every client by itself).
function WS.Publish(ply, S)
	if not SERVER then return end
	ply:SetNW2Int("ws_mode", S.mode)
	ply:SetNW2Bool("ws_dive", S.dive)
	if S.mode ~= MODE_NONE then
		ply:SetNW2Vector("ws_anchor", Vector(S.ax, S.ay, S.az))
		ply:SetNW2Entity("ws_ent", S.ent or NULL)
		ply:SetNW2Vector("ws_local", S.lv)
		ply:SetNW2Float("ws_t0", S.t0)
		ply:SetNW2Float("ws_len", S.L)
		ply:SetNW2Bool("ws_ledge", S.zledge)
	else
		ply:SetNW2Entity("ws_ent", NULL)
		ply:SetNW2Float("ws_tension", 0)
	end
end

local function Snd(ply, key, level, pitch, volume)
	if not T.sounds then return end
	ply:EmitSound(SOUNDS[key], level or 65, pitch or 100, volume or 0.8)
end
WS.Snd = Snd

---------------------------------------------------------------------------
-- Traces (one reusable table: nothing is allocated per call)
---------------------------------------------------------------------------
local trStart, trEnd = Vector(), Vector()
local trOut = {}
local trData = { start = trStart, endpos = trEnd, mask = MASK_SOLID, output = trOut }
local owner
local function FilterFn(ent)
	if ent == owner then return false end
	if not T.attachPlayers and ent:IsPlayer() then return false end
	return true
end
trData.filter = FilterFn

local function Trace(x1, y1, z1, x2, y2, z2, mask)
	trStart.x, trStart.y, trStart.z = x1, y1, z1
	trEnd.x, trEnd.y, trEnd.z = x2, y2, z2
	trData.mask = mask or MASK_SOLID
	return util.TraceLine(trData)
end

local hullOut = {}
local hullData = { start = Vector(), endpos = Vector(), mins = Vector(-16, -16, 0), maxs = Vector(16, 16, 72), mask = MASK_PLAYERSOLID, output = hullOut }
local function HullFree(ply, x, y, z)
	local s, e = hullData.start, hullData.endpos
	s.x, s.y, s.z = x, y, z
	e.x, e.y, e.z = x, y, z
	hullData.filter = ply
	local tr = util.TraceHull(hullData)
	return not tr.Hit and not tr.StartSolid
end

-- can a web hang on this? (the world and props yes; players only if allowed)
local function AnchorEntityOK(ent)
	if not IsValid(ent) or ent:IsWorld() then return true end
	if ent:IsPlayer() then return T.attachPlayers end
	if ent:IsWeapon() then return false end
	return true
end

-- Where a find ended up. Read it right after the call; the next call overwrites it.
local Hit = { x = 0, y = 0, z = 0, nx = 0, ny = 0, nz = 1, ent = nil, dist = 0, kind = 0, score = 0,
	gx = 0, gy = 0, gz = 0, ledge = false, inx = 0, iny = 0 }
WS.Hit = Hit

local function SetHit(hx, hy, hz, nx, ny, nz, ent, bx, by, bz, kind)
	Hit.x, Hit.y, Hit.z, Hit.nx, Hit.ny, Hit.nz = hx, hy, hz, nx, ny, nz
	Hit.ent = (IsValid(ent) and not ent:IsWorld()) and ent or nil
	Hit.dist = M.dist(bx, by, bz, hx, hy, hz)
	Hit.kind = kind
end

---------------------------------------------------------------------------
-- Attach-point assist
---------------------------------------------------------------------------
local CAND, CAND_ENT = {}, {}

local function Assist(ply, bx, by, bz, aimx, aimy, aimz, vx, vy, vz)
	local maxD = T.maxDist
	local floorZ
	local ft = Trace(bx, by, bz, bx, by, bz - 4000)
	if ft.Hit then floorZ = ft.HitPos.z end
	T.g = (svGravity and svGravity:GetFloat() or 600)
	local baseYaw = M.assistBaseYaw(M.yawOf(aimx, aimy), vx, vy, T)
	local cone = T.assistCone / 48
	local n = 0
	for i = 1, #M.ASSIST_AZ do
		for j = 1, #M.ASSIST_EL do
			local dx, dy, dz = M.assistDir(i, j, baseYaw, cone)
			local tr = Trace(bx, by, bz, bx + dx * maxD, by + dy * maxD, bz + dz * maxD)
			if tr.Hit and not tr.HitSky then
				local ent = tr.Entity
				if AnchorEntityOK(ent) then
					local hp, hn = tr.HitPos, tr.HitNormal
					if hp.z > bz + T.assistMinUp and M.dist(bx, by, bz, hp.x, hp.y, hp.z) >= T.assistMinDist then
						n = n + 1
						local o = (n - 1) * 6
						CAND[o + 1], CAND[o + 2], CAND[o + 3] = hp.x, hp.y, hp.z
						CAND[o + 4], CAND[o + 5], CAND[o + 6] = hn.x, hn.y, hn.z
						CAND_ENT[n] = ent
					end
				end
			end
		end
	end
	if n == 0 then return false end
	local idx, score = M.pickBest(bx, by, bz, vx, vy, vz, aimx, aimy, aimz, CAND, n, floorZ, T)
	if idx == 0 then return false end
	local o = (idx - 1) * 6
	SetHit(CAND[o + 1], CAND[o + 2], CAND[o + 3], CAND[o + 4], CAND[o + 5], CAND[o + 6], CAND_ENT[idx], bx, by, bz, 2)
	Hit.score = score
	return true
end

-- Find where a web would attach. e: the eye/camera, aim: unit aim direction, b: the
-- body (the rope's hold), v: velocity. Aim first (a direct hit on a surface within
-- range); if that is sky/out of range/too close and assist is on, search a cone.
-- Returns ok, kind (1 = direct, 2 = assist); the point is in WebSwing.Hit.
function WS.FindAnchor(ply, ex, ey, ez, aimx, aimy, aimz, bx, by, bz, vx, vy, vz, allowAssist)
	owner = ply
	local maxD = T.maxDist
	local reach = maxD + 250
	local tr = Trace(ex, ey, ez, ex + aimx * reach, ey + aimy * reach, ez + aimz * reach)
	if tr.Hit and not tr.HitSky and AnchorEntityOK(tr.Entity) then
		local hp, hn = tr.HitPos, tr.HitNormal
		local hx, hy, hz, nx, ny, nz = hp.x, hp.y, hp.z, hn.x, hn.y, hn.z
		local ent = tr.Entity
		local dp = M.dist(bx, by, bz, hx, hy, hz)
		if dp <= maxD + 100 and dp > 14 and hz > bz - 160 then
			-- something between the hands and the aim point? grab that instead
			local k = (dp - 6) / dp
			local t2 = Trace(bx, by, bz, bx + (hx - bx) * k, by + (hy - by) * k, bz + (hz - bz) * k)
			local ok = true
			if t2.Hit then
				if t2.HitSky or not AnchorEntityOK(t2.Entity) then
					ok = false
				else
					local p2, n2 = t2.HitPos, t2.HitNormal
					hx, hy, hz, nx, ny, nz, ent = p2.x, p2.y, p2.z, n2.x, n2.y, n2.z, t2.Entity
					dp = M.dist(bx, by, bz, hx, hy, hz)
					if hz <= bz - 160 then ok = false end
				end
			end
			if ok and dp >= T.minAttach then
				SetHit(hx, hy, hz, nx, ny, nz, ent, bx, by, bz, 1)
				return true, 1
			end
		end
	end
	if allowAssist and T.assist and Assist(ply, bx, by, bz, aimx, aimy, aimz, vx, vy, vz) then
		return true, 2
	end
	return false, 0
end

-- FindAnchor with the gravity the simulated swing should use (the board lives in Skate 3's
-- gravity with no extra pull), always restored, even if something throws.
function WS.FindAnchorWith(g, gscale, ply, ...)
	local og, ogs = T.g, T.gravityScale
	T.g, T.gravityScale = g, gscale
	local ok, a, b = pcall(WS.FindAnchor, ply, ...)
	T.g, T.gravityScale = og, ogs
	if not ok then error(a, 0) end
	return a, b
end

---------------------------------------------------------------------------
-- Zip target
---------------------------------------------------------------------------
-- A hit as a zip goal: land on a roof, hop a ledge just above a wall hit, or
-- hang in front of a wall. Fills Hit.g* (the body's goal) and Hit.ledge.
local function ZipFromHit(ply, hx, hy, hz, nx, ny, nz, ent, bx, by, bz, kind)
	local dist = M.dist(bx, by, bz, hx, hy, hz)
	if dist < 150 or dist > T.zipRange + 100 then return false end
	local ix, iy
	if nz > 0.7 then
		-- an up-facing surface: land on it, heading on in the direction we came
		ix, iy = M.norm(hx - bx, hy - by, 0)
		local gx, gy, gz = hx, hy, hz + STAND
		if not HullFree(ply, gx, gy, gz - STAND + 4) then return false end
		SetHit(hx, hy, hz, nx, ny, nz, ent, bx, by, bz, kind)
		Hit.gx, Hit.gy, Hit.gz, Hit.ledge, Hit.inx, Hit.iny = gx, gy, gz, true, ix, iy
		return true
	end
	if abs(nz) < 0.5 then
		local inx, iny = M.norm(-nx, -ny, 0)
		-- a ledge above the hit: look straight down just inside the wall
		local px, py = hx + inx * 12, hy + iny * 12
		local top = Trace(px, py, hz + T.ledgeMax, px, py, hz - 8)
		if top.Hit and not top.StartSolid and top.HitNormal.z > 0.7 then
			local tz = top.HitPos.z
			if tz - hz <= T.ledgeMax + 8 and tz >= hz - 8 then
				local gx, gy = px + inx * 20, py + iny * 20
				if HullFree(ply, gx, gy, tz + 2) then
					SetHit(hx, hy, hz, nx, ny, nz, ent, bx, by, bz, kind)
					Hit.gx, Hit.gy, Hit.gz, Hit.ledge, Hit.inx, Hit.iny = gx, gy, tz + STAND, true, inx, iny
					return true
				end
			end
		end
		-- a bare wall: hang in front of it
		SetHit(hx, hy, hz, nx, ny, nz, ent, bx, by, bz, kind)
		Hit.gx, Hit.gy, Hit.gz, Hit.ledge, Hit.inx, Hit.iny = hx + nx * 30, hy + ny * 30, hz + nz * 30, false, inx, iny
		return true
	end
	return false
end

function WS.FindZip(ply, ex, ey, ez, aimx, aimy, aimz, bx, by, bz)
	owner = ply
	local range = T.zipRange
	local tr = Trace(ex, ey, ez, ex + aimx * (range + 250), ey + aimy * (range + 250), ez + aimz * (range + 250))
	if tr.Hit and not tr.HitSky and AnchorEntityOK(tr.Entity) then
		local hp, hn = tr.HitPos, tr.HitNormal
		if ZipFromHit(ply, hp.x, hp.y, hp.z, hn.x, hn.y, hn.z, tr.Entity, bx, by, bz, 1) then return true end
	end
	if not T.assist then return false end
	-- nothing usable on the aim: look for a ledge or roof around it (best = closest to the aim)
	local baseYaw = M.yawOf(aimx, aimy)
	local aimElev = math.deg(math.asin(max(-1, min(1, aimz))))
	local best = -math.huge
	local b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, bent
	for i = 1, #M.ASSIST_AZ do
		for j = 1, #M.ASSIST_EL do
			local az = M.ASSIST_AZ[i] * 0.6
			local el = M.ASSIST_EL[j] * 0.8
			local dx, dy, dz = M.dirFromYawElev(baseYaw + az, el)
			local t = Trace(bx, by, bz, bx + dx * range, by + dy * range, bz + dz * range)
			if t.Hit and not t.HitSky and AnchorEntityOK(t.Entity) then
				local hp, hn = t.HitPos, t.HitNormal
				-- (only somewhere to stand counts when the aim itself found nothing)
				if ZipFromHit(ply, hp.x, hp.y, hp.z, hn.x, hn.y, hn.z, t.Entity, bx, by, bz, 2) and Hit.ledge then
					local ang = math.sqrt(az * az + (el - max(aimElev, 20)) ^ 2)
					local sc = M.zipScore(Hit.dist, ang, true, T)
					if sc > best then
						best = sc
						b1, b2, b3, b4, b5, b6 = Hit.x, Hit.y, Hit.z, Hit.nx, Hit.ny, Hit.nz
						b7, b8, b9, b10, b11, bent = Hit.gx, Hit.gy, Hit.gz, Hit.inx, Hit.iny, Hit.ent
					end
				end
			end
		end
	end
	if best == -math.huge then return false end
	SetHit(b1, b2, b3, b4, b5, b6, bent, bx, by, bz, 2)
	Hit.gx, Hit.gy, Hit.gz, Hit.inx, Hit.iny, Hit.ledge = b7, b8, b9, b10, b11, true
	return true
end

---------------------------------------------------------------------------
-- Environment and bookkeeping
---------------------------------------------------------------------------
local function HoldingSwep(ply)
	local wep = ply:GetActiveWeapon()
	return IsValid(wep) and wep.IsWebSwing == true
end
WS.HoldingSwep = HoldingSwep

-- can this player be on a web right now? (not on a ladder, in water, noclipping, in a vehicle,
-- dead, frozen, or being the skater of SkateGM)
local function EnvOK(ply)
	if not ply:Alive() then return false end
	if ply:GetMoveType() ~= MOVETYPE_WALK then return false end -- noclip, ladder, fly, observer, vphysics...
	if ply:InVehicle() then return false end
	if ply:WaterLevel() >= 2 then return false end
	if ply:IsFrozen() then return false end
	if WS.SkateGM.IsSkating(ply) then return false end
	return true
end
WS.EnvOK = EnvOK

local scratch = Vector()
local function SetVel(mv, x, y, z)
	scratch.x, scratch.y, scratch.z = x, y, z
	mv:SetVelocity(scratch)
end

local function VMax()
	local m = T.maxSpeed
	local sv = svMaxVel and svMaxVel:GetFloat() or 3500
	return min(m, sv * 0.98)
end

local function EntGravity(ply)
	local g = svGravity and svGravity:GetFloat() or 600
	local eg = ply:GetGravity()
	if eg and eg ~= 0 then g = g * eg end
	return g
end

---------------------------------------------------------------------------
-- Release
---------------------------------------------------------------------------
-- kind: "release" (let go: slingshot boost), "jump" (hop off), anything else is
-- silent (holster, death, snapped, entity gone...). mv: when given, the boost is
-- written to the movedata so it takes effect this very tick.
function WS.Release(ply, S, kind, mv)
	if S.mode == MODE_NONE and not S.dive then return end
	local now = CurTime()
	if S.mode == MODE_WEB and mv and (kind == "release" or kind == "jump") then
		local o, v = mv:GetOrigin(), mv:GetVelocity()
		local vx, vy, vz = v.x, v.y, v.z
		if kind == "release" then
			local ax, ay, az = AnchorXYZ(S)
			local nx, ny, nz = M.norm(o.x - ax, o.y - ay, o.z + CHEST - az)
			local boost = M.releaseBoost(M.len(vx, vy, vz), -nz, vz, T)
			vx, vy, vz = M.releaseVelocity(vx, vy, vz, boost, T)
			S.boost = boost
		else
			vz = vz + T.jumpPop
			S.boost = T.jumpPop * 0.6
		end
		SetVel(mv, vx, vy, vz)
		Snd(ply, "release", 62, 100 + min(40, S.boost / 10), 0.6)
	end
	local wasDive = S.dive
	S.mode = MODE_NONE
	S.dive = false
	S.ent = nil
	S.relT = now
	S.lastUse = now
	S.losT = 0
	WS.Publish(ply, S)
	return wasDive
end

-- Anything that ends it without a movedata (death, spawn, holster...)
function WS.ForceClear(ply, why)
	local S = ply.WSS
	if S and (S.mode ~= MODE_NONE or S.dive) then
		WS.Release(ply, S, why or "clear")
	end
end

local function EndDive(ply, mv, S, auto)
	if not S.dive then return end
	local v = mv:GetVelocity()
	local o = mv:GetOrigin()
	local hv = sqrt(v.x * v.x + v.y * v.y)
	local dirx, diry
	if hv > 6 * M.UNIT then
		dirx, diry = v.x / hv, v.y / hv
	else
		local a = mv:GetAngles()
		dirx, diry = M.forward(0, a.y)
	end
	local nx, ny, nz = M.pullUpVelocity(v.x, v.y, v.z, dirx, diry, T)
	if not (auto and ply:IsOnGround()) then SetVel(mv, nx, ny, nz) end
	S.dive = false
	S.lastUse = CurTime()
	WS.Publish(ply, S)
end

---------------------------------------------------------------------------
-- The per-tick work
---------------------------------------------------------------------------
local function BodyPoint(ply, mv)
	local o = mv:GetOrigin()
	return o.x, o.y, o.z + (ply:Crouching() and CHEST_DUCK or CHEST)
end

local function ViewVectors(mv)
	local a = mv:GetAngles()
	local fx, fy, fz = M.forward(a.p, a.y)
	return fx, fy, fz, a.y
end

local function TryAttach(ply, mv, S, now, first)
	local bx, by, bz = BodyPoint(ply, mv)
	local ex, ey, ez
	do local e = ply:GetShootPos() ex, ey, ez = e.x, e.y, e.z end
	local fx, fy, fz = ViewVectors(mv)
	local v = mv:GetVelocity()
	T.g = EntGravity(ply)
	local ok, kind = WS.FindAnchor(ply, ex, ey, ez, fx, fy, fz, bx, by, bz, v.x, v.y, v.z, true)
	if not ok then
		if first then
			S.nextFire = now + 0.22
			S.whiffT = now
			S.whiffX, S.whiffY, S.whiffZ = ex + fx * 900, ey + fy * 900, ez + fz * 900
			Snd(ply, "whiff", 60, 150, 0.4)
		end
		return false
	end
	if first then
		SetAnchor(S, Hit.x, Hit.y, Hit.z, Hit.ent)
		S.nx, S.ny, S.nz = Hit.nx, Hit.ny, Hit.nz
		S.mode = MODE_WEB
		S.kind = kind
		S.L = min(max(T.minRope, Hit.dist), T.maxDist + 100)
		S.t, S.t0 = 0, now
		S.losT, S.nextLos = 0, now + 0.15
		S.zledge = false
		S.lastUse = now
		S.boost = 0
		S.dive = false
		Snd(ply, "fire", 62, 120, 0.5)
		Snd(ply, "attach", 66, 110, 0.7)
		WS.Publish(ply, S)
	end
	return true
end

local function TryZip(ply, mv, S, now, first)
	local bx, by, bz = BodyPoint(ply, mv)
	local ex, ey, ez
	do local e = ply:GetShootPos() ex, ey, ez = e.x, e.y, e.z end
	local fx, fy, fz = ViewVectors(mv)
	local ok
	if S.mode == MODE_WEB then
		-- zip to the web you are hanging on
		local ax, ay, az = AnchorXYZ(S)
		owner = ply
		ok = ZipFromHit(ply, ax, ay, az, S.nx, S.ny, S.nz, S.ent, bx, by, bz, 1)
		if not ok then
			-- no sensible ledge or roof: just fly to the anchor
			local ux, uy, uz = M.norm(bx - ax, by - ay, bz - az)
			SetHit(ax, ay, az, S.nx, S.ny, S.nz, S.ent, bx, by, bz, 1)
			Hit.gx, Hit.gy, Hit.gz, Hit.ledge, Hit.inx, Hit.iny = ax + ux * 30, ay + uy * 30, az + uz * 30, false, 0, 0
			ok = Hit.dist >= 150
		end
	else
		ok = WS.FindZip(ply, ex, ey, ez, fx, fy, fz, bx, by, bz)
	end
	if not ok then
		if first then
			S.nextFire = now + 0.25
			Snd(ply, "whiff", 60, 150, 0.4)
		end
		return false
	end
	if first then
		SetAnchor(S, Hit.x, Hit.y, Hit.z, Hit.ent)
		S.gox, S.goy, S.goz = Hit.gx - Hit.x, Hit.gy - Hit.y, Hit.gz - Hit.z
		S.mode = MODE_ZIP
		S.zledge = Hit.ledge
		S.zinx, S.ziny = Hit.inx, Hit.iny
		local v = mv:GetVelocity()
		local dx, dy, dz = M.norm(Hit.gx - bx, Hit.gy - by, Hit.gz - bz)
		S.zspeed = max(T.zipStart, v.x * dx + v.y * dy + v.z * dz)
		S.zt, S.zd, S.zdAt = 0, Hit.dist, now
		S.t0, S.L = now, Hit.dist
		S.dive = false
		S.kind = Hit.kind
		S.lastUse = now
		Snd(ply, "zip", 66, 110, 0.7)
		WS.Publish(ply, S)
	end
	return true
end

local function ApplyWeb(ply, mv, S, dt, first, now, btn)
	local o, v = mv:GetOrigin(), mv:GetVelocity()
	local px, py, pz = o.x, o.y, o.z + (ply:Crouching() and CHEST_DUCK or CHEST)
	local vx, vy, vz = v.x, v.y, v.z
	local ax, ay, az, valid = AnchorXYZ(S)
	if not valid and SERVER and first then WS.Release(ply, S, "gone") return end

	local nx, ny, nz, dist = M.norm(px - ax, py - ay, pz - az)
	if first then
		S.t = S.t + dt
		S.lastUse = now
		if S.t < T.autoReelT and dist < S.L then S.L = max(T.minRope, dist) end
	end
	local g = EntGravity(ply)

	-- input: the forward key pumps along the arc, A/D steer, crouch reels in
	local fx, fy, fz, yaw = ViewVectors(mv)
	if band(btn, IN_FORWARD) ~= 0 then
		local ux, uy, uz = M.pumpAccel(vx, vy, vz, nx, ny, nz, fx, fy, fz, T)
		vx, vy, vz = vx + ux * dt, vy + uy * dt, vz + uz * dt
	end
	local side = (band(btn, IN_MOVERIGHT) ~= 0 and 1 or 0) - (band(btn, IN_MOVELEFT) ~= 0 and 1 or 0)
	if side ~= 0 then
		local rx, ry, rz = M.right(yaw)
		local ux, uy, uz = M.steerAccel(nx, ny, nz, rx, ry, rz, side, T)
		vx, vy, vz = vx + ux * dt, vy + uy * dt, vz + uz * dt
	end
	local L = S.L
	if band(btn, IN_DUCK) ~= 0 and L > T.minRope then
		local L2 = max(T.minRope, L - T.reel * dt)
		vx, vy, vz = M.reelVelocity(vx, vy, vz, nx, ny, nz, L, L2, T.reelAM)
		L = L2
		if first then S.L = L2 end
	end

	-- gravity: the engine applies the map's; this is the extra (or less) for the feel
	vz = vz - (T.gravityScale - 1) * g * dt
	local drag = M.dragFactor(M.len(vx, vy, vz), dt, T)
	vx, vy, vz = vx * drag, vy * drag, vz * drag
	vx, vy, vz = M.clampSpeed(vx, vy, vz, VMax())

	-- ground friction would eat the swing: stay in the air while the rope is working.
	-- (right after a web fired from the floor, kick off it: groundHop)
	if ply:IsOnGround() then
		if S.t <= 0.06 and T.groundHop > 0 then
			if vz < T.groundHop then vz = T.groundHop end
		elseif vz < 160 and (dist >= L - 24 or sqrt(vx * vx + vy * vy) > 450) then
			vz = 160
		end
	end

	local nvx, nvy, nvz, corr = M.constrain(px, py, pz, vx, vy, vz, ax, ay, az, L, dt, g, T.maxPull)
	if first then
		local tg = M.tensionG(corr, dt, g)
		S.tension = S.tension + (tg - S.tension) * 0.25
		if SERVER and now >= S.nextNW then
			S.nextNW = now + 0.1
			ply:SetNW2Float("ws_tension", S.tension)
		end
		-- a rope that stays behind the world snaps after a moment
		if now >= S.nextLos then
			S.nextLos = now + 0.1
			owner = ply
			-- from the body to 8 units in front of the anchor: only the world (and static props) blocks it
			local k = dist > 24 and 8 / dist or 0
			local tr = Trace(px, py, pz, ax + (px - ax) * k, ay + (py - ay) * k, az + (pz - az) * k, MASK_SOLID_BRUSHONLY)
			if k > 0 and tr.Hit and tr.HitWorld then
				S.losT = S.losT + 0.1
				if T.snapTime > 0 and S.losT > T.snapTime and SERVER then
					SetVel(mv, nvx, nvy, nvz)
					WS.Release(ply, S, "snap")
					return
				end
			else
				S.losT = max(0, S.losT - 0.2)
			end
		end
		if SERVER and corr > 0 and S.ent and WS.PropReaction then
			WS.PropReaction(ply, S, nvx - vx, nvy - vy, nvz - vz)
		end
	end
	SetVel(mv, nvx, nvy, nvz)
end

local function ApplyZip(ply, mv, S, dt, first, now, btn)
	local o, v = mv:GetOrigin(), mv:GetVelocity()
	local px, py, pz = o.x, o.y, o.z + (ply:Crouching() and CHEST_DUCK or CHEST)
	local ax, ay, az, valid = AnchorXYZ(S)
	if not valid and SERVER and first then WS.Release(ply, S, "gone") return end
	local gx, gy, gz = ax + S.gox, ay + S.goy, az + S.goz
	local vx, vy, vz, speed, d = M.zipStep(px, py, pz, gx, gy, gz, S.zspeed, dt, T)
	if first then
		S.zspeed = speed
		S.zt = S.zt + dt
		S.lastUse = now
	end
	if M.zipDone(d, S.zt, T) then
		if first then
			local ex, ey, ez
			if S.zledge then
				local hx, hy = M.norm(gx - px, gy - py, 0)
				ex, ey, ez = M.vaultVelocity(hx, hy, S.zinx, S.ziny, S.zspeed, T)
			else
				local dx, dy, dz = M.norm(gx - px, gy - py, gz - pz)
				if d < 1 then dx, dy, dz = M.norm(v.x, v.y, v.z) end
				ex, ey, ez = M.exitVelocity(dx, dy, dz, S.zspeed)
			end
			SetVel(mv, ex, ey, ez)
			Snd(ply, "vault", 66, 100, 0.7)
			S.mode = MODE_NONE
			S.ent = nil
			S.relT = now
			WS.Publish(ply, S)
		end
		return
	end
	-- being stopped (a wall, a prop): give up rather than grind against it
	if first and now - S.zdAt >= 0.3 then
		if S.zd - d < speed * 0.3 * 0.15 then
			S.mode = MODE_NONE
			S.ent = nil
			S.relT = now
			WS.Publish(ply, S)
			return
		end
		S.zd, S.zdAt = d, now
	end
	-- the engine takes half a tick of gravity before it moves us; give it back
	local g = EntGravity(ply)
	vz = vz + 0.5 * g * dt
	if ply:IsOnGround() and vz < 160 then vz = 160 end
	SetVel(mv, vx, vy, vz)
end

local function ApplyDive(ply, mv, S, dt, first, now, btn)
	local v = mv:GetVelocity()
	local fx, fy, fz, yaw = ViewVectors(mv)
	local wx = (band(btn, IN_FORWARD) ~= 0 and 1 or 0) - (band(btn, IN_BACK) ~= 0 and 1 or 0)
	local wy = (band(btn, IN_MOVELEFT) ~= 0 and 1 or 0) - (band(btn, IN_MOVERIGHT) ~= 0 and 1 or 0)
	local fhx, fhy = M.forward(0, yaw)
	local lhx, lhy = -fhy, fhx -- left
	local wishx, wishy = M.norm(fhx * wx + lhx * wy, fhy * wx + lhy * wy, 0)
	local vx, vy, vz = M.diveVelocity(v.x, v.y, v.z, wishx or 0, wishy or 0, fhx, fhy, dt, T)
	vx, vy, vz = M.clampSpeed(vx, vy, vz, VMax())
	if first then S.lastUse = now end
	SetVel(mv, vx, vy, vz)
end

-- The hook. mv/cmd as GM:SetupMove.
local function Tick(ply, mv, cmd)
	local S = ply.WSS
	local active = S ~= nil and (S.mode ~= MODE_NONE or S.dive)
	local holding = HoldingSwep(ply)
	if not active and not holding then return end
	if not T.enabled then
		if active then WS.Release(ply, S, "disabled") end
		return
	end
	if not EnvOK(ply) then
		if active then WS.Release(ply, S, "env") end
		return
	end
	S = S or WS.GetState(ply)
	local first = IsFirstTimePredicted()
	local now = CurTime()
	local dt = FrameTime()
	if dt < 0.004 or dt > 0.1 then dt = engine.TickInterval() end
	if CLIENT then S.tickAt = now end

	if not holding then
		-- weapon put away or taken: the web goes with it
		if first then WS.Release(ply, S, "holster") end
		return
	end

	local btn, old = mv:GetButtons(), mv:GetOldButtons()
	local fire = band(btn, IN_ATTACK) ~= 0
	local zipPressed = band(btn, IN_ATTACK2) ~= 0 and band(old, IN_ATTACK2) == 0
	local jumpPressed = band(btn, IN_JUMP) ~= 0 and band(old, IN_JUMP) == 0
	local diveHeld = band(btn, IN_RELOAD) ~= 0
	local onGround = ply:IsOnGround()
	if onGround then S.airT = 0 elseif first then S.airT = S.airT + dt end

	if S.mode == MODE_WEB then
		if first then
			if not fire then WS.Release(ply, S, "release", mv) return end
			if jumpPressed then WS.Release(ply, S, "jump", mv) return end
			if diveHeld and S.airT > 0.12 then
				WS.Release(ply, S, "dive")
				S.dive = true
				Snd(ply, "dive", 62, 100, 0.5)
				WS.Publish(ply, S)
				ApplyDive(ply, mv, S, dt, first, now, btn)
				return
			end
			if zipPressed and TryZip(ply, mv, S, now, first) then ApplyZip(ply, mv, S, dt, first, now, btn) return end
		end
		if S.mode == MODE_WEB then ApplyWeb(ply, mv, S, dt, first, now, btn) end
	elseif S.mode == MODE_ZIP then
		if first and (jumpPressed or not ply:Alive()) then
			SetVel(mv, mv:GetVelocity().x, mv:GetVelocity().y, mv:GetVelocity().z + 170)
			S.mode, S.ent, S.relT = MODE_NONE, nil, now
			WS.Publish(ply, S)
			return
		end
		ApplyZip(ply, mv, S, dt, first, now, btn)
	elseif S.dive then
		if first and (not diveHeld) then EndDive(ply, mv, S, false) return end
		if first and onGround and S.airT == 0 then EndDive(ply, mv, S, true) return end
		ApplyDive(ply, mv, S, dt, first, now, btn)
	else
		-- idle: a press starts something
		if first then
			if fire and now >= S.nextFire and not S.fireLatch then
				if TryAttach(ply, mv, S, now, first) then
					S.fireLatch = true
					ApplyWeb(ply, mv, S, dt, first, now, btn)
					return
				end
			elseif zipPressed and now >= S.nextFire then
				if TryZip(ply, mv, S, now, first) then ApplyZip(ply, mv, S, dt, first, now, btn) return end
			elseif diveHeld and not onGround and S.airT > 0.12 and now - S.relT > 0.05 then
				S.dive = true
				Snd(ply, "dive", 62, 100, 0.5)
				WS.Publish(ply, S)
				ApplyDive(ply, mv, S, dt, first, now, btn)
				return
			end
			if not fire then S.fireLatch = false end
		end
	end
end
WS.Tick = Tick

hook.Add("SetupMove", "webswing_setupmove", Guard("SetupMove", Tick))

-- a stuck "holding fire" latch must not survive a weapon change
hook.Add("PlayerSwitchWeapon", "webswing_switch", Guard("PlayerSwitchWeapon", function(ply)
	local S = ply.WSS
	if S then S.fireLatch = false end
end))
