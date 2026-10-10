-- tests/replay_ui_calls.lua <calls.json> : the Lua half of the browser round trip. tests/ui_bridge_test.mjs records every mta.triggerEvent the real page made (event name, callback name,
-- the JSON STRING); this feeds each one, byte for byte, into the real client Lua as the local event outbreak:ui with the browser element as the source, and checks what arrives at the
-- server and in the sim. So: page click -> bridge -> JSON string -> shared/json_decode.lua -> client/ui.lua -> triggerServerEvent -> server/net.lua -> host -> sim. Any runtime.
local here = (arg and arg[0] or "tests/replay_ui_calls.lua"):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local H = require("harness")
local Json = require("shared.json")
local JsonDecode = require("shared.json_decode")
local NET = require("shared.mta_net")

local path = arg and arg[1]
if not path then io.stderr:write("usage: replay_ui_calls.lua <calls.json>\n"); os.exit(2) end
local f = assert(io.open(path, "rb"))
local calls = JsonDecode.decode(f:read("*a"), { max_len = 4000000, max_depth = 40 })
f:close()

local checks, failed = 0, 0
local function check(ok, msg)
	checks = checks + 1
	if not ok then failed = failed + 1; print("  FAIL  " .. msg) else print("  ok    " .. msg) end
end

local m = H.boot({ warm_ms = 3000 })
local ctx = H.sreq(m, "server.ctx")
local world = H.world(m)
local UI = H.creq(m, "client.ui")
local c1 = nil
for _, c in ipairs(world.s.colonists) do if c.id == "c1" then c1 = c end end
check(c1 ~= nil, "the mock sim has colonist c1 like the browser fixture")
local lv0 = c1.prio and c1.prio.cook
check(lv0 == 3, "and its cook priority starts at 3, the level the page showed before the first click (" .. tostring(lv0) .. ")")

local n_orders, n_in = #m:sent("server", NET.order), #m:sent("server", NET.ui_action)
local rejected0, decode0 = UI.stats.rejected, UI.stats.decode_errors
local by_name = {}
for _, c in ipairs(calls) do
	by_name[c.name] = (by_name[c.name] or 0) + 1
	check(c.event == "outbreak:ui" and type(c.json) == "string", string.format("call %s: event %s, JSON string of %d bytes", c.name, c.event, #c.json))
	m:browser_trigger(c.name, nil, c.json)
	m:step(120)
end
m:step(500)

check(UI.stats.rejected == rejected0 and UI.stats.decode_errors == decode0, "the client rejected nothing and could decode every body (rejected " .. (UI.stats.rejected - rejected0) .. ", decode errors " .. (UI.stats.decode_errors - decode0) .. ")")
check(#m.errors == 0, "no Lua error anywhere" .. (#m.errors > 0 and (": " .. table.concat(m.errors, " | ")) or ""))
local orders = {}
for i = n_orders + 1, #m:sent("server", NET.order) do orders[#orders + 1] = m:sent("server", NET.order)[i].args[1] end
local prio = {}
for _, o in ipairs(orders) do if o.kind == "priority" then prio[#prio + 1] = o end end
check(#prio == 5, "five priority orders reached the server (" .. #prio .. ")")
local levels = {}
for _, o in ipairs(prio) do levels[#levels + 1] = o.target.level; check(o.id == "c1" and o.target.work == "cook", "order for c1 / cook, level " .. tostring(o.target.level)) end
check(table.concat(levels, ",") == "4,0,1,2,3", "levels 4,0,1,2,3 as the page sent them (" .. table.concat(levels, ",") .. ")")
check(c1.prio.cook == 3, "and the sim holds the last one: c1 cook priority is " .. tostring(c1.prio.cook))
local results = m:out_events("order_result")
local ok_results = 0
for _, e in ipairs(results) do if e.ok then ok_results = ok_results + 1 end end
check(ok_results >= 5, ok_results .. " order_result events with ok = true came back")
check(H.host(m).speed == 2, "ui set_speed 2 reached the host (speed " .. tostring(H.host(m).speed) .. ")")
check(H.host(m).paused == true, "ui toggle_pause reached the host (paused " .. tostring(H.host(m).paused) .. ")")
check(#m:sent("server", NET.ui_action) > n_in, "ui callbacks became outbreak:ui_action events")
check(ctx.colony_mode == true, "screens / mode callbacks: the server knows the client is in colony view")
local ready = #m:sent("server", NET.ready)
check(ready >= 2, "the ready callback made the client tell the server (" .. ready .. " ready events)")
local boots = m:ui_messages("boot")
check(#boots >= 1 and boots[#boots].data.resource == "outbreak", "and the client answered the page with a boot message")
check(H.creq(m, "client.camera") ~= nil, "(client camera module present)")
m:stop()
check(#m.errors == 0, "stop is clean")
print(string.format("\n%d of %d checks passed (%s)", checks - failed, checks, _VERSION .. (jit and (" / " .. jit.version) or "")))
os.exit(failed == 0 and 0 or 1)
