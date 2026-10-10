-- fivem/tools/native_check.lua : verifies that EVERY native the resource's Lua calls exists in the FiveM native definitions, and that it
-- is available on the side (client / server) that calls it.
--
--   lua5.4 fivem/tools/native_check.lua [--resource DIR] [--natives FILE] [--decls DIR] [--runtime FILE] [--list] [--quiet]
--
-- Sources of truth (cloned FiveM repo, default /home/user/citizenfx/fivem):
--   ext/natives/natives_stash/gta_universal.lua  every GTA native: `native "SNAKE_CASE_NAME"` (client side unless marked otherwise)
--   ext/native-decls/**/*.md                      every CFX native: file name + `## SNAKE_CASE_NAME` + `apiset: client|server|shared` header
--   data/shared/citizen/scripting/lua/scheduler.lua  the Lua runtime's own global functions (Wait, AddEventHandler, TriggerEvent ...)
-- Name mapping is FiveM's own (codegen_out_lua.lua): lower-case, `_x` -> `X`, first letter upper-case: GET_ENTITY_COORDS -> GetEntityCoords.
--
-- What counts as a native use: a PascalCase identifier that is CALLED (Name(...), Name{...}, Name"..") and is not a field access (a.Name,
-- a:Name), not a name this resource defines itself (function Name / local function Name / Name = function), and not a Lua runtime global.
-- Exit code 1 when an unknown native is found, when a native is used on the wrong side, or when a source file is missing.
local args = { ... }
local opt = { resource = nil, natives = nil, decls = nil, runtime = nil, list = false, quiet = false, files = {} }
do
	local i = 1
	while i <= #args do
		local a = args[i]
		if a == "--resource" then opt.resource = args[i + 1]; i = i + 1
		elseif a == "--natives" then opt.natives = args[i + 1]; i = i + 1
		elseif a == "--decls" then opt.decls = args[i + 1]; i = i + 1
		elseif a == "--runtime" then opt.runtime = args[i + 1]; i = i + 1
		elseif a == "--list" then opt.list = true
		elseif a == "--quiet" then opt.quiet = true
		elseif a == "--file" then opt.files[#opt.files + 1] = args[i + 1]; i = i + 1 end
		i = i + 1
	end
end

local script_dir = (arg and arg[0] or "native_check.lua"):gsub("\\", "/"):match("^(.*)/[^/]*$") or "."
local FIVEM = os.getenv("FIVEM_SRC") or "/home/user/citizenfx/fivem"
opt.resource = opt.resource or (script_dir .. "/../outbreak")
opt.natives = opt.natives or (FIVEM .. "/ext/natives/natives_stash/gta_universal.lua")
opt.decls = opt.decls or (FIVEM .. "/ext/native-decls")
opt.runtime = opt.runtime or (FIVEM .. "/data/shared/citizen/scripting/lua/scheduler.lua")

local function read(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function die(msg) io.stderr:write("native_check: " .. msg .. "\n"); os.exit(2) end

-- FiveM's name conversion (codegen_out_lua.lua printFunctionName)
local function pascal(name)
	return (name:lower():gsub("0x", "n_0x"):gsub("_(%a)", string.upper):gsub("(%a)(.+)", function(a, b) return a:upper() .. b end))
end

-- ---------------------------------------------------------------------------------------------------------------- native sets
-- known[name] = { client = bool, server = bool, src = "gta|cfx" }
local known = {}
local function add(name, client, server, src)
	local k = known[name]
	if not k then known[name] = { client = client, server = server, src = src }
	else k.client = k.client or client; k.server = k.server or server end
end

local gta = read(opt.natives) or die("cannot read " .. opt.natives)
local n_gta = 0
do
	local current
	for line in gta:gmatch("[^\n]+") do
		local nm = line:match('^native "([%w_]+)"')
		if nm then current = pascal(nm); add(current, true, false, "gta"); n_gta = n_gta + 1
		elseif current then
			local ap = line:match('^%s*apiset%s+[\'"](%a+)[\'"]')
			if ap then
				local k = known[current]
				k.client, k.server = (ap == "client" or ap == "shared"), (ap == "server" or ap == "shared")
			end
		end
	end
end

local n_cfx = 0
do
	local p = io.popen('find "' .. opt.decls .. '" -name "*.md" 2>/dev/null')
	if not p then die("cannot list " .. opt.decls) end
	for path in p:lines() do
		local text = read(path)
		if text then
			local fm = text:match("^%-%-%-\n(.-)\n%-%-%-")
			local ap = fm and fm:match("apiset:%s*(%a+)") or "shared"
			local game = fm and fm:match("game:%s*(%w+)") -- a decl that exists only for RedM / LibertyM is not a GTA V native
			local client, server = (ap == "client" or ap == "shared"), (ap == "server" or ap == "shared")
			local base = path:match("([^/]+)%.md$")
			if not game or game == "gta5" then
				if base then add(base, client, server, "cfx"); n_cfx = n_cfx + 1 end
				for nm in text:gmatch("\n## ([%w_]+)") do add(pascal(nm), client, server, "cfx") end
			end
		end
	end
	p:close()
end
if n_cfx == 0 then die("no native-decls found under " .. opt.decls) end

-- Lua runtime globals (scheduler.lua) + the few documented pseudo-globals
local runtime = {}
do
	local sch = read(opt.runtime) or die("cannot read " .. opt.runtime)
	for nm in sch:gmatch("\n%s*function%s+([%w_]+)%s*%(") do runtime[nm] = true end
	for nm in sch:gmatch("\n%s*([%u][%w_]*)%s*=%s*[%w_.]+%s*\n") do runtime[nm] = true end -- e.g. `Wait = Citizen.Wait`
	for _, nm in ipairs({ "Wait", "CreateThread", "SetTimeout", "ClearTimeout", "Citizen", "Entity", "Player", "GlobalState", "RegisterNetEvent", "AddEventHandler",
		"RemoveEventHandler", "TriggerEvent", "TriggerServerEvent", "TriggerClientEvent", "TriggerLatentClientEvent", "TriggerLatentServerEvent", "RegisterNUICallback",
		"SendNUIMessage", "PerformHttpRequest", "GetPlayers", "GetPlayerIdentifiers", "GetPlayerTokens" }) do runtime[nm] = true end
end

-- ---------------------------------------------------------------------------------------------------------------- scanning
local function list_lua(dir)
	local out = {}
	local p = io.popen('find "' .. dir .. '" -name "*.lua" -not -path "*/sim/*" -not -path "*/data/*" 2>/dev/null | sort')
	for f in p:lines() do out[#out + 1] = f end
	p:close()
	return out
end

-- remove comments and string contents so words inside them are not mistaken for calls (line structure is preserved)
local function strip(src)
	local out, i, n = {}, 1, #src
	while i <= n do
		local c = src:sub(i, i)
		if c == "-" and src:sub(i, i + 1) == "--" then
			local lvl = src:match("^%-%-%[(=*)%[", i)
			if lvl then
				local close = "]" .. lvl .. "]"
				local j = src:find(close, i, true) or n
				local chunk = src:sub(i, j + #close - 1)
				out[#out + 1] = (chunk:gsub("[^\n]", " "))
				i = j + #close
			else
				local j = src:find("\n", i, true) or (n + 1)
				i = j
			end
		elseif c == "[" and src:match("^%[=*%[", i) then
			local lvl = src:match("^%[(=*)%[", i)
			local close = "]" .. lvl .. "]"
			local j = src:find(close, i, true) or n
			local chunk = src:sub(i, j + #close - 1)
			out[#out + 1] = '""' .. (chunk:gsub("[^\n]", " "))
			i = j + #close
		elseif c == '"' or c == "'" then
			local j = i + 1
			while j <= n do
				local d = src:sub(j, j)
				if d == "\\" then j = j + 2
				elseif d == c or d == "\n" then break
				else j = j + 1 end
			end
			out[#out + 1] = c .. c
			i = j + 1
		elseif c == "`" then -- FiveM backtick hash literal
			local j = src:find("`", i + 1, true) or n
			out[#out + 1] = "0"
			i = j + 1
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

-- names this resource defines itself (any file): function Name / local function Name / Name = function / local Name = function
local defined = {}
local files = #opt.files > 0 and opt.files or list_lua(opt.resource)
if #files == 0 then die("no Lua files under " .. opt.resource) end
local stripped = {}
for _, f in ipairs(files) do
	local src = read(f) or die("cannot read " .. f)
	local s = strip(src)
	stripped[f] = s
	for nm in s:gmatch("function%s+([%u][%w_]*)%s*%(") do defined[nm] = true end
	for nm in s:gmatch("([%u][%w_]*)%s*=%s*function") do defined[nm] = true end
	for nm in s:gmatch("local%s+([%u][%w_]*)%s*=") do defined[nm] = true end
	for nm in s:gmatch("local%s+([%u][%w_]*)%s*,") do defined[nm] = true end
end

local function side_of(path)
	if path:find("/server/", 1, true) then return "server" end
	if path:find("/client/", 1, true) then return "client" end
	return "shared"
end

local uses = {}     -- name -> { count, where = { "file:line" }, sides = {client=,server=} }
local problems = {}
for _, f in ipairs(files) do
	local side = side_of(f)
	local ln = 0
	for line in (stripped[f] .. "\n"):gmatch("([^\n]*)\n") do
		ln = ln + 1
		local pos = 1
		while true do
			local s, e, pre, name, post = line:find("([%.:]?)%f[%w_]([%u][%w_]*)%s*([%(%{\"'])", pos)
			if not s then break end
			pos = e + 1
			-- identifiers preceded by `.` or `:` are fields/methods (Config.Foo(), obj:Foo()); `function Name(` declarations are filtered via `defined`
			if pre == "" and not defined[name] and not runtime[name] then
				local u = uses[name]
				if not u then u = { count = 0, where = {}, sides = {} }; uses[name] = u end
				u.count = u.count + 1
				u.sides[side] = true
				if #u.where < 3 then u.where[#u.where + 1] = f:match("([^/]+/[^/]+)$") .. ":" .. ln end
				local k = known[name]
				if not k then
					problems[#problems + 1] = string.format("UNKNOWN native %s at %s:%d", name, f, ln)
				elseif side == "client" and not k.client then
					problems[#problems + 1] = string.format("%s is not available on the CLIENT (used at %s:%d)", name, f, ln)
				elseif side == "server" and not k.server then
					problems[#problems + 1] = string.format("%s is not available on the SERVER (used at %s:%d)", name, f, ln)
				elseif side == "shared" and not (k.client and k.server) then
					problems[#problems + 1] = string.format("%s is not available on both sides but is used in shared code (%s:%d)", name, f, ln)
				end
			end
		end
	end
end

-- dedupe identical problem lines
local seen, uniq = {}, {}
for _, p in ipairs(problems) do if not seen[p] then seen[p] = true; uniq[#uniq + 1] = p end end

local names = {}
for nm in pairs(uses) do names[#names + 1] = nm end
table.sort(names)

if not opt.quiet then
	print(string.format("native_check: %d Lua files scanned under %s", #files, opt.resource))
	print(string.format("native_check: definitions loaded: %d GTA natives (gta_universal.lua) + %d CFX decl files; runtime globals: %d", n_gta, n_cfx, (function() local c = 0 for _ in pairs(runtime) do c = c + 1 end return c end)()))
	print(string.format("native_check: %d distinct natives used", #names))
	if opt.list then
		for _, nm in ipairs(names) do
			local u = uses[nm]
			local sides = {}
			for s in pairs(u.sides) do sides[#sides + 1] = s end
			table.sort(sides)
			print(string.format("  %-40s x%-3d [%s] %s", nm, u.count, table.concat(sides, "+"), known[nm] and known[nm].src or "?"))
		end
	end
end
if #uniq > 0 then
	for _, p in ipairs(uniq) do print("FAIL " .. p) end
	print(string.format("native_check: FAILED with %d problem(s)", #uniq))
	os.exit(1)
end
if not opt.quiet then print("native_check: OK, every native exists and is available on the side that calls it") end
os.exit(0)
