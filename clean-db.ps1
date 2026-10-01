. "$PSScriptRoot\resolve-paths.ps1"

$config  = Resolve-VerdaccioConfig
$storage = Resolve-VerdaccioStorage $config
$dbFile  = Join-Path $storage ".verdaccio-db.json"

Write-Host "Config:  $config"
Write-Host "Storage: $storage"
$dbFile = Join-Path $storage ".verdaccio-db.json"

# 备份统一放在脚本同级的 db-backups\(与其他脚本一致)
$backupDir = Join-Path $PSScriptRoot "db-backups"

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

# DB 解析失败(损坏/空文件)时必须立即退出,
# 否则 $db 为 null,后面会把 DB 写成 0 字节,secret 丢失 → 所有 token 失效
try {
    $db = Get-Content $dbFile -Raw | ConvertFrom-Json
}
catch {
    Write-Host "ERROR: DB file is corrupted / not valid JSON:"
    Write-Host $dbFile
    Write-Host "Nothing was deleted. Restore it from db-backups first."
    exit 1
}

if ($null -eq $db -or [string]::IsNullOrWhiteSpace("$($db.secret)")) {
    Write-Host "ERROR: DB is empty or the secret is missing."
    Write-Host "Nothing was deleted."
    exit 1
}

$originalCount = @($db.list).Count

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

$json = $db | ConvertTo-Json -Compress -Depth 100

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
Write-Host "Secret preserved: YES"

Write-Host ""
Write-Host "Backup:"
Write-Host $backupFile