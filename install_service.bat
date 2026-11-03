@echo off
chcp 65001 >nul
REM ============================================================
REM  stock-random 一键安装为系统服务
REM  双击运行即可，会自动请求管理员权限
REM ============================================================
cd /d "%~dp0"

REM 检查是否已是管理员，不是则通过 UAC 提权重启自身
net session >nul 2>nul
if not errorlevel 1 goto :install

echo [INFO] 请求管理员权限...
powershell -Command "Start-Process '%~f0' -Verb RunAs"
exit /b

:install
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\install_service.ps1"
echo.
pause
