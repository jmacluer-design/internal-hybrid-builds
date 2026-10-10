-- bootstrap.lua : load the sim on hosts with no filesystem `package.path` (FiveM resources have LoadResourceFile instead).
--
--   -- in the adapter (FiveM, Lua 5.4):
--   local boot = load(LoadResourceFile(GetCurrentResourceName(), "sim/bootstrap.lua"), "@sim/bootstrap.lua")()
--   boot.install(function(path) return LoadResourceFile(GetCurrentResourceName(), path) end)   -- defines a global `require`
--   local World = require("sim.world")
--
-- Modules call the global `require` (some lazily, inside functions), so `install` defines one when the host has none.
-- `make_require` returns a standalone loader without touching globals. Paths are "sim/<name>.lua" and "data/<name>.lua"
-- relative to the resource root (pass a root prefix when the sim lives in a sub-folder).
local M = {}

function M.make_require(read_file, root)
	local compile = loadstring or load
	local loaded, loading = {}, {}
	root = root or ""
	local function req(name)
		if loaded[name] ~= nil then return loaded[name] end
		if loading[name] then error("circular require of " .. name, 2) end
		local path = root .. name:gsub("%.", "/") .. ".lua"
		local src = read_file(path)
		if not src then error("module '" .. name .. "' not found (" .. path .. ")", 2) end
		local fn, err = compile(src, "@" .. path)
		if not fn then error(err, 2) end
		loading[name] = true
		local result = fn(name)
		loading[name] = nil
		if result == nil then result = true end
		loaded[name] = result
		return result
	end
	return req
end

-- define the global `require` (replacing any existing one only when `force` is true)
function M.install(read_file, root, force)
	local g = _G
	if force or g.require == nil then g.require = M.make_require(read_file, root) end
	return g.require
end

return M
