#Requires -RunAsAdministrator
# stock-random 安装为 Windows 系统服务（NSSM）
# 用法：右键 PowerShell 运行，或在管理员 PowerShell 中执行：
#   powershell -ExecutionPolicy Bypass -File scripts\install_service.ps1
$ErrorActionPreference = "Stop"

$ServiceName = "stock-random"
$Root = Split-Path -Parent $PSScriptRoot
$Nssm = Join-Path $Root "tools\nssm.exe"
$VenvPy = Join-Path $Root ".venv\Scripts\python.exe"
$LogDir = Join-Path $Root "logs"
$GitPullInterval = 300   # git pull 间隔（秒），0 关闭
$WatchEnabled = 1        # 文件变化热加载，0 关闭

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path (Join-Path $LogDir "install.log") -Force | Out-Null

function Update-SessionPath {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

function Install-WithWinget([string]$Id, [string]$Name) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "缺少 $Name，且系统无 winget，请手动安装后重试"
    }
    Write-Host "[INFO] 使用 winget 安装 $Name ..."
    winget install -e --id $Id --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -ne 0) { throw "$Name 安装失败 (winget exit=$LASTEXITCODE)" }
    Update-SessionPath
}

# 0. 自动补齐缺失依赖：Python / Git / NSSM
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "[INFO] 未检测到 Python，自动安装..."
    Install-WithWinget "Python.Python.3.12" "Python"
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        throw "Python 安装后仍不可用，请重开终端后重试"
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "[INFO] 未检测到 Git（定时 git pull 需要），自动安装..."
    Install-WithWinget "Git.Git" "Git"
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "[WARN] Git 安装后仍不可用，定时 git pull 将不生效"
    }
}

if (-not (Test-Path $Nssm)) {
    Write-Host "[INFO] 未检测到 NSSM，自动下载到 tools\ ..."
    New-Item -ItemType Directory -Force -Path (Join-Path $Root "tools") | Out-Null
    $zip = Join-Path $Root "tools\nssm.zip"
    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath (Join-Path $Root "tools\nssm-tmp") -Force
    Copy-Item (Join-Path $Root "tools\nssm-tmp\nssm-2.24\win64\nssm.exe") $Nssm
    Remove-Item -Recurse -Force (Join-Path $Root "tools\nssm-tmp"), $zip
}

# 1. 准备虚拟环境并幂等安装 Python 依赖
if (-not (Test-Path $VenvPy)) {
    Write-Host "[INFO] 创建虚拟环境 .venv ..."
    python -m venv (Join-Path $Root ".venv")
}
Write-Host "[INFO] 安装/更新依赖（已满足的会跳过）..."
& $VenvPy -m pip install --quiet --upgrade pip
& $VenvPy -m pip install --quiet -r (Join-Path $Root "requirements.txt")
if ($LASTEXITCODE -ne 0) { throw "依赖安装失败" }

# 2. 若服务已存在先卸载
& $Nssm status $ServiceName *> $null
if ($LASTEXITCODE -eq 0) {
    Write-Host "[INFO] 服务已存在，先移除旧实例..."
    & $Nssm stop $ServiceName *> $null
    & $Nssm remove $ServiceName confirm *> $null
}

# 3. 注册服务
Write-Host "[INFO] 注册服务 $ServiceName ..."
& $Nssm install $ServiceName $VenvPy "run_service.py"
& $Nssm set $ServiceName AppDirectory $Root
& $Nssm set $ServiceName DisplayName "stock-random (Flask A股随机行情)"
& $Nssm set $ServiceName Description "随机A股行情服务。守护进程自动重启、定时git pull、文件变化热加载。"
& $Nssm set $ServiceName Start SERVICE_AUTO_START

# 崩溃自动重启（NSSM 层，守护脚本内还有一层）
& $Nssm set $ServiceName AppExit Default Restart
& $Nssm set $ServiceName AppRestartDelay 3000
& $Nssm set $ServiceName AppStopMethodSkip 6

# 日志（带轮转）
& $Nssm set $ServiceName AppStdout (Join-Path $LogDir "service.log")
& $Nssm set $ServiceName AppStderr (Join-Path $LogDir "service.log")
& $Nssm set $ServiceName AppRotateFiles 1
& $Nssm set $ServiceName AppRotateOnline 1
& $Nssm set $ServiceName AppRotateBytes 10485760

# 守护进程参数
& $Nssm set $ServiceName AppEnvironmentExtra "GIT_PULL_INTERVAL=$GitPullInterval" "WATCH_ENABLED=$WatchEnabled" "PYTHONIOENCODING=utf-8"

# 4. 启动
& $Nssm start $ServiceName
Start-Sleep -Seconds 3
& $Nssm status $ServiceName

Write-Host ""
Write-Host "[OK] 服务已安装并启动"
Write-Host "     访问: http://127.0.0.1:8080"
Write-Host "     日志: $LogDir\service.log"
Write-Host "     管理: nssm start/stop/restart $ServiceName   或   services.msc"
Stop-Transcript | Out-Null
