#Requires -RunAsAdministrator
# stock-random: restart Windows service
$ErrorActionPreference = "Stop"

$ServiceName = "stock-random"
$Root = Split-Path -Parent $PSScriptRoot
$Nssm = Join-Path $Root "tools\nssm.exe"

# NOTE: use Get-Service instead of "nssm status" -- with EAP=Stop, redirecting
# native-command stderr turns "Can't open service!" into a terminating error.
if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Service $ServiceName does not exist. Run install_service.bat first."
    exit 1
}

Write-Host "[INFO] Restarting service $ServiceName ..."
& $Nssm restart $ServiceName
Start-Sleep -Seconds 3
& $Nssm status $ServiceName
Write-Host "[OK] Service restarted, visit http://127.0.0.1:8080"
