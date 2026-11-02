@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

REM ============================================================
REM  stock-random 一键启动
REM  1. 检查 Python
REM  2. 创建/复用虚拟环境 .venv
REM  3. 安装依赖 requirements.txt
REM  4. 启动 app.py
REM ============================================================

where python >nul 2>nul
if errorlevel 1 (
    echo [ERROR] 未检测到 Python，请先安装 Python 3.10+ 并加入 PATH
    echo         https://www.python.org/downloads/
    pause
    exit /b 1
)

if not exist .venv (
    echo [INFO] 首次运行，创建虚拟环境 .venv ...
    python -m venv .venv
    if errorlevel 1 (
        echo [ERROR] 虚拟环境创建失败
        pause
        exit /b 1
    )
)

call .venv\Scripts\activate.bat

echo [INFO] 检查依赖...
python -m pip show flask akshare pandas >nul 2>nul
if errorlevel 1 (
    echo [INFO] 安装依赖中，请稍候...
    python -m pip install --upgrade pip
    python -m pip install -r requirements.txt
    if errorlevel 1 (
        echo [ERROR] 依赖安装失败，请检查网络或 pip 源
        pause
        exit /b 1
    )
) else (
    echo [INFO] 依赖已就绪
)

echo.
echo [INFO] 启动 Flask 服务，访问 http://127.0.0.1:8080
echo        按 Ctrl+C 停止
echo.
python app.py

pause
