-- rng.lua : portable Park-Miller / Lehmer generator (a = 48271, m = 2^31 - 1).
-- Every intermediate product is < 2^47 so it is exact in doubles AND in 64-bit integers:
-- LuaJIT and Lua 5.4 produce bit-identical streams. State is two plain numbers
-- ({ seed = ..., s = ... }) so it serializes and restores with save().
local U = require("sim.util")

local M = {}
M.__index = M

local A, MOD = 48271, 2147483647
local floor = math.floor

-- scramble an arbitrary seed (number or string) into [1, MOD-1]. Raw Park-Miller maps adjacent
-- seeds to adjacent first outputs, so we hash first and then warm the stream up.
local function seed_to_state(seed)
	local str
	if type(seed) == "number" then str = U.fmt_num(floor(seed)) .. "#seed" else str = seed end
	local s = U.hash_num(str) % (MOD - 1) + 1
	return s
end

function M.new(seed)
	local s = seed_to_state(seed or 1)
	local r = setmetatable({ seed = s, s = s }, M)
	for _ = 1, 6 do r.s = (r.s * A) % MOD end -- warm-up
	return r
end

-- re-attach the metatable to a deserialized table
function M.attach(t) return setmetatable(t, M) end

function M:raw()
	local s = (self.s * A) % MOD
	self.s = s
	return s
end

-- uniform float in [0, 1)
function M:float()
	return (self:raw() - 1) / MOD
end

-- uniform float in [lo, hi)
function M:range(lo, hi) return lo + (hi - lo) * self:float() end

-- uniform integer in [lo, hi] inclusive
function M:int(lo, hi)
	if hi < lo then lo, hi = hi, lo end
	return lo + floor(self:float() * (hi - lo + 1))
end

function M:chance(p)
	if p <= 0 then return false end
	if p >= 1 then return true end
	return self:float() < p
end

-- approx normal(mean, sd) from the sum of 4 uniforms (Irwin-Hall); no log/cos so it is portable
function M:gauss(mean, sd)
	local s = self:float() + self:float() + self:float() + self:float() - 2 -- var = 4/12
	return (mean or 0) + s * 1.7320508075688772 * (sd or 1)
end

function M:pick(list)
	local n = #list
	if n == 0 then return nil end
	return list[self:int(1, n)]
end

-- entries: array of tables; wfn(entry) -> weight (>= 0), or the field name holding it ("w")
function M:weighted(entries, wfn)
	local total = 0
	local n = #entries
	local get = wfn
	if type(wfn) ~= "function" then
		local key = wfn or "w"
		get = function(e) return e[key] or 0 end
	end
	for i = 1, n do total = total + get(entries[i]) end
	if total <= 0 then return nil, nil end
	local x = self:float() * total
	for i = 1, n do
		local w = get(entries[i])
		if x < w then return entries[i], i end
		x = x - w
	end
	-- float rounding guard: last entry with positive weight
	for i = n, 1, -1 do if get(entries[i]) > 0 then return entries[i], i end end
	return nil, nil
end

-- in-place Fisher-Yates
function M:shuffle(list)
	for i = #list, 2, -1 do
		local j = self:int(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

-- An independent stream derived from (seed, label). Does NOT consume this stream, so forking
-- never perturbs the parent and the same label always gives the same child.
function M:fork(label)
	if type(label) == "number" then label = U.fmt_num(label) end
	local mixed = U.fmt_num(self.seed) .. "/" .. label
	local child = setmetatable({}, M)
	child.seed = U.hash_num(mixed) % (MOD - 1) + 1
	child.s = child.seed
	for _ = 1, 6 do child.s = (child.s * A) % MOD end
	return child
end

function M:state() return self.s end
function M:setstate(s) self.s = s end
function M:copy() return setmetatable({ seed = self.seed, s = self.s }, M) end

return M
