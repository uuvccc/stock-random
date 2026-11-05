@echo off
chcp 65001 >nul
REM ============================================================
REM  stock-random 服务实时状态监控（每 3 秒刷新，Ctrl+C 退出）
REM  查看状态不需要管理员权限
REM ============================================================
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\status_service.ps1" %*
