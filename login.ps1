$registry = "http://localhost:4873"

Write-Host "========================================"
Write-Host " Verdaccio npm Login"
Write-Host "========================================"
Write-Host ""
Write-Host "Registry:"
Write-Host "  $registry"
Write-Host ""

# 检查 Verdaccio 是否运行
$connections = Get-NetTCPConnection `
    -LocalPort 4873 `
    -State Listen `
    -ErrorAction SilentlyContinue

if ($null -eq $connections) {
    Write-Host "ERROR: Verdaccio is not running."
    Write-Host ""
    Write-Host "Please start Verdaccio first:"
    Write-Host "  ..\bat\run-start-background.bat"
    Write-Host ""
    exit 1
}

Write-Host "Verdaccio is running."
Write-Host ""

# 测试 Registry
try {
    $response = Invoke-WebRequest `
        -Uri "$registry/-/ping" `
        -UseBasicParsing `
        -TimeoutSec 3

    if ($response.StatusCode -ne 200) {
        Write-Host "ERROR: Verdaccio ping failed."
        exit 1
    }
}
catch {
    Write-Host "ERROR: Cannot connect to Verdaccio."
    Write-Host $_.Exception.Message
    exit 1
}

Write-Host "Registry is reachable."
Write-Host ""

Write-Host "Starting npm login..."
Write-Host ""
Write-Host "After successful login, npm will update your .npmrc"
Write-Host "with a new authentication token."
Write-Host ""

npm login `
    --registry $registry `
    --auth-type=legacy

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "========================================"
    Write-Host " npm login FAILED"
    Write-Host "========================================"
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "========================================"
Write-Host " npm login completed"
Write-Host "========================================"
Write-Host ""
Write-Host "A new Verdaccio authentication token"
Write-Host "should now be stored in your .npmrc."
Write-Host ""
Write-Host "You can test it with:"
Write-Host ""
Write-Host "  npm --registry $registry whoami"
Write-Host ""