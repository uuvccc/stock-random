#Requires -RunAsAdministrator
# stock-random: uninstall Windows service
$ErrorActionPreference = "Stop"

$ServiceName = "stock-random"
$Root = Split-Path -Parent $PSScriptRoot
$Nssm = Join-Path $Root "tools\nssm.exe"

& $Nssm status $ServiceName *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Service $ServiceName does not exist"
    exit 0
}

Write-Host "[INFO] Stopping and removing service $ServiceName ..."
& $Nssm stop $ServiceName
& $Nssm remove $ServiceName confirm
Write-Host "[OK] Service uninstalled"
