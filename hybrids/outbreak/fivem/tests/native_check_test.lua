-- tools/native_check.lua: passes on the resource, FAILS on a file that calls a made-up native or a client-only native on the server.
local T, H = ...
local interp = (arg and arg[-1]) or "lua5.4"
local tool = H.tools .. "/native_check.lua"

T.group("native_check")

local function run(args)
	local p = io.popen(string.format('%s %s %s 2>&1; echo "EXIT:$?"', interp, tool, args))
	local out = p:read("*a")
	p:close()
	local code = tonumber(out:match("EXIT:(%d+)%s*$"))
	return code, out
end

local function tmpdir()
	local d = os.tmpname()
	os.remove(d)
	os.execute("mkdir -p " .. d .. "/server " .. d .. "/client " .. d .. "/shared")
	return d
end

local function write(path, text) local f = assert(io.open(path, "wb")); f:write(text); f:close() end

T.test("the resource passes, and the checker reports how many natives it checked", function()
	local code, out = run("--resource " .. H.res)
	T.eq(code, 0, out)
	T.truthy(out:find("every native exists", 1, true), out)
	local n = tonumber(out:match("(%d+) distinct natives used"))
	T.truthy(n and n >= 120, "checked " .. tostring(n) .. " distinct natives")
	T.note("native_check: %s distinct natives, exit 0", tostring(n))
end)

T.test("an unknown native fails the check", function()
	local d = tmpdir()
	write(d .. "/client/a.lua", "local x = GetEntityCoords(PlayerPedId())\nlocal y = DefinitelyNotANative(x)\n")
	local code, out = run("--resource " .. d)
	T.eq(code, 1, out)
	T.truthy(out:find("UNKNOWN native DefinitelyNotANative", 1, true), out)
	os.execute("rm -rf " .. d)
end)

T.test("a client-only native used on the server fails; a server-only native used on the client fails", function()
	local d = tmpdir()
	write(d .. "/server/a.lua", "local p = PlayerPedId()\n")
	write(d .. "/client/a.lua", "local n = GetPlayerEndpoint(1)\nlocal ok = GetPlayerName(1)\n")
	local code, out = run("--resource " .. d)
	T.eq(code, 1, out)
	T.truthy(out:find("PlayerPedId is not available on the SERVER", 1, true), out)
	T.truthy(out:find("GetPlayerEndpoint is not available on the CLIENT", 1, true), out)
	T.falsy(out:find("GetPlayerName is not available", 1, true), "GetPlayerName exists on both sides")
	os.execute("rm -rf " .. d)
end)

T.test("field access, own functions, strings and comments are not mistaken for natives", function()
	local d = tmpdir()
	write(d .. "/client/a.lua", table.concat({
		"local M = {}",
		"function M.Frobnicate() end",
		"function Helper() end",
		"-- NotANative(1) in a comment",
		"local s = 'FakeInString(2)'",
		"M.Frobnicate()",
		"Helper()",
		"local c = PlayerPedId()",
	}, "\n"))
	local code, out = run("--resource " .. d)
	T.eq(code, 0, out)
	os.execute("rm -rf " .. d)
end)

T.test("a missing definitions file is an error, not a silent pass", function()
	local code, out = run("--resource " .. H.res .. " --natives /nonexistent/gta_universal.lua")
	T.ne(code, 0, out)
end)
