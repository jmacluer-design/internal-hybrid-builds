-- shared/json.lua : minimal JSON encoder (no decoder needed: the browser decodes) for hosts without a native `json`
-- (the wasmoon browser preview and the test harness). FiveM has its own `json.encode`; the server/client never use this file.
-- Output is deterministic (object keys sorted). Empty tables encode as [] (the UI treats [] and {} alike).
-- Numbers: integers print without a decimal point; non-finite numbers become null.
local M = {}

local format, concat = string.format, table.concat
local floor = math.floor

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function esc_char(c) return ESC[c] or format("\\u%04x", c:byte()) end

local function quote(s)
	return '"' .. s:gsub('[%c"\\]', esc_char) .. '"'
end

local function num(n)
	if n ~= n or n == math.huge or n == -math.huge then return "null" end
	if n == floor(n) and n > -1e15 and n < 1e15 then return format("%d", n) end
	return format("%.10g", n)
end

local function sorted_keys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end -- sorted below
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then return ta < tb end
		return a < b
	end)
	return keys
end

local function enc(v, buf, n, depth)
	local t = type(v)
	if t == "nil" then n = n + 1; buf[n] = "null"
	elseif t == "boolean" then n = n + 1; buf[n] = v and "true" or "false"
	elseif t == "number" then n = n + 1; buf[n] = num(v)
	elseif t == "string" then n = n + 1; buf[n] = quote(v)
	elseif t == "table" then
		if depth > 40 then error("json: too deep (cycle?)", 0) end
		local count = 0
		for _ in pairs(v) do count = count + 1 end -- counting only
		if count == 0 then
			n = n + 1; buf[n] = "[]"
		elseif count == #v then
			n = n + 1; buf[n] = "["
			for i = 1, count do
				if i > 1 then n = n + 1; buf[n] = "," end
				n = enc(v[i], buf, n, depth + 1)
			end
			n = n + 1; buf[n] = "]"
		else
			local keys = sorted_keys(v)
			n = n + 1; buf[n] = "{"
			local first = true
			for i = 1, #keys do
				local k = keys[i]
				if not first then n = n + 1; buf[n] = "," end
				first = false
				n = n + 1; buf[n] = quote(tostring(k))
				n = n + 1; buf[n] = ":"
				n = enc(v[k], buf, n, depth + 1)
			end
			n = n + 1; buf[n] = "}"
		end
	else
		n = n + 1; buf[n] = "null"
	end
	return n
end

function M.encode(v)
	local buf = {}
	enc(v, buf, 0, 0)
	return concat(buf)
end

return M
