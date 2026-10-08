dofile("env.lua") TEST.open("release")
local function wait(s) local t = os.clock() + s while os.clock() < t do end end
local bytes = TEST.mapBytes()
local cx, cy, cz = TEST.centre[1], TEST.centre[2], TEST.centre[3]
skategm.Load(TEST.data, cx, cy, cz, 0, bytes, 1, 1) wait(4)
skategm.Activate(cx, cy, cz, 0) wait(2)
local all = skategm.CollisionNear(cx, cy, cz, 1e6, 1e7)
print(string.format("collision triangles in the region: %d", #all / 9))
local t = os.clock()
local hits = 0
for i = 1, 2000 do if skategm.CollisionHas(cx + i % 50, cy, cz, 600) then hits = hits + 1 end end
print(string.format("CollisionHas: %.3f ms per call (%d/2000 found a surface)", (os.clock() - t) / 2000 * 1000, hits))
t = os.clock()
for i = 1, 200 do skategm.CollisionNear(cx + i % 50, cy, cz, 16, 200) end
print(string.format("CollisionNear (16 units): %.3f ms per call", (os.clock() - t) / 200 * 1000))
skategm.Stop()
