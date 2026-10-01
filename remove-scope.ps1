param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Scope,
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

# 归一化:确保 scope 以 @ 开头
if (-not $Scope.StartsWith("@")) {
    $Scope = "@" + $Scope
}

Write-Host "========================================"
Write-Host " Remove Verdaccio Packages by Scope"
Write-Host "========================================"
Write-Host "Scope: $Scope"
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

# 匹配 scope 下的所有包(-like 大小写不敏感)
$targets = @(
    $db.list | Where-Object {
        $_ -like "$Scope/*"
    }
)

Write-Host "Packages found: $($targets.Count)"
Write-Host ""

if ($targets.Count -eq 0) {
    Write-Host "No packages under scope $Scope."
    exit 0
}

foreach ($package in $targets) {
    Write-Host "  $package"
}

Write-Host ""
Write-Host "WARNING: This will DELETE the storage of ALL"
Write-Host "packages listed above and remove them from the DB."
Write-Host "The DB secret will be preserved."
Write-Host ""

# 创建 backup
if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$backupFile = Join-Path `
    $backupDir `
    ".verdaccio-db-before-remove-scope-$timestamp.json"

Copy-Item $dbFile $backupFile

Write-Host "DB backup created:"
Write-Host $backupFile
Write-Host ""

# 二次确认
$answer = Read-Host "Type DELETE to confirm"

if ($answer -ne "DELETE") {
    Write-Host "Cancelled."
    exit 0
}

# 删除 storage
foreach ($package in $targets) {

    $packagePath = Join-Path `
        $storage `
        ($package -replace "/", "\")

    if (Test-Path $packagePath) {
        Remove-Item `
            -LiteralPath $packagePath `
            -Recurse `
            -Force

        Write-Host "Deleted storage: $package"
    }
    else {
        Write-Host "Storage missing (DB-only): $package"
    }
}

# 从 DB 中移除
$kept = @(
    $db.list | Where-Object {
        $_ -notlike "$Scope/*"
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
Write-Host " Scope removed"
Write-Host "========================================"
Write-Host "Scope          : $Scope"
Write-Host "Packages removed: $($targets.Count)"
Write-Host "Packages kept   : $($kept.Count)"
Write-Host "DB updated."
Write-Host "Secret preserved: YES"
Write-Host "Backup: $backupFile"
