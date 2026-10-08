AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

DEFINE_BASECLASS("gamemode_sandbox")

util.AddNetworkString(SKATEGM_GM.NET_START)
util.AddNetworkString(SKATEGM_GM.NET_FAILED)
util.AddNetworkString(SKATEGM_GM.NET_RETRY)

-- spawned: no weapons, then skating
function GM:PlayerLoadout(ply) return true end

function GM:PlayerSpawn(ply, transiton)
	if ply.SkateGMFailed then
		-- (still failed: back to watching)
		timer.Simple(0, function() if IsValid(ply) then SKATEGM_GM.Spectate(ply, ply.SkateGMFailed) end end)
		return
	end
	BaseClass.PlayerSpawn(self, ply, transiton)
	-- watching from the spawn (not walking about) until Skater mode is on
	SKATEGM_GM.Wait(ply)
	ply.SkateGMAsked = CurTime()
	timer.Simple(0.5, function()
		if not IsValid(ply) then return end
		net.Start(SKATEGM_GM.NET_START)
		net.Send(ply)
	end)
end

-- waiting for Skater mode: a fixed view from the spawn point (the skater
-- starts where the player is, so they mustn't roam off meanwhile)
function SKATEGM_GM.Wait(ply)
	ply:StripWeapons()
	ply:Spectate(OBS_MODE_FIXED)
	ply.SkateGMWaiting = true
end

-- on the board: not waiting, not failed
hook.Add("SkateGMEnter", "skategm_gm", function(ply)
	ply.SkateGMFailed = nil
	ply:SetNW2String("SkateGMFailed", "")
	if ply.SkateGMWaiting or ply:GetObserverMode() ~= OBS_MODE_NONE then
		ply.SkateGMWaiting = nil
		ply:UnSpectate()
	end
end)

function SKATEGM_GM.Spectate(ply, why)
	ply.SkateGMWaiting = nil
	ply.SkateGMFailed = why
	ply:SetNW2String("SkateGMFailed", why)
	ply:StripWeapons()
	ply:Spectate(OBS_MODE_ROAMING)
end

function SKATEGM_GM.Retry(ply)
	ply.SkateGMFailed = nil
	ply:SetNW2String("SkateGMFailed", "")
	ply:UnSpectate()
	ply:Spawn()
end


net.Receive(SKATEGM_GM.NET_FAILED, function(_, ply)
	local why = string.sub(net.ReadString(), 1, 400)
	if why == "" then why = "Skater mode didn't start" end
	if ply.SkateGM then return end
	SKATEGM_GM.Spectate(ply, why)
end)

net.Receive(SKATEGM_GM.NET_RETRY, function(_, ply)
	if not ply.SkateGMFailed then return end
	if CurTime() - (ply.SkateGMRetryAt or 0) < 3 then return end
	ply.SkateGMRetryAt = CurTime()
	SKATEGM_GM.Retry(ply)
end)

-- none of Garry's Mod's own gameplay: no noclip, weapons, tools, vehicles,
-- spawning things (props, NPCs, ragdolls, effects, entities - park parts
-- come from the park editor), flashlight, sprays or suicide. (Sandbox stays
-- underneath only for its saves and limits.) A skater somehow out of
-- Skater mode for long is told to go back in.
local function No() return false end
GM.PlayerNoClip = No
GM.PlayerCanPickupWeapon = No
GM.PlayerCanPickupItem = No
GM.CanPlayerEnterVehicle = No
GM.PlayerSpawnVehicle = No
GM.PlayerSpawnSWEP = No
GM.PlayerGiveSWEP = No
GM.PlayerSpawnProp = No
GM.PlayerSpawnRagdoll = No
GM.PlayerSpawnEffect = No
GM.PlayerSpawnNPC = No
GM.PlayerSpawnSENT = No
GM.PlayerSpawnObject = No
GM.PlayerSwitchFlashlight = function(_, ply, on) return not on end
GM.CanPlayerSuicide = No
GM.PlayerSpray = function() return true end
GM.PhysgunPickup = No
GM.GravGunPickupAllowed = No
GM.CanTool = No
GM.CanProperty = No
GM.CanDrive = No

function GM:Think()
	BaseClass.Think(self)
	local now = CurTime()
	if now < (SKATEGM_GM.nextCheck or 0) then return end
	SKATEGM_GM.nextCheck = now + 1
	for _, ply in ipairs(player.GetHumans()) do
		if ply:Alive() and not ply.SkateGM and not ply.SkateGMFailed then
			ply.SkateGMOffSince = ply.SkateGMOffSince or now
			local asked = ply.SkateGMAsked or 0
			if now - ply.SkateGMOffSince > 3 and now - asked > 5 then
				ply.SkateGMAsked = now
				net.Start(SKATEGM_GM.NET_START)
				net.Send(ply)
			end
			if now - ply.SkateGMOffSince > SKATEGM_GM.START_TIMEOUT then
				SKATEGM_GM.Spectate(ply, "Skater mode didn't start in " .. SKATEGM_GM.START_TIMEOUT .. " seconds")
			end
		else
			ply.SkateGMOffSince = nil
		end
	end
end
