#Requires -RunAsAdministrator
# stock-random 卸载 Windows 系统服务
$ErrorActionPreference = "Stop"

$ServiceName = "stock-random"
$Root = Split-Path -Parent $PSScriptRoot
$Nssm = Join-Path $Root "tools\nssm.exe"

& $Nssm status $ServiceName *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] 服务 $ServiceName 不存在"
    exit 0
}

Write-Host "[INFO] 停止并移除服务 $ServiceName ..."
& $Nssm stop $ServiceName
& $Nssm remove $ServiceName confirm
Write-Host "[OK] 服务已卸载"
