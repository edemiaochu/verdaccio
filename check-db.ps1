$storage = "C:\Users\lenovo\.config\verdaccio\storage"
$dbFile = Join-Path $storage ".verdaccio-db.json"

if (-not (Test-Path $dbFile)) {
    Write-Host "ERROR: DB not found:"
    Write-Host $dbFile
    exit 1
}

$db = Get-Content $dbFile -Raw | ConvertFrom-Json

$missing = @()
$existing = @()

foreach ($package in $db.list) {

    $packagePath = Join-Path `
        $storage `
        ($package -replace "/", "\")

    $packageJson = Join-Path `
        $packagePath `
        "package.json"

    if (Test-Path $packageJson) {
        $existing += $package
    }
    else {
        $missing += $package
    }
}

Write-Host "========================================"
Write-Host " Verdaccio DB Check"
Write-Host "========================================"

Write-Host ""
Write-Host "Total packages : $($db.list.Count)"
Write-Host "Existing       : $($existing.Count)"
Write-Host "Missing        : $($missing.Count)"

Write-Host ""
Write-Host "========== MISSING PACKAGES =========="

$missing | ForEach-Object {
    Write-Host "REMOVE: $_"
}

Write-Host ""
Write-Host "========================================"