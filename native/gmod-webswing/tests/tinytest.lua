-- A tiny test harness (no dependencies). Used by run.lua and the *_test.lua files.
local T = { passed = 0, failed = 0, failures = {}, current = nil, root = "." }

local function fmt(...)
	local n = select("#", ...)
	if n == 0 then return "" end
	local ok, s = pcall(string.format, ...)
	return ok and s or tostring((...))
end

function T.note(...) print("      " .. fmt(...)) end

function T.test(name, fn)
	T.current = name
	local ok, err = xpcall(fn, function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end)
	if ok then
		T.passed = T.passed + 1
		print("  PASS  " .. name)
	else
		T.failed = T.failed + 1
		T.failures[#T.failures + 1] = name
		print("  FAIL  " .. name)
		print("        " .. tostring(err):gsub("\n", "\n        "))
	end
	T.current = nil
end

local function fail(msg, level) error(msg, (level or 1) + 2) end

function T.truthy(v, ...) if not v then fail("expected truthy: " .. fmt(...)) end end
function T.falsy(v, ...) if v then fail("expected falsy: " .. fmt(...)) end end
function T.eq(a, b, ...) if a ~= b then fail(string.format("expected %s == %s %s", tostring(a), tostring(b), fmt(...))) end end
function T.near(a, b, tol, ...)
	if a ~= a or b ~= b or math.abs(a - b) > tol then
		fail(string.format("expected %.9g ~= %.9g (tol %.3g) %s", a, b, tol, fmt(...)))
	end
end
function T.lt(a, b, ...) if not (a < b) then fail(string.format("expected %.9g < %.9g %s", a, b, fmt(...))) end end
function T.le(a, b, ...) if not (a <= b) then fail(string.format("expected %.9g <= %.9g %s", a, b, fmt(...))) end end
function T.gt(a, b, ...) if not (a > b) then fail(string.format("expected %.9g > %.9g %s", a, b, fmt(...))) end end
function T.finite(a, ...) if a ~= a or a == math.huge or a == -math.huge then fail("expected a finite number " .. fmt(...)) end end

return T
