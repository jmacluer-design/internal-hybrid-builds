@echo off
rem One real-engine harness run. Edit the paths, then e.g.:
rem   run_harness.bat classicold det_c.txt
set SK8_DLL=..\gm_skategm\prebuilt\gmcl_skategm_win64.dll
if not defined SK8_DATA set SK8_DATA=%LOCALAPPDATA%/SkateGM/data/assets
if not defined SK8_MAP set SK8_MAP=maps	l_skatepark.bsp
set SK8_PAK=pak
set SK8_SPOTS_DIR=results
if not exist pak python extract_pak.py "%SK8_MAP%" pak
win\luajit.exe harness.lua %1 120 11 -2600 -700 420 %2
