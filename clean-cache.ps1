param(
    [string]$Config = "",
    [switch]$DryRun
)

# 清空上游缓存包,保留本地发布的包
#
# 判定依据:.verdaccio-db.json 的 list 只记录本地 publish 过的包,
# verdaccio 从 uplink(如 npmmirror)缓存下来的包不会写入 list。
# 因此:storage 里凡是不在 list 中的包目录 = 缓存,删除;
# 在 list 中的 = 本地发布,保留。DB 文件本身不修改。
#
# 注意:不能用 package.json 里的 _uplinks 字段区分 —— 本地包
# 在配置了 proxy 后同样会带上 _uplinks 记录(已实测)。

. "$PSScriptRoot\resolve-paths.ps1"

$config  = Resolve-VerdaccioConfig $Config
$storage = Resolve-VerdaccioStorage $config
$dbFile  = Join-Path $storage ".verdaccio-db.json"

Write-Host "Config:  $config"
Write-Host "Storage: $storage"

Write-Host "========================================"
Write-Host " Clean Upstream Cache (keep local packages)"
Write-Host "========================================"
Write-Host ""

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
    Write-Host "ERROR: Verdaccio is still running."
    Write-Host "Please run .\stop.ps1 first."
    exit 1
}

# ----------------------------------------
# 3. 读取 DB(严格校验:list 是"保留名单"的唯一来源,
#    DB 损坏时绝不能继续,否则本地包会被当成缓存误删)
# ----------------------------------------

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

$localNames = @($db.list)

if ($localNames.Count -eq 0) {
    Write-Host "ERROR: DB package list is empty."
    Write-Host "Refusing to clean cache: with an empty list every package"
    Write-Host "in storage would look like cache and be deleted."
    Write-Host "If the DB is damaged, restore it from db-backups first."
    Write-Host "If you really want to delete everything, use remove-all-packages.ps1"
    exit 1
}

# 保留名单(区分大小写,与 npm 包名语义一致)
$keep = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal)
foreach ($name in $localNames) {
    [void]$keep.Add("$name")
}

# ----------------------------------------
# 4. 扫描 storage,分类 本地包 / 缓存包
#    - 顶层普通目录:目录名在 list 中 → 保留
#    - 顶层 @scope 目录:子目录 @scope/name 在 list 中 → 保留
#    - 其余全部视为缓存 → 删除;删空的 scope 目录一并移除
# ----------------------------------------

function Get-CacheTargets {
    # 返回要删除的完整路径列表
    $targets = [System.Collections.Generic.List[string]]::new()

    $rootDirs = Get-ChildItem `
        -LiteralPath $storage `
        -Directory `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike ".*" }

    foreach ($dir in $rootDirs) {

        if ($dir.Name.StartsWith("@")) {

            foreach ($sub in Get-ChildItem `
                -LiteralPath $dir.FullName `
                -Directory `
                -ErrorAction SilentlyContinue) {

                $pkgName = "$($dir.Name)/$($sub.Name)"

                if (-not $keep.Contains($pkgName)) {
                    $targets.Add($sub.FullName)
                }
            }
        }
        elseif (-not $keep.Contains($dir.Name)) {
            $targets.Add($dir.FullName)
        }
    }

    return $targets
}

$toDelete = Get-CacheTargets
$scopeDirs = @(
    Get-ChildItem -LiteralPath $storage -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith("@") -and $_.Name -notlike ".*" } |
        ForEach-Object { $_.FullName }
)

# ----------------------------------------
# 5. 统计预览
# ----------------------------------------

$totalBytes = [long]0
foreach ($target in $toDelete) {
    $sum = (Get-ChildItem `
        -LiteralPath $target `
        -Recurse -File -Force `
        -ErrorAction SilentlyContinue |
        Measure-Object -Sum Length).Sum
    $totalBytes += [long]$sum
}
$totalMb = [math]::Round($totalBytes / 1MB, 1)

# DB 里记录了、但磁盘上没有目录的本地包(与缓存清理无关,仅提示;
# 记录清理由 clean-db.ps1 负责)
$missingOnDisk = @(
    $localNames | Where-Object {
        -not (Test-Path (Join-Path $storage ($_ -replace "/", "\")))
    }
)

Write-Host "Local packages (kept) : $($localNames.Count)"
Write-Host "Cache to delete       : $($toDelete.Count)"
Write-Host "Cache size            : $totalMb MB"
if ($missingOnDisk.Count -gt 0) {
    Write-Host ""
    Write-Host "NOTE: $($missingOnDisk.Count) local package(s) in DB have no"
    Write-Host "folder on disk (use clean-db.ps1 to drop those records):"
    foreach ($name in $missingOnDisk) { Write-Host "  $name" }
}
Write-Host ""
Write-Host "DB file and secret are NOT modified by this script."

if ($DryRun) {
    Write-Host ""
    Write-Host "[DryRun] Nothing deleted."
    exit 0
}

# ----------------------------------------
# 6. 确认
# ----------------------------------------

Write-Host ""
$answer = Read-Host 'Type "CLEAN CACHE" to confirm'

if ($answer -ne "CLEAN CACHE") {
    Write-Host "Cancelled."
    exit 0
}

# ----------------------------------------
# 7. 删除缓存包
# ----------------------------------------

$done = 0
$failed = [System.Collections.Generic.List[string]]::new()

foreach ($target in $toDelete) {

    try {
        Remove-Item `
            -LiteralPath $target `
            -Recurse -Force `
            -ErrorAction Stop
    }
    catch {
        # 长路径(>260 字符)重试:\\?\ 前缀绕过 MAX_PATH 限制
        try {
            Remove-Item `
                -LiteralPath ("\\?\" + $target) `
                -Recurse -Force `
                -ErrorAction Stop
        }
        catch {
            $failed.Add($target)
            continue
        }
    }

    $done++
    if ($done % 100 -eq 0) {
        Write-Host "Deleted $done / $($toDelete.Count) ..."
    }
}

# 移除已经清空的 scope 目录
foreach ($scope in $scopeDirs) {
    if (Test-Path -LiteralPath $scope) {
        $left = Get-ChildItem -LiteralPath $scope -Force -ErrorAction SilentlyContinue
        if (-not $left) {
            Remove-Item -LiteralPath $scope -Force
        }
    }
}

# ----------------------------------------
# 8. 校验结果
# ----------------------------------------

$remaining = @(Get-CacheTargets)
$keptOnDisk = @(
    $localNames | Where-Object {
        Test-Path (Join-Path $storage ($_ -replace "/", "\"))
    }
)

Write-Host ""
Write-Host "========================================"
Write-Host " Cache cleanup completed"
Write-Host "========================================"
Write-Host ""
Write-Host "Deleted cache packages : $done"
Write-Host "Failed                 : $($failed.Count)"
foreach ($target in $failed) {
    Write-Host "  FAILED: $target"
}
Write-Host "Freed space            : $totalMb MB"
Write-Host "Local packages kept    : $($keptOnDisk.Count) / $($localNames.Count)"
Write-Host "Cache remaining        : $($remaining.Count)"
Write-Host ""
Write-Host "DB modified: NO (secret and package list untouched)"

if ($failed.Count -gt 0 -or $remaining.Count -gt 0) {
    exit 1
}
