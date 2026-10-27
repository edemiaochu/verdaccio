param(
    [Parameter(Mandatory = $true)]
    [string]$List,             # 包列表文件(JSON 或每行一个包名的文本)

    [string]$Config = "",
    [switch]$DryRun
)

# 读取包列表文件,批量删除其中的包(整个包,含全部版本)。
#
# 支持的列表文件格式:
#   1. 简洁版 JSON:      { "packages": ["name1", "name2"] }
#   2. 带版本简洁版:      { "packages": ["name@1.2.3", ...] }  ← 版本号忽略,按整个包删除
#   3. 完整版 JSON:      { "packages": [{ "name": "...", ... }] }
#   4. 顶层就是数组:      ["name1", "name2"]
#   5. 文本文件:         每行一个包名(空行与 # 注释忽略)
#
# 流程与 remove-package.ps1 一致:先停止 Verdaccio,自动备份 DB,
# 二次确认(DELETE LIST)后删除 storage 目录并从 DB 列表移除,
# secret 原样保留。列表中不存在的包名只提示跳过,可重复执行。

. "$PSScriptRoot\resolve-paths.ps1"

# ----------------------------------------
# 0. 解析源路径 / 校验列表文件
# ----------------------------------------

$config  = Resolve-VerdaccioConfig $Config
$storage = Resolve-VerdaccioStorage $config
$dbFile  = Join-Path $storage ".verdaccio-db.json"
$backupDir = Join-Path $PSScriptRoot "db-backups"

Write-Host "========================================"
Write-Host " Remove Packages by List"
Write-Host "========================================"
Write-Host "Config:  $config"
Write-Host "Storage: $storage"
Write-Host "List:    $List"
Write-Host ""

if (-not (Test-Path -LiteralPath $List -PathType Leaf)) {
    Write-Host "ERROR: list file not found:"
    Write-Host $List
    exit 1
}

# ----------------------------------------
# 1. 解析列表 → 包名
# ----------------------------------------

# name@version 条目去掉版本号;scoped 名(@scope/name)不受影响
function Get-PackageName([string]$Entry) {
    $s = $Entry.Trim()
    if ($s -match '^(@?[^@]+(/[^@]+)?)@([^@]+)$') {
        return @{
            Name    = $Matches[1]
            Version = $Matches[3]
        }
    }
    return @{ Name = $s; Version = $null }
}

$raw = Get-Content -LiteralPath $List -Raw -ErrorAction SilentlyContinue
if ([string]::IsNullOrWhiteSpace($raw)) {
    Write-Host "ERROR: list file is empty:"
    Write-Host $List
    exit 1
}

$entries = $null

try {
    $json = $raw | ConvertFrom-Json
    # 顶层对象取 packages 字段(简洁版 / 完整版);其余按顶层数组处理。
    # 注意:不能用 -is [Array] 判断 —— 单元素数组经管道解包后是标量
    if ($json -and $json.PSObject.Properties["packages"] -and -not ($json -is [string])) {
        $entries = @($json.packages)
    }
    else {
        $entries = @($json)
    }
}
catch {
    # 不是 JSON:按文本文件处理,每行一个包名
    $entries = @(
        $raw -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith("#") }
    )
}

$names = [System.Collections.Generic.List[string]]::new()
$invalid = [System.Collections.Generic.List[string]]::new()
$versioned = [System.Collections.Generic.List[string]]::new()
$seen = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::Ordinal)

foreach ($e in $entries) {
    $text = $null
    if ($e -is [string]) {
        $text = $e
    }
    elseif ($e -and $e.PSObject.Properties["name"]) {
        # 完整版 JSON 的对象条目(versions 等字段忽略,按整个包删除)
        $text = "$($e.name)"
    }

    if ($null -eq $text -or [string]::IsNullOrWhiteSpace($text)) {
        $invalid.Add("(无法识别的条目: $e)")
        continue
    }

    $parsed = Get-PackageName $text
    $name = $parsed.Name

    if ($name -notmatch '^[@a-zA-Z0-9][@a-zA-Z0-9\/._-]*$') {
        $invalid.Add($text)
        continue
    }

    if ($parsed.Version) {
        $versioned.Add("$name@$($parsed.Version)")
    }

    if ($seen.Add($name)) { $names.Add($name) }
}

if ($invalid.Count -gt 0) {
    Write-Host "ERROR: $($invalid.Count) invalid entry(ies) in the list:"
    foreach ($x in $invalid) { Write-Host "  $x" }
    Write-Host "Nothing was deleted."
    exit 1
}

if ($names.Count -eq 0) {
    Write-Host "ERROR: no package names found in the list file."
    Write-Host "Supported formats: JSON {packages:[...]}, top-level array,"
    Write-Host "or a text file with one package name per line."
    exit 1
}

if ($versioned.Count -gt 0) {
    Write-Host "NOTE: $($versioned.Count) name@version entrie(s) found;"
    Write-Host "      the whole package will be deleted (version ignored)."
    Write-Host ""
}

# ----------------------------------------
# 2. 读取 DB
# ----------------------------------------

if (-not (Test-Path $dbFile)) {
    Write-Host "ERROR: DB file not found:"
    Write-Host $dbFile
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

# ----------------------------------------
# 3. 匹配:哪些包真实存在(DB 或磁盘)
# ----------------------------------------

$targets = [System.Collections.Generic.List[string]]::new()
$notFound = [System.Collections.Generic.List[string]]::new()

foreach ($name in $names) {
    $packagePath = Join-Path $storage ($name -replace "/", "\")
    $existsInDb = @($db.list) -contains $name
    $existsOnDisk = Test-Path -LiteralPath $packagePath

    if ($existsInDb -or $existsOnDisk) { $targets.Add($name) }
    else { $notFound.Add($name) }
}

Write-Host "Entries in list       : $($names.Count)"
Write-Host "Matched (will delete) : $($targets.Count)"
Write-Host "Not found (skipped)   : $($notFound.Count)"
Write-Host ""

# ----------------------------------------
# 4. 预览
# ----------------------------------------

$show = @($targets | Select-Object -First 50)
foreach ($name in $show) {
    $packagePath = Join-Path $storage ($name -replace "/", "\")
    $mark = ""
    if (-not (Test-Path -LiteralPath $packagePath)) { $mark = "  (DB record only)" }
    Write-Host "  $name$mark"
}
if ($targets.Count -gt 50) {
    Write-Host "  ... (共 $($targets.Count) 个)"
}
Write-Host ""

if ($notFound.Count -gt 0) {
    Write-Host "Not in storage / DB (skipped):"
    foreach ($name in @($notFound | Select-Object -First 20)) { Write-Host "  $name" }
    if ($notFound.Count -gt 20) {
        Write-Host "  ... (共 $($notFound.Count) 个)"
    }
    Write-Host ""
}

if ($targets.Count -eq 0) {
    Write-Host "Nothing to delete."
    exit 0
}

if ($DryRun) {
    Write-Host "[DryRun] Nothing deleted."
    exit 0
}

# ----------------------------------------
# 5. 运行中检查:占用该 storage 的 Verdaccio 必须先停止
#    (按 storage 归属判断而非端口;DryRun 预览不受限制)
# ----------------------------------------

function Get-RunningVerdaccioStorages {
    $result = [System.Collections.Generic.List[string]]::new()
    $procs = Get-CimInstance Win32_Process `
        -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue

    foreach ($p in $procs) {
        $cmd = "$($p.CommandLine)"
        if ($cmd -notmatch 'verdaccio') { continue }

        $cfg = $null
        if ($cmd -match '(?:^|\s)-c\s+"([^"]+)"') { $cfg = $Matches[1] }
        elseif ($cmd -match "(?:^|\s)-c\s+'([^']+)'") { $cfg = $Matches[1] }
        elseif ($cmd -match '(?:^|\s)-c\s+([^\s"]+)') { $cfg = $Matches[1] }
        if (-not $cfg) { $cfg = Join-Path $env:APPDATA "verdaccio\config.yaml" }

        $rel = "storage"
        if (Test-Path -LiteralPath $cfg) {
            $text = Get-Content $cfg -Raw -ErrorAction SilentlyContinue
            if ($text -match '(?m)^\s*storage\s*:\s*(.+?)\s*(?:#.*)?$') {
                $rel = $Matches[1].Trim().Trim('"').Trim("'")
            }
            $dir = Split-Path -Parent $cfg
            if ([System.IO.Path]::IsPathRooted($rel)) {
                $result.Add([System.IO.Path]::GetFullPath($rel))
            }
            else {
                $result.Add([System.IO.Path]::GetFullPath((Join-Path $dir $rel)))
            }
        }
    }
    return $result
}

$targetStorageFull = [System.IO.Path]::GetFullPath($storage)
foreach ($running in Get-RunningVerdaccioStorages) {
    if ([string]::Equals($running, $targetStorageFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "ERROR: a running Verdaccio is using this storage:"
        Write-Host $targetStorageFull
        Write-Host "Please run .\stop.ps1 first."
        exit 1
    }
}

# ----------------------------------------
# 6. 创建 backup
# ----------------------------------------

if (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$backupFile = Join-Path `
    $backupDir `
    ".verdaccio-db-before-remove-list-$timestamp.json"

Copy-Item $dbFile $backupFile

Write-Host "DB backup:"
Write-Host $backupFile
Write-Host ""

# ----------------------------------------
# 7. 二次确认
# ----------------------------------------

if ([Console]::IsInputRedirected) {
    $answer = [Console]::In.ReadLine()
}
else {
    $answer = Read-Host 'Type "DELETE LIST" to confirm'
}

if ("$answer".Trim() -ne "DELETE LIST") {
    Write-Host "Cancelled."
    exit 0
}

# ----------------------------------------
# 8. 删除 storage 与 DB 记录
# ----------------------------------------

$done = 0
$failed = [System.Collections.Generic.List[string]]::new()

foreach ($name in $targets) {
    $packagePath = Join-Path $storage ($name -replace "/", "\")

    if (Test-Path -LiteralPath $packagePath) {
        try {
            Remove-Item `
                -LiteralPath $packagePath `
                -Recurse `
                -Force `
                -ErrorAction Stop
        }
        catch {
            # 长路径(>260 字符)重试:\\?\ 前缀绕过 MAX_PATH 限制
            try {
                Remove-Item `
                    -LiteralPath ("\\?\" + $packagePath) `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop
            }
            catch {
                $failed.Add($name)
                continue
            }
        }
    }

    $done++
}

# 从 DB 列表移除(保留 secret)
$kept = @(
    $db.list | Where-Object {
        $targets -notcontains $_
    }
)

$db.list = $kept
$db.secret = $secret

# 写回 DB(-Depth 必须 ≥ 3,默认 2 会把嵌套对象写成类型名字符串)
$json = $db | ConvertTo-Json -Compress -Depth 100

[System.IO.File]::WriteAllText(
    $dbFile,
    $json,
    [System.Text.UTF8Encoding]::new($false))

# 移除删空的 @scope 目录
$scopeDirs = @(
    Get-ChildItem -LiteralPath $storage -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith("@") -and $_.Name -notlike ".*" } |
        ForEach-Object { $_.FullName }
)
foreach ($scope in $scopeDirs) {
    if (Test-Path -LiteralPath $scope) {
        $left = Get-ChildItem -LiteralPath $scope -Force -ErrorAction SilentlyContinue
        if (-not $left) {
            Remove-Item -LiteralPath $scope -Force -ErrorAction SilentlyContinue
        }
    }
}

# ----------------------------------------
# 9. 汇总
# ----------------------------------------

Write-Host ""
Write-Host "========================================"
Write-Host " Remove by list completed"
Write-Host "========================================"
Write-Host "Packages deleted : $done / $($targets.Count)"
Write-Host "Not found        : $($notFound.Count) (skipped)"
Write-Host "Failed           : $($failed.Count)"
foreach ($name in $failed) { Write-Host "  FAILED: $name" }
Write-Host "DB updated."
Write-Host "Secret preserved: YES"
Write-Host "Backup: $backupFile"

if ($failed.Count -gt 0) {
    exit 1
}
