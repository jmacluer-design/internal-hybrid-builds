-- shared/util.lua : small helpers used by the server, the client and the tests. Plain Lua (5.1 .. 5.4 compatible):
-- the same file runs in FiveM's Lua 5.4, in LuaJIT and in wasmoon (browser preview).
local M = {}

local floor, abs = math.floor, math.abs
local huge = math.huge

function M.clamp(x, lo, hi)
	if x < lo then return lo end
	if x > hi then return hi end
	return x
end

function M.round(x, step)
	step = step or 1
	return floor(x / step + 0.5) * step
end

-- one decimal, as a number (keeps UI payloads small)
function M.r1(x) return floor(x * 10 + 0.5) / 10 end
function M.r2(x) return floor(x * 100 + 0.5) / 100 end

function M.finite(x) return type(x) == "number" and x == x and x ~= huge and x ~= -huge end

function M.num(x, default)
	if type(x) == "string" then x = tonumber(x) end
	if M.finite(x) then return x end
	return default
end

function M.keys(t)
	local out = {}
	for k in pairs(t) do out[#out + 1] = k end -- sorted below
	table.sort(out, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then return ta < tb end
		return a < b
	end)
	return out
end

function M.copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = M.copy(v) end
	return out
end

function M.shallow(t)
	local out = {}
	for k, v in pairs(t) do out[k] = v end
	return out
end

function M.count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

-- merge `over` into a copy of `base` (tables merge recursively, everything else is replaced)
function M.merge(base, over)
	local out = M.copy(base)
	if type(over) ~= "table" then return out end
	for k, v in pairs(over) do
		if type(v) == "table" and type(out[k]) == "table" then out[k] = M.merge(out[k], v) else out[k] = M.copy(v) end
	end
	return out
end

-- 2D distance between two {x,y} tables
function M.dist2d(a, b)
	local dx, dy = a.x - b.x, a.y - b.y
	return math.sqrt(dx * dx + dy * dy)
end

local atan2 = math.atan2 or math.atan -- LuaJIT / Lua 5.4

-- compass bearing in degrees from a to b: 0 = north (+y), 90 = east (+x)
function M.bearing(a, b)
	local deg = atan2(b.x - a.x, b.y - a.y) * 180 / math.pi
	if deg < 0 then deg = deg + 360 end
	return deg
end

-- split "a,b,c" -> { "a", "b", "c" }
function M.split(s, sep)
	local out = {}
	sep = sep or ","
	for part in (tostring(s) .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = part end
	return out
end

-- "1850.0,3700.0,34" -> { x = 1850.0, y = 3700.0, z = 34.0 } (nil when malformed)
function M.parse_vec3(s)
	local p = M.split(s or "", ",")
	local x, y, z = tonumber(p[1]), tonumber(p[2]), tonumber(p[3])
	if x and y and z and M.finite(x) and M.finite(y) and M.finite(z) then return { x = x + 0.0, y = y + 0.0, z = z + 0.0 } end
	return nil
end

-- Is `v` safe to hand to msgpack (TriggerClientEvent / TriggerServerEvent payloads, exports) and to SendNUIMessage (JSON)?
-- Rules: only nil/boolean/finite number/string/table; tables are either dense arrays 1..n or string-keyed maps (never mixed,
-- never sparse, never numeric keys in a map); no metatables, no functions/userdata, no cycles, bounded depth/size.
-- Returns true, or false + a path string describing the first problem.
function M.msgpack_safe(v, limits)
	limits = limits or {}
	local max_depth = limits.depth or 12
	local max_nodes = limits.nodes or 20000
	local nodes = 0
	local seen = {}
	local function walk(x, path, depth)
		nodes = nodes + 1
		if nodes > max_nodes then return false, path .. ": too many nodes" end
		local t = type(x)
		if t == "nil" or t == "boolean" or t == "string" then return true end
		if t == "number" then
			if x ~= x or x == huge or x == -huge then return false, path .. ": non-finite number" end
			return true
		end
		if t ~= "table" then return false, path .. ": " .. t .. " is not msgpack-safe" end
		if depth > max_depth then return false, path .. ": too deep" end
		if seen[x] then return false, path .. ": cycle" end
		if getmetatable(x) ~= nil then return false, path .. ": has a metatable" end
		seen[x] = true
		local n, arr, map = 0, 0, 0
		for k in pairs(x) do
			n = n + 1
			if type(k) == "number" then arr = arr + 1 elseif type(k) == "string" then map = map + 1 else return false, path .. ": bad key type " .. type(k) end
		end
		if arr > 0 and map > 0 then return false, path .. ": mixed array/map table" end
		if arr > 0 then
			for i = 1, arr do
				if x[i] == nil then return false, path .. ": sparse array (hole at " .. i .. ")" end
			end
			if #x ~= arr then return false, path .. ": non-sequence numeric keys" end
			for i = 1, arr do
				local ok, why = walk(x[i], path .. "[" .. i .. "]", depth + 1)
				if not ok then return false, why end
			end
		else
			for k, val in pairs(x) do
				local ok, why = walk(val, path .. "." .. k, depth + 1)
				if not ok then return false, why end
			end
		end
		seen[x] = nil -- shared (non-cyclic) references are fine
		return true
	end
	return walk(v, "$", 0)
end

return M
