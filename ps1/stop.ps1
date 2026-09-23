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

    # 注意:不能用 $pid,它是 PowerShell 只读自动变量(当前进程 PID)
    $procId = $connection.OwningProcess

    Write-Host "Found process:"
    Write-Host "PID: $procId"

    $process = Get-Process -Id $procId -ErrorAction SilentlyContinue

    if ($null -ne $process) {
        Write-Host "Process: $($process.ProcessName)"
        Write-Host "Stopping..."

        Stop-Process -Id $procId -Force

        Write-Host "Stopped."
    }
    else {
        Write-Host "Process not found (may have already stopped)."
    }
}

Write-Host ""
Write-Host "Verdaccio stopped."