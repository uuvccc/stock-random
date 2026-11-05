@echo off
REM ============================================================
REM  stock-random - one-click restart Windows service
REM  Double-click to run; admin rights are requested via UAC
REM ============================================================
cd /d "%~dp0"

net session >nul 2>nul
if not errorlevel 1 goto :restart

echo [INFO] Requesting administrator privileges...
powershell -Command "Start-Process '%~f0' -Verb RunAs"
exit /b

:restart
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\restart_service.ps1"
echo.
pause
