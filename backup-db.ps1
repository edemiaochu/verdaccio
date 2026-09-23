$storage = "C:\Users\lenovo\.config\verdaccio\storage"
$dbFile = Join-Path $storage ".verdaccio-db.json"

$backupDir = "D:\verdaccio\db-backups"

if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

if (-not (Test-Path $dbFile)) {
    Write-Host "ERROR: DB file not found:"
    Write-Host $dbFile
    exit 1
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$backupFile = Join-Path `
    $backupDir `
    ".verdaccio-db-$timestamp.json"

Copy-Item $dbFile $backupFile

Write-Host "DB backup completed."
Write-Host ""
Write-Host "Original:"
Write-Host $dbFile
Write-Host ""
Write-Host "Backup:"
Write-Host $backupFile