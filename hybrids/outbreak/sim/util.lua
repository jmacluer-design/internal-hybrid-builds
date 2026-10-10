-- util.lua : portable helpers shared by every sim module.
--
-- Portability contract (LuaJIT 2.1 / Lua 5.1 semantics AND Lua 5.4):
--   * never iterate with pairs() where order matters (use U.keys / U.spairs),
--   * never sort with a non-total comparator (use U.sort, which is stable),
--   * never put numbers into strings with `..` or %s (5.4 prints 3.0, LuaJIT prints 3),
--     use U.fmt_id / string.format("%d") / "%.1f",
--   * no ^, math.pow, math.exp/log/sin/cos (not guaranteed bit-identical across libm/JIT),
--   * no bitwise operators, no //, no goto, no integer/float subtype reliance.
local U = {}

U.unpack = table.unpack or unpack

local floor, sqrt, abs = math.floor, math.sqrt, math.abs

function U.clamp(x, lo, hi)
	if x ~= x then return lo end -- NaN guard: never let NaN leak through a clamp
	if x < lo then return lo end
	if x > hi then return hi end
	return x
end

function U.round(x) return floor(x + 0.5) end

function U.finite(x) return x == x and x ~= math.huge and x ~= -math.huge end

function U.sign(x) if x > 0 then return 1 elseif x < 0 then return -1 end return 0 end

function U.min(a, b) if a < b then return a end return b end
function U.max(a, b) if a > b then return a end return b end

-- number -> canonical string (identical on every runtime). Integers print without a
-- decimal point, everything else round-trips exactly with 17 significant digits.
function U.fmt_num(n)
	if n == 0 then return "0" end -- also folds -0
	if n ~= n or n == math.huge or n == -math.huge then error("non-finite number in canonical output") end
	if n == floor(n) and n > -1e15 and n < 1e15 then return string.format("%d", n) end
	return string.format("%.17g", n)
end

-- id counters live in plain state: counters = { c = 3, b = 7 }
function U.next_id(counters, prefix)
	local n = (counters[prefix] or 0) + 1
	counters[prefix] = n
	return prefix .. string.format("%d", n)
end

-- sorted array of a table's keys (all keys must be of one comparable type)
function U.keys(t)
	local ks, n = {}, 0
	for k in pairs(t) do n = n + 1; ks[n] = k end -- order-free: sorted below
	table.sort(ks)
	return ks
end

-- iterate a map in sorted-key order:  for k, v in U.spairs(t) do ... end
function U.spairs(t)
	local ks = U.keys(t)
	local i = 0
	return function()
		i = i + 1
		local k = ks[i]
		if k ~= nil then return k, t[k] end
	end
end

function U.count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end -- order-free
	return n
end

function U.is_empty(t) return next(t) == nil end

function U.copy(t)
	local r = {}
	for k, v in pairs(t) do r[k] = v end -- order-free
	return r
end

function U.deepcopy(t)
	if type(t) ~= "table" then return t end
	local r = {}
	for k, v in pairs(t) do r[k] = U.deepcopy(v) end -- order-free
	return r
end

-- stable merge sort (total order => identical result on every runtime, unlike table.sort
-- whose algorithm differs between LuaJIT and PUC Lua when the comparator has ties).
-- lt(a, b) must be a strict weak ordering. Sorts in place and returns the list.
function U.sort(list, lt)
	local n = #list
	if n < 2 then return list end
	lt = lt or function(a, b) return a < b end
	if n <= 12 then -- insertion sort: stable
		for i = 2, n do
			local v = list[i]
			local j = i - 1
			while j >= 1 and lt(v, list[j]) do list[j + 1] = list[j]; j = j - 1 end
			list[j + 1] = v
		end
		return list
	end
	local src, dst = list, {}
	local width = 1
	while width < n do
		local i = 1
		while i <= n do
			local mid = i + width
			local hi = i + 2 * width
			if mid > n + 1 then mid = n + 1 end
			if hi > n + 1 then hi = n + 1 end
			local a, b, k = i, mid, i
			while a < mid and b < hi do
				if lt(src[b], src[a]) then dst[k] = src[b]; b = b + 1 else dst[k] = src[a]; a = a + 1 end
				k = k + 1
			end
			while a < mid do dst[k] = src[a]; a = a + 1; k = k + 1 end
			while b < hi do dst[k] = src[b]; b = b + 1; k = k + 1 end
			i = i + 2 * width
		end
		src, dst = dst, src
		width = width * 2
	end
	if src ~= list then for i = 1, n do list[i] = src[i] end end
	return list
end

-- remove the first element equal to v; returns true when something was removed
function U.remove_value(list, v)
	for i = 1, #list do
		if list[i] == v then table.remove(list, i); return true end
	end
	return false
end

function U.index_of(list, v)
	for i = 1, #list do if list[i] == v then return i end end
	return nil
end

-- array of ids -> set
function U.set(list)
	local s = {}
	for i = 1, #list do s[list[i]] = true end
	return s
end

function U.dist(a, b) -- 2D ground distance
	local dx, dy = a.x - b.x, a.y - b.y
	return sqrt(dx * dx + dy * dy)
end

function U.dist2(ax, ay, bx, by)
	local dx, dy = ax - bx, ay - by
	return sqrt(dx * dx + dy * dy)
end

function U.pos(x, y, z) return { x = x, y = y, z = z or 0 } end
function U.pos_copy(p) return { x = p.x, y = p.y, z = p.z or 0 } end

-- Two-lane arithmetic string hash. Not cryptographic; exact in doubles (all products < 2^47)
-- so it is identical on every runtime. Returns 16 hex chars.
local MOD1, MOD2 = 2147483647, 2147483629
function U.hash(str)
	local h1, h2 = 1, 7
	local n = #str
	local i = 1
	local byte = string.byte
	while i + 7 <= n do
		local b1, b2, b3, b4, b5, b6, b7, b8 = byte(str, i, i + 7)
		h1 = (h1 * 48271 + b1 + 1) % MOD1
		h2 = (h2 * 69621 + b1 + 3) % MOD2
		h1 = (h1 * 48271 + b2 + 1) % MOD1
		h2 = (h2 * 69621 + b2 + 3) % MOD2
		h1 = (h1 * 48271 + b3 + 1) % MOD1
		h2 = (h2 * 69621 + b3 + 3) % MOD2
		h1 = (h1 * 48271 + b4 + 1) % MOD1
		h2 = (h2 * 69621 + b4 + 3) % MOD2
		h1 = (h1 * 48271 + b5 + 1) % MOD1
		h2 = (h2 * 69621 + b5 + 3) % MOD2
		h1 = (h1 * 48271 + b6 + 1) % MOD1
		h2 = (h2 * 69621 + b6 + 3) % MOD2
		h1 = (h1 * 48271 + b7 + 1) % MOD1
		h2 = (h2 * 69621 + b7 + 3) % MOD2
		h1 = (h1 * 48271 + b8 + 1) % MOD1
		h2 = (h2 * 69621 + b8 + 3) % MOD2
		i = i + 8
	end
	while i <= n do
		local b = byte(str, i)
		h1 = (h1 * 48271 + b + 1) % MOD1
		h2 = (h2 * 69621 + b + 3) % MOD2
		i = i + 1
	end
	h1 = (h1 * 48271 + n) % MOD1
	h2 = (h2 * 69621 + n) % MOD2
	return string.format("%08x%08x", h1, h2)
end

-- numeric hash of a string for seeding streams (two lanes folded to one < 2^31-1)
function U.hash_num(str)
	local h1, h2 = 1, 7
	for i = 1, #str do
		local b = string.byte(str, i)
		h1 = (h1 * 48271 + b + 1) % MOD1
		h2 = (h2 * 69621 + b + 3) % MOD2
	end
	return (h1 * 31 + h2) % 2147483646 + 1
end

-- tiny printf that never errors on odd args (used for notify texts)
function U.fmt(f, ...)
	local ok, s = pcall(string.format, f, ...)
	if ok then return s end
	return f
end

-- weighted average-free helpers
function U.sum_map(m)
	local n = 0
	for _, v in U.spairs(m) do n = n + v end
	return n
end

-- merge map b into a (adding numbers)
function U.add_map(a, b)
	for k, v in U.spairs(b) do a[k] = (a[k] or 0) + v end
	return a
end

-- linear interpolation
function U.lerp(a, b, t) return a + (b - a) * t end

return U
