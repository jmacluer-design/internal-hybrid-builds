include("shared.lua")

DEFINE_BASECLASS("gamemode_sandbox")

local C = SKATEGM_GM.client or {}
SKATEGM_GM.client = C
C.FAIL_AFTER = 2 -- off (not loading) this long after asking: it failed

local function API() return SkateGM and SkateGM.API end

-- into Skater mode, and kept there
-- (not spawned yet - just joined, or between lives - isn't a failure: the
-- start waits for it; C.Think tries again)
function C.Ready()
	local me = LocalPlayer()
	return IsValid(me) and me:Alive()
end

function C.Start(now)
	local a = API()
	if not a then return C.Fail("the SkateGM add-on isn't loaded") end
	if a.SetLocked then a.SetLocked(true) end
	if a.IsSkating() or a.IsLoading() then return end
	C.wanted = true
	if not C.Ready() then return end
	if a.CanSkate and not a.CanSkate() then return C.Fail(a.LastError and a.LastError() or "the SkateGM module couldn't load") end
	C.askedAt = now
	a.StartSkating()
end

function C.Fail(why)
	if C.failSent == why then return end
	C.failSent = why
	net.Start(SKATEGM_GM.NET_FAILED)
	net.WriteString(why or "")
	net.SendToServer()
end

function C.Think(now)
	local a = API()
	if a and a.SetLocked and not (a.IsLocked and a.IsLocked()) then a.SetLocked(true) end
	if a and (a.IsSkating() or a.IsLoading()) then
		C.offSince = nil
		if a.IsSkating() then C.askedAt, C.wanted, C.failSent = nil, nil, nil end
		return
	end
	if C.Failed() then return end
	-- asked while not spawned yet: start as soon as I am
	if C.wanted and not C.askedAt and C.Ready() then return C.Start(now) end
	if not C.askedAt then return end
	C.offSince = C.offSince or now
	if now - C.offSince > C.FAIL_AFTER then
		C.askedAt, C.offSince = nil, nil
		C.Fail(a and a.LastError and a.LastError() or "Skater mode didn't start")
	end
end

-- why I'm spectating (nil while skating or loading, whatever the server's
-- flag still says)
function C.Failed()
	local me = LocalPlayer()
	local a = API()
	if a and (a.IsSkating() or a.IsLoading()) then return nil end
	return IsValid(me) and me:GetNW2String("SkateGMFailed", "") ~= "" and me:GetNW2String("SkateGMFailed", "") or nil
end

function C.Retry()
	if not C.Failed() then return end
	C.failSent = nil
	net.Start(SKATEGM_GM.NET_RETRY)
	net.SendToServer()
end

net.Receive(SKATEGM_GM.NET_START, function() C.failSent = nil C.Start(RealTime()) end)
hook.Add("InitPostEntity", "skategm_gm", function() timer.Simple(1, function() C.Start(RealTime()) end) end)
hook.Add("Think", "skategm_gm", function() C.Think(RealTime()) end)
concommand.Add("skategm_gm_retry", function() C.Retry() end, nil, "SkateGM gamemode: try getting into Skater mode again")
-- (spectating: reload or use tries again)
hook.Add("PlayerBindPress", "skategm_gm", function(_, bind, pressed)
	if pressed and C.Failed() and (bind:find("+reload", 1, true) or bind:find("+use", 1, true) or bind:find("+jump", 1, true)) then C.Retry() return true end
end)

-- none of Garry's Mod's own menus or HUD: no spawn menu (Q), context menu
-- (C), weapon selection, crosshair or health
function GM:SpawnMenuOpen() return false end
function GM:ContextMenuOpen() return false end
C.HIDDEN_HUD = { CHudCrosshair = true, CHudWeaponSelection = true, CHudHealth = true, CHudBattery = true, CHudAmmo = true, CHudSecondaryAmmo = true, CHudDamageIndicator = true }
function GM:HUDShouldDraw(name)
	if C.HIDDEN_HUD[name] then return false end
	return BaseClass.HUDShouldDraw(self, name)
end

local fontsAt
local function Fonts()
	local h = ScrH()
	if fontsAt == h then return end
	fontsAt = h
	surface.CreateFont("skategm_gm_title", { font = "Roboto", size = math.max(22, math.floor(h * 0.04)), weight = 900 })
	surface.CreateFont("skategm_gm_text", { font = "Roboto", size = math.max(15, math.floor(h * 0.022)), weight = 600 })
end

local logo
-- the SkateGM logo, centred, its bottom at y
local function Logo(bottom)
	logo = logo or Material("skategm/logo.png", "smooth")
	if not logo or logo:IsError() then return end
	local lh = ScrH() * 0.16
	local lw = lh * 682 / 350
	surface.SetDrawColor(255, 255, 255, 255)
	surface.SetMaterial(logo)
	surface.DrawTexturedRect((ScrW() - lw) / 2, bottom - lh, lw, lh)
end
C.Logo = Logo

function GM:HUDPaint()
	BaseClass.HUDPaint(self)
	local why = C.Failed()
	if not why then
		-- waiting for Skater mode to come on (while it loads, Skater mode says
		-- so itself)
		local a = API()
		if a and not a.IsSkating() then Logo(ScrH() * 0.4) end
		if a and not a.IsSkating() and not a.IsLoading() then
			Fonts()
			local text = "Getting you into Skater mode..."
			draw.SimpleText(text, "skategm_gm_title", ScrW() / 2 + 2, ScrH() * 0.42 + 2, Color(0, 0, 0, 180), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
			draw.SimpleText(text, "skategm_gm_title", ScrW() / 2, ScrH() * 0.42, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
		end
		return
	end
	Fonts()
	local w, h = ScrW(), ScrH()
	local pw, ph = w * 0.56, h * 0.26
	local x, y = (w - pw) / 2, h * 0.32
	Logo(y - h * 0.02)
	draw.RoundedBox(12, x, y, pw, ph, Color(0, 0, 0, 215))
	draw.SimpleText("Couldn't put you into Skater mode", "skategm_gm_title", w / 2, y + h * 0.02, Color(255, 110, 90), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	-- the reason, wrapped
	local words, line, lines = {}, "", {}
	for wd in why:gmatch("%S+") do words[#words + 1] = wd end
	surface.SetFont("skategm_gm_text")
	for _, wd in ipairs(words) do
		local try = line == "" and wd or (line .. " " .. wd)
		if surface.GetTextSize(try) > pw - 40 then lines[#lines + 1] = line line = wd else line = try end
	end
	if line ~= "" then lines[#lines + 1] = line end
	for i, l in ipairs(lines) do
		draw.SimpleText(l, "skategm_gm_text", w / 2, y + h * 0.08 + (i - 1) * h * 0.03, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	end
	draw.SimpleText("You're spectating. Fix that, then press Reload (R) or Use to try again.", "skategm_gm_text", w / 2, y + ph - h * 0.045, Color(170, 170, 170), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
end
