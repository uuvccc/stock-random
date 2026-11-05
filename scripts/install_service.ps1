#Requires -RunAsAdministrator
# stock-random: install as Windows service via NSSM
# Usage (admin PowerShell):
#   powershell -ExecutionPolicy Bypass -File scripts\install_service.ps1
$ErrorActionPreference = "Stop"

$ServiceName = "stock-random"
$Root = Split-Path -Parent $PSScriptRoot
$Nssm = Join-Path $Root "tools\nssm.exe"
$VenvPy = Join-Path $Root ".venv\Scripts\python.exe"
$LogDir = Join-Path $Root "logs"
$GitPullInterval = 300   # git pull interval in seconds, 0 = disabled
$WatchEnabled = 1        # hot reload on file change, 0 = disabled

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
Start-Transcript -Path (Join-Path $LogDir "install.log") -Force | Out-Null

function Update-SessionPath {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

function Install-WithWinget([string]$Id, [string]$Name) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "Missing $Name and winget is not available. Please install $Name manually."
    }
    Write-Host "[INFO] Installing $Name via winget ..."
    winget install -e --id $Id --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -ne 0) { throw "$Name install failed (winget exit=$LASTEXITCODE)" }
    Update-SessionPath
}

# 0. Auto-install missing prerequisites: Python / Git / NSSM
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "[INFO] Python not found, installing ..."
    Install-WithWinget "Python.Python.3.12" "Python"
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        throw "Python still not available after install. Open a new terminal and retry."
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "[INFO] Git not found (needed for scheduled git pull), installing ..."
    Install-WithWinget "Git.Git" "Git"
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Host "[WARN] Git still not available; scheduled git pull will not work."
    }
}

if (-not (Test-Path $Nssm)) {
    Write-Host "[INFO] NSSM not found, downloading to tools\ ..."
    New-Item -ItemType Directory -Force -Path (Join-Path $Root "tools") | Out-Null
    $zip = Join-Path $Root "tools\nssm.zip"
    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath (Join-Path $Root "tools\nssm-tmp") -Force
    Copy-Item (Join-Path $Root "tools\nssm-tmp\nssm-2.24\win64\nssm.exe") $Nssm
    Remove-Item -Recurse -Force (Join-Path $Root "tools\nssm-tmp"), $zip
}

# 1. Prepare venv and install Python deps (idempotent)
if (-not (Test-Path $VenvPy)) {
    Write-Host "[INFO] Creating virtualenv .venv ..."
    python -m venv (Join-Path $Root ".venv")
}
Write-Host "[INFO] Installing/updating deps (already-satisfied ones are skipped) ..."
& $VenvPy -m pip install --quiet --upgrade pip
& $VenvPy -m pip install --quiet -r (Join-Path $Root "requirements.txt")
if ($LASTEXITCODE -ne 0) { throw "pip install failed" }

# 2. Remove existing service instance first
# NOTE: use Get-Service instead of "nssm status" -- with EAP=Stop, redirecting
# native-command stderr turns "Can't open service!" into a terminating error.
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Write-Host "[INFO] Service already exists, removing old instance ..."
    & $Nssm stop $ServiceName | Out-Null
    & $Nssm remove $ServiceName confirm | Out-Null
}

# 3. Register service
Write-Host "[INFO] Registering service $ServiceName ..."
& $Nssm install $ServiceName $VenvPy "run_service.py"
& $Nssm set $ServiceName AppDirectory $Root
& $Nssm set $ServiceName DisplayName "stock-random (Flask A-share random quotes)"
& $Nssm set $ServiceName Description "Random A-share quote service. Supervisor auto-restarts app, runs scheduled git pull, and hot-reloads on file changes."
& $Nssm set $ServiceName Start SERVICE_AUTO_START

# Auto restart on crash (NSSM layer; supervisor has its own restart too)
& $Nssm set $ServiceName AppExit Default Restart
& $Nssm set $ServiceName AppRestartDelay 3000
& $Nssm set $ServiceName AppStopMethodSkip 6

# Logs with rotation
& $Nssm set $ServiceName AppStdout (Join-Path $LogDir "service.log")
& $Nssm set $ServiceName AppStderr (Join-Path $LogDir "service.log")
& $Nssm set $ServiceName AppRotateFiles 1
& $Nssm set $ServiceName AppRotateOnline 1
& $Nssm set $ServiceName AppRotateBytes 10485760

# Supervisor env
& $Nssm set $ServiceName AppEnvironmentExtra "GIT_PULL_INTERVAL=$GitPullInterval" "WATCH_ENABLED=$WatchEnabled" "PYTHONIOENCODING=utf-8"

# 4. Start
& $Nssm start $ServiceName
Start-Sleep -Seconds 3
& $Nssm status $ServiceName

Write-Host ""
Write-Host "[OK] Service installed and started"
Write-Host "     URL:  http://127.0.0.1:8080"
Write-Host "     Logs: $LogDir\service.log"
Write-Host "     Mgmt: nssm start/stop/restart $ServiceName   or   services.msc"
Stop-Transcript | Out-Null
