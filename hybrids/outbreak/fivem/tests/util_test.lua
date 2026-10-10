-- shared/util.lua (msgpack_safe, parsing) and shared/json.lua (encoder + decoder) on this runtime.
local T, H = ...
local U = require("shared.util")
local json = require("shared.json")

T.group("util+json")

T.test("clamp / round / r1 / r2 / num / finite", function()
	T.eq(U.clamp(5, 0, 3), 3); T.eq(U.clamp(-1, 0, 3), 0); T.eq(U.clamp(2, 0, 3), 2)
	T.eq(U.round(7.4, 5), 5); T.eq(U.round(7.6, 5), 10)
	T.eq(U.r1(1.26), 1.3); T.eq(U.r2(1.264), 1.26)
	T.eq(U.num("12.5"), 12.5); T.eq(U.num("x", 9), 9); T.eq(U.num(0 / 0, 4), 4); T.eq(U.num(math.huge, 4), 4); T.eq(U.num(nil), nil)
	T.truthy(U.finite(1)); T.falsy(U.finite(0 / 0)); T.falsy(U.finite("1"))
end)

T.test("keys sorts mixed key types deterministically", function()
	local k = U.keys({ b = 1, a = 2, [3] = 3, [1] = 4 })
	T.eq(#k, 4); T.eq(k[1], 1); T.eq(k[2], 3); T.eq(k[3], "a"); T.eq(k[4], "b")
end)

T.test("parse_vec3 and split", function()
	local p = U.parse_vec3("1850.5, 3700, 34")
	T.near(p.x, 1850.5, 1e-9); T.near(p.z, 34, 1e-9)
	T.eq(U.parse_vec3("1,2"), nil); T.eq(U.parse_vec3("a,b,c"), nil); T.eq(U.parse_vec3("1,2,nan"), nil); T.eq(U.parse_vec3(nil), nil)
	T.eq(#U.split("a,b,,c", ","), 4)
end)

T.test("msgpack_safe accepts plain data", function()
	T.truthy(U.msgpack_safe({ a = 1, b = { 1, 2, 3 }, c = "x", d = true, e = { f = {} } }))
	T.truthy(U.msgpack_safe({}))
	T.truthy(U.msgpack_safe(nil)); T.truthy(U.msgpack_safe("s")); T.truthy(U.msgpack_safe(4.5))
end)

T.test("msgpack_safe rejects every unsafe shape", function()
	local function bad(v, why) local ok, w = U.msgpack_safe(v); T.falsy(ok, "should reject " .. why); T.truthy(w and #w > 0, "reports a path for " .. why) end
	bad({ a = 0 / 0 }, "nan"); bad({ a = math.huge }, "inf")
	bad({ 1, 2, a = 3 }, "mixed table"); bad({ [1] = 1, [3] = 3 }, "sparse array"); bad({ [2] = 1 }, "array not starting at 1")
	bad({ [1.5] = 1 }, "float key"); bad({ [true] = 1 }, "boolean key")
	bad({ f = function() end }, "function"); bad({ co = coroutine.create(function() end) }, "thread")
	bad(setmetatable({}, { __index = {} }), "metatable")
	local cyc = {}; cyc.me = cyc; bad(cyc, "cycle")
	local shared = { k = 1 }; T.truthy(U.msgpack_safe({ a = shared, b = shared }), "shared (non-cyclic) references are fine: msgpack copies them")
	local deep = {}; local cur = deep; for _ = 1, 20 do cur.n = {}; cur = cur.n end; bad(deep, "too deep")
end)

T.test("json encode: sorted keys, integers without decimals, escapes, non-finite -> null", function()
	T.eq(json.encode({ b = 1, a = 2 }), '{"a":2,"b":1}')
	T.eq(json.encode({ 1, 2, 3 }), "[1,2,3]")
	T.eq(json.encode({}), "[]")
	T.eq(json.encode(3), "3"); T.eq(json.encode(3.5), "3.5"); T.eq(json.encode(0 / 0), "null"); T.eq(json.encode(math.huge), "null")
	T.eq(json.encode('a"b\\c\n\t'), '"a\\"b\\\\c\\n\\t"')
	T.eq(json.encode("\1"), '"\\u0001"')
	T.eq(json.encode({ x = true, y = false }), '{"x":true,"y":false}')
end)

T.test("json decode: round trip, unicode escapes, nesting, errors", function()
	local v = json.decode('{"a":[1,2.5,"x\\u00e9\\n"],"b":{"c":null,"d":true},"e":-3e2}')
	T.eq(v.a[1], 1); T.eq(v.a[2], 2.5); T.eq(v.a[3], "x\195\169\n"); T.eq(v.b.d, true); T.eq(v.e, -300)
	local src = { n = 1, list = { 1, 2, { z = "q" } }, s = "hello \"world\"", f = 0.25 }
	local back = json.decode(json.encode(src))
	T.eq(back.n, 1); T.eq(back.list[3].z, "q"); T.eq(back.s, src.s); T.eq(back.f, 0.25)
	for _, junk in ipairs({ '{"a":', "[1,2,", "nope", '"abc', '{"a" 1}', "[1 2]", '"\\x"' }) do
		local r, err = json.decode(junk)
		T.eq(r, nil, junk); T.truthy(err and #err > 0, "error text for " .. junk)
	end
end)

T.test("json decodes a real UI payload (state view of a fresh world)", function()
	local m = H.boot({ warm_ms = 500 })
	local V = require("shared.view")
	local w = m:host().world
	local st = V.state(w, { speed = 1 })
	local s = json.encode(st)
	T.gt(#s, 1000)
	local back = json.decode(s)
	T.eq(#back.colonists, #st.colonists)
end)
