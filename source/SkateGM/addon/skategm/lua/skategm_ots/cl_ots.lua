-- Own the Spot, client: follows the server's session state, runs your turn,
-- spectates everyone else's, and draws the display. Uses only SkateGM.API.
local C = { state = { phase = "idle" }, cam = nil }
OTS.client = C

local API = SKATEGM_MODES.API
local function Send(t) OTS.mode:Send(t) end
local CanSkate = SKATEGM_MODES.CanSkate
local function Say(text, bad) OTS.mode:Say(text, bad) end

local Commas = SKATEGM_MODES.Commas
local Clock = SKATEGM_MODES.Clock

local ACTIVE = { prep = true, countdown = true, turn = true, between = true }

function C.IsMine(st) return st.active and st.active ~= 0 and st.active == LocalPlayer():EntIndex() end
function C.Taking(st)
	local me = LocalPlayer():EntIndex()
	for _, p in ipairs(st.players or {}) do if p.ent == me then return true end end
	return false
end

---------------------------------------------------------------------------
-- following the server
---------------------------------------------------------------------------
function C.OnState(st, now)
	local prev = C.state or { phase = "idle" }
	C.state = st
	C.stateAt = now
	local mine, wasMine = C.IsMine(st), C.IsMine(prev)
	local a = API()
	-- someone else's turn: waiting, out of sight and out of the way
	if a and a.SetHidden then a.SetHidden("ots", (ACTIVE[st.phase] and C.Taking(st) and not mine) or false) end
	st.spotV = st.spot and Vector(st.spot[1], st.spot[2], st.spot[3]) or nil
	-- my turn begins: into Skater mode, then to the spot (see Think)
	if st.phase == "prep" and mine and not (prev.phase == "prep" and wasMine) then
		C.prep = { t = now, teleported = false, readySent = false }
		if a then a.StartSkating() end
		Say("your turn: get ready")
	end
	-- the clock starts: a fresh start from the spot, score counted from here
	if st.phase == "turn" and mine and not (prev.phase == "turn" and wasMine) then
		if a then
			if st.spotV then a.TeleportTo(st.spotV, st.yaw) end
			C.baseline = a.Score()
		end
		C.current, C.nextLive = 0, 0
	end
	-- my turn ended: send the final score
	if prev.phase == "turn" and wasMine and not (st.phase == "turn" and mine) then
		Send({ cmd = "final", score = C.current or 0 })
	end
	-- someone else's turn: watch instead of skating
	OTS.mode:Watch(ACTIVE[st.phase] and C.Taking(st) and not mine, function() return C.View(RealTime(), true) end)
	if st.phase ~= prev.phase or st.active ~= prev.active then C.cam = nil end
	if st.phase == "idle" and prev.phase ~= "idle" then C.baseline, C.current, C.prep = nil, nil, nil end
end

OTS.mode:OnState(function(st, now) C.OnState(st, now) end)

function C.Think(now)
	local st = C.state
	local a = API()
	if not a then return end
	if st.phase == "prep" and C.IsMine(st) and C.prep then
		if a.IsSkating() and not C.prep.teleported and st.spotV then
			a.TeleportTo(st.spotV, st.yaw)
			C.prep.teleported, C.prep.at = true, now
		end
		if C.prep.teleported and not C.prep.readySent and now - C.prep.at > 0.5 then
			C.prep.readySent = true
			Send({ cmd = "ready" })
		end
	elseif st.phase == "turn" and C.IsMine(st) and C.baseline then
		C.current = math.max(0, a.Score() - C.baseline)
		if now > (C.nextLive or 0) then
			C.nextLive = now + 0.25
			Send({ cmd = "live", score = C.current })
		end
	end
end
hook.Add("Think", "skategm_ots", function() C.Think(RealTime()) end)

---------------------------------------------------------------------------
-- spectating: a chase camera on the active skater
---------------------------------------------------------------------------
function C.View(now, skating)
	local st = C.state
	if not ACTIVE[st.phase] or C.IsMine(st) then return nil end
	if not (C.Taking(st) or C.watch) then return nil end
	local a = API()
	if a and a.IsSkating() and not skating then return nil end
	local target, dir
	local active = st.active and Entity(st.active)
	local P = a and IsValid(active) and a.PoseOf(active) or nil
	if P and P.HIPS then
		target = P.HIPS + Vector(0, 0, 10)
		local cam = C.cam or {}
		if cam.last then
			local moved = target - cam.last
			moved.z = 0
			if moved:LengthSqr() > 0.25 then cam.dir = LerpVector(0.08, cam.dir or moved:GetNormalized(), moved:GetNormalized()) end
		end
		cam.last = target
		dir = cam.dir or Angle(0, st.yaw or 0, 0):Forward()
		local want = target - dir:GetNormalized() * 130 + Vector(0, 0, 55)
		cam.pos = cam.pos and LerpVector(0.12, cam.pos, want) or want
		C.cam = cam
		return { origin = cam.pos, angles = (target - cam.pos):Angle(), drawviewer = false }
	elseif st.spotV then
		-- nobody to follow yet: look at the spot
		local d = Angle(0, (st.yaw or 0) + 180, 0):Forward()
		local pos = st.spotV - d * -160 + Vector(0, 0, 90)
		return { origin = pos, angles = (st.spotV - pos):Angle(), drawviewer = false }
	end
end
hook.Add("CalcView", "skategm_ots", function() return C.View(RealTime()) end)

---------------------------------------------------------------------------
-- display
---------------------------------------------------------------------------
local FONTS = {
	skategm_ots_big = { "Coolvetica", 0.05, 500 },
	skategm_ots_mid = { "Coolvetica", 0.026, 500 },
	skategm_ots_small = { "Roboto", 0.017, 700 },
}
local function Fonts() OTS.mode:Fonts(FONTS) end
local function Text(t, font, x, y, col, ax) SKATEGM_MODES.Text(t, font, x, y, col, ax or TEXT_ALIGN_LEFT, 1) end

local function Standings(st)
	local rows = {}
	for _, p in ipairs(st.players or {}) do rows[#rows + 1] = { name = p.name, best = p.best or 0, turns = p.turns or 0 } end
	for _, g in ipairs(st.gone or {}) do rows[#rows + 1] = { name = g.name .. " (left)", best = g.best or 0, turns = 1 } end
	table.sort(rows, function(x, y) return x.best > y.best end)
	return rows
end
C.Standings = Standings

function C.Paint(w, h, now)
	local st = C.state
	if st.phase == "idle" then return end
	Fonts()
	local gold, grey = Color(255, 210, 90), Color(200, 200, 200)
	local x, y, line = w * 0.02, h * 0.2, h * 0.024
	local hostName = "?"
	for _, p in ipairs(st.players or {}) do if p.ent == st.host then hostName = p.name end end
	local activeName
	for _, p in ipairs(st.players or {}) do if p.ent == st.active then activeName = p.name end end
	local left = (st.timeLeft or 0) - (now - (C.stateAt or now))

	Text("OWN THE SPOT", "skategm_ots_mid", x, y, gold)
	y = y + line * 1.3
	if st.phase == "lobby" then
		Text(string.format("host: %s   turns: %d s   rounds: %d", hostName, st.turn or 0, st.rounds or 0), "skategm_ots_small", x, y, grey)
		y = y + line
		for _, p in ipairs(st.players or {}) do Text("  " .. p.name, "skategm_ots_small", x, y) y = y + line * 0.85 end
		y = y + line * 0.3
		if st.host == LocalPlayer():EntIndex() then
			Text("you're the host: LB + D-pad left to start", "skategm_ots_small", x, y, gold)
		elseif not C.Taking(st) then
			Text("LB + D-pad left to join", "skategm_ots_small", x, y, gold)
		else
			Text("waiting for the host to start", "skategm_ots_small", x, y, grey)
		end
		return
	end
	Text(string.format("round %d / %d", math.min(st.round or 1, st.rounds or 1), st.rounds or 1), "skategm_ots_small", x, y, grey)
	y = y + line
	for i, r in ipairs(Standings(st)) do
		Text(string.format("%d. %s  %s", i, r.name, r.turns > 0 and Commas(r.best) or "-"), "skategm_ots_small", x, y, i == 1 and r.best > 0 and gold or color_white)
		y = y + line * 0.85
	end
	-- the middle of the screen: whose turn, countdown, clock, result
	local cx, cy = w / 2, h * 0.1
	if st.phase == "prep" then
		Text((activeName or "?") .. " is getting to the spot...", "skategm_ots_mid", cx, cy, grey, TEXT_ALIGN_CENTER)
	elseif st.phase == "countdown" then
		Text(C.IsMine(st) and "YOUR TURN" or ((activeName or "?") .. "'S TURN"), "skategm_ots_mid", cx, cy, gold, TEXT_ALIGN_CENTER)
		Text(tostring(math.max(1, math.ceil(left))), "skategm_ots_big", cx, cy + line * 1.4, color_white, TEXT_ALIGN_CENTER)
	elseif st.phase == "turn" then
		local score = C.IsMine(st) and (C.current or 0) or (st.live or 0)
		Text(string.format("%s   %s", C.IsMine(st) and "YOU" or (activeName or "?"), Clock(left)), "skategm_ots_mid", cx, cy, left <= 5 and Color(255, 110, 90) or color_white, TEXT_ALIGN_CENTER)
		Text(Commas(score), "skategm_ots_big", cx, cy + line * 1.4, gold, TEXT_ALIGN_CENTER)
	elseif st.phase == "between" and st.last then
		local r = st.last
		Text(r.skipped and (r.name .. ": skipped (" .. (r.reason or "") .. ")") or string.format("%s scored %s", r.name, Commas(r.score)),
			"skategm_ots_mid", cx, cy, gold, TEXT_ALIGN_CENTER)
	elseif st.phase == "final" then
		if st.winner then
			Text(string.format("%s OWNS THE SPOT", string.upper(st.winner.name)), "skategm_ots_big", cx, cy, gold, TEXT_ALIGN_CENTER)
			Text(Commas(st.winner.score) .. " points", "skategm_ots_mid", cx, cy + line * 2.2, color_white, TEXT_ALIGN_CENTER)
		else
			Text("nobody set a score", "skategm_ots_mid", cx, cy, grey, TEXT_ALIGN_CENTER)
		end
	end
end

local panel
local function EnsurePanel()
	if IsValid(panel) then return end
	panel = vgui.Create("DPanel")
	panel:SetPos(0, 0)
	panel:SetSize(ScrW(), ScrH())
	panel:SetMouseInputEnabled(false)
	panel:SetKeyboardInputEnabled(false)
	panel.Paint = function(self, w, h)
		if self:GetWide() ~= ScrW() then self:SetSize(ScrW(), ScrH()) end
		local ok, err = pcall(C.Paint, w, h, RealTime())
		if not ok and not C.paintErr then C.paintErr = tostring(err) Say("display error: " .. C.paintErr, true) end
	end
end
hook.Add("Think", "skategm_ots_panel", function()
	if C.state.phase ~= "idle" and vgui and vgui.Create then EnsurePanel() end
end)

-- the spot: a ring on the ground and a post
hook.Add("PostDrawTranslucentRenderables", "skategm_ots", function(depth, sky)
	local st = C.state
	if depth or sky or st.phase == "idle" or not st.spotV then return end
	local p = st.spotV + Vector(0, 0, 1)
	local pulse = 0.6 + 0.4 * math.sin(RealTime() * 3)
	local col = Color(255, 210, 90, 255 * pulse)
	for i = 0, 31 do
		local a0, a1 = i / 32 * math.pi * 2, (i + 1) / 32 * math.pi * 2
		render.DrawLine(p + Vector(math.cos(a0), math.sin(a0), 0) * 40, p + Vector(math.cos(a1), math.sin(a1), 0) * 40, col, true)
	end
	render.SetColorMaterial()
	render.DrawBox(p, angle_zero, Vector(-1, -1, 0), Vector(1, 1, 80), Color(255, 210, 90, 120 * pulse))
end)

---------------------------------------------------------------------------
-- commands, chat and the host menu
---------------------------------------------------------------------------
concommand.Add("skategm_ots_create", function(_, _, args)
	Send({ cmd = "create", turn = tonumber(args[1]) or OTS.TURN_DEFAULT, rounds = tonumber(args[2]) or OTS.ROUNDS_DEFAULT, canSkate = CanSkate() })
end, nil, "Own the Spot: open a challenge at your spot [turn seconds] [rounds]")
concommand.Add("skategm_ots_join", function() Send({ cmd = "join", canSkate = CanSkate() }) end)
concommand.Add("skategm_ots_leave", function() Send({ cmd = "leave" }) end)
concommand.Add("skategm_ots_start", function() Send({ cmd = "begin" }) end)
concommand.Add("skategm_ots_stop", function() Send({ cmd = "stop" }) end)
concommand.Add("skategm_ots_spot", function() Send({ cmd = "spot" }) end)
concommand.Add("skategm_ots_time", function(_, _, args) Send({ cmd = "settings", turn = tonumber(args[1]) }) end)
concommand.Add("skategm_ots_rounds", function(_, _, args) Send({ cmd = "settings", rounds = tonumber(args[1]) }) end)
concommand.Add("skategm_ots_watch", function() C.watch = not C.watch Say(C.watch and "watching the challenge" or "stopped watching") end)

-- !ots create [seconds] [rounds] | join | leave | start | stop | spot | time N | rounds N | menu | watch
local CHAT = { create = "skategm_ots_create", join = "skategm_ots_join", leave = "skategm_ots_leave", start = "skategm_ots_start",
	stop = "skategm_ots_stop", spot = "skategm_ots_spot", time = "skategm_ots_time", rounds = "skategm_ots_rounds", watch = "skategm_ots_watch" }
C.Chat = OTS.mode:ChatCommands(CHAT, "create [seconds] [rounds], join, leave, start, stop, spot, time N, rounds N, watch")

OTS.mode:Host({
	description = "take turns at a spot, best score wins; the spot is where you stand",
	options = {
		{ key = "turn", label = "Turn length", type = "number", min = OTS.TURN_MIN, max = OTS.TURN_MAX, step = 5, default = OTS.TURN_DEFAULT, format = function(v) return v .. " s" end },
		{ key = "rounds", label = "Rounds", type = "number", min = OTS.ROUNDS_MIN, max = OTS.ROUNDS_MAX, step = 1, default = OTS.ROUNDS_DEFAULT },
	},
	start = function(v, mode)
		mode:Send({ cmd = "create", turn = v.turn, rounds = v.rounds, canSkate = CanSkate() })
	end,
})

