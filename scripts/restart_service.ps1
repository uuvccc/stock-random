#Requires -RunAsAdministrator
# stock-random 重启 Windows 系统服务
$ErrorActionPreference = "Stop"

$ServiceName = "stock-random"
$Root = Split-Path -Parent $PSScriptRoot
$Nssm = Join-Path $Root "tools\nssm.exe"

& $Nssm status $ServiceName *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] 服务 $ServiceName 不存在，请先运行 install_service.bat 安装"
    exit 1
}

Write-Host "[INFO] 重启服务 $ServiceName ..."
& $Nssm restart $ServiceName
Start-Sleep -Seconds 3
& $Nssm status $ServiceName
Write-Host "[OK] 服务已重启，访问 http://127.0.0.1:8080"
