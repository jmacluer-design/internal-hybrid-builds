-- Knocking props over: light, loose physics props aren't solid to the skater;
-- skate into one and it goes flying. Delete lua/skategm_knock/ (and this
-- file) and props are solid as before.
if SERVER then
	AddCSLuaFile("skategm_knock/sh_knock.lua")
	AddCSLuaFile("skategm_knock/cl_knock.lua")
	include("skategm_knock/sh_knock.lua")
	include("skategm_knock/sv_knock.lua")
else
	include("skategm_knock/sh_knock.lua")
	include("skategm_knock/cl_knock.lua")
end
