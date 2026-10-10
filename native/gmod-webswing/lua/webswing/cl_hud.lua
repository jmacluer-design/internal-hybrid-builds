-- Web Swing: the HUD. A crosshair that tints when a web would attach (green: your aim hits
-- something, amber: the attach-point assist found a surface, dim red: nothing in reach), the
-- speed, and a tension bar while you hang on a web. Works for the SWEP and, while you skate,
-- for SkateGM board mode.

if not CLIENT then return end

local WS = WebSwing
local M = WS.Math
local T = WS.T
local CCV = WS.CCV
local Guard = WS.Guard
local CL = WS.Client
local probe = CL.probe

local svGravity = GetConVar("sv_gravity")
local clamp = M.clamp

---------------------------------------------------------------------------
-- Probe: "would a web attach where I'm aiming?" (a few times a second)
---------------------------------------------------------------------------
local nextProbe = 0
local function RunProbe(lp)
	local now = RealTime()
	if now < nextProbe then return end
	nextProbe = now + 0.12
	local C = WS.SkateGM
	local ex, ey, ez, ax, ay, az, bx, by, bz, vx, vy, vz
	local g, gs
	if C.IsSkating(lp) then
		ex, ey, ez, ax, ay, az, bx, by, bz, vx, vy, vz = C.BoardProbeInput()
		if not ex then probe.ok = false return end
		g, gs = T.boardG, 1
	else
		if not (WS.HoldingSwep(lp) and WS.EnvOK(lp)) then probe.ok = false return end
		local e, a, o, v = lp:GetShootPos(), lp:EyeAngles(), lp:GetPos(), lp:GetVelocity()
		ex, ey, ez = e.x, e.y, e.z
		ax, ay, az = M.forward(a.p, a.y)
		bx, by, bz = o.x, o.y, o.z + (lp:Crouching() and 26 or WS.CHEST)
		vx, vy, vz = v.x, v.y, v.z
		g, gs = svGravity and svGravity:GetFloat() or 600, T.gravityScale
	end
	local ok, kind = WS.FindAnchorWith(g, gs, lp, ex, ey, ez, ax, ay, az, bx, by, bz, vx, vy, vz, true)
	probe.ok, probe.kind, probe.at = ok, kind, now
	if ok then
		local h = WS.Hit
		probe.x, probe.y, probe.z, probe.dist = h.x, h.y, h.z, h.dist
	end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
local fontH
local function Fonts()
	local h = ScrH()
	if fontH == h then return end
	fontH = h
	surface.CreateFont("webswing_hud", { font = "Roboto", size = math.max(16, math.floor(h * 0.024)), weight = 700, extended = true })
	surface.CreateFont("webswing_hud_small", { font = "Roboto", size = math.max(12, math.floor(h * 0.016)), weight = 600, extended = true })
end

local COL_OK = Color(120, 255, 160)
local COL_ASSIST = Color(255, 210, 90)
local COL_NONE = Color(255, 90, 90, 170)
local COL_ON = Color(235, 245, 255)
local COL_SHADOW = Color(0, 0, 0, 170)
local col = Color(255, 255, 255)
local speedInt, speedText = -1, ""

local function SetCol(c) col.r, col.g, col.b, col.a = c.r, c.g, c.b, c.a or 255 end

local function Paint()
	if not (T.enabled and CCV.hud:GetBool()) then return end
	local lp = LocalPlayer()
	if not IsValid(lp) or not lp:Alive() then return end
	local C = WS.SkateGM
	local skating = C.IsSkating(lp)
	if skating then
		if not (T.boardEnabled and CCV.hud_board:GetBool()) then return end
	else
		local S = lp.WSS
		local busy = lp:GetNW2Int("ws_mode", 0) ~= 0 or lp:GetNW2Bool("ws_dive", false) or (S and (S.mode ~= 0 or S.dive))
		if not (busy or WS.HoldingSwep(lp)) then return end
	end
	Fonts()
	local V = WS.ViewState(lp)
	if V.mode == 0 then RunProbe(lp) end
	local cx, cy = ScrW() / 2, ScrH() / 2

	-- crosshair
	local c
	if V.mode ~= 0 then
		c = COL_ON
	elseif probe.ok and RealTime() - probe.at < 0.5 then
		c = probe.kind == 1 and COL_OK or COL_ASSIST
	else
		c = COL_NONE
	end
	SetCol(c)
	surface.DrawCircle(cx, cy, 9, col.r, col.g, col.b, col.a)
	surface.DrawCircle(cx, cy, 10, 0, 0, 0, 120)
	surface.SetDrawColor(col.r, col.g, col.b, col.a)
	surface.DrawRect(cx - 1, cy - 1, 2, 2)

	-- where the web would go (assist shows its pick)
	if V.mode == 0 and probe.ok and probe.kind == 2 then
		local s = Vector(probe.x, probe.y, probe.z):ToScreen()
		if s.visible then
			surface.SetDrawColor(COL_ASSIST.r, COL_ASSIST.g, COL_ASSIST.b, 220)
			surface.DrawOutlinedRect(s.x - 6, s.y - 6, 12, 12, 2)
		end
	end

	if V.mode == 0 and not V.dive then return end

	-- tension bar
	local bw, bh = 6, 64
	local bx, by = cx + 22, cy - bh / 2
	surface.SetDrawColor(0, 0, 0, 140)
	surface.DrawRect(bx - 1, by - 1, bw + 2, bh + 2)
	local fill = clamp(V.tension / 3, 0, 1)
	surface.SetDrawColor(120 + 135 * fill, 255 - 150 * fill, 160 - 100 * fill, 230)
	surface.DrawRect(bx, by + bh * (1 - fill), bw, bh * fill)

	-- speed
	if CCV.hud_speed:GetBool() then
		local speed
		if skating and C.API() and C.API().Velocity then
			local v = C.API().Velocity()
			speed = v and v:Length() or 0
		else
			speed = lp:GetVelocity():Length()
		end
		local kmh = math.floor(speed * 0.0254 * 3.6 + 0.5)
		if kmh ~= speedInt then speedInt, speedText = kmh, kmh .. " km/h" end
		draw.SimpleText(speedText, "webswing_hud", cx + 1, cy + 52 + 1, COL_SHADOW, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
		draw.SimpleText(speedText, "webswing_hud", cx, cy + 52, COL_ON, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
		local label = V.mode == 2 and "ZIP" or (V.dive and "DIVE" or nil)
		if label then
			draw.SimpleText(label, "webswing_hud_small", cx, cy + 52 + 26, COL_ASSIST, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
		end
	end
end
hook.Add("HUDPaint", "webswing_hud", Guard("HUDPaint", Paint))
