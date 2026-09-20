$config = "C:\Users\lenovo\.config\verdaccio\config.yaml"

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