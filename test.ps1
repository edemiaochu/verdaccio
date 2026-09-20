Write-Host "Testing Verdaccio..."
Write-Host ""

npm --registry http://localhost:4873 ping

Write-Host ""
Write-Host "Testing @szewec/bis-core-schema..."

npm --registry http://localhost:4873 view @szewec/bis-core-schema

Write-Host ""
Write-Host "Testing @szewtwin/core-backend..."

npm --registry http://localhost:4873 view @szewtwin/core-backend