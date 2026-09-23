param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Scope
)

$storage = "C:\Users\lenovo\.config\verdaccio\storage"
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

$db = Get-Content $dbFile -Raw | ConvertFrom-Json

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

# 写回 DB
$json = $db | ConvertTo-Json -Compress

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
