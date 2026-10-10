-- shared/json_decode.lua (borrowed rxi/json.lua decode half, with limits) and the shared/json.lua encoder round trip.
local T, H = ...
T.group("json")
local D = require("shared.json_decode")
local E = require("shared.json")

T.test("decodes objects, arrays, numbers, escapes, unicode and literals", function()
	local t = D.decode([[ {"a":[1,2.5,-3e2,{"b":"xé\n\"q\""}],"c":true,"d":null,"e":false,"f":"😀"} ]])
	T.eq(t.a[1], 1); T.eq(t.a[2], 2.5); T.eq(t.a[3], -300)
	T.eq(t.a[4].b, "x\xc3\xa9\n\"q\"")
	T.eq(t.c, true); T.eq(t.d, nil); T.eq(t.e, false)
	T.eq(t.f, "\xf0\x9f\x98\x80", "a surrogate pair becomes one UTF-8 code point")
	T.eq(#D.decode("[]"), 0)
end)

T.test("bad input is an error, never a crash or a hang: syntax, trailing garbage, control characters, unterminated strings", function()
	for _, bad in ipairs({ "", "{", "[1,", '{"a" 1}', "{1:2}", "nope", "[1] x", '"abc', '"a\nb"', "[01x]", '{"a":}', "\0" }) do
		local ok = pcall(D.decode, bad)
		T.falsy(ok, "should reject " .. string.format("%q", bad))
	end
	T.throws(function() D.decode(nil) end)
	T.throws(function() D.decode(5) end)
end)

T.test("limits: nesting depth and text length are capped (the text comes from a browser page)", function()
	T.no_throw(function() D.decode(string.rep("[", 12) .. string.rep("]", 12)) end)
	T.throws(function() D.decode(string.rep("[", 13) .. string.rep("]", 13)) end)
	T.throws(function() D.decode(string.rep("{\"a\":", 30) .. "1" .. string.rep("}", 30)) end)
	T.throws(function() D.decode(string.rep(" ", 70000) .. "1") end)
	T.eq(D.decode("[1]", { max_len = 3 })[1], 1)
	T.throws(function() D.decode("[1,2]", { max_len = 3 }) end)
	-- the depth counter is reset after an error: a later valid decode works
	T.eq(D.decode("[[1]]")[1][1], 1)
end)

T.test("round trip: what the encoder writes for the UI payloads decodes to the same data", function()
	local V = require("shared.view")
	local data = { a = 1, b = { 1, 2, 3 }, c = "x\ny\"z", d = { e = true, f = { g = 0.25 } }, h = {} }
	local back = D.decode(E.encode(data))
	T.eq(back.a, 1); T.eq(back.b[3], 3); T.eq(back.c, "x\ny\"z"); T.eq(back.d.e, true); T.eq(back.d.f.g, 0.25); T.eq(#back.h, 0)
	local cat = V.catalog()
	local again = D.decode(E.encode(cat))
	T.eq(again.items.canned_beans.name, cat.items.canned_beans.name)
	T.note("catalog json: %d bytes", #E.encode(cat))
end)
