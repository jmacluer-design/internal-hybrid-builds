-- shared/protocol.lua: the validators the server runs on everything the (untrusted) client sends.
local T, H = ...
local P = require("shared.protocol")
local U = require("shared.util")

T.group("protocol")

T.test("event names are unique and namespaced", function()
	local seen = {}
	for k, v in pairs(P.NET) do
		T.truthy(v:match("^outbreak:"), k)
		T.falsy(seen[v], "duplicate " .. v)
		seen[v] = true
	end
end)

T.test("sanitize_in: valid events pass and are copies", function()
	local raw = { type = "noise", pos = { x = 1, y = 2, z = 3 }, loudness = 80, kind = "gunshot", extra = "dropped" }
	local ev = P.sanitize_in(raw)
	T.eq(ev.type, "noise"); T.eq(ev.loudness, 80); T.eq(ev.kind, "gunshot"); T.eq(ev.extra, nil); T.ne(ev.pos, raw.pos)
	local d = P.sanitize_in({ type = "ped_damage", id = "c12", amount = 18.5, kind = "bite", part = "arm" })
	T.eq(d.id, "c12"); T.eq(d.kind, "bite"); T.eq(d.part, "arm")
	T.eq(P.sanitize_in({ type = "ped_died", id = "player", cause = "bullet" }).id, "player")
	T.eq(P.sanitize_in({ type = "ped_died", id = "h4", zkind = "runner" }).zkind, "runner")
	T.eq(P.sanitize_in({ type = "horde_report", id = "h9", pos = { x = 5, y = 6 } }).id, "h9")
	T.eq(P.sanitize_in({ type = "raid_report", id = "r2", pos = { x = 5, y = 6 } }).id, "r2")
	T.eq(P.sanitize_in({ type = "container_opened", container = "pile:p3", ctype = "pile", pos = { x = 1, y = 1 }, danger = 9 }).danger, 5)
	T.eq(P.sanitize_in({ type = "colonist_ref", id = "c1", ref = 1234 }).ref, 1234)
	T.eq(P.sanitize_in({ type = "player_state", pos = { x = 1, y = 1 }, needs = { hunger = 5, bogus = 1, infection = "none" } }).needs.hunger, 5)
end)

T.test("sanitize_in: clamps and rejects hostile input", function()
	T.eq(P.sanitize_in({ type = "noise", pos = { x = 1, y = 1 }, loudness = 1e9 }).loudness, 400)
	T.eq(P.sanitize_in({ type = "noise", pos = { x = 1e9, y = -1e9 }, loudness = 5 }).pos.x, 6000)
	local bad = {
		{ type = "noise", pos = { x = 1, y = 1 }, loudness = -5 }, { type = "noise", pos = { x = 1, y = 1 }, loudness = 0 / 0 }, { type = "noise", loudness = 5 },
		{ type = "noise", pos = { x = "a", y = 1 }, loudness = 5 },
		{ type = "ped_damage", id = "c1", amount = 0 }, { type = "ped_damage", id = "x1", amount = 5 }, { type = "ped_damage", id = "c1" .. string.rep("9", 20), amount = 5 },
		{ type = "ped_died" }, { type = "ped_died", id = "zzz" },
		{ type = "time_set", hour = 3 }, { type = "order", id = "c1" }, { type = "item_moved" }, { type = "debug_horde" },
		{ type = "colonist_ref", id = "c1", ref = {} }, { type = "colonist_ref", id = "c1", ref = 0 / 0 },
		{ type = "container_opened", container = "", ctype = "x", pos = { x = 1, y = 1 } },
		"string", 5, nil, { type = 5 }, {},
	}
	for i = 1, 25 do
		local v = bad[i]
		local ev = P.sanitize_in(v)
		T.eq(ev, nil, "bad input #" .. i .. " must be rejected")
	end
	local ev = P.sanitize_in({ type = "ped_damage", id = "c1", amount = 1e12, kind = "<script>" })
	T.eq(ev.amount, 500); T.eq(ev.kind, "blunt")
end)

T.test("only the documented IN types are accepted from clients", function()
	T.eq(table.concat(P.CLIENT_IN_TYPES, ","), "colonist_ref,container_opened,horde_report,noise,ped_damage,ped_died,player_state,raid_report")
end)

T.test("sanitize_order: whitelist, ids, positions, deep clean", function()
	local o = P.sanitize_order({ id = "c3", kind = "priority", target = { work = "cook", level = 2 } })
	T.eq(o.kind, "priority"); T.eq(o.target.work, "cook"); T.eq(o.target.level, 2)
	local g = P.sanitize_order({ id = "c3", kind = "goto", target = { x = 5, y = 6, z = 1 } })
	T.eq(g.target.x, 5)
	T.eq(P.sanitize_order({ id = "colony", kind = "place_blueprint", target = { bp = "wall", pos = { x = 1, y = 2 } } }).target.bp, "wall")
	T.eq(P.sanitize_order({ id = "all", kind = "draft", target = true }).id, "all")
	T.eq(P.sanitize_order({ id = "c3", kind = "goto", target = { x = 1e9, y = 0 } }).target.x, 6000)
	T.eq(P.sanitize_order({ id = "c3", kind = "goto" }), nil, "goto without position")
	T.eq(P.sanitize_order({ id = "colony", kind = "place_blueprint", target = { pos = { x = 1, y = 2 } } }), nil, "no blueprint id")
	T.eq(P.sanitize_order({ id = "c3", kind = "rm_rf" }), nil)
	T.eq(P.sanitize_order({ id = "q1", kind = "priority" }), nil)
	T.eq(P.sanitize_order({ id = string.rep("c", 50), kind = "priority" }), nil)
	T.eq(P.sanitize_order("x"), nil); T.eq(P.sanitize_order(nil), nil)
	-- a deeply nested / huge target is cut down, not forwarded
	local deep = { a = { b = { c = { d = { e = { f = 1 } } } } } }
	local ok = P.sanitize_order({ id = "c1", kind = "schedule", target = deep })
	T.truthy(ok)
	T.eq(ok.target.a.b.c.d, nil, "depth capped")
	local big = {}
	for i = 1, 500 do big[i] = i end
	local o2 = P.sanitize_order({ id = "c1", kind = "schedule", target = big })
	T.le(#o2.target, 40)
	T.truthy(U.msgpack_safe(o2))
end)

T.test("every order kind the UI sends is on the whitelist", function()
	local f = assert(io.open(H.res .. "/ui/js/priorities.js", "rb")):read("*a")
	T.truthy(f:find("priority", 1, true))
	for _, k in ipairs({ "priority", "draft", "goto", "place_blueprint", "cancel_blueprint", "expedition", "schedule", "zone_create", "zone_set", "trade", "set_profile" }) do
		T.truthy(P.ORDER_KINDS[k], k)
	end
end)
