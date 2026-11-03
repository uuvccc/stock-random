@echo off
chcp 65001 >nul
REM ============================================================
REM  stock-random 一键重启系统服务
REM  双击运行即可，会自动请求管理员权限
REM ============================================================
cd /d "%~dp0"

net session >nul 2>nul
if not errorlevel 1 goto :restart

echo [INFO] 请求管理员权限...
powershell -Command "Start-Process '%~f0' -Verb RunAs"
exit /b

:restart
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\restart_service.ps1"
echo.
pause
