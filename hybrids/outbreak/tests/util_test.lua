-- util + clock + a portability lint over every sim/ and data/ source file.
local T = ...
package.path = T.root .. "/?.lua;" .. package.path
local U = require("sim.util")
local clock = require("sim.clock")
local TUNING = require("data.tuning")

T.group("util+clock")

T.test("U.sort is a stable total-order sort for every size", function()
	local r = require("sim.rng").new(5)
	for n = 0, 70 do
		local list = {}
		for i = 1, n do list[i] = { k = r:int(1, 6), i = i } end
		U.sort(list, function(a, b) return a.k < b.k end)
		for i = 2, n do
			local a, b = list[i - 1], list[i]
			if a.k > b.k or (a.k == b.k and a.i > b.i) then T.truthy(false, "unstable or unsorted at n=" .. n) end
		end
	end
	local big = {}
	for i = 1, 2000 do big[i] = { k = r:int(1, 50), i = i } end
	U.sort(big, function(a, b) return a.k < b.k end)
	local digest = 0
	for i = 1, 2000 do digest = (digest * 31 + big[i].i) % 1000003 end
	T.truthy(digest > 0)
	T.eq(#big, 2000)
	local strs = { "pear", "apple", "fig", "apple", "kiwi" }
	U.sort(strs)
	T.eq(table.concat(strs, ","), "apple,apple,fig,kiwi,pear")
	T.eq(#U.sort({}), 0)
end)

T.test("U.sort matches a reference stable sort (table.sort with an index tie-break)", function()
	local r = require("sim.rng").new(31337)
	local a, b = {}, {}
	for i = 1, 3000 do
		local k = r:int(1, 40)
		a[i] = { k = k, i = i }
		b[i] = { k = k, i = i }
	end
	U.sort(a, function(x, y) return x.k < y.k end)
	table.sort(b, function(x, y) if x.k ~= y.k then return x.k < y.k end return x.i < y.i end)
	local same = true
	for i = 1, 3000 do if a[i].i ~= b[i].i then same = false; break end end
	T.truthy(same, "stable merge sort must equal the tie-broken reference order")
	T.eq(U.hash(table.concat((function() local t = {} for i = 1, 100 do t[i] = string.format("%d", a[i].i) end return t end)(), ",")), U.hash(table.concat((function() local t = {} for i = 1, 100 do t[i] = string.format("%d", b[i].i) end return t end)(), ",")))
end)

T.test("U.fmt_num is canonical", function()
	T.eq(U.fmt_num(3), "3")
	T.eq(U.fmt_num(3.0), "3")
	T.eq(U.fmt_num(-12), "-12")
	T.eq(U.fmt_num(0), "0")
	T.eq(U.fmt_num(-0.0), "0")
	T.eq(U.fmt_num(0.1), "0.10000000000000001")
	T.eq(tonumber(U.fmt_num(0.1)), 0.1)
	T.eq(tonumber(U.fmt_num(1 / 3)), 1 / 3, "17 digits round-trip a double exactly")
	T.throws(function() U.fmt_num(0 / 0) end, "NaN must not serialize")
	T.throws(function() U.fmt_num(math.huge) end, "inf must not serialize")
end)

T.test("U.hash: golden values, stability and sensitivity", function()
	T.eq(U.hash("outbreak"), "6b28beb152299775")
	T.eq(U.hash(""), "0000bc8f00076fb3")
	T.eq(#U.hash("anything"), 16)
	T.ne(U.hash("abc"), U.hash("abd"))
	T.ne(U.hash("abc"), U.hash("abcc"))
	T.eq(U.hash_num("x"), 1987623)
	local long = string.rep("0123456789", 500)
	T.eq(U.hash(long), U.hash(long))
	T.ne(U.hash(long), U.hash(long .. "!"))
end)

T.test("keys / spairs iterate in sorted order; copies are independent", function()
	local t = { zeta = 1, alpha = 2, mid = 3, beta = 4 }
	T.eq(table.concat(U.keys(t), ","), "alpha,beta,mid,zeta")
	local out = {}
	for k, v in U.spairs(t) do out[#out + 1] = k .. "=" .. string.format("%d", v) end
	T.eq(table.concat(out, ","), "alpha=2,beta=4,mid=3,zeta=1")
	local nested = { a = { b = { 1, 2, 3 } } }
	local d = U.deepcopy(nested)
	d.a.b[1] = 99
	T.eq(nested.a.b[1], 1)
	local c = U.copy(t)
	c.zeta = 5
	T.eq(t.zeta, 1)
	T.eq(U.count(t), 4)
	T.truthy(U.is_empty({}))
	T.falsy(U.is_empty(t))
end)

T.test("clamp, round, ids and misc helpers", function()
	T.eq(U.clamp(5, 0, 3), 3)
	T.eq(U.clamp(-1, 0, 3), 0)
	T.eq(U.clamp(0 / 0, 2, 3), 2, "NaN clamps to the low bound instead of leaking")
	T.eq(U.round(2.5), 3)
	T.eq(U.round(-0.4), 0)
	local ids = {}
	T.eq(U.next_id(ids, "c"), "c1")
	T.eq(U.next_id(ids, "c"), "c2")
	T.eq(U.next_id(ids, "b"), "b1")
	T.near(U.dist({ x = 0, y = 0 }, { x = 3, y = 4 }), 5, 1e-12)
	T.truthy(U.finite(1.5))
	T.falsy(U.finite(math.huge))
	T.falsy(U.finite(0 / 0))
	T.eq(U.index_of({ "a", "b" }, "b"), 2)
	local l = { 1, 2, 3 }
	T.truthy(U.remove_value(l, 2))
	T.falsy(U.remove_value(l, 9))
	T.eq(#l, 2)
end)

T.test("clock: day/hour/minute arithmetic", function()
	T.eq(clock.day(0), 1)
	T.eq(clock.day(1439), 1)
	T.eq(clock.day(1440), 2)
	T.eq(clock.hour(8 * 60 + 5), 8)
	T.eq(clock.minute(8 * 60 + 5), 5)
	T.eq(clock.at(3, 14, 30), 2 * 1440 + 14 * 60 + 30)
	T.eq(clock.fmt(clock.at(12, 7, 9)), "D12 07:09")
	T.eq(clock.with_time_of_day(clock.at(4, 20, 0), 6, 15), clock.at(4, 6, 15))
	T.eq(clock.MIN_PER_DAY, 1440)
end)

T.test("clock: night boundaries, daylight ramps, seasons", function()
	T.falsy(clock.is_night(clock.at(1, 20, 59)))
	T.truthy(clock.is_night(clock.at(1, 21, 0)))
	T.truthy(clock.is_night(clock.at(1, 4, 59)))
	T.falsy(clock.is_night(clock.at(1, 5, 0)))
	T.eq(clock.daylight(clock.at(1, 12, 0)), 1)
	T.eq(clock.daylight(clock.at(1, 2, 0)), 0)
	T.near(clock.daylight(clock.at(1, 6, 0)), 0.5, 1e-9)
	T.near(clock.daylight(clock.at(1, 20, 0)), 0.5, 1e-9)
	local prev = -1
	for m = 0, 120, 5 do
		local d = clock.daylight(clock.at(1, 5, 0) + m)
		T.truthy(d >= prev - 1e-12, "dawn must be monotonic")
		prev = d
	end
	local len = TUNING.clock.season_len_days
	T.eq(clock.season(clock.at(1, 0, 0)), "spring")
	T.eq(clock.season(clock.at(len + 1, 0, 0)), "summer")
	T.eq(clock.season(clock.at(2 * len + 1, 0, 0)), "autumn")
	T.eq(clock.season(clock.at(3 * len + 1, 0, 0)), "winter")
	T.eq(clock.season(clock.at(4 * len + 1, 0, 0)), "spring")
end)

-- ---------------------------------------------------------------------------------------------
-- portability lint
-- ---------------------------------------------------------------------------------------------
local SIM = { "util", "rng", "clock", "items", "loot", "needs", "mood", "skills", "traits", "colonist", "stockpile", "blueprints",
	"jobs", "grid", "expedition", "horde", "factions", "director", "combat_abstract", "siege", "world", "handlers", "save", "ai_policy", "runner", "bootstrap" }
local DATA = { "tuning", "items", "blueprints", "loot", "traits", "thoughts", "events", "factions", "districts", "recipes", "names" }

local function read(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- split a source file into per-line { code = (strings blanked, comments removed), comment = text }
local function scan(src)
	local lines = {}
	local n = 0
	for raw in (src .. "\n"):gmatch("(.-)\n") do
		n = n + 1
		local code, comment = {}, nil
		local i, len = 1, #raw
		while i <= len do
			local c = raw:sub(i, i)
			if c == "-" and raw:sub(i + 1, i + 1) == "-" then
				comment = raw:sub(i + 2)
				break
			elseif c == '"' or c == "'" then
				local q = c
				i = i + 1
				while i <= len do
					local d = raw:sub(i, i)
					if d == "\\" then i = i + 1
					elseif d == q then break end
					i = i + 1
				end
				code[#code + 1] = '""'
			else
				code[#code + 1] = c
			end
			i = i + 1
		end
		lines[n] = { code = table.concat(code), comment = comment or "" }
	end
	return lines
end

local BANNED = {
	{ "goto", "%f[%w_]goto%f[^%w_]" },
	{ "integer division //", "//" },
	{ "bit shift", "<<" }, { "bit shift", ">>" },
	{ "bitwise and", "[^&]&[^&]" }, { "bitwise or", "|" }, { "bitwise xor", "[^~=<>]~[^=]" },
	{ "exponent operator ^", "%^" },
	{ "math.pow", "math%.pow" }, { "math.exp", "math%.exp" }, { "math.log", "math%.log" }, { "math.sin", "math%.sin" },
	{ "math.cos", "math%.cos" }, { "math.tan", "math%.tan" }, { "math.atan", "math%.atan" }, { "math.fmod", "math%.fmod" },
	{ "math.random", "math%.random" }, { "math.ldexp/frexp", "math%.[lf][dr]exp" },
	{ "setfenv/getfenv", "[sg]etfenv" }, { "utf8", "utf8" }, { "string.pack", "string%.pack" }, { "string.unpack", "string%.unpack" },
	{ "loadstring", "loadstring" }, { "os.time", "os%.time" }, { "os.clock", "os%.clock" }, { "os.date", "os%.date" },
	{ "os.getenv", "os%.getenv" }, { "io library", "%f[%w_]io%." }, { "collectgarbage", "collectgarbage" },
}

T.test("every module file exists (and nothing unlisted lives in sim/ or data/)", function()
	for _, m in ipairs(SIM) do T.truthy(read(T.root .. "/sim/" .. m .. ".lua"), "missing sim/" .. m .. ".lua") end
	for _, m in ipairs(DATA) do T.truthy(read(T.root .. "/data/" .. m .. ".lua"), "missing data/" .. m .. ".lua") end
	local ok, p = pcall(io.popen, "ls '" .. T.root .. "/sim' '" .. T.root .. "/data' 2>/dev/null")
	if ok and p then
		local listing = p:read("*a")
		p:close()
		local known = {}
		for _, m in ipairs(SIM) do known[m .. ".lua"] = true end
		for _, m in ipairs(DATA) do known[m .. ".lua"] = true end
		for f in listing:gmatch("[%w_]+%.lua") do T.truthy(known[f], "unlisted source file " .. f .. " (add it to the lint list)") end
	end
end)

T.test("portability lint: no goto, bit ops, //, ^, libm trig/exp/log, os.time/clock, math.random, pack/unpack, setfenv, utf8", function()
	for _, dir_mods in ipairs({ { "sim", SIM }, { "data", DATA } }) do
		for _, m in ipairs(dir_mods[2]) do
			local path = dir_mods[1] .. "/" .. m .. ".lua"
			local lines = scan(read(T.root .. "/" .. path))
			local bad = {}
			for ln, l in ipairs(lines) do
				for _, b in ipairs(BANNED) do
					-- sim/bootstrap.lua is the one place that must compile source text (loadstring or load) for hosts without package.path
					local allowed = (m == "bootstrap" and b[1] == "loadstring")
					if l.code:find(b[2]) and not allowed then bad[#bad + 1] = string.format("%s:%d uses %s: %s", path, ln, b[1], l.code) end
				end
			end
			T.eq(#bad, 0, table.concat(bad, "\n"))
		end
	end
end)

T.test("portability lint: pairs() only where order cannot matter (line carries an 'order-free' note)", function()
	for _, m in ipairs(SIM) do
		local path = "sim/" .. m .. ".lua"
		local lines = scan(read(T.root .. "/" .. path))
		local bad = {}
		for ln, l in ipairs(lines) do
			if l.code:find("[^i%w_]pairs%(") and not l.comment:find("order%-free") then
				bad[#bad + 1] = string.format("%s:%d unannotated pairs(): %s", path, ln, l.code)
			end
		end
		T.eq(#bad, 0, table.concat(bad, "\n"))
	end
end)

T.test("portability lint: table.sort / unpack only in the reviewed helper modules", function()
	for _, m in ipairs(SIM) do
		local path = "sim/" .. m .. ".lua"
		local lines = scan(read(T.root .. "/" .. path))
		local bad = {}
		for ln, l in ipairs(lines) do
			if l.code:find("table%.sort%(") and m ~= "util" and m ~= "save" then bad[#bad + 1] = string.format("%s:%d table.sort outside util/save (use U.sort)", path, ln) end
			if l.code:find("table%.unpack") and m ~= "util" then bad[#bad + 1] = string.format("%s:%d table.unpack (use U.unpack)", path, ln) end
			if l.code:find("[^%.%w_]unpack%(") and m ~= "util" then bad[#bad + 1] = string.format("%s:%d bare unpack (use U.unpack)", path, ln) end
		end
		T.eq(#bad, 0, table.concat(bad, "\n"))
	end
end)

T.test("tuning table: every number is finite and the documented sections exist", function()
	local sections = { "sim", "clock", "map", "base", "player", "colonist", "needs", "mood", "skills", "combat", "grid", "jobs",
		"expedition", "horde", "factions", "director", "world" }
	for _, s in ipairs(sections) do T.eq(type(TUNING[s]), "table", "TUNING." .. s) end
	local function walk(t, path)
		for _, k in ipairs(U.keys(t)) do
			local v = t[k]
			local p = path .. "." .. k
			if type(v) == "number" then
				if not U.finite(v) then T.truthy(false, p .. " is not finite") end
			elseif type(v) == "table" then
				walk(v, p)
			end
		end
	end
	walk(TUNING, "TUNING")
	T.truthy(TUNING.horde.R_dematerialize > TUNING.horde.R_materialize, "hysteresis margin must be positive")
	T.truthy(TUNING.horde.max_materialized > 0)
end)
