-- Every native the resource uses (as listed by tools/native_check.lua) is implemented by the mock on the side that calls it, so a new native
-- cannot be added to the code without a mock, and the mock cannot silently rot.
local T, H = ...
local interp = (arg and arg[-1]) or "lua5.4"

T.group("native_coverage")

local function used_natives()
	local p = io.popen(string.format("%s %s/native_check.lua --list --resource %s 2>&1", interp, H.tools, H.res))
	local out = p:read("*a")
	p:close()
	local list = {}
	for name, sides in out:gmatch("\n  (%S+)%s+x%d+%s+%[([%a+]+)%]") do list[#list + 1] = { name = name, sides = sides } end
	return list, out
end

T.test("the mock implements every native the resource calls, on every side that calls it", function()
	local list, out = used_natives()
	T.gt(#list, 120, "parsed the native list: " .. out:sub(1, 200))
	local m = H.Mock.new({ root = H.res })
	local server, client = m:make_side("server"), m:make_side("client")
	local missing = {}
	for _, u in ipairs(list) do
		local on_client = u.sides:find("client", 1, true) or u.sides:find("shared", 1, true)
		local on_server = u.sides:find("server", 1, true) or u.sides:find("shared", 1, true)
		if on_client and rawget(client.env, u.name) == nil then missing[#missing + 1] = "client:" .. u.name end
		if on_server and rawget(server.env, u.name) == nil then missing[#missing + 1] = "server:" .. u.name end
	end
	T.eq(#missing, 0, "missing from the mock: " .. table.concat(missing, ", "))
	T.note("%d natives, all implemented by the mock", #list)
end)

T.test("an unimplemented native or a client native on the server raises", function()
	local m = H.Mock.new({ root = H.res })
	local server, client = m:make_side("server"), m:make_side("client")
	T.throws(function() return client.env.TotallyFakeNative() end)
	T.throws(function() return server.env.PlayerPedId() end)
	T.eq(client.env.someLowerCaseThing, nil)
end)

T.test("the mock refuses what the real game refuses: unloaded models, stale handles, deleting the player", function()
	local m = H.Mock.new({ root = H.res })
	local client = m:make_side("client")
	local e = client.env
	local h = e.GetHashKey("a_m_y_runner_01")
	T.throws(function() e.CreatePed(4, h, 0.0, 0.0, 30.0, 0.0, false, false) end, "CreatePed before the model streamed in")
	e.RequestModel(h)
	T.eq(e.HasModelLoaded(h), false, "streaming takes time")
	m:step(200)
	T.eq(e.HasModelLoaded(h), true)
	local ped = e.CreatePed(4, h, 0.0, 0.0, 30.0, 0.0, false, false)
	T.truthy(e.DoesEntityExist(ped))
	e.DeleteEntity(ped)
	T.falsy(e.DoesEntityExist(ped))
	e.SetEntityHealth(ped, 50)
	T.eq(m.stale_calls.SetEntityHealth, 1, "using a deleted handle is recorded")
	T.throws(function() e.DeleteEntity(e.PlayerPedId()) end)
end)
