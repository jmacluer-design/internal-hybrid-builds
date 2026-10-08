dofile("env.lua") TEST.open("debug")
local before = os.getenv("PATH")
local r = skategm.SetTuning("PATH", "x")
print("other variables are refused and left alone:", (not r) and os.getenv("PATH") == before and "OK" or "<-- WRONG")
