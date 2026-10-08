-- Hot Potato: a separate game mode on top of Skater mode.
-- Everything lives in lua/skategm_potato/; delete that folder (and this file) and
-- the rest of the add-on works exactly as before.
if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_potato/sh_potato.lua")
	AddCSLuaFile("skategm_potato/cl_potato.lua")
	include("skategm_potato/sh_potato.lua")
	include("skategm_potato/sv_potato.lua")
else
	include("skategm_potato/sh_potato.lua")
	include("skategm_potato/cl_potato.lua")
end
