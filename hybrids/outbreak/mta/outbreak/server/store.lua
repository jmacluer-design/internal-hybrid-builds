-- server/store.lua : the key-value store shared/host.lua saves through ({ get, set, del }), over MTA's file API (default) or an SQLite database.
-- Host keeps two rotating slots plus a meta pointer and a versioned, checksummed payload (shared/host.lua save_game / load_game), so a crash while writing never destroys the
-- last good save; this module only has to store strings. `set` raises on failure so that Host.save_game aborts BEFORE it flips the meta pointer.
-- Files live in the resource's own folder (save/<key>.sav, relative paths are resource-relative on the server); the database is created by dbConnect in the server's databases folder.
-- Written here; nothing borrowed.
local ctx = require("server.ctx")

local S = {}

local function path_for(key)
	return "save/" .. tostring(key):gsub("[^%w_%-]", "_") .. ".sav"
end

function S.file_store()
	local st = {}
	function st.get(key)
		local p = path_for(key)
		if not fileExists(p) then return nil end
		local f = fileOpen(p, true)
		if not f then return nil end
		local size = fileGetSize(f)
		local data = ""
		if size and size > 0 then data = fileRead(f, size) or "" end
		fileClose(f)
		return data
	end
	function st.set(key, value)
		local p = path_for(key)
		local f = fileCreate(p) -- creates or truncates
		if not f then error("fileCreate failed for " .. p) end
		local n = fileWrite(f, value)
		fileClose(f)
		if n ~= #value then error(string.format("short write to %s (%s of %d bytes)", p, tostring(n), #value)) end
	end
	function st.del(key)
		local p = path_for(key)
		if fileExists(p) then fileDelete(p) end
	end
	st.kind = "file"
	return st
end

function S.sqlite_store()
	local db = dbConnect("sqlite", "outbreak.db")
	if not db then return nil, "dbConnect(sqlite) failed" end
	if not dbExec(db, "CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT)") then return nil, "cannot create the kv table" end
	local st = {}
	function st.get(key)
		local q = dbQuery(db, "SELECT v FROM kv WHERE k = ?", tostring(key))
		if not q then return nil end
		local rows = dbPoll(q, -1)
		if type(rows) == "table" and rows[1] then return rows[1].v end
		return nil
	end
	function st.set(key, value)
		if not dbExec(db, "INSERT OR REPLACE INTO kv (k, v) VALUES (?, ?)", tostring(key), value) then error("sqlite write failed for " .. tostring(key)) end
	end
	function st.del(key) dbExec(db, "DELETE FROM kv WHERE k = ?", tostring(key)) end
	st.kind = "sqlite"
	return st
end

-- kind = "file" | "sqlite"; falls back to the file store (with a log line) when the database cannot be opened
function S.open(kind)
	if kind == "sqlite" then
		local st, why = S.sqlite_store()
		if st then return st end
		ctx.log("warn", "sqlite store unavailable (" .. tostring(why) .. "); using files")
	end
	return S.file_store()
end

return S
