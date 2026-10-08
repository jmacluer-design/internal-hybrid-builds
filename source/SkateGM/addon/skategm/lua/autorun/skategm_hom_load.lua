if not SKATEGM_MODES or not SKATEGM_MODES.Register then
	if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
	include("skategm_modes/sh_modes.lua")
end
if SERVER then
	AddCSLuaFile("skategm_hom/sh_hom.lua")
	AddCSLuaFile("skategm_hom/cl_hom.lua")
	include("skategm_hom/sh_hom.lua")
	include("skategm_hom/sv_hom.lua")
else
	include("skategm_hom/sh_hom.lua")
	include("skategm_hom/cl_hom.lua")
end
