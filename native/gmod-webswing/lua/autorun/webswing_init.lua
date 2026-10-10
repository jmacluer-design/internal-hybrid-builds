-- Web Swing: loader, convars, network strings.
--
-- One global, WebSwing (like SkateGM's SkateGM). Everything else is local.
-- Load order: sh_swing (pure math) -> convars/tuning -> sh_core -> skategm_compat
-- -> server / client files. Safe to run again (lua refresh): hooks are replaced by name.

WebSwing = WebSwing or {}
local WS = WebSwing
WS.VERSION = "0.1.0"
WS.NET_BOARD = "webswing_board" -- client -> server: the skater's web (SkateGM board mode), see skategm_compat.lua

if SERVER then
	AddCSLuaFile("webswing/sh_swing.lua")
	AddCSLuaFile("webswing/sh_core.lua")
	AddCSLuaFile("webswing/skategm_compat.lua")
	AddCSLuaFile("webswing/cl_swing.lua")
	AddCSLuaFile("webswing/cl_hud.lua")
	util.AddNetworkString(WS.NET_BOARD)
end

---------------------------------------------------------------------------
-- Errors in a hook stop every other hook of that event for that call in GMod,
-- so every hook of this addon is wrapped: it can never take SkateGM's (or
-- anyone's) hooks down with it. Reported once every few seconds, in the console.
---------------------------------------------------------------------------
WS.lastError = nil
local errorAt = {}
function WS.ReportError(name, err)
	WS.lastError = name .. ": " .. tostring(err)
	local now = SysTime()
	if now - (errorAt[name] or -100) > 5 then
		errorAt[name] = now
		ErrorNoHalt("[WebSwing] error in " .. name .. ": " .. tostring(err) .. "\n")
	end
end
-- Guard(name, fn) -> a function that runs fn under pcall and returns its first result
function WS.Guard(name, fn)
	return function(...)
		local ok, r = pcall(fn, ...)
		if ok then return r end
		WS.ReportError(name, r)
	end
end

---------------------------------------------------------------------------
-- Convars
---------------------------------------------------------------------------
-- Server side, replicated to clients (so prediction uses the same numbers), saved.
local SVFLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY)
local function SV(name, default, help, lo, hi) return CreateConVar(name, default, SVFLAGS, help, lo, hi) end

WS.CV = {
	enabled       = SV("ws_enabled", "1", "Web Swing master switch: 0 turns webs, zips, dives and the SkateGM board web off for everyone", 0, 1),
	max_dist      = SV("ws_max_dist", "2800", "Web range, in units", 400, 8000),
	assist        = SV("ws_assist", "1", "Attach-point assist: when the aim misses (sky), search a cone for a building/prop surface up and ahead. 0 = off", 0, 1),
	assist_cone   = SV("ws_assist_cone", "48", "Attach-point assist: half-width of the search cone, in degrees", 10, 80),
	boost         = SV("ws_boost", "1", "Release boost multiplier (0 = no slingshot when you let go)", 0, 4),
	gravity_scale = SV("ws_gravity_scale", "1.6", "Gravity multiplier while hanging on a web (1 = the map's gravity; higher = snappier arcs)", 0.2, 4),
	pump          = SV("ws_pump", "670", "Forward key while swinging: acceleration along the arc (units/s^2)", 0, 3000),
	steer         = SV("ws_steer", "510", "A/D while swinging: sideways acceleration (units/s^2)", 0, 3000),
	reel_speed    = SV("ws_reel_speed", "590", "Crouch while swinging: how fast the rope shortens (units/s)", 0, 3000),
	min_rope      = SV("ws_min_rope", "120", "Shortest rope, in units (reeling stops here)", 30, 1000),
	zip_speed     = SV("ws_zip_speed", "2200", "Zip speed, in units/s", 300, 3400),
	zip_range     = SV("ws_zip_range", "3000", "Zip range, in units", 300, 8000),
	dive_gravity  = SV("ws_dive_gravity", "2440", "Extra downward pull while diving (units/s^2)", 0, 8000),
	max_speed     = SV("ws_max_speed", "3400", "Speed cap while swinging/zipping/diving (the engine's sv_maxvelocity is 3500)", 500, 3500),
	ground_hop    = SV("ws_ground_hop", "260", "Upward kick when you fire a web from the ground (so you leave the floor)", 0, 800),
	attach_players = SV("ws_attach_players", "0", "Webs may attach to other players", 0, 1),
	prop_reaction = SV("ws_prop_reaction", "1", "Server: the rope pulls on a physics prop it is anchored to (respects prop protection that exposes CPPI)", 0, 1),
	no_fall_damage = SV("ws_no_fall_damage", "1", "No fall damage for a few seconds after using a web, zip or dive", 0, 1),
	snap_time     = SV("ws_snap_time", "0.7", "Seconds a web may be blocked by the world before it snaps (0 = never)", 0, 10),
	sounds        = SV("ws_sounds", "1", "Web Swing sounds (stock GMod sounds)", 0, 1),
	-- SkateGM board mode (client authoritative: SkateGM simulates the skater on the client)
	board_enabled = SV("ws_board_enabled", "1", "Allow firing the web while skating on a SkateGM board", 0, 1),
	board_hop     = SV("ws_board_hop", "2.5", "Board mode: upward kick (m/s) when you fire a web while rolling on the ground", 0, 12),
	board_max_dv  = SV("ws_board_max_dv", "700", "Board mode: the most speed (units/s) one rope correction may add to the skater", 50, 4000),
	board_wait    = SV("ws_board_wait", "0.08", "Board mode: seconds between rope corrections (SkateGM takes a moment to show a push; longer = softer rope, safer)", 0.016, 0.3),
	board_gain    = SV("ws_board_gain", "0.85", "Board mode: the share of the needed correction applied per pulse (lower = a softer, safer rope)", 0.1, 1),
	board_lag     = SV("ws_board_lag", "0.025", "Board mode: how old the skater's polled position is, in seconds (the rope looks this far ahead)", 0, 0.15),
}

-- Client only: per player, saved.
if CLIENT then
	local function CL(name, default, help, lo, hi) return CreateClientConVar(name, default, true, false, help, lo, hi) end
	WS.CCV = {
		hud           = CL("ws_hud", "1", "Web Swing HUD (crosshair tint, speed, tension)", 0, 1),
		hud_board     = CL("ws_hud_board", "1", "Show the web crosshair while skating on a SkateGM board", 0, 1),
		hud_speed     = CL("ws_hud_speed", "1", "Show the speed readout while swinging", 0, 1),
		rope_width    = CL("ws_rope_width", "1", "Rope thickness multiplier", 0.3, 4),
		rope_sag      = CL("ws_rope_sag", "1", "How much a slack rope hangs (0 = ruler straight)", 0, 3),
		rope_wobble   = CL("ws_rope_wobble", "1", "Rope wobble after attaching (0 = none)", 0, 3),
		board_mouse   = CL("ws_board_mouse", "1", "Board mode: left mouse button holds the web, right mouse button zips", 0, 1),
		board_pad     = CL("ws_board_pad", "0", "Board mode, EXPERIMENTAL: the controller's Back/View button holds the web, a left-stick click reels (Skate 3 may also use Back)", 0, 1),
		key_dive      = CL("ws_key_dive", tostring(KEY_G or 17), "Board mode: key code that dives (hold). Default G. Not a SkateGM key.", 0, 200),
		key_reel      = CL("ws_key_reel", tostring(KEY_V or 32), "Board mode: key code that reels the rope in (hold). Default V. Not a SkateGM key.", 0, 200),
		board_handoff = CL("ws_board_handoff", "1", "Swing -> board: fraction of your swing speed the skater keeps when you drop onto the board (0 = off)", 0, 1),
		debug         = CL("ws_debug", "0", "Print Web Swing debug lines", 0, 1),
	}
end

---------------------------------------------------------------------------
-- Tuning: the numbers the math reads. Starts as the math module's defaults, and
-- is refreshed from the convars whenever one changes (no convar reads per tick).
---------------------------------------------------------------------------
WS.Math = include("webswing/sh_swing.lua")
local M = WS.Math
WS.T = M.params()
local T = WS.T

function WS.RefreshTuning()
	local CV = WS.CV
	T.enabled = CV.enabled:GetBool()
	T.maxDist = CV.max_dist:GetFloat()
	T.assist = CV.assist:GetBool()
	T.assistCone = CV.assist_cone:GetFloat()
	T.boostMult = CV.boost:GetFloat()
	T.gravityScale = CV.gravity_scale:GetFloat()
	T.pump = CV.pump:GetFloat()
	T.steer = CV.steer:GetFloat()
	T.reel = CV.reel_speed:GetFloat()
	T.minRope = CV.min_rope:GetFloat()
	T.zipSpeed = CV.zip_speed:GetFloat()
	T.zipRange = CV.zip_range:GetFloat()
	T.diveGrav = CV.dive_gravity:GetFloat()
	T.maxSpeed = CV.max_speed:GetFloat()
	T.groundHop = CV.ground_hop:GetFloat()
	T.attachPlayers = CV.attach_players:GetBool()
	T.propReaction = CV.prop_reaction:GetBool()
	T.noFallDamage = CV.no_fall_damage:GetBool()
	T.snapTime = CV.snap_time:GetFloat()
	T.sounds = CV.sounds:GetBool()
	T.boardEnabled = CV.board_enabled:GetBool()
	T.boardHop = CV.board_hop:GetFloat() * M.UNIT
	T.boardMaxDv = CV.board_max_dv:GetFloat()
	T.boardWait = CV.board_wait:GetFloat()
	T.boardGain = CV.board_gain:GetFloat()
	T.boardLag = CV.board_lag:GetFloat()
	-- the zip's pace follows its top speed
	T.zipStart = math.min(T.zipStart, T.zipSpeed)
	T.zipAccel = T.zipSpeed * 3
	T.maxPull = 9000
end
-- fixed extras (not convars)
T.minAttach = 200          -- a web needs at least this much room
T.groundHop = 260
T.fallGrace = 5            -- seconds of "no fall damage" after the last web/zip/dive
T.playerMass = 85          -- for the rope's pull on props
T.propMaxDv = 700          -- a prop is yanked by at most this much speed per tick
T.boardG = 386             -- Skate 3's world gravity in units/s^2 (9.81 m/s^2), for the rope prediction only
T.boardMaxPull = 6000

for name, cv in pairs(WS.CV) do
	cvars.AddChangeCallback(cv:GetName(), function() WS.RefreshTuning() end, "webswing_" .. name)
end
WS.RefreshTuning()

---------------------------------------------------------------------------
-- The rest
---------------------------------------------------------------------------
include("webswing/sh_core.lua")
include("webswing/skategm_compat.lua")
if CLIENT then
	include("webswing/cl_swing.lua")
	include("webswing/cl_hud.lua")
else
	include("webswing/sv_swing.lua")
end
