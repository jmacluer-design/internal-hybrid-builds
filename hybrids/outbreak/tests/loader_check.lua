-- Run in a SEPARATE process by tests/loader_test.lua: loads the whole sim through sim/bootstrap.lua with the standard `require`
-- search path disabled (the way a FiveM resource would), runs a short colony and prints the state hash.
--   luajit tests/loader_check.lua <root> <days>
local root, days = arg[1], tonumber(arg[2]) or 3
local function read(path)
	local f = io.open(root .. "/" .. path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end
local compile = loadstring or load
local boot = compile(read("sim/bootstrap.lua"), "@sim/bootstrap.lua")()
package.path = "/nonexistent/?.lua"      -- the normal search path finds nothing...
package.loaded["sim.world"] = nil
local ok = pcall(function() package.cpath = "" end)
_G.require = nil                          -- ...and there is no global require either, until we install ours
boot.install(read)
local World = require("sim.world")
local runner = require("sim.runner")
local save = require("sim.save")
local res = runner.run({ seed = 21, profile = "escalating", days = days, max_dt = 1 })
local back = save.load(save.save(res.world))
print(string.format("LOADER hash=%s reload=%s alive=%d", res.world:hash(), tostring(back:hash() == res.world:hash()), res.alive))
