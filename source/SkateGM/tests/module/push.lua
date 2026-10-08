dofile("env.lua") TEST.open("debug")
local function wait(s) local t = os.clock() + s while os.clock() < t do end end
skategm.Load(TEST.data, 0, 0, 0, 0) wait(0.2)
skategm.Activate(0, 0, 0, 0) wait(0.1)
print("push accepted:", skategm.Push(400, 0, 0) and "OK" or "<-- WRONG")
print("nonsense rejected:", skategm.Push(0/0, 0, 0) == false and "OK" or "<-- WRONG")
for i = 1, 10 do skategm.Step(1/60, false, 0, 0,0,0,0,0,0) end wait(0.1)
print("still running:", skategm.Poll().status == "active" and "OK" or "<-- WRONG")
skategm.Stop()
