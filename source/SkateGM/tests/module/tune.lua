dofile("env.lua") TEST.open("debug")
-- (on Windows the module's environment isn't the one luajit's os.getenv reads:
-- separate C runtimes - only that the call is accepted is checked there)
local env = function(v) return TEST.windows or os.getenv("SK8_CURVE_CAP") == v end
print("tuning set:", skategm.SetTuning("SK8_CURVE_CAP", "16") and env("16") and "OK" or "<-- WRONG")
print("tuning cleared:", skategm.SetTuning("SK8_CURVE_CAP", nil) and env(nil) and "OK" or "<-- WRONG")
-- (refused: returns false, as tune2.lua checks in full)
print("only SK8_ switches:", skategm.SetTuning("PATH", "x") == false and "OK" or "<-- WRONG")
print("speed limit accepted:", skategm.SetSpeedLimit(25) and "OK" or "<-- WRONG")
