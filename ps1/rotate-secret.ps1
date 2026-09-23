$storage = "C:\Users\lenovo\.config\verdaccio\storage"
$dbFile = Join-Path $storage ".verdaccio-db.json"

# 因为当前脚本位于：
# verdaccio-tools-windows\ps1\
# 所以工具根目录是上一级
$toolRoot = Split-Path $PSScriptRoot -Parent

$backupDir = Join-Path $toolRoot "backups"

Write-Host "========================================"
Write-Host " Verdaccio Secret Rotation"
Write-Host "========================================"
Write-Host ""

# ----------------------------------------
# 检查 DB
# ----------------------------------------

if (-not (Test-Path $dbFile)) {
    Write-Host "ERROR: DB file not found:"
    Write-Host $dbFile
    exit 1
}

# ----------------------------------------
# 检查 Verdaccio 是否正在运行
# ----------------------------------------

$connections = Get-NetTCPConnection `
    -LocalPort 4873 `
    -State Listen `
    -ErrorAction SilentlyContinue

if ($null -ne $connections) {
    Write-Host "ERROR: Verdaccio is still running."
    Write-Host ""
    Write-Host "Please run:"
    Write-Host "  ..\bat\run-stop.bat"
    Write-Host ""
    exit 1
}

# ----------------------------------------
# 读取 DB
# ----------------------------------------

try {
    $db = Get-Content $dbFile -Raw | ConvertFrom-Json
}
catch {
    Write-Host "ERROR: Failed to read Verdaccio DB."
    Write-Host $_.Exception.Message
    exit 1
}

if ($null -eq $db.secret -or [string]::IsNullOrWhiteSpace($db.secret)) {
    Write-Host "ERROR: Existing secret was not found."
    exit 1
}

$oldSecretLength = $db.secret.Length

# ----------------------------------------
# 创建备份目录
# ----------------------------------------

if (-not (Test-Path $backupDir)) {
    New-Item `
        -ItemType Directory `
        -Path $backupDir |
        Out-Null
}

# ----------------------------------------
# 备份 DB
# ----------------------------------------

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$backupFile = Join-Path `
    $backupDir `
    ".verdaccio-db-before-secret-rotation-$timestamp.json"

Copy-Item `
    -LiteralPath $dbFile `
    -Destination $backupFile `
    -Force

Write-Host "DB backup created:"
Write-Host "  $backupFile"
Write-Host ""

# ----------------------------------------
# 二次确认
# ----------------------------------------

Write-Host "WARNING:"
Write-Host "Rotating the Verdaccio secret will invalidate"
Write-Host "existing Verdaccio authentication tokens."
Write-Host ""
Write-Host "After rotation, users must login again."
Write-Host ""

$answer = Read-Host 'Type "ROTATE" to continue'

if ($answer -ne "ROTATE") {
    Write-Host ""
    Write-Host "Cancelled."
    exit 0
}

# ----------------------------------------
# 使用 Windows Cryptographic RNG
# ----------------------------------------

$characters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

try {
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)

    $newSecretChars = New-Object char[] 32

    for ($i = 0; $i -lt 32; $i++) {
        $newSecretChars[$i] =
            $characters[$bytes[$i] % $characters.Length]
    }

    $newSecret = -join $newSecretChars
}
finally {
    $rng.Dispose()
}

# ----------------------------------------
# 修改 secret
#
# list 完全保留
# ----------------------------------------

$db.secret = $newSecret

# ----------------------------------------
# 写回 JSON
# ----------------------------------------

try {
    $json = $db | ConvertTo-Json -Compress -Depth 100

    [System.IO.File]::WriteAllText(
        $dbFile,
        $json,
        [System.Text.UTF8Encoding]::new($false)
    )
}
catch {
    Write-Host "ERROR: Failed to write Verdaccio DB."
    Write-Host $_.Exception.Message
    Write-Host ""
    Write-Host "Your original DB backup is still available:"
    Write-Host $backupFile
    exit 1
}

# ----------------------------------------
# 验证写入
# ----------------------------------------

try {
    $verifyDb = Get-Content $dbFile -Raw | ConvertFrom-Json

    if ($null -eq $verifyDb.secret) {
        throw "Secret is missing after write."
    }

    if ($verifyDb.secret.Length -ne 32) {
        throw "Secret length is not 32."
    }
}
catch {
    Write-Host "ERROR: Secret verification failed."
    Write-Host $_.Exception.Message
    Write-Host ""
    Write-Host "Backup:"
    Write-Host $backupFile
    exit 1
}

# ----------------------------------------
# 完成
# ----------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host " Secret rotation completed"
Write-Host "========================================"
Write-Host ""
Write-Host "DB:"
Write-Host "  $dbFile"
Write-Host ""
Write-Host "Old secret length:"
Write-Host "  $oldSecretLength"
Write-Host ""
Write-Host "New secret length:"
Write-Host "  32"
Write-Host ""
Write-Host "Secret changed : YES"
Write-Host "Package list   : PRESERVED"
Write-Host "Backup created : YES"
Write-Host ""
Write-Host "The new secret is intentionally NOT displayed."
Write-Host ""
Write-Host "Existing authentication tokens are now invalid."
Write-Host "Run npm login again to obtain a new token."
Write-Host ""