@echo off
cd /d "%~dp0"
set "SCRIPT=%~dp0Tools\Launcher\Scripts\Launcher.ps1"

where pwsh >nul 2>&1 && (
    pwsh -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%SCRIPT%"
) || (
    powershell -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "%SCRIPT%"
)
