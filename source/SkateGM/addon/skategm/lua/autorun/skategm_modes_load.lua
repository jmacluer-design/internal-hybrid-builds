if SERVER then AddCSLuaFile("skategm_modes/sh_modes.lua") end
if not SKATEGM_MODES or not SKATEGM_MODES.Register then include("skategm_modes/sh_modes.lua") end
