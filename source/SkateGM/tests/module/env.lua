-- Where the module tests find the stand-in module (cargo build --no-default-features),
-- a map and a data folder: on Linux (the .so, /tmp) or on Windows (the
-- stand-in DLL). SK8_TEST_DLL and SK8_TEST_MAP (a .bsp) override both.
TEST = {}
TEST.windows = package.config:sub(1, 1) == "\\"
local function exists(p) local f = io.open(p, "rb") if f then f:close() return true end return false end
TEST.exists = exists

function TEST.dll(kind)
	local e = os.getenv("SK8_TEST_DLL")
	if e then return e end
	local name = TEST.windows and "gmcl_skategm_win64.dll" or "libgmcl_skategm_win64.so"
	for _, k in ipairs({ kind or "release", "release", "debug" }) do
		local p = "../../gm_skategm/target/" .. k .. "/" .. name
		if exists(p) then return p end
	end
	error("no stand-in module built: cargo build --no-default-features (in gm_skategm)")
end

function TEST.open(kind)
	local open = assert(package.loadlib(TEST.dll(kind), "gmod13_open"))
	open()
end

TEST.data = TEST.windows and "" or "/tmp"

-- a map, and a point in the middle of it (its collision is built around there)
local KOTH = "/tmp/vbsp-src/koth_bagel_rc2a.bsp"
local TL = os.getenv("SK8_TEST_TL") or "../../harness/maps/tl_skatepark.bsp"
TEST.map = os.getenv("SK8_TEST_MAP") or (exists(KOTH) and KOTH) or TL
TEST.centre = TEST.map == KOTH and { 0, 0, 0 } or TEST.map == TL and { -2600, -700, 420 } or { 0, 0, 0 }

function TEST.mapBytes()
	local f = assert(io.open(TEST.map, "rb"))
	local bytes = f:read("*a")
	f:close()
	return bytes
end
