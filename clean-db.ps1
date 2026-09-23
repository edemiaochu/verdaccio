$storage = "C:\Users\lenovo\.config\verdaccio\storage"
$dbFile = Join-Path $storage ".verdaccio-db.json"

$backupDir = "D:\verdaccio\db-backups"

Write-Host "========================================"
Write-Host " Verdaccio DB Cleanup"
Write-Host "========================================"

# ----------------------------------------
# 1. 检查 DB
# ----------------------------------------

if (-not (Test-Path $dbFile)) {
    Write-Host "ERROR: DB file not found:"
    Write-Host $dbFile
    exit 1
}

# ----------------------------------------
# 2. 检查 Verdaccio 是否仍在运行
# ----------------------------------------

$connections = Get-NetTCPConnection `
    -LocalPort 4873 `
    -State Listen `
    -ErrorAction SilentlyContinue

if ($null -ne $connections) {

    Write-Host ""
    Write-Host "ERROR: Verdaccio is still running."
    Write-Host "Please stop Verdaccio first."
    Write-Host ""
    Write-Host "Use:"
    Write-Host "    .\stop.ps1"

    exit 1
}

# ----------------------------------------
# 3. 创建 backup
# ----------------------------------------

if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$backupFile = Join-Path `
    $backupDir `
    ".verdaccio-db-before-clean-$timestamp.json"

Copy-Item $dbFile $backupFile

Write-Host ""
Write-Host "Backup created:"
Write-Host $backupFile

# ----------------------------------------
# 4. 读取 DB
# ----------------------------------------

$db = Get-Content $dbFile -Raw | ConvertFrom-Json

$originalCount = $db.list.Count

# ----------------------------------------
# 5. 保留 secret
# ----------------------------------------

$secret = $db.secret

# ----------------------------------------
# 6. 检查 package
# ----------------------------------------

$removed = @()
$kept = @()

foreach ($package in $db.list) {

    $packagePath = Join-Path `
        $storage `
        ($package -replace "/", "\")

    $packageJson = Join-Path `
        $packagePath `
        "package.json"

    if (Test-Path $packageJson) {

        $kept += $package

    }
    else {

        $removed += $package
    }
}

# ----------------------------------------
# 7. 显示清理结果
# ----------------------------------------

Write-Host ""
Write-Host "Original packages : $originalCount"
Write-Host "Keep packages     : $($kept.Count)"
Write-Host "Remove packages   : $($removed.Count)"

Write-Host ""
Write-Host "========== REMOVE =========="

foreach ($package in $removed) {
    Write-Host $package
}

# ----------------------------------------
# 8. 修改 DB
# ----------------------------------------

$db.list = @($kept)

# 确保 secret 原样保存
$db.secret = $secret

# ----------------------------------------
# 9. 写回
# ----------------------------------------

$json = $db | ConvertTo-Json -Compress

[System.IO.File]::WriteAllText(
    $dbFile,
    $json,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host ""
Write-Host "========================================"
Write-Host " Cleanup completed."
Write-Host "========================================"

Write-Host ""
Write-Host "DB:"
Write-Host $dbFile

Write-Host ""
Write-Host "Secret preserved:"
Write-Host $db.secret

Write-Host ""
Write-Host "Backup:"
Write-Host $backupFile