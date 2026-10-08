@echo off
setlocal
title Skate 3 Clone - Latest Main

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\launch_university_map_visual_test.ps1" %*
set "RESULT=%ERRORLEVEL%"

if not "%RESULT%"=="0" (
    echo.
    echo Skate 3 Clone launch failed with exit code %RESULT%.
    pause
)
exit /b %RESULT%
