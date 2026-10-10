-- rng: determinism, exactness, distribution, serializable state, forks.
local T = ...
package.path = T.root .. "/?.lua;" .. package.path
local R = require("sim.rng")
local U = require("sim.util")

T.group("rng")

T.test("same seed gives the same stream; different seeds differ", function()
	local a, b, c = R.new(123), R.new(123), R.new(124)
	local same, diff = true, 0
	for _ = 1, 500 do
		local x, y, z = a:raw(), b:raw(), c:raw()
		if x ~= y then same = false end
		if x ~= z then diff = diff + 1 end
	end
	T.truthy(same, "identical seeds must produce identical streams")
	T.gt(diff, 495, "adjacent seeds must not produce the same numbers")
end)

T.test("golden values (exact on every Lua runtime)", function()
	local r = R.new(42)
	local want = { 1427675414, 422193317, 73794877, 1624620941, 269621865 }
	for i = 1, #want do T.eq(r:raw(), want[i], "raw output " .. i) end
	local f = R.new(42):fork("loot")
	T.eq(f:raw(), 12643036)
	T.eq(f:raw(), 406635008)
	T.eq(R.new(7).seed, 243324940)
	T.eq(R.new("abc").seed, 623042735)
end)

T.test("outputs stay in range and are exact integers", function()
	local r = R.new(99)
	for _ = 1, 20000 do
		local x = r:raw()
		if x < 1 or x > 2147483646 or x ~= math.floor(x) then T.truthy(false, "raw out of range: " .. x) end
		local f = r:float()
		if f < 0 or f >= 1 then T.truthy(false, "float out of [0,1): " .. f) end
	end
	T.truthy(true)
end)

T.test("state can be saved and restored mid-stream", function()
	local r = R.new(5)
	for _ = 1, 37 do r:raw() end
	local snap = { seed = r.seed, s = r.s }
	local expect = {}
	for i = 1, 10 do expect[i] = r:int(1, 1000) end
	local r2 = R.attach(snap)
	for i = 1, 10 do T.eq(r2:int(1, 1000), expect[i], "restored stream diverged at " .. i) end
	local r3 = r2:copy()
	T.eq(r3:raw(), r2:copy():raw())
end)

T.test("uniform float: mean, variance and chi-square over 10 bins", function()
	local r = R.new(2024)
	local n, bins, sum, sum2 = 100000, {}, 0, 0
	for i = 1, 10 do bins[i] = 0 end
	for _ = 1, n do
		local x = r:float()
		sum = sum + x
		sum2 = sum2 + x * x
		local b = math.floor(x * 10) + 1
		bins[b] = bins[b] + 1
	end
	local mean = sum / n
	local var = sum2 / n - mean * mean
	T.near(mean, 0.5, 0.005, "mean")
	T.near(var, 1 / 12, 0.003, "variance")
	local chi = 0
	for i = 1, 10 do chi = chi + (bins[i] - n / 10) ^ 2 / (n / 10) end
	T.lt(chi, 27.9, "chi-square (9 dof, p=0.001 is 27.88)")
end)

T.test("int(lo,hi) is inclusive, covers the range, and is roughly uniform", function()
	local r = R.new(11)
	local seen, n = {}, 60000
	for _ = 1, n do
		local v = r:int(3, 8)
		seen[v] = (seen[v] or 0) + 1
	end
	for v = 3, 8 do
		T.truthy(seen[v], "value " .. v .. " never produced")
		T.near(seen[v] / n, 1 / 6, 0.01)
	end
	T.falsy(seen[2] or seen[9], "out-of-range value produced")
	T.eq(r:int(5, 5), 5)
	local swapped = r:int(9, 2)
	T.truthy(swapped >= 2 and swapped <= 9, "reversed bounds are normalised")
end)

T.test("chance(p) edge cases and rate", function()
	local r = R.new(3)
	T.falsy(r:chance(0))
	T.falsy(r:chance(-1))
	T.truthy(r:chance(1))
	T.truthy(r:chance(5))
	local hits = 0
	for _ = 1, 50000 do if r:chance(0.3) then hits = hits + 1 end end
	T.near(hits / 50000, 0.3, 0.01)
end)

T.test("weighted pick follows the weights, ignores zero weights", function()
	local r = R.new(8)
	local entries = { { id = "a", w = 1 }, { id = "b", w = 3 }, { id = "c", w = 0 }, { id = "d", w = 6 } }
	local cnt = { a = 0, b = 0, c = 0, d = 0 }
	for _ = 1, 50000 do
		local e = r:weighted(entries, "w")
		cnt[e.id] = cnt[e.id] + 1
	end
	T.eq(cnt.c, 0, "zero-weight entry must never be picked")
	T.near(cnt.a / 50000, 0.1, 0.012)
	T.near(cnt.b / 50000, 0.3, 0.012)
	T.near(cnt.d / 50000, 0.6, 0.012)
	T.eq(r:weighted({}, "w"), nil)
	T.eq(r:weighted({ { w = 0 } }, "w"), nil)
	local e, i = r:weighted(entries, function(en) return en.id == "d" and 1 or 0 end)
	T.eq(e.id, "d")
	T.eq(i, 4)
end)

T.test("shuffle is a permutation and unbiased in position 1", function()
	local r = R.new(77)
	local first = {}
	for _ = 1, 30000 do
		local list = { 1, 2, 3, 4, 5 }
		r:shuffle(list)
		local sum = 0
		for i = 1, 5 do sum = sum + list[i] end
		if sum ~= 15 then T.truthy(false, "shuffle lost or duplicated an element") end
		first[list[1]] = (first[list[1]] or 0) + 1
	end
	for v = 1, 5 do T.near((first[v] or 0) / 30000, 0.2, 0.012, "first-slot share of " .. v) end
end)

T.test("gauss has the requested mean and standard deviation", function()
	local r = R.new(404)
	local n, sum, sum2 = 40000, 0, 0
	for _ = 1, n do
		local g = r:gauss(10, 2)
		sum = sum + g
		sum2 = sum2 + g * g
	end
	local mean = sum / n
	T.near(mean, 10, 0.05)
	T.near(math.sqrt(sum2 / n - mean * mean), 2, 0.06)
end)

T.test("fork: stable, independent, and does not consume the parent", function()
	local parent = R.new(2025)
	local before = parent.s
	local a, b = parent:fork("loot"), parent:fork("loot")
	T.eq(parent.s, before, "fork must not advance the parent")
	T.eq(a:raw(), b:raw(), "same label -> same child stream")
	local c = parent:fork("combat")
	local d = parent:fork("loot")
	local same = 0
	for _ = 1, 200 do if c:raw() == d:raw() then same = same + 1 end end
	T.lt(same, 3, "different labels must give different streams")
	-- correlation between two forks is near zero
	local x, y = parent:fork("x"), parent:fork("y")
	local n, sxy, sx, sy, sxx, syy = 20000, 0, 0, 0, 0, 0
	for _ = 1, n do
		local u, v = x:float(), y:float()
		sx, sy, sxy, sxx, syy = sx + u, sy + v, sxy + u * v, sxx + u * u, syy + v * v
	end
	local cov = sxy / n - (sx / n) * (sy / n)
	local corr = cov / math.sqrt((sxx / n - (sx / n) ^ 2) * (syy / n - (sy / n) ^ 2))
	T.lt(math.abs(corr), 0.03, "forks should be uncorrelated")
	-- numeric labels work and are stable
	T.eq(parent:fork(7):raw(), parent:fork(7):raw())
end)

T.test("consecutive seeds do not give correlated first outputs", function()
	local bins = {}
	for i = 1, 10 do bins[i] = 0 end
	for seed = 1, 1000 do
		local x = R.new(seed):float()
		local b = math.floor(x * 10) + 1
		bins[b] = bins[b] + 1
	end
	local chi = 0
	for i = 1, 10 do chi = chi + (bins[i] - 100) ^ 2 / 100 end
	T.lt(chi, 27.9, "first outputs of seeds 1..1000 should look uniform")
end)

T.test("no short cycle within 200k draws", function()
	local r = R.new(9)
	local first = r:raw()
	local back = false
	for _ = 1, 200000 do if r:raw() == first then back = true; break end end
	T.falsy(back, "stream repeated its first value too early")
end)
