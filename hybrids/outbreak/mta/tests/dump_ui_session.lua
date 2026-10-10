-- tests/dump_ui_session.lua <out.json> : plays a short session through the REAL server + client Lua on the mock and writes every JavaScript string the client pushed into the
-- browser (executeBrowserJavascript), in order. tests/ui_bridge_test.mjs replays them into the real page in headless Chromium, so the browser test sees exactly what Lua sends,
-- not a hand-made fixture. Also writes the index of the priorities-screen push and the colonist ids. Usable under any runtime (luajit, lua5.4, lua5.1).
local here = (arg and arg[0] or "tests/dump_ui_session.lua"):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local H = require("harness")
local Json = require("shared.json")
local TUNING = require("data.tuning")

local out = arg and arg[1]
if not out then io.stderr:write("usage: dump_ui_session.lua <out.json>\n"); os.exit(2) end

local m = H.boot({ warm_ms = 3000 })
local host = H.host(m)
local o = H.sreq(m, "server.ctx").origin
m:player_move_to(o.x + 6, o.y + 6)
m:browser_trigger("ready", { v = 1 })  -- the page's own `ready` callback (js/main.js) when it has loaded: the client answers with `boot`, the server resends the world
m:step(1500)
host:debug("horde", { n = 12, dist = 90 })
m:step(30000)                      -- colonists work, the horde walks, the HUD and the colony state update
H.client(m).set_mode("colony")
m:step(1500)
local from = #m.browser_js + 1
H.creq(m, "client.ui").send("screen", { name = "priorities" }) -- what the client sends when the player opens a screen from a key bind
m:step(300)
if #m.errors > 0 then io.stderr:write("mock errors:\n" .. table.concat(m.errors, "\n") .. "\n"); os.exit(1) end

local colonists = {}
for _, c in ipairs(H.world(m).s.colonists) do colonists[#colonists + 1] = c.id end
local f = assert(io.open(out, "wb"))
f:write(Json.encode({ pushes = m.browser_js, priorities_index = from, colonists = colonists, base = { x = TUNING.base.x, y = TUNING.base.y } }))
f:close()
print(string.format("dumped %d JavaScript pushes (%d bytes of JSON) to %s", #m.browser_js, (function() local s = 0; for _, j in ipairs(m.browser_js) do s = s + #j end return s end)(), out))
m:stop()
