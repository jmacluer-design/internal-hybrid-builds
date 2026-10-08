dofile("gmock.lua")
local function check(label, ok) print(string.format("%-72s %s", label, ok and "OK" or "<-- WRONG")) end
local runs = {}
hook = { Add = function() end, Run = function(name, ply, chunk, old) runs[#runs + 1] = { name = name, ply = ply, chunk = chunk, old = old } end }
timer = { Create = function() end }
game = { GetMap = function() return "gm_infmap_whatever" end }
function IsValid(x) return x ~= nil end
InfMap = { chunk_size = 5000 }
local ply = { SkateGM = true, CHUNK_OFFSET = Vector(2, 0, 0) }
player = { GetAll = function() return { ply } end }
dofile("../../addon/skategm/lua/skategm/sv_infmap.lua")
local IMS = SkateGM.infmapServer
local function chunks() local got = {} for _, q in ipairs(runs) do got[q.chunk.x .. "," .. q.chunk.y] = (got[q.chunk.x .. "," .. q.chunk.y] or 0) + 1 end return got end

IMS.Think(0)
local got = chunks()
local n = 0
for _ in pairs(got) do n = n + 1 end
check("skating: InfMap's own PropUpdateChunk for all 8 chunks around mine", #runs == 8 and n == 8 and not got["2,0"] and got["1,-1"] and got["3,1"])
check("... reported as arriving from mine (so the map keeps mine)", runs[1].name == "PropUpdateChunk" and runs[1].ply == ply and runs[1].old.x == 2)
runs = {}
IMS.Think(1)
check("... asked once, not every look", #runs == 0)
IMS.Think(IMS.REFRESH + 0.1)
check("... and again every IMS.REFRESH seconds (a map drops a chunk when its last player leaves)", #runs == 8)

-- crossing into the next chunk: only the new row is asked for; the far row
-- is kept a while (skating back over the border doesn't rebuild it)
runs = {}
ply.CHUNK_OFFSET = Vector(3, 0, 0)
IMS.Think(6)
got = chunks()
check("crossed into the next chunk: the new row asked for, and the chunk I left", got["4,-1"] and got["4,0"] and got["4,1"] and got["2,0"] and not got["3,0"])
check("... the far row isn't let go yet", not got["1,0"])
runs = {}
IMS.Think(6 + IMS.KEEP + 0.1)
local released = 0
for _, q in ipairs(runs) do if q.chunk.x == 3 and q.chunk.y == 0 and q.old.x == 1 then released = released + 1 end end
check("... after IMS.KEEP seconds the far row is reported left (the map tidies it)", released == 3)

-- back into a chunk I'd been in: it's asked for again when I leave it
runs = {}
ply.CHUNK_OFFSET = Vector(4, 0, 0)
IMS.Think(30)
ply.CHUNK_OFFSET = Vector(3, 0, 0)
runs = {}
IMS.Think(31)
check("left a chunk I'd crossed into: asked for again (the map dropped it)", chunks()["4,0"] == 1)

ply.SkateGM = false
runs = {}
IMS.Think(32)
check("not skating: nothing asked for", #runs == 0)
