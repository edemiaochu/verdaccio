Write-Host "========================================"
Write-Host " Verdaccio Status"
Write-Host "========================================"

$processes = Get-Process node -ErrorAction SilentlyContinue

if ($null -eq $processes) {
    Write-Host "No Node.js process found."
}
else {
    Write-Host "Node.js processes:"
    $processes | Select-Object Id, ProcessName, StartTime
}

Write-Host ""
Write-Host "Checking http://localhost:4873 ..."

try {
    $response = Invoke-WebRequest `
        -Uri "http://localhost:4873/-/ping" `
        -UseBasicParsing `
        -TimeoutSec 3

    Write-Host "Verdaccio is ONLINE"
    Write-Host "HTTP Status: $($response.StatusCode)"
}
catch {
    Write-Host "Verdaccio is OFFLINE"
}