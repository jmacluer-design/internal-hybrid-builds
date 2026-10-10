-- mta/tests/harness.lua : path setup and small helpers shared by the test files (run through tests/run.lua).
local H = {}

local here = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."
H.tests = here
H.mta = here .. "/.."
H.res = H.mta .. "/outbreak"            -- the resource folder (what an MTA server would see)
H.tools = H.mta .. "/tools"
H.sim_root = H.mta .. "/../"            -- hybrids/outbreak (the canonical sim + its tests)

-- the resource's own files, reachable with require("shared.x") / require("sim.x") / require("server.x") in plain Lua (the mock gives the sandboxes their own `require` through bootstrap_mta.lua)
package.path = H.res .. "/?.lua;" .. here .. "/?.lua;" .. H.sim_root .. "tests/?.lua;" .. H.tools .. "/?.lua;" .. package.path

local Mock = require("mock_mta")
H.Mock = Mock

-- a booted mock: server + client, advanced `warm_ms` so the owner handshake and the first events have been processed
function H.boot(opts)
	opts = opts or {}
	local settings = { debug = "1", selftest = "0", autosave = "0", store = "file" }
	for k, v in pairs(opts.settings or {}) do settings[k] = v end
	local m = Mock.new({ root = H.res, settings = settings, fs = opts.fs, ambient_peds = opts.ambient_peds, invalid_ped_models = opts.invalid_ped_models,
		invalid_object_models = opts.invalid_object_models, player_name = opts.player_name, defs = opts.defs })
	m.capture = opts.capture ~= false
	if opts.setup then opts.setup(m) end
	if opts.boot ~= false then m:boot({ warm_ms = opts.warm_ms or 3000, client = opts.client }) end
	return m
end

function H.host(m) return m.sides.server.env.OutbreakHost() end
function H.world(m) return m.sides.server.env.OutbreakHost().world end
function H.client(m) return m.sides.client.env.OutbreakClient() end
function H.sreq(m, name) return m.sides.server.env.require(name) end
function H.creq(m, name) return m.sides.client.env.require(name) end
function H.errors_text(m) return #m.errors > 0 and table.concat(m.errors, "\n") or "" end

return H
