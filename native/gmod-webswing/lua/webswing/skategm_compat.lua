-- Web Swing <-> SkateGM.
--
-- WHAT SkateGM IS (read from its source, see README "How it composes with SkateGM")
--   * The skate simulation (Skate 3's engine, a Rust DLL: global `skategm`) runs on the
--     CLIENT. There is no Move/SetupMove hook and no board entity. While Skater mode is
--     on, the real player entity is hidden, MOVETYPE_NOCLIP, not solid, weaponless, and
--     only follows the skater by SetPos (skategm_pos, ~5/s).
--   * While skating, SkateGM's CreateMove clears the usercmd's buttons and movement
--     (so IN_ATTACK etc. never arrive), and its PlayerBindPress hook swallows every
--     bind except a short list. So the SWEP and +commands cannot work on the board.
--   * Its public client API (SkateGM.API) has what a rope needs: SkaterPos(),
--     Velocity(), State(), Tick(), View(), PoseOf(ply), IsSkating(), StartSkating(),
--     and Launch(vel m/s) which adds velocity to the skater and board while they are
--     rolling, powersliding, reverting or in the air (and returns false otherwise).
--
-- SO, TWO MODES
--   foot mode: the SWEP and the predicted SetupMove hook in sh_core.lua. This file only
--              tells it when to stay out of the way (IsSkating).
--   board mode (CLIENT, below): the web is driven from the client, because that is
--              where the skater is simulated. Inputs are polled (mouse buttons and two
--              keys SkateGM doesn't use), the rope is a velocity constraint applied with
--              API.Launch at most once per engine tick, and the web is reported to the
--              server (WS.NET_BOARD) only so everyone else can see it.
--
-- If SkateGM is not installed none of this runs: C.API() is nil and every entry point
-- returns immediately.

local WS = WebSwing
local M = WS.Math
local T = WS.T
local Guard = WS.Guard

local C = WS.SkateGM or {}
WS.SkateGM = C

---------------------------------------------------------------------------
-- Detection (shared). Re-evaluated on every call: add-on load order is not guaranteed.
---------------------------------------------------------------------------
function C.API()
	local s = rawget(_G, "SkateGM")
	if type(s) == "table" and type(s.API) == "table" then return s.API end
	return nil
end
function C.Installed() return C.API() ~= nil end

-- Is this player the skater of SkateGM right now?
--   server: SkateGM sets ply.SkateGM in Enter() / Leave()
--   client: the local player: API.IsSkating() (immediate); everyone: the NW2 bool it sets
function C.IsSkating(ply)
	local api = C.API()
	if not api then return false end
	if SERVER then return ply.SkateGM == true end
	if ply == LocalPlayer() and api.IsSkating and api.IsSkating() then return true end
	return ply:GetNW2Bool("SkateGMSkating", false)
end

-- SkateGM's engine only takes a push while riding / in the air
function C.CanPush(state)
	if type(state) ~= "string" then return false end
	if state:find("Biped", 1, true) or state:find("Wipeout", 1, true) then return false end
	return state:find("PhysicsGround", 1, true) ~= nil or state:find("SlideGround", 1, true) ~= nil
		or state:find("RevertGround", 1, true) ~= nil or state:find("Air", 1, true) ~= nil
end

-- infinite-map frame shift (SkateGM converts to absolute coordinates on the wire)
function C.ToAbs(v)
	local s = rawget(_G, "SkateGM")
	if type(s) == "table" and type(s.ToAbs) == "function" then return s.ToAbs(v) end
	return v
end
function C.FromAbs(v)
	local s = rawget(_G, "SkateGM")
	if type(s) == "table" and type(s.FromAbs) == "function" then return s.FromAbs(v) end
	return v
end

---------------------------------------------------------------------------
-- SERVER: show everyone the skater's web
---------------------------------------------------------------------------
if SERVER then
	local function Clear(ply)
		local B = ply.WSB
		if B and B.mode ~= 0 then
			B.mode, B.ent = 0, nil
			WS.Publish(ply, B)
		end
	end
	C.ClearBoard = Clear

	net.Receive(WS.NET_BOARD, Guard("board_report", function(len, ply)
		if not IsValid(ply) or not ply.SkateGM then return end
		local now = SysTime()
		if now - (ply.WSBoardAt or 0) < 1 / 30 then return end -- at most 30 a second
		ply.WSBoardAt = now
		local mode = net.ReadUInt(2)
		if mode == 0 then Clear(ply) return end
		if not (T.enabled and T.boardEnabled) then Clear(ply) return end
		local ax, ay, az = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
		local hasEnt = net.ReadBool()
		local ent, lx, ly, lz
		if hasEnt then
			ent = net.ReadEntity()
			lx, ly, lz = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
		end
		local L = net.ReadFloat()
		if ax ~= ax or ay ~= ay or az ~= az or L ~= L then return end -- NaN
		if math.abs(ax) > 2 ^ 31 or math.abs(ay) > 2 ^ 31 or math.abs(az) > 2 ^ 31 then return end
		-- the skater is simulated on its client: all the server can do is check the web is
		-- somewhere a web could be (the skater's last reported hips, generously)
		local ref = ply.SkateGMHips or ply:GetPos()
		local limit = T.maxDist * 1.5 + 800
		if (ax - ref.x) ^ 2 + (ay - ref.y) ^ 2 + (az - ref.z) ^ 2 > limit * limit then return end
		local B = ply.WSB
		if not B then B = WS.NewState() ply.WSB = B end
		local changed = B.mode ~= mode or (B.ax - ax) ^ 2 + (B.ay - ay) ^ 2 + (B.az - az) ^ 2 > 64
		local entOK = hasEnt and IsValid(ent) and not ent:IsWorld() and (T.attachPlayers or not ent:IsPlayer())
		if (B.ent ~= nil) ~= entOK or (entOK and B.ent ~= ent) then changed = true end
		B.ax, B.ay, B.az = ax, ay, az
		B.ent = entOK and ent or nil
		if entOK then B.lv.x, B.lv.y, B.lv.z = lx, ly, lz end
		B.L = L
		B.zledge = false
		B.seen = now
		if changed then
			local wasOff = B.mode == 0
			B.mode = mode
			if wasOff then
				B.t0 = CurTime()
				WS.Snd(ply, "attach", 66, 110, 0.7)
			end
			WS.Publish(ply, B)
		end
	end))

	-- skater mode begins: the foot web ends (the SWEP is put away by SkateGM anyway), the
	-- board web starts clean
	hook.Add("SkateGMEnter", "webswing_skategm_enter", Guard("SkateGMEnter", function(ply)
		WS.ForceClear(ply, "board")
		Clear(ply)
	end))
	for _, ev in ipairs({ "PlayerDeath", "PlayerSilentDeath", "PlayerSpawn" }) do
		hook.Add(ev, "webswing_skategm_" .. ev, Guard(ev, function(ply) if IsValid(ply) then Clear(ply) end end))
	end
	hook.Add("PlayerDisconnected", "webswing_skategm_disc", Guard("PlayerDisconnected", function(ply) if IsValid(ply) then Clear(ply) end end))

	-- SkateGM has no "left skater mode" hook: a skater who stopped (or whose client
	-- stopped reporting) must not keep a web hanging in everyone's view
	local nextWatch = 0
	hook.Add("Think", "webswing_skategm_watch", Guard("Think", function()
		local now = SysTime()
		if now < nextWatch then return end
		nextWatch = now + 1
		for _, ply in ipairs(player.GetAll()) do
			local B = ply.WSB
			if B and B.mode ~= 0 and (not ply.SkateGM or now - (B.seen or 0) > 1.6) then Clear(ply) end
		end
	end))
	return
end

---------------------------------------------------------------------------
-- CLIENT: board mode
---------------------------------------------------------------------------
local CCV = WS.CCV
local B = { S = WS.NewState(), keys = { fire = false, zip = false, dive = false, reel = false },
	was = { fire = false, zip = false }, wasSkating = false, frame = 0, lastTick = nil, nextSend = 0, nextFire = 0,
	blockT = 0, footVx = 0, footVy = 0, footVz = 0, handoff = nil, err = nil, pushes = 0, rejected = 0 }
C.Board = B

function B.Active() return B.S.mode ~= 0 or B.S.dive end
local function Client() return WS.Client end

-- engine pushes not yet visible in the polled velocity (Launch is asynchronous: it
-- takes a tick or two to show up in Poll). A fixed number of slots: nothing allocated.
local PEND = 4
local pT, pX, pY, pZ = {}, {}, {}, {}
local function PendAdd(tick, dx, dy, dz)
	local slot = 1
	local oldest = math.huge
	for i = 1, PEND do
		if pT[i] == nil then slot = i break end
		if pT[i] < oldest then oldest, slot = pT[i], i end
	end
	pT[slot], pX[slot], pY[slot], pZ[slot] = tick, dx, dy, dz
end
local function PendDrop(tick)
	for i = 1, PEND do
		if pT[i] ~= nil and pT[i] <= tick - T.boardAckTicks then pT[i] = nil end
	end
end
local function PendSum()
	local x, y, z = 0, 0, 0
	for i = 1, PEND do
		if pT[i] ~= nil then x, y, z = x + pX[i], y + pY[i], z + pZ[i] end
	end
	return x, y, z
end
local function PendClear() for i = 1, PEND do pT[i] = nil end end

-- Launch takes m/s; the rope works in map units/s (SkateGM: 1 unit = 0.0254 m * world scale)
local function Launch(api, dvx, dvy, dvz)
	local s = rawget(_G, "SkateGM")
	local k = 0.0254 * ((type(s) == "table" and s.loadedScale) or 1)
	return api.Launch(Vector(dvx * k, dvy * k, dvz * k)) == true
end

local function InputBlocked()
	if not (gui and vgui and input) then return true end
	if gui.IsGameUIVisible() or gui.IsConsoleVisible() or vgui.CursorVisible() then return true end
	if system and system.HasFocus and not system.HasFocus() then return true end
	local focus = vgui.GetKeyboardFocus()
	if focus and IsValid(focus) then return true end
	local lp = LocalPlayer()
	if IsValid(lp) and lp.IsTyping and lp:IsTyping() then return true end
	-- SkateGM's own menus (the controller UI) want the buttons
	local ui = rawget(_G, "SKATEGM_UI")
	if type(ui) == "table" and ui.open ~= nil then return true end
	local s = rawget(_G, "SkateGM")
	if type(s) == "table" and type(s.InputBlockWanted) == "function" and s.InputBlockWanted() then return true end
	return false
end

local function Down(code)
	if not code or code <= 0 then return false end
	return input.IsButtonDown(code)
end

local function ReadKeys()
	local k = B.keys
	if InputBlocked() then
		k.fire, k.zip, k.dive, k.reel = false, false, false, false
		return
	end
	local mouse = CCV.board_mouse:GetBool()
	k.fire = mouse and Down(MOUSE_LEFT)
	k.zip = mouse and Down(MOUSE_RIGHT)
	k.dive = Down(CCV.key_dive:GetInt())
	k.reel = Down(CCV.key_reel:GetInt())
end

function B.Send(force)
	local S = B.S
	local now = RealTime()
	if not force and now < B.nextSend then return end
	B.nextSend = now + 0.5
	net.Start(WS.NET_BOARD)
	net.WriteUInt(S.mode, 2)
	if S.mode ~= 0 then
		local a = C.ToAbs(Vector(S.ax, S.ay, S.az))
		net.WriteFloat(a.x) net.WriteFloat(a.y) net.WriteFloat(a.z)
		local e = S.ent
		local hasEnt = IsValid(e) and not e:IsWorld()
		net.WriteBool(hasEnt)
		if hasEnt then
			net.WriteEntity(e)
			net.WriteFloat(S.lv.x) net.WriteFloat(S.lv.y) net.WriteFloat(S.lv.z)
		end
		net.WriteFloat(S.L)
	end
	net.SendToServer()
end

-- stop the web without a boost (bailed, SkateGM turned off, entity gone...)
local function BoardClear()
	local S = B.S
	local was = S.mode ~= 0 or S.dive
	S.mode, S.dive, S.ent = 0, false, nil
	PendClear()
	B.blockT = 0
	if was then B.Send(true) end
end

local function BodyFrom(pos) return pos.x, pos.y, pos.z + 16 end

-- the aim: the skater's camera (SkateGM.API.View, set every frame in its CalcView)
local function AimFrom(api)
	local view = api.View and api.View() or nil
	if view and view.origin and view.angles then
		local o, a = view.origin, view.angles
		local fx, fy, fz = M.forward(a.p, a.y)
		return o.x, o.y, o.z, fx, fy, fz
	end
	local lp = LocalPlayer()
	local e, a = lp:EyePos(), lp:EyeAngles()
	local fx, fy, fz = M.forward(a.p, a.y)
	return e.x, e.y, e.z, fx, fy, fz
end

-- for the HUD's "can I attach here?" probe: nil when not applicable
function C.BoardProbeInput()
	local api = C.API()
	if not (api and T.enabled and T.boardEnabled and api.IsSkating and api.IsSkating()) then return nil end
	local pos, vel = api.SkaterPos(), api.Velocity()
	if not (pos and vel) then return nil end
	local ex, ey, ez, ax, ay, az = AimFrom(api)
	local bx, by, bz = BodyFrom(pos)
	return ex, ey, ez, ax, ay, az, bx, by, bz, vel.x, vel.y, vel.z
end

local function Attach(api, now)
	local pos, vel = api.SkaterPos(), api.Velocity()
	if not (pos and vel) then return false end
	local ex, ey, ez, ax, ay, az = AimFrom(api)
	local bx, by, bz = BodyFrom(pos)
	local lp = LocalPlayer()
	-- (the board lives in Skate 3's gravity, with no extra pull)
	local ok, kind = WS.FindAnchorWith(T.boardG, 1, lp, ex, ey, ez, ax, ay, az, bx, by, bz, vel.x, vel.y, vel.z, true)
	local S = B.S
	if not ok then
		S.whiffT = now
		B.nextFire = now + 0.25
		return false
	end
	local Hit = WS.Hit
	WS.SetAnchor(S, Hit.x, Hit.y, Hit.z, Hit.ent)
	S.nx, S.ny, S.nz = Hit.nx, Hit.ny, Hit.nz
	S.mode = 1
	S.kind = kind
	S.L = math.min(math.max(T.minRope, Hit.dist), T.maxDist + 100)
	S.t, S.t0 = 0, now
	S.zledge = false
	S.boost = 0
	S.lastUse = now
	B.blockT = 0
	B.lastTick = nil
	PendClear()
	-- rolling on the ground: a small hop, so the rope does not just drag the board
	local st = api.State and api.State() or nil
	if T.boardHop > 0 and type(st) == "string" and st:find("Ground", 1, true) then
		Launch(api, 0, 0, T.boardHop)
	end
	B.Send(true)
	return true
end

local function Release(api, kind)
	local S = B.S
	if S.mode == 1 and kind == "release" then
		local pos, vel = api.SkaterPos(), api.Velocity()
		if pos and vel then
			local ax, ay, az = WS.AnchorXYZ(S)
			local bx, by, bz = BodyFrom(pos)
			local nx, ny, nz = M.norm(bx - ax, by - ay, bz - az)
			local px, py, pz = PendSum()
			local vx, vy, vz = vel.x + px, vel.y + py, vel.z + pz
			local boost = M.releaseBoost(M.len(vx, vy, vz), -nz, vz, T)
			if boost > 0 then
				local wx, wy, wz = M.releaseVelocity(vx, vy, vz, boost, T)
				Launch(api, wx - vx, wy - vy, wz - vz)
				S.boost = boost
			end
		end
	end
	S.mode, S.ent = 0, nil
	S.relT = RealTime()
	PendClear()
	B.Send(true)
end

-- The rope, applied as a push. Called once per new engine tick.
local function ApplyRope(api, S, pos, vel, dtc, now)
	local ax, ay, az, valid = WS.AnchorXYZ(S)
	if not valid then Release(api, "gone") return end
	local bx, by, bz = BodyFrom(pos)
	local px, py, pz = PendSum()
	local vx, vy, vz = vel.x + px, vel.y + py, vel.z + pz
	local ivx, ivy, ivz = vx, vy, vz
	local nx, ny, nz, dist = M.norm(bx - ax, by - ay, bz - az)
	S.t = S.t + dtc
	if S.t < T.autoReelT and dist < S.L then S.L = math.max(T.minRope, dist) end
	if B.keys.reel and S.L > T.minRope then
		local L2 = math.max(T.minRope, S.L - T.reel * dtc)
		vx, vy, vz = M.reelVelocity(vx, vy, vz, nx, ny, nz, S.L, L2, T.reelAM)
		S.L = L2
	end
	local nvx, nvy, nvz, corr = M.constrain(bx, by, bz, vx, vy, vz, ax, ay, az, S.L, dtc, T.boardG, T.boardMaxPull)
	local dvx, dvy, dvz = nvx - ivx, nvy - ivy, nvz - ivz
	local dl = M.len(dvx, dvy, dvz)
	S.tension = S.tension + (M.tensionG(corr, dtc, T.boardG) - S.tension) * 0.25
	if dl > 1e-3 then
		if dl > T.boardMaxDv then
			local k = T.boardMaxDv / dl
			dvx, dvy, dvz = dvx * k, dvy * k, dvz * k
		end
		local tick = B.lastTick or 0
		if Launch(api, dvx, dvy, dvz) then
			PendAdd(tick, dvx, dvy, dvz)
			B.pushes = B.pushes + 1
			B.blockT = 0
		else
			B.rejected = B.rejected + 1
			B.blockT = B.blockT + dtc
		end
	end
end

local function ApplyZip(api, S, pos, vel, dtc, now)
	local ax, ay, az, valid = WS.AnchorXYZ(S)
	if not valid then Release(api, "gone") return end
	local bx, by, bz = BodyFrom(pos)
	local px, py, pz = PendSum()
	local vx, vy, vz = vel.x + px, vel.y + py, vel.z + pz
	local gx, gy, gz = ax + S.gox, ay + S.goy, az + S.goz
	local tx, ty, tz, speed, d = M.zipStep(bx, by, bz, gx, gy, gz, S.zspeed, dtc, T)
	S.zspeed = speed
	S.zt = S.zt + dtc
	local tick = B.lastTick or 0
	if M.zipDone(d, S.zt / 1.5, T) then
		-- arrive: hop over the ledge, or carry on with part of the zip speed
		local wx, wy, wz
		if S.zledge then
			local hx, hy = M.norm(gx - bx, gy - by, 0)
			wx, wy, wz = M.vaultVelocity(hx, hy, S.zinx, S.ziny, S.zspeed, T)
		else
			local dx, dy, dz = M.norm(gx - bx, gy - by, gz - bz)
			wx, wy, wz = M.exitVelocity(dx, dy, dz, S.zspeed)
		end
		local dvx, dvy, dvz = wx - vx, wy - vy, wz - vz
		if Launch(api, dvx, dvy, dvz) then PendAdd(tick, dvx, dvy, dvz) end
		S.mode, S.ent, S.relT = 0, nil, RealTime()
		B.Send(true)
		return
	end
	-- steer the skater's velocity toward the zip's: a bounded change per tick
	local dvx, dvy, dvz = tx - vx, ty - vy, tz - vz
	local dl = M.len(dvx, dvy, dvz)
	local cap = T.zipAccel * dtc
	if dl > cap then local k = cap / dl dvx, dvy, dvz = dvx * k, dvy * k, dvz * k end
	if Launch(api, dvx, dvy, dvz) then
		PendAdd(tick, dvx, dvy, dvz)
		B.blockT = 0
	else
		B.blockT = B.blockT + dtc
	end
end

local function TryZip(api, now)
	local pos, vel = api.SkaterPos(), api.Velocity()
	if not (pos and vel) then return false end
	local ex, ey, ez, ax, ay, az = AimFrom(api)
	local bx, by, bz = BodyFrom(pos)
	local S = B.S
	local ok
	if S.mode == 1 then
		-- zip to the web in use
		local x, y, z = WS.AnchorXYZ(S)
		local ux, uy, uz = M.norm(bx - x, by - y, bz - z)
		local Hit = WS.Hit
		Hit.x, Hit.y, Hit.z, Hit.ent, Hit.kind = x, y, z, S.ent, 1
		Hit.dist = M.dist(bx, by, bz, x, y, z)
		Hit.gx, Hit.gy, Hit.gz, Hit.ledge, Hit.inx, Hit.iny = x + ux * 30, y + uy * 30, z + uz * 30, false, 0, 0
		ok = Hit.dist >= 150
	else
		ok = WS.FindZip(LocalPlayer(), ex, ey, ez, ax, ay, az, bx, by, bz)
	end
	if not ok then B.nextFire = now + 0.25 return false end
	local Hit = WS.Hit
	WS.SetAnchor(S, Hit.x, Hit.y, Hit.z, Hit.ent)
	S.gox, S.goy, S.goz = Hit.gx - Hit.x, Hit.gy - Hit.y, Hit.gz - Hit.z
	S.mode = 2
	S.zledge = Hit.ledge
	S.zinx, S.ziny = Hit.inx, Hit.iny
	local dx, dy, dz = M.norm(Hit.gx - bx, Hit.gy - by, Hit.gz - bz)
	S.zspeed = math.max(T.zipStart, vel.x * dx + vel.y * dy + vel.z * dz)
	S.zt, S.t0, S.L = 0, now, Hit.dist
	S.dive = false
	S.lastUse = now
	B.blockT = 0
	B.lastTick = nil
	PendClear()
	B.Send(true)
	return true
end

-- foot -> board: carry the swing's speed onto the board (best effort: the engine only
-- takes a push once the skater is riding or in the air, so this retries for a moment)
local function HandoffThink(api, st)
	local h = B.handoff
	if not h then return end
	if RealTime() - h.t > 2.5 then B.handoff = nil return end
	if not C.CanPush(st) then return end
	if Launch(api, h.vx, h.vy, h.vz) then B.handoff = nil end
end

function B.OnStart(api)
	local cl = Client()
	local frac = CCV.board_handoff:GetFloat()
	local recent = cl and (CurTime() - (cl.lastWebAt or -100)) < 4
	local speed = math.sqrt(B.footVx ^ 2 + B.footVy ^ 2 + B.footVz ^ 2)
	if frac > 0 and recent and speed > 400 then
		B.handoff = { vx = B.footVx * frac, vy = B.footVy * frac, vz = B.footVz * frac, t = RealTime() }
	else
		B.handoff = nil
	end
end

local function BoardThink()
	if B.err then return end
	local api = C.API()
	if not api then return end
	if not (api.IsSkating and api.Launch and api.Velocity and api.SkaterPos) then
		-- an older/different SkateGM without the calls the rope needs: stay out of its way
		B.err = "this SkateGM has no API.Launch / Velocity / SkaterPos"
		return
	end
	local skating = api.IsSkating and api.IsSkating() == true
	if not skating then
		if B.wasSkating then
			B.wasSkating = false
			B.handoff = nil
			BoardClear()
		end
		-- remember how fast we were moving as a normal player, for the handoff
		local lp = LocalPlayer()
		if IsValid(lp) then
			local v = lp:GetVelocity()
			B.footVx, B.footVy, B.footVz = v.x, v.y, v.z
		end
		return
	end
	if not B.wasSkating then
		B.wasSkating = true
		B.OnStart(api)
	end
	local now = CurTime()
	local S = B.S
	local st = api.State and api.State() or nil
	HandoffThink(api, st)
	if not (T.enabled and T.boardEnabled) then
		if B.Active() then BoardClear() end
		return
	end

	ReadKeys()
	local k, was = B.keys, B.was
	local firePressed = k.fire and not was.fire
	local zipPressed = k.zip and not was.zip
	was.fire, was.zip = k.fire, k.zip
	local pushable = C.CanPush(st)
	local dtc = math.Clamp(FrameTime(), 1 / 120, 1 / 20)

	-- one engine tick at a time: the polled pose only changes when the engine has stepped
	B.frame = B.frame + 1
	local tick = api.Tick and api.Tick() or B.frame
	local newTick = tick ~= B.lastTick
	if newTick then
		B.lastTick = tick
		PendDrop(tick)
	end

	if S.mode == 0 then
		if S.dive and not k.dive then S.dive = false end
		if pushable and now >= B.nextFire then
			if k.fire and (firePressed or not B.fireLatch) then
				if Attach(api, now) then B.fireLatch = true end
			elseif zipPressed then
				TryZip(api, now)
			end
		end
		if not k.fire then B.fireLatch = false end
		if k.dive and pushable and newTick and type(st) == "string" and st:find("Air", 1, true) then
			local vel = api.Velocity()
			if vel and vel.z > -T.diveTerminal then
				S.dive = true
				local dv = T.diveGrav * dtc
				if Launch(api, 0, 0, -dv) then PendAdd(tick, 0, 0, -dv) end
			end
		end
		return
	end

	if S.mode == 1 then
		if not k.fire then Release(api, "release") return end
		if zipPressed and TryZip(api, now) then return end
		if newTick then
			local pos, vel = api.SkaterPos(), api.Velocity()
			if pos and vel then ApplyRope(api, S, pos, vel, dtc, now) end
		end
	elseif S.mode == 2 then
		if newTick then
			local pos, vel = api.SkaterPos(), api.Velocity()
			if pos and vel then ApplyZip(api, S, pos, vel, dtc, now) end
		end
		if not k.zip and S.zt > 0.25 then
			-- let go of the zip button: cancel it (the skater keeps the speed)
			S.mode, S.ent = 0, nil
			B.Send(true)
			return
		end
	end
	-- bailed, went on foot, started a grind...: the engine will not take a push, so the web lets go
	if S.mode ~= 0 then
		if not pushable then B.blockT = B.blockT + dtc end
		if B.blockT > 0.35 then
			S.mode, S.ent = 0, nil
			PendClear()
			B.Send(true)
			return
		end
		B.Send(false) -- keep-alive for the server's watchdog
	end
end

hook.Add("Think", "webswing_board", function()
	local ok, err = pcall(BoardThink)
	if not ok then
		-- never let a SkateGM change take SkateGM (or anything else) down with us
		B.err = tostring(err)
		WS.ReportError("board mode", err)
		ErrorNoHalt("[WebSwing] board mode is switched off for this session (ws_status shows why)\n")
	end
end)

-- we died: nothing may be left hanging
gameevent.Listen("entity_killed")
hook.Add("entity_killed", "webswing_board_killed", Guard("entity_killed", function(data)
	local lp = LocalPlayer()
	if IsValid(lp) and data and data.entindex_killed == lp:EntIndex() then BoardClear() end
end))

-- where the skater's hand is, in the client's frame (nil: use the normal player model)
function C.HandPos(ply)
	local api = C.API()
	if not (api and api.PoseOf) then return nil end
	local s = rawget(_G, "SkateGM")
	local P
	if ply == LocalPlayer() and type(s) == "table" and s.renderP then P = s.renderP end
	P = P or api.PoseOf(ply)
	if not P then return nil end
	local h = P.RIGHTHAND or P.LEFTHAND or P.RIGHTFOREARM or P.HIPS
	if not h then return nil end
	return h.x, h.y, h.z
end

concommand.Add("ws_board", function()
	local api = C.API()
	if not api then
		chat.AddText(Color(255, 90, 80), "[WebSwing] ", color_white, "SkateGM isn't installed.")
		return
	end
	if api.IsSkating() or api.IsLoading() then return end
	if api.CanSkate and not api.CanSkate() then
		chat.AddText(Color(255, 90, 80), "[WebSwing] ", color_white, "SkateGM can't start: " .. tostring(api.LastError and api.LastError() or "?"))
		return
	end
	api.StartSkating()
end, nil, "Drop onto your SkateGM board (keeps your swing's speed)")
