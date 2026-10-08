-- Loads and unloads the module (as GMod does on a map change) to check that
-- it lets go of its threads and memory.
--   luajit unload.lua   (gmcl_skategm_win64.dll and map.bsp in this folder)
local ffi = require("ffi")
ffi.cdef[[
void* GetModuleHandleA(const char* name);
int FreeLibrary(void* module);
void Sleep(unsigned int ms);
]]
local k32 = ffi.load("kernel32")
local open = assert(package.loadlib("gmcl_skategm_win64.dll", "gmod13_open"))
local close = assert(package.loadlib("gmcl_skategm_win64.dll", "gmod13_close"))
open()
local f = assert(io.open("map.bsp", "rb")) local bytes = f:read("*a") f:close()
print("load:", skategm.Load("C:/nope", 0, 0, 0, 0, bytes))
k32.Sleep(300) -- engine thread busy reading the map
print("close while the engine is busy...")
close()
print("  close returned")
-- what Garry's Mod does next: unload the module (try hard)
for i = 1, 5 do k32.FreeLibrary(k32.GetModuleHandleA("gmcl_skategm_win64.dll")) end
k32.Sleep(500) -- give any stray thread time to crash us
print("module still mapped after 5x FreeLibrary:", k32.GetModuleHandleA("gmcl_skategm_win64.dll") ~= nil and "yes (pinned) OK" or "NO")
-- next map
open()
print("load again (next map):", skategm.Load("C:/nope", 0, 0, 0, 0, bytes))
k32.Sleep(300)
local p = skategm.Poll()
print("status:", p.status, "| map:", p.world and p.world:sub(1, 60) or "-", "| error:", p.error and p.error:sub(1, 50))
close()
print("alive at the end")
