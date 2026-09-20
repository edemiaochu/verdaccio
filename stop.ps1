Write-Host "========================================"
Write-Host " Stopping Verdaccio"
Write-Host "========================================"

$connections = Get-NetTCPConnection `
    -LocalPort 4873 `
    -State Listen `
    -ErrorAction SilentlyContinue

if ($null -eq $connections) {
    Write-Host "Verdaccio is not running on port 4873."
    exit 0
}

foreach ($connection in $connections) {

    $pid = $connection.OwningProcess

    Write-Host "Found process:"
    Write-Host "PID: $pid"

    $process = Get-Process -Id $pid -ErrorAction SilentlyContinue

    if ($null -ne $process) {
        Write-Host "Process: $($process.ProcessName)"
        Write-Host "Stopping..."

        Stop-Process -Id $pid -Force

        Write-Host "Stopped."
    }
}

Write-Host ""
Write-Host "Verdaccio stopped."