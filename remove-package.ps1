param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$PackageName,
    [string]$Config = ""
)

. "$PSScriptRoot\resolve-paths.ps1"

$config  = Resolve-VerdaccioConfig $Config
$storage = Resolve-VerdaccioStorage $config
$dbFile  = Join-Path $storage ".verdaccio-db.json"

Write-Host "Config:  $config"
Write-Host "Storage: $storage"
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

# 写回 DB(-Depth 必须 ≥ 3,默认 2 会把嵌套对象写成类型名字符串)
$json = $db | ConvertTo-Json -Compress -Depth 100

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