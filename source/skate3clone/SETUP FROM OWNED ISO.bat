@echo off
setlocal
title Skate 3 Clone - Setup From Owned ISO

if "%~1"=="" (
    echo Drag your legally owned Skate 3 Xbox 360 ISO onto this file,
    echo or run:
    echo   "SETUP FROM OWNED ISO.bat" "D:\path\Skate 3.iso"
    echo.
    pause
    exit /b 2
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\setup_from_owned_iso.ps1" -Iso "%~1"
set "code=%ERRORLEVEL%"
if not "%code%"=="0" (
    echo.
    echo Setup failed with exit code %code%.
    pause
)
exit /b %code%
