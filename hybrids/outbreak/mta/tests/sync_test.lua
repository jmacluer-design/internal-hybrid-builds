-- The resource folder is built from reused files: sim/ + data/ (the sim core), shared/ host core + protocol + view models (the FiveM adapter), ui/ (the vanilla NUI).
-- These tests prove the copies are byte-identical, that the generated files (ui/mta.html, meta.xml, selftest data) are current, and that the checks FAIL when a copy drifts.
local T, H = ...
T.group("sync")

local function sh(cmd)
	local p = io.popen(cmd .. ' 2>&1; echo "EXIT:$?"')
	local out = p:read("*a")
	p:close()
	return tonumber(out:match("EXIT:(%d+)%s*$")), out
end

local interp = (arg and arg[-1]) or "lua5.4"

T.test("sim / data / shared / ui copies are in sync, meta.xml and the self-test hash are current", function()
	for _, tool in ipairs({ "sync_sim.sh", "sync_shared.sh", "sync_ui.sh" }) do
		local code, out = sh("sh " .. H.tools .. "/" .. tool .. " check")
		T.eq(code, 0, tool .. ": " .. out)
	end
	local code, out = sh(interp .. " " .. H.tools .. "/gen_meta.lua --check")
	T.eq(code, 0, out)
end)

T.test("the browser entry page is the vanilla index.html plus exactly one line (the bridge), inserted before the first vanilla script", function()
	local function read(p) local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s end
	local vanilla = read(H.mta .. "/../fivem/outbreak/ui/index.html")
	local entry = read(H.res .. "/ui/mta.html")
	local line = '<script src="mta-bridge.js"></script>\n'
	local pos = entry:find(line, 1, true)
	T.truthy(pos, "the bridge line is present")
	T.eq(entry:sub(1, pos - 1) .. entry:sub(pos + #line), vanilla, "removing that line gives back the vanilla page byte for byte")
	local first_script = entry:find('<script src="js/core.js"></script>', 1, true)
	T.lt(pos, first_script, "the bridge runs before js/core.js")
	T.eq(select(2, entry:gsub('<script src="mta%-bridge%.js">', "")), 1, "only once")
end)

-- a scratch copy of the tree: mta/tools + fivem/outbreak/{ui,shared} + sim + data + mta/outbreak/{ui,sim,data,shared}
local function scratch()
	local d = os.tmpname()
	os.remove(d)
	local root = d .. "/hybrids/outbreak"
	local cmds = {
		"mkdir -p " .. root .. "/mta/tools " .. root .. "/mta/outbreak " .. root .. "/fivem/outbreak",
		"cp " .. H.tools .. "/*.sh " .. root .. "/mta/tools/",
		"cp -R " .. H.mta .. "/../fivem/outbreak/ui " .. root .. "/fivem/outbreak/ui",
		"cp -R " .. H.mta .. "/../fivem/outbreak/shared " .. root .. "/fivem/outbreak/shared",
		"cp -R " .. H.mta .. "/../sim " .. root .. "/sim",
		"cp -R " .. H.mta .. "/../data " .. root .. "/data",
		"cp -R " .. H.res .. "/ui " .. root .. "/mta/outbreak/ui",
		"cp -R " .. H.res .. "/sim " .. root .. "/mta/outbreak/sim",
		"cp -R " .. H.res .. "/data " .. root .. "/mta/outbreak/data",
		"cp -R " .. H.res .. "/shared " .. root .. "/mta/outbreak/shared",
	}
	for _, c in ipairs(cmds) do os.execute(c .. " >/dev/null 2>&1") end
	return d, root
end

T.test("the checks FAIL when a copy drifts: a changed sim file, a changed shared file, a changed vanilla UI file, a stale entry page", function()
	local d, root = scratch()
	local function check(tool) return sh("sh " .. root .. "/mta/tools/" .. tool .. " check") end
	for _, tool in ipairs({ "sync_sim.sh", "sync_shared.sh", "sync_ui.sh" }) do T.eq((check(tool)), 0, "scratch copy starts clean: " .. tool) end
	os.execute("echo '-- drift' >> " .. root .. "/mta/outbreak/sim/world.lua")
	local code, out = check("sync_sim.sh")
	T.eq(code, 1, out); T.truthy(out:find("OUT OF SYNC", 1, true), out)
	os.execute("echo '-- drift' >> " .. root .. "/mta/outbreak/shared/host.lua")
	code, out = check("sync_shared.sh")
	T.eq(code, 1, out); T.truthy(out:find("host.lua", 1, true), out)
	os.execute("echo '/* drift */' >> " .. root .. "/mta/outbreak/ui/js/core.js")
	code, out = check("sync_ui.sh")
	T.eq(code, 1, out)
	os.execute("cp " .. root .. "/fivem/outbreak/ui/js/core.js " .. root .. "/mta/outbreak/ui/js/core.js")
	T.eq((check("sync_ui.sh")), 0, "restored")
	os.execute("echo '<!-- x -->' >> " .. root .. "/mta/outbreak/ui/mta.html")
	code, out = check("sync_ui.sh")
	T.eq(code, 1, out); T.truthy(out:find("generated entry page", 1, true), out)
	-- the copy mode repairs it, and leaves the bridge alone
	os.execute("sh " .. root .. "/mta/tools/sync_ui.sh >/dev/null 2>&1")
	T.eq((check("sync_ui.sh")), 0, "sync_ui.sh repaired the entry page")
	os.execute("rm -rf " .. d)
end)

T.test("meta.xml lists exactly the files a client or a browser may fetch; the server-only files are NOT listed (MTA's HTTP server serves every listed <file> without a login)", function()
	local m = H.Mock.new({ root = H.res, defs = false })
	local listed = {}
	for src in pairs(m.meta.files) do listed[src] = true end
	for _, s in ipairs(m.meta.scripts) do listed[s.src] = true end
	local p = io.popen('cd "' .. H.res .. '" && find . -type f | sed "s|^\\./||" | LC_ALL=C sort')
	local unlisted = {}
	for f in p:lines() do
		if f ~= "meta.xml" and not listed[f] then unlisted[#unlisted + 1] = f end
	end
	p:close()
	-- everything unlisted is server-side code and data: server/*.lua (main.lua is a listed <script type="server">), the shared modules no client requires, sim/, data/, save/
	local server_only = function(f) return f:match("^server/") or f:match("^sim/") or f:match("^data/") or f:match("^save/") or f:match("^shared/") end
	for _, f in ipairs(unlisted) do T.truthy(server_only(f), f .. " is not listed in meta.xml but is not a server-only file either: add it to the generator or to the server-only folders") end
	T.gt(#unlisted, 50, "the server-only files are the unlisted ones (" .. #unlisted .. ")")
	for src in pairs(listed) do
		local f = io.open(H.res .. "/" .. src, "rb")
		T.truthy(f, "listed but missing: " .. src)
		if f then f:close() end
		T.falsy(src:match("^sim/") or src:match("^data/") or (src:match("^server/") and src ~= "server/main.lua") or src:match("^save/"), src .. " is listed: MTA would serve it to anyone over HTTP")
	end
	for _, name in ipairs({ "sim/world.lua", "data/tuning.lua", "server/net.lua", "server/phone.lua", "shared/host.lua", "shared/view.lua", "shared/survival.lua", "shared/selftest.lua", "save/README.txt" }) do
		T.falsy(listed[name], name .. " must not be listed (not downloaded, not served over HTTP)")
		T.falsy(m.client_files[name], name .. " must not reach a client")
	end
	for _, name in ipairs({ "client/camera.lua", "shared/protocol.lua", "shared/mta_config.lua", "ui/mta.html", "ui/mta-bridge.js", "ui/phone-bridge.js", "ui/js/core.js", "ui/css/base.css" }) do
		T.eq(m.meta.files[name] and m.meta.files[name].download, true, name .. " must be downloadable")
	end
	-- the client's requires resolve: every module name a client file requires is a downloadable file
	for _, f in ipairs({ "client/main.lua", "client/ui.lua", "client/camera.lua", "client/noise.lua", "client/placement.lua", "client/survival.lua", "client/driver.lua", "client/ground.lua", "client/world.lua", "client/props.lua", "client/ctx.lua" }) do
		local src = assert(io.open(H.res .. "/" .. f, "rb")):read("*a")
		for mod in src:gmatch('require%("([%w_%.]+)"%)') do
			local path = mod:gsub("%.", "/") .. ".lua"
			T.truthy(m.client_files[path], f .. " requires " .. mod .. " but the client does not download " .. path)
		end
	end
end)
