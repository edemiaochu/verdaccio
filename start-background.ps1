param(
    [string]$Config = ""
)

. "$PSScriptRoot\resolve-paths.ps1"

# 未显式指定时,跟随工具箱启动记录 / 运行中的 Verdaccio / 默认配置
$config = Resolve-VerdaccioConfig $Config
$logDir = "D:\verdaccio\logs"

if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$stdout = "$logDir\verdaccio-$timestamp.log"
$stderr = "$logDir\verdaccio-$timestamp-error.log"

Write-Host "Starting Verdaccio in background..."
Write-Host "Config: $config"
Write-Host "Log:    $stdout"

Start-Process `
    -FilePath "verdaccio.cmd" `
    -ArgumentList "-c `"$config`"" `
    -RedirectStandardOutput $stdout `
    -RedirectStandardError $stderr `
    -WindowStyle Hidden

Write-Host ""
Write-Host "Verdaccio started."