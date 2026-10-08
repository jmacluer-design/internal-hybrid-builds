local function Modules(dir)
	local list = file.Find(dir .. "/*.lua", "LUA") or {}
	table.sort(list)
	for i, f in ipairs(list) do list[i] = dir .. "/" .. f end
	return list
end

local function Shared()
	local out = {}
	for _, dir in ipairs({ "skategm_boards", "skategm_fx" }) do
		for _, f in ipairs(Modules(dir)) do out[#out + 1] = f end
	end
	return out
end

if SERVER then
	AddCSLuaFile("skategm_board/sh_board.lua")
	AddCSLuaFile("skategm_board/cl_board.lua")
	include("skategm_board/sh_board.lua")
	include("skategm_board/sv_board.lua")
	for _, f in ipairs(Shared()) do
		AddCSLuaFile(f)
		include(f)
	end
else
	include("skategm_board/sh_board.lua")
	include("skategm_board/cl_board.lua")
	for _, f in ipairs(Shared()) do include(f) end
end
