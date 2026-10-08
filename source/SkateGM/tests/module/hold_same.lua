dofile("env.lua") TEST.open("release")
local function wait(s) local t = os.clock() + s while os.clock() < t do end end
skategm.Load(TEST.data, 0, 0, 0, 0) wait(0.3)
skategm.Activate(0, 0, 0, 0) wait(0.3)
for i = 1, 10 do skategm.Step(1/60, false, 0x1000, 0,0,0,0,0,0) wait(0.02) end
wait(0.5)
-- past the installed region's edge, but still on the test floor (16000 across):
-- the region built there holds the same triangles, so that build is skipped
skategm.Activate(6000, 0, 0, 0) wait(0.1)
local t1 = skategm.Poll().tick
local t = os.clock() + 3
repeat skategm.Step(1/60, false, 0x1000, 0,0,0,0,0,0) wait(0.05) until skategm.Poll().tick > t1 or os.clock() > t
local p = skategm.Poll()
print(string.format("teleport onto the same collision: held %d time(s), released in under 3 s (builds %d)", p.holds or 0, p.builds10s or 0), p.tick > t1 and not p.held and "OK" or "<-- WRONG")
-- and a step in the same direction afterwards: no second hold
local h = p.holds or 0
skategm.Activate(6100, 0, 0, 0) wait(0.1)
for i = 1, 5 do skategm.Step(1/60, false, 0x1000, 0,0,0,0,0,0) wait(0.02) end
print("then a short teleport: no hold", (skategm.Poll().holds or 0) == h and not skategm.Poll().held and "OK" or "<-- WRONG")
skategm.Stop()
