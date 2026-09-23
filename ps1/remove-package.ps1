param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$PackageName
)

$storage = "C:\Users\lenovo\.config\verdaccio\storage"
$dbFile = Join-Path $storage ".verdaccio-db.json"
$backupDir = Join-Path $PSScriptRoot "db-backups"

Write-Host "========================================"
Write-Host " Remove Verdaccio Package"
Write-Host "========================================"
Write-Host "Package: $PackageName"
Write-Host ""

if (-not (Test-Path $dbFile)) {
    Write-Host "ERROR: DB file not found:"
    Write-Host $dbFile
    exit 1
}

# Verdaccio 必须先停止
$connections = Get-NetTCPConnection `
    -LocalPort 4873 `
    -State Listen `
    -ErrorAction SilentlyContinue

if ($null -ne $connections) {
    Write-Host "ERROR: Verdaccio is still running."
    Write-Host "Please run .\stop.ps1 first."
    exit 1
}

$db = Get-Content $dbFile -Raw | ConvertFrom-Json

# 保存 secret
$secret = $db.secret

# package name -> storage path
$packagePath = Join-Path `
    $storage `
    ($PackageName -replace "/", "\")

$existsInDb = @($db.list) -contains $PackageName
$existsOnDisk = Test-Path $packagePath

Write-Host "In DB   : $existsInDb"
Write-Host "On disk : $existsOnDisk"
Write-Host "Path    : $packagePath"
Write-Host ""

if (-not $existsInDb -and -not $existsOnDisk) {
    Write-Host "Package does not exist in DB or storage."
    exit 0
}

# 创建 backup
if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$backupFile = Join-Path `
    $backupDir `
    ".verdaccio-db-before-remove-$timestamp.json"

Copy-Item $dbFile $backupFile

Write-Host "DB backup:"
Write-Host $backupFile
Write-Host ""

# 二次确认
$answer = Read-Host "Type DELETE to confirm"

if ($answer -ne "DELETE") {
    Write-Host "Cancelled."
    exit 0
}

# 删除 storage
if (Test-Path $packagePath) {
    Remove-Item `
        -LiteralPath $packagePath `
        -Recurse `
        -Force

    Write-Host "Storage directory deleted."
}

# 删除 DB 中的 package
$kept = @(
    $db.list | Where-Object {
        $_ -ne $PackageName
    }
)

$db.list = $kept

# 明确保留 secret
$db.secret = $secret

# 写回 DB
$json = $db | ConvertTo-Json -Compress

[System.IO.File]::WriteAllText(
    $dbFile,
    $json,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host ""
Write-Host "========================================"
Write-Host " Package removed"
Write-Host "========================================"
Write-Host "Package: $PackageName"
Write-Host "DB updated."
Write-Host "Secret preserved: YES"
Write-Host "Backup: $backupFile"