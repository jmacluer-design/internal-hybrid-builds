-- Web Swing: server side.
--
-- The authoritative web state lives in the predicted SetupMove hook in sh_core.lua (it runs
-- on the server for every usercmd, so the server's own result is the truth). This file is
-- the bookkeeping around it: cleanup on death/respawn/disconnect, the rope's pull on props,
-- fall damage, and a few console commands.

local WS = WebSwing
local M = WS.Math
local T = WS.T
local Guard = WS.Guard

---------------------------------------------------------------------------
-- Cleanup: nothing may stay hanging after a death, respawn or disconnect
---------------------------------------------------------------------------
for _, ev in ipairs({ "PlayerDeath", "PlayerSilentDeath", "PlayerSpawn", "PlayerDisconnected" }) do
	hook.Add(ev, "webswing_clear_" .. ev, Guard(ev, function(ply)
		if IsValid(ply) then WS.ForceClear(ply, ev) end
	end))
end

---------------------------------------------------------------------------
-- Fall damage: swinging into the street at 2000 u/s is the point, not a mistake
---------------------------------------------------------------------------
hook.Add("GetFallDamage", "webswing_falldamage", Guard("GetFallDamage", function(ply, speed)
	if not T.noFallDamage then return end
	local S = ply.WSS
	if S and CurTime() - S.lastUse < T.fallGrace then return 0 end
end))

---------------------------------------------------------------------------
-- The rope pulls on what it hangs on
---------------------------------------------------------------------------
-- dv: the speed the rope just gave the player (toward the anchor). The anchor entity gets the
-- opposite impulse, at the anchor point: a light barrel is dragged toward you, a car barely
-- moves. Capped so a prop is yanked, never launched. Players and NPCs are not pushed. If a
-- prop-protection addon exposes CPPI, you only pull what you could physgun.
function WS.PropReaction(ply, S, dvx, dvy, dvz)
	if not T.propReaction then return end
	local ent = S.ent
	if not IsValid(ent) or ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() then return end
	local phys = ent:GetPhysicsObject()
	if not IsValid(phys) or not phys:IsMotionEnabled() then return end
	if ent.CPPICanPhysgun and not ent:CPPICanPhysgun(ply) then return end
	local mass = phys:GetMass()
	local fx, fy, fz = -dvx * T.playerMass, -dvy * T.playerMass, -dvz * T.playerMass
	local maxJ = mass * T.propMaxDv
	local j = M.len(fx, fy, fz)
	if j > maxJ then
		local k = maxJ / j
		fx, fy, fz = fx * k, fy * k, fz * k
	end
	phys:ApplyForceOffset(Vector(fx, fy, fz), Vector(S.ax, S.ay, S.az))
end

---------------------------------------------------------------------------
-- Console
---------------------------------------------------------------------------
-- panic button: let go of everything
concommand.Add("ws_release", function(ply)
	if IsValid(ply) then
		WS.ForceClear(ply, "ws_release")
		if WS.SkateGM.ClearBoard then WS.SkateGM.ClearBoard(ply) end
	end
end, nil, "Web Swing: let go of the web / zip / dive")

-- convenient in singleplayer and for admins (the spawn menu's Weapons tab works too)
concommand.Add("ws_give", function(ply)
	if not IsValid(ply) then return end
	if game.SinglePlayer() or ply:IsAdmin() then
		ply:Give("weapon_webswing")
		ply:SelectWeapon("weapon_webswing")
	else
		ply:ChatPrint("[WebSwing] Admins only.")
	end
end, nil, "Web Swing: give yourself the Web Shooters")

concommand.Add("ws_status_sv", function(ply)
	local function say(...)
		local s = string.format(...)
		if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, s .. "\n") else print(s) end
	end
	say("[WebSwing sv] v%s enabled=%s range=%d assist=%s boost=%.2f gravity x%.2f snap=%.1fs", WS.VERSION, tostring(T.enabled), T.maxDist, tostring(T.assist), T.boostMult, T.gravityScale, T.snapTime)
	say("[WebSwing sv] SkateGM installed: %s (board webs allowed: %s)", tostring(WS.SkateGM.Installed()), tostring(T.boardEnabled))
	say("[WebSwing sv] last error: %s", tostring(WS.lastError))
	for _, p in ipairs(player.GetAll()) do
		local S, B = p.WSS, p.WSB
		if (S and (S.mode ~= 0 or S.dive)) or (B and B.mode ~= 0) then
			say("  %s: foot mode=%d dive=%s, board mode=%d, tension %.2f g", p:Nick(), S and S.mode or 0, tostring(S and S.dive), B and B.mode or 0, S and S.tension or 0)
		end
	end
end, nil, "Web Swing: server status")
