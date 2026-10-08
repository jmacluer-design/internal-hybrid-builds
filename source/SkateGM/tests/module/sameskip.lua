dofile("env.lua") TEST.open("debug")
local function wait(s) local t = os.clock() + s while os.clock() < t do end end
skategm.Load(TEST.data, 0, 0, 0, 0) wait(0.3)
skategm.Activate(0, 0, 0, 0) wait(0.5)
local function builds() for i = 1, 3 do skategm.Step(1/60, false, 0, 0,0,0,0,0,0) wait(0.05) end return skategm.Poll().builds10s or 0 end
local b0 = builds()
for i = 1, 5 do skategm.SetEntities({}) wait(0.3) end
skategm.Activate(0, 0, 0, 0) wait(0.5)
local b1 = builds()
print(string.format("identical updates and a teleport in place: builds %d -> %d", b0, b1), b1 == b0 and "OK" or "<-- WRONG")
skategm.DefineModel("models/box.mdl", { { -10,-10,0, 10,-10,0, 10,10,0,  -10,-10,0, 10,10,0, -10,10,0,  -10,-10,20, 10,10,20, 10,-10,20,  -10,-10,20, -10,10,20, 10,10,20 } })
skategm.SetEntities({ { "models/box.mdl", 50, 0, 0, 0, 0, 0 } }) wait(0.5)
-- (a build takes its time: up to 5 s, slower machines included)
local b2, t2 = builds(), os.clock()
while b2 <= b1 and os.clock() - t2 < 5 do b2 = builds() end
print(string.format("a real change (a box appears): builds %d -> %d", b1, b2), b2 > b1 and "OK" or "<-- WRONG")
for i = 1, 20 do skategm.Step(1/60, false, 0, 0,0,0,0,0,0) wait(0.1) end
print("after 2 s: builds", skategm.Poll().builds10s, "|", skategm.Poll().collision)
skategm.Stop()
