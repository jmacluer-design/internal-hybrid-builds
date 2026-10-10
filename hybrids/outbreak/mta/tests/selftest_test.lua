-- The determinism self-test the server runs inside the real MTA: its recorded hash is the one this runtime computes, and a mismatch is reported loudly.
local T, H = ...
T.group("selftest")
local interp = (arg and arg[-1]) or "lua5.4"

T.test("the recorded self-test hash equals what this runtime computes (the same under LuaJIT and Lua 5.4)", function()
	local S = require("shared.selftest")
	local ok, r = S.check()
	T.truthy(ok, "hash " .. tostring(r.hash) .. " recorded " .. tostring(r.expected) .. " " .. tostring(r.error))
	T.eq(r.reload_ok, true, "save -> load reproduces the state")
	T.lt(r.ms, 5000, "the self-test is cheap enough to run inside a game server (" .. r.ms .. " ms)")
	T.note("selftest hash %s, %d ms, save %d bytes (%s)", r.hash, r.ms, r.bytes, _VERSION .. (jit and "/LuaJIT" or ""))
	for _, rt in ipairs({ "luajit", "lua5.4" }) do
		local p = io.popen(string.format("%s %s/gen_selftest.lua --check 2>&1; echo EXIT:$?", rt, H.tools))
		local out = p:read("*a"); p:close()
		T.truthy(out:find("EXIT:0", 1, true), rt .. ": " .. out)
	end
end)

T.test("on start the server runs the self-test and logs OK; a wrong recorded hash is logged as FAILED and the owner is told", function()
	local m = H.boot({ settings = { selftest = "1" }, warm_ms = 4000 })
	local log = table.concat(m.log, "\n")
	T.truthy(log:find("selftest OK", 1, true), log)
	T.eq(H.sreq(m, "server.ctx").selftest.ok, true)
	m:stop()
	local fs = { server = { ["shared/selftest_data.lua"] = 'return { hash = "deadbeefdeadbeef" }' }, client = {} }
	local m2 = H.boot({ settings = { selftest = "1" }, fs = fs, warm_ms = 4000 })
	log = table.concat(m2.log, "\n")
	T.truthy(log:find("selftest FAILED", 1, true), log)
	local told = false
	for _, c in ipairs(m2.chat) do if c.text:find("selftest FAILED", 1, true) then told = true end end
	T.truthy(told, "the owner got a chat line")
	T.eq(#m2.errors, 0, H.errors_text(m2))
	-- the admin command reruns it
	m2:command("server", m2.player, "outbreak_selftest")
	local last = m2.chat[#m2.chat].text
	T.truthy(last:find("selftest FAILED", 1, true), last)
	m2:stop()
end)
