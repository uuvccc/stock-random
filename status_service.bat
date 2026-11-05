@echo off
REM ============================================================
REM  stock-random - live service status monitor (refresh every 3s)
REM  No admin rights needed. Ctrl+C to quit.
REM ============================================================
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\status_service.ps1" %*
