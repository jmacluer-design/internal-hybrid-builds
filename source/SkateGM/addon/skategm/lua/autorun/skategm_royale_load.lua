-- Run Royale: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_royale/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_royale/sh_royale.lua")
	AddCSLuaFile("skategm_royale/cl_royale.lua")
	include("skategm_royale/sh_royale.lua")
	include("skategm_royale/sv_royale.lua")
else
	include("skategm_royale/sh_royale.lua")
	include("skategm_royale/cl_royale.lua")
end
