﻿# stock-random 服务实时状态监控
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\status_service.ps1          # 每 3 秒刷新
#   powershell -ExecutionPolicy Bypass -File scripts\status_service.ps1 -Once    # 只看一次
#   powershell -ExecutionPolicy Bypass -File scripts\status_service.ps1 -Interval 5
param(
    [switch]$Once,
    [int]$Interval = 3,
    [int]$LogLines = 12
)

$ServiceName = "stock-random"
$Root = Split-Path -Parent $PSScriptRoot
$LogFile = Join-Path $Root "logs\service.log"
$Url = "http://127.0.0.1:8080/"

function Show-Status {
    Clear-Host
    Write-Host "=== stock-random 状态监控 ===  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host ""

    # 1. Windows 服务状态
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        $color = if ($svc.Status -eq "Running") { "Green" } else { "Red" }
        Write-Host ("[服务] {0,-10} 启动类型: {1}" -f $svc.Status, $svc.StartType) -ForegroundColor $color
    } else {
        Write-Host "[服务] 未安装（先运行 install_service.bat）" -ForegroundColor Yellow
    }

    # 2. 守护进程 / app 进程信息
    $procs = Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "run_service\.py|app\.py" }
    if ($procs) {
        foreach ($p in $procs) {
            $ws = [math]::Round($p.WorkingSetSize / 1MB, 1)
            $start = $p.CreationDate
            $up = (Get-Date) - $start
            $role = if ($p.CommandLine -match "run_service\.py") { "守护" } else { "app  " }
            Write-Host ("[进程] {0} pid={1,-7} 内存={2,7}MB  已运行={3:hh\:mm\:ss}" -f $role, $p.ProcessId, $ws, $up) -ForegroundColor Green
        }
    } else {
        Write-Host "[进程] 未发现守护/app 进程" -ForegroundColor Red
    }

    # 3. 端口监听
    $conn = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
        Write-Host "[端口] 8080 监听中 (pid=$($conn[0].OwningProcess))" -ForegroundColor Green
    } else {
        Write-Host "[端口] 8080 未监听" -ForegroundColor Red
    }

    # 4. HTTP 健康检查
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
        $sw.Stop()
        Write-Host "[HTTP] $($r.StatusCode) OK  $($sw.ElapsedMilliseconds)ms  ($Url)" -ForegroundColor Green
    } catch {
        Write-Host "[HTTP] 访问失败: $($_.Exception.Message)" -ForegroundColor Red
    }

    # 5. 最新日志
    Write-Host ""
    Write-Host "--- service.log 最后 $LogLines 行 ---" -ForegroundColor DarkCyan
    if (Test-Path $LogFile) {
        Get-Content $LogFile -Tail $LogLines -Encoding UTF8
    } else {
        Write-Host "(暂无日志文件)"
    }

    if (-not $Once) {
        Write-Host ""
        Write-Host "每 $Interval 秒刷新，Ctrl+C 退出" -ForegroundColor DarkGray
    }
}

do {
    Show-Status
    if ($Once) { break }
    Start-Sleep -Seconds $Interval
} while ($true)
