dofile("env.lua") TEST.open("debug")
local function wait(s) local t = os.clock() + s while os.clock() < t do end end
skategm.Load(TEST.data, 0, 0, 0, 0) wait(0.3)
skategm.Activate(0, 0, 0, 0) wait(0.3)
for i = 1, 10 do skategm.Step(1/60, false, 0x1000, 0,0,0,0,0,0) wait(0.02) end
wait(0.5)
local t0 = skategm.Poll().tick
-- far away: outside the region the collision covers
skategm.Activate(30000, 30000, 0, 0) wait(0.1)
for i = 1, 5 do skategm.Step(1/60, false, 0x1000, 0,0,0,0,0,0) wait(0.02) end
local t1 = skategm.Poll().tick
print(string.format("far teleport: held until collision there is in (holds %d)", skategm.Poll().holds), skategm.Poll().holds == 1 and "OK" or "<-- WRONG")
local t = os.clock() + 20
repeat skategm.Step(1/60, false, 0x1000, 0,0,0,0,0,0) wait(0.05) until skategm.Poll().tick > t1 or os.clock() > t
local p = skategm.Poll()
print(string.format("collision there is in: released, simulating again at %.0f %.0f", p.pos[1], p.pos[2]), p.tick > t1 and math.abs(p.pos[1] - 30000) < 500 and "OK" or "<-- WRONG")
-- a teleport inside the region: no hold
local t2 = p.tick
skategm.Activate(30100, 30000, 0, 0) wait(0.1)
for i = 1, 5 do skategm.Step(1/60, false, 0x1000, 0,0,0,0,0,0) wait(0.02) end
print("a short teleport: carries straight on, no hold", skategm.Poll().tick > t2 and skategm.Poll().holds == 1 and not skategm.Poll().held and "OK" or "<-- WRONG")
skategm.Stop()
