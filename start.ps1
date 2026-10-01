param(
    [string]$Config = ""
)

. "$PSScriptRoot\resolve-paths.ps1"

# 未显式指定时,跟随工具箱启动记录 / 运行中的 Verdaccio / 默认配置
$config = Resolve-VerdaccioConfig $Config

Write-Host "========================================"
Write-Host " Starting Verdaccio"
Write-Host "========================================"
Write-Host "Config:"
Write-Host $config
Write-Host ""

if (-not (Test-Path $config)) {
    Write-Host "ERROR: config.yaml not found!"
    exit 1
}

Write-Host "Starting..."
Write-Host ""

verdaccio -c $config