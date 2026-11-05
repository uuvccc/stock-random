# stock-random: live service status monitor
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\status_service.ps1          # refresh every 3s
#   powershell -ExecutionPolicy Bypass -File scripts\status_service.ps1 -Once    # single snapshot
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
    Write-Host "=== stock-random status monitor ===  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    Write-Host ""

    # 1. Windows service status
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        $color = if ($svc.Status -eq "Running") { "Green" } else { "Red" }
        Write-Host ("[Service] {0,-10} StartType: {1}" -f $svc.Status, $svc.StartType) -ForegroundColor $color
    } else {
        Write-Host "[Service] not installed (run install_service.bat first)" -ForegroundColor Yellow
    }

    # 2. Supervisor / app process info
    $procs = Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "run_service\.py|app\.py" }
    if ($procs) {
        foreach ($p in $procs) {
            $ws = [math]::Round($p.WorkingSetSize / 1MB, 1)
            $start = $p.CreationDate
            $up = (Get-Date) - $start
            $role = if ($p.CommandLine -match "run_service\.py") { "supervisor" } else { "app       " }
            Write-Host ("[Process] {0} pid={1,-7} mem={2,7}MB  up={3:hh\:mm\:ss}" -f $role, $p.ProcessId, $ws, $up) -ForegroundColor Green
        }
    } else {
        Write-Host "[Process] no supervisor/app process found" -ForegroundColor Red
    }

    # 3. Port listening
    $conn = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
        Write-Host "[Port] 8080 listening (pid=$($conn[0].OwningProcess))" -ForegroundColor Green
    } else {
        Write-Host "[Port] 8080 not listening" -ForegroundColor Red
    }

    # 4. HTTP health check
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
        $sw.Stop()
        Write-Host "[HTTP] $($r.StatusCode) OK  $($sw.ElapsedMilliseconds)ms  ($Url)" -ForegroundColor Green
    } catch {
        Write-Host "[HTTP] request failed: $($_.Exception.Message)" -ForegroundColor Red
    }

    # 5. Latest logs
    Write-Host ""
    Write-Host "--- last $LogLines lines of service.log ---" -ForegroundColor DarkCyan
    if (Test-Path $LogFile) {
        Get-Content $LogFile -Tail $LogLines -Encoding UTF8
    } else {
        Write-Host "(no log file yet)"
    }

    if (-not $Once) {
        Write-Host ""
        Write-Host "Refreshing every $Interval s, Ctrl+C to quit" -ForegroundColor DarkGray
    }
}

do {
    Show-Status
    if ($Once) { break }
    Start-Sleep -Seconds $Interval
} while ($true)
