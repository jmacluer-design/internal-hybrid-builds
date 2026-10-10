-- A tiny test harness (no dependencies), modelled on gmod-webswing/tests/tinytest.lua but it also
-- counts ASSERTIONS (every T.eq / T.truthy / ... call) and groups tests under T.group(name).
local T = { passed = 0, failed = 0, asserts = 0, failures = {}, current = nil, root = ".", groups = {}, group_name = "-" }

local function fmt(...)
	local n = select("#", ...)
	if n == 0 then return "" end
	local ok, s = pcall(string.format, ...)
	return ok and s or tostring((...))
end

function T.note(...) print("      " .. fmt(...)) end

function T.group(name)
	T.group_name = name
	if not T.groups[name] then T.groups[name] = { asserts = 0, tests = 0 } end
end

function T.test(name, fn)
	T.current = name
	local g = T.groups[T.group_name] or { asserts = 0, tests = 0 }
	T.groups[T.group_name] = g
	g.tests = g.tests + 1
	local before = T.asserts
	local ok, err = xpcall(fn, function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end)
	g.asserts = g.asserts + (T.asserts - before)
	if ok then
		T.passed = T.passed + 1
		print("  PASS  " .. name)
	else
		T.failed = T.failed + 1
		T.failures[#T.failures + 1] = name
		print("  FAIL  " .. name)
		print("        " .. (tostring(err):gsub("\n", "\n        ")))
	end
	T.current = nil
end

local function fail(msg, level) error(msg, (level or 1) + 2) end

local function count() T.asserts = T.asserts + 1 end

function T.truthy(v, ...) count(); if not v then fail("expected truthy: " .. fmt(...)) end end
function T.falsy(v, ...) count(); if v then fail("expected falsy: " .. fmt(...)) end end
function T.eq(a, b, ...) count(); if a ~= b then fail(string.format("expected %s == %s %s", tostring(a), tostring(b), fmt(...))) end end
function T.ne(a, b, ...) count(); if a == b then fail(string.format("expected %s ~= %s %s", tostring(a), tostring(b), fmt(...))) end end
function T.near(a, b, tol, ...)
	count()
	if a ~= a or b ~= b or math.abs(a - b) > tol then
		fail(string.format("expected %.9g ~= %.9g (tol %.3g) %s", a, b, tol, fmt(...)))
	end
end
function T.lt(a, b, ...) count(); if not (a < b) then fail(string.format("expected %.9g < %.9g %s", a, b, fmt(...))) end end
function T.le(a, b, ...) count(); if not (a <= b) then fail(string.format("expected %.9g <= %.9g %s", a, b, fmt(...))) end end
function T.gt(a, b, ...) count(); if not (a > b) then fail(string.format("expected %.9g > %.9g %s", a, b, fmt(...))) end end
function T.ge(a, b, ...) count(); if not (a >= b) then fail(string.format("expected %.9g >= %.9g %s", a, b, fmt(...))) end end
function T.finite(a, ...)
	count()
	if type(a) ~= "number" or a ~= a or a == math.huge or a == -math.huge then fail("expected a finite number " .. fmt(...)) end
end
function T.throws(fn, ...)
	count()
	local ok = pcall(fn)
	if ok then fail("expected an error " .. fmt(...)) end
end
function T.no_throw(fn, ...)
	count()
	local ok, e = pcall(fn)
	if not ok then fail("unexpected error: " .. tostring(e) .. " " .. fmt(...)) end
end

return T
