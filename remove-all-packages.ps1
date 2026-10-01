. "$PSScriptRoot\resolve-paths.ps1"

$config  = Resolve-VerdaccioConfig
$storage = Resolve-VerdaccioStorage $config
$dbFile  = Join-Path $storage ".verdaccio-db.json"

Write-Host "Config:  $config"
Write-Host "Storage: $storage"
$dbFile = Join-Path $storage ".verdaccio-db.json"
$backupDir = Join-Path $PSScriptRoot "db-backups"

Write-Host "========================================"
Write-Host " REMOVE ALL VERDACCIO PACKAGES"
Write-Host "========================================"
Write-Host ""

if (-not (Test-Path $dbFile)) {
    Write-Host "ERROR: DB file not found:"
    Write-Host $dbFile
    exit 1
}

# Verdaccio 必须停止
$connections = Get-NetTCPConnection `
    -LocalPort 4873 `
    -State Listen `
    -ErrorAction SilentlyContinue

if ($null -ne $connections) {
    Write-Host "ERROR: Verdaccio is still running."
    Write-Host "Please run .\stop.ps1 first."
    exit 1
}

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

# 保存 secret
$secret = $db.secret

$originalPackages = @($db.list)

# storage 下的 package namespace
$packageDirs = Get-ChildItem `
    -LiteralPath $storage `
    -Directory `
    -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -ne ".git"
    }

Write-Host "Storage:"
Write-Host "  $storage"
Write-Host ""

Write-Host "Packages in DB    : $($originalPackages.Count)"
Write-Host "Storage folders   : $($packageDirs.Count)"
Write-Host ""

Write-Host "WARNING:"
Write-Host "This will DELETE ALL Verdaccio package storage."
Write-Host "The DB file itself will NOT be deleted."
Write-Host "The DB package list will be cleared."
Write-Host "The Verdaccio secret will be preserved."
Write-Host ""

# 强制确认
$answer = Read-Host 'Type "DELETE ALL" to confirm'

if ($answer -ne "DELETE ALL") {
    Write-Host "Cancelled."
    exit 0
}

# backup
if (-not (Test-Path $backupDir)) {
    New-Item `
        -ItemType Directory `
        -Path $backupDir |
        Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$backupFile = Join-Path `
    $backupDir `
    ".verdaccio-db-before-remove-all-$timestamp.json"

Copy-Item $dbFile $backupFile

Write-Host ""
Write-Host "DB backup created:"
Write-Host $backupFile
Write-Host ""

# 删除 package storage
foreach ($dir in $packageDirs) {

    Write-Host "Deleting:"
    Write-Host "  $($dir.FullName)"

    Remove-Item `
        -LiteralPath $dir.FullName `
        -Recurse `
        -Force
}

# 清空 DB package list
$db.list = @()

# 保留 secret
$db.secret = $secret

$json = $db | ConvertTo-Json -Compress -Depth 100

[System.IO.File]::WriteAllText(
    $dbFile,
    $json,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host ""
Write-Host "========================================"
Write-Host " All packages removed"
Write-Host "========================================"
Write-Host ""
Write-Host "DB: $dbFile"
Write-Host "Backup: $backupFile"
Write-Host ""
Write-Host "Package list cleared : YES"
Write-Host "Secret preserved     : YES"