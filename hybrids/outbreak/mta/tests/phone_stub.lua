-- phone_stub.lua: the REAL server Lua (server/phone.lua and everything under it) on the mock MTA, as a child process that a node test talks to over stdin / stdout (JSON lines), so a real browser can
-- drive the phone page against it without an MTA install (tests/phone_bridge_test.mjs). It stands in for MTA's HTTP call interface only: the node side does the login, this side runs phoneApi.
--   in : {"id":1,"fn":"phoneApi","account":"phone"|"phoneview","headers":{...},"args":["poll","sid",0,1]}   {"id":2,"cmd":"step","ms":2000}   {"id":3,"cmd":"restart"}   {"id":4,"cmd":"hash"}
--   out: {"id":1,"result":"<the string phoneApi returned>"}   {"id":2,"ok":true}   {"id":3,"ok":true}   {"id":4,"hash":"...","prio":{...}}
local here = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")) or "."
package.path = here .. "/?.lua;" .. here .. "/../../tests/?.lua;" .. package.path
local H = require("harness")
local Json = require("shared.json")
local unpack = table.unpack or unpack

local m, accounts
local function boot()
	if m then pcall(function() m:stop() end) end
	m = H.boot({ boot = false, settings = { debug = "0", selftest = "0", autosave = "0" } })
	m:load_side("server"); m:start_server()
	m:step(600)
	H.host(m):new_game(4242, "calm", nil)
	accounts = {
		phone = m:account("phone", { "resource.outbreak.phone_control", "resource.outbreak.phone_view" }),
		phoneview = m:account("phoneview", { "resource.outbreak.phone_view" }),
	}
end
boot()

local function reply(t) io.stdout:write(Json.encode(t), "\n"); io.stdout:flush() end
for line in io.lines() do
	local req = Json.decode(line)
	if type(req) ~= "table" then reply({ error = "bad request" })
	elseif req.cmd == "step" then m:step(req.ms or 1000); reply({ id = req.id, ok = true })
	elseif req.cmd == "restart" then boot(); reply({ id = req.id, ok = true })
	elseif req.cmd == "hash" then
		local col = H.sreq(m, "sim.colonist")
		local prio = {}
		for _, c in ipairs(H.world(m).s.colonists) do prio[c.id] = {}; for _, w in ipairs(col.WORK) do prio[c.id][w] = col.priority(c, w) end end
		reply({ id = req.id, hash = H.host(m):status().hash, prio = prio, speed = H.host(m).speed, buildings = #H.world(m).s.buildings })
	elseif req.fn then
		local res, err = m:http_call(accounts[req.account], req.headers or {}, req.fn, unpack(req.args or {}))
		reply({ id = req.id, result = res, error = err })
	else reply({ id = req.id, error = "unknown request" }) end
end
