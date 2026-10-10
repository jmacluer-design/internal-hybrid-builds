-- shared/boot.lua : FiveM has no filesystem `require` for resource files, so define one over LoadResourceFile (the sim ships its own
-- loader for exactly this: sim/bootstrap.lua). Runs first on BOTH the server and the client (shared_script). After it, every file of the
-- resource is reachable as require("shared.util"), require("sim.world"), require("client.pool") ...
-- On the client the files must be listed in `files {}` of fxmanifest.lua (LoadResourceFile only sees those there).
local res = GetCurrentResourceName()
local function read(path) return LoadResourceFile(res, path) end
local src = read("sim/bootstrap.lua")
assert(src, "outbreak: sim/bootstrap.lua is missing; run fivem/tools/sync_sim.sh and copy the whole resource folder")
local boot = load(src, "@sim/bootstrap.lua")()
boot.install(read, nil, true) -- force: a stock `require` cannot see resource files
