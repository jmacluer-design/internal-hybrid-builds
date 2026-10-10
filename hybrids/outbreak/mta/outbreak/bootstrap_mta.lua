-- bootstrap_mta.lua : MTA:SA has no `package.path` (and its `require` is a disabled stub: CLuaMain::InitSecurity), but a resource can read its own files with
-- fileExists / fileOpen / fileRead / fileClose and compile them with loadstring. This mirrors sim/bootstrap.lua (which does the same over FiveM's LoadResourceFile):
--
--   shared script, runs first on BOTH sides (meta.xml); a script has no return value, so it publishes the global OB_BOOT (end of the file)
--   OB_BOOT.install()                                      -- replaces the global `require` with one that loads resource files
--   local World = require("sim.world")                     -- sim/world.lua, data/tuning.lua, shared/util.lua, server/ctx.lua ... all work the same way
--
-- On the CLIENT the files must be listed as <file src="..."/> in meta.xml (the client only has what it downloaded), see meta.xml.
-- MTA's Lua is 5.1: `loadstring` takes the source text (5.1's `load` takes a reader function), so only `loadstring` is used here.
local B = {}

-- read a whole resource file; nil when it does not exist or cannot be opened. `path` is relative to the resource folder.
function B.read_file(path)
	if not fileExists(path) then return nil end
	local f = fileOpen(path, true) -- read only
	if not f then return nil end
	local size = fileGetSize(f)
	local data = ""
	if size and size > 0 then data = fileRead(f, size) or "" end
	fileClose(f)
	return data
end

-- standalone loader over any `read_file(path) -> string|nil` (mirrors sim/bootstrap.lua make_require; paths are "<dir>/<name>.lua" under `root`)
function B.make_require(read_file, root)
	local loaded, loading = {}, {}
	root = root or ""
	local function req(name)
		if loaded[name] ~= nil then return loaded[name] end
		if loading[name] then error("circular require of " .. name, 2) end
		local path = root .. name:gsub("%.", "/") .. ".lua"
		local src = read_file(path)
		if not src then error("module '" .. name .. "' not found (" .. path .. "): is it listed in meta.xml, and did you run mta/tools/sync_sim.sh + sync_shared.sh?", 2) end
		local fn, err = loadstring(src, "@" .. path)
		if not fn then error(err, 2) end
		loading[name] = true
		local result = fn(name)
		loading[name] = nil
		if result == nil then result = true end
		loaded[name] = result
		return result
	end
	return req, loaded
end

-- replace the global `require` (MTA's stock one is a disabled stub, so the replacement is always forced)
function B.install(read_file, root)
	local req, loaded = B.make_require(read_file or B.read_file, root)
	_G.require = req
	B.loaded = loaded
	return req
end

OB_BOOT = B -- a shared script has no return value; the side scripts (server/main.lua, client/main.lua) call OB_BOOT.install()
