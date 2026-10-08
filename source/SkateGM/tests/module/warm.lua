dofile("env.lua") TEST.open("debug")
local function wait(s) local t = os.clock() + s while os.clock() < t do end end
print("before:", skategm.WarmStatus())
local started = skategm.Preload(TEST.data)
local s1 = skategm.WarmStatus()
wait(0.3)
local s2, ms = skategm.WarmStatus()
print(string.format("started %s, then %s, then %s (%d ms)", tostring(started), s1, s2, ms), (started and s1 == "warming" and s2 == "warm") and "OK" or "<-- WRONG")
print("a second call doesn't start another load:", skategm.Preload(TEST.data) == false and "OK" or "<-- WRONG")
