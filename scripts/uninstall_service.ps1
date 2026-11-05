#Requires -RunAsAdministrator
# stock-random: uninstall Windows service
$ErrorActionPreference = "Stop"

$ServiceName = "stock-random"
$Root = Split-Path -Parent $PSScriptRoot
$Nssm = Join-Path $Root "tools\nssm.exe"

# NOTE: use Get-Service instead of "nssm status" -- with EAP=Stop, redirecting
# native-command stderr turns "Can't open service!" into a terminating error.
if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
    Write-Host "[INFO] Service $ServiceName does not exist"
    exit 0
}

Write-Host "[INFO] Stopping and removing service $ServiceName ..."
& $Nssm stop $ServiceName | Out-Null
& $Nssm remove $ServiceName confirm | Out-Null
Write-Host "[OK] Service uninstalled"
